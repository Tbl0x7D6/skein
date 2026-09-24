//! Skein ISA 编码定义（P0 冻结），汇编器和黄金模型共用这一份。
//!
//! 位分配见 docs/design.md §5.3：
//!
//! ```text
//! R  : op[5:0] rd[10:6] ra[15:11] rb[20:16] pred[24:21] func[31:25]
//! RI : op[5:0] rd[10:6] ra[15:11] pred[19:16] imm[31:20]
//! BR : op[5:0] rs[10:6] off[31:11]（21 位有符号，单位是指令字）
//! J  : op[5:0] off[31:6]（26 位有符号，单位是指令字）
//! SR : op[5:0] rd[10:6] sreg[15:11]
//! SYS: op[5:0] func[31:25]
//! ```
//!
//! `pred` 字段 0 = 无谓词，1..8 = `@p0..@p7`。mask 指令的 `.P` 形式把谓词号放在
//! `rb` 字段（0..7）。

pub const NUM_LANES: usize = 4; // 与 rtl/SK_config.vh 保持一致
pub const NUM_WARPS: usize = 4;
pub const NUM_GPR: usize = 32;
pub const NUM_PRED: usize = 8;
pub const WORD_BYTES: u32 = 4;

/// warp 生成时的完整 mask（低 NUM_LANES 位）。
pub const fn full_mask() -> u32 {
    (1 << NUM_LANES) - 1
}

// --- 主操作码（6 位）---
pub const OP_RALU: u32 = 0x01; // 算术/逻辑/移位/比较/搬移
pub const OP_CMP: u32 = 0x02; // 比较写谓词，func = 条件，rd = 谓词号
pub const OP_SEL: u32 = 0x03; // 按谓词选值，pred 字段 = 谓词号
pub const OP_ADDI: u32 = 0x04;
pub const OP_ANDI: u32 = 0x05;
pub const OP_ORI: u32 = 0x06;
pub const OP_SHLI: u32 = 0x07;
pub const OP_SLTI: u32 = 0x08;
pub const OP_LDS: u32 = 0x09; // shared 读
pub const OP_STS: u32 = 0x0A; // shared 写
pub const OP_LDG: u32 = 0x0B; // global 读
pub const OP_STG: u32 = 0x0C; // global 写
pub const OP_LUI: u32 = 0x0D; // rd = imm12 << 20
pub const OP_MASK: u32 = 0x0E; // mask 指令（warp 级）
pub const OP_BRZ: u32 = 0x0F;
pub const OP_BRNZ: u32 = 0x10;
pub const OP_JMP: u32 = 0x11;
pub const OP_SREAD: u32 = 0x12;
pub const OP_SYS: u32 = 0x13; // NOP / BAR / EXIT
pub const OP_LUM: u32 = 0x14; // rd = ra | (imm12 << 12)

/// RI 格式的操作码：`pred` 在 bits[19:16]，其余格式在 bits[24:21]。
pub fn is_ri_op(op: u32) -> bool {
    matches!(
        op,
        OP_ADDI
            | OP_ANDI
            | OP_ORI
            | OP_SHLI
            | OP_SLTI
            | OP_LUI
            | OP_LUM
            | OP_LDS
            | OP_STS
            | OP_LDG
            | OP_STG
    )
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
    /// mask 指令（op = OP_MASK，warp 级，不受 M 门控）。
    MaskOp {
        Msave = 0x00 => "MSAVE", Mrest = 0x01 => "MREST", Mmov = 0x02 => "MMOV",
        Mand = 0x03 => "MAND", Mandn = 0x04 => "MANDN", Mor = 0x05 => "MOR",
        Mnot = 0x06 => "MNOT", MandP = 0x07 => "MAND.P", MandnP = 0x08 => "MANDN.P",
        MorP = 0x09 => "MOR.P", MclrP = 0x0A => "MCLR.P",
    }
);

impl MaskOp {
    /// 是否是 `.P` 形式（谓词号在 rb 字段）。
    pub const fn is_predicated(self) -> bool {
        matches!(self, MaskOp::MandP | MaskOp::MandnP | MaskOp::MorP)
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
        Ntid = 0x03 => "NTID", Nwarp = 0x04 => "NWARP", Grid = 0x05 => "GRID",
        PtrA = 0x06 => "PTR_A", PtrB = 0x07 => "PTR_B", PtrC = 0x08 => "PTR_C",
        Arg0 = 0x09 => "ARG0", Arg1 = 0x0A => "ARG1", Arg2 = 0x0B => "ARG2",
        Status = 0x0C => "STATUS",
    }
);

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
    }
);

/// 谓词号 0..7 -> pred 字段值 1..8。
pub const fn pred_field(index: u32) -> u32 {
    index + 1
}

/// 把 `bits` 位字段按二进制补码做符号扩展。
pub const fn sext(value: u32, bits: u32) -> i32 {
    let shift = 32 - bits;
    ((value << shift) as i32) >> shift
}

// --- 编码 ---

pub fn enc_r(op: u32, rd: u32, ra: u32, rb: u32, pred: u32, func: u32) -> u32 {
    op | (rd << 6) | (ra << 11) | (rb << 16) | (pred << 21) | (func << 25)
}

pub fn enc_ri(op: u32, rd: u32, ra: u32, pred: u32, imm: u32) -> u32 {
    op | (rd << 6) | (ra << 11) | (pred << 16) | (imm << 20)
}

/// `off` 是已经取过补码低位的 21 位字段。
pub fn enc_br(op: u32, rs: u32, off: u32) -> u32 {
    op | (rs << 6) | (off << 11)
}

/// `off` 是已经取过补码低位的 26 位字段。
pub fn enc_j(op: u32, off: u32) -> u32 {
    op | (off << 6)
}

pub fn enc_sread(rd: u32, sreg: u32) -> u32 {
    OP_SREAD | (rd << 6) | (sreg << 11)
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
            func: (word >> 25) & 0x7F,
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
        Some(index) if !matches!(insn.op, OP_SEL) => format!("@p{index} "),
        _ => String::new(),
    };
    let (rd, ra, rb) = (insn.rd, insn.ra, insn.rb);
    match insn.op {
        OP_RALU => match Ralu::from_code(insn.func) {
            Some(Ralu::Mov) => format!("{gate}MOV r{rd}, r{ra}"),
            Some(op) => format!("{gate}{} r{rd}, r{ra}, r{rb}", op.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_CMP => match Cmp::from_code(insn.func) {
            Some(cond) => format!("CMP.{} p{rd}, r{ra}, r{rb}", cond.text()),
            None => format!("word {:08x}（未定义）", insn.word),
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
            Some(sreg) => format!("SREAD r{rd}, S_{}", sreg.text()),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        OP_SYS => match Sys::from_code(insn.func) {
            Some(op) => op.text().to_string(),
            None => format!("word {:08x}（未定义）", insn.word),
        },
        _ => format!("word {:08x}（未定义）", insn.word),
    }
}
