//! Skein ISA 编码定义（P0 冻结），汇编器和黄金模型共用这一份。
//!
//! 位分配见 docs/design.md §5.3：
//!
//! ```text
//! R  : op[5:0] rd[10:6] ra[15:11] rb[20:16] pred[24:21] func[28:25] pinv[29]
//! RI : op[5:0] rd[10:6] ra[15:11] pred[19:16] imm[31:20]（没有取反位）
//! BR : op[5:0] rs[10:6] off[31:11]（21 位有符号，单位是指令字）
//! J  : op[5:0] off[31:6]（26 位有符号，单位是指令字）
//! SR : op[5:0] rd[10:6] sreg[15:11] pred[24:21] pinv[29]
//! SYS: op[5:0] func[28:25]
//! ```
//!
//! `pred` 字段 0 = 无谓词，1..8 = `@p0..@p7`。mask 指令的 `.P` 形式把谓词号放在
//! `rb` 字段（0..7）。`pinv` 为 1 表示 `@!p`（只有 R/SR 格式有这一位）。

pub const NUM_LANES: usize = 4; // 与 rtl/SK_config.vh 保持一致
pub const NUM_WARPS: usize = 4;
pub const NUM_GPR: usize = 32;
pub const NUM_PRED: usize = 8;
pub const WORD_BYTES: u32 = 4;

/// warp 生成时的完整 mask（低 NUM_LANES 位）。
pub const fn full_mask() -> u32 {
    (1 << NUM_LANES) - 1
}

// --- 主操作码（6 位）：op[5:4] = 类，op[3:0] = 类内子码 ---
//
// 类 00     R 向量执行：0000 RALU、0100-0111 CMP（bop = op[1:0]）、1000 SEL、
//                       1001 SHFL、1010 VOTE；其余预留
// 类 01     RI 立即数 ALU：ADDI/ANDI/ORI/SHLI/SLTI/LUI/LUM；其余预留
// 类 10     RI 访存：LDS/STS/LDG/STG；其余预留（字节/半字、原子）
// 类 11_0   控制流：BRZ/BRNZ/JMP；其余预留（更多条件）
// 类 11_1   warp 级 / 系统：MASK/SREAD/SYS；其余预留

// 类 00：R 向量执行
pub const OP_RALU: u32 = 0x00; // 子码 0000
pub const OP_CMP: u32 = 0x04; // 0100，bop = op[1:0] = 00（直接赋值）
pub const OP_CMPA: u32 = 0x05; // 0101，谓词与：p &= cond
pub const OP_CMPO: u32 = 0x06; // 0110，谓词或：p |= cond
pub const OP_CMPX: u32 = 0x07; // 0111，谓词异或：p ^= cond
pub const OP_SEL: u32 = 0x08; // 1000，按谓词选值，pred 字段 = 谓词号
pub const OP_SHFL: u32 = 0x09; // 1001，warp 内 lane 间传值（func 选模式）
pub const OP_VOTE: u32 = 0x0A; // 1010，warp 级谓词投票，结果写所有 lane

// 类 01：RI 立即数 ALU
pub const OP_ADDI: u32 = 0x10;
pub const OP_ANDI: u32 = 0x11;
pub const OP_ORI: u32 = 0x12;
pub const OP_SHLI: u32 = 0x13;
pub const OP_SLTI: u32 = 0x14;
pub const OP_LUI: u32 = 0x15; // rd = imm12 << 20
pub const OP_LUM: u32 = 0x16; // rd = ra | (imm12 << 12)

// 类 10：RI 访存
pub const OP_LDS: u32 = 0x20; // shared 读
pub const OP_STS: u32 = 0x21; // shared 写
pub const OP_LDG: u32 = 0x22; // global 读
pub const OP_STG: u32 = 0x23; // global 写

// 类 11_0：控制流
pub const OP_BRZ: u32 = 0x30;
pub const OP_BRNZ: u32 = 0x31;
pub const OP_JMP: u32 = 0x32;

// 类 11_1：warp 级 / 系统
pub const OP_MASK: u32 = 0x38; // mask 指令（warp 级）
pub const OP_SREAD: u32 = 0x39;
pub const OP_SYS: u32 = 0x3A; // NOP / BAR / EXIT

/// 主操作码的类（`op[5:4]`）：0 = R，1/2 = RI，3 = 控制流或 warp 级。
pub const fn op_class_bits(op: u32) -> u32 {
    (op >> 4) & 0x3
}

