//! kernel 级测试：手写 mask 序列（IF/ELSE、循环、break/continue、vecadd）。

mod common;

use common::{gprs, one_warp, run};
use skein::asm;
use skein::golden::{Config, Machine, Space};
use skein::isa::{Sreg, Status};

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
    // break：把"正在退出"的 lane 组合成 mask，从继续 mask 里减掉，再清掉这一段
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
            MSAVE   r5                  ; 当前活跃 lane
            MAND.P  r5, r5, p6          ; 其中满足条件的
            MANDN   r25, r25, r5        ; 这些 lane 退出循环
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
