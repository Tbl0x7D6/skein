//! 性能计数器：IPC（`INST_RETIRED / CYCLE`）和"为什么没发射"的来源，清单见
//! docs/design.md §13。`CTRL.start` 清零、跑的过程中累加、`done` 之后自然冻结。
//!
//! 这里只留两个"没发射"的量：总共几拍没发射（读的时候用 `CYCLE - INST_ISSUED`
//! 算出来，不占计数器）和 `STALL_NO_WARP`（一条 RUN 状态的 warp 都没有）。
//! 更细的"在等 load / 等访存槽 / 指令还没走完"不再按拍归因——同一拍几条 warp 各有
//! 各的原因，硬摊到一条 warp 头上只会误导（见 docs/design.md §13）。
//!
//! 不做 `STALL_FETCH`：IMEM 是单口 BRAM、发射级一拍一条，不存在取指排队。
//! 读出口复用调试扫描口（后面接 AXI-Lite）：`0x30` 起，一个地址一个 32 位计数器。

module SK_perf #(
    parameter int NUM = 7
) (
    input  logic              clk,
    input  logic              aresetn,
    input  logic              start_i,      // 块开始：清零
    input  logic              run_i,        // 核在跑（S_RUN）
    input  logic              issued_i,     // 本拍发射了一条指令
    input  logic              retired_i,    // 本拍提交了一条指令
    input  logic              replay_i,     // 本拍重发了一条指令（译码级发现冒险）
    input  logic              barrier_i,    // 本拍放行了一次 BAR
    input  logic              no_warp_i,    // 本拍一条 RUN 状态的 warp 都没有
    input  logic              lsu_busy_i,   // 本拍有访存请求在排队
    input  logic [3:0]        addr_i,
    output logic [31:0]       data_o
);

    localparam int PERF_CYCLE         = 0;
    localparam int PERF_ISSUED        = 1;
    localparam int PERF_RETIRED       = 2;
    localparam int PERF_REPLAY        = 3;
    localparam int PERF_BARRIER       = 4;
    localparam int PERF_STALL_NO_WARP = 5;
    localparam int PERF_LSU_BUSY      = 6;

    logic [31:0] cnt_q [NUM];

    always_ff @(posedge clk) begin
        if (!aresetn || start_i) begin
            for (int i = 0; i < NUM; i++) begin
                cnt_q[i] <= '0;
            end
        end else if (run_i) begin
            cnt_q[PERF_CYCLE] <= cnt_q[PERF_CYCLE] + 32'd1;
            if (issued_i) begin
                cnt_q[PERF_ISSUED] <= cnt_q[PERF_ISSUED] + 32'd1;
            end
            if (retired_i) begin
                cnt_q[PERF_RETIRED] <= cnt_q[PERF_RETIRED] + 32'd1;
            end
            if (replay_i) begin
                cnt_q[PERF_REPLAY] <= cnt_q[PERF_REPLAY] + 32'd1;
            end
            if (barrier_i) begin
                cnt_q[PERF_BARRIER] <= cnt_q[PERF_BARRIER] + 32'd1;
            end
            if (no_warp_i) begin
                cnt_q[PERF_STALL_NO_WARP] <= cnt_q[PERF_STALL_NO_WARP] + 32'd1;
            end
            if (lsu_busy_i) begin
                cnt_q[PERF_LSU_BUSY] <= cnt_q[PERF_LSU_BUSY] + 32'd1;
            end
        end
    end

    always_comb begin
        data_o = 32'd0;
        unique case (addr_i)
            4'd0: data_o = cnt_q[PERF_CYCLE];
            4'd1: data_o = cnt_q[PERF_ISSUED];
            4'd2: data_o = cnt_q[PERF_RETIRED];
            4'd3: data_o = cnt_q[PERF_REPLAY];
            4'd4: data_o = cnt_q[PERF_BARRIER];
            4'd5: data_o = cnt_q[PERF_STALL_NO_WARP];
            4'd6: data_o = cnt_q[PERF_LSU_BUSY];
            default: ;
        endcase
    end

endmodule
