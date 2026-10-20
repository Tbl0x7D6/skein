//! 定向 ISA 测试：每条指令至少一条，含门控、mask 相干、错误码。

mod common;

use common::{gprs, one_warp, run, run_with};
use skein::asm;
use skein::golden::{Config, Machine, Space};
use skein::isa::*;

#[test]
fn alu_register_ops() {
    let m = run("
            LI   r1, 7
            LI   r2, 5
            ADD  r3, r1, r2
            SUB  r4, r1, r2
            MUL  r5, r1, r2
            SLT  r6, r2, r1
            SLTU r7, r2, r1
            MOV  r8, r1
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [12; 4]);
    assert_eq!(gprs(&m, 4, 0), [2; 4]);
    assert_eq!(gprs(&m, 5, 0), [35; 4]);
    assert_eq!(gprs(&m, 6, 0), [1; 4]);
    assert_eq!(gprs(&m, 7, 0), [1; 4]);
    assert_eq!(gprs(&m, 8, 0), [7; 4]);
}

#[test]
fn li_carries_the_gate() {
    // LI 展开成多条指令，谓词门控要一路带下去（三段拼装都带 pred）
    let m = run("
            SREAD r1, S_LANEID
            LI    r2, 2
            CMP.LT p0, r1, r2
            @p0 LI r3, 0x12345678
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [0x1234_5678, 0x1234_5678, 0, 0]);
}

#[test]
fn predicate_inversion_gates_lanes() {
    // @!p 是取反门控：lane0/1 满足 p0，取反后只有 lane2/3 执行
    let m = run("
            SREAD r1, S_LANEID
            LI    r2, 2
            CMP.LT p0, r1, r2
            LI    r3, 100
            @!p0 ADD r3, r3, r3
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [100, 100, 200, 200]);
}

