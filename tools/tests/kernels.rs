//! kernel 级测试：手写 mask 序列（IF/ELSE、循环、break/continue），以及从 cases/
//! 装载输入的 vecadd / matmul 语义对照。

mod common;

use common::{gprs, run};
use skein::case::Case;
use skein::golden::{Machine, Space};
use skein::isa::Status;
use std::path::Path;

/// matmul kernel 的内层维度（kernel 里写死 16）。
const MATMUL_N: usize = 16;

#[test]
fn warp_sum_via_shuffle() {
    // SHFL.BFLY 做 warp 内归约：4 lane 的 laneid 求和 = 0+1+2+3 = 6
    let m = run("
            SREAD     r1, S_LANEID
            LI        r2, 1
            SHFL.BFLY r3, r1, r2
            ADD       r1, r1, r3
            LI        r2, 2
            SHFL.BFLY r3, r1, r2
            ADD       r1, r1, r3
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 1, 0), [6; 4]);
}

#[test]
fn warp_prefix_sum_via_shuffle() {
    // SHFL.UP 做前缀和：[0,1,2,3] -> [0,1,3,6]。
    // SHFL.UP 越界时返回自己的值，所以扫之前要用谓词把越界 lane 的增量清成 0。
    let m = run("
            SREAD   r1, S_LANEID
            MOV     r4, r1
            LI      r2, 1
            SHFL.UP r3, r1, r2
            CMP.GE  p2, r4, r2
            SEL     r3, r3, r0, p2
            ADD     r1, r1, r3
            LI      r2, 2
            SHFL.UP r3, r1, r2
            CMP.GE  p2, r4, r2
            SEL     r3, r3, r0, p2
            ADD     r1, r1, r3
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 1, 0), [0, 1, 3, 6]);
}

#[test]
fn handwritten_if_else() {
    // IF/ELSE 的手写 mask 序列，模板见 docs/design.md §6.2
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LT  p7, r1, r2          ; p7 = lane0,1
            MSAVE   r24                 ; 入口 mask
            MAND.P  r25, r24, p7        ; then 路径的 lane
            MANDN.P r26, r24, p7        ; else 路径的 lane
            MREST   r25
            LI      r3, 10              ; then body
            MSAVE   r25                 ; then 退出时的 mask
            MREST   r26
            LI      r3, 20              ; else body
            MSAVE   r26
            MOR     r24, r25, r26       ; 合并两条路径
            MREST   r24                 ; 重汇聚
            LI      r4, 99
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [10, 10, 20, 20]);
    assert_eq!(gprs(&m, 4, 0), [99; 4]);
}

#[test]
fn handwritten_loop_uniform_exit() {
    let m = run("
            LI      r1, 0               ; i
            LI      r2, 5               ; n
            LI      r3, 0               ; sum
            MSAVE   r24
            MSAVE   r25
    loop:
            MREST   r25
            CMP.LT  p7, r1, r2          ; i < n
            MAND.P  r25, r25, p7
            MREST   r25
            BRZ     r25, done
            ADD     r3, r3, r1
            ADDI    r1, r1, 1
            MREST   r25
            JMP     loop
    done:
            MREST   r24
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [10; 4]); // 0+1+2+3+4
}

#[test]
fn handwritten_continue() {
    let m = run("
            LI      r1, 0               ; i
            LI      r2, 4               ; n
            LI      r3, 0               ; sum
            LI      r6, 2
            MSAVE   r24
            MSAVE   r25
    loop:
            MREST   r25
            CMP.LT  p7, r1, r2
            MAND.P  r25, r25, p7
            MREST   r25
            BRZ     r25, done
            ADDI    r1, r1, 1           ; i++（continue 之前先自增）
            CMP.EQ  p6, r1, r6          ; i == 2 ?
            MCLR.P  p6                  ; 这些 lane 跳过本轮剩余部分
            ADD     r3, r3, r1
            JMP     loop
    done:
            MREST   r24
            EXIT
    ");
    assert_eq!(gprs(&m, 3, 0), [8; 4]); // 1+3+4，跳过 i == 2
}

#[test]
fn handwritten_break_is_per_lane() {
    // break：MANDN.P 的谓词按 p & M 读，所以直接写 r25 也只会删当前 M 内的 lane；
    // MCLR.P 再把本迭代剩余部分清掉（见 design.md §6.4）
    let m = run("
            SREAD   r7, S_TID
            LI      r1, 0               ; i
            LI      r2, 6               ; n
            LI      r3, 0               ; sum
            LI      r4, 3
            SUB     r4, r4, r7          ; limit = 3 - tid
            MSAVE   r24
            MSAVE   r25
    loop:
            MREST   r25
            CMP.LT  p7, r1, r2
            MAND.P  r25, r25, p7
            MREST   r25
            BRZ     r25, done
            ADDI    r1, r1, 1           ; i++
            CMP.EQ  p6, r1, r4          ; i == limit ?
            MANDN.P r25, r25, p6        ; 这些 lane 永久退出循环
            MCLR.P  p6                  ; 本迭代剩余部分不再执行
            ADD     r3, r3, r1
            JMP     loop
    done:
            MREST   r24
            EXIT
    ");
    assert_eq!(gprs(&m, 3, 0), [3, 1, 0, 21]);
    assert_eq!(gprs(&m, 1, 0), [3, 2, 1, 6]);
}

#[test]
fn break_in_then_keeps_else_lanes() {
    // break 写在 IF/ELSE 的 then 里时，不能把 else 路径的 lane 从循环 mask 里删掉
    let m = run("
            SREAD   r7, S_TID           ; tid 0..3
            LI      r1, 0               ; i
            LI      r2, 2               ; 阈值：tid >= 2 走 then
            LI      r3, 4               ; 循环 n 轮
            LI      r4, 0               ; else 路径执行了几轮
            MSAVE   r24
            MSAVE   r25
    loop:
            MREST   r25
            CMP.LT  p7, r1, r3          ; i < n
            MAND.P  r25, r25, p7
            MREST   r25
            BRZ     r25, done
            ADDI    r1, r1, 1           ; i++
            CMP.GE  p1, r7, r2          ; then = tid >= 2
            MSAVE   r26                 ; 入口 mask
            MAND.P  r27, r26, p1        ; then 路径
            MANDN.P r28, r26, p1        ; else 路径
            MREST   r27
            LI      r5, 2
            CMP.EQ  p6, r1, r5          ; 第 2 轮时 then 里的 break
            MANDN.P r25, r25, p6        ; 只删 M 内的 lane
            MCLR.P  p6
            MSAVE   r27                 ; then 退出时的 mask
            MREST   r28
            ADDI    r4, r4, 1           ; else 路径的计数
            MSAVE   r28
            MOR     r26, r27, r28       ; 合并两条路径
            MREST   r26
            JMP     loop
    done:
            MREST   r24
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 4, 0), [4, 4, 0, 0]); // else 的 lane 跑满 4 轮
    assert_eq!(gprs(&m, 1, 0), [4, 4, 2, 2]); // then 的 lane 第 2 轮 break
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
    let mut c = vec![0i32; rows * MATMUL_N];
    for i in 0..rows {
        for j in 0..MATMUL_N {
            let mut acc = 0i32;
            for k in 0..MATMUL_N {
                acc = acc.wrapping_add(a[i * MATMUL_N + k].wrapping_mul(b[k * MATMUL_N + j]));
            }
            c[i * MATMUL_N + j] = acc;
        }
    }
    c
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
