//! 黄金模型：ISA 语义的唯一裁判。
//!
//! - per-lane 通用寄存器和谓词，per-warp 执行 mask `M`、PC、状态；
//! - warp 级统一分支、mask 指令（含 `.P` 形式的 `M` 相干规则）；
//! - shared / global 两个地址空间，访存做对齐和越界检查；
//! - 多条 warp 轮转执行，`BAR` 在"所有未结束的 warp 都到达 BAR"时放行。
//!
//! 不模拟流水线、延迟和 scoreboard，所以 `LDG` 的下一条指令就能看到结果。
//! ISA 有歧义时以本文件为准，然后同步 docs/design.md。

use crate::isa::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum WarpState {
    Run,
    Bar,
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Space {
    Smem,
    Gmem,
}

#[derive(Clone, Debug)]
pub struct Config {
    /// warpSize：每个 warp 的 lane 数（对应 `S_WARPSZ`，硬件上是 `SK_NUM_LANES`）。
    pub warpsz: usize,
    /// warp 数（硬件容量）。
    pub nwarp: usize,
    /// `blockDim.x`：主机给的 block 线程数。`None` = 用满容量 `nwarp * warpsz`。
    pub block_dim: Option<usize>,
    pub grid: u32,
    pub smem_bytes: usize,
    pub gmem_bytes: usize,
    pub sregs: Vec<(Sreg, u32)>,
    pub trace: bool,
    pub max_steps: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            warpsz: NUM_LANES,
            nwarp: NUM_WARPS,
            block_dim: None,
            grid: 1,
            smem_bytes: 32 * 1024,
            gmem_bytes: 1 << 20,
            sregs: Vec::new(),
            trace: false,
            max_steps: 1_000_000,
        }
    }
}

impl Config {
    /// 设置一个特殊寄存器（`PTR_A`、`ARG0` …）。
    pub fn with(mut self, sreg: Sreg, value: u32) -> Self {
        self.sregs.push((sreg, value));
        self
    }

    pub fn tracing(mut self, trace: bool) -> Self {
        self.trace = trace;
        self
    }
}

pub struct Warp {
    pub wid: usize,
    pub pc: usize,
    pub m: u32,
    /// warp 生成时的完整 mask，`BAR` 要求 `m == full`。
    pub full: u32,
    pub gpr: Vec<[u32; NUM_GPR]>,
    pub pred: Vec<[bool; NUM_PRED]>,
    pub state: WarpState,
}

pub struct Machine {
    pub imem: Vec<u32>,
    pub warps: Vec<Warp>,
    pub status: Status,
    pub steps: u64,
    pub barriers: u64,
    /// 出错时停在哪：`(wid, pc)`。`STATUS` 和这个 PC 是错误路径的契约
    /// （docs/design.md §5.5）；正常结束是 `None`。
    pub fault: Option<(usize, usize)>,
    /// 各分类的指令条数（性能计数用，见 docs/design.md §13）。
    counts: Vec<u64>,
    /// 当前正在执行哪条 warp 的哪条指令：fail 时用它抓"停下来的 PC"。
    cur_wid: Option<usize>,
    /// 模拟器的死循环保护被触发（不是硬件状态）。
    pub limit_hit: bool,
    /// warpSize（`S_WARPSZ`）。
    pub warpsz: usize,
    pub nwarp: usize,
    /// 主机给的 block 线程数（`S_BLOCK_DIM`），已解析成具体值。
    block_dim: usize,
    grid: u32,
    /// 当前正在跑的 block 索引（`S_BID`）。
    bid: u32,
    smem: Vec<u8>,
    gmem: Vec<u8>,
    sregs: Vec<(Sreg, u32)>,
    trace: bool,
    max_steps: u64,
}