#[test]
fn sread_can_be_predicated() {
    // SR 格式带 pred，SREAD 可以被 @p / @!p 门控
    let m = run("
            SREAD r1, S_LANEID
            LI    r2, 2
            CMP.LT p0, r1, r2
            LI    r3, 0
            @p0  SREAD r3, S_WARPSZ      ; 只有 lane0/1 写
            LI    r4, 0
            @!p0 SREAD r4, S_TID         ; 只有 lane2/3 写
            EXIT
    ");
    assert_eq!(gprs(&m, 3, 0), [4, 4, 0, 0]);
    assert_eq!(gprs(&m, 4, 0), [0, 0, 2, 3]);
}

#[test]
fn cmp_combine_modifiers() {
    // 组合修饰是读改写；不带修饰的 CMP 是直接赋值
    let m = run("
            SREAD      r1, S_LANEID
            LI         r2, 2
            CMP.LT     p1, r1, r2        ; p1 = lane < 2
            CMP.GE.AND p1, r1, r2        ; 与 lane >= 2 无交集 -> 空
            LI         r3, 0
            @p1 ADD    r3, r3, r2
            CMP.LT     p2, r1, r2
            CMP.GE.OR  p2, r1, r2        ; 并集 -> 全 lane
            CMP.LT     p2, r1, r2        ; SET 覆盖，不是组合
            LI         r4, 0
            @p2 ADD    r4, r4, r2
            CMP.LT     p3, r1, r2
            CMP.LT.XOR p3, r1, r2        ; 自己异或自己 -> 空
            LI         r5, 0
            @p3 ADD    r5, r5, r2
            CMP.LT     p4, r1, r2
            CMP.GE.XOR p4, r1, r2        ; 互补 -> 全 lane
            LI         r6, 0
            @p4 ADD    r6, r6, r2
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [0; 4]);
    assert_eq!(gprs(&m, 4, 0), [2, 2, 0, 0]);
    assert_eq!(gprs(&m, 5, 0), [0; 4]);
    assert_eq!(gprs(&m, 6, 0), [2; 4]);
}

#[test]
fn shfl_modes_and_bounds() {
    let m = run("
            SREAD     r1, S_LANEID        ; 0,1,2,3
            LI        r2, 1
            SHFL.BFLY r3, r1, r2          ; lane ^ 1
            SHFL.UP   r4, r1, r2          ; lane - 1，越界保持自己的值
            SHFL.DOWN r5, r1, r2          ; lane + 1
            LI        r6, 5
            SHFL.IDX  r7, r1, r6          ; 源 lane = 5 % 4 = 1
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [1, 0, 3, 2]);
    assert_eq!(gprs(&m, 4, 0), [0, 0, 1, 2]);
    assert_eq!(gprs(&m, 5, 0), [1, 2, 3, 3]);
    assert_eq!(gprs(&m, 7, 0), [1; 4]);
}

#[test]
fn shfl_source_must_be_active() {
    // 源 lane 不在 M 里：保持自己的值，不报错
    let m = run("
            SREAD     r1, S_LANEID
            LI        r2, 1
            LI        r3, 0b0011
            MREST     r3                  ; M = lane0/1
            SHFL.BFLY r4, r1, r2          ; lane0 <-> lane1 都在 M 里
            SHFL.DOWN r5, r1, r2          ; lane1 的源 lane2 不在 M 里
            EXIT
    ");
    assert_eq!(gprs(&m, 4, 0), [1, 0, 0, 0]);
    assert_eq!(gprs(&m, 5, 0), [1, 1, 0, 0]);
}

#[test]
fn vote_any_all_results_and_m() {
    let m = run("
            SREAD    r1, S_LANEID
            LI       r2, 2
            CMP.GE   p1, r1, r2          ; lane2/3 满足
            LI       r5, 0b0011
            LI       r8, 0b1100
            LI       r11, 0
            MSAVE    r24                 ; 满 mask 备份
            VOTE.ANY r3, p1              ; 满 mask：有 lane 满足 -> 1
            VOTE.ALL r4, p1              ; 满 mask：不是全满足 -> 0
            MREST    r5                  ; 活跃 lane 0/1 都不满足
            VOTE.ANY r6, p1
            VOTE.ALL r7, p1
            MREST    r8                  ; 活跃 lane 2/3 都满足
            VOTE.ANY r9, p1
            VOTE.ALL r10, p1
            MREST    r11                 ; M 为空
            VOTE.ANY r12, p1
            VOTE.ALL r13, p1
            MREST    r24                 ; 恢复满 mask
            VOTE.ANY r15, p1
            LI       r14, 0
            BRNZ     r15, done           ; VOTE 结果直接接统一分支
            LI       r14, 0xBAD
    done:
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [1; 4]);
    assert_eq!(gprs(&m, 4, 0), [0; 4]);
    assert_eq!(gprs(&m, 6, 0), [0; 4]);
    assert_eq!(gprs(&m, 7, 0), [0; 4]);
    assert_eq!(gprs(&m, 9, 0), [1; 4]); // lane 0 不在 M 里，也要读到结果
    assert_eq!(gprs(&m, 10, 0), [1; 4]);
    assert_eq!(gprs(&m, 12, 0), [0; 4]);
    assert_eq!(gprs(&m, 13, 0), [1; 4]); // 空 mask：ALL 为真（对齐 NV）
    assert_eq!(gprs(&m, 14, 0), [0; 4]);
}

#[test]
fn assembler_rejects_unsupported_predicates() {
    for src in [
        "@p0 NOP", // SYS 格式没有 pred
        "@p0 BAR",
        "@p0 EXIT",
        "loop:\n@p0 JMP loop", // 分支没有 pred
        "@p0 MSAVE r24",       // mask 指令是 warp 级、不受门控
        "@!p0 ADDI r1, r0, 1", // RI 格式没有取反位
        "@!p0 LDG r1, [r2]",
        "@!p0 LI r1, 0x12345678", // LI 展开成的也是 RI
        "@p0 SEL r1, r2, r3, p1", // SEL 的 pred 字段是操作数
        "CMP.LT.FOO p1, r1, r2",  // 只有 AND/OR/XOR
        "CMP.LT. p1, r1, r2",
    ] {
        assert!(asm::assemble(src).is_err(), "应该被拒绝：{src}");
    }
    for src in [
        "@!p0 ADD r1, r0, r0",
        "@p3 SREAD r1, S_TID",
        "CMP.GE.XOR p1, r0, r0",
        "@p0 LDS r1, [r2]",
        "SHFL.BFLY r1, r2, r3",
        "@!p0 SHFL.IDX r1, r2, r3",
        "VOTE.ALL r1, p7",
    ] {
        assert!(asm::assemble(src).is_ok(), "应该被接受：{src}");
    }
}

#[test]
fn assembler_checks_warp_ops() {
    for src in [
        "SHFL.XXX r1, r2, r3", // 只有 IDX/UP/DOWN/BFLY
        "SHFL.IDX r1, r2",     // 需要 3 个操作数
        "VOTE.MAYBE r1, p1",   // 只有 ANY/ALL
        "VOTE.ANY r1",         // 需要 2 个操作数
        "VOTE.ANY r1, p8",     // 谓词号越界
        "@p0 VOTE.ANY r1, p1", // VOTE 是 warp 级、不接受门控
    ] {
        assert!(asm::assemble(src).is_err(), "应该被拒绝：{src}");
    }
}

#[test]
fn block_dim_selects_active_warps() {
    // BLOCK_DIM 决定激活几条 warp（必须是 warpSize 的整数倍），其余直接 done
    let source = "
            SREAD   r5, S_BLOCK_DIM
            SREAD   r6, S_PTR_C
            STG     [r6], r5              ; gmem[PTR_C] = blockDim.x
            SREAD   r1, S_TID
            SHLI    r3, r1, 2
            ADD     r3, r3, r6
            LI      r4, 0xABCD
            STG     [r3+0x100], r4        ; 每个活跃线程留一个标记
            BAR                           ; 只有活跃 warp 会到屏障，不能死等
            EXIT
    ";
    let mut steps = Vec::new();
    for bdim in [4usize, 8, 16] {
        let config = Config {
            nwarp: 4,
            block_dim: Some(bdim),
            ..Config::default()
        }
        .with(Sreg::PtrC, 0x1000);
        let machine = run_with(source, config);
        assert_eq!(machine.status, Status::Ok, "bdim = {bdim}");
        assert_eq!(machine.read_word(Space::Gmem, 0x1000), bdim as u32);
        for tid in 0..16 {
            let marker = machine.read_word(Space::Gmem, 0x1100 + 4 * tid);
            let expect = if tid < bdim { 0xABCD } else { 0 };
            assert_eq!(marker, expect, "bdim = {bdim}，tid = {tid}");
        }
        assert_eq!(machine.barriers, 1, "bdim = {bdim}");
        steps.push(machine.steps);
    }
    // 跑的工作量按活跃 warp 数成比例
    assert_eq!(steps[1], 2 * steps[0]);
    assert_eq!(steps[2], 4 * steps[0]);
}

#[test]
fn block_dim_rejects_bad_launch() {
    // 0、不是 warpSize 整数倍、超容量：都在 start 时报 BAD_LAUNCH，一条指令都不跑
    for bdim in [0usize, 2, 6, 17, 32] {
        let config = Config {
            nwarp: 4,
            block_dim: Some(bdim),
            ..Config::default()
        };
        let machine = run_with("EXIT", config);
        assert_eq!(machine.status, Status::BadLaunch, "bdim = {bdim}");
        assert_eq!(machine.steps, 0, "bdim = {bdim}");
    }
}

#[test]
fn grid_zero_is_bad_launch() {
    // GRID_DIM 至少要 1 个 block（RTL 的 SK_ctrl 也是这么校验的）
    let config = Config {
        grid: 0,
        ..one_warp()
    };
    let machine = run_with("EXIT", config);
    assert_eq!(machine.status, Status::BadLaunch);
    assert_eq!(machine.steps, 0);
}

#[test]
fn grid_runs_blocks_in_order() {
    // grid > 1：每个 block 从头跑一遍，S_BID 是当前 block 索引
    let config = Config {
        grid: 3,
        ..one_warp()
    }
    .with(Sreg::PtrC, 0x1000);
    let output = asm::assemble(
        "
            SREAD   r1, S_BID
            SREAD   r2, S_PTR_C
            SHLI    r1, r1, 2
            ADD     r2, r2, r1
            STG     [r2], r1
            BAR                     ; 每个 block 自己同步一次
            EXIT
    ",
    )
    .unwrap();
    let mut machine = Machine::new(output.words, config);
    assert_eq!(machine.run(), Status::Ok);
    for block in 0..3 {
        let bid = block as u32;
        assert_eq!(
            machine.read_word(Space::Gmem, 0x1000 + 4 * block),
            4 * bid,
            "block {block} 的 BID"
        );
    }
    assert_eq!(machine.barriers, 3);
}

#[test]
fn fma_accumulates_into_rd() {
    // FMA rd, ra, rb：rd = rd + ra * rb，rd 既读又写
    let m = run("
            LI   r1, 3
            LI   r2, 4
            LI   r3, 10
            FMA  r3, r1, r2             ; 10 + 3 * 4
            FMA  r3, r3, r3             ; rd 同时是源
            LI   r4, 0
            LI   r5, -1
            FMA  r4, r5, r5             ; 0 + (-1) * (-1)
            LI   r6, 0x10000
            FMA  r4, r6, r6             ; 只保留低 32 位
            SREAD r7, S_LANEID
            LI   r8, 2
            CMP.LT p0, r7, r8           ; lane 0/1
            LI   r9, 100
            @p0 FMA r9, r1, r2          ; 只有 lane 0/1 累加
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [506; 4]);
    assert_eq!(gprs(&m, 4, 0), [1; 4]);
    assert_eq!(gprs(&m, 9, 0), [112, 112, 100, 100]);
}

#[test]
fn shift_and_logic_ops() {
    let m = run("
            LI   r1, 1
            SHLI r2, r1, 4
            SHL  r3, r1, r1
            LI   r4, 0xFF
            SHR  r5, r4, r1
            ANDI r6, r4, 0xF
            ORI  r7, r6, 0x30
            XOR  r8, r7, r4
            SUB  r9, r0, r1
            SAR  r10, r9, r1
            EXIT
    ");
    assert_eq!(gprs(&m, 2, 0), [16; 4]);
    assert_eq!(gprs(&m, 3, 0), [2; 4]);
    assert_eq!(gprs(&m, 5, 0), [0x7F; 4]);
    assert_eq!(gprs(&m, 6, 0), [15; 4]);
    assert_eq!(gprs(&m, 7, 0), [0x3F; 4]);
    assert_eq!(gprs(&m, 8, 0), [0xC0; 4]);
    assert_eq!(gprs(&m, 9, 0), [0xFFFF_FFFF; 4]);
    assert_eq!(gprs(&m, 10, 0), [0xFFFF_FFFF; 4]);
}

#[test]
fn li_builds_any_32_bit_constant() {
    let source = "
            LI   r1, 0x12345678
            LI   r2, 0xFFFFFFFF
            LI   r3, 4096
            LI   r4, 2047
            EXIT
    ";
    let m = run(source);
    assert_eq!(gprs(&m, 1, 0), [0x1234_5678; 4]);
    assert_eq!(gprs(&m, 2, 0), [0xFFFF_FFFF; 4]);
    assert_eq!(gprs(&m, 3, 0), [4096; 4]);
    assert_eq!(gprs(&m, 4, 0), [2047; 4]);
    // 12 位以内 1 条（ADDI），其余按 bits31:20 / 23:12 / 11:0 分段，最多 3 条
    assert_eq!(
        skein::asm::assemble(source).unwrap().words.len(),
        3 + 1 + 1 + 1 + 1
    );
}

#[test]
fn shared_memory_roundtrip() {
    let m = run("
            LI   r1, 0x40
            LI   r2, 0xDEADBEEF
            STS  [r1], r2
            LDS  r3, [r1]
            STS  [r1+4], r2
            LDS  r4, [r1+4]
            LDS  r5, [r1-4]
            EXIT
    ");
    assert_eq!(gprs(&m, 3, 0), [0xDEAD_BEEF; 4]);
    assert_eq!(gprs(&m, 4, 0), [0xDEAD_BEEF; 4]);
    assert_eq!(m.read_word(Space::Smem, 0x40), 0xDEAD_BEEF);
    assert_eq!(m.read_word(Space::Smem, 0x3C), 0);
}

#[test]
fn global_memory_roundtrip() {
    let m = run("
            LI   r1, 0x100
            LI   r2, 1234
            STG  [r1], r2
            LDG  r3, [r1]
            EXIT
    ");
    assert_eq!(gprs(&m, 3, 0), [1234; 4]);
    assert_eq!(m.read_word(Space::Gmem, 0x100), 1234);
}

#[test]
fn predicated_write_only_touches_selected_lanes() {
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LTU p1, r1, r2
            LI      r3, 100
            @p1 ADD r4, r0, r3
            EXIT
    ");
    assert_eq!(gprs(&m, 4, 0), [100, 100, 0, 0]);
}

#[test]
fn select_picks_by_predicate() {
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 1
            CMP.LTU p1, r1, r2
            LI      r3, 11
            LI      r4, 22
            SEL     r5, r3, r4, p1
            EXIT
    ");
    assert_eq!(gprs(&m, 5, 0), [11, 22, 22, 22]);
}

#[test]
fn mask_arithmetic() {
    let m = run("
            MSAVE   r24
            LI      r1, 5
            MAND    r25, r24, r1
            MANDN   r26, r24, r1
            MOR     r27, r24, r1
            MNOT    r28, r1
            EXIT
    ");
    let all = full_mask();
    assert_eq!(gprs(&m, 25, 0), [all & 5; 4]);
    assert_eq!(gprs(&m, 26, 0), [all & !5; 4]);
    assert_eq!(gprs(&m, 27, 0), [all; 4]);
    assert_eq!(gprs(&m, 28, 0), [all & !5; 4]);
}

#[test]
fn dot_p_reads_predicate_masked_by_m() {
    // 谓词按 p & M 读，然后做普通位运算；结果不再强制 ⊆ M
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LTU p1, r1, r2      ; p1 = lane0,1
            CMP.GEU p2, r1, r2      ; p2 = lane2,3
            MSAVE   r24             ; M = 0b1111
            MAND.P  r25, r24, p1    ; 0b0011
            MREST   r25             ; M = 0b0011
            MAND.P  r26, r24, p2    ; p2 & M = 0 -> 0
            MOR.P   r27, r24, p2    ; 同上 -> r24
            MANDN.P r28, r24, p2    ; ~(p2 & M) = 全 1 -> r24（不再被 M 截断）
            MANDN.P r29, r25, p2    ; ra 显式给当前 M -> 0b0011（break 模板的写法）
            MANDN.P r30, r24, p1    ; ~(p1 & M) = 0b1100
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 25, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 26, 0), [0; 4]);
    assert_eq!(gprs(&m, 27, 0), [0b1111; 4]);
    assert_eq!(gprs(&m, 28, 0), [0b1111; 4]);
    assert_eq!(gprs(&m, 29, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 30, 0), [0b1100; 4]);
}

#[test]
fn dot_pm_updates_rd_and_mask_together() {
    // .PM：结果同时写 rd（所有 lane）和 M；同拍读旧 M、写新 M，结果仍 & full
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LTU p1, r1, r2      ; p1 = lane0,1
            LI      r3, 0b1111
            LI      r4, -1
            MREST   r3              ; M = 0b1111
            MAND.PM r24, r3, p1     ; rd = 0b0011，M 也变成 0b0011
            MSAVE   r25             ; 读回 M
            MOR.PM  r26, r24, p1    ; rd = 0b0011 | (p1 & M) = 0b0011，M 不变
            MSAVE   r27
            MREST   r4              ; M = 0xFFFFFFFF & full
            MAND.PM r5, r4, p1      ; rd = 0xFFFFFFFF & (p1 & M) = 0b0011
            MSAVE   r6
            MANDN.PM r28, r24, p1   ; 旧 M = 0b0011 -> rd = 0b0011 & ~0b0011 = 0，M = 0
            MSAVE   r29
            EXIT
    ");
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
#[should_panic(expected = "必须全 lane 一致")]
fn mask_operands_must_be_warp_uniform() {
    // 硬件不查一致性；黄金模型在这里 panic（见 design.md §6.5）
    run("
            SREAD   r1, S_LANEID        ; 每条 lane 都不一样
            MSAVE   r24
            MAND    r25, r24, r1        ; r1 不是 warp 一致的 mask 值
            EXIT
    ");
}

#[test]
fn mclr_p_narrows_m() {
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LTU p1, r1, r2
            LI      r3, 0b1111
            MREST   r3
            MCLR.P  p1
            LI      r4, 7
            ADD     r5, r0, r4      ; 只有 lane2,3 写
            MSAVE   r24
            EXIT
    ");
    assert_eq!(gprs(&m, 24, 0), [0b1100; 4]);
    assert_eq!(gprs(&m, 5, 0), [0, 0, 7, 7]);
}

#[test]
fn uniform_branch() {
    let m = run("
            LI    r1, 0
            LI    r2, 5
            BRZ   r1, skip
            LI    r3, 1
    skip:
            BRZ   r2, end
            LI    r4, 2
    end:
            BRNZ  r2, fin
            LI    r5, 3
    fin:
            JMP   over
            LI    r6, 4
    over:
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [0; 4]);
    assert_eq!(gprs(&m, 4, 0), [2; 4]);
    assert_eq!(gprs(&m, 5, 0), [0; 4]);
    assert_eq!(gprs(&m, 6, 0), [0; 4]);
}

#[test]
fn special_registers() {
    let config = Config {
        nwarp: 2,
        ..one_warp()
    }
    .with(Sreg::PtrA, 0x1234);
    let m = run_with(
        "
            SREAD   r1, S_TID
            SREAD   r2, S_LANEID
            SREAD   r3, S_WID
            SREAD   r4, S_WARPSZ
            SREAD   r5, S_NWARP
            SREAD   r6, S_PTR_A
            SREAD   r7, S_BID
            SREAD   r8, S_BLOCK_DIM
            EXIT
    ",
        config,
    );
    assert_eq!(gprs(&m, 1, 0), [0, 1, 2, 3]);
    assert_eq!(gprs(&m, 1, 1), [4, 5, 6, 7]);
    assert_eq!(gprs(&m, 2, 1), [0, 1, 2, 3]);
    assert_eq!(gprs(&m, 3, 0), [0; 4]);
    assert_eq!(gprs(&m, 3, 1), [1; 4]);
    assert_eq!(gprs(&m, 4, 0), [4; 4]);
    assert_eq!(gprs(&m, 5, 0), [2; 4]);
    assert_eq!(gprs(&m, 6, 1), [0x1234; 4]);
    assert_eq!(gprs(&m, 7, 0), [0; 4]);
    assert_eq!(gprs(&m, 8, 0), [8; 4]); // 默认用满容量：nwarp 2 × warpsz 4
    assert_eq!(gprs(&m, 12, 0), [Status::Ok.code(); 4]);
}

#[test]
fn warpsz_bigger_than_default_warp_width() {
    // 黄金模型按 warpsz 参数化，不受编译期 NUM_LANES 限制
    let config = Config {
        warpsz: 8,
        ..one_warp()
    };
    let m = run_with(
        "
            SREAD   r1, S_TID
            SREAD   r2, S_WARPSZ
            EXIT
    ",
        config,
    );
    assert_eq!(gprs(&m, 1, 0), [0, 1, 2, 3, 4, 5, 6, 7]);
    assert_eq!(gprs(&m, 2, 0), [8; 8]);
}

#[test]
fn exit_is_per_warp() {
    let config = Config {
        nwarp: 2,
        ..one_warp()
    };
    let m = run_with(
        "
            SREAD   r1, S_WID
            BRZ     r1, wid0
            LI      r3, 2
            EXIT
    wid0:
            LI      r3, 1
            EXIT
    ",
        config,
    );
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 3, 0), [1; 4]);
    assert_eq!(gprs(&m, 3, 1), [2; 4]);
}

#[test]
fn barrier_releases_all_warps() {
    let config = Config {
        nwarp: 3,
        ..one_warp()
    };
    let m = run_with(
        "
            SREAD   r1, S_WID
            BRZ     r1, wid0
            LI      r2, 0x40
            BAR
            LDS     r3, [r2]
            EXIT
    wid0:
            LI      r2, 0x40
            LI      r3, 0x42
            STS     [r2], r3
            BAR
            EXIT
    ",
        config,
    );
    assert_eq!(m.status, Status::Ok);
    assert_eq!(m.barriers, 1);
    assert_eq!(gprs(&m, 3, 1), [0x42; 4]);
}

#[test]
fn barrier_requires_full_mask() {
    let m = run("
            LI      r1, 0b0011
            MREST   r1
            BAR
            EXIT
    ");
    assert_eq!(m.status, Status::BarIncomplete);
}

#[test]
fn error_unaligned_access() {
    let m = run("
            LI   r1, 2
            LDS  r2, [r1]
            EXIT
    ");
    assert_eq!(m.status, Status::Unaligned);
    assert_eq!(m.fault, Some((0, 2)), "出错指令的 PC + 1");
}

#[test]
fn error_shared_out_of_range() {
    let config = Config {
        smem_bytes: 0x8000,
        ..one_warp()
    };
    let m = run_with(
        "
            LI   r1, 0x8000
            LDS  r2, [r1]
            EXIT
    ",
        config,
    );
    assert_eq!(m.status, Status::SmemOob);
}

#[test]
fn error_global_out_of_range() {
    let config = Config {
        gmem_bytes: 0x100000,
        ..one_warp()
    };
    let m = run_with(
        "
            LI   r1, 0x100000
            LDG  r2, [r1]
            EXIT
    ",
        config,
    );
    assert_eq!(m.status, Status::GmemOob);
}

#[test]
fn error_bad_insn() {
    // 预留子码：R 类 1011、控制流 0111、warp/系统 1111；func 只有 4 位，0xF 不是合法 ALU
    let cases = [
        0x0000_000B,
        0x0000_0033,
        0x0000_003F,
        enc_r(OP_RALU, 0, 0, 0, Gate::NONE, 0xF),
        enc_sys(0x7),
    ];
    for word in cases {
        let mut machine = Machine::new(vec![word], one_warp());
        machine.run();
        assert_eq!(machine.status, Status::BadInsn, "word {word:08x}");
    }
}

#[test]
fn opcode_layout_is_class_based() {
    // op[5:4] = 类，op[3:0] = 类内子码
    for op in [
        OP_RALU, OP_CMP, OP_CMPA, OP_CMPO, OP_CMPX, OP_SEL, OP_SHFL, OP_VOTE,
    ] {
        assert_eq!(op_class_bits(op), 0, "R 类：{op:#04x}");
        assert!(!is_ri_op(op), "R 类不是 RI：{op:#04x}");
    }
    for op in [OP_ADDI, OP_ANDI, OP_ORI, OP_SHLI, OP_SLTI, OP_LUI, OP_LUM] {
        assert_eq!(op_class_bits(op), 1, "立即数类：{op:#04x}");
        assert!(is_ri_op(op));
    }
    for op in [OP_LDS, OP_STS, OP_LDG, OP_STG] {
        assert_eq!(op_class_bits(op), 2, "访存类：{op:#04x}");
        assert!(is_ri_op(op));
    }
    for op in [OP_BRZ, OP_BRNZ, OP_JMP, OP_MASK, OP_SREAD, OP_SYS] {
        assert_eq!(op_class_bits(op), 3, "控制流/warp 类：{op:#04x}");
        assert!(!is_ri_op(op));
    }
    // CMP 的 bop 就是 op[1:0]，子码 0100–0111
    for (op, bop) in [
        (OP_CMP, Bop::Set),
        (OP_CMPA, Bop::And),
        (OP_CMPO, Bop::Or),
        (OP_CMPX, Bop::Xor),
    ] {
        assert_eq!(op & 0x3, bop.code() - OP_CMP, "{op:#04x}");
        assert_eq!(op & 0xF0, 0x00, "{op:#04x}");
    }
    // 子码在段内：立即数类 0000–0110、访存类 0000–0011、控制流 000–010、warp/系统 000–010
    assert_eq!(OP_LUM & 0xF, 0x6);
    assert_eq!(OP_STG & 0xF, 0x3);
    assert_eq!(OP_BRZ & 0x7, 0x0);
    assert_eq!(OP_JMP & 0x7, 0x2);
    assert_eq!(OP_MASK & 0x7, 0x0);
    assert_eq!(OP_SYS & 0x7, 0x2);
}

#[test]
fn reserved_opcodes_are_rejected() {
    // 已分配的 25 个主操作码之外，其余都是预留/非法
    let allocated = [
        OP_RALU, OP_CMP, OP_CMPA, OP_CMPO, OP_CMPX, OP_SEL, OP_SHFL, OP_VOTE, OP_ADDI, OP_ANDI,
        OP_ORI, OP_SHLI, OP_SLTI, OP_LUI, OP_LUM, OP_LDS, OP_STS, OP_LDG, OP_STG, OP_BRZ, OP_BRNZ,
        OP_JMP, OP_MASK, OP_SREAD, OP_SYS,
    ];
    for op in 0u32..64 {
        if allocated.contains(&op) {
            continue;
        }
        let mut machine = Machine::new(vec![op], one_warp());
        machine.run();
        assert_eq!(machine.status, Status::BadInsn, "op = {op:#04x} 应该被拒绝");
    }
    assert_eq!(allocated.len(), 25);
}

#[test]
fn error_pc_out_of_range() {
    let m = run("NOP"); // 没有 EXIT，跑出 IMEM
    assert_eq!(m.status, Status::PcOob);
    assert_eq!(m.fault, Some((0, 1)), "取指越界停在取不到的地址上");
}

#[test]
fn writes_to_r0_are_dropped() {
    // r0 恒为 0：任何写 r0 都被丢弃（RTL 的寄存器堆也这么干），读出来永远是 0
    let m = run("
            LI    r1, 7
            MOV   r0, r1              ; 普通 ALU 写 r0
            LI    r2, 0x100
            ADD   r0, r2, r2          ; 读改写 r0
            FMA   r0, r2, r2          ; rd 既读又写，也一样丢弃
            MSAVE r0                  ; warp 级 mask 指令写 r0
            SREAD r0, S_TID           ; 特殊寄存器写 r0
            ADD   r3, r0, r1          ; 读 r0 = 0 -> r3 = 7
            EXIT
    ");
    assert_eq!(m.status, Status::Ok);
    assert_eq!(gprs(&m, 0, 0), [0, 0, 0, 0]);
    assert_eq!(gprs(&m, 3, 0), [7; 4]);
}
