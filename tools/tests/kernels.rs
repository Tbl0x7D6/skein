//! kernel 级测试：输入（程序、形状、初态）都从 cases/ 装载，黄金模型跑完在这里做
//! 语义断言。手写 mask 序列在 cases/kernels/mask/，vecadd / matmul 在对应目录。

mod common;

use common::gprs;
use skein::case::Case;
use skein::golden::{Machine, Space};
use skein::isa::{OpClass, Status};
use std::path::Path;

/// matmul kernel 的内层维度（kernel 里写死 16）。
const MATMUL_N: usize = 16;

/// 4 lane 的满 mask。
const FULL: u32 = 0b1111;

#[test]
fn warp_sum_via_shuffle() {
    let m = run_mask_case("shfl_sum");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 1, 0), [6; 4]); // 0+1+2+3
}

#[test]
fn warp_prefix_sum_via_shuffle() {
    let m = run_mask_case("shfl_prefix");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 1, 0), [0, 1, 3, 6]);
}

#[test]
fn divergent_if_else_merges() {
    let m = run_mask_case("if_else");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [10, 10, 20, 20]);
    assert_eq!(gprs(&m, 4, 0), [99; 4]);
    // merge 后 M 回满；IF/ELSE 模板（design.md §6.2）有 9 条 MASK 类指令，
    // 模板加减指令时这条会红，顺带提醒同步文档。
    assert_eq!(m.warps[0].m, FULL);
    assert_eq!(m.count(OpClass::Mask), 9);
}

#[test]
fn nested_if_else_merges() {
    let m = run_mask_case("if_nested");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [1, 2, 3, 3]); // inner then / inner else / outer else
    assert_eq!(gprs(&m, 4, 0), [99; 4]);
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn if_without_else_merges() {
    let m = run_mask_case("if_no_else");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [7, 7, 0, 0]); // else 路径的 lane 没写
    assert_eq!(gprs(&m, 4, 0), [99; 4]);
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn loop_uniform_exit() {
    let m = run_mask_case("loop_uniform");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [10; 4]); // 0+1+2+3+4
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn continue_skips_the_rest_of_the_iteration() {
    let m = run_mask_case("continue");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [8; 4]); // 1+3+4，跳过 i == 2
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn break_is_per_lane() {
    let m = run_mask_case("break");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [3, 1, 0, 21]);
    assert_eq!(gprs(&m, 1, 0), [3, 2, 1, 6]);
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn break_in_then_keeps_else_lanes() {
    let m = run_mask_case("break_in_then");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 4, 0), [4, 4, 0, 0]); // else 的 lane 跑满 4 轮
    assert_eq!(gprs(&m, 1, 0), [4, 4, 2, 2]); // then 的 lane 第 2 轮 break
    assert_eq!(m.warps[0].m, FULL);
}

#[test]
fn pm_writes_rd_and_mask_in_the_same_cycle() {
    let m = run_mask_case("pm");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 24, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 25, 0), [0b0011; 4]); // rd 和 M 同步更新
    assert_eq!(gprs(&m, 26, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 27, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 5, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 6, 0), [0b0011; 4]); // M 也被 & full
    assert_eq!(gprs(&m, 28, 0), [0; 4]); // 读的是旧 M，不是刚写进去的新值
    assert_eq!(gprs(&m, 29, 0), [0; 4]);
}

#[test]
fn vote_any_all_feed_branches() {
    let m = run_mask_case("vote");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 4, 0), [10; 4]); // ANY 成立 -> 走 BRNZ
    assert_eq!(gprs(&m, 6, 0), [30; 4]); // ALL 不成立 -> 走 BRZ
    assert_eq!(gprs(&m, 8, 0), [60; 4]); // ALL 成立 -> 走 BRNZ
}

/// 从 `cases/kernels/mask/` 读一个 case 并跑黄金模型。
fn run_mask_case(name: &str) -> Machine {
    run_case(&format!("kernels/mask/{name}")).1
}

/// 从 `cases/` 里读一个 case 并跑黄金模型：输入（初态、形状、参数）以 case 为准。
fn run_case(name: &str) -> (Case, Machine) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../cases")
        .join(format!("{name}.toml"));
    let case = Case::load(&path).unwrap_or_else(|err| panic!("{err}"));
    let mut machine = case.machine(false).unwrap_or_else(|err| panic!("{err}"));
    machine.run();
    (case, machine)
}

/// case 里声明的特殊寄存器（PTR_A / ARG0 …）。
fn sreg_of(case: &Case, name: &str) -> u32 {
    case.sreg(name)
        .unwrap_or_else(|| panic!("{} 里没有 {name}", case.name))
}

fn gmem(machine: &Machine, addr: u32, words: usize) -> Vec<u32> {
    (0..words)
        .map(|index| machine.read_word(Space::Gmem, addr as usize + 4 * index))
        .collect()
}