impl Machine {
    pub fn new(imem: Vec<u32>, config: Config) -> Machine {
        // warp 的完整 mask 由 warpSize 决定（32 位是上限）；没有部分 warp
        let full = if config.warpsz >= 32 {
            u32::MAX
        } else {
            (1u32 << config.warpsz) - 1
        };
        let warps = (0..config.nwarp)
            .map(|wid| Warp {
                wid,
                pc: 0,
                m: full,
                full,
                gpr: vec![[0; NUM_GPR]; config.warpsz],
                pred: vec![[false; NUM_PRED]; config.warpsz],
                state: WarpState::Run,
            })
            .collect();
        Machine {
            imem,
            warps,
            status: Status::Ok,
            steps: 0,
            barriers: 0,
            fault: None,
            counts: vec![0; OpClass::ALL.len()],
            cur_wid: None,
            limit_hit: false,
            warpsz: config.warpsz,
            nwarp: config.nwarp,
            block_dim: config.block_dim.unwrap_or(config.nwarp * config.warpsz),
            grid: config.grid,
            bid: 0,
            smem: vec![0; config.smem_bytes],
            gmem: vec![0; config.gmem_bytes],
            sregs: config.sregs,
            trace: config.trace,
            max_steps: config.max_steps,
        }
    }

    // --- 内存访问（测试和主机侧用）---

    pub fn write_word(&mut self, space: Space, addr: usize, value: u32) {
        let memory = self.memory_mut(space);
        memory[addr..addr + 4].copy_from_slice(&value.to_le_bytes());
    }

    pub fn read_word(&self, space: Space, addr: usize) -> u32 {
        let memory = self.memory(space);
        u32::from_le_bytes(memory[addr..addr + 4].try_into().unwrap())
    }

    fn memory(&self, space: Space) -> &[u8] {
        match space {
            Space::Smem => &self.smem,
            Space::Gmem => &self.gmem,
        }
    }

    fn memory_mut(&mut self, space: Space) -> &mut [u8] {
        match space {
            Space::Smem => &mut self.smem,
            Space::Gmem => &mut self.gmem,
        }
    }

    // --- 性能计数（M3 的 IPC 曲线、M5 的带宽/事务表用）---

    pub fn count(&self, class: OpClass) -> u64 {
        self.counts[class.code() as usize]
    }

