//! 上板顶层（P6）：SK_ctrl（AXI4-Lite 控制）+ SK_core + AXI4 主口。
//!
//! 打包成 Vitis RTL kernel 的是外面的 `SK_afu`（rtl/top/SK_afu.sv）：它只多两件事——
//! 把 testbench 专用的 shared memory 主机口 tie 掉、把 master 位宽对到 shell 的
//! 512-bit（P6.2）。仿真里 `tb_top` 直接实例化这个模块，用 AXI-Lite 主机驱动它，
//! 跑的就是板上的主机流程（写 IMEM → 写参数 → start → 轮询 done → 用扫描口读状态）。
//!
//! `smem_*` 是 testbench 专用口：装 shared 初态、读快照。板上没有这个通路，
//! kernel 自己负责往 shared 里搬数据。

`include "SK_config.vh"

module SK_top (
    input  logic        clk,
    input  logic        aresetn,
    // ---- AXI4-Lite 控制口（主机）----
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [11:0] s_awaddr,
    input  logic        s_wvalid,
    output logic        s_wready,
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    output logic        s_bvalid,
    input  logic        s_bready,
    output logic [1:0]  s_bresp,
    input  logic        s_arvalid,
    output logic        s_arready,
    input  logic [11:0] s_araddr,
    output logic        s_rvalid,
    input  logic        s_rready,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp,
    // ---- AXI4 主口（global memory，512-bit 行事务）----
    output logic [63:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [511:0] m_axi_wdata,
    output logic [63:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [63:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [511:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    // ---- testbench 专用：shared memory 主机口（SK_afu 里 tie 0）----
    input  logic        smem_ld_we,
    input  logic [12:0] smem_ld_addr,       // 字地址
    input  logic [31:0] smem_ld_wdata,
    input  logic [12:0] smem_rd_addr,       // 字地址
    input  logic        smem_rd_en,
    output logic [31:0] smem_rd_data
);

    logic [31:0] sreg [16];
    logic        start_pulse;
    logic        perf_clear;
    logic        imem_we;
    logic [11:0] imem_addr;
    logic [31:0] imem_wdata;
    logic [7:0]  dbg_addr;
    logic [1:0]  dbg_wid;
    logic [1:0]  dbg_lane;
    logic [31:0] dbg_data;
    logic [15:0] shape;
    logic [3:0]  status;
    logic        done;
    logic [63:0] gmem_base;

    SK_ctrl u_ctrl (
        .clk            (clk),
        .aresetn        (aresetn),
        .s_awvalid      (s_awvalid),
        .s_awready      (s_awready),
        .s_awaddr       (s_awaddr),
        .s_wvalid       (s_wvalid),
        .s_wready       (s_wready),
        .s_wdata        (s_wdata),
        .s_wstrb        (s_wstrb),
        .s_bvalid       (s_bvalid),
        .s_bready       (s_bready),
        .s_bresp        (s_bresp),
        .s_arvalid      (s_arvalid),
        .s_arready      (s_arready),
        .s_araddr       (s_araddr),
        .s_rvalid       (s_rvalid),
        .s_rready       (s_rready),
        .s_rdata        (s_rdata),
        .s_rresp        (s_rresp),
        .sreg_o         (sreg),
        .start_o        (start_pulse),
        .perf_clear_o   (perf_clear),
        .imem_we_o      (imem_we),
        .imem_addr_o    (imem_addr),
        .imem_wdata_o   (imem_wdata),
        .dbg_addr_o     (dbg_addr),
        .dbg_wid_o      (dbg_wid),
        .dbg_lane_o     (dbg_lane),
        .dbg_data_i     (dbg_data),
        .shape_i        (shape),
        .core_status_i  (status),
        .core_done_i    (done),
        .gmem_base_o    (gmem_base)
    );

    SK_core u_core (
        .clk            (clk),
        .aresetn        (aresetn),
        .start_i        (start_pulse),
        .perf_clear_i   (perf_clear),
        .sreg_i         (sreg),
        .shape_o        (shape),
        .imem_we_i      (imem_we),
        .imem_addr_i    (imem_addr),
        .imem_wdata_i   (imem_wdata),
        .gmem_base_i    (gmem_base),
        .smem_ld_we_i   (smem_ld_we),
        .smem_ld_addr_i (smem_ld_addr),
        .smem_ld_wdata_i(smem_ld_wdata),
        .smem_rd_addr_i (smem_rd_addr),
        .smem_rd_en_i   (smem_rd_en),
        .smem_rd_data_o (smem_rd_data),
        .m_axi_awaddr_o (m_axi_awaddr),
        .m_axi_awlen_o  (m_axi_awlen),
        .m_axi_awsize_o (m_axi_awsize),
        .m_axi_awburst_o(m_axi_awburst),
        .m_axi_awvalid_o(m_axi_awvalid),
        .m_axi_awready_i(m_axi_awready),
        .m_axi_wdata_o  (m_axi_wdata),
        .m_axi_wstrb_o  (m_axi_wstrb),
        .m_axi_wlast_o  (m_axi_wlast),
        .m_axi_wvalid_o (m_axi_wvalid),
        .m_axi_wready_i (m_axi_wready),
        .m_axi_bresp_i  (m_axi_bresp),
        .m_axi_bvalid_i (m_axi_bvalid),
        .m_axi_bready_o (m_axi_bready),
        .m_axi_araddr_o (m_axi_araddr),
        .m_axi_arlen_o  (m_axi_arlen),
        .m_axi_arsize_o (m_axi_arsize),
        .m_axi_arburst_o(m_axi_arburst),
        .m_axi_arvalid_o(m_axi_arvalid),
        .m_axi_arready_i(m_axi_arready),
        .m_axi_rdata_i  (m_axi_rdata),
        .m_axi_rresp_i  (m_axi_rresp),
        .m_axi_rlast_i  (m_axi_rlast),
        .m_axi_rvalid_i (m_axi_rvalid),
        .m_axi_rready_o (m_axi_rready),
        .status_o       (status),
        .done_o         (done),
        .dbg_addr_i     (dbg_addr),
        .dbg_wid_i      (dbg_wid),
        .dbg_lane_i     (dbg_lane),
        .dbg_data_o     (dbg_data)
    );

endmodule
