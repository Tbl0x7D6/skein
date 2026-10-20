//! AXI4 主设备：单 outstanding，把"核侧 64-bit beat 突发"打包成 shell 的 512-bit 行事务。
//!
//! 上游还是"一拍一条突发"的简单接口（coalescer / L1 都这么造请求）：
//!   - 请求（addr/len/we）保持到 `req_ready_o`；请求保证落在**同一条 64 B 行**内
//!     （coalescer 按行分组、L1 只发整行，这是全设计的不变式）；
//!   - 写突发的数据由上游按 `wbeat_taken_o` 推进 beat 计数，每拍现给；
//!   - 读突发的数据用 `rbeat_valid_o` 送 64-bit 切片，`rbeat_ready_i` 反压；
//!   - 突发结束给一拍 `done_o`，`RRESP`/`BRESP` 非 OKAY 时给 `fault_o`。
//!
//! 下游 AXI 一次性搬整行（512-bit、len=0、size=6、地址 64 B 对齐）：写把上游的 beat
//! 按行内偏移摆进 512-bit 数据 + `WSTRB`，读把整行读回来再按上游要的区间切片。
//! `base_i` 是设备的 64 位基址，核里的 32 位地址是它内部的偏移（ISA 寄存器是 32 位，
//! 上板时 BO 的地址可能超过 4 GB，见 docs/design.md §5.6）。
//!
//! 事件（txn / beat）喂性能计数器：txn 数的是**总线上的突发**，beat 数的是**核侧搬的
//! 8 字节块**（所以 bytes = beats × 8 在两个配置下都可比，见 docs/design.md §12.11）。
//!
//! AXI 通道遵守 AXI4 握手：`valid` 一旦拉起，在 `ready` 之前不撤销。

