//! AXI4 主设备：单 outstanding，INCR 突发，数据宽度 64-bit（P6 可加宽）。
//!
//! 上游是"一拍一条突发"的简单接口：
//!   - 请求（addr/len/we）保持到 `req_ready_o`；写突发的数据由上游按 `wbeat_taken_o`
//!     推进自己的 beat 计数，每拍现给（coalescer 和 L1 都是这么造的）；
//!   - 读突发的数据用 `rbeat_valid_o` 送出，`rbeat_ready_i` 反压；
//!   - 突发结束给一拍 `done_o`，`RRESP`/`BRESP` 非 OKAY 时同时给 `fault_o`。
//!
//! 事件（txn / beat）直接喂性能计数器，见 docs/design.md §13。
//!
//! AXI 通道遵守 AXI4 握手：`valid` 一旦拉起，在 `ready` 之前不撤销。

`include "SK_config.vh"

module SK_axi_master #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = `SK_AXI_DATA_W,
    parameter int LEN_W  = 4            // 突发长度 - 1（1..16 beat）
) (
    input  logic                     clk,
    input  logic                     aresetn,
    // 上游突发接口
    input  logic                     req_valid_i,
    output logic                     req_ready_o,
    input  logic                     req_we_i,
    input  logic [ADDR_W-1:0]        req_addr_i,
    input  logic [LEN_W-1:0]         req_len_i,
    input  logic [DATA_W-1:0]        wdata_i,
    input  logic [DATA_W/8-1:0]      wstrb_i,
    output logic                     wbeat_taken_o,
    output logic                     rbeat_valid_o,
    output logic [DATA_W-1:0]        rbeat_data_o,
    output logic                     rbeat_last_o,
    input  logic                     rbeat_ready_i,
    output logic                     done_o,
    output logic                     fault_o,
    output logic                     busy_o,
    // 计数器事件
    output logic                     ev_rd_txn_o,
    output logic                     ev_wr_txn_o,
    output logic                     ev_rd_beat_o,
    output logic                     ev_wr_beat_o,
    // AXI4 主口
    output logic [ADDR_W-1:0]        m_axi_awaddr_o,
    output logic [7:0]               m_axi_awlen_o,
    output logic [2:0]               m_axi_awsize_o,
    output logic [1:0]               m_axi_awburst_o,
    output logic                     m_axi_awvalid_o,
    input  logic                     m_axi_awready_i,
    output logic [DATA_W-1:0]        m_axi_wdata_o,
    output logic [DATA_W/8-1:0]      m_axi_wstrb_o,
    output logic                     m_axi_wlast_o,
    output logic                     m_axi_wvalid_o,
    input  logic                     m_axi_wready_i,
    input  logic [1:0]               m_axi_bresp_i,
    input  logic                     m_axi_bvalid_i,
    output logic                     m_axi_bready_o,
    output logic [ADDR_W-1:0]        m_axi_araddr_o,
    output logic [7:0]               m_axi_arlen_o,
    output logic [2:0]               m_axi_arsize_o,
    output logic [1:0]               m_axi_arburst_o,
    output logic                     m_axi_arvalid_o,
    input  logic                     m_axi_arready_i,
    input  logic [DATA_W-1:0]        m_axi_rdata_i,
    input  logic [1:0]               m_axi_rresp_i,
    input  logic                     m_axi_rlast_i,
    input  logic                     m_axi_rvalid_i,
    output logic                     m_axi_rready_o
);

    localparam logic [2:0] AXI_SIZE  = 3'($clog2(DATA_W / 8));   // 每 beat 字节数
    localparam logic [1:0] AXI_INCR  = 2'b01;

    typedef enum logic [2:0] {ST_IDLE, ST_AR, ST_R, ST_AW, ST_W, ST_B} state_e;

    state_e          state_q;
    logic [ADDR_W-1:0] addr_q;
    logic [LEN_W-1:0]  len_q;
    logic [LEN_W-1:0]  beat_q;
    logic              resp_err_q;

    assign busy_o    = (state_q != ST_IDLE);
    assign req_ready_o = (state_q == ST_IDLE);

    // --- 写通道 ---
    assign m_axi_awaddr_o  = addr_q;
    assign m_axi_awlen_o   = 8'(len_q);
    assign m_axi_awsize_o  = AXI_SIZE;
    assign m_axi_awburst_o = AXI_INCR;
    assign m_axi_awvalid_o = (state_q == ST_AW);
    assign m_axi_wdata_o   = wdata_i;
    assign m_axi_wstrb_o   = wstrb_i;
    assign m_axi_wlast_o   = (beat_q == len_q);
    assign m_axi_wvalid_o  = (state_q == ST_W);
    assign m_axi_bready_o  = (state_q == ST_B);

    assign wbeat_taken_o = (state_q == ST_W) && m_axi_wready_i;
    assign ev_wr_txn_o   = (state_q == ST_AW) && m_axi_awready_i;
    assign ev_wr_beat_o  = wbeat_taken_o;

    // --- 读通道 ---
    assign m_axi_araddr_o  = addr_q;
    assign m_axi_arlen_o   = 8'(len_q);
    assign m_axi_arsize_o  = AXI_SIZE;
    assign m_axi_arburst_o = AXI_INCR;
    assign m_axi_arvalid_o = (state_q == ST_AR);
    assign m_axi_rready_o  = (state_q == ST_R) && rbeat_ready_i;

    assign rbeat_valid_o = (state_q == ST_R) && m_axi_rvalid_i;
    assign rbeat_data_o  = m_axi_rdata_i;
    assign rbeat_last_o  = m_axi_rlast_i;
    assign ev_rd_txn_o   = (state_q == ST_AR) && m_axi_arready_i;
    assign ev_rd_beat_o  = rbeat_valid_o && rbeat_ready_i;

    // 完成一拍：读在 RLAST 握手、写在 B 握手那一拍；fault 与 done 同拍
    assign done_o = ((state_q == ST_R) && m_axi_rvalid_i && m_axi_rlast_i && rbeat_ready_i)
                 || ((state_q == ST_B) && m_axi_bvalid_i);
    assign fault_o = done_o && (resp_err_q
                    || ((state_q == ST_R) && (m_axi_rresp_i != 2'b00))
                    || ((state_q == ST_B) && (m_axi_bresp_i != 2'b00)));

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q    <= ST_IDLE;
            addr_q     <= '0;
            len_q      <= '0;
            beat_q     <= '0;
            resp_err_q <= 1'b0;
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (req_valid_i) begin
                        addr_q     <= req_addr_i;
                        len_q      <= req_len_i;
                        beat_q     <= '0;
                        resp_err_q <= 1'b0;
                        state_q    <= req_we_i ? ST_AW : ST_AR;
                    end
                end
                ST_AR: if (m_axi_arready_i) state_q <= ST_R;
                ST_R: begin
                    if (m_axi_rvalid_i && rbeat_ready_i) begin
                        if (m_axi_rresp_i != 2'b00) resp_err_q <= 1'b1;
                        if (m_axi_rlast_i) state_q <= ST_IDLE;
                    end
                end
                ST_AW: if (m_axi_awready_i) state_q <= ST_W;
                ST_W: begin
                    if (m_axi_wready_i) begin
                        if (beat_q == len_q) state_q <= ST_B;
                        else                beat_q <= beat_q + LEN_W'(1);
                    end
                end
                ST_B: begin
                    if (m_axi_bvalid_i) begin
                        if (m_axi_bresp_i != 2'b00) resp_err_q <= 1'b1;
                        state_q <= ST_IDLE;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
