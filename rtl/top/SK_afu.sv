//! Vitis RTL kernel 壳（P6）：把 SK_top 包成 `v++` 认的接口。
//!
//! 接口按 UG1393 的 RTL kernel 约定命名（工具靠名字推断）：
//!   - `ap_clk` / `ap_rst_n`：系统时钟复位；
//!   - `s_axi_control`：AXI4-Lite 控制口，寄存器表见 docs/design.md §5.6
//!     （kernel.xml 里声明 range=0x1000、32-bit）；
//!   - `m_axi_gmem`：AXI4 主口，512-bit、INCR、一次一整行 64 B（kernel.xml 里
//!     声明 512-bit）。
//!
//! 这里只做两件事：把 testbench 专用的 shared memory 主机口 tie 掉、把命名换掉。
//! 核和主机接口都在 SK_top 里，仿真和上板是同一份。

module SK_afu (
    input  logic         ap_clk,
    input  logic         ap_rst_n,
    // ---- AXI4-Lite 控制口（s_axi_control）----
    input  logic         s_axi_control_awvalid,
    output logic         s_axi_control_awready,
    input  logic [11:0]  s_axi_control_awaddr,
    input  logic         s_axi_control_wvalid,
    output logic         s_axi_control_wready,
    input  logic [31:0]  s_axi_control_wdata,
    input  logic [3:0]   s_axi_control_wstrb,
    output logic         s_axi_control_bvalid,
    input  logic         s_axi_control_bready,
    output logic [1:0]   s_axi_control_bresp,
    input  logic         s_axi_control_arvalid,
    output logic         s_axi_control_arready,
    input  logic [11:0]  s_axi_control_araddr,
    output logic         s_axi_control_rvalid,
    input  logic         s_axi_control_rready,
    output logic [31:0]  s_axi_control_rdata,
    output logic [1:0]   s_axi_control_rresp,
    // ---- AXI4 主口（m_axi_gmem，512-bit）----
    output logic [63:0]  m_axi_gmem_awaddr,
    output logic [7:0]   m_axi_gmem_awlen,
    output logic [2:0]   m_axi_gmem_awsize,
    output logic [1:0]   m_axi_gmem_awburst,
    output logic         m_axi_gmem_awvalid,
    input  logic         m_axi_gmem_awready,
    output logic [511:0] m_axi_gmem_wdata,
    output logic [63:0]  m_axi_gmem_wstrb,
    output logic         m_axi_gmem_wlast,
    output logic         m_axi_gmem_wvalid,
    input  logic         m_axi_gmem_wready,
    input  logic [1:0]   m_axi_gmem_bresp,
    input  logic         m_axi_gmem_bvalid,
    output logic         m_axi_gmem_bready,
    output logic [63:0]  m_axi_gmem_araddr,
    output logic [7:0]   m_axi_gmem_arlen,
    output logic [2:0]   m_axi_gmem_arsize,
    output logic [1:0]   m_axi_gmem_arburst,
    output logic         m_axi_gmem_arvalid,
    input  logic         m_axi_gmem_arready,
    input  logic [511:0] m_axi_gmem_rdata,
    input  logic [1:0]   m_axi_gmem_rresp,
    input  logic         m_axi_gmem_rlast,
    input  logic         m_axi_gmem_rvalid,
    output logic         m_axi_gmem_rready
);

    SK_top u_top (
        .clk            (ap_clk),
        .aresetn        (ap_rst_n),
        .s_awvalid      (s_axi_control_awvalid),
        .s_awready      (s_axi_control_awready),
        .s_awaddr       (s_axi_control_awaddr),
        .s_wvalid       (s_axi_control_wvalid),
        .s_wready       (s_axi_control_wready),
        .s_wdata        (s_axi_control_wdata),
        .s_wstrb        (s_axi_control_wstrb),
        .s_bvalid       (s_axi_control_bvalid),
        .s_bready       (s_axi_control_bready),
        .s_bresp        (s_axi_control_bresp),
        .s_arvalid      (s_axi_control_arvalid),
        .s_arready      (s_axi_control_arready),
        .s_araddr       (s_axi_control_araddr),
        .s_rvalid       (s_axi_control_rvalid),
        .s_rready       (s_axi_control_rready),
        .s_rdata        (s_axi_control_rdata),
        .s_rresp        (s_axi_control_rresp),
        .m_axi_awaddr   (m_axi_gmem_awaddr),
        .m_axi_awlen    (m_axi_gmem_awlen),
        .m_axi_awsize   (m_axi_gmem_awsize),
        .m_axi_awburst  (m_axi_gmem_awburst),
        .m_axi_awvalid  (m_axi_gmem_awvalid),
        .m_axi_awready  (m_axi_gmem_awready),
        .m_axi_wdata    (m_axi_gmem_wdata),
        .m_axi_wstrb    (m_axi_gmem_wstrb),
        .m_axi_wlast    (m_axi_gmem_wlast),
        .m_axi_wvalid   (m_axi_gmem_wvalid),
        .m_axi_wready   (m_axi_gmem_wready),
        .m_axi_bresp    (m_axi_gmem_bresp),
        .m_axi_bvalid   (m_axi_gmem_bvalid),
        .m_axi_bready   (m_axi_gmem_bready),
        .m_axi_araddr   (m_axi_gmem_araddr),
        .m_axi_arlen    (m_axi_gmem_arlen),
        .m_axi_arsize   (m_axi_gmem_arsize),
        .m_axi_arburst  (m_axi_gmem_arburst),
        .m_axi_arvalid  (m_axi_gmem_arvalid),
        .m_axi_arready  (m_axi_gmem_arready),
        .m_axi_rdata    (m_axi_gmem_rdata),
        .m_axi_rresp    (m_axi_gmem_rresp),
        .m_axi_rlast    (m_axi_gmem_rlast),
        .m_axi_rvalid   (m_axi_gmem_rvalid),
        .m_axi_rready   (m_axi_gmem_rready),
        // testbench 专用口：板上没有通路，tie 掉（kernel 自己往 shared 搬数据）
        .smem_ld_we     (1'b0),
        .smem_ld_addr   ('0),
        .smem_ld_wdata  ('0),
        .smem_rd_addr   ('0),
        .smem_rd_en     (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .smem_rd_data   ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

endmodule
