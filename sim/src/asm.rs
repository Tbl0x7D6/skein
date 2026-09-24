//! Skein 汇编器：一行一条指令，翻译成 IMEM 镜像。
//!
//! 只做三件事：去掉注释、记下标签、把指令编码成 32 位字。控制流和掩码序列是
//! kernel 自己写的——`MSAVE`/`MREST`/`MAND.P`/`MCLR.P`/`BRZ` 都是普通指令，
//! 写法模板见 docs/design.md §6，完整例子见 sim/kernels/vecadd.s。
//!
//! 唯一的伪指令是 `LI rd, imm`：展开成 1–3 条 `ADDI`/`LUI`/`LUM`/`ORI`。

use std::collections::BTreeMap;
use std::fmt;

use crate::isa::*;

#[derive(Clone, Debug)]
pub struct AsmError {
    pub line: usize,
    pub msg: String,
}

impl AsmError {
    fn new(line: usize, msg: impl Into<String>) -> Self {
        AsmError {
            line,
            msg: msg.into(),
        }
    }
}

impl fmt::Display for AsmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "第 {} 行：{}", self.line, self.msg)
    }
}

impl std::error::Error for AsmError {}

/// 汇编结果：IMEM 镜像（每个元素一条指令）和标签地址（指令下标）。
pub struct Output {
    pub words: Vec<u32>,
    pub labels: BTreeMap<String, usize>,
}

pub fn assemble(src: &str) -> Result<Output, AsmError> {
    let mut labels = BTreeMap::new();
    let mut program: Vec<(usize, String)> = Vec::new(); // （源文件行号，指令文本）

    for (index, raw) in src.lines().enumerate() {
        let line = index + 1;
        let text = strip_comment(raw).trim();
        let (label, rest) = split_label(text);
        if let Some(name) = label {
            if labels.insert(name.clone(), program.len()).is_some() {
                return Err(AsmError::new(line, format!("标签 {name} 重复定义")));
            }
        }
        if !rest.is_empty() {
            push_line(rest, line, &mut program)?;
        }
    }

    let mut words = Vec::with_capacity(program.len());
    for (index, (line, text)) in program.iter().enumerate() {
        words.push(encode(text, &labels, index, *line)?);
    }
    Ok(Output { words, labels })
}

fn strip_comment(text: &str) -> &str {
    match text.find([';', '#']) {
        Some(end) => &text[..end],
        None => text,
    }
}

/// `名字: 指令` 拆成（标签, 剩下的部分）。
fn split_label(text: &str) -> (Option<String>, &str) {
    if let Some(position) = text.find(':') {
        let (head, rest) = text.split_at(position);
        let name = head.trim();
        if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return (Some(name.to_string()), rest[1..].trim());
        }
    }
    (None, text)
}

/// `LI rd, imm` 展开成 1–3 条指令；其他行原样收下。
fn push_line(text: &str, line: usize, program: &mut Vec<(usize, String)>) -> Result<(), AsmError> {
    let normalized = text.replace(',', " ");
    let tokens: Vec<&str> = normalized.split_whitespace().collect();
    if !tokens
        .first()
        .is_some_and(|token| token.eq_ignore_ascii_case("LI"))
    {
        program.push((line, text.to_string()));
        return Ok(());
    }
    if tokens.len() != 3 {
        return Err(AsmError::new(line, "LI 用法：LI rd, imm"));
    }
    let (rd, text_imm) = (tokens[1], tokens[2]);
    let value = parse_imm(text_imm, line)?;
    if !(-(1i64 << 31)..=(1i64 << 32) - 1).contains(&value) {
        return Err(AsmError::new(
            line,
            format!("LI 的立即数超出 32 位：{text_imm}"),
        ));
    }
    let imm = value as u32;
    if imm <= 0x7FF || imm >= 0xFFFF_F800 {
        program.push((line, format!("ADDI {rd}, r0, {}", imm as i32)));
        return Ok(());
    }
    // 三段拼：LUI 放 bits31:20，LUM 放 bits23:12，ORI 放 bits11:0
    let mut steps: Vec<(&str, u32)> = Vec::new();
    if imm >> 20 != 0 {
        steps.push(("LUI", imm >> 20));
    }
    if (imm >> 12) & 0xFF != 0 {
        steps.push(("LUM", (imm >> 12) & 0xFF));
    }
    if imm & 0xFFF != 0 {
        steps.push(("ORI", imm & 0xFFF));
    }
    for (step, (mnem, part)) in steps.iter().enumerate() {
        let source = if step == 0 { "r0" } else { rd };
        program.push((line, format!("{mnem} {rd}, {source}, {part}")));
    }
    Ok(())
}

