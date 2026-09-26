//! P2 的核：1 warp × `SK_NUM_LANES` lane，2 级流水（取指 / 译码+执行+写回）。
//!
//! 取指用 BRAM，所以指令在地址给出后下一拍才到执行级：`pc_q` 是取指地址，`insn_f`
//! 就是执行级的指令（它的 PC 是上一拍的 `pc_q`，存在 `pc_e_q` 里）。统一分支在执行级
//! 解析：命中就重定向并把在途的取指丢掉（一个空泡）。没有 scoreboard，访存是阻塞式的。
//!
//! 多 lane：每个 lane 一套 GPR 和谓词，共享 PC 和执行 mask `M`。有效 lane 是
//! `M & @p`，写回、访存、谓词写都按 lane 门控；写回端口是 per-lane 的，所以 `VOTE`/
//! `MASK` 这类 warp 级指令显式写所有 lane，`SHFL` 走 N×N 交换网络。
//!
//! 访存是多周期的：一条 `LDS/STS/LDG/STG` 占 `SK_NUM_LANES` 拍，按 lane 0→N-1 顺序
//! 每拍服务一条 lane（没有 active lane 也照走），期间冻结取指和执行级寄存器，不会重发。
//! 读出的数据在当前 lane 那一拍落进它的寄存器堆；某条 lane 非对齐/越界就立刻停下这条
//! 指令——出错 lane 之前已经提交的 lane 不回滚，这是实现行为不是架构契约（design.md §5.5）。
//!
//! 架构状态（PC、GPR、谓词、M）在块开始时清零，和黄金模型逐寄存器对拍。
//! 多 warp 调度和 5 级流水分别在 P3 展开（见 docs/plan.md）。

