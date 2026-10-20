//! 测试台用的 AXI4-Lite 主机：一条命令（读或写）翻译成一次 AXI4-Lite 事务。
//!
//! 命令口是"简单口"：C++ 侧拉 `cmd_valid`，等 `rsp_valid` 一拍读结果——
//! 和板上 XRT 走 `s_axi_control` 的读写是同一套寄存器访问。

module tb_axil_host #(
    parameter int ADDR_W = 12
) (
    input  logic              clk,
    input  logic              aresetn,
    // 命令口（C++ 驱动）
    input  logic              cmd_valid_i,
    output logic              cmd_ready_o,
    input  logic              cmd_wr_i,
    input  logic [ADDR_W-1:0] cmd_addr_i,
    input  logic [31:0]       cmd_wdata_i,
    // 响应口
    output logic              rsp_valid_o,
    output logic [31:0]       rsp_rdata_o,
    output logic              rsp_error_o,     // 从机回了非 OKAY（tb 里应当永远为 0）
    // AXI4-Lite 主口
    output logic [ADDR_W-1:0] m_awaddr_o,
    output logic              m_awvalid_o,
    input  logic              m_awready_i,
    output logic [31:0]       m_wdata_o,
    output logic [3:0]        m_wstrb_o,
    output logic              m_wvalid_o,
    input  logic              m_wready_i,
    input  logic              m_bvalid_i,
    output logic              m_bready_o,
    input  logic [1:0]        m_bresp_i,
    output logic [ADDR_W-1:0] m_araddr_o,
    output logic              m_arvalid_o,
    input  logic              m_arready_i,
    output logic              m_rready_o,
    input  logic              m_rvalid_i,
    input  logic [31:0]       m_rdata_i,
    input  logic [1:0]        m_rresp_i
);

    typedef enum logic [2:0] {T_IDLE, T_WAW, T_WB, T_RAR, T_RR, T_RSP} tstate_e;

    tstate_e           state_q;
    logic [ADDR_W-1:0] addr_q;
    logic [31:0]       wdata_q;
    logic [31:0]       rdata_q;
    logic              aw_done_q, w_done_q;

    assign cmd_ready_o = (state_q == T_IDLE);
    assign rsp_valid_o = (state_q == T_RSP);
    assign rsp_rdata_o = rdata_q;

    assign m_awaddr_o  = addr_q;
    assign m_awvalid_o = (state_q == T_WAW) && !aw_done_q;
    assign m_wdata_o   = wdata_q;
    assign m_wstrb_o   = 4'hF;
    assign m_wvalid_o  = (state_q == T_WAW) && !w_done_q;
    assign m_bready_o  = (state_q == T_WB);
    assign m_araddr_o  = addr_q;
    assign m_arvalid_o = (state_q == T_RAR);
    assign m_rready_o  = (state_q == T_RR);

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q <= T_IDLE;
            addr_q  <= '0;
            wdata_q <= '0;
            rdata_q <= '0;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end else begin
            unique case (state_q)
                T_IDLE: begin
                    if (cmd_valid_i) begin
                        addr_q  <= cmd_addr_i;
                        wdata_q <= cmd_wdata_i;
                        aw_done_q <= 1'b0;
                        w_done_q  <= 1'b0;
                        state_q <= cmd_wr_i ? T_WAW : T_RAR;
                    end
                end
                T_WAW: begin
                    // AW 和 W 可以分开到达：各自记完成，两个都握上了再等 B
                    if (m_awready_i) aw_done_q <= 1'b1;
                    if (m_wready_i)  w_done_q  <= 1'b1;
                    if ((aw_done_q || m_awready_i) && (w_done_q || m_wready_i)) begin
                        state_q <= T_WB;
                    end
                end
                T_WB: begin
                    if (m_bvalid_i) begin
                        rdata_q <= '0;
                        state_q <= T_RSP;
                    end
                end
                T_RAR: begin
                    if (m_arready_i) state_q <= T_RR;
                end
                T_RR: begin
                    if (m_rvalid_i) begin
                        rdata_q <= m_rdata_i;
                        state_q <= T_RSP;
                    end
                end
                default: state_q <= T_IDLE;      // T_RSP：只报一拍
            endcase
        end
    end

    assign rsp_error_o = ((state_q == T_WB) && m_bvalid_i && (m_bresp_i != 2'b00)) ||
                         ((state_q == T_RR) && m_rvalid_i && (m_rresp_i != 2'b00));

endmodule
