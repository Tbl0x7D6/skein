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
    pub ntid: usize,
    pub nwarp: usize,
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
            ntid: NUM_LANES,
            nwarp: NUM_WARPS,
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
    /// 模拟器的死循环保护被触发（不是硬件状态）。
    pub limit_hit: bool,
    ntid: usize,
    nwarp: usize,
    grid: u32,
    smem: Vec<u8>,
    gmem: Vec<u8>,
    sregs: Vec<(Sreg, u32)>,
    trace: bool,
    max_steps: u64,
}

impl Machine {
    pub fn new(imem: Vec<u32>, config: Config) -> Machine {
        // warp 的完整 mask 由 ntid 决定（32 位是上限）
        let full = if config.ntid >= 32 {
            u32::MAX
        } else {
            (1u32 << config.ntid) - 1
        };
        let warps = (0..config.nwarp)
            .map(|wid| Warp {
                wid,
                pc: 0,
                m: full,
                full,
                gpr: vec![[0; NUM_GPR]; config.ntid],
                pred: vec![[false; NUM_PRED]; config.ntid],
                state: WarpState::Run,
            })
            .collect();
        Machine {
            imem,
            warps,
            status: Status::Ok,
            steps: 0,
            barriers: 0,
            limit_hit: false,
            ntid: config.ntid,
            nwarp: config.nwarp,
            grid: config.grid,
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

    // --- 执行 ---

    pub fn run(&mut self) -> Status {
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
        self.status
    }

    fn step(&mut self, wid: usize) {
        if self.warps[wid].pc >= self.imem.len() {
            self.fail(Status::PcOob);
            return;
        }
        let pc = self.warps[wid].pc;
        let insn = Insn::decode(self.imem[pc]);
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
                width = self.ntid
            );
        }
        self.execute(wid, pc, &insn);
    }

    fn fail(&mut self, status: Status) {
        self.status = status;
        for warp in &mut self.warps {
            warp.state = WarpState::Done;
        }
    }

    /// 受 `M` 和 `@p` 门控的活跃 lane；`SEL` 的 pred 字段是操作数，不是门控。
    fn lanes(&self, wid: usize, insn: &Insn, gate: bool) -> Vec<usize> {
        let index = if gate { insn.pred_index() } else { None };
        let warp = &self.warps[wid];
        (0..self.ntid)
            .filter(|&lane| (warp.m >> lane) & 1 == 1)
            .filter(|&lane| match index {
                Some(index) => warp.pred[lane][index as usize],
                None => true,
            })
            .collect()
    }

    /// 每 lane 的谓词拼成一个 mask 值。
    fn pred_word(&self, wid: usize, index: u32) -> u32 {
        let mut word = 0;
        for lane in 0..self.ntid {
            if self.warps[wid].pred[lane][index as usize] {
                word |= 1 << lane;
            }
        }
        word
    }

    /// 没设置过的参数寄存器读出 0（对应 AXI-Lite 控制寄存器的复位值）。
    fn read_sreg(&self, wid: usize, lane: usize, sreg: Sreg) -> u32 {
        match sreg {
            Sreg::Tid => (self.warps[wid].wid * self.ntid + lane) as u32,
            Sreg::LaneId => lane as u32,
            Sreg::Wid => self.warps[wid].wid as u32,
            Sreg::Ntid => self.ntid as u32,
            Sreg::Nwarp => self.nwarp as u32,
            Sreg::Grid => self.grid,
            Sreg::Status => self.status.code(),
            other => self
                .sregs
                .iter()
                .find(|(name, _)| *name == other)
                .map(|(_, value)| *value)
                .unwrap_or(0),
        }
    }

    fn execute(&mut self, wid: usize, pc: usize, insn: &Insn) {
        match insn.op {
            OP_RALU => {
                let Some(op) = Ralu::from_code(insn.func) else {
                    return self.fail(Status::BadInsn);
                };
                for lane in self.lanes(wid, insn, true) {
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    let b = self.warps[wid].gpr[lane][insn.rb as usize];
                    self.warps[wid].gpr[lane][insn.rd as usize] = ralu_exec(op, a, b);
                }
            }
            OP_CMP => {
                let Some(cond) = Cmp::from_code(insn.func) else {
                    return self.fail(Status::BadInsn);
                };
                if insn.rd as usize >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                for lane in self.lanes(wid, insn, true) {
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    let b = self.warps[wid].gpr[lane][insn.rb as usize];
                    self.warps[wid].pred[lane][insn.rd as usize] = cmp_exec(cond, a, b);
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
                    self.warps[wid].gpr[lane][insn.rd as usize] = value;
                }
            }
            OP_ADDI | OP_ANDI | OP_ORI | OP_SHLI | OP_SLTI | OP_LUI | OP_LUM => {
                for lane in self.lanes(wid, insn, true) {
                    let a = self.warps[wid].gpr[lane][insn.ra as usize];
                    self.warps[wid].gpr[lane][insn.rd as usize] = imm_exec(insn, a);
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
                    self.warps[wid].gpr[lane][insn.rd as usize] = self.read_word(space, addr);
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
            OP_MASK => self.mask_op(wid, insn),
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
                    self.warps[wid].gpr[lane][insn.rd as usize] = value;
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

    fn mask_op(&mut self, wid: usize, insn: &Insn) {
        let Some(op) = MaskOp::from_code(insn.func) else {
            return self.fail(Status::BadInsn);
        };
        let full = self.warps[wid].full;
        let (rd, ra, rb) = (insn.rd as usize, insn.ra as usize, insn.rb as usize);
        let value = match op {
            MaskOp::Msave => self.warps[wid].m,
            MaskOp::Mrest => {
                self.warps[wid].m = self.warps[wid].gpr[0][ra] & full;
                return;
            }
            MaskOp::MclrP => {
                if rb >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                self.warps[wid].m = self.warps[wid].m & !self.pred_word(wid, rb as u32) & full;
                return;
            }
            MaskOp::Mmov => self.warps[wid].gpr[0][ra],
            MaskOp::Mnot => !self.warps[wid].gpr[0][ra],
            MaskOp::Mand => self.warps[wid].gpr[0][ra] & self.warps[wid].gpr[0][rb],
            MaskOp::Mandn => self.warps[wid].gpr[0][ra] & !self.warps[wid].gpr[0][rb],
            MaskOp::Mor => self.warps[wid].gpr[0][ra] | self.warps[wid].gpr[0][rb],
            MaskOp::MandP | MaskOp::MandnP | MaskOp::MorP => {
                if rb >= NUM_PRED {
                    return self.fail(Status::BadInsn);
                }
                let pred = self.pred_word(wid, rb as u32);
                let source = self.warps[wid].gpr[0][ra];
                let m = self.warps[wid].m;
                match op {
                    MaskOp::MandP => source & pred & m,
                    MaskOp::MandnP => source & !pred & m,
                    _ => (source | pred) & m,
                }
            }
        } & full;
        // mask 指令是 warp 级操作，不受 M 门控
        for lane in 0..self.ntid {
            self.warps[wid].gpr[lane][rd] = value;
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
        out.push_str(&format!("  \"steps\": {},\n", self.steps));
        out.push_str(&format!("  \"barriers\": {},\n", self.barriers));
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

fn ralu_exec(op: Ralu, a: u32, b: u32) -> u32 {
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
