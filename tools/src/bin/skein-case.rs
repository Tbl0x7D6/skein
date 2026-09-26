//! skein-case：把 `cases/*.toml` 同时送进黄金模型和 RTL testbench，逐项比对。
//!
//! 黄金模型在进程里跑；RTL 由 Verilator 的 `tb_core` 跑，它只负责喂输入、dump 状态，
//! 比对逻辑都在这里。形状不支持的 case（多 warp / 多 lane）只跑黄金模型，报 SKIP。
//!
//! 用法见 `skein-case --help`；`make rtl-sim` 会先建好模型再调它。

use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};

use clap::Parser;
use serde::Deserialize;

use skein::case::Case;
use skein::golden::Machine;
use skein::isa::Status;

/// 一个 case 最多列几条差异，剩下的只报数量
const MAX_PROBLEMS: usize = 10;

#[derive(Parser)]
#[command(name = "skein-case", version, max_term_width = 100)]
struct Args {
    /// case 文件或目录，可以给多个；默认 cases/
    #[arg(value_name = "CASE", default_value = "cases")]
    paths: Vec<PathBuf>,

    /// 只跑名字里含这个子串的 case
    #[arg(long, value_name = "SUBSTR")]
    filter: Option<String>,

    /// RTL testbench（Verilator 模型）；不给就只跑黄金模型
    #[arg(long, value_name = "FILE")]
    rtl_tb: Option<PathBuf>,

    /// 临时文件目录：镜像、初态和 RTL 的状态 dump 都放这里
    #[arg(long, value_name = "DIR", default_value = "build/cases")]
    work_dir: PathBuf,

    /// 把 RTL 波形（FST）写到这个文件；一次只跑一个 case，
    /// 而且要配带波形的模型（--rtl-tb 指向 make tb-trace 出来的 tb_core_trace）
    #[arg(long, value_name = "FILE")]
    wave: Option<PathBuf>,
}

/// `tb_core --dump-state` 写出来的状态快照。
#[derive(Deserialize, Debug)]
struct Snapshot {
    status: u32,
    #[serde(default)]
    cycles: u64,
    warps: Vec<SnapshotWarp>,
    #[serde(default)]
    mem: Vec<SnapshotWindow>,
}

#[derive(Deserialize, Debug)]
struct SnapshotWarp {
    pc: u32,
    m: u32,
    gpr: Vec<Vec<u32>>,
    pred: Vec<Vec<u8>>,
}

#[derive(Deserialize, Debug)]
struct SnapshotWindow {
    space: String,
    addr: u32,
    words: Vec<u32>,
}

enum Outcome {
    Pass { cycles: u64, wave: Option<PathBuf> },
    Skip { reason: String },
}