/// `CMP` 家族：`func` = 条件，主操作码低 2 位 = 谓词组合修饰。
pub fn is_cmp_op(op: u32) -> bool {
    matches!(op, OP_CMP | OP_CMPA | OP_CMPO | OP_CMPX)
}

/// RI 格式的操作码（类 01 立即数 ALU、类 10 访存）：`pred` 在 bits[19:16]，
/// 其余格式在 bits[24:21]。
pub const fn is_ri_op(op: u32) -> bool {
    matches!(op_class_bits(op), 1 | 2)
}

/// 立即数/访存类指令的助记符（trace 和调试用）。
pub fn ri_op_name(op: u32) -> &'static str {
    match op {
        OP_ADDI => "ADDI",
        OP_ANDI => "ANDI",
        OP_ORI => "ORI",
        OP_SHLI => "SHLI",
        OP_SLTI => "SLTI",
        OP_LUI => "LUI",
        OP_LUM => "LUM",
        OP_LDS => "LDS",
        OP_STS => "STS",
        OP_LDG => "LDG",
        OP_STG => "STG",
        _ => "?",
    }
}

macro_rules! coded_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident = $code:expr => $text:expr),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Clone, Copy, PartialEq, Eq, Debug)]
        pub enum $name { $($variant),+ }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            pub const fn code(self) -> u32 {
                match self { $($name::$variant => $code),+ }
            }

            pub const fn text(self) -> &'static str {
                match self { $($name::$variant => $text),+ }
            }

            pub fn from_code(code: u32) -> Option<$name> {
                Self::ALL.iter().copied().find(|item| item.code() == code)
            }

            pub fn from_text(text: &str) -> Option<$name> {
                Self::ALL.iter().copied().find(|item| item.text() == text)
            }
        }
    };
}

coded_enum!(
    /// R 格式 ALU 的 func（op = OP_RALU）。
    Ralu {
        Add = 0x00 => "ADD", Sub = 0x01 => "SUB", And = 0x02 => "AND", Or = 0x03 => "OR",
        Xor = 0x04 => "XOR", Shl = 0x05 => "SHL", Shr = 0x06 => "SHR", Sar = 0x07 => "SAR",
        Slt = 0x08 => "SLT", Sltu = 0x09 => "SLTU", Mul = 0x0A => "MUL", Mov = 0x0B => "MOV",
        Fma = 0x0C => "FMA",
    }
);

coded_enum!(
    /// CMP 的条件（op = OP_CMP）。
    Cmp {
        Eq = 0x00 => "EQ", Ne = 0x01 => "NE", Lt = 0x02 => "LT",
        Ge = 0x03 => "GE", Ltu = 0x04 => "LTU", Geu = 0x05 => "GEU",
    }
);

coded_enum!(
    /// CMP 的谓词组合修饰（主操作码区分）。
    Bop {
        Set = OP_CMP => "", And = OP_CMPA => "AND", Or = OP_CMPO => "OR", Xor = OP_CMPX => "XOR",
    }
);

coded_enum!(
    /// SHFL 的模式（op = OP_SHFL）。
    Shfl {
        Idx = 0x00 => "IDX", Up = 0x01 => "UP", Down = 0x02 => "DOWN", Bfly = 0x03 => "BFLY",
    }
);

coded_enum!(
    /// VOTE 的模式（op = OP_VOTE）。
    Vote { Any = 0x00 => "ANY", All = 0x01 => "ALL" }
);

coded_enum!(
    /// 指令分类，性能计数用（黄金模型和 RTL 用同一份分类对拍）。
    OpClass {
        Alu = 0x00 => "ALU", Cmp = 0x01 => "CMP", Sel = 0x02 => "SEL", Imm = 0x03 => "IMM",
        Lds = 0x04 => "LDS", Sts = 0x05 => "STS", Ldg = 0x06 => "LDG", Stg = 0x07 => "STG",
        Mask = 0x08 => "MASK", Branch = 0x09 => "BRANCH", Jump = 0x0A => "JMP",
        Sread = 0x0B => "SREAD", Sys = 0x0C => "SYS", Shfl = 0x0D => "SHFL", Vote = 0x0E => "VOTE",
    }
);

