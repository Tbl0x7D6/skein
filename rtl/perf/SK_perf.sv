//! 性能计数器：IPC（`INST_RETIRED / CYCLE`）、"为什么没发射"和 P5 的内存事件，
//! 清单见 docs/design.md §13。`CTRL.start` 清零、跑的过程中累加、`done` 之后自然冻结。
//!
//! 这里只留两个"没发射"的量：总共几拍没发射（读的时候用 `CYCLE - INST_ISSUED`
//! 算出来，不占计数器）和 `STALL_NO_WARP`（一条 RUN 状态的 warp 都没有）。
//!
//! 按指令类的 retired 计数（15 类，和黄金模型的 `op_counts` 同码）也在这里，
//! `skein-case` 拿它逐类和黄金模型对拍。
//!
//! 读出口复用调试扫描口（后面接 AXI-Lite）：`0x30` 起是一个 32 位计数器；
//! `0x44` 起是 15 个指令类计数。

module SK_perf #(
    parameter int NUM    = 20,       // 0x30..0x43 的通用计数器
    parameter int NCLASS = 15        // 0x44..0x52 的指令类计数
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
    // P5 内存事件
    input  logic              lds_txn_i,
    input  logic              sts_txn_i,
    input  logic              lds_replay_i,
    input  logic              axi_rd_txn_i,
    input  logic              axi_wr_txn_i,
    input  logic              axi_rd_beat_i,
    input  logic              axi_wr_beat_i,
    input  logic              axi_stall_i,
    input  logic              l1_rd_hit_i,
    input  logic              l1_rd_miss_i,
    input  logic              l1_wr_hit_i,
    input  logic              l1_wr_miss_i,
    input  logic              l1_wb_i,
    // 按指令类 retired
    input  logic [3:0]        class_i,
    input  logic              class_valid_i,
    input  logic [5:0]        addr_i,
    output logic [31:0]       data_o
);

    localparam int PERF_CYCLE         = 0;
    localparam int PERF_ISSUED        = 1;
    localparam int PERF_RETIRED       = 2;
    localparam int PERF_REPLAY        = 3;
    localparam int PERF_BARRIER       = 4;
    localparam int PERF_STALL_NO_WARP = 5;
    localparam int PERF_LSU_BUSY      = 6;
    localparam int PERF_LDS_TXN       = 7;
    localparam int PERF_STS_TXN       = 8;
    localparam int PERF_LDS_REPLAY    = 9;
    localparam int PERF_AXI_RD_TXN    = 10;
    localparam int PERF_AXI_WR_TXN    = 11;
    localparam int PERF_AXI_RD_BEATS  = 12;
    localparam int PERF_AXI_WR_BEATS  = 13;
    localparam int PERF_AXI_STALL     = 14;
    localparam int PERF_L1_RD_HIT     = 15;
    localparam int PERF_L1_RD_MISS    = 16;
    localparam int PERF_L1_WR_HIT     = 17;
    localparam int PERF_L1_WR_MISS    = 18;
    localparam int PERF_L1_WB         = 19;

    localparam logic [5:0] ADDR_BASE  = 6'h30;
    localparam logic [5:0] CLASS_BASE = 6'h44;

    logic [31:0] cnt_q [NUM];
    logic [31:0] class_q [NCLASS];

    always_ff @(posedge clk) begin
        if (!aresetn || start_i) begin
            for (int i = 0; i < NUM; i++) begin
                cnt_q[i] <= '0;
            end
            for (int i = 0; i < NCLASS; i++) begin
                class_q[i] <= '0;
            end
        end else if (run_i) begin
            cnt_q[PERF_CYCLE] <= cnt_q[PERF_CYCLE] + 32'd1;
            if (issued_i)      cnt_q[PERF_ISSUED]        <= cnt_q[PERF_ISSUED] + 32'd1;
            if (retired_i)     cnt_q[PERF_RETIRED]       <= cnt_q[PERF_RETIRED] + 32'd1;
            if (replay_i)      cnt_q[PERF_REPLAY]        <= cnt_q[PERF_REPLAY] + 32'd1;
            if (barrier_i)     cnt_q[PERF_BARRIER]       <= cnt_q[PERF_BARRIER] + 32'd1;
            if (no_warp_i)     cnt_q[PERF_STALL_NO_WARP] <= cnt_q[PERF_STALL_NO_WARP] + 32'd1;
            if (lsu_busy_i)    cnt_q[PERF_LSU_BUSY]      <= cnt_q[PERF_LSU_BUSY] + 32'd1;
            if (lds_txn_i)     cnt_q[PERF_LDS_TXN]       <= cnt_q[PERF_LDS_TXN] + 32'd1;
            if (sts_txn_i)     cnt_q[PERF_STS_TXN]       <= cnt_q[PERF_STS_TXN] + 32'd1;
            if (lds_replay_i)  cnt_q[PERF_LDS_REPLAY]    <= cnt_q[PERF_LDS_REPLAY] + 32'd1;
            if (axi_rd_txn_i)  cnt_q[PERF_AXI_RD_TXN]    <= cnt_q[PERF_AXI_RD_TXN] + 32'd1;
            if (axi_wr_txn_i)  cnt_q[PERF_AXI_WR_TXN]    <= cnt_q[PERF_AXI_WR_TXN] + 32'd1;
            if (axi_rd_beat_i) cnt_q[PERF_AXI_RD_BEATS]  <= cnt_q[PERF_AXI_RD_BEATS] + 32'd1;
            if (axi_wr_beat_i) cnt_q[PERF_AXI_WR_BEATS]  <= cnt_q[PERF_AXI_WR_BEATS] + 32'd1;
            if (axi_stall_i)   cnt_q[PERF_AXI_STALL]     <= cnt_q[PERF_AXI_STALL] + 32'd1;
            if (l1_rd_hit_i)   cnt_q[PERF_L1_RD_HIT]     <= cnt_q[PERF_L1_RD_HIT] + 32'd1;
            if (l1_rd_miss_i)  cnt_q[PERF_L1_RD_MISS]    <= cnt_q[PERF_L1_RD_MISS] + 32'd1;
            if (l1_wr_hit_i)   cnt_q[PERF_L1_WR_HIT]     <= cnt_q[PERF_L1_WR_HIT] + 32'd1;
            if (l1_wr_miss_i)  cnt_q[PERF_L1_WR_MISS]    <= cnt_q[PERF_L1_WR_MISS] + 32'd1;
            if (l1_wb_i)       cnt_q[PERF_L1_WB]         <= cnt_q[PERF_L1_WB] + 32'd1;
            if (retired_i && class_valid_i && (class_i < 4'(NCLASS))) begin
                class_q[class_i] <= class_q[class_i] + 32'd1;
            end
        end
    end

    always_comb begin
        data_o = '0;
        for (int i = 0; i < NUM; i++) begin
            if (addr_i == (ADDR_BASE + 6'(i))) data_o = cnt_q[i];
        end
        for (int i = 0; i < NCLASS; i++) begin
            if (addr_i == (CLASS_BASE + 6'(i))) data_o = class_q[i];
        end
    end

endmodule