fn main() -> ExitCode {
    let args = Args::parse();
    if let Some(tb) = &args.rtl_tb {
        if !tb.is_file() {
            eprintln!(
                "找不到 RTL testbench：{}（先 make rtl-sim 或者给出正确路径）",
                tb.display()
            );
            return ExitCode::FAILURE;
        }
    }
    let cases = match collect(&args.paths, args.filter.as_deref()) {
        Ok(cases) => cases,
        Err(err) => {
            eprintln!("{err}");
            return ExitCode::FAILURE;
        }
    };
    if cases.is_empty() {
        eprintln!("没有匹配的 case");
        return ExitCode::FAILURE;
    }
    if args.wave.is_some() && args.rtl_tb.is_none() {
        eprintln!("--wave 需要 --rtl-tb 指向带波形的模型（make tb-trace 出来的 tb_core_trace）");
        return ExitCode::FAILURE;
    }
    if args.wave.is_some() && cases.len() != 1 {
        eprintln!("--wave 一次只能跑一个 case，现在匹配到 {} 个", cases.len());
        return ExitCode::FAILURE;
    }

    let (mut passed, mut skipped, mut failed) = (0usize, 0usize, 0usize);
    let width = cases
        .iter()
        .map(|case| case.name.chars().count())
        .max()
        .unwrap_or(0);
    for case in &cases {
        match run(case, &args) {
            Ok(Outcome::Pass { cycles, wave }) => {
                passed += 1;
                match wave {
                    Some(path) => println!(
                        "{:<width$} PASS  cycles={cycles}  wave={}",
                        case.name,
                        path.display()
                    ),
                    None => println!("{:<width$} PASS  cycles={cycles}", case.name),
                }
            }
            Ok(Outcome::Skip { reason }) => {
                skipped += 1;
                println!("{:<width$} SKIP  {reason}", case.name);
            }
            Err(problems) => {
                failed += 1;
                println!("{:<width$} FAIL", case.name);
                for problem in problems.iter().take(MAX_PROBLEMS) {
                    println!("    {problem}");
                }
                if problems.len() > MAX_PROBLEMS {
                    println!("    ……还有 {} 条差异", problems.len() - MAX_PROBLEMS);
                }
            }
        }
    }
    println!("合计：{passed} PASS，{skipped} SKIP，{failed} FAIL");
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// 展开命令行给的路径：文件直接用，目录取里面的 `*.toml`。
fn collect(paths: &[PathBuf], filter: Option<&str>) -> Result<Vec<Case>, String> {
    let mut cases = Vec::new();
    for path in paths {
        if path.is_dir() {
            cases.extend(Case::load_dir(path)?);
        } else {
            cases.push(Case::load(path)?);
        }
    }
    if let Some(filter) = filter {
        cases.retain(|case| case.name.contains(filter));
    }
    cases.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(cases)
}

fn run(case: &Case, args: &Args) -> Result<Outcome, Vec<String>> {
    let mut machine = case.machine(false).map_err(|err| vec![err])?;
    machine.run();
    let golden_problems = case.check_golden(&machine);
    if !golden_problems.is_empty() {
        return Err(golden_problems);
    }
    if let Err(reason) = case.rtl_eligible() {
        return Ok(Outcome::Skip { reason });
    }
    let Some(tb) = &args.rtl_tb else {
        return Ok(Outcome::Skip {
            reason: "没给 --rtl-tb，只跑了黄金模型".to_string(),
        });
    };

    let input = case
        .materialize_rtl(&args.work_dir)
        .map_err(|err| vec![err])?;
    let state_path = case.work_dir(&args.work_dir).join("state.json");
    let mut command = Command::new(tb);
    command
        .args(&input.args)
        .arg("--dump-state")
        .arg(&state_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(wave) = &args.wave {
        command.arg("--dump-wave").arg(wave);
    }
    let output = command
        .output()
        .map_err(|err| vec![format!("调用 {} 失败：{err}", tb.display())])?;
    if !output.status.success() {
        return Err(vec![format!(
            "RTL 跑挂了（退出码 {}）：{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout).trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        )]);
    }
    let text = std::fs::read_to_string(&state_path)
        .map_err(|err| vec![format!("{}: {err}", state_path.display())])?;
    let snapshot: Snapshot = serde_json::from_str(&text).map_err(|err| {
        vec![format!(
            "{} 不是合法的状态 dump：{err}",
            state_path.display()
        )]
    })?;
    let windows = case.read_windows(&machine).map_err(|err| vec![err])?;

    let problems = compare(&machine, &windows, &snapshot);
    if problems.is_empty() {
        Ok(Outcome::Pass {
            cycles: snapshot.cycles,
            wave: args.wave.clone(),
        })
    } else {
        Err(problems)
    }
}

/// RTL 的快照 vs 黄金模型：状态、warp 0 的 pc/M/GPR/谓词，加上 case 声明的内存窗口。
fn compare(golden: &Machine, windows: &[Vec<u32>], rtl: &Snapshot) -> Vec<String> {
    let mut problems = Vec::new();
    let want_status = golden.status;
    if rtl.status != want_status.code() {
        problems.push(format!(
            "status 期望 {}（{}），实际 {}{}",
            want_status.text(),
            want_status.code(),
            rtl.status,
            match Status::from_code(rtl.status) {
                Some(status) => format!("（{}）", status.text()),
                None => String::new(),
            }
        ));
    }

    let Some(warp) = rtl.warps.first() else {
        problems.push("RTL 的 dump 里没有 warp".to_string());
        return problems;
    };
    let want_warp = &golden.warps[0];
    if warp.pc as usize != want_warp.pc {
        problems.push(format!("pc 期望 {}，实际 {}", want_warp.pc, warp.pc));
    }
    if warp.m != want_warp.m {
        problems.push(format!("M 期望 {:#x}，实际 {:#x}", want_warp.m, warp.m));
    }
    for (lane, want_gpr) in want_warp.gpr.iter().enumerate() {
        let Some(rtl_gpr) = warp.gpr.get(lane) else {
            problems.push(format!("RTL 的 dump 少了 lane {lane}"));
            continue;
        };
        for (reg, want) in want_gpr.iter().enumerate() {
            match rtl_gpr.get(reg) {
                Some(actual) if actual == want => {}
                Some(actual) => problems.push(format!(
                    "lane {lane} r{reg} 期望 {want}（{want:#x}），实际 {actual}（{actual:#x}）"
                )),
                None => problems.push(format!("lane {lane} 少了 r{reg}")),
            }
        }
    }
    for (lane, want_pred) in want_warp.pred.iter().enumerate() {
        let Some(rtl_pred) = warp.pred.get(lane) else {
            problems.push(format!("RTL 的 dump 少了 lane {lane} 的谓词"));
            continue;
        };
        for (index, want) in want_pred.iter().enumerate() {
            let actual = rtl_pred.get(index).copied().unwrap_or(0) != 0;
            if actual != *want {
                problems.push(format!(
                    "lane {lane} p{index} 期望 {}，实际 {}",
                    u8::from(*want),
                    u8::from(actual)
                ));
            }
        }
    }

    if rtl.mem.len() != windows.len() {
        problems.push(format!(
            "内存窗口数对不上：RTL 给了 {} 个，case 声明了 {} 个",
            rtl.mem.len(),
            windows.len()
        ));
    }
    for (index, want_words) in windows.iter().enumerate() {
        let Some(window) = rtl.mem.get(index) else {
            continue;
        };
        if window.words.len() != want_words.len() {
            problems.push(format!(
                "第 {index} 个内存窗口（{} 0x{:x}）长度对不上：期望 {}，实际 {}",
                window.space,
                window.addr,
                want_words.len(),
                window.words.len()
            ));
            continue;
        }
        for (offset, want) in want_words.iter().enumerate() {
            let actual = window.words[offset];
            if actual != *want {
                problems.push(format!(
                    "{} 0x{:x} 第 {offset} 个字期望 {want}（{want:#x}），实际 {actual}（{actual:#x}）",
                    window.space,
                    window.addr as usize + offset * 4,
                ));
            }
        }
    }
    problems
}