    pub fn op_counts(&self) -> impl Iterator<Item = (OpClass, u64)> + '_ {
        OpClass::ALL
            .iter()
            .copied()
            .map(|class| (class, self.count(class)))
    }

    // --- 执行 ---

    /// 启动参数检查：`1 ≤ BLOCK_DIM ≤ NWARP × WARPSZ`，且是 `WARPSZ` 的整数倍
    /// （不允许部分 warp）。见 docs/design.md §5.6。
    fn launch_error(&self) -> Option<Status> {
        let capacity = self.nwarp * self.warpsz;
        let bad = self.warpsz == 0
            || self.block_dim == 0
            || self.block_dim > capacity
            || self.block_dim % self.warpsz != 0;
        bad.then_some(Status::BadLaunch)
    }

    pub fn run(&mut self) -> Status {
        self.cur_wid = None;
        self.fault = None;
        if let Some(status) = self.launch_error() {
            self.fail(status);
            return self.status;
        }
        let active_warps = self.block_dim / self.warpsz;
        for block in 0..self.grid {
            self.bid = block;
            for warp in &mut self.warps {
                warp.pc = 0;
                warp.m = warp.full;
                warp.gpr.fill([0; NUM_GPR]);
                warp.pred.fill([false; NUM_PRED]);
                // 只有 BLOCK_DIM / WARPSZ 条 warp 活跃，其余直接 done
                warp.state = if warp.wid < active_warps {
                    WarpState::Run
                } else {
                    WarpState::Done
                };
            }
            self.run_block();
            if self.status != Status::Ok || self.limit_hit {
                break;
            }
        }
        self.status
    }

    /// 跑一个 block：所有 warp 轮转执行到 EXIT；剩下还在 BAR 的 warp 一起放行。
    fn run_block(&mut self) {
        while self.status == Status::Ok {
            let running: Vec<usize> = (0..self.warps.len())
                .filter(|&wid| self.warps[wid].state == WarpState::Run)
                .collect();
            if running.is_empty() {
                let waiting: Vec<usize> = (0..self.warps.len())
                    .filter(|&wid| self.warps[wid].state == WarpState::Bar)
                    .collect();
                if !waiting.is_empty() {
                    for wid in waiting {
                        self.warps[wid].state = WarpState::Run;
                    }
                    self.barriers += 1;
                    continue;
                }
                break;
            }
            for wid in running {
                self.step(wid);
                if self.status != Status::Ok {
                    break;
                }
            }
        }
    }

    fn step(&mut self, wid: usize) {
        self.cur_wid = Some(wid);
        if self.warps[wid].pc >= self.imem.len() {
            self.fail(Status::PcOob);
            return;
        }
        let pc = self.warps[wid].pc;
        let insn = Insn::decode(self.imem[pc]);
        if let Some(class) = op_class(insn.op) {
            self.counts[class.code() as usize] += 1;
        }
        self.warps[wid].pc += 1;
        self.steps += 1;
        if self.steps > self.max_steps {
            self.limit_hit = true;
            for warp in &mut self.warps {
                warp.state = WarpState::Done;
            }
            return;
        }
        if self.trace {
            println!(
                "w{wid} {pc:04x}  M={:0width$b}  {}",
                self.warps[wid].m,
                disasm(&insn, Some(pc)),
                width = self.warpsz
            );
        }
        self.execute(wid, pc, &insn);
    }

    fn fail(&mut self, status: Status) {
        self.status = status;
        // "停下来的 PC" = 这条 warp 现在的 pc：取指越界时不前进，其余错误是
        // `pc += 1` 之后的值，两种都和契约一致（docs/design.md §5.5）。
        self.fault = self.cur_wid.map(|wid| (wid, self.warps[wid].pc));
        for warp in &mut self.warps {
            warp.state = WarpState::Done;
        }
    }

    /// 受 `M` 和 `@p` 门控的活跃 lane；`SEL` 的 pred 字段是操作数，不是门控。
    fn lanes(&self, wid: usize, insn: &Insn, gate: bool) -> Vec<usize> {
        let index = if gate { insn.pred_index() } else { None };
        let inverted = gate && insn.pred_inverted();
        let warp = &self.warps[wid];
        (0..self.warpsz)
            .filter(|&lane| (warp.m >> lane) & 1 == 1)
            .filter(|&lane| match index {
                Some(index) => warp.pred[lane][index as usize] != inverted,
                None => true,
            })
            .collect()
    }

    /// 每 lane 的谓词拼成一个 mask 值。
    fn pred_word(&self, wid: usize, index: u32) -> u32 {
        let mut word = 0;
        for lane in 0..self.warpsz {
            if self.warps[wid].pred[lane][index as usize] {
                word |= 1 << lane;
            }
        }
        word
    }

    /// 没设置过的参数寄存器读出 0（对应 AXI-Lite 控制寄存器的复位值）。
    fn read_sreg(&self, wid: usize, lane: usize, sreg: Sreg) -> u32 {
        match sreg {
            Sreg::Tid => (self.warps[wid].wid * self.warpsz + lane) as u32,
            Sreg::LaneId => lane as u32,
            Sreg::Wid => self.warps[wid].wid as u32,
            Sreg::Warpsz => self.warpsz as u32,
            Sreg::Nwarp => self.nwarp as u32,
            Sreg::BlockDim => self.block_dim as u32,
            Sreg::Grid => self.grid,
            Sreg::Bid => self.bid,
            Sreg::Status => self.status.code(),
            other => self
                .sregs
                .iter()
                .find(|(name, _)| *name == other)
                .map(|(_, value)| *value)
                .unwrap_or(0),
        }
    }

    /// 一条 lane 的 GPR 写回。`r0` 恒为 0：写 `r0` 被丢弃，和 RTL 的寄存器堆一致。
    fn wb(&mut self, wid: usize, lane: usize, reg: u32, value: u32) {
        if reg != 0 {
            self.warps[wid].gpr[lane][reg as usize] = value;
        }
    }

    fn execute(&mut self, wid: usize, pc: usize, insn: &Insn) {
        match insn.op {
            OP_RALU => {
                let Some(op) = Ralu::from_code(insn.func) else {
                    return self.fail(Status::BadInsn);
                };
                for lane in self.lanes(wid, insn, true) {
                    let acc = self.warps[wid].gpr[lane][insn.rd as usize];
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    let b = self.warps[wid].gpr[lane][insn.rb as usize];
                    let value = ralu_exec(op, acc, a, b);
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            op if is_cmp_op(op) => {
                let (Some(cond), Some(bop)) = (Cmp::from_code(insn.func), insn.bop()) else {
                    return self.fail(Status::BadInsn);
                };
                if insn.rd as usize >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                for lane in self.lanes(wid, insn, true) {
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    let b = self.warps[wid].gpr[lane][insn.rb as usize];
                    let value = cmp_exec(cond, a, b);
                    let dest = &mut self.warps[wid].pred[lane][insn.rd as usize];
                    *dest = match bop {
                        Bop::Set => value,
                        Bop::And => *dest & value,
                        Bop::Or => *dest | value,
                        Bop::Xor => *dest ^ value,
                    };
                }
            }
            OP_SEL => {
                let Some(index) = insn.pred_index() else {
                    return self.fail(Status::BadInsn);
                };
                for lane in self.lanes(wid, insn, false) {
                    let pred = self.warps[wid].pred[lane][index as usize];
                    let (ra, rb) = (insn.ra as usize, insn.rb as usize);
                    let value = if pred {
                        self.warps[wid].gpr[lane][ra]
                    } else {
                        self.warps[wid].gpr[lane][rb]
                    };
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            OP_ADDI | OP_ANDI | OP_ORI | OP_SHLI | OP_SLTI | OP_LUI | OP_LUM => {
                for lane in self.lanes(wid, insn, true) {
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    let value = imm_exec(insn, a);
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            OP_LDS | OP_LDG => {
                let space = if insn.op == OP_LDS {
                    Space::Smem
                } else {
                    Space::Gmem
                };
                let Some(addrs) = self.active_addrs(wid, insn, space) else {
                    return;
                };
                for (lane, addr) in addrs {
                    let value = self.read_word(space, addr);
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            OP_STS | OP_STG => {
                let space = if insn.op == OP_STS {
                    Space::Smem
                } else {
                    Space::Gmem
                };
                let Some(addrs) = self.active_addrs(wid, insn, space) else {
                    return;
                };
                for (lane, addr) in addrs {
                    let value = self.warps[wid].gpr[lane][insn.rd as usize];
                    self.write_word(space, addr, value);
                }
            }
            OP_MASK => self.mask_op(wid, pc, insn),
            OP_BRZ | OP_BRNZ => {
                let zero = self.warps[wid].gpr[0][insn.rs() as usize] == 0;
                let taken = if insn.op == OP_BRZ { zero } else { !zero };
                if taken {
                    self.warps[wid].pc = (pc as i64 + 1 + insn.off_signed() as i64) as usize;
                }
            }
            OP_JMP => {
                self.warps[wid].pc = (pc as i64 + 1 + insn.off_signed() as i64) as usize;
            }
            OP_SREAD => {
                let Some(sreg) = Sreg::from_code(insn.ra) else {
                    return self.fail(Status::BadInsn);
                };
                for lane in self.lanes(wid, insn, true) {
                    let value = self.read_sreg(wid, lane, sreg);
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            OP_SHFL => {
                let Some(mode) = Shfl::from_code(insn.func) else {
                    return self.fail(Status::BadInsn);
                };
                let lanes = self.lanes(wid, insn, true);
                let n = self.warpsz;
                let m = self.warps[wid].m;
                let (rd, rb) = (insn.rd as usize, insn.rb as usize);
                // 先快照所有 lane 的源值：写回不能影响同一拍的其他 lane
                let source: Vec<u32> = (0..n)
                    .map(|lane| self.warps[wid].gpr[lane][insn.ra as usize])
                    .collect();
                for lane in lanes {
                    let delta = self.warps[wid].gpr[lane][rb] as usize;
                    let src = match mode {
                        Shfl::Idx => Some(delta % n),
                        Shfl::Up => lane.checked_sub(delta),
                        Shfl::Down => lane.checked_add(delta).filter(|src| *src < n),
                        Shfl::Bfly => Some(lane ^ delta).filter(|src| *src < n),
                    };
                    // 越界或源 lane 不在 M 里：保持自己的值（对齐 NV）
                    let value = match src {
                        Some(src) if (m >> src) & 1 == 1 => source[src],
                        _ => source[lane],
                    };
                    self.wb(wid, lane, rd as u32, value);
                }
            }
            OP_VOTE => {
                let Some(mode) = Vote::from_code(insn.func) else {
                    return self.fail(Status::BadInsn);
                };
                if insn.rb as usize >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                let pred = self.pred_word(wid, insn.rb);
                let m = self.warps[wid].m;
                let value = match mode {
                    Vote::Any => u32::from(m & pred != 0),
                    Vote::All => u32::from(m & !pred == 0),
                };
                // warp 级指令：结果写所有 lane，BRZ/BRNZ 读 lane 0 也拿得到
                for lane in 0..self.warpsz {
                    self.wb(wid, lane, insn.rd, value);
                }
            }
            OP_SYS => self.sys_op(wid, insn),
            _ => self.fail(Status::BadInsn),
        }
    }

    /// 活跃 lane 的访存地址；对齐或越界就报错并返回 `None`。
    fn active_addrs(
        &mut self,
        wid: usize,
        insn: &Insn,
        space: Space,
    ) -> Option<Vec<(usize, usize)>> {
        let mut addrs = Vec::new();
        for lane in self.lanes(wid, insn, true) {
            let addr =
                self.warps[wid].gpr[lane][insn.ra as usize] as i64 + insn.imm_signed() as i64;
            if addr % WORD_BYTES as i64 != 0 {
                self.fail(Status::Unaligned);
                return None;
            }
            let addr = addr as usize;
            if addr + WORD_BYTES as usize > self.memory(space).len() {
                self.fail(oob_status(space));
                return None;
            }
            addrs.push((lane, addr));
        }
        Some(addrs)
    }

    /// mask 指令的 GPR 操作数必须全 lane 一致。硬件不查这一条，这是模型侧的调试检查
    /// （见 docs/design.md §6.5）：mask 值由 MSAVE 广播、被 MREST 当输入，天生是 warp
    /// 一致的，kernel 里出现"每条 lane 各自一套 mask"一定是写错了。返回 lane 0 的值。
    fn uniform_gpr(&self, wid: usize, pc: usize, insn: &Insn, reg: u32) -> u32 {
        let warp = &self.warps[wid];
        let first = warp.gpr[0][reg as usize];
        let odd: Vec<String> = (0..self.warpsz)
            .filter(|&lane| warp.gpr[lane][reg as usize] != first)
            .map(|lane| format!("lane{lane}={:#010x}", warp.gpr[lane][reg as usize]))
            .collect();
        assert!(
            odd.is_empty(),
            "w{wid} pc={pc:04x} {}：r{reg} 必须全 lane 一致，lane0={first:#010x}，{}",
            disasm(insn, Some(pc)),
            odd.join(" ")
        );
        first
    }

    fn mask_op(&mut self, wid: usize, pc: usize, insn: &Insn) {
        let Some(op) = MaskOp::from_code(insn.func) else {
            return self.fail(Status::BadInsn);
        };
        let full = self.warps[wid].full;
        let (rd, rb) = (insn.rd as usize, insn.rb as usize);
        let value = match op {
            MaskOp::Msave => self.warps[wid].m,
            MaskOp::Mrest => {
                let source = self.uniform_gpr(wid, pc, insn, insn.ra);
                self.warps[wid].m = source & full;
                return;
            }
            MaskOp::MclrP => {
                if rb >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                self.warps[wid].m = self.warps[wid].m & !self.pred_word(wid, rb as u32) & full;
                return;
            }
            MaskOp::Mmov => self.uniform_gpr(wid, pc, insn, insn.ra),
            MaskOp::Mnot => !self.uniform_gpr(wid, pc, insn, insn.ra),
            MaskOp::Mand => {
                self.uniform_gpr(wid, pc, insn, insn.ra) & self.uniform_gpr(wid, pc, insn, insn.rb)
            }
            MaskOp::Mandn => {
                self.uniform_gpr(wid, pc, insn, insn.ra) & !self.uniform_gpr(wid, pc, insn, insn.rb)
            }
            MaskOp::Mor => {
                self.uniform_gpr(wid, pc, insn, insn.ra) | self.uniform_gpr(wid, pc, insn, insn.rb)
            }
            // `.P` / `.PM`：谓词按 `p & M` 读，之后是普通位运算；结果不再强制 ⊆ M，
            // 要交集就显式把当前 mask 当 ra。
            MaskOp::MandP
            | MaskOp::MandnP
            | MaskOp::MorP
            | MaskOp::MandPm
            | MaskOp::MandnPm
            | MaskOp::MorPm => {
                if rb >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                let pred = self.pred_word(wid, rb as u32) & self.warps[wid].m;
                let source = self.uniform_gpr(wid, pc, insn, insn.ra);
                match op {
                    MaskOp::MandP | MaskOp::MandPm => source & pred,
                    MaskOp::MandnP | MaskOp::MandnPm => source & !pred,
                    _ => source | pred,
                }
            }
        } & full;
        // mask 指令是 warp 级操作，不受 M 门控：写所有 lane
        for lane in 0..self.warpsz {
            self.wb(wid, lane, rd as u32, value);
        }
        // `.PM`：rd 和 M 同拍更新（上面算结果时读的还是旧 M）
        if op.writes_mask() {
            self.warps[wid].m = value;
        }
    }

    fn sys_op(&mut self, wid: usize, insn: &Insn) {
        match Sys::from_code(insn.func) {
            Some(Sys::Nop) => {}
            Some(Sys::Bar) => {
                if self.warps[wid].m != self.warps[wid].full {
                    return self.fail(Status::BarIncomplete);
                }
                self.warps[wid].state = WarpState::Bar;
            }
            Some(Sys::Exit) => self.warps[wid].state = WarpState::Done,
            None => self.fail(Status::BadInsn),
        }
    }

    pub fn dump_state(&self) -> String {
        let mut out = String::new();
        out.push_str("{\n");
        out.push_str(&format!("  \"status\": {},\n", self.status.code()));
        out.push_str(&format!("  \"status_name\": \"{}\",\n", self.status.text()));
        out.push_str("  \"fault\": ");
        match self.fault {
            Some((wid, pc)) => out.push_str(&format!("{{\"wid\": {wid}, \"pc\": {pc}}},\n")),
            None => out.push_str("null,\n"),
        }
        out.push_str(&format!("  \"steps\": {},\n", self.steps));
        out.push_str(&format!("  \"barriers\": {},\n", self.barriers));
        out.push_str(&format!("  \"grid\": {},\n", self.grid));
        out.push_str(&format!("  \"bid\": {},\n", self.bid));
        out.push_str(&format!("  \"warpsz\": {},\n", self.warpsz));
        out.push_str(&format!("  \"block_dim\": {},\n", self.block_dim));
        let counts: Vec<String> = self
            .op_counts()
            .map(|(class, value)| format!("\"{}\": {value}", class.text()))
            .collect();
        out.push_str(&format!("  \"op_counts\": {{{}}},\n", counts.join(", ")));
        out.push_str("  \"warps\": [\n");
        for (index, warp) in self.warps.iter().enumerate() {
            out.push_str("    {\n");
            out.push_str(&format!("      \"wid\": {},\n", warp.wid));
            out.push_str(&format!("      \"pc\": {},\n", warp.pc));
            out.push_str(&format!("      \"m\": {},\n", warp.m));
            out.push_str(&format!("      \"state\": \"{:?}\",\n", warp.state));
            let gpr: Vec<String> = warp
                .gpr
                .iter()
                .map(|lane| format!("[{}]", join_u32(lane)))
                .collect();
            out.push_str(&format!("      \"gpr\": [{}],\n", gpr.join(", ")));
            let pred: Vec<String> = warp
                .pred
                .iter()
                .map(|lane| {
                    let bits: Vec<String> = lane.iter().map(|p| u8::from(*p).to_string()).collect();
                    format!("[{}]", bits.join(", "))
                })
                .collect();
            out.push_str(&format!("      \"pred\": [{}]\n", pred.join(", ")));
            out.push_str(if index + 1 == self.warps.len() {
                "    }\n"
            } else {
                "    },\n"
            });
        }
        out.push_str("  ]\n}\n");
        out
    }
}

fn join_u32(values: &[u32]) -> String {
    values
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

fn oob_status(space: Space) -> Status {
    match space {
        Space::Smem => Status::SmemOob,
        Space::Gmem => Status::GmemOob,
    }
}

/// 执行 R 格式 ALU 指令；`acc` 是 `rd` 的旧值，只有 `FMA` 用得到。
fn ralu_exec(op: Ralu, acc: u32, a: u32, b: u32) -> u32 {
    match op {
        Ralu::Add => a.wrapping_add(b),
        Ralu::Sub => a.wrapping_sub(b),
        Ralu::And => a & b,
        Ralu::Or => a | b,
        Ralu::Xor => a ^ b,
        Ralu::Shl => a.wrapping_shl(b & 31),
        Ralu::Shr => a.wrapping_shr(b & 31),
        Ralu::Sar => ((a as i32) >> (b & 31)) as u32,
        Ralu::Slt => u32::from((a as i32) < (b as i32)),
        Ralu::Sltu => u32::from(a < b),
        Ralu::Mul => a.wrapping_mul(b),
        Ralu::Mov => a,
        Ralu::Fma => acc.wrapping_add(a.wrapping_mul(b)),
    }
}

fn cmp_exec(cond: Cmp, a: u32, b: u32) -> bool {
    match cond {
        Cmp::Eq => a == b,
        Cmp::Ne => a != b,
        Cmp::Lt => (a as i32) < (b as i32),
        Cmp::Ge => (a as i32) >= (b as i32),
        Cmp::Ltu => a < b,
        Cmp::Geu => a >= b,
    }
}

fn imm_exec(insn: &Insn, a: u32) -> u32 {
    match insn.op {
        OP_ADDI => a.wrapping_add(insn.imm_signed() as u32),
        OP_ANDI => a & insn.imm,
        OP_ORI => a | insn.imm,
        OP_SHLI => a.wrapping_shl(insn.imm),
        OP_SLTI => u32::from((a as i32) < insn.imm_signed()),
        OP_LUI => insn.imm << 20,
        OP_LUM => a | (insn.imm << 12),
        _ => a,
    }
}
