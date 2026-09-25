//! 每个 lane 一套通用寄存器：NUM_GPR × WIDTH，LUTRAM/FF，3 读 1 写，组合读。
//!
//! `r0` 恒为 0（写 r0 被丢弃）。第三个读口给 `FMA` 的 `rd`（既读又写）和 `STG`/`STS`
//! 的源寄存器（它的编号也在 rd 字段）。不要用 BRAM：见 docs/design.md §12.5。
//!
//! 第 4 个读口是仿真用的扫描口（P1 的 testbench 靠它把 GPR 和黄金模型逐寄存器对拍），
//! 不被指令使用；上板前可以去掉。

module SK_regfile #(
    parameter int NUM_GPR = 32,
    parameter int WIDTH   = 32
) (
    input  logic                       clk,
    input  logic                       clear_i,      // 块开始：架构状态清零
    // 写口
    input  logic                       we_i,
    input  logic [$clog2(NUM_GPR)-1:0] waddr_i,
    input  logic [WIDTH-1:0]           wdata_i,
    // 读口 A / B / C
    input  logic [$clog2(NUM_GPR)-1:0] raddr_a_i,
    output logic [WIDTH-1:0]           rdata_a_o,
    input  logic [$clog2(NUM_GPR)-1:0] raddr_b_i,
    output logic [WIDTH-1:0]           rdata_b_o,
    input  logic [$clog2(NUM_GPR)-1:0] raddr_c_i,
    output logic [WIDTH-1:0]           rdata_c_o,
    // 调试扫描口
    input  logic [$clog2(NUM_GPR)-1:0] raddr_dbg_i,
    output logic [WIDTH-1:0]           rdata_dbg_o
);

    logic [WIDTH-1:0] regs_q [NUM_GPR];

    always_comb begin
        rdata_a_o = (raddr_a_i == '0) ? '0 : regs_q[raddr_a_i];
        rdata_b_o = (raddr_b_i == '0) ? '0 : regs_q[raddr_b_i];
        rdata_c_o = (raddr_c_i == '0) ? '0 : regs_q[raddr_c_i];
        rdata_dbg_o = (raddr_dbg_i == '0) ? '0 : regs_q[raddr_dbg_i];
    end

    always_ff @(posedge clk) begin
        if (clear_i) begin
            for (int i = 0; i < NUM_GPR; i++) begin
                regs_q[i] <= '0;
            end
        end else if (we_i && waddr_i != '0) begin
            regs_q[waddr_i] <= wdata_i;
        end
    end

endmodule
