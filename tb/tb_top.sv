//! Verilator 顶层：AXI-Lite 主机 + SK_top（控制 + 核）+ AXI 从机（内存模型）。
//!
//! C++ 侧只驱动两样东西：AXI-Lite 的命令口（`cmd_*`）和内存的主机口
//! （`host_*` / `smem_*`）——和板上的主机流程一致：写 IMEM 和参数走控制寄存器、
//! 数据走内存、跑完从控制寄存器读 done/STATUS、从扫描口读架构状态。
//!
//! global memory 挂在 AXI 从机后面（`tb_axi_mem`）；shared memory 在核里，
//! 这里只留主机装载/快照口（板上没有这个通路，kernel 自己搬数据）。

`include "SK_config.vh"

module tb_top (
    input  logic        clk,
    input  logic        aresetn,
    // ---- AXI-Lite 主机命令口（C++）----
    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  logic        cmd_wr_i,
    input  logic [11:0] cmd_addr_i,
    input  logic [31:0] cmd_wdata_i,
    output logic        rsp_valid_o,
    output logic [31:0] rsp_rdata_o,
    output logic        rsp_error_o,
    // ---- shared memory 主机口（测试台专用）----
    input  logic        smem_ld_we_i,
    input  logic [12:0] smem_ld_addr_i,
    input  logic [31:0] smem_ld_wdata_i,
    input  logic [12:0] smem_rd_addr_i,
    input  logic        smem_rd_en_i,
    output logic [31:0] smem_rd_data_o,
    // ---- global memory 主机口（tb_axi_mem 后面的存储）----
    input  logic        host_we_i,
    input  logic [63:0] host_addr_i,
    input  logic [31:0] host_wdata_i,
    input  logic [63:0] host_raddr_i,
    output logic [31:0] host_rdata_o,
    // ---- AXI 从机延迟 ----
    input  logic [7:0]  rd_lat_i,
    input  logic [7:0]  wr_lat_i,
    // ---- AXI 从机的地址空间基址（和主机写进 GMEM_BASE 的值一致）----
    input  logic [63:0] addr_base_i
);

    // AXI4-Lite：主机 ↔ SK_top
    logic        axil_awvalid, axil_awready, axil_wvalid, axil_wready;
    logic        axil_bvalid, axil_bready;
    logic [11:0] axil_awaddr;
    logic [31:0] axil_wdata;
    logic [3:0]  axil_wstrb;
    logic [1:0]  axil_bresp;
    logic        axil_arvalid, axil_arready, axil_rvalid, axil_rready;
    logic [11:0] axil_araddr;
    logic [31:0] axil_rdata;
    logic [1:0]  axil_rresp;

    tb_axil_host #(.ADDR_W(12)) u_axil_host (
        .clk         (clk),
        .aresetn     (aresetn),
        .cmd_valid_i (cmd_valid_i),
        .cmd_ready_o (cmd_ready_o),
        .cmd_wr_i    (cmd_wr_i),
        .cmd_addr_i  (cmd_addr_i),
        .cmd_wdata_i (cmd_wdata_i),
        .rsp_valid_o (rsp_valid_o),
        .rsp_rdata_o (rsp_rdata_o),
        .rsp_error_o (rsp_error_o),
        .m_awaddr_o  (axil_awaddr),
        .m_awvalid_o (axil_awvalid),
        .m_awready_i (axil_awready),
        .m_wdata_o   (axil_wdata),
        .m_wstrb_o   (axil_wstrb),
        .m_wvalid_o  (axil_wvalid),
        .m_wready_i  (axil_wready),
        .m_bvalid_i  (axil_bvalid),
        .m_bready_o  (axil_bready),
        .m_bresp_i   (axil_bresp),
        .m_araddr_o  (axil_araddr),
        .m_arvalid_o (axil_arvalid),
        .m_arready_i (axil_arready),
        .m_rready_o  (axil_rready),
        .m_rvalid_i  (axil_rvalid),
        .m_rdata_i   (axil_rdata),
        .m_rresp_i   (axil_rresp)
    );

    // AXI4：SK_top ↔ 从机（512-bit 行事务）
    logic [63:0] g_awaddr;
    logic [7:0]  g_awlen;
    logic [2:0]  g_awsize;
    logic [1:0]  g_awburst;
    logic        g_awvalid, g_awready;
    logic [511:0] g_wdata;
    logic [63:0]  g_wstrb;
    logic        g_wlast, g_wvalid, g_wready;
    logic [1:0]  g_bresp;
    logic        g_bvalid, g_bready;
    logic [63:0] g_araddr;
    logic [7:0]  g_arlen;
    logic [2:0]  g_arsize;
    logic [1:0]  g_arburst;
    logic        g_arvalid, g_arready;
    logic [511:0] g_rdata;
    logic [1:0]  g_rresp;
    logic        g_rlast, g_rvalid, g_rready;

    SK_top u_top (
        .clk            (clk),
        .aresetn        (aresetn),
        .s_awvalid      (axil_awvalid),
        .s_awready      (axil_awready),
        .s_awaddr       (axil_awaddr),
        .s_wvalid       (axil_wvalid),
        .s_wready       (axil_wready),
        .s_wdata        (axil_wdata),
        .s_wstrb        (axil_wstrb),
        .s_bvalid       (axil_bvalid),
        .s_bready       (axil_bready),
        .s_bresp        (axil_bresp),
        .s_arvalid      (axil_arvalid),
        .s_arready      (axil_arready),
        .s_araddr       (axil_araddr),
        .s_rvalid       (axil_rvalid),
        .s_rready       (axil_rready),
        .s_rdata        (axil_rdata),
        .s_rresp        (axil_rresp),
        .m_axi_awaddr   (g_awaddr),
        .m_axi_awlen    (g_awlen),
        .m_axi_awsize   (g_awsize),
        .m_axi_awburst  (g_awburst),
        .m_axi_awvalid  (g_awvalid),
        .m_axi_awready  (g_awready),
        .m_axi_wdata    (g_wdata),
        .m_axi_wstrb    (g_wstrb),
        .m_axi_wlast    (g_wlast),
        .m_axi_wvalid   (g_wvalid),
        .m_axi_wready   (g_wready),
        .m_axi_bresp    (g_bresp),
        .m_axi_bvalid   (g_bvalid),
        .m_axi_bready   (g_bready),
        .m_axi_araddr   (g_araddr),
        .m_axi_arlen    (g_arlen),
        .m_axi_arsize   (g_arsize),
        .m_axi_arburst  (g_arburst),
        .m_axi_arvalid  (g_arvalid),
        .m_axi_arready  (g_arready),
        .m_axi_rdata    (g_rdata),
        .m_axi_rresp    (g_rresp),
        .m_axi_rlast    (g_rlast),
        .m_axi_rvalid   (g_rvalid),
        .m_axi_rready   (g_rready),
        .smem_ld_we     (smem_ld_we_i),
        .smem_ld_addr   (smem_ld_addr_i),
        .smem_ld_wdata  (smem_ld_wdata_i),
        .smem_rd_addr   (smem_rd_addr_i),
        .smem_rd_en     (smem_rd_en_i),
        .smem_rd_data   (smem_rd_data_o)
    );

    tb_axi_mem #(.ADDR_W(64), .DATA_W(512)) u_mem (
        .clk         (clk),
        .aresetn     (aresetn),
        .rd_lat_i    (rd_lat_i),
        .wr_lat_i    (wr_lat_i),
        .addr_base_i (addr_base_i),
        .s_awaddr_i  (g_awaddr),
        .s_awlen_i   (g_awlen),
        .s_awsize_i  (g_awsize),
        .s_awburst_i (g_awburst),
        .s_awvalid_i (g_awvalid),
        .s_awready_o (g_awready),
        .s_wdata_i   (g_wdata),
        .s_wstrb_i   (g_wstrb),
        .s_wlast_i   (g_wlast),
        .s_wvalid_i  (g_wvalid),
        .s_wready_o  (g_wready),
        .s_bresp_o   (g_bresp),
        .s_bvalid_o  (g_bvalid),
        .s_bready_i  (g_bready),
        .s_araddr_i  (g_araddr),
        .s_arlen_i   (g_arlen),
        .s_arsize_i  (g_arsize),
        .s_arburst_i (g_arburst),
        .s_arvalid_i (g_arvalid),
        .s_arready_o (g_arready),
        .s_rdata_o   (g_rdata),
        .s_rresp_o   (g_rresp),
        .s_rlast_o   (g_rlast),
        .s_rvalid_o  (g_rvalid),
        .s_rready_i  (g_rready),
        .host_we_i   (host_we_i),
        .host_addr_i (host_addr_i),
        .host_wdata_i(host_wdata_i),
        .host_raddr_i(host_raddr_i),
        .host_rdata_o(host_rdata_o)
    );

endmodule
