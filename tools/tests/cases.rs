//! case 级测试：`cases/*.toml` 每个都跑一遍黄金模型，检查 `[expect]`。
//!
//! 这一步不需要 Verilator，`make test` 就能跑；RTL 与黄金模型的逐项比对在
//! `skein-case`（`make rtl-sim`）里做。

use std::path::{Path, PathBuf};

use skein::case::Case;

/// `cases/` 在 crate 的上一层（仓库根目录）。
fn cases_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../cases")
}

#[test]
fn cases_match_expectations() {
    let cases = Case::load_dir(&cases_dir()).expect("读不到 cases/");
    assert!(!cases.is_empty(), "cases/ 里一个 case 都没有");
    let mut problems = Vec::new();
    for case in &cases {
        let mut machine = match case.machine(false) {
            Ok(machine) => machine,
            Err(err) => {
                problems.push(err);
                continue;
            }
        };
        machine.run();
        for problem in case.check_golden(&machine) {
            problems.push(format!("{}: {problem}", case.name));
        }
    }
    assert!(
        problems.is_empty(),
        "{} 个 case 有问题：\n{}",
        problems.len(),
        problems.join("\n")
    );
}

#[test]
fn cases_are_well_formed() {
    // 程序能汇编、形状和 [sreg] 能解析、初态装得下、比对窗口读得出来
    for case in Case::load_dir(&cases_dir()).expect("读不到 cases/") {
        case.program_words()
            .unwrap_or_else(|err| panic!("{}: {err}", case.name));
        let machine = case
            .machine(false)
            .unwrap_or_else(|err| panic!("{}: {err}", case.name));
        case.read_windows(&machine)
            .unwrap_or_else(|err| panic!("{}: {err}", case.name));
    }
}
