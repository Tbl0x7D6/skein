//! 每个 warp × 每个 lane 一套通用寄存器：WARPS × LANES × NUM_GPR × WIDTH，
//! 组合读、每 warp 一个写口（per-lane 写使能）。
//!
//! `r0` 恒为 0（写 r0 被丢弃）。第三个读口给 `FMA` 的 `rd`（既读又写）和 `STG`/`STS`
//! 的源寄存器（它的编号也在 rd 字段），第四个是仿真用的扫描口。不要用 BRAM：见
//! docs/design.md §12.5。
//!
//! 一个写口要同时服务三件事，`SK_core` 负责按 warp 选源，并在流水线提交和 LSU 回写
//! 撞上同一个 warp 时让 LSU 等一拍（见 docs/practice.md §1.9）：
//!   - 流水线提交（一个 warp，per-lane 写使能）；
//!   - `LDG`/`LDS` 的数据回写（一个 warp 的一个 lane）；
//!   - 块开始的清零（所有 warp 的所有 lane）。

module SK_regfile #(
    parameter int WARPS   = 4,
    parameter int LANES   = 4,
    parameter int NUM_GPR = 32,
    parameter int WIDTH   = 32,
    parameter int WARP_W  = (WARPS > 1) ? $clog2(WARPS) : 1,
    parameter int LANE_W  = (LANES > 1) ? $clog2(LANES) : 1,
    parameter int GPR_W   = (NUM_GPR > 1) ? $clog2(NUM_GPR) : 1
) (
    input  logic                                   clk,
    input  logic                                   clear_i,     // 块开始：架构状态清零
    // 写口：每个 warp 一个，per-lane 写使能
    input  logic [WARPS-1:0]                       we_i,
    input  logic [WARPS-1:0][LANES-1:0]            wlane_i,
    input  logic [WARPS-1:0][GPR_W-1:0]            waddr_i,
    input  logic [WARPS-1:0][LANES-1:0][WIDTH-1:0] wdata_i,
    // 读口 A / B / C：一次只读一个 warp（就是译码级那条指令的 warp）
    input  logic [WARP_W-1:0]                      rd_wid_i,
    input  logic [GPR_W-1:0]                       raddr_a_i,
    output logic [LANES-1:0][WIDTH-1:0]            rdata_a_o,
    input  logic [GPR_W-1:0]                       raddr_b_i,
    output logic [LANES-1:0][WIDTH-1:0]            rdata_b_o,
    input  logic [GPR_W-1:0]                       raddr_c_i,
    output logic [LANES-1:0][WIDTH-1:0]            rdata_c_o,
    // 调试扫描口
    input  logic [WARP_W-1:0]                      rd_wid_dbg_i,
    input  logic [LANE_W-1:0]                      rd_lane_dbg_i,
    input  logic [GPR_W-1:0]                       raddr_dbg_i,
    output logic [WIDTH-1:0]                       rdata_dbg_o
);

    logic [WIDTH-1:0] regs_q [WARPS][LANES][NUM_GPR];

    always_comb begin
        for (int lane = 0; lane < LANES; lane++) begin
            rdata_a_o[lane] = (raddr_a_i == '0) ? '0 : regs_q[rd_wid_i][lane][raddr_a_i];
            rdata_b_o[lane] = (raddr_b_i == '0) ? '0 : regs_q[rd_wid_i][lane][raddr_b_i];
            rdata_c_o[lane] = (raddr_c_i == '0) ? '0 : regs_q[rd_wid_i][lane][raddr_c_i];
        end
        rdata_dbg_o = (raddr_dbg_i == '0)
                    ? '0
                    : regs_q[rd_wid_dbg_i][rd_lane_dbg_i][raddr_dbg_i];
    end

    generate
        for (genvar warp = 0; warp < WARPS; warp++) begin : g_warp
            for (genvar lane = 0; lane < LANES; lane++) begin : g_lane
                always_ff @(posedge clk) begin
                    if (clear_i) begin
                        for (int i = 0; i < NUM_GPR; i++) begin
                            regs_q[warp][lane][i] <= '0;
                        end
                    end else if (we_i[warp] && wlane_i[warp][lane] && (waddr_i[warp] != '0)) begin
                        regs_q[warp][lane][waddr_i[warp]] <= wdata_i[warp][lane];
                    end
                end
            end
        end
    endgenerate

endmodule