/// 主操作码 -> 指令分类；保留编码返回 `None`。
pub fn op_class(op: u32) -> Option<OpClass> {
    Some(match op {
        OP_RALU => OpClass::Alu,
        OP_CMP | OP_CMPA | OP_CMPO | OP_CMPX => OpClass::Cmp,
        OP_SEL => OpClass::Sel,
        OP_ADDI | OP_ANDI | OP_ORI | OP_SHLI | OP_SLTI | OP_LUI | OP_LUM => OpClass::Imm,
        OP_LDS => OpClass::Lds,
        OP_STS => OpClass::Sts,
        OP_LDG => OpClass::Ldg,
        OP_STG => OpClass::Stg,
        OP_MASK => OpClass::Mask,
        OP_BRZ | OP_BRNZ => OpClass::Branch,
        OP_JMP => OpClass::Jump,
        OP_SREAD => OpClass::Sread,
        OP_SYS => OpClass::Sys,
        OP_SHFL => OpClass::Shfl,
        OP_VOTE => OpClass::Vote,
        _ => return None,
    })
}

coded_enum!(
    /// mask 指令（op = OP_MASK，warp 级，不受 M 门控）。
    MaskOp {
        Msave = 0x00 => "MSAVE", Mrest = 0x01 => "MREST", Mmov = 0x02 => "MMOV",
        Mand = 0x03 => "MAND", Mandn = 0x04 => "MANDN", Mor = 0x05 => "MOR",
        Mnot = 0x06 => "MNOT", MandP = 0x07 => "MAND.P", MandnP = 0x08 => "MANDN.P",
        MorP = 0x09 => "MOR.P", MclrP = 0x0A => "MCLR.P",
        MandPm = 0x0B => "MAND.PM", MandnPm = 0x0C => "MANDN.PM", MorPm = 0x0D => "MOR.PM",
    }
);

impl MaskOp {
    /// 是否是 `.P` 形式（谓词号在 `rb` 字段；`.PM` 还会写 `M`）。
    pub const fn is_predicated(self) -> bool {
        matches!(
            self,
            MaskOp::MandP
                | MaskOp::MandnP
                | MaskOp::MorP
                | MaskOp::MandPm
                | MaskOp::MandnPm
                | MaskOp::MorPm
        )
    }

    /// `.PM`：结果同时写 `rd` 和执行 mask `M`。
    pub const fn writes_mask(self) -> bool {
        matches!(self, MaskOp::MandPm | MaskOp::MandnPm | MaskOp::MorPm)
    }
}

coded_enum!(
    /// 系统指令（op = OP_SYS）。
    Sys { Nop = 0x00 => "NOP", Bar = 0x01 => "BAR", Exit = 0x02 => "EXIT" }
);

coded_enum!(
    /// 特殊寄存器编号（SREAD）。
    Sreg {
        Tid = 0x00 => "TID", LaneId = 0x01 => "LANEID", Wid = 0x02 => "WID",
        Warpsz = 0x03 => "WARPSZ", Nwarp = 0x04 => "NWARP", Grid = 0x05 => "GRID",
        PtrA = 0x06 => "PTR_A", PtrB = 0x07 => "PTR_B", PtrC = 0x08 => "PTR_C",
        Arg0 = 0x09 => "ARG0", Arg1 = 0x0A => "ARG1", Arg2 = 0x0B => "ARG2",
        Status = 0x0C => "STATUS", Bid = 0x0D => "BID", BlockDim = 0x0E => "BLOCK_DIM",
    }
);

impl Sreg {
    /// 名字 -> 特殊寄存器：接受 `PTR_A` / `S_PTR_A`，大小写不敏感。
    pub fn from_name(name: &str) -> Option<Sreg> {
        let upper = name.trim().to_uppercase();
        let bare = upper.strip_prefix("S_").unwrap_or(&upper);
        Sreg::from_text(bare)
    }

    /// 主机能写的特殊寄存器：命令行 `--set` 和 case 的 `[sreg]` 都只允许这些。
    pub const fn writable(self) -> bool {
        matches!(
            self,
            Sreg::PtrA | Sreg::PtrB | Sreg::PtrC | Sreg::Arg0 | Sreg::Arg1 | Sreg::Arg2
        )
    }
}

coded_enum!(
    /// STATUS 错误码，非 0 表示 kernel 已经报错结束。
    Status {
        Ok = 0 => "OK",
        BadInsn = 1 => "BAD_INSN",
        Unaligned = 2 => "UNALIGNED",
        SmemOob = 3 => "SMEM_OOB",
        GmemOob = 4 => "GMEM_OOB",
        BarIncomplete = 5 => "BAR_INCOMPLETE",
        PcOob = 6 => "PC_OOB",
        BadLaunch = 7 => "BAD_LAUNCH",
    }
);

