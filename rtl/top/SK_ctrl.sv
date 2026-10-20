//! 主机接口（P6）：AXI4-Lite 控制寄存器 + 启动序列 + IMEM 装载口 + 调试扫描口。
//!
//! 寄存器映射按 Vitis RTL kernel 的约定：`0x00` CTRL（bit0=start、bit1=done、
//! bit2=idle、bit3=ready）、`0x04/0x08/0x0C` GIE/IER/ISR（没有中断，留成兼容桩），
//! 参数从 `0x10` 起。完整表见 docs/design.md §5.6。
//!
//! 一次 launch：主机写 IMEM 镜像 → 写参数 → 写 `CTRL.start`。这里按 `GRID_DIM` 个
//! block 串行地脉冲 `start_o`，`S_BID` 跟着变；核在每个 block 开始时自己清 PC/M/
//! 谓词/寄存器堆（和黄金模型一致）。全部跑完置 done、记住 STATUS，直到下一次 start。
//! 忙碌时写 start 会被忽略（主机流程是"写参数 → 启动 → 轮询 done"）。
//!
//! 调试扫描口（`0x4C`-`0x54`）就是仿真里用的那套：选 (warp, lane) 读 GPR/谓词/M/PC，
//! 以及 `0x30`-`0x52` 的性能计数器。上板 bring-up 全靠它。