// --------------------------------------------------------------------------
// 编码：助记符 + 操作数 -> 32 位指令字
// --------------------------------------------------------------------------

fn encode(
    text: &str,
    labels: &BTreeMap<String, usize>,
    index: usize,
    line: usize,
) -> Result<u32, AsmError> {
    let normalized = text.replace(',', " ");
    let tokens: Vec<&str> = normalized.split_whitespace().collect();
    if tokens.is_empty() {
        return Err(AsmError::new(line, "空指令"));
    }
    let mut position = 0;
    let mut gate = 0;
    if tokens[0].starts_with('@') {
        gate = pred_field(parse_pred(tokens[0].trim_start_matches('@'), line)?);
        position += 1;
    }
    if position >= tokens.len() {
        return Err(AsmError::new(line, "谓词后面缺少指令"));
    }
    let mnem = tokens[position].to_uppercase();
    encode_insn(&mnem, &tokens[position + 1..], gate, labels, index, line)
}

fn encode_insn(
    mnem: &str,
    args: &[&str],
    gate: u32,
    labels: &BTreeMap<String, usize>,
    index: usize,
    line: usize,
) -> Result<u32, AsmError> {
    if mnem == "MOV" {
        let (rd, ra) = expect2(args, mnem, line)?;
        return Ok(enc_r(
            OP_RALU,
            parse_reg(rd, line)?,
            parse_reg(ra, line)?,
            0,
            gate,
            Ralu::Mov.code(),
        ));
    }
    if let Some(op) = Ralu::from_text(mnem) {
        let (rd, ra, rb) = expect3(args, mnem, line)?;
        return Ok(enc_r(
            OP_RALU,
            parse_reg(rd, line)?,
            parse_reg(ra, line)?,
            parse_reg(rb, line)?,
            gate,
            op.code(),
        ));
    }
    if let Some(cond) = mnem.strip_prefix("CMP.").and_then(Cmp::from_text) {
        let (pd, ra, rb) = expect3(args, mnem, line)?;
        return Ok(enc_r(
            OP_CMP,
            parse_pred(pd, line)?,
            parse_reg(ra, line)?,
            parse_reg(rb, line)?,
            0,
            cond.code(),
        ));
    }
    if mnem == "SEL" {
        if args.len() != 4 {
            return Err(AsmError::new(
                line,
                format!("SEL 需要 4 个操作数，实际给了 {}", args.len()),
            ));
        }
        return Ok(enc_r(
            OP_SEL,
            parse_reg(args[0], line)?,
            parse_reg(args[1], line)?,
            parse_reg(args[2], line)?,
            pred_field(parse_pred(args[3], line)?),
            0,
        ));
    }
    if let Some(op) = ri_opcode(mnem) {
        match mnem {
            "ADDI" | "SLTI" => {
                let (rd, ra, imm) = expect3(args, mnem, line)?;
                let imm = fit(
                    parse_imm(imm, line)?,
                    -2048,
                    2047,
                    "12 位有符号立即数",
                    line,
                )?;
                return Ok(enc_ri(
                    op,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    gate,
                    imm,
                ));
            }
            "ANDI" | "ORI" => {
                let (rd, ra, imm) = expect3(args, mnem, line)?;
                let imm = fit(parse_imm(imm, line)?, -2048, 4095, "12 位立即数", line)?;
                return Ok(enc_ri(
                    op,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    gate,
                    imm,
                ));
            }
            "SHLI" => {
                let (rd, ra, imm) = expect3(args, mnem, line)?;
                let imm = fit(parse_imm(imm, line)?, 0, 31, "移位量", line)?;
                return Ok(enc_ri(
                    op,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    gate,
                    imm,
                ));
            }
            "LUI" | "LUM" => {
                let (rd, ra, imm) = expect3(args, mnem, line)?;
                let imm = fit(parse_imm(imm, line)?, 0, 4095, "12 位立即数", line)?;
                return Ok(enc_ri(
                    op,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    gate,
                    imm,
                ));
            }
            "LDS" | "LDG" => {
                let (rd, mem) = expect2(args, mnem, line)?;
                let (base, offset) = parse_mem(mem, line)?;
                let imm = fit(offset, -2048, 2047, "访存偏移", line)?;
                return Ok(enc_ri(op, parse_reg(rd, line)?, base, gate, imm));
            }
            "STS" | "STG" => {
                let (mem, rs) = expect2(args, mnem, line)?;
                let (base, offset) = parse_mem(mem, line)?;
                let imm = fit(offset, -2048, 2047, "访存偏移", line)?;
                return Ok(enc_ri(op, parse_reg(rs, line)?, base, gate, imm));
            }
            _ => {}
        }
    }
    if let Some(op) = MaskOp::from_text(mnem) {
        return match op {
            MaskOp::Msave => {
                let (rd,) = expect1(args, mnem, line)?;
                Ok(enc_r(OP_MASK, parse_reg(rd, line)?, 0, 0, 0, op.code()))
            }
            MaskOp::Mrest => {
                let (ra,) = expect1(args, mnem, line)?;
                Ok(enc_r(OP_MASK, 0, parse_reg(ra, line)?, 0, 0, op.code()))
            }
            MaskOp::MclrP => {
                let (pd,) = expect1(args, mnem, line)?;
                Ok(enc_r(OP_MASK, 0, 0, parse_pred(pd, line)?, 0, op.code()))
            }
            op if op.is_predicated() => {
                let (rd, ra, pd) = expect3(args, mnem, line)?;
                Ok(enc_r(
                    OP_MASK,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    parse_pred(pd, line)?,
                    0,
                    op.code(),
                ))
            }
            MaskOp::Mand | MaskOp::Mandn | MaskOp::Mor => {
                let (rd, ra, rb) = expect3(args, mnem, line)?;
                Ok(enc_r(
                    OP_MASK,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    parse_reg(rb, line)?,
                    0,
                    op.code(),
                ))
            }
            _ => {
                let (rd, ra) = expect2(args, mnem, line)?;
                Ok(enc_r(
                    OP_MASK,
                    parse_reg(rd, line)?,
                    parse_reg(ra, line)?,
                    0,
                    0,
                    op.code(),
                ))
            }
        };
    }
    match mnem {
        "BRZ" | "BRNZ" => {
            let (rs, target) = expect2(args, mnem, line)?;
            let offset = target_offset(target, labels, index, line, 21)?;
            let op = if mnem == "BRZ" { OP_BRZ } else { OP_BRNZ };
            return Ok(enc_br(op, parse_reg(rs, line)?, offset));
        }
        "JMP" => {
            let (target,) = expect1(args, mnem, line)?;
            let offset = target_offset(target, labels, index, line, 26)?;
            return Ok(enc_j(OP_JMP, offset));
        }
        "SREAD" => {
            let (rd, sreg) = expect2(args, mnem, line)?;
            let name = sreg.to_uppercase();
            let name = name.strip_prefix("S_").unwrap_or(&name).to_string();
            let sreg = Sreg::from_text(&name)
                .ok_or_else(|| AsmError::new(line, format!("不认识的特殊寄存器：{sreg}")))?;
            return Ok(enc_sread(parse_reg(rd, line)?, sreg.code()));
        }
        _ => {}
    }
    if let Some(op) = Sys::from_text(mnem) {
        if !args.is_empty() {
            return Err(AsmError::new(line, format!("{mnem} 不需要操作数")));
        }
        return Ok(enc_sys(op.code()));
    }
    Err(AsmError::new(line, format!("不认识的指令：{mnem}")))
}