/// 谓词号 0..7 -> pred 字段值 1..8。
pub const fn pred_field(index: u32) -> u32 {
    index + 1
}

/// 谓词取反位：只有 R/SR 格式有（RI 的 bit29 属于 `imm`）。
pub const PINV_BIT: u32 = 29;

/// 谓词门控：`field` 0 = 无门控、1..8 = `@p0..@p7`，`invert` = `@!p`。
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Gate {
    pub field: u32,
    pub invert: bool,
}

impl Gate {
    pub const NONE: Gate = Gate {
        field: 0,
        invert: false,
    };

    pub const fn is_none(self) -> bool {
        self.field == 0 && !self.invert
    }
}

/// 把 `bits` 位字段按二进制补码做符号扩展。
pub const fn sext(value: u32, bits: u32) -> i32 {
    let shift = 32 - bits;
    ((value << shift) as i32) >> shift
}

// --- 编码 ---

pub fn enc_r(op: u32, rd: u32, ra: u32, rb: u32, gate: Gate, func: u32) -> u32 {
    op | (rd << 6)
        | (ra << 11)
        | (rb << 16)
        | (gate.field << 21)
        | (func << 25)
        | (u32::from(gate.invert) << PINV_BIT)
}

/// RI 格式没有取反位，`gate.invert` 必须为假（由汇编器拒绝）。
pub fn enc_ri(op: u32, rd: u32, ra: u32, gate: Gate, imm: u32) -> u32 {
    debug_assert!(!gate.invert, "RI 格式没有谓词取反位");
    op | (rd << 6) | (ra << 11) | (gate.field << 16) | (imm << 20)
}

/// `off` 是已经取过补码低位的 21 位字段。
pub fn enc_br(op: u32, rs: u32, off: u32) -> u32 {
    op | (rs << 6) | (off << 11)
}

/// `off` 是已经取过补码低位的 26 位字段。
pub fn enc_j(op: u32, off: u32) -> u32 {
    op | (off << 6)
}

pub fn enc_sr(rd: u32, sreg: u32, gate: Gate) -> u32 {
    OP_SREAD | (rd << 6) | (sreg << 11) | (gate.field << 21) | (u32::from(gate.invert) << PINV_BIT)
}

pub fn enc_sys(func: u32) -> u32 {
    OP_SYS | (func << 25)
}

// --- 译码 ---

#[derive(Clone, Copy, Debug)]
pub struct Insn {
    pub word: u32,
    pub op: u32,
    pub rd: u32,
    pub ra: u32,
    pub rb: u32,
    pub pred: u32,
    pub func: u32,
    pub imm: u32,
    pub off: u32,
}

impl Insn {
    pub fn decode(word: u32) -> Insn {
        let op = word & 0x3F;
        Insn {
            word,
            op,
            rd: (word >> 6) & 0x1F,
            ra: (word >> 11) & 0x1F,
            rb: (word >> 16) & 0x1F,
            pred: if is_ri_op(op) {
                (word >> 16) & 0xF
            } else {
                (word >> 21) & 0xF
            },
            func: (word >> 25) & 0xF,
            imm: (word >> 20) & 0xFFF,
            off: if op == OP_BRZ || op == OP_BRNZ {
                (word >> 11) & 0x1F_FFFF
            } else {
                (word >> 6) & 0x3FF_FFFF
            },
        }
    }

    /// 分支指令的 rs 落在 rd 字段（bits[10:6]）。
    pub fn rs(&self) -> u32 {
        self.rd
    }

    /// pred 字段 0 表示没有谓词门控。
    pub fn pred_index(&self) -> Option<u32> {
        if self.pred == 0 {
            None
        } else {
            Some(self.pred - 1)
        }
    }

    /// `@!p`：谓词取反。RI 格式的 bit29 属于 `imm`，所以恒为假。
    pub fn pred_inverted(&self) -> bool {
        !is_ri_op(self.op) && (self.word >> PINV_BIT) & 1 == 1
    }

    /// `CMP` 家族的谓词组合修饰。
    pub fn bop(&self) -> Option<Bop> {
        if is_cmp_op(self.op) {
            Bop::from_code(self.op)
        } else {
            None
        }
    }

    pub fn imm_signed(&self) -> i32 {
        sext(self.imm, 12)
    }

    pub fn off_signed(&self) -> i32 {
        if self.op == OP_BRZ || self.op == OP_BRNZ {
            sext(self.off, 21)
        } else {
            sext(self.off, 26)
        }
    }
}

