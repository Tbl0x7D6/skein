//! P1 的核：1 warp × 1 lane，2 级流水（取指 / 译码+执行+写回）。
//!
//! 取指用 BRAM，所以指令在地址给出后下一拍才到执行级：`pc_q` 是取指地址，`insn_f`
//! 就是执行级的指令（它的 PC 是上一拍的 `pc_q`，存在 `pc_e_q` 里）。统一分支在执行级
//! 解析：命中就重定向并把在途的取指丢掉（一个空泡）。因为写回在同一个时钟沿落进寄存器堆，
//! 下一条指令读到的就是新值，不需要前递；没有 scoreboard，访存是阻塞式的。
//!
//! 架构状态（PC、GPR、谓词、M）在块开始时清零，和黄金模型逐寄存器对拍。
//! 5 级流水和 N lane 分别在 P3、P2 展开（见 docs/plan.md）。

`include "SK_config.vh"

module SK_core #(
    parameter int NUM_GPR    = `SK_NUM_GPR,
    parameter int NUM_PRED   = `SK_NUM_PRED,
    parameter int IMEM_DEPTH = (`SK_IMEM_KB * 1024) / 4
) (
    input  logic                              clk,
    input  logic                              aresetn,        // 同步复位，低有效
    input  logic                              start_i,        // 启动脉冲（P6 接 CTRL.start）
    // 特殊寄存器（P1 由 testbench 驱动；P6 接 AXI-Lite 控制寄存器）
    input  logic [31:0]                       sreg_i [16],
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
    // 调试扫描口（仿真用）：0x00-0x1F = GPR，0x20 = M，0x21 = 谓词，
    // 0x22 = E 阶段 PC，0x23 = STATUS，0x24 = E 阶段指令，0x25 = {done, E 有效}，
    // 0x26 = 架构 PC
    input  logic [7:0]                        dbg_addr_i,
    output logic [31:0]                       dbg_data_o
);

    import SK_pkg::*;

    localparam logic FULL_MASK = 1'b1;         // 1 lane：完整 mask 就是 1 位

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_e;

    // 状态寄存器
    state_e      state_q;
    logic [15:0] pc_q;        // 取指地址
    logic [15:0] pc_e_q;      // 执行级指令的 PC
    logic [15:0] pc_a_q;      // 架构 PC（黄金模型的 pc）
    logic        e_valid_q;   // 执行级的指令有效（不是空泡）
    logic [NUM_PRED-1:0] pred_q;   // 每 lane 谓词：p0..p7
    logic [3:0]  status_q;
    logic        start_pulse;

    // 取指 / 译码
    logic [31:0] insn_f;
    logic        pc_oob_f;
    logic [31:0] gpr_dbg;
    sk_ctrl_t    ctrl;

    // 门控
    logic        ex_valid, gate_used, gate_ok, lane_act;
    logic [2:0]  gate_idx;

    // 寄存器堆
    logic [31:0] ra_val, rb_val, rc_val;
    logic [31:0] gpr_wdata;
    logic        gpr_we;
    logic [4:0]  gpr_waddr;

    // 算术 / 比较
    logic [31:0] b_operand, alu_r;
    logic        cmp_r;

    // mask 单元
    logic        m_q, mask_rd_we, pred_p;
    logic [31:0] mask_rd;

    // 访存
    logic [31:0] lsu_addr, lsu_wdata, lsu_rdata;
    logic [3:0]  lsu_fault;
    logic        mem_active;

    // 执行级
    logic [15:0] npc_fetch, npc_arch;
    logic        squash, halt;
    logic [3:0]  fault;
    logic [31:0] wb_data, vote_val, sreg_val;
    logic        wb_en, wb_en_warp, pred_we, pred_wr_val, pred_sel;

    assign start_pulse = (state_q == S_IDLE) && start_i;

    SK_imem #(.DEPTH(IMEM_DEPTH)) u_imem (
        .clk       (clk),
        .pc_i      (pc_q),
        .insn_o    (insn_f),
        .pc_oob_o  (pc_oob_f),
        .ld_we_i   (imem_we_i),
        .ld_addr_i (imem_addr_i),
        .ld_wdata_i(imem_wdata_i)
    );

    SK_decode u_decode (
        .insn_i (insn_f),
        .ctrl_o (ctrl)
    );

    // --- 门控：M 和 @p / @!p（SEL 的 pred 字段是操作数，不是门控）---
    // 取指越界时指令无效：和黄金模型一样，先报 PC_OOB、什么都不执行
    assign ex_valid  = e_valid_q && !pc_oob_f;
    assign gate_used = (ctrl.op == SK_OP_ALU) || (ctrl.op == SK_OP_CMP)
                    || (ctrl.op == SK_OP_LOAD) || (ctrl.op == SK_OP_STORE)
                    || (ctrl.op == SK_OP_SHFL) || (ctrl.op == SK_OP_SREAD);
    assign gate_idx  = ctrl.pred[2:0] - 3'd1;
    assign gate_ok   = !gate_used || (ctrl.pred == 4'd0) || (pred_q[gate_idx] ^ ctrl.pinv);
    assign lane_act  = ex_valid && m_q && gate_ok;

    SK_regfile #(.NUM_GPR(NUM_GPR), .WIDTH(32)) u_regfile (
        .clk        (clk),
        .clear_i    (start_pulse),
        .we_i       (gpr_we),
        .waddr_i    (gpr_waddr),
        .wdata_i    (gpr_wdata),
        .raddr_a_i  (ctrl.ra),
        .rdata_a_o  (ra_val),
        .raddr_b_i  (ctrl.rb),
        .rdata_b_o  (rb_val),
        .raddr_c_i  (ctrl.rd),
        .rdata_c_o  (rc_val),
        .raddr_dbg_i(dbg_addr_i[4:0]),
        .rdata_dbg_o(gpr_dbg)
    );

    assign b_operand = ctrl.imm_sel ? ctrl.imm : rb_val;

    SK_alu u_alu (
        .alu_op_i (ctrl.alu_op),
        .cmp_op_i (ctrl.cmp_op),
        .a_i      (ra_val),
        .b_i      (b_operand),
        .acc_i    (rc_val),
        .alu_o    (alu_r),
        .cmp_o    (cmp_r)
    );

    assign pred_p = pred_q[ctrl.rb[2:0]];      // `.P`/`.PM`/`MCLR.P` 的谓词号在 rb 字段

    SK_mask u_mask (
        .clk     (clk),
        .aresetn (aresetn),
        .init_i  (start_pulse),
        .full_i  (FULL_MASK),
        .en_i    (ex_valid && (ctrl.op == SK_OP_MASK)),
        .op_i    (ctrl.mask_op),
        .ra_i    (ra_val),
        .rb_i    (rb_val),
        .p_i     (pred_p),
        .m_o     (m_q),
        .rd_o    (mask_rd),
        .rd_we_o (mask_rd_we)
    );

    assign mem_active = lane_act && (ctrl.op == SK_OP_LOAD || ctrl.op == SK_OP_STORE);

    SK_lsu u_lsu (
        .op_en_i     (mem_active),
        .store_i     (ctrl.op == SK_OP_STORE),
        .global_i    (ctrl.mem_global),
        .base_i      (ra_val),
        .imm_i       (ctrl.imm),
        .wdata_i     (rc_val),                 // STORE 的源寄存器在 rd 字段
        .smem_rdata_i(smem_rdata_i),
        .smem_fault_i(smem_fault_i),
        .gmem_rdata_i(gmem_rdata_i),
        .gmem_fault_i(gmem_fault_i),
        .addr_o      (lsu_addr),
        .wdata_o     (lsu_wdata),
        .smem_we_o   (smem_we_o),
        .gmem_we_o   (gmem_we_o),
        .rdata_o     (lsu_rdata),
        .fault_o     (lsu_fault)
    );

    assign smem_addr_o  = lsu_addr;
    assign smem_wdata_o = lsu_wdata;
    assign gmem_addr_o  = lsu_addr;
    assign gmem_wdata_o = lsu_wdata;

    // --- 执行级：写回、分支、结束 ---
    assign sreg_val = sreg_i[ctrl.sreg[3:0]];              // 编号上限由译码保证
    assign pred_sel = pred_q[ctrl.pred[2:0] - 3'd1];        // SEL 的操作数谓词

    always_comb begin
        unique case (ctrl.func)
            SK_VOTE_ANY: vote_val = {31'd0, (m_q & pred_p)};        // M 里有一个满足
            SK_VOTE_ALL: vote_val = {31'd0, ~(m_q & ~pred_p)};      // M 里全满足
            default:     vote_val = 32'd0;
        endcase
    end

    always_comb begin
        npc_fetch    = pc_q + 16'd1;         // 顺序取指
        npc_arch     = pc_e_q + 16'd1;       // 架构 PC：下一条指令
        squash       = 1'b0;
        halt         = 1'b0;
        fault        = SK_STATUS_OK;
        wb_data      = alu_r;
        wb_en        = 1'b0;
        wb_en_warp   = 1'b0;
        pred_we      = 1'b0;
        pred_wr_val  = cmp_r;

        if (e_valid_q && pc_oob_f) begin
            fault = SK_STATUS_PC_OOB;                         // 取指越界，指令不执行
        end else if (ex_valid) begin
            unique case (ctrl.op)
                SK_OP_ALU: begin
                    wb_en   = 1'b1;
                    wb_data = alu_r;
                end
                SK_OP_CMP: begin
                    pred_we = 1'b1;
                    unique case (ctrl.bop)
                        SK_BOP_SET: pred_wr_val = cmp_r;
                        SK_BOP_AND: pred_wr_val = pred_q[ctrl.rd[2:0]] & cmp_r;
                        SK_BOP_OR:  pred_wr_val = pred_q[ctrl.rd[2:0]] | cmp_r;
                        SK_BOP_XOR: pred_wr_val = pred_q[ctrl.rd[2:0]] ^ cmp_r;
                        default:    pred_wr_val = cmp_r;
                    endcase
                end
                SK_OP_SEL: begin
                    wb_en   = 1'b1;
                    wb_data = pred_sel ? ra_val : rb_val;
                end
                SK_OP_LOAD: begin
                    wb_en   = 1'b1;
                    wb_data = lsu_rdata;
                end
                SK_OP_STORE: ;                                    // 只写内存
                SK_OP_MASK: begin
                    wb_en_warp = mask_rd_we;                      // warp 级：不受 M 门控
                    wb_data    = mask_rd;
                end
                SK_OP_BRZ: if (ra_val == 32'd0) begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;                             // 丢掉在途的取指
                end
                SK_OP_BRNZ: if (ra_val != 32'd0) begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;
                end
                SK_OP_JMP: begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;
                end
                SK_OP_SREAD: begin
                    wb_en   = 1'b1;
                    wb_data = sreg_val;
                end
                SK_OP_SYS: begin
                    unique case (ctrl.func)
                        SK_SYS_NOP: ;
                        SK_SYS_BAR: if (m_q != FULL_MASK) fault = SK_STATUS_BAR_INCOMPLETE;
                        SK_SYS_EXIT: begin
                            halt   = 1'b1;
                            squash = 1'b1;
                        end
                        default: ;
                    endcase
                end
                SK_OP_SHFL: begin
                    // 1 lane：源 lane 恒为自己（越界也返回自己的值）
                    wb_en   = 1'b1;
                    wb_data = ra_val;
                end
                SK_OP_VOTE: begin
                    wb_en_warp = 1'b1;                            // 结果写所有 lane
                    wb_data    = vote_val;
                end
                default: fault = SK_STATUS_BAD_INSN;
            endcase

            if (fault == SK_STATUS_OK) begin
                fault = lsu_fault;
            end
        end
    end

    // 报错的指令不写回（访存出错时读出来的数据没有意义，和黄金模型一致）
    assign gpr_we      = ((wb_en && lane_act) || (wb_en_warp && ex_valid))
                       && (fault == SK_STATUS_OK);
    assign gpr_waddr   = ctrl.rd;
    assign gpr_wdata   = wb_data;
    assign status_o    = status_q;
    assign done_o      = (state_q == S_DONE);

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q   <= S_IDLE;
            pc_q      <= 16'd0;
            pc_e_q    <= 16'd0;
            pc_a_q    <= 16'd0;
            e_valid_q <= 1'b0;
            pred_q    <= 8'd0;
            status_q  <= SK_STATUS_OK;
        end else begin
            case (state_q)
                S_IDLE: begin
                    if (start_i) begin
                        state_q   <= S_RUN;
                        pc_q      <= 16'd0;
                        pc_e_q    <= 16'd0;
                        pc_a_q    <= 16'd0;
                        e_valid_q <= 1'b0;
                        pred_q    <= 8'd0;
                        status_q  <= SK_STATUS_OK;
                    end
                end
                S_RUN: begin
                    pc_q   <= npc_fetch;
                    pc_e_q <= pc_q;
                    if (e_valid_q) begin
                        // 取指越界时黄金模型不推进 PC，这里保持一致
                        pc_a_q <= (fault == SK_STATUS_PC_OOB) ? pc_e_q : npc_arch;
                    end
                    if (pred_we && lane_act) begin
                        pred_q[ctrl.rd[2:0]] <= pred_wr_val;
                    end
                    if (!e_valid_q) begin
                        e_valid_q <= 1'b1;                        // 空泡之后恢复
                    end else if (fault != SK_STATUS_OK) begin
                        status_q  <= fault;
                        state_q   <= S_DONE;
                        e_valid_q <= 1'b0;
                    end else if (halt) begin
                        state_q   <= S_DONE;
                        e_valid_q <= 1'b0;
                    end else begin
                        e_valid_q <= ~squash;
                    end
                end
                default: ;                                        // S_DONE：保持
            endcase
        end
    end

    // --- 调试扫描口（仿真用）---
    always_comb begin
        unique case (dbg_addr_i)
            8'h20:   dbg_data_o = {31'd0, m_q};
            8'h21:   dbg_data_o = {24'd0, pred_q};
            8'h22:   dbg_data_o = {16'd0, pc_e_q};
            8'h23:   dbg_data_o = {28'd0, status_q};
            8'h24:   dbg_data_o = insn_f;
            8'h25:   dbg_data_o = {30'd0, done_o, e_valid_q};
            8'h26:   dbg_data_o = {16'd0, pc_a_q};
            default: dbg_data_o = (dbg_addr_i < 8'd32) ? gpr_dbg : 32'd0;
        endcase
    end

endmodule