fn ri_opcode(mnem: &str) -> Option<u32> {
    Some(match mnem {
        "ADDI" => OP_ADDI,
        "ANDI" => OP_ANDI,
        "ORI" => OP_ORI,
        "SHLI" => OP_SHLI,
        "SLTI" => OP_SLTI,
        "LUI" => OP_LUI,
        "LUM" => OP_LUM,
        "LDS" => OP_LDS,
        "STS" => OP_STS,
        "LDG" => OP_LDG,
        "STG" => OP_STG,
        _ => return None,
    })
}

fn expect1<'a>(args: &[&'a str], mnem: &str, line: usize) -> Result<(&'a str,), AsmError> {
    match args {
        [a] => Ok((*a,)),
        _ => Err(AsmError::new(
            line,
            format!("{mnem} 需要 1 个操作数，实际给了 {}", args.len()),
        )),
    }
}

fn expect2<'a>(args: &[&'a str], mnem: &str, line: usize) -> Result<(&'a str, &'a str), AsmError> {
    match args {
        [a, b] => Ok((*a, *b)),
        _ => Err(AsmError::new(
            line,
            format!("{mnem} 需要 2 个操作数，实际给了 {}", args.len()),
        )),
    }
}

fn expect3<'a>(
    args: &[&'a str],
    mnem: &str,
    line: usize,
) -> Result<(&'a str, &'a str, &'a str), AsmError> {
    match args {
        [a, b, c] => Ok((*a, *b, *c)),
        _ => Err(AsmError::new(
            line,
            format!("{mnem} 需要 3 个操作数，实际给了 {}", args.len()),
        )),
    }
}