#[test]
fn vecadd_matches_reference() {
    // 输入（a/b 的初态、指针、n）都来自 cases/vecadd.toml，这里只加语义断言
    let (case, machine) = run_case("kernels/vecadd/warp4");
    assert_eq!(machine.status, Status::Ok);
    let (a_ptr, b_ptr, c_ptr) = (
        sreg_of(&case, "PTR_A"),
        sreg_of(&case, "PTR_B"),
        sreg_of(&case, "PTR_C"),
    );
    let n = sreg_of(&case, "ARG0") as usize;
    let (a, b, c) = (
        gmem(&machine, a_ptr, n),
        gmem(&machine, b_ptr, n),
        gmem(&machine, c_ptr, n),
    );
    for i in 0..n {
        assert_eq!(c[i], a[i].wrapping_add(b[i]), "i = {i}");
    }
    // 没有越界写
    assert_eq!(machine.read_word(Space::Gmem, c_ptr as usize + 4 * n), 0);
}

/// 从 case 读回 A、B，算参考结果，和 C 窗口逐元素比。
fn check_matmul(case: &Case, machine: &Machine) {
    let rows = sreg_of(case, "ARG0") as usize;
    let a: Vec<i32> = gmem(machine, sreg_of(case, "PTR_A"), rows * MATMUL_N)
        .iter()
        .map(|value| *value as i32)
        .collect();
    let b: Vec<i32> = gmem(machine, sreg_of(case, "PTR_B"), MATMUL_N * MATMUL_N)
        .iter()
        .map(|value| *value as i32)
        .collect();
    let c = gmem(machine, sreg_of(case, "PTR_C"), rows * MATMUL_N);
    let expect = matmul_reference(rows, &a, &b);
    for index in 0..rows * MATMUL_N {
        assert_eq!(
            c[index] as i32,
            expect[index],
            "{}：第 {} 行第 {} 列",
            case.name,
            index / MATMUL_N,
            index % MATMUL_N
        );
    }
}

fn matmul_reference(rows: usize, a: &[i32], b: &[i32]) -> Vec<i32> {
    matmul_reference_n(rows, MATMUL_N, a, b)
}

/// 通用 rows × n 的整数矩阵乘参考（A: rows×n，B: n×n）。
fn matmul_reference_n(rows: usize, n: usize, a: &[i32], b: &[i32]) -> Vec<i32> {
    let mut c = vec![0i32; rows * n];
    for i in 0..rows {
        for j in 0..n {
            let mut acc = 0i32;
            for k in 0..n {
                acc = acc.wrapping_add(a[i * n + k].wrapping_mul(b[k * n + j]));
            }
            c[i * n + j] = acc;
        }
    }
    c
}

#[test]
fn vecadd_stream_matches_reference() {
    // M5 的 streaming 用例：n = 1024，访存全是连续 lane，事务数应该被合并器压到最低
    let (case, machine) = run_case("bench/vecadd_stream/vecadd_stream");
    assert_eq!(machine.status, Status::Ok);
    let n = sreg_of(&case, "ARG0") as usize;
    let (a, b) = (
        gmem(&machine, sreg_of(&case, "PTR_A"), n),
        gmem(&machine, sreg_of(&case, "PTR_B"), n),
    );
    let c = gmem(&machine, sreg_of(&case, "PTR_C"), n);
    for i in 0..n {
        assert_eq!(c[i], a[i].wrapping_add(b[i]), "i = {i}");
    }
}

#[test]
fn sgemm64_matches_reference() {
    // M5 的 sgemm：int32 64×64（A 转置进 shared，B 广播），逐元素和 Rust 参考比
    const N: usize = 64;
    let (case, machine) = run_case("bench/sgemm64/sgemm64");
    assert_eq!(machine.status, Status::Ok);
    let a: Vec<i32> = gmem(&machine, sreg_of(&case, "PTR_A"), N * N)
        .iter()
        .map(|value| *value as i32)
        .collect();
    let b: Vec<i32> = gmem(&machine, sreg_of(&case, "PTR_B"), N * N)
        .iter()
        .map(|value| *value as i32)
        .collect();
    let c = gmem(&machine, sreg_of(&case, "PTR_C"), N * N);
    let expect = matmul_reference_n(N, N, &a, &b);
    for index in 0..N * N {
        assert_eq!(
            c[index] as i32,
            expect[index],
            "第 {} 行第 {} 列",
            index / N,
            index % N
        );
    }
}

#[test]
fn matmul_multi_warp() {
    // 把 A、B 搬进 shared，BAR 之后每个线程算自己认领的行。
    // rows = 4 是单 warp × 4 lane（RTL 也跑）；16 是 4 warp × 4 lane、每线程正好一行；
    // 23 时前几个线程要算两行（有分歧）。BAR 次数和步数上界写在 case 的 [expect] 里，
    // 由 tests/cases.rs 统一检查。
    for name in [
        "kernels/matmul/rows4",
        "kernels/matmul/rows16",
        "kernels/matmul/rows23",
    ] {
        let (case, machine) = run_case(name);
        assert_eq!(machine.status, Status::Ok, "{name}");
        check_matmul(&case, &machine);
    }
}

#[test]
fn matmul_runs_with_smaller_block() {
    // blockDim.x = 8（2 条 warp）：线程少了，认领行的 stride 要跟着变成 blockDim.x
    let (case, machine) = run_case("kernels/matmul/bdim8");
    assert_eq!(machine.status, Status::Ok);
    check_matmul(&case, &machine);
}