`include "SK_config.vh"

module SK_axi_master #(
    parameter int ADDR_W     = 32,
    parameter int DATA_W     = 64,               // 上游 beat 宽度
    parameter int AXI_ADDR_W = 64,
    parameter int AXI_DATA_W = `SK_AXI_DATA_W,   // 行宽（512）
    parameter int LEN_W      = 3                 // 上游突发长度 - 1（0..7 beat）
) (
    input  logic                      clk,
    input  logic                      aresetn,
    input  logic [AXI_ADDR_W-1:0]     base_i,      // 设备地址基址
    // 上游突发接口（64-bit beat）
    input  logic                      req_valid_i,
    output logic                      req_ready_o,
    input  logic                      req_we_i,
    input  logic [ADDR_W-1:3]         req_addr_i,     // beat 对齐的字节地址
    input  logic [LEN_W-1:0]          req_len_i,
    input  logic [DATA_W-1:0]         wdata_i,
    input  logic [DATA_W/8-1:0]       wstrb_i,
    output logic                      wbeat_taken_o,
    output logic                      rbeat_valid_o,
    output logic [DATA_W-1:0]         rbeat_data_o,
    output logic                      rbeat_last_o,
    input  logic                      rbeat_ready_i,
    output logic                      done_o,
    output logic                      fault_o,
    output logic                      busy_o,
    // 计数器事件
    output logic                      ev_rd_txn_o,
    output logic                      ev_wr_txn_o,
    output logic                      ev_rd_beat_o,
    output logic                      ev_wr_beat_o,
    // AXI4 主口（512-bit）
    output logic [AXI_ADDR_W-1:0]     m_axi_awaddr_o,
    output logic [7:0]                m_axi_awlen_o,
    output logic [2:0]                m_axi_awsize_o,
    output logic [1:0]                m_axi_awburst_o,
    output logic                      m_axi_awvalid_o,
    input  logic                      m_axi_awready_i,
    output logic [AXI_DATA_W-1:0]     m_axi_wdata_o,
    output logic [AXI_DATA_W/8-1:0]   m_axi_wstrb_o,
    output logic                      m_axi_wlast_o,
    output logic                      m_axi_wvalid_o,
    input  logic                      m_axi_wready_i,
    input  logic [1:0]                m_axi_bresp_i,
    input  logic                      m_axi_bvalid_i,
    output logic                      m_axi_bready_o,
    output logic [AXI_ADDR_W-1:0]     m_axi_araddr_o,
    output logic [7:0]                m_axi_arlen_o,
    output logic [2:0]                m_axi_arsize_o,
    output logic [1:0]                m_axi_arburst_o,
    output logic                      m_axi_arvalid_o,
    input  logic                      m_axi_arready_i,
    input  logic [AXI_DATA_W-1:0]     m_axi_rdata_i,
    input  logic [1:0]                m_axi_rresp_i,
    input  logic                      m_axi_rlast_i,
    input  logic                      m_axi_rvalid_i,
    output logic                      m_axi_rready_o
);

    localparam int LINE_BYTES = AXI_DATA_W / 8;              // 64
    localparam logic [2:0] AXI_SIZE = 3'($clog2(LINE_BYTES));// 6
    localparam logic [1:0] AXI_INCR = 2'b01;

    typedef enum logic [2:0] {
        ST_IDLE, ST_RD_AR, ST_RD_R, ST_RD_OUT,
        ST_WR_COLLECT, ST_WR_AW, ST_WR_B, ST_RESP
    } state_e;

    state_e            state_q;
    logic              resp_fault_q;
    logic [LEN_W-1:0]  len_q;
    logic [2:0]        first_beat_q, cnt_q;
    logic [AXI_ADDR_W-1:0] line_addr_q;      // 64 B 对齐的设备地址
    logic [AXI_DATA_W-1:0] line_q;           // 读回来的整行 / 写出去的整行
    logic [LINE_BYTES-1:0] strb_q;
    logic              aw_done_q, w_done_q;

    logic [8:0]        wr_bit_off, rd_bit_off;
    logic [2:0]        wr_idx, rd_idx;

    assign wr_idx = first_beat_q + cnt_q;
    assign rd_idx = first_beat_q + cnt_q;
    assign wr_bit_off = 9'(wr_idx) * 9'(DATA_W);
    assign rd_bit_off = 9'(rd_idx) * 9'(DATA_W);

    assign busy_o      = (state_q != ST_IDLE);
    assign req_ready_o = (state_q == ST_IDLE);

    // --- 读通道 ---
    assign m_axi_araddr_o  = line_addr_q;
    assign m_axi_arlen_o   = 8'd0;             // 一次一行
    assign m_axi_arsize_o  = AXI_SIZE;
    assign m_axi_arburst_o = AXI_INCR;
    assign m_axi_arvalid_o = (state_q == ST_RD_AR);
    assign m_axi_rready_o  = (state_q == ST_RD_R);

    assign rbeat_valid_o = (state_q == ST_RD_OUT);
    assign rbeat_data_o  = line_q[rd_bit_off +: DATA_W];
    assign rbeat_last_o  = (cnt_q == len_q);
    assign ev_rd_txn_o   = (state_q == ST_RD_AR) && m_axi_arready_i;
    assign ev_rd_beat_o  = (state_q == ST_RD_OUT) && rbeat_ready_i;

    // --- 写通道 ---
    assign m_axi_awaddr_o  = line_addr_q;
    assign m_axi_awlen_o   = 8'd0;
    assign m_axi_awsize_o  = AXI_SIZE;
    assign m_axi_awburst_o = AXI_INCR;
    assign m_axi_awvalid_o = (state_q == ST_WR_AW) && !aw_done_q;
    assign m_axi_wdata_o   = line_q;
    assign m_axi_wstrb_o   = strb_q;
    assign m_axi_wlast_o   = 1'b1;
    assign m_axi_wvalid_o  = (state_q == ST_WR_AW) && !w_done_q;
    assign m_axi_bready_o  = (state_q == ST_WR_B);

    // 写：上游每拍给一个 64-bit beat，按行内偏移摆进整行
    assign wbeat_taken_o = (state_q == ST_WR_COLLECT);
    assign ev_wr_beat_o  = wbeat_taken_o;
    // AW 和 W 是分开握手的：两个都完成的那一拍才算一笔写事务
    assign ev_wr_txn_o   = (state_q == ST_WR_AW) &&
                           (aw_done_q || m_axi_awready_i) &&
                           (w_done_q  || m_axi_wready_i);

    assign done_o  = (state_q == ST_RESP);
    assign fault_o = (state_q == ST_RESP) && resp_fault_q;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q    <= ST_IDLE;
            len_q      <= '0;
            cnt_q      <= '0;
            first_beat_q <= '0;
            line_addr_q  <= '0;
            line_q       <= '0;
            strb_q       <= '0;
            aw_done_q    <= 1'b0;
            w_done_q     <= 1'b0;
            resp_fault_q <= 1'b0;
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (req_valid_i) begin
                        len_q        <= req_len_i;
                        cnt_q        <= '0;
                        first_beat_q <= req_addr_i[5:3];
                        // 一行对齐的设备地址：base + (核内地址的行内偏移清零)
                        line_addr_q  <= base_i + AXI_ADDR_W'({req_addr_i[ADDR_W-1:6], 6'b0});
                        line_q       <= '0;
                        strb_q       <= '0;
                        aw_done_q    <= 1'b0;
                        w_done_q     <= 1'b0;
                        resp_fault_q <= 1'b0;
                        state_q      <= req_we_i ? ST_WR_COLLECT : ST_RD_AR;
                    end
                end
                ST_RD_AR: begin
                    if (m_axi_arready_i) state_q <= ST_RD_R;
                end
                ST_RD_R: begin
                    if (m_axi_rvalid_i) begin
                        line_q       <= m_axi_rdata_i;
                        resp_fault_q <= (m_axi_rresp_i != 2'b00) || !m_axi_rlast_i;
                        cnt_q        <= '0;
                        state_q      <= ST_RD_OUT;
                    end
                end
                ST_RD_OUT: begin
                    if (rbeat_ready_i) begin
                        if (cnt_q == len_q) state_q <= ST_RESP;
                        else                     cnt_q   <= cnt_q + 3'd1;
                    end
                end
                ST_WR_COLLECT: begin
                    // 上游一拍一个 beat，摆到行内对应的 64 位槽
                    line_q[wr_bit_off +: DATA_W] <= wdata_i;
                    for (int b = 0; b < DATA_W / 8; b++) begin
                        strb_q[wr_idx * (DATA_W / 8) + b] <= wstrb_i[b];
                    end
                    if (cnt_q == len_q) begin
                        state_q <= ST_WR_AW;
                    end else begin
                        cnt_q <= cnt_q + 3'd1;
                    end
                end
                ST_WR_AW: begin
                    if (m_axi_awready_i) aw_done_q <= 1'b1;
                    if (m_axi_wready_i)  w_done_q  <= 1'b1;
                    if ((aw_done_q || m_axi_awready_i) && (w_done_q || m_axi_wready_i)) begin
                        state_q <= ST_WR_B;
                    end
                end
                ST_WR_B: begin
                    if (m_axi_bvalid_i) begin
                        resp_fault_q <= (m_axi_bresp_i != 2'b00);
                        state_q      <= ST_RESP;
                    end
                end
                default: state_q <= ST_IDLE;     // ST_RESP：done/fault 一拍
            endcase
        end
    end

endmodule
