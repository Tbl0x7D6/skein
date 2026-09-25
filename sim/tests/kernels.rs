//! kernel 级测试：手写 mask 序列（IF/ELSE、循环、break/continue、vecadd）。

mod common;

use common::{gprs, one_warp, run};
use skein::asm;
use skein::golden::{Config, Machine, Space};
use skein::isa::{Sreg, Status};

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

#[test]
fn vecadd_matches_reference() {
    let n: u32 = 37; // 16 线程 + 非整除的 n，制造 lane 分歧
    let output = asm::assemble(include_str!("../kernels/vecadd.s")).unwrap();
    let config = Config {
        nwarp: 4,
        ..one_warp()
    }
    .with(Sreg::PtrA, 0x1000)
    .with(Sreg::PtrB, 0x2000)
    .with(Sreg::PtrC, 0x3000)
    .with(Sreg::Arg0, n);
    let mut machine = Machine::new(output.words, config);
    let a: Vec<u32> = (0..n).map(|i| i * 3 + 1).collect();
    let b: Vec<u32> = (0..n).map(|i| i * 7 + 2).collect();
    for i in 0..n as usize {
        machine.write_word(Space::Gmem, 0x1000 + 4 * i, a[i]);
        machine.write_word(Space::Gmem, 0x2000 + 4 * i, b[i]);
    }
    machine.run();
    assert_eq!(machine.status, Status::Ok);
    for i in 0..n as usize {
        assert_eq!(
            machine.read_word(Space::Gmem, 0x3000 + 4 * i),
            a[i].wrapping_add(b[i]),
            "i = {i}"
        );
    }
    assert_eq!(machine.read_word(Space::Gmem, 0x3000 + 4 * n as usize), 0); // 没有越界写
}

/// 跑一次 matmul kernel，返回（结束状态, BAR 次数, 指令数, C 的内容）。
fn run_matmul(rows: usize) -> (Status, u64, u64, Vec<u32>) {
    run_matmul_with(rows, None)
}

/// 同上，但可以指定 `blockDim.x`（`None` = 用满容量）。
fn run_matmul_with(rows: usize, block_dim: Option<usize>) -> (Status, u64, u64, Vec<u32>) {
    let output = asm::assemble(include_str!("../kernels/matmul.s")).unwrap();
    let config = Config {
        nwarp: 4,
        block_dim,
        ..one_warp()
    }
    .with(Sreg::PtrA, 0x1000)
    .with(Sreg::PtrB, 0x2000)
    .with(Sreg::PtrC, 0x3000)
    .with(Sreg::Arg0, rows as u32);
    let mut machine = Machine::new(output.words, config);
    for (index, value) in matmul_a(rows).iter().enumerate() {
        machine.write_word(Space::Gmem, 0x1000 + 4 * index, *value as u32);
    }
    for (index, value) in matmul_b().iter().enumerate() {
        machine.write_word(Space::Gmem, 0x2000 + 4 * index, *value as u32);
    }
    let status = machine.run();
    let c = (0..rows * MATMUL_N)
        .map(|index| machine.read_word(Space::Gmem, 0x3000 + 4 * index))
        .collect();
    (status, machine.barriers, machine.steps, c)
}

/// 小整数，乘法不会溢出，方便和参考结果比。
fn matmul_a(rows: usize) -> Vec<i32> {
    (0..rows * MATMUL_N).map(|i| (i as i32 % 7) - 3).collect()
}

fn matmul_b() -> Vec<i32> {
    (0..MATMUL_N * MATMUL_N)
        .map(|i| (i as i32 % 5) - 2)
        .collect()
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
    // 4 warp x 4 lane 协作把 A、B 搬进 shared，BAR 之后每个线程算自己认领的行。
    // rows = 16 时每线程正好一行（无分歧）；20/23 时前几个线程要算两行（有分歧）。
    for rows in [16usize, 20, 23] {
        let (status, barriers, steps, c) = run_matmul(rows);
        assert_eq!(status, Status::Ok, "rows = {rows}");
        assert_eq!(barriers, 1, "rows = {rows}");
        // 粗回归：每个 MAC 摊到的 warp 指令数应该在 3 左右；万一 stride 算错
        // （比如拿 WARPSZ 当 stride）导致各 warp 重复劳动，这里会立刻炸。
        let macs = rows * MATMUL_N * MATMUL_N;
        assert!(
            steps < 5 * macs as u64,
            "rows = {rows}：{steps} 条指令 / {macs} 个 MAC，划分可能退化了"
        );
        let expect = matmul_reference(rows, &matmul_a(rows), &matmul_b());
        for index in 0..rows * MATMUL_N {
            assert_eq!(
                c[index] as i32,
                expect[index],
                "rows = {rows}，第 {} 行第 {} 列",
                index / MATMUL_N,
                index % MATMUL_N
            );
        }
    }
}

#[test]
fn matmul_runs_with_smaller_block() {
    // BLOCK_DIM = 8（2 条 warp）：线程少了，认领行的 stride 要跟着变成 blockDim.x
    for rows in [16usize, 20] {
        let (status, barriers, _, c) = run_matmul_with(rows, Some(8));
        assert_eq!(status, Status::Ok, "rows = {rows}");
        assert_eq!(barriers, 1, "rows = {rows}");
        let expect = matmul_reference(rows, &matmul_a(rows), &matmul_b());
        for index in 0..rows * MATMUL_N {
            assert_eq!(
                c[index] as i32, expect[index],
                "rows = {rows}，第 {index} 个元素"
            );
        }
    }
}
