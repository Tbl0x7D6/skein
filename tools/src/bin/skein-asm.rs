//! skein-asm：把结构化汇编汇编成 IMEM 二进制镜像（每字 32 位小端）。
//!
//! 选项见 `skein-asm --help`。

use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use skein::asm;

/// 把结构化汇编汇编成 IMEM 镜像。
#[derive(Parser)]
#[command(name = "skein-asm", version, max_term_width = 100)]
struct Args {
    /// 汇编源文件（.s）
    input: PathBuf,

    /// 输出镜像路径；默认与输入同名，扩展名换成 .bin
    #[arg(short, long, value_name = "FILE")]
    output: Option<PathBuf>,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let output = args
        .output
        .clone()
        .unwrap_or_else(|| args.input.with_extension("bin"));

    let source = match std::fs::read_to_string(&args.input) {
        Ok(source) => source,
        Err(err) => {
            eprintln!("{}: {err}", args.input.display());
            return ExitCode::FAILURE;
        }
    };
    let result = match asm::assemble(&source) {
        Ok(result) => result,
        Err(err) => {
            eprintln!("{}:{}: error: {}", args.input.display(), err.line, err.msg);
            return ExitCode::FAILURE;
        }
    };
    let mut bytes = Vec::with_capacity(result.words.len() * 4);
    for word in &result.words {
        bytes.extend_from_slice(&word.to_le_bytes());
    }
    if let Err(err) = std::fs::write(&output, &bytes) {
        eprintln!("{}: {err}", output.display());
        return ExitCode::FAILURE;
    }
    println!(
        "{} -> {}（{} 条指令，{} 字节）",
        args.input.display(),
        output.display(),
        result.words.len(),
        bytes.len()
    );
    ExitCode::SUCCESS
}