fn signed_imm_text(imm: u32) -> String {
    format!("{}", sext(imm, 12))
}

fn mem_text(ra: u32, imm: u32) -> String {
    let offset = sext(imm, 12);
    if offset == 0 {
        format!("[r{ra}]")
    } else {
        format!("[r{ra}{offset:+}]")
    }
}

/// 把一条指令还原成可读文本（trace 和调试用）。
pub fn disasm(insn: &Insn, pc: Option<usize>) -> String {
    let gate = match insn.pred_index() {
        Some(index) if !matches!(insn.op, OP_SEL) => {
            let bang = if insn.pred_inverted() { "!" } else { "" };
            format!("@{bang}p{index} ")
        }
        _ => String::new(),
    };
    let (rd, ra, rb) = (insn.rd, insn.ra, insn.rb);
    match insn.op {
        OP_RALU => match Ralu::from_code(insn.func) {
            Some(Ralu::Mov) => format!("{gate}MOV r{rd}, r{ra}"),
            Some(op) => format!("{gate}{} r{rd}, r{ra}, r{rb}", op.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        op if is_cmp_op(op) => match (Cmp::from_code(insn.func), insn.bop()) {
            (Some(cond), Some(bop)) => {
                let suffix = if bop == Bop::Set {
                    String::new()
                } else {
                    format!(".{}", bop.text())
                };
                format!("{gate}CMP.{}{suffix} p{rd}, r{ra}, r{rb}", cond.text())
            }
            _ => format!("word {:08x}（未定义）", insn.word),
        },
        OP_SEL => match insn.pred_index() {
            Some(index) => format!("SEL r{rd}, r{ra}, r{rb}, p{index}"),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_ADDI | OP_SLTI => {
            format!(
                "{gate}{} r{rd}, r{ra}, {}",
                ri_op_name(insn.op),
                signed_imm_text(insn.imm)
            )
        }
        OP_ANDI | OP_ORI | OP_SHLI | OP_LUI | OP_LUM => {
            format!("{gate}{} r{rd}, r{ra}, {}", ri_op_name(insn.op), insn.imm)
        }
        OP_LDS | OP_LDG => {
            format!(
                "{gate}{} r{rd}, {}",
                ri_op_name(insn.op),
                mem_text(ra, insn.imm)
            )
        }
        OP_STS | OP_STG => {
            format!(
                "{gate}{} {}, r{rd}",
                ri_op_name(insn.op),
                mem_text(ra, insn.imm)
            )
        }
        OP_MASK => match MaskOp::from_code(insn.func) {
            Some(MaskOp::Msave) => format!("MSAVE r{rd}"),
            Some(MaskOp::Mrest) => format!("MREST r{ra}"),
            Some(MaskOp::MclrP) => format!("MCLR.P p{rb}"),
            Some(op) if op.is_predicated() => format!("{} r{rd}, r{ra}, p{rb}", op.text()),
            Some(MaskOp::Mand) | Some(MaskOp::Mandn) | Some(MaskOp::Mor) => {
                format!(
                    "{} r{rd}, r{ra}, r{rb}",
                    MaskOp::from_code(insn.func).unwrap().text()
                )
            }
            Some(op) => format!("{} r{rd}, r{ra}", op.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_BRZ | OP_BRNZ => {
            let name = if insn.op == OP_BRZ { "BRZ" } else { "BRNZ" };
            let target = match pc {
                Some(pc) => format!("{:04x}", (pc as i32 + 1 + insn.off_signed()) as u32),
                None => format!("{:+}", insn.off_signed()),
            };
            format!("{name} r{}, {target}", insn.rs())
        }
        OP_JMP => {
            let target = match pc {
                Some(pc) => format!("{:04x}", (pc as i32 + 1 + insn.off_signed()) as u32),
                None => format!("{:+}", insn.off_signed()),
            };
            format!("JMP {target}")
        }
        OP_SREAD => match Sreg::from_code(ra) {
            Some(sreg) => format!("{gate}SREAD r{rd}, S_{}", sreg.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_SHFL => match Shfl::from_code(insn.func) {
            Some(mode) => format!("{gate}SHFL.{} r{rd}, r{ra}, r{rb}", mode.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_VOTE => match Vote::from_code(insn.func) {
            Some(mode) => format!("VOTE.{} r{rd}, p{rb}", mode.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_SYS => match Sys::from_code(insn.func) {
            Some(op) => op.text().to_string(),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        _ => format!("word {:08x}（未定义）", insn.word),
    }
}