fn parse_reg(token: &str, line: usize) -> Result<u32, AsmError> {
    let name = token.trim().to_lowercase();
    let number = name
        .strip_prefix('r')
        .and_then(|rest| rest.parse::<u32>().ok())
        .filter(|n| (*n as usize) < NUM_GPR)
        .ok_or_else(|| {
            AsmError::new(
                line,
                format!("寄存器写法应为 r0..r{}：{token}", NUM_GPR - 1),
            )
        })?;
    Ok(number)
}

fn parse_pred(token: &str, line: usize) -> Result<u32, AsmError> {
    let name = token.trim().to_lowercase();
    let number = name
        .strip_prefix('p')
        .and_then(|rest| rest.parse::<u32>().ok())
        .filter(|n| (*n as usize) < NUM_PRED)
        .ok_or_else(|| {
            AsmError::new(line, format!("谓词写法应为 p0..p{}：{token}", NUM_PRED - 1))
        })?;
    Ok(number)
}

fn parse_imm(token: &str, line: usize) -> Result<i64, AsmError> {
    let text = token.trim().replace('_', "");
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest.to_string()),
        None => (false, text.trim_start_matches('+').to_string()),
    };
    let value = if let Some(hex) = digits
        .strip_prefix("0x")
        .or_else(|| digits.strip_prefix("0X"))
    {
        i64::from_str_radix(hex, 16)
    } else if let Some(bin) = digits
        .strip_prefix("0b")
        .or_else(|| digits.strip_prefix("0B"))
    {
        i64::from_str_radix(bin, 2)
    } else {
        digits.parse::<i64>()
    };
    value
        .map(|value| if negative { -value } else { value })
        .map_err(|_| AsmError::new(line, format!("不是合法的立即数：{token}")))
}

fn parse_mem(token: &str, line: usize) -> Result<(u32, i64), AsmError> {
    let inner = token
        .trim()
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .ok_or_else(|| {
            AsmError::new(
                line,
                format!("访存操作数写法应为 [r1+4] / [r1-8] / [r1]：{token}"),
            )
        })?;
    let split = inner
        .char_indices()
        .skip(1)
        .find(|(_, ch)| *ch == '+' || *ch == '-')
        .map(|(index, _)| index);
    match split {
        Some(index) => {
            let base = parse_reg(&inner[..index], line)?;
            let offset = parse_imm(&inner[index..], line)?;
            Ok((base, offset))
        }
        None => Ok((parse_reg(inner, line)?, 0)),
    }
}

fn fit(value: i64, lo: i64, hi: i64, what: &str, line: usize) -> Result<u32, AsmError> {
    if value < lo || value > hi {
        return Err(AsmError::new(
            line,
            format!("{what} 超出范围 [{lo}, {hi}]：{value}"),
        ));
    }
    Ok((value as u32) & 0xFFF)
}

fn target_offset(
    target: &str,
    labels: &BTreeMap<String, usize>,
    index: usize,
    line: usize,
    bits: u32,
) -> Result<u32, AsmError> {
    let destination = labels
        .get(target)
        .ok_or_else(|| AsmError::new(line, format!("标签未定义：{target}")))?;
    let offset = *destination as i64 - (index as i64 + 1);
    let limit = 1i64 << (bits - 1);
    if offset < -limit || offset >= limit {
        return Err(AsmError::new(
            line,
            format!("分支/跳转超出范围（{bits} 位偏移）：{offset} 条指令"),
        ));
    }
    Ok((offset as u32) & ((1 << bits) - 1))
}
