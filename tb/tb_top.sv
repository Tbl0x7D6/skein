//! Verilator 顶层：SK_core + AXI 从机（内存模型）。C++ 侧只驱动/观察这里的简单端口，
//! AXI 握手全部由 SV 侧的时序逻辑完成（tb_axi_mem.sv）。
//!
//! shared memory 在核内（`SK_smem`），这里只留主机装载/快照口：testbench 装初态、
//! 按 case 的窗口读回来比对；global memory 挂在 AXI 从机后面，走核的 AXI4 主口。

`include "SK_config.vh"

module tb_top #(
    parameter int WARP_W = (`SK_NUM_WARPS > 1) ? $clog2(`SK_NUM_WARPS) : 1,
    parameter int LANE_W = (`SK_NUM_LANES > 1) ? $clog2(`SK_NUM_LANES) : 1,
    parameter int SMEM_W = $clog2((`SK_SMEM_KB * 1024) / 4)
) (
    input  logic                clk,
    input  logic                aresetn,
    input  logic                start_i,
    input  logic [31:0]         sreg_i [16],
    input  logic                imem_we_i,
    input  logic [11:0]         imem_addr_i,
    input  logic [31:0]         imem_wdata_i,
    output logic [15:0]         shape_o,
    output logic [3:0]          status_o,
    output logic                done_o,
    input  logic [7:0]          dbg_addr_i,
    input  logic [WARP_W-1:0]   dbg_wid_i,
    input  logic [LANE_W-1:0]   dbg_lane_i,
    output logic [31:0]         dbg_data_o,
    // shared memory 主机口（核内 SRAM，testbench 装初态 / 读快照）
    input  logic                smem_ld_we_i,
    input  logic [SMEM_W-1:0]   smem_ld_addr_i,
    input  logic [31:0]         smem_ld_wdata_i,
    input  logic [SMEM_W-1:0]   smem_rd_addr_i,
    input  logic                smem_rd_en_i,
    output logic [31:0]         smem_rd_data_o,
    // global memory 主机口（AXI 从机后面的存储，字节地址）
    input  logic                host_we_i,
    input  logic [31:0]         host_addr_i,
    input  logic [31:0]         host_wdata_i,
    input  logic [31:0]         host_raddr_i,
    output logic [31:0]         host_rdata_o,
    input  logic [7:0]          rd_lat_i,
    input  logic [7:0]          wr_lat_i
);

    // AXI4
    logic [31:0] m_axi_awaddr, m_axi_araddr;
    logic [63:0] m_axi_rdata_s;
    logic [7:0]  m_axi_awlen, m_axi_arlen, m_axi_wstrb;
    logic [2:0]  m_axi_awsize, m_axi_arsize;
    logic [1:0]  m_axi_awburst, m_axi_arburst, m_axi_bresp, m_axi_rresp;
    logic        m_axi_awvalid, m_axi_awready, m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic        m_axi_bvalid, m_axi_bready;
    logic        m_axi_arvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid, m_axi_rready;
    logic [63:0] m_axi_wdata;

    SK_core u_core (
        .clk             (clk),
        .aresetn         (aresetn),
        .start_i         (start_i),
        .sreg_i          (sreg_i),
        .shape_o         (shape_o),
        .imem_we_i       (imem_we_i),
        .imem_addr_i     (imem_addr_i),
        .imem_wdata_i    (imem_wdata_i),
        .smem_ld_we_i    (smem_ld_we_i),
        .smem_ld_addr_i  (smem_ld_addr_i),
        .smem_ld_wdata_i (smem_ld_wdata_i),
        .smem_rd_addr_i  (smem_rd_addr_i),
        .smem_rd_en_i    (smem_rd_en_i),
        .smem_rd_data_o  (smem_rd_data_o),
        .m_axi_awaddr_o  (m_axi_awaddr),
        .m_axi_awlen_o   (m_axi_awlen),
        .m_axi_awsize_o  (m_axi_awsize),
        .m_axi_awburst_o (m_axi_awburst),
        .m_axi_awvalid_o (m_axi_awvalid),
        .m_axi_awready_i (m_axi_awready),
        .m_axi_wdata_o   (m_axi_wdata),
        .m_axi_wstrb_o   (m_axi_wstrb),
        .m_axi_wlast_o   (m_axi_wlast),
        .m_axi_wvalid_o  (m_axi_wvalid),
        .m_axi_wready_i  (m_axi_wready),
        .m_axi_bresp_i   (m_axi_bresp),
        .m_axi_bvalid_i  (m_axi_bvalid),
        .m_axi_bready_o  (m_axi_bready),
        .m_axi_araddr_o  (m_axi_araddr),
        .m_axi_arlen_o   (m_axi_arlen),
        .m_axi_arsize_o  (m_axi_arsize),
        .m_axi_arburst_o (m_axi_arburst),
        .m_axi_arvalid_o (m_axi_arvalid),
        .m_axi_arready_i (m_axi_arready),
        .m_axi_rdata_i   (m_axi_rdata_s),
        .m_axi_rresp_i   (m_axi_rresp),
        .m_axi_rlast_i   (m_axi_rlast),
        .m_axi_rvalid_i  (m_axi_rvalid),
        .m_axi_rready_o  (m_axi_rready),
        .status_o        (status_o),
        .done_o          (done_o),
        .dbg_addr_i      (dbg_addr_i),
        .dbg_wid_i       (dbg_wid_i),
        .dbg_lane_i      (dbg_lane_i),
        .dbg_data_o      (dbg_data_o)
    );

    tb_axi_mem u_mem (
        .clk        (clk),
        .aresetn    (aresetn),
        .rd_lat_i   (rd_lat_i),
        .wr_lat_i   (wr_lat_i),
        .s_awaddr_i (m_axi_awaddr),
        .s_awlen_i  (m_axi_awlen),
        .s_awsize_i (m_axi_awsize),
        .s_awburst_i(m_axi_awburst),
        .s_awvalid_i(m_axi_awvalid),
        .s_awready_o(m_axi_awready),
        .s_wdata_i  (m_axi_wdata),
        .s_wstrb_i  (m_axi_wstrb),
        .s_wlast_i  (m_axi_wlast),
        .s_wvalid_i (m_axi_wvalid),
        .s_wready_o (m_axi_wready),
        .s_bresp_o  (m_axi_bresp),
        .s_bvalid_o (m_axi_bvalid),
        .s_bready_i (m_axi_bready),
        .s_araddr_i (m_axi_araddr),
        .s_arlen_i  (m_axi_arlen),
        .s_arsize_i (m_axi_arsize),
        .s_arburst_i(m_axi_arburst),
        .s_arvalid_i(m_axi_arvalid),
        .s_arready_o(m_axi_arready),
        .s_rdata_o  (m_axi_rdata_s),
        .s_rresp_o  (m_axi_rresp),
        .s_rlast_o  (m_axi_rlast),
        .s_rvalid_o (m_axi_rvalid),
        .s_rready_i (m_axi_rready),
        .host_we_i   (host_we_i),
        .host_addr_i (host_addr_i),
        .host_wdata_i(host_wdata_i),
        .host_raddr_i(host_raddr_i),
        .host_rdata_o(host_rdata_o)
    );

endmodule
