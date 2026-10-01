//! P3 的核：1 个 block × `SK_NUM_WARPS` 条 warp × `SK_NUM_LANES` 个 lane，5 级流水。
//!
//! | 级 | 干什么 |
//! |----|--------|
//! | S1 调度 | `SK_scheduler` 轮询挑一条能发的 warp，把 PC 存进取指请求寄存器 |
//! | S2 取指 | BRAM 一拍后出指令，连同它的 PC/wid 落到 IF/ID（含取指越界标志） |
//! | S3 译码 | 译码、组合读寄存器堆、读该 warp 的 M/谓词快照；scoreboard 查冒险，冲突就重发 |
//! | S4 执行 | ALU / 访存地址 / 分支判定 / mask / SHFL / VOTE；访存请求在这里进 `SK_lsu` |
//! | S5 提交 | 写寄存器堆、写谓词、写 M；改 warp 状态（BAR / EXIT） |
//!
//! 每条 warp 最多一条指令在流水里（`warp_busy`）：发射后要等 4 拍才能再发，正好让
//! 寄存器堆的写在下一次读之前落地，因此不需要前递，也不会在中途卡住某一级。所有可能
//! 卡住的情况（读没回来的 load 目标寄存器、访存槽还占着、BAR/EXIT 前没排空）都在 S3
//! 查出来重发（`replay`），改成别的 warp 继续走。
//!
//! 访存是非阻塞的：请求进 `SK_lsu` 的 per-warp 槽，之后流水线不等它——`LDG/LDS` 的
//! 目标寄存器进 scoreboard（`SK_scoreboard`），`STG/STS` 是 posted write，`EXIT`/`BAR`
//! 之前必须排空。访存占 `SK_NUM_LANES` 拍（一拍一条 lane），P5 的合并器针对它。
//!
//! 出错（访存出错 / 取指越界 / BAD_INSN / BAR 不完整）就停整台核：`STATUS` 和停下来
//! 的 PC 是契约，其余架构状态不作为保证（docs/design.md §5.5）。

