//! skein-case：把 `cases/*.toml` 同时送进黄金模型和 RTL testbench，逐项比对。
//!
//! 黄金模型在进程里跑；RTL 由 Verilator 的 `tb_core` 跑，它只负责喂输入、dump 状态，
//! 比对逻辑都在这里。形状不支持的 case（block 比核还大、多 block）只跑黄金模型，报
//! SKIP；形状由 `tb_core --print-shape` 自报，所以这里不写死 lane 数 / warp 数。
//!
//! 黄金模型报错（status != OK）时只比 status 和 trap（哪条 warp 停在哪个 PC）：出错
//! 之后哪些 lane / 哪些存储已经生效属于实现行为，不是架构契约（见 docs/design.md
//! §5.5），逐字节比只会得到假 FAIL。
//!
//! 用法见 `skein-case --help`；`make rtl-sim` 会先建好模型再调它。

use std::path::PathBuf;
use std::process::{Command, ExitCode, Stdio};

use clap::Parser;
use serde::Deserialize;

use skein::case::{Case, RtlShape};
use skein::golden::Machine;
use skein::isa::{OpClass, Status};

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

    /// 每个 case 多打一行性能计数器（IPC 的分解，M3 的曲线从这儿拿数据）
    #[arg(long)]
    stats: bool,

    /// AXI 从机的固定延迟（拍），两个方向同值；M5 对比表用 20
    #[arg(long, value_name = "N")]
    axi_latency: Option<u32>,
}

/// `tb_core --dump-state` 写出来的状态快照。
#[derive(Deserialize, Debug)]
struct Snapshot {
    status: u32,
    #[serde(default)]
    cycles: u64,
    #[serde(default)]
    fault: Option<SnapshotFault>,
    #[serde(default)]
    perf: Perf,
    warps: Vec<SnapshotWarp>,
    #[serde(default)]
    mem: Vec<SnapshotWindow>,
}

/// RTL 的 trap（`SK_core.trap_*`）：正常结束是 null。
#[derive(Deserialize, Debug)]
struct SnapshotFault {
    wid: u32,
    pc: u32,
}

/// RTL 的性能计数器（`SK_perf`，见 docs/design.md §13）。
#[derive(Deserialize, Debug, Default)]
struct Perf {
    #[serde(default)]
    cycles: u64,
    #[serde(default)]
    issued: u64,
    #[serde(default)]
    retired: u64,
    #[serde(default)]
    replay: u64,
    #[serde(default)]
    barriers: u64,
    #[serde(default)]
    stall_no_warp: u64,
    #[serde(default)]
    lsu_busy: u64,
    #[serde(default)]
    lds_txn: u64,
    #[serde(default)]
    sts_txn: u64,
    #[serde(default)]
    lds_replay: u64,
    #[serde(default)]
    axi_rd_txn: u64,
    #[serde(default)]
    axi_wr_txn: u64,
    #[serde(default)]
    axi_rd_beats: u64,
    #[serde(default)]
    axi_wr_beats: u64,
    #[serde(default)]
    axi_stall: u64,
    #[serde(default)]
    l1_rd_hit: u64,
    #[serde(default)]
    l1_rd_miss: u64,
    #[serde(default)]
    l1_wr_hit: u64,
    #[serde(default)]
    l1_wr_miss: u64,
    #[serde(default)]
    l1_wb: u64,
    #[serde(default)]
    class: Vec<u64>,
}

impl Perf {
    /// IPC = 提交的指令数 / 周期数；一次都没跑就报 0。
    fn ipc(&self) -> f64 {
        if self.cycles == 0 {
            0.0
        } else {
            self.retired as f64 / self.cycles as f64
        }
    }

    /// 没发射的拍数：`CYCLE - INST_ISSUED`（读的时候算，RTL 里不占计数器）。
    fn no_issue(&self) -> u64 {
        self.cycles.saturating_sub(self.issued)
    }
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
    Pass {
        cycles: u64,
        ipc: f64,
        stats: Option<String>,
        wave: Option<PathBuf>,
        limited: bool,
    },
    Skip {
        reason: String,
    },
}

