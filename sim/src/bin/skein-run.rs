//! skein-run：在黄金模型里跑 IMEM 镜像。
//!
//! 选项见 `skein-run --help`。

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use skein::golden::{Config, Machine};
use skein::isa::{Sreg, Status, NUM_LANES, NUM_WARPS};

/// 在黄金模型里跑 IMEM 镜像。
#[derive(Parser)]
#[command(name = "skein-run", version, max_term_width = 100)]
struct Args {
    /// IMEM 镜像（每条指令 32 位小端）
    image: PathBuf,

    /// 打印每条指令
    #[arg(long)]
    trace: bool,

    /// 结束状态写成 JSON
    #[arg(long, value_name = "FILE")]
    dump_state: Option<PathBuf>,

    /// 打印各分类的指令条数（性能计数，见 docs/design.md §13）
    #[arg(long)]
    stats: bool,

    /// 设置特殊寄存器，可重复：--set PTR_A=0x1000
    #[arg(long = "set", value_name = "NAME=VALUE", value_parser = parse_sreg)]
    sregs: Vec<(Sreg, u32)>,

    /// warp 数
    #[arg(long, value_name = "N", default_value_t = NUM_WARPS, value_parser = parse_nwarp)]
    nwarp: usize,

    /// warpSize：每个 warp 的 lane 数
    #[arg(long, value_name = "N", default_value_t = NUM_LANES, value_parser = parse_warpsz)]
    warpsz: usize,

    /// blockDim.x：block 线程数（默认用满容量 NWARP × WARPSZ）
    #[arg(long, value_name = "N", value_parser = parse_usize)]
    bdim: Option<usize>,

    /// block 数（按 block 顺序执行）
    #[arg(long, value_name = "N", default_value_t = 1, value_parser = parse_grid)]
    grid: u32,

    /// global memory 大小（字节）
    #[arg(long, value_name = "BYTES", default_value_t = 1 << 20, value_parser = parse_usize)]
    gmem_bytes: usize,

    /// shared memory 大小（字节）
    #[arg(long, value_name = "BYTES", default_value_t = 32 * 1024, value_parser = parse_usize)]
    smem_bytes: usize,

    /// 执行步数上限（死循环保护）
    #[arg(long, value_name = "N", default_value_t = 1_000_000, value_parser = parse_usize)]
    max_steps: usize,
}

/// 十进制、0x / 0b 前缀和下划线都接受。
fn parse_number(text: &str) -> Result<i64, String> {
    let text = text.trim().replace('_', "");
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
        .map_err(|_| format!("不是合法的数字：{text}"))
}

fn parse_usize(text: &str) -> Result<usize, String> {
    let value = parse_number(text)?;
    usize::try_from(value).map_err(|_| format!("需要一个非负整数：{text}"))
}

fn parse_warpsz(text: &str) -> Result<usize, String> {
    let value = parse_usize(text)?;
    if !(1..=32).contains(&value) {
        return Err(format!("lane 数要在 1..=32：{text}"));
    }
    Ok(value)
}

fn parse_nwarp(text: &str) -> Result<usize, String> {
    let value = parse_usize(text)?;
    if !(1..=64).contains(&value) {
        return Err(format!("warp 数要在 1..=64：{text}"));
    }
    Ok(value)
}

fn parse_grid(text: &str) -> Result<u32, String> {
    let value = parse_usize(text)?;
    if !(1..=65535).contains(&value) {
        return Err(format!("block 数要在 1..=65535：{text}"));
    }
    Ok(value as u32)
}

/// `NAME=VALUE` -> (特殊寄存器, 值)。
fn parse_sreg(text: &str) -> Result<(Sreg, u32), String> {
    let (name, value) = match text.split_once('=') {
        Some(pair) => pair,
        None => return Err(format!("写法应为 NAME=VALUE：{text}")),
    };
    let name = name.trim().to_uppercase();
    let name = name.strip_prefix("S_").unwrap_or(&name).to_string();
    let sreg = match Sreg::from_text(&name) {
        Some(sreg) => sreg,
        None => return Err(format!("不认识的特殊寄存器：{name}")),
    };
    match sreg {
        Sreg::PtrA | Sreg::PtrB | Sreg::PtrC | Sreg::Arg0 | Sreg::Arg1 | Sreg::Arg2 => {}
        _ => {
            return Err(format!(
                "{} 是只读的；--set 只能设置 PTR_A/PTR_B/PTR_C/ARG0/ARG1/ARG2",
                sreg.text()
            ))
        }
    }
    let value = parse_number(value.trim())?;
    let value = u32::try_from(value).map_err(|_| format!("值超出 32 位：{text}"))?;
    Ok((sreg, value))
}

fn load_image(path: &PathBuf) -> Option<Vec<u32>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("{}: {err}", path.display());
            return None;
        }
    };
    if bytes.len() % 4 != 0 {
        eprintln!(
            "{}: 不是 4 字节对齐的镜像（{} 字节）",
            path.display(),
            bytes.len()
        );
        return None;
    }
    let words = (0..bytes.len() / 4)
        .map(|index| {
            let start = index * 4;
            u32::from_le_bytes([
                bytes[start],
                bytes[start + 1],
                bytes[start + 2],
                bytes[start + 3],
            ])
        })
        .collect();
    Some(words)
}

fn main() -> ExitCode {
    let args = Args::parse();
    let Some(image) = load_image(&args.image) else {
        return ExitCode::FAILURE;
    };
    let config = Config {
        warpsz: args.warpsz.max(1),
        nwarp: args.nwarp.max(1),
        block_dim: args.bdim,
        grid: args.grid,
        smem_bytes: args.smem_bytes.max(4),
        gmem_bytes: args.gmem_bytes.max(4),
        sregs: args.sregs,
        trace: args.trace,
        max_steps: args.max_steps as u64,
    };

    let mut machine = Machine::new(image, config);
    let status = machine.run();
    if machine.limit_hit {
        eprintln!("执行步数超过上限（死循环？）");
    }
    if let Some(path) = args.dump_state {
        if let Err(err) = std::fs::write(&path, machine.dump_state()) {
            eprintln!("{}: {err}", path.display());
            return ExitCode::FAILURE;
        }
        println!("状态 -> {}", path.display());
    }
    println!(
        "status={} steps={} barriers={}",
        status.text(),
        machine.steps,
        machine.barriers
    );
    if args.stats {
        let counts: Vec<String> = machine
            .op_counts()
            .map(|(class, value)| format!("{}={value}", class.text()))
            .collect();
        println!("ops: {}", counts.join(" "));
    }
    if status == Status::Ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