`include "SK_config.vh"

module SK_ctrl #(
    parameter int NUM_LANES = `SK_NUM_LANES,
    parameter int NUM_WARPS = `SK_NUM_WARPS,
    parameter int WARP_W    = (NUM_WARPS > 1) ? $clog2(NUM_WARPS) : 1,
    parameter int LANE_W    = (NUM_LANES > 1) ? $clog2(NUM_LANES) : 1,
    parameter int ADDR_W    = 12
) (
    input  logic              clk,
    input  logic              aresetn,
    // ---- AXI4-Lite 控制口（主机 / testbench）----
    input  logic              s_awvalid,
    output logic              s_awready,
    input  logic [ADDR_W-1:0] s_awaddr,
    input  logic              s_wvalid,
    output logic              s_wready,
    input  logic [31:0]       s_wdata,
    input  logic [3:0]        s_wstrb,
    output logic              s_bvalid,
    input  logic              s_bready,
    output logic [1:0]        s_bresp,
    input  logic              s_arvalid,
    output logic              s_arready,
    input  logic [ADDR_W-1:0] s_araddr,
    output logic              s_rvalid,
    input  logic              s_rready,
    output logic [31:0]       s_rdata,
    output logic [1:0]        s_rresp,
    // ---- 给核 ----
    output logic [31:0]       sreg_o [16],
    output logic              start_o,          // 一拍脉冲
    output logic              perf_clear_o,     // 一次 launch 的第一拍（清性能计数器）
    output logic              imem_we_o,
    output logic [11:0]       imem_addr_o,
    output logic [31:0]       imem_wdata_o,
    output logic [7:0]        dbg_addr_o,
    output logic [WARP_W-1:0] dbg_wid_o,
    output logic [LANE_W-1:0] dbg_lane_o,
    input  logic [31:0]       dbg_data_i,
    input  logic [15:0]       shape_i,
    input  logic [3:0]        core_status_i,
    input  logic              core_done_i,
    // 设备地址基址：核里的 32 位指针是偏移，AXI 地址 = 基址 + 偏移
    output logic [63:0]       gmem_base_o
);

    import SK_pkg::*;

    // 寄存器映射（docs/design.md §5.6）
    localparam logic [ADDR_W-1:0] A_CTRL      = 12'h000,
                                  A_GIE       = 12'h004,
                                  A_IER       = 12'h008,
                                  A_ISR       = 12'h00C,
                                  A_GRID      = 12'h010,
                                  A_BLOCK_DIM = 12'h014,
                                  A_PTR_A     = 12'h018,
                                  A_PTR_B     = 12'h01C,
                                  A_PTR_C     = 12'h020,
                                  A_ARG0      = 12'h024,
                                  A_ARG1      = 12'h028,
                                  A_ARG2      = 12'h02C,
                                  A_BASE_LO   = 12'h030,
                                  A_BASE_HI   = 12'h034,
                                  A_IMEM_ADDR = 12'h038,
                                  A_IMEM_DATA = 12'h03C,
                                  A_IMEM_WE   = 12'h040,
                                  A_STATUS    = 12'h044,
                                  A_SHAPE     = 12'h048,
                                  A_DBG_ADDR  = 12'h04C,
                                  A_DBG_SEL   = 12'h050,
                                  A_DBG_DATA  = 12'h054;

    // ---- AXI4-Lite 从机：写握手（AW → W → B）----
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_e;
    wstate_e           wstate_q;
    logic [ADDR_W-1:0] waddr_q;

    assign s_awready = (wstate_q == W_IDLE);
    assign s_wready  = (wstate_q == W_DATA);
    assign s_bvalid  = (wstate_q == W_RESP);
    assign s_bresp   = 2'b00;      // OKAY

    logic w_hs;
    assign w_hs = s_wvalid && s_wready;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            wstate_q <= W_IDLE;
            waddr_q  <= '0;
        end else begin
            unique case (wstate_q)
                W_IDLE: begin
                    if (s_awvalid) begin
                        waddr_q  <= s_awaddr;
                        wstate_q <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (s_wvalid) wstate_q <= W_RESP;
                end
                default: begin                        // W_RESP
                    if (s_bready) wstate_q <= W_IDLE;
                end
            endcase
        end
    end

    // ---- AXI4-Lite 从机：读握手（AR → R）----
    typedef enum logic {R_IDLE, R_DATA} rstate_e;
    rstate_e           rstate_q;
    logic [ADDR_W-1:0] raddr_q;
    logic [31:0]       rdata_q;

    assign s_arready = (rstate_q == R_IDLE);
    assign s_rvalid  = (rstate_q == R_DATA);
    assign s_rdata   = rdata_q;
    assign s_rresp   = 2'b00;      // OKAY

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            rstate_q <= R_IDLE;
            raddr_q  <= '0;
        end else begin
            unique case (rstate_q)
                R_IDLE: begin
                    if (s_arvalid) begin
                        raddr_q  <= s_araddr;
                        rstate_q <= R_DATA;
                    end
                end
                default: begin                        // R_DATA
                    if (s_rready) rstate_q <= R_IDLE;
                end
            endcase
        end
    end

    // ---- 主机写的寄存器 ----
    logic [15:0] grid_dim_q, block_dim_q;
    logic [31:0] ptr_q [3], arg_q [3];
    logic [31:0] base_lo_q, base_hi_q;
    logic [11:0] imem_addr_q;
    logic [31:0] imem_wdata_q;
    logic [31:0] gie_q, ier_q;
    logic [7:0]  dbg_addr_q;
    logic [31:0] dbg_sel_q;

    logic [31:0] wmask;
    assign wmask = {{8{s_wstrb[3]}}, {8{s_wstrb[2]}}, {8{s_wstrb[1]}}, {8{s_wstrb[0]}}};

    // 启动/装载是一次性动作，用组合脉冲，不占寄存器
    logic launch_now, imem_we_now;
    assign launch_now  = w_hs && (waddr_q == A_CTRL) && s_wdata[0] && s_wstrb[0];
    assign imem_we_now = w_hs && (waddr_q == A_IMEM_WE) && s_wdata[0] && s_wstrb[0];

    // ---- 启动序列：GRID_DIM 个 block 串行 ----
    typedef enum logic [1:0] {L_IDLE, L_LAUNCH, L_RUN} lstate_e;
    lstate_e     lstate_q;
    logic [15:0] bid_q;
    logic        done_q;
    logic [3:0]  status_q;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            lstate_q     <= L_IDLE;
            bid_q        <= '0;
            done_q       <= 1'b0;
            status_q     <= SK_STATUS_OK;
            grid_dim_q   <= 16'd1;
            block_dim_q  <= 16'(NUM_WARPS * NUM_LANES);
            base_lo_q    <= '0;
            base_hi_q    <= '0;
            imem_addr_q  <= '0;
            imem_wdata_q <= '0;
            gie_q        <= '0;
            ier_q        <= '0;
            dbg_addr_q   <= '0;
            dbg_sel_q    <= '0;
            for (int i = 0; i < 3; i++) begin
                ptr_q[i] <= '0;
                arg_q[i] <= '0;
            end
        end else begin
            if (w_hs) begin
                unique case (waddr_q)
                    A_GIE:       gie_q        <= (s_wdata & wmask) | (gie_q & ~wmask);
                    A_IER:       ier_q        <= (s_wdata & wmask) | (ier_q & ~wmask);
                    A_GRID:      grid_dim_q   <= s_wdata[15:0];
                    A_BLOCK_DIM: block_dim_q  <= s_wdata[15:0];
                    A_PTR_A:     ptr_q[0]     <= (s_wdata & wmask) | (ptr_q[0] & ~wmask);
                    A_PTR_B:     ptr_q[1]     <= (s_wdata & wmask) | (ptr_q[1] & ~wmask);
                    A_PTR_C:     ptr_q[2]     <= (s_wdata & wmask) | (ptr_q[2] & ~wmask);
                    A_ARG0:      arg_q[0]     <= (s_wdata & wmask) | (arg_q[0] & ~wmask);
                    A_ARG1:      arg_q[1]     <= (s_wdata & wmask) | (arg_q[1] & ~wmask);
                    A_ARG2:      arg_q[2]     <= (s_wdata & wmask) | (arg_q[2] & ~wmask);
                    A_BASE_LO:   base_lo_q    <= (s_wdata & wmask) | (base_lo_q & ~wmask);
                    A_BASE_HI:   base_hi_q    <= (s_wdata & wmask) | (base_hi_q & ~wmask);
                    A_IMEM_ADDR: imem_addr_q  <= s_wdata[11:0];
                    A_IMEM_DATA: imem_wdata_q <= (s_wdata & wmask) | (imem_wdata_q & ~wmask);
                    A_DBG_ADDR:  dbg_addr_q   <= s_wdata[7:0];
                    A_DBG_SEL:   dbg_sel_q    <= (s_wdata & wmask) | (dbg_sel_q & ~wmask);
                    default: ;
                endcase
            end

            if (launch_now && (lstate_q == L_IDLE)) begin
                done_q <= 1'b0;
                if (grid_dim_q == 16'd0) begin
                    status_q <= SK_STATUS_BAD_LAUNCH;
                    done_q   <= 1'b1;
                end else begin
                    bid_q    <= '0;
                    lstate_q <= L_LAUNCH;
                end
            end

            unique case (lstate_q)
                L_IDLE: ;
                L_LAUNCH: begin
                    // start_o 在 L_LAUNCH 这一拍拉高；核在 S_DONE/S_IDLE 都能重新开始
                    lstate_q <= L_RUN;
                end
                default: begin                     // L_RUN
                    if (core_done_i) begin
                        status_q <= core_status_i;
                        if ((core_status_i != SK_STATUS_OK) || (bid_q + 16'd1 >= grid_dim_q)) begin
                            done_q   <= 1'b1;
                            lstate_q <= L_IDLE;
                        end else begin
                            bid_q    <= bid_q + 16'd1;
                            lstate_q <= L_LAUNCH;
                        end
                    end
                end
            endcase
        end
    end

    assign start_o        = (lstate_q == L_LAUNCH);
    assign perf_clear_o   = (lstate_q == L_LAUNCH) && (bid_q == 16'd0);
    assign imem_we_o      = imem_we_now;
    assign imem_addr_o    = imem_addr_q;
    assign imem_wdata_o   = imem_wdata_q;
    assign dbg_addr_o = dbg_addr_q;
    assign dbg_lane_o = dbg_sel_q[LANE_W-1:0];
    assign dbg_wid_o  = dbg_sel_q[LANE_W +: WARP_W];
    assign gmem_base_o = {base_hi_q, base_lo_q};

    // ---- 特殊寄存器：主机写参数、硬件补容量和 BID ----
    always_comb begin
        sreg_o = '{default: '0};
        sreg_o[SK_SREG_WARPSZ]    = 32'(NUM_LANES);
        sreg_o[SK_SREG_NWARP]     = 32'(NUM_WARPS);
        sreg_o[SK_SREG_GRID]      = {16'd0, grid_dim_q};
        sreg_o[SK_SREG_BID]       = {16'd0, bid_q};
        sreg_o[SK_SREG_BLOCK_DIM] = {16'd0, block_dim_q};
        sreg_o[SK_SREG_STATUS]    = {28'd0, core_status_i};
        sreg_o[SK_SREG_PTR_A]     = ptr_q[0];
        sreg_o[SK_SREG_PTR_B]     = ptr_q[1];
        sreg_o[SK_SREG_PTR_C]     = ptr_q[2];
        sreg_o[SK_SREG_ARG0]      = arg_q[0];
        sreg_o[SK_SREG_ARG1]      = arg_q[1];
        sreg_o[SK_SREG_ARG2]      = arg_q[2];
    end

    // ---- 读回路（rvalid 跟在 ar 一拍之后，读出不改状态）----
    always_comb begin
        rdata_q = '0;
        unique case (raddr_q)
            A_CTRL:      rdata_q = {28'd0, (lstate_q == L_IDLE), (lstate_q == L_IDLE), done_q, 1'b0};
            A_GIE:       rdata_q = gie_q;
            A_IER:       rdata_q = ier_q;
            A_ISR:       rdata_q = '0;
            A_GRID:      rdata_q = {16'd0, grid_dim_q};
            A_BLOCK_DIM: rdata_q = {16'd0, block_dim_q};
            A_PTR_A:     rdata_q = ptr_q[0];
            A_PTR_B:     rdata_q = ptr_q[1];
            A_PTR_C:     rdata_q = ptr_q[2];
            A_ARG0:      rdata_q = arg_q[0];
            A_ARG1:      rdata_q = arg_q[1];
            A_ARG2:      rdata_q = arg_q[2];
            A_BASE_LO:   rdata_q = base_lo_q;
            A_BASE_HI:   rdata_q = base_hi_q;
            A_STATUS:    rdata_q = {28'd0, status_q};
            A_SHAPE:     rdata_q = {16'd0, shape_i};
            A_DBG_DATA:  rdata_q = dbg_data_i;
            default:     rdata_q = '0;
        endcase
    end

endmodule