`include "SK_config.vh"

module SK_core #(
    parameter int NUM_LANES  = `SK_NUM_LANES,
    parameter int NUM_WARPS  = `SK_NUM_WARPS,
    parameter int NUM_GPR    = `SK_NUM_GPR,
    parameter int NUM_PRED   = `SK_NUM_PRED,
    parameter int IMEM_DEPTH = (`SK_IMEM_KB * 1024) / 4,
    parameter int WARP_W     = (NUM_WARPS > 1) ? $clog2(NUM_WARPS) : 1,
    parameter int LANE_W     = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 1,
    parameter int GPR_W      = (NUM_GPR > 1) ? $clog2(NUM_GPR) : 1
) (
    input  logic                              clk,
    input  logic                              aresetn,        // 同步复位，低有效
    input  logic                              start_i,        // 启动脉冲（P6 接 CTRL.start）
    // 特殊寄存器（P3 由 testbench 驱动；P6 接 AXI-Lite 控制寄存器）
    input  logic [31:0]                       sreg_i [16],
    // 核的容量：{NWARP, NUM_LANES}；testbench 用它决定 dump 形状（P6 接成只读寄存器）
    output logic [15:0]                       shape_o,
    // IMEM 装载口
    input  logic                              imem_we_i,
    input  logic [$clog2(IMEM_DEPTH)-1:0]     imem_addr_i,
    input  logic [31:0]                       imem_wdata_i,
    // shared memory
    output logic [31:0]                       smem_addr_o,
    output logic [31:0]                       smem_wdata_o,
    output logic                              smem_we_o,
    input  logic [31:0]                       smem_rdata_i,
    input  logic                              smem_fault_i,
    // global memory
    output logic [31:0]                       gmem_addr_o,
    output logic [31:0]                       gmem_wdata_o,
    output logic                              gmem_we_o,
    input  logic [31:0]                       gmem_rdata_i,
    input  logic                              gmem_fault_i,
    // 状态
    output logic [3:0]                        status_o,
    output logic                              done_o,
    // 调试扫描口（仿真用）：0x00-0x1F = (warp, lane) 选中的 GPR，0x20 = 该 warp 的 M，
    // 0x21 = 该 (warp, lane) 的谓词，0x22 = 架构 PC，0x23 = STATUS，0x24 = S4 阶段指令，
    // 0x25 = {done, 在跑}，0x26 = S4 阶段 PC，0x27 = 该 warp 的状态，
    // 0x29-0x2B = trap（出错停机时才有意义），0x30-0x39 = 性能计数器（SK_perf）
    input  logic [7:0]                        dbg_addr_i,
    input  logic [WARP_W-1:0]                 dbg_wid_i,
    input  logic [LANE_W-1:0]                 dbg_lane_i,
    output logic [31:0]                       dbg_data_o
);

    import SK_pkg::*;

    localparam logic [NUM_LANES-1:0] FULL_MASK = '1;   // 没有部分 warp：完整 mask 就是全 lane
    localparam int WARPSZ_SHIFT = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 0;

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_e;

    state_e     state_q;
    logic [3:0] status_q;
    logic       start_pulse;

    // 每条 warp 的架构状态
    logic [15:0]          pc_q [NUM_WARPS];       // 取指 PC（发射时 +1，分支在执行级改）
    logic [NUM_LANES-1:0] m_q [NUM_WARPS];
    logic [NUM_PRED-1:0]  pred_q [NUM_WARPS][NUM_LANES];

    // 出错停机时停在哪（错误路径的契约，docs/design.md §5.5）：正常结束 valid 为 0
    logic              trap_valid_q;
    logic [WARP_W-1:0] trap_wid_q;
    logic [15:0]       trap_pc_q;

    // 启动参数：blockDim 是主机给的（P6 走 AXI-Lite），这里只做范围检查
    logic [31:0]       block_dim;
    logic              launch_bad;
    logic [WARP_W:0]   active_warps;

    assign block_dim    = sreg_i[SK_SREG_BLOCK_DIM];
    assign launch_bad   = (block_dim == 32'd0) || (block_dim > 32'(NUM_WARPS * NUM_LANES))
                       || ((block_dim & 32'(NUM_LANES - 1)) != 32'd0);
    assign active_warps = ((block_dim >> WARPSZ_SHIFT) > 32'(NUM_WARPS))
                        ? (WARP_W+1)'(NUM_WARPS) : (WARP_W+1)'(block_dim >> WARPSZ_SHIFT);

    assign start_pulse = (state_q == S_IDLE) && start_i;
    assign shape_o     = {8'(NUM_WARPS), 8'(NUM_LANES)};

    // --- 调度 ---
    logic                 issue_valid;
    logic [WARP_W-1:0]    issue_wid;
    logic [NUM_WARPS-1:0] warp_busy;      // 指令还在 S2..S4
    logic [NUM_WARPS-1:0] warp_wait;      // 重发过，等自己的访存排空
    logic [NUM_WARPS-1:0] warp_pend;      // scoreboard 里有寄存器在等 load 的数据
    logic [NUM_WARPS-1:0] warp_lsu_busy;  // 访存请求槽还占着
    logic [NUM_WARPS-1:0] warp_mem_wait, warp_run, warp_bar, warp_done;
    logic [NUM_WARPS-1:0] arrive_bar, exit_warp;
    logic                 bar_release;
    sk_warp_state_e       warp_state [NUM_WARPS];

    SK_scheduler #(.WARPS(NUM_WARPS)) u_sched (
        .clk           (clk),
        .aresetn       (aresetn),
        .start_i       (start_pulse),
        .active_warps_i(active_warps),
        .busy_i        (warp_busy),
        .wait_i        (warp_wait),
        .arrive_bar_i  (arrive_bar),
        .exit_i        (exit_warp),
        .bar_release_i (bar_release),
        .state_o       (warp_state),
        .issue_valid_o (issue_valid),
        .issue_wid_o   (issue_wid)
    );

    always_comb begin
        for (int warp = 0; warp < NUM_WARPS; warp++) begin
            warp_run[warp]      = (warp_state[warp] == SK_WARP_RUN);
            warp_bar[warp]      = (warp_state[warp] == SK_WARP_BAR);
            warp_done[warp]     = (warp_state[warp] == SK_WARP_DONE);
            warp_mem_wait[warp] = warp_lsu_busy[warp] || warp_pend[warp];
        end
    end

    SK_bar_unit #(.WARPS(NUM_WARPS)) u_bar (
        .bar_i     (warp_bar),
        .done_i    (warp_done),
        .release_o (bar_release)
    );

    // --- S1 调度 / S2 取指 ---
    // 取指用两级寄存器：`f1` 是 BRAM 的读地址（寄存输出对 BRAM 友好），`f2` 是它的
    // 延迟副本——BRAM 下一拍才出数据，指令回来时要和它的 PC 对齐，不然会错一拍。
    logic [15:0] fetch_pc;
    logic        f1_valid_q;
    logic [WARP_W-1:0] f1_wid_q;
    logic [15:0] f1_pc_q;
    logic        f2_valid_q;
    logic [WARP_W-1:0] f2_wid_q;
    logic [15:0] f2_pc_q;
    logic [31:0] insn_f;
    logic        pc_oob_f;
    logic        ifid_valid_q;
    logic [WARP_W-1:0] ifid_wid_q;
    logic [15:0] ifid_pc_q;
    logic [31:0] ifid_insn_q;
    logic        ifid_oob_q;

    assign fetch_pc = pc_q[issue_wid];

    SK_imem #(.DEPTH(IMEM_DEPTH)) u_imem (
        .clk       (clk),
        .pc_i      (f1_pc_q),
        .insn_o    (insn_f),
        .pc_oob_o  (pc_oob_f),
        .ld_we_i   (imem_we_i),
        .ld_addr_i (imem_addr_i),
        .ld_wdata_i(imem_wdata_i)
    );

    // --- S3 译码 ---
    sk_ctrl_t            ctrl;
    logic [NUM_LANES-1:0][31:0]         ra_val, rb_val, rc_val;
    logic [NUM_LANES-1:0]               m_snap, lane_act, gate_ok;
    logic [NUM_LANES-1:0][NUM_PRED-1:0] pred_snap;
    logic                               gate_used, sb_hazard, fetch_oob, replay;
    logic                               op_is_mem, op_is_bar, op_is_exit;

    SK_decode u_decode (
        .insn_i (ifid_insn_q),
        .ctrl_o (ctrl)
    );

    // 门控：M 和 @p / @!p（SEL 的 pred 字段是操作数，不是门控）
    assign gate_used = (ctrl.op == SK_OP_ALU) || (ctrl.op == SK_OP_CMP)
                    || (ctrl.op == SK_OP_LOAD) || (ctrl.op == SK_OP_STORE)
                    || (ctrl.op == SK_OP_SHFL) || (ctrl.op == SK_OP_SREAD);

    always_comb begin
        m_snap = m_q[ifid_wid_q];
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            pred_snap[lane] = pred_q[ifid_wid_q][lane];
            gate_ok[lane]   = !gate_used || (ctrl.pred == 4'd0)
                            || (pred_snap[lane][ctrl.pred[2:0] - 3'd1] ^ ctrl.pinv);
            lane_act[lane]  = gate_ok[lane] && m_snap[lane];
        end
    end

    assign fetch_oob  = ifid_valid_q && ifid_oob_q;
    assign op_is_mem  = (ctrl.op == SK_OP_LOAD) || (ctrl.op == SK_OP_STORE);
    assign op_is_bar  = (ctrl.op == SK_OP_SYS) && (ctrl.func == SK_SYS_BAR);
    assign op_is_exit = (ctrl.op == SK_OP_SYS) && (ctrl.func == SK_SYS_EXIT);

    // 冒险都在这里查、查到就重发：读还在等的 load 目标、访存槽还占着、BAR/EXIT 前没排空
    assign replay = ifid_valid_q && !fetch_oob
                 && (sb_hazard
                     || (op_is_mem && warp_lsu_busy[ifid_wid_q])
                     || ((op_is_bar || op_is_exit) && warp_mem_wait[ifid_wid_q]));

    // --- 访存接口信号（LSU 实例在下面，scoreboard 和寄存器堆写口都要用）---
    logic                 lsu_push, lsu_fault, lsu_wb_we, lsu_flush;
    logic [3:0]           lsu_fault_code;
    logic [WARP_W-1:0]    lsu_fault_wid, lsu_wb_wid;
    logic [15:0]          lsu_fault_pc;
    logic [NUM_WARPS-1:0] lsu_done;
    logic                 lsu_wb_stall;
    logic [LANE_W-1:0]    lsu_wb_lane;
    logic [GPR_W-1:0]     lsu_wb_addr;
    logic [31:0]          lsu_wb_data;
    logic [NUM_LANES-1:0][31:0] lsu_wb_lanes;

    SK_scoreboard #(.WARPS(NUM_WARPS), .NUM_GPR(NUM_GPR)) u_scoreboard (
        .clk        (clk),
        .aresetn    (aresetn),
        .start_i    (start_pulse),
        .chk_valid_i(ifid_valid_q && !fetch_oob),
        .chk_wid_i  (ifid_wid_q),
        .chk_srcs_i (ctrl.srcs),
        .chk_wr_rd_i(ctrl.wr_rd),
        .chk_ra_i   (ctrl.ra[GPR_W-1:0]),
        .chk_rb_i   (ctrl.rb[GPR_W-1:0]),
        .chk_rd_i   (ctrl.rd[GPR_W-1:0]),
        .hazard_o   (sb_hazard),
        .set_valid_i(ifid_valid_q && !fetch_oob && !replay && (ctrl.op == SK_OP_LOAD)),
        .set_wid_i  (ifid_wid_q),
        .set_rd_i   (ctrl.rd[GPR_W-1:0]),
        .clear_i    (lsu_done),
        .busy_o     (warp_pend)
    );

    // --- 寄存器堆 ---
    logic [NUM_WARPS-1:0]                      rf_we;
    logic [NUM_WARPS-1:0][NUM_LANES-1:0]       rf_wlane;
    logic [NUM_WARPS-1:0][GPR_W-1:0]           rf_waddr;
    logic [NUM_WARPS-1:0][NUM_LANES-1:0][31:0] rf_wdata;
    logic                                      commit_wr;
    logic [31:0]                               gpr_dbg;

    SK_regfile #(.WARPS(NUM_WARPS), .LANES(NUM_LANES), .NUM_GPR(NUM_GPR)) u_regfile (
        .clk           (clk),
        .clear_i       (start_pulse),
        .we_i          (rf_we),
        .wlane_i       (rf_wlane),
        .waddr_i       (rf_waddr),
        .wdata_i       (rf_wdata),
        .rd_wid_i      (ifid_wid_q),
        .raddr_a_i     (ctrl.ra[GPR_W-1:0]),
        .rdata_a_o     (ra_val),
        .raddr_b_i     (ctrl.rb[GPR_W-1:0]),
        .rdata_b_o     (rb_val),
        .raddr_c_i     (ctrl.rd[GPR_W-1:0]),
        .rdata_c_o     (rc_val),
        .rd_wid_dbg_i  (dbg_wid_i),
        .rd_lane_dbg_i (dbg_lane_i),
        .raddr_dbg_i   (dbg_addr_i[4:0]),
        .rdata_dbg_o   (gpr_dbg)
    );

    // --- S3 → S4 ---
    logic                idex_valid_q;
    logic [WARP_W-1:0]   idex_wid_q;
    logic [15:0]         idex_pc_q;
    logic [31:0]         idex_insn_q;
    sk_exec_t            idex_ctrl_q;
    logic [NUM_LANES-1:0][31:0]         idex_ra_q, idex_rb_q, idex_rc_q;
    logic [NUM_LANES-1:0][31:0]         idex_b_q;    // ALU 的 B 操作数（立即数/寄存器选好）
    logic [NUM_LANES-1:0]               idex_act_q, idex_m_q;
    logic [NUM_LANES-1:0][NUM_PRED-1:0] idex_pred_q;

    // --- S4 执行 ---
    logic [NUM_LANES-1:0][31:0] alu_r, sreg_val, shfl_val;
    logic [NUM_LANES-1:0]       cmp_r, pred_sel, mask_pred_p;
    logic [31:0]                vote_val, mask_value;
    logic [NUM_LANES-1:0]       mask_m;
    logic                       mask_rd_we, mask_m_we;
    logic [15:0]                br_target;
    logic                       br_taken;
    logic [NUM_LANES-1:0][31:0] x_data;
    logic [NUM_LANES-1:0]       x_we, x_pred_we, x_pred_val, x_mask, x_m;
    logic [NUM_LANES-1:0][31:0] x_addr, x_wdata;
    logic                       x_warp_we, x_m_we, x_push, x_bar, x_exit;
    logic [15:0]                x_npc;
    logic [3:0]                 x_fault;

    generate
        for (genvar lane = 0; lane < NUM_LANES; lane++) begin : g_alu
            assign pred_sel[lane]  = idex_pred_q[lane][idex_ctrl_q.pred[2:0] - 3'd1];
            assign mask_pred_p[lane] = idex_pred_q[lane][idex_ctrl_q.rb[2:0]];
            SK_alu u_alu (
                .alu_op_i (idex_ctrl_q.alu_op),
                .cmp_op_i (idex_ctrl_q.cmp_op),
                .a_i      (idex_ra_q[lane]),
                // B 操作数在 S3 就选好了（立即数 vs 寄存器），这里直接从流水寄存器来，
                // 不然"选 B + 进 DSP + 出结果"这条路径会顶到 200 MHz 的天花板。
                .b_i      (idex_b_q[lane]),
                .acc_i    (idex_rc_q[lane]),
                .alu_o    (alu_r[lane]),
                .cmp_o    (cmp_r[lane])
            );
        end
    endgenerate

    // mask 指令的 GPR 操作数要求全 lane 一致：硬件取 lane 0 的读数据，不做检查
    SK_mask #(.LANES(NUM_LANES)) u_mask (
        .full_i  (FULL_MASK),
        .m_i     (idex_m_q),
        .op_i    (idex_ctrl_q.mask_op),
        .ra_i    (idex_ra_q[0]),
        .rb_i    (idex_rb_q[0]),
        .p_i     (mask_pred_p),
        .value_o (mask_value),
        .rd_we_o (mask_rd_we),
        .m_o     (mask_m),
        .m_we_o  (mask_m_we)
    );

    assign br_target = idex_pc_q + 16'd1 + idex_ctrl_q.off[15:0];

    always_comb begin
        br_taken = 1'b0;
        unique case (idex_ctrl_q.op)
            SK_OP_BRZ:  br_taken = (idex_ra_q[0] == 32'd0);
            SK_OP_BRNZ: br_taken = (idex_ra_q[0] != 32'd0);
            SK_OP_JMP:  br_taken = 1'b1;
            default: ;
        endcase
    end

    // 特殊寄存器：只有 LANEID / WID / TID 按 lane 或按 warp 算，其余全 lane 同值
    always_comb begin
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            unique case (idex_ctrl_q.sreg[3:0])
                SK_SREG_LANEID: sreg_val[lane] = 32'(lane);
                SK_SREG_WID:    sreg_val[lane] = 32'(idex_wid_q);
                SK_SREG_TID:    sreg_val[lane] = 32'(idex_wid_q) * sreg_i[SK_SREG_WARPSZ]
                                              + 32'(lane);
                default:        sreg_val[lane] = sreg_i[idex_ctrl_q.sreg[3:0]];
            endcase
        end
    end

    // SHFL：N×N 交换网络，读同拍旧值；越界或源 lane 不在 M 里返回自己的值（对齐 NV）
    always_comb begin
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            logic [63:0]       delta, src;
            logic              src_ok;
            logic [LANE_W-1:0] idx;

            delta = {32'd0, idex_rb_q[lane]};
            unique case (idex_ctrl_q.func)
                SK_SHFL_IDX:  begin src = delta % 64'(NUM_LANES); src_ok = 1'b1; end
                SK_SHFL_UP:   begin src = 64'(lane) - delta;
                                    src_ok = (64'(lane) >= delta);
                              end
                SK_SHFL_DOWN: begin src = 64'(lane) + delta;
                                    src_ok = (src < 64'(NUM_LANES));
                              end
                SK_SHFL_BFLY: begin src = 64'(lane) ^ delta;
                                    src_ok = (src < 64'(NUM_LANES));
                              end
                default:      begin src = 64'(lane); src_ok = 1'b0; end
            endcase
            idx = src_ok ? src[LANE_W-1:0] : LANE_W'(lane);
            shfl_val[lane] = (src_ok && idex_m_q[idx]) ? idex_ra_q[idx] : idex_ra_q[lane];
        end
    end

    // VOTE：M 内的 lane 做 OR/AND 归约，结果广播给所有 lane（写 GPR，直接接 BRZ/BRNZ）
    always_comb begin
        logic vote_any, vote_all;
        vote_any = 1'b0;
        vote_all = 1'b1;
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            vote_any |= idex_m_q[lane] & mask_pred_p[lane];
            vote_all &= ~(idex_m_q[lane] & ~mask_pred_p[lane]);   // M 为空也算 1
        end
        if (idex_ctrl_q.func == SK_VOTE_ALL) begin
            vote_val = {31'd0, vote_all};
        end else if (idex_ctrl_q.func == SK_VOTE_ANY) begin
            vote_val = {31'd0, vote_any};
        end else begin
            vote_val = 32'd0;
        end
    end

    // S4：算这条指令的写回值、下一条 PC、访存请求，以及它自己报的错
    always_comb begin
        x_data     = '0;
        x_we       = '0;
        x_warp_we  = 1'b0;
        x_pred_we  = '0;
        x_pred_val = '0;
        x_m        = mask_m;
        x_m_we     = 1'b0;
        x_push     = 1'b0;
        x_mask     = '0;
        x_bar      = 1'b0;
        x_exit     = 1'b0;
        x_npc      = idex_pc_q + 16'd1;
        x_fault    = SK_STATUS_OK;
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            x_addr[lane]  = idex_ra_q[lane] + idex_ctrl_q.imm;
            x_wdata[lane] = idex_rc_q[lane];
        end

        if (idex_valid_q) begin
            for (int lane = 0; lane < NUM_LANES; lane++) begin
                x_pred_val[lane] = cmp_r[lane];
            end

            unique case (idex_ctrl_q.op)
                SK_OP_ALU: begin
                    x_we = '1;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        x_data[lane] = alu_r[lane];
                    end
                end
                SK_OP_CMP: begin
                    x_pred_we = '1;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        unique case (idex_ctrl_q.bop)
                            SK_BOP_SET: x_pred_val[lane] = cmp_r[lane];
                            SK_BOP_AND: x_pred_val[lane] =
                                idex_pred_q[lane][idex_ctrl_q.rd[2:0]] & cmp_r[lane];
                            SK_BOP_OR:  x_pred_val[lane] =
                                idex_pred_q[lane][idex_ctrl_q.rd[2:0]] | cmp_r[lane];
                            SK_BOP_XOR: x_pred_val[lane] =
                                idex_pred_q[lane][idex_ctrl_q.rd[2:0]] ^ cmp_r[lane];
                            default:    x_pred_val[lane] = cmp_r[lane];
                        endcase
                    end
                end
                SK_OP_SEL: begin
                    x_we = '1;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        x_data[lane] = pred_sel[lane] ? idex_ra_q[lane] : idex_rb_q[lane];
                    end
                end
                SK_OP_LOAD, SK_OP_STORE: begin
                    x_push = 1'b1;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        x_mask[lane] = idex_act_q[lane];
                    end
                end
                SK_OP_MASK: begin
                    x_warp_we = mask_rd_we;                   // warp 级：不受 M 门控
                    x_m_we    = mask_m_we;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        x_data[lane] = mask_value;
                    end
                end
                SK_OP_BRZ, SK_OP_BRNZ, SK_OP_JMP: begin
                    if (br_taken) begin
                        x_npc = br_target;
                    end
                end
                SK_OP_SREAD: begin
                    x_we   = '1;
                    x_data = sreg_val;
                end
                SK_OP_SHFL: begin
                    x_we   = '1;
                    x_data = shfl_val;
                end
                SK_OP_VOTE: begin
                    x_warp_we = 1'b1;                         // 结果写所有 lane
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        x_data[lane] = vote_val;
                    end
                end
                SK_OP_SYS: begin
                    unique case (idex_ctrl_q.func)
                        SK_SYS_NOP: ;
                        SK_SYS_BAR: begin
                            x_bar = 1'b1;
                            if (idex_m_q != FULL_MASK) begin
                                x_fault = SK_STATUS_BAR_INCOMPLETE;
                            end
                        end
                        SK_SYS_EXIT: x_exit = 1'b1;
                        default: x_fault = SK_STATUS_BAD_INSN;
                    endcase
                end
                default: x_fault = SK_STATUS_BAD_INSN;
            endcase

            // 普通指令按 M & @p 逐 lane 门控；warp 级指令（VOTE / mask 指令）不门控
            for (int lane = 0; lane < NUM_LANES; lane++) begin
                x_we[lane]      = x_we[lane] && idex_act_q[lane];
                x_pred_we[lane] = x_pred_we[lane] && idex_act_q[lane];
            end
        end
    end

    // --- S4 → S5 ---
    logic                exwb_valid_q;
    logic [WARP_W-1:0]   exwb_wid_q;
    logic [GPR_W-1:0]    exwb_rd_q;        // 目的寄存器（也当谓词号用）
    logic [NUM_LANES-1:0][31:0]         exwb_data_q;
    logic [NUM_LANES-1:0]               exwb_we_q, exwb_pred_we_q, exwb_pred_val_q, exwb_m_q;
    logic                               exwb_warp_we_q, exwb_m_we_q, exwb_bar_q, exwb_exit_q;
    logic [15:0]                        exwb_npc_q;
    logic [3:0]                         exwb_fault_q;

    SK_lsu #(.WARPS(NUM_WARPS), .LANES(NUM_LANES), .GPR_W(GPR_W)) u_lsu (
        .clk           (clk),
        .aresetn       (aresetn),
        .push_i        (lsu_push),
        .push_wid_i    (idex_wid_q),
        .push_store_i  (idex_ctrl_q.op == SK_OP_STORE),
        .push_global_i (idex_ctrl_q.mem_global),
        .push_rd_i     (idex_ctrl_q.rd[GPR_W-1:0]),
        .push_pc_i     (idex_pc_q),
        .push_addr_i   (x_addr),
        .push_wdata_i  (x_wdata),
        .push_mask_i   (x_mask),
        .busy_o        (warp_lsu_busy),
        .done_o        (lsu_done),
        .wb_we_o       (lsu_wb_we),
        .wb_wid_o      (lsu_wb_wid),
        .wb_lane_o     (lsu_wb_lane),
        .wb_addr_o     (lsu_wb_addr),
        .wb_data_o     (lsu_wb_data),
        .wb_stall_i    (lsu_wb_stall),
        .fault_o       (lsu_fault),
        .fault_code_o  (lsu_fault_code),
        .fault_wid_o   (lsu_fault_wid),
        .fault_pc_o    (lsu_fault_pc),
        .flush_i       (lsu_flush),
        .smem_addr_o   (smem_addr_o),
        .smem_wdata_o  (smem_wdata_o),
        .smem_we_o     (smem_we_o),
        .smem_rdata_i  (smem_rdata_i),
        .smem_fault_i  (smem_fault_i),
        .gmem_addr_o   (gmem_addr_o),
        .gmem_wdata_o  (gmem_wdata_o),
        .gmem_we_o     (gmem_we_o),
        .gmem_rdata_i  (gmem_rdata_i),
        .gmem_fault_i  (gmem_fault_i)
    );

    // --- 寄存器堆写口：流水线提交（优先）和 LSU 回写 ---
    // 两条写撞在同一个 warp 上时让 LSU 等一拍（`lsu_wb_stall`），一个写口就够。
    always_comb begin
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            lsu_wb_lanes[lane] = (LANE_W'(lane) == lsu_wb_lane) ? lsu_wb_data : 32'd0;
        end
        for (int warp = 0; warp < NUM_WARPS; warp++) begin
            rf_we[warp]    = 1'b0;
            rf_wlane[warp] = '0;
            rf_waddr[warp] = '0;
            rf_wdata[warp] = '0;
            if (commit_wr && (exwb_wid_q == WARP_W'(warp))) begin
                rf_we[warp]    = 1'b1;
                rf_wlane[warp] = exwb_warp_we_q ? '1 : exwb_we_q;
                rf_waddr[warp] = exwb_rd_q;
                rf_wdata[warp] = exwb_data_q;
            end else if (lsu_wb_we && !lsu_flush && (lsu_wb_wid == WARP_W'(warp))) begin
                rf_we[warp]    = 1'b1;
                rf_wlane[warp] = NUM_LANES'(1) << lsu_wb_lane;
                rf_waddr[warp] = lsu_wb_addr;
                rf_wdata[warp] = lsu_wb_lanes;
            end
        end
    end

    // --- 出错 / 结束 ---
    logic       commit_bar, commit_exit, all_done, mem_fault, stop_now;
    logic [3:0] stop_status, commit_fault;

    assign commit_fault = exwb_valid_q ? exwb_fault_q : SK_STATUS_OK;
    assign mem_fault    = lsu_fault;
    assign stop_now     = mem_fault || fetch_oob || (commit_fault != SK_STATUS_OK);
    assign stop_status  = mem_fault ? lsu_fault_code
                       : (fetch_oob ? SK_STATUS_PC_OOB : commit_fault);
    assign commit_bar   = exwb_valid_q && exwb_bar_q && (exwb_fault_q == SK_STATUS_OK);
    assign commit_exit  = exwb_valid_q && exwb_exit_q && (exwb_fault_q == SK_STATUS_OK);
    assign all_done     = ((warp_run | warp_bar) == '0);

    assign commit_wr    = exwb_valid_q && (exwb_fault_q == SK_STATUS_OK)
                       && (exwb_warp_we_q || (|exwb_we_q));
    assign lsu_wb_stall = commit_wr && (exwb_wid_q == lsu_wb_wid);
    assign lsu_push     = idex_valid_q && !lsu_flush && x_push;
    assign lsu_flush    = stop_now || start_pulse;

    generate
        for (genvar warp = 0; warp < NUM_WARPS; warp++) begin : g_events
            assign arrive_bar[warp] = commit_bar && (exwb_wid_q == WARP_W'(warp));
            assign exit_warp[warp]  = commit_exit && (exwb_wid_q == WARP_W'(warp));
        end
    endgenerate

    // --- 性能计数器 ---
    logic [31:0] perf_data;
    logic        no_run_warp;

    // 一条 RUN 状态的 warp 都没有：都在 BAR 上等 / 已经 EXIT。计数器只在 S_RUN 累加，
    // 所以这里不带状态判断。
    assign no_run_warp = (warp_run == '0);

    SK_perf u_perf (
        .clk        (clk),
        .aresetn    (aresetn),
        .start_i    (start_pulse),
        .run_i      (state_q == S_RUN),
        .issued_i   (issue_valid),
        .retired_i  (exwb_valid_q),
        .replay_i   (replay),
        .barrier_i  (bar_release),
        .no_warp_i  (no_run_warp),
        .lsu_busy_i (|warp_lsu_busy),
        .addr_i     (dbg_addr_i[3:0]),
        .data_o     (perf_data)
    );

    assign status_o = status_q;
    assign done_o   = (state_q == S_DONE);

    // --- 顺序逻辑 ---
    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q      <= S_IDLE;
            status_q     <= SK_STATUS_OK;
            trap_valid_q <= 1'b0;
            warp_busy    <= '0;
            warp_wait    <= '0;
            f1_valid_q   <= 1'b0;
            ifid_valid_q <= 1'b0;
            idex_valid_q <= 1'b0;
            exwb_valid_q <= 1'b0;
            for (int warp = 0; warp < NUM_WARPS; warp++) begin
                pc_q[warp]   <= 16'd0;
                m_q[warp]    <= FULL_MASK;
                for (int lane = 0; lane < NUM_LANES; lane++) begin
                    pred_q[warp][lane] <= '0;
                end
            end
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (start_i) begin
                        trap_valid_q <= 1'b0;
                        // 调度器的"在途/等排空"标志也一起清：留下 stale 的 busy 位，
                        // 这条 warp 就因为 ready 要求 !busy 而永远发不出去（grid>1、
                        // 出错停机后重启都会踩到）。
                        warp_busy <= '0;
                        warp_wait <= '0;
                        if (launch_bad) begin
                            state_q  <= S_DONE;
                            status_q <= SK_STATUS_BAD_LAUNCH;
                        end else begin
                            state_q      <= S_RUN;
                            status_q     <= SK_STATUS_OK;
                            f1_valid_q   <= 1'b0;
                            ifid_valid_q <= 1'b0;
                            idex_valid_q <= 1'b0;
                            exwb_valid_q <= 1'b0;
                            for (int warp = 0; warp < NUM_WARPS; warp++) begin
                                pc_q[warp]   <= 16'd0;
                                m_q[warp]    <= FULL_MASK;
                                for (int lane = 0; lane < NUM_LANES; lane++) begin
                                    pred_q[warp][lane] <= '0;
                                end
                            end
                        end
                    end
                end
                S_RUN: begin
                    if (stop_now) begin
                        status_q     <= stop_status;
                        state_q      <= S_DONE;
                        // trap 是错误路径的契约：记下哪条 warp 停在哪个 PC。访存出错的
                        // 那条指令没提交过，PC 记它的下一条；取指越界停在取不到的地址上
                        // （黄金模型也是这个语义，见 docs/design.md §5.5）。
                        trap_valid_q <= 1'b1;
                        if (mem_fault) begin
                            trap_wid_q <= lsu_fault_wid;
                            trap_pc_q  <= lsu_fault_pc + 16'd1;
                        end else if (fetch_oob) begin
                            trap_wid_q <= ifid_wid_q;
                            trap_pc_q  <= ifid_pc_q;
                        end else begin
                            trap_wid_q <= exwb_wid_q;
                            trap_pc_q  <= exwb_npc_q;
                        end
                        f1_valid_q   <= 1'b0;
                        ifid_valid_q <= 1'b0;
                        idex_valid_q <= 1'b0;
                        exwb_valid_q <= 1'b0;
                    end else begin
                        // S1 → 取指请求（下一拍给 BRAM 出地址）
                        f1_valid_q <= issue_valid;
                        f1_wid_q   <= issue_wid;
                        f1_pc_q    <= fetch_pc;

                        // 取指请求的延迟副本：和 BRAM 这一拍吐出来的指令对齐
                        f2_valid_q <= f1_valid_q;
                        f2_wid_q   <= f1_wid_q;
                        f2_pc_q    <= f1_pc_q;

                        // S2 → S3：BRAM 出的是 f2 那条指令，PC 和它一起进 IF/ID
                        ifid_valid_q <= f2_valid_q;
                        ifid_wid_q   <= f2_wid_q;
                        ifid_pc_q    <= f2_pc_q;
                        ifid_insn_q  <= insn_f;
                        ifid_oob_q   <= pc_oob_f;

                        // S2 → S3：译码级发现冒险就丢成空泡，warp 的 PC 回退去重发
                        idex_valid_q <= ifid_valid_q && !replay;
                        idex_wid_q   <= ifid_wid_q;
                        idex_pc_q    <= ifid_pc_q;
                        idex_insn_q  <= ifid_insn_q;
                        // 只把执行级要用的字段带过去（译码级的 ra/门控/scoreboard 字段留在 S3）
                        idex_ctrl_q  <= '{
                            op: ctrl.op, alu_op: ctrl.alu_op, cmp_op: ctrl.cmp_op,
                            mask_op: ctrl.mask_op, bop: ctrl.bop, rd: ctrl.rd, rb: ctrl.rb,
                            pred: ctrl.pred, func: ctrl.func, sreg: ctrl.sreg,
                            mem_global: ctrl.mem_global, imm: ctrl.imm, off: ctrl.off
                        };
                        idex_ra_q    <= ra_val;
                        idex_rb_q    <= rb_val;
                        idex_rc_q    <= rc_val;
                        for (int lane = 0; lane < NUM_LANES; lane++) begin
                            idex_b_q[lane] <= ctrl.imm_sel ? ctrl.imm : rb_val[lane];
                        end
                        idex_act_q   <= lane_act;
                        idex_m_q     <= m_snap;
                        idex_pred_q  <= pred_snap;

                        // S3 → S4
                        exwb_valid_q    <= idex_valid_q;
                        exwb_wid_q      <= idex_wid_q;
                        exwb_rd_q       <= idex_ctrl_q.rd[GPR_W-1:0];
                        exwb_data_q     <= x_data;
                        exwb_we_q       <= x_we;
                        exwb_warp_we_q  <= x_warp_we;
                        exwb_pred_val_q <= x_pred_val;
                        exwb_pred_we_q  <= x_pred_we;
                        exwb_m_q        <= x_m;
                        exwb_m_we_q     <= x_m_we;
                        exwb_npc_q      <= x_npc;
                        exwb_fault_q    <= x_fault;
                        exwb_bar_q      <= x_bar;
                        exwb_exit_q     <= x_exit;

                        // 取指 PC 的三件事各改各的 warp，不能写成全局 if/else：
                        // 别的 warp 在发射时，重发的那条也必须把 PC 回退。
                        for (int warp = 0; warp < NUM_WARPS; warp++) begin
                            if (replay && (ifid_wid_q == WARP_W'(warp))) begin
                                pc_q[warp] <= ifid_pc_q;               // 重发：PC 退回去
                            end else if (issue_valid && (issue_wid == WARP_W'(warp))) begin
                                pc_q[warp] <= pc_q[warp] + 16'd1;      // 发射：顺序取下一条
                            end
                            // 分支在 S4 解析（这条 warp 还在流水里，不会同时发射或重发）
                            if (idex_valid_q && br_taken && (idex_wid_q == WARP_W'(warp))) begin
                                pc_q[warp] <= br_target;
                            end
                        end

                        // S5 提交：写谓词、写 M（寄存器堆写口在组合逻辑里）
                        if (exwb_valid_q) begin
                            if (exwb_fault_q != SK_STATUS_OK) begin
                                status_q <= exwb_fault_q;
                                state_q  <= S_DONE;
                            end else begin
                                for (int lane = 0; lane < NUM_LANES; lane++) begin
                                    if (exwb_pred_we_q[lane]) begin
                                        pred_q[exwb_wid_q][lane][exwb_rd_q[2:0]]
                                            <= exwb_pred_val_q[lane];
                                    end
                                end
                                if (exwb_m_we_q) begin
                                    m_q[exwb_wid_q] <= exwb_m_q;
                                end
                            end
                        end

                        // 所有 warp 都结束：整台核收工
                        if (all_done) begin
                            state_q <= S_DONE;
                        end
                    end

                    // warp 在途标志：发射时置起，走到 S4 就放开（下一拍可以再发）。
                    // BAR / EXIT 例外：它们要到提交（S5）才改 warp 状态，在那之前不能
                    // 让 warp 再发一条——EXIT 后面那条 PC 已经越过程序末尾，会假报
                    // PC_OOB，把还在跑的其它 warp 一起带走。
                    for (int warp = 0; warp < NUM_WARPS; warp++) begin
                        if (issue_valid && (issue_wid == WARP_W'(warp))) begin
                            warp_busy[warp] <= 1'b1;
                        end else if ((idex_valid_q && (idex_wid_q == WARP_W'(warp))
                                      && !(x_bar || x_exit))
                                  || (exwb_valid_q && (exwb_bar_q || exwb_exit_q)
                                      && (exwb_wid_q == WARP_W'(warp)))
                                  || (replay && (ifid_wid_q == WARP_W'(warp)))) begin
                            warp_busy[warp] <= 1'b0;
                        end
                        // 重发之后先等自己的访存排空，免得反复占着发射口空转
                        if (replay && (ifid_wid_q == WARP_W'(warp))) begin
                            warp_wait[warp] <= 1'b1;
                        end else if (!warp_mem_wait[warp]) begin
                            warp_wait[warp] <= 1'b0;
                        end
                    end
                end
                default: ;                             // S_DONE：保持
            endcase
        end
    end

    // --- 调试扫描口（仿真用）---
    always_comb begin
        unique case (dbg_addr_i)
            8'h20:   dbg_data_o = 32'(m_q[dbg_wid_i]);
            8'h21:   dbg_data_o = 32'(pred_q[dbg_wid_i][dbg_lane_i]);
            8'h22:   dbg_data_o = {16'd0, pc_q[dbg_wid_i]};
            8'h23:   dbg_data_o = {28'd0, status_q};
            8'h24:   dbg_data_o = idex_insn_q;
            8'h25:   dbg_data_o = {30'd0, done_o, (state_q == S_RUN)};
            8'h26:   dbg_data_o = {16'd0, idex_pc_q};
            8'h27:   dbg_data_o = {30'd0, warp_state[dbg_wid_i]};
            8'h28:   dbg_data_o = {29'd0, idex_valid_q, idex_wid_q};
            8'h29:   dbg_data_o = {31'd0, trap_valid_q};
            8'h2A:   dbg_data_o = {30'd0, trap_wid_q};
            8'h2B:   dbg_data_o = {16'd0, trap_pc_q};
            default: dbg_data_o = (dbg_addr_i >= 8'h30) ? perf_data
                                 : ((dbg_addr_i < 8'd32) ? gpr_dbg : 32'd0);
        endcase
    end

endmodule