`include "SK_config.vh"

module SK_core #(
    parameter int NUM_LANES  = `SK_NUM_LANES,
    parameter int NUM_WARPS  = `SK_NUM_WARPS,
    parameter int NUM_GPR    = `SK_NUM_GPR,
    parameter int NUM_PRED   = `SK_NUM_PRED,
    parameter int IMEM_DEPTH = (`SK_IMEM_KB * 1024) / 4
) (
    input  logic                              clk,
    input  logic                              aresetn,        // 同步复位，低有效
    input  logic                              start_i,        // 启动脉冲（P6 接 CTRL.start）
    // 特殊寄存器（P2 由 testbench 驱动；P6 接 AXI-Lite 控制寄存器）
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
    // 调试扫描口（仿真用）：0x00-0x1F = 选中 lane 的 GPR，0x20 = M，0x21 = 谓词，
    // 0x22 = E 阶段 PC，0x23 = STATUS，0x24 = E 阶段指令，0x25 = {done, E 有效}，
    // 0x26 = 架构 PC；lane 由 dbg_lane_i 选
    input  logic [7:0]                        dbg_addr_i,
    input  logic [$clog2(NUM_LANES)-1:0]      dbg_lane_i,
    output logic [31:0]                       dbg_data_o
);

    import SK_pkg::*;

    localparam int  LANE_W = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 1;
    localparam logic [NUM_LANES-1:0] FULL_MASK = '1;   // 没有部分 warp：完整 mask 就是全 lane
    localparam logic [LANE_W-1:0]    LANE_LAST = LANE_W'(NUM_LANES - 1);

    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_e;

    // 状态寄存器
    state_e      state_q;
    logic [15:0] pc_q;        // 取指地址
    logic [15:0] pc_e_q;      // 执行级指令的 PC
    logic [15:0] pc_a_q;      // 架构 PC（黄金模型的 pc）
    logic        e_valid_q;   // 执行级的指令有效（不是空泡）
    logic [NUM_PRED-1:0] pred_q [NUM_LANES];   // 每 lane 谓词：p0..p7
    logic [3:0]  status_q;
    logic        start_pulse;

    // 取指 / 译码
    logic [31:0] insn_f;
    logic        pc_oob_f;
    logic [31:0] gpr_dbg;
    sk_ctrl_t    ctrl;

    // 执行级：多周期访存期间冻住这条指令的译码结果（取指口这时已经在读下一条指令了）
    sk_ctrl_t    ctrl_e_q;
    logic [31:0] insn_e_q;
    sk_ctrl_t    ctrl_e;
    logic [31:0] insn_e;

    // 门控
    logic                 ex_valid, fetch_oob_e, gate_used;
    logic [NUM_LANES-1:0] gate_ok, lane_act;
    logic [2:0]           gate_idx, pred_idx;

    // 寄存器堆
    logic [NUM_LANES-1:0][31:0] ra_val, rb_val, rc_val;
    logic [NUM_LANES-1:0][31:0] gpr_wdata;
    logic [NUM_LANES-1:0]       gpr_we;
    logic [4:0]                 gpr_waddr;

    // 算术 / 比较
    logic [NUM_LANES-1:0][31:0] b_operand, alu_r;
    logic [NUM_LANES-1:0]       cmp_r, pred_sel, pred_wr_val, pred_we;

    // mask 单元
    logic [NUM_LANES-1:0] m_q, pred_p;
    logic                 mask_rd_we;
    logic [31:0]          mask_rd;

    // 访存
    logic [31:0]          lsu_addr, lsu_wdata, lsu_rdata;
    logic [3:0]           lsu_fault;
    logic                 mem_op, mem_cycle, mem_finish, lsu_en, stall;
    logic [LANE_W-1:0]    mem_lane, mem_lane_q;
    logic                 mem_busy_q;
    logic [NUM_LANES-1:0] mem_wb;             // 多周期 load：本拍把数据写回当前 lane

    // 执行级
    logic [15:0] npc_fetch, npc_arch;
    logic        squash, halt;
    logic [3:0]  fault;
    logic [31:0] vote_val;
    logic [NUM_LANES-1:0][31:0] wb_data, sreg_val, shfl_val;
    logic [NUM_LANES-1:0] wb_en;
    logic                 wb_en_warp;

    assign start_pulse = (state_q == S_IDLE) && start_i;
    assign shape_o     = {8'(NUM_WARPS), 8'(NUM_LANES)};
    // 访存的那几拍：取指口已经在读下一条指令，执行级必须用冻住的那份译码结果
    assign ctrl_e      = mem_busy_q ? ctrl_e_q : ctrl;
    assign insn_e      = mem_busy_q ? insn_e_q : insn_f;

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
    // 取指越界时指令无效：和黄金模型一样，先报 PC_OOB、什么都不执行。
    // 多周期访存期间 `pc_oob_f` 说的是在途取指（下一条），不能拿来否掉手里这条指令。
    assign ex_valid    = e_valid_q && (mem_busy_q || !pc_oob_f);
    assign fetch_oob_e = e_valid_q && pc_oob_f && !mem_busy_q;
    assign gate_used   = (ctrl_e.op == SK_OP_ALU) || (ctrl_e.op == SK_OP_CMP)
                      || (ctrl_e.op == SK_OP_LOAD) || (ctrl_e.op == SK_OP_STORE)
                      || (ctrl_e.op == SK_OP_SHFL) || (ctrl_e.op == SK_OP_SREAD);
    assign gate_idx    = ctrl_e.pred[2:0] - 3'd1;
    assign pred_idx    = ctrl_e.rb[2:0];         // `.P`/`.PM`/`MCLR.P` 的谓词号在 rb 字段

    generate
        for (genvar lane = 0; lane < NUM_LANES; lane++) begin : g_gate
            assign gate_ok[lane] = !gate_used || (ctrl_e.pred == 4'd0)
                                 || (pred_q[lane][gate_idx] ^ ctrl_e.pinv);
            assign lane_act[lane] = ex_valid && m_q[lane] && gate_ok[lane];
            assign pred_sel[lane] = pred_q[lane][gate_idx];         // SEL 的操作数谓词
            assign pred_p[lane]   = pred_q[lane][pred_idx];         // `.P` 类指令的谓词
        end
    endgenerate

    SK_regfile #(.LANES(NUM_LANES), .NUM_GPR(NUM_GPR), .WIDTH(32)) u_regfile (
        .clk             (clk),
        .clear_i         (start_pulse),
        .we_i            (gpr_we),
        .waddr_i         (gpr_waddr),
        .wdata_i         (gpr_wdata),
        .raddr_a_i       (ctrl_e.ra),
        .rdata_a_o       (ra_val),
        .raddr_b_i       (ctrl_e.rb),
        .rdata_b_o       (rb_val),
        .raddr_c_i       (ctrl_e.rd),
        .rdata_c_o       (rc_val),
        .raddr_dbg_lane_i(dbg_lane_i),
        .raddr_dbg_i     (dbg_addr_i[4:0]),
        .rdata_dbg_o     (gpr_dbg)
    );

    generate
        for (genvar lane = 0; lane < NUM_LANES; lane++) begin : g_alu
            assign b_operand[lane] = ctrl_e.imm_sel ? ctrl_e.imm : rb_val[lane];
            SK_alu u_alu (
                .alu_op_i (ctrl_e.alu_op),
                .cmp_op_i (ctrl_e.cmp_op),
                .a_i      (ra_val[lane]),
                .b_i      (b_operand[lane]),
                .acc_i    (rc_val[lane]),
                .alu_o    (alu_r[lane]),
                .cmp_o    (cmp_r[lane])
            );
        end
    endgenerate

    // mask 指令的 GPR 操作数要求全 lane 一致：硬件取 lane 0 的读数据，不做检查
    SK_mask #(.LANES(NUM_LANES)) u_mask (
        .clk     (clk),
        .aresetn (aresetn),
        .init_i  (start_pulse),
        .full_i  (FULL_MASK),
        .en_i    (ex_valid && (ctrl_e.op == SK_OP_MASK)),
        .op_i    (ctrl_e.mask_op),
        .ra_i    (ra_val[0]),
        .rb_i    (rb_val[0]),
        .p_i     (pred_p),
        .m_o     (m_q),
        .rd_o    (mask_rd),
        .rd_we_o (mask_rd_we)
    );

    // --- 访存：一条指令占 NUM_LANES 拍，每拍一条 lane（lane 顺序就是地址检查顺序）---
    assign mem_op     = (ctrl_e.op == SK_OP_LOAD) || (ctrl_e.op == SK_OP_STORE);
    assign mem_lane   = mem_busy_q ? mem_lane_q : '0;
    assign mem_cycle  = mem_busy_q || (ex_valid && mem_op);
    assign mem_finish = mem_cycle && ((mem_lane == LANE_LAST) || (lsu_fault != SK_STATUS_OK));
    assign stall      = mem_cycle && !mem_finish;   // 中途冻结取指和执行级
    assign lsu_en     = mem_cycle && ex_valid && lane_act[mem_lane];

    SK_lsu u_lsu (
        .op_en_i     (lsu_en),
        .store_i     (ctrl_e.op == SK_OP_STORE),
        .global_i    (ctrl_e.mem_global),
        .base_i      (ra_val[mem_lane]),
        .imm_i       (ctrl_e.imm),
        .wdata_i     (rc_val[mem_lane]),       // STORE 的源寄存器在 rd 字段
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

    // --- 各执行通路的写回数据（每 lane 一份；warp 级指令是广播的同一个值）---
    always_comb begin
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            unique case (ctrl_e.sreg[3:0])
                SK_SREG_LANEID: sreg_val[lane] = 32'(lane);
                SK_SREG_TID:    sreg_val[lane] = sreg_i[SK_SREG_WID] * sreg_i[SK_SREG_WARPSZ]
                                              + 32'(lane);
                default:        sreg_val[lane] = sreg_i[ctrl_e.sreg[3:0]];
            endcase
        end

        for (int lane = 0; lane < NUM_LANES; lane++) begin
            logic [63:0]       delta, src;
            logic              src_ok;
            logic [LANE_W-1:0] idx;

            delta = {32'd0, rb_val[lane]};
            unique case (ctrl_e.func)
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
            // 越界或者源 lane 不在 M 里：返回自己的值，对齐 NV 语义
            shfl_val[lane] = (src_ok && m_q[idx]) ? ra_val[idx] : ra_val[lane];
        end

        // VOTE：M 内的 lane 做 OR/AND 归约，结果广播给所有 lane
        begin
            logic vote_any, vote_all;
            vote_any = 1'b0;
            vote_all = 1'b1;
            for (int lane = 0; lane < NUM_LANES; lane++) begin
                vote_any |= m_q[lane] & pred_p[lane];
                vote_all &= ~(m_q[lane] & ~pred_p[lane]);   // M 为空也算 1
            end
            if (ctrl_e.func == SK_VOTE_ALL) begin
                vote_val = {31'd0, vote_all};
            end else if (ctrl_e.func == SK_VOTE_ANY) begin
                vote_val = {31'd0, vote_any};
            end else begin
                vote_val = 32'd0;
            end
        end

        for (int lane = 0; lane < NUM_LANES; lane++) begin
            unique case (ctrl_e.op)
                SK_OP_ALU:   wb_data[lane] = alu_r[lane];
                SK_OP_SEL:   wb_data[lane] = pred_sel[lane] ? ra_val[lane] : rb_val[lane];
                SK_OP_LOAD:  wb_data[lane] = lsu_rdata;
                SK_OP_MASK:  wb_data[lane] = mask_rd;
                SK_OP_SREAD: wb_data[lane] = sreg_val[lane];
                SK_OP_SHFL:  wb_data[lane] = shfl_val[lane];
                SK_OP_VOTE:  wb_data[lane] = vote_val;
                default:     wb_data[lane] = 32'd0;
            endcase
        end
    end

    // --- 执行级：写回、分支、结束 ---
    always_comb begin
        npc_fetch  = pc_q + 16'd1;           // 顺序取指
        npc_arch   = pc_e_q + 16'd1;         // 架构 PC：下一条指令
        squash     = 1'b0;
        halt       = 1'b0;
        fault      = SK_STATUS_OK;
        wb_en      = '0;
        wb_en_warp = 1'b0;
        pred_we    = '0;
        for (int lane = 0; lane < NUM_LANES; lane++) begin
            pred_wr_val[lane] = cmp_r[lane];
        end

        if (fetch_oob_e) begin
            fault = SK_STATUS_PC_OOB;                         // 取指越界，指令不执行
        end else if (ex_valid) begin
            unique case (ctrl_e.op)
                SK_OP_ALU: begin
                    wb_en = '1;
                end
                SK_OP_CMP: begin
                    pred_we = '1;
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        unique case (ctrl_e.bop)
                            SK_BOP_SET: pred_wr_val[lane] = cmp_r[lane];
                            SK_BOP_AND: pred_wr_val[lane] =
                                pred_q[lane][ctrl_e.rd[2:0]] & cmp_r[lane];
                            SK_BOP_OR:  pred_wr_val[lane] =
                                pred_q[lane][ctrl_e.rd[2:0]] | cmp_r[lane];
                            SK_BOP_XOR: pred_wr_val[lane] =
                                pred_q[lane][ctrl_e.rd[2:0]] ^ cmp_r[lane];
                            default:    pred_wr_val[lane] = cmp_r[lane];
                        endcase
                    end
                end
                SK_OP_SEL: begin
                    wb_en = '1;
                end
                SK_OP_LOAD, SK_OP_STORE: begin
                    // 本拍服务 mem_lane：出错就以这个错误码结束这条指令
                    if (mem_cycle && lsu_fault != SK_STATUS_OK) begin
                        fault = lsu_fault;
                    end
                end
                SK_OP_MASK: begin
                    wb_en_warp = mask_rd_we;                  // warp 级：不受 M 门控
                end
                SK_OP_BRZ: if (ra_val[0] == 32'd0) begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl_e.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;                         // 丢掉在途的取指
                end
                SK_OP_BRNZ: if (ra_val[0] != 32'd0) begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl_e.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;
                end
                SK_OP_JMP: begin
                    npc_fetch = pc_e_q + 16'd1 + ctrl_e.off[15:0];
                    npc_arch  = npc_fetch;
                    squash    = 1'b1;
                end
                SK_OP_SREAD: begin
                    wb_en = '1;
                end
                SK_OP_SYS: begin
                    unique case (ctrl_e.func)
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
                    wb_en = '1;                               // 每 lane 各写各的源 lane 值
                end
                SK_OP_VOTE: begin
                    wb_en_warp = 1'b1;                        // 结果写所有 lane
                end
                default: fault = SK_STATUS_BAD_INSN;
            endcase
        end
    end

    generate
        for (genvar lane = 0; lane < NUM_LANES; lane++) begin : g_wb
            // 多周期 load：本拍读出来的就是 mem_lane 的值，同拍落进它的寄存器堆
            assign mem_wb[lane] = mem_cycle && (ctrl_e.op == SK_OP_LOAD)
                               && (mem_lane == LANE_W'(lane)) && ex_valid
                               && lane_act[lane] && (lsu_fault == SK_STATUS_OK);
            // 报错的指令不写回（访存出错时读出来的数据没有意义，和黄金模型一致）
            assign gpr_we[lane] = (fault == SK_STATUS_OK)
                               && ((wb_en[lane] && lane_act[lane])
                                   || (wb_en_warp && ex_valid) || mem_wb[lane]);
        end
    endgenerate

    assign gpr_waddr   = ctrl_e.rd;
    assign gpr_wdata   = wb_data;
    assign status_o    = status_q;
    assign done_o      = (state_q == S_DONE);

    // 访存的多周期计数器：lane 0..NUM_LANES-1 走一遍，出错立即结束这条指令
    always_ff @(posedge clk) begin
        if (!aresetn || start_pulse) begin
            mem_busy_q <= 1'b0;
            mem_lane_q <= '0;
            ctrl_e_q   <= '0;
            insn_e_q   <= 32'd0;
        end else if (state_q == S_RUN) begin
            if (mem_cycle && !mem_finish) begin
                mem_busy_q <= 1'b1;
                mem_lane_q <= mem_lane_q + 1'b1;
                if (!mem_busy_q) begin          // 第一拍：把这条指令的译码结果冻住
                    ctrl_e_q <= ctrl;
                    insn_e_q <= insn_f;
                end
            end else begin
                mem_busy_q <= 1'b0;
                mem_lane_q <= '0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q   <= S_IDLE;
            pc_q      <= 16'd0;
            pc_e_q    <= 16'd0;
            pc_a_q    <= 16'd0;
            e_valid_q <= 1'b0;
            for (int lane = 0; lane < NUM_LANES; lane++) pred_q[lane] <= '0;
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
                        for (int lane = 0; lane < NUM_LANES; lane++) pred_q[lane] <= '0;
                        status_q  <= SK_STATUS_OK;
                    end
                end
                S_RUN: if (!stall) begin                 // 访存进行中：整条流水冻结
                    pc_q   <= npc_fetch;
                    pc_e_q <= pc_q;
                    if (e_valid_q) begin
                        // 取指越界时黄金模型不推进 PC，这里保持一致
                        pc_a_q <= (fault == SK_STATUS_PC_OOB) ? pc_e_q : npc_arch;
                    end
                    for (int lane = 0; lane < NUM_LANES; lane++) begin
                        if (pred_we[lane] && lane_act[lane]) begin
                            pred_q[lane][ctrl_e.rd[2:0]] <= pred_wr_val[lane];
                        end
                    end
                    if (!e_valid_q) begin
                        e_valid_q <= 1'b1;                // 空泡之后恢复
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
                default: ;                                // S_DONE：保持
            endcase
        end
    end

    // --- 调试扫描口（仿真用）---
    always_comb begin
        unique case (dbg_addr_i)
            8'h20:   dbg_data_o = 32'(m_q);
            8'h21:   dbg_data_o = 32'(pred_q[dbg_lane_i]);
            8'h22:   dbg_data_o = {16'd0, pc_e_q};
            8'h23:   dbg_data_o = {28'd0, status_q};
            8'h24:   dbg_data_o = insn_e;
            8'h25:   dbg_data_o = {30'd0, done_o, e_valid_q};
            8'h26:   dbg_data_o = {16'd0, pc_a_q};
            default: dbg_data_o = (dbg_addr_i < 8'd32) ? gpr_dbg : 32'd0;
        endcase
    end

endmodule