fn main() -> ExitCode {
    let args = Args::parse();
    let shape = match &args.rtl_tb {
        Some(tb) => {
            if !tb.is_file() {
                eprintln!(
                    "找不到 RTL testbench：{}（先 make rtl-sim 或者给出正确路径）",
                    tb.display()
                );
                return ExitCode::FAILURE;
            }
            match probe_shape(tb) {
                Ok(shape) => {
                    println!(
                        "RTL 形状：{} lane/warp × {} warp，最多 {} 个线程/block，{} 个 block",
                        shape.warpsz, shape.nwarp, shape.max_block_dim, shape.max_grid
                    );
                    Some(shape)
                }
                Err(err) => {
                    eprintln!("{err}");
                    return ExitCode::FAILURE;
                }
            }
        }
        None => None,
    };
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
        match run(case, &args, shape.as_ref()) {
            Ok(Outcome::Pass {
                cycles,
                ipc,
                stats,
                wave,
                limited,
            }) => {
                passed += 1;
                let note = if limited { "  只比 status/trap" } else { "" };
                let stats = stats
                    .map(|line| format!("\n    {line}"))
                    .unwrap_or_default();
                match wave {
                    Some(path) => println!(
                        "{:<width$} PASS  cycles={cycles}  IPC={ipc:.3}  wave={}{note}{stats}",
                        case.name,
                        path.display()
                    ),
                    None => println!(
                        "{:<width$} PASS  cycles={cycles}  IPC={ipc:.3}{note}{stats}",
                        case.name
                    ),
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

/// 问一次 testbench 的形状：`tb_core --print-shape` 打一行 JSON。
fn probe_shape(tb: &PathBuf) -> Result<RtlShape, String> {
    let output = Command::new(tb)
        .arg("--print-shape")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("调用 {} --print-shape 失败：{err}", tb.display()))?;
    if !output.status.success() {
        return Err(format!(
            "{} --print-shape 失败（退出码 {}）：{}",
            tb.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    serde_json::from_str(text.trim())
        .map_err(|err| format!("{} --print-shape 的输出不是形状 JSON：{err}", tb.display()))
}

fn run(case: &Case, args: &Args, shape: Option<&RtlShape>) -> Result<Outcome, Vec<String>> {
    let mut machine = case.machine(false).map_err(|err| vec![err])?;
    machine.run();
    let golden_problems = case.check_golden(&machine);
    if !golden_problems.is_empty() {
        return Err(golden_problems);
    }
    let (Some(tb), Some(shape)) = (&args.rtl_tb, shape) else {
        return Ok(Outcome::Skip {
            reason: "没给 --rtl-tb，只跑了黄金模型".to_string(),
        });
    };
    if let Err(reason) = case.rtl_eligible(shape) {
        return Ok(Outcome::Skip { reason });
    }

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
    if let Some(latency) = args.axi_latency {
        command
            .arg("--axi-rd-latency")
            .arg(latency.to_string())
            .arg("--axi-wr-latency")
            .arg(latency.to_string());
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

    let mut problems = compare(&machine, &windows, &snapshot);
    let limited = machine.status != Status::Ok;
    // 提交条数和 BAR 次数要和黄金模型对得上（报错用例的路径本来就不一样，不比）
    if !limited {
        if snapshot.perf.retired != machine.steps {
            problems.push(format!(
                "RTL 提交 {} 条指令，黄金模型执行了 {} 条",
                snapshot.perf.retired, machine.steps
            ));
        }
        if snapshot.perf.barriers != machine.barriers {
            problems.push(format!(
                "RTL 放行 {} 次 BAR，黄金模型 {} 次",
                snapshot.perf.barriers, machine.barriers
            ));
        }
        // 按指令类对拍：黄金模型的 op_counts 是对照组（和总数一样，属于语义检查）
        let mut want_class = vec![0u64; OpClass::ALL.len()];
        for (class, count) in machine.op_counts() {
            want_class[class.code() as usize] = count;
        }
        for (index, want) in want_class.iter().enumerate() {
            let actual = snapshot.perf.class.get(index).copied().unwrap_or(0);
            if actual != *want {
                problems.push(format!(
                    "RTL 提交 {} 条 {}，黄金模型 {} 条",
                    actual,
                    OpClass::ALL[index].text(),
                    want
                ));
            }
        }
    }
    if problems.is_empty() {
        let stats = args.stats.then(|| {
            format!(
                "issued={} retired={} replay={} no_issue={} no_warp={} lsu_busy={}\n    \
                 lds={} sts={} lds_replay={} l1(hit/miss/wb)={}/{}/{} wr={}/{}\n    \
                 axi(rd/wr txn)={}/{} beats={}/{} core_bytes={} bus_bytes={} stall={}",
                snapshot.perf.issued,
                snapshot.perf.retired,
                snapshot.perf.replay,
                snapshot.perf.no_issue(),
                snapshot.perf.stall_no_warp,
                snapshot.perf.lsu_busy,
                snapshot.perf.lds_txn,
                snapshot.perf.sts_txn,
                snapshot.perf.lds_replay,
                snapshot.perf.l1_rd_hit,
                snapshot.perf.l1_rd_miss + snapshot.perf.l1_wr_miss,
                snapshot.perf.l1_wb,
                snapshot.perf.l1_wr_hit,
                snapshot.perf.l1_wr_miss,
                snapshot.perf.axi_rd_txn,
                snapshot.perf.axi_wr_txn,
                snapshot.perf.axi_rd_beats,
                snapshot.perf.axi_wr_beats,
                (snapshot.perf.axi_rd_beats + snapshot.perf.axi_wr_beats) * 8,
                // 512-bit 主口：一笔事务搬一整行 64 B（见 design.md §8/§12.11）
                (snapshot.perf.axi_rd_txn + snapshot.perf.axi_wr_txn) * 64,
                snapshot.perf.axi_stall,
            )
        });
        Ok(Outcome::Pass {
            cycles: snapshot.cycles,
            ipc: snapshot.perf.ipc(),
            stats,
            wave: args.wave.clone(),
            limited,
        })
    } else {
        Err(problems)
    }
}

/// RTL 的快照 vs 黄金模型：正常结束时比每条 warp 的 pc/M/GPR/谓词和 case 声明的内存
/// 窗口；黄金模型报错时只比 status 和 trap——出错之后哪些 lane 已经提交、内存写进去
/// 多少都属于实现行为（docs/design.md §5.5），不是架构契约；比下去只会得到假 FAIL。
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

    if golden.status != Status::Ok {
        match (golden.fault, &rtl.fault) {
            (Some((wid, pc)), Some(actual)) => {
                if actual.wid as usize != wid || actual.pc as usize != pc {
                    problems.push(format!(
                        "trap 期望 w{wid} pc {pc}，实际 w{} pc {}",
                        actual.wid, actual.pc
                    ));
                }
            }
            (Some((wid, pc)), None) => {
                problems.push(format!("RTL 没报 trap，黄金模型停在 w{wid} pc {pc}"));
            }
            (None, Some(actual)) => {
                problems.push(format!(
                    "黄金模型没报 trap，RTL 停在 w{} pc {}",
                    actual.wid, actual.pc
                ));
            }
            (None, None) => {} // BAD_LAUNCH 之类：还没执行到任何指令
        }
        return problems;
    }

    if rtl.fault.is_some() {
        problems.push("状态是 OK，但 RTL 报了 trap".to_string());
    }
    if rtl.warps.len() < golden.warps.len() {
        problems.push(format!(
            "RTL 的 dump 里只有 {} 条 warp，黄金模型有 {} 条",
            rtl.warps.len(),
            golden.warps.len()
        ));
        return problems;
    }
    // 每条 warp 各比各的
    for (wid, want_warp) in golden.warps.iter().enumerate() {
        let warp = &rtl.warps[wid];
        if warp.pc as usize != want_warp.pc {
            problems.push(format!("w{wid} pc 期望 {}，实际 {}", want_warp.pc, warp.pc));
        }
    }
    for (wid, want_warp) in golden.warps.iter().enumerate() {
        let warp = &rtl.warps[wid];
        if warp.m != want_warp.m {
            problems.push(format!(
                "w{wid} M 期望 {:#x}，实际 {:#x}",
                want_warp.m, warp.m
            ));
        }
        for (lane, want_gpr) in want_warp.gpr.iter().enumerate() {
            let Some(rtl_gpr) = warp.gpr.get(lane) else {
                problems.push(format!("w{wid} 的 dump 少了 lane {lane}"));
                continue;
            };
            for (reg, want) in want_gpr.iter().enumerate() {
                match rtl_gpr.get(reg) {
                    Some(actual) if actual == want => {}
                    Some(actual) => problems.push(format!(
                        "w{wid} lane {lane} r{reg} 期望 {want}（{want:#x}），实际 {actual}（{actual:#x}）"
                    )),
                    None => problems.push(format!("w{wid} lane {lane} 少了 r{reg}")),
                }
            }
        }
        for (lane, want_pred) in want_warp.pred.iter().enumerate() {
            let Some(rtl_pred) = warp.pred.get(lane) else {
                problems.push(format!("w{wid} 的 dump 少了 lane {lane} 的谓词"));
                continue;
            };
            for (index, want) in want_pred.iter().enumerate() {
                let actual = rtl_pred.get(index).copied().unwrap_or(0) != 0;
                if actual != *want {
                    problems.push(format!(
                        "w{wid} lane {lane} p{index} 期望 {}，实际 {}",
                        u8::from(*want),
                        u8::from(actual)
                    ));
                }
            }
        }
    }
    // 核的容量比 case 用的大时，多出来的 warp 必须是"没跑过"的样子（PC = 0、
    // M = 完整 mask、GPR 和谓词全 0）；真跑过就说明调度器把不该起来的 warp 放出去了。
    let full = if golden.warpsz >= 32 {
        u32::MAX
    } else {
        (1u32 << golden.warpsz) - 1
    };
    for (wid, warp) in rtl.warps.iter().enumerate().skip(golden.warps.len()) {
        let pristine = warp.pc == 0
            && warp.m == full
            && warp.gpr.iter().all(|lane| lane.iter().all(|reg| *reg == 0))
            && warp
                .pred
                .iter()
                .all(|lane| lane.iter().all(|bit| *bit == 0));
        if !pristine {
            problems.push(format!(
                "w{wid} 不在这个 block 里，但状态不是没跑过的样子（pc={} m={:#x}）",
                warp.pc, warp.m
            ));
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
