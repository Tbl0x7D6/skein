//! 定向 ISA 测试：每条指令至少一条，含门控、mask 相干、错误码。

mod common;

use common::{gprs, one_warp, run, run_with};
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
fn dot_p_result_is_masked_by_m() {
    // inactive lane 的旧谓词不能把 lane 复活（.P 形式的 M 相干规则）
    let m = run("
            SREAD   r1, S_TID
            LI      r2, 2
            CMP.LTU p1, r1, r2      ; p1 = lane0,1
            CMP.GEU p2, r1, r2      ; p2 = lane2,3
            MSAVE   r24             ; M = 0b1111
            MAND.P  r25, r24, p1    ; 0b0011
            MREST   r25             ; M = 0b0011
            MAND.P  r26, r24, p2    ; p2 只在 M 外为真 -> 被 M 挡掉
            MOR.P   r27, r24, p2
            EXIT
    ");
    assert_eq!(gprs(&m, 25, 0), [0b0011; 4]);
    assert_eq!(gprs(&m, 26, 0), [0; 4]);
    assert_eq!(gprs(&m, 27, 0), [0b0011; 4]);
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
            SREAD   r4, S_NTID
            SREAD   r5, S_NWARP
            SREAD   r6, S_PTR_A
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
    assert_eq!(gprs(&m, 12, 0), [Status::Ok.code(); 4]);
}

#[test]
fn ntid_bigger_than_default_warp_width() {
    // 黄金模型按 ntid 参数化，不受编译期 NUM_LANES 限制
    let config = Config {
        ntid: 8,
        ..one_warp()
    };
    let m = run_with(
        "
            SREAD   r1, S_TID
            SREAD   r2, S_NTID
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
    let mut machine = Machine::new(vec![0x0000_0000], one_warp()); // op=0 是保留编码
    machine.run();
    assert_eq!(machine.status, Status::BadInsn);
}

#[test]
fn error_pc_out_of_range() {
    let m = run("NOP"); // 没有 EXIT，跑出 IMEM
    assert_eq!(m.status, Status::PcOob);
}
