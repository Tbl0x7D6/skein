//! 指令存储：BRAM，取指同步读，主机通过装载口写指令镜像。
//!
//! 取指：给出 `pc_i` 之后下一拍 `insn_o` 有效，`pc_oob_o` 与它同拍（取指超出 IMEM，
//! 对应 STATUS = PC_OOB）。装载口 P1 由 testbench 驱动，P6 接到 AXI-Lite。

module SK_imem #(
    parameter int DEPTH = 4096            // 指令条数（16 KB / 4）
) (
    input  logic                     clk,
    // 取指
    input  logic [15:0]              pc_i,
    output logic [31:0]              insn_o,
    output logic                     pc_oob_o,
    // 主机装载
    input  logic                     ld_we_i,
    input  logic [$clog2(DEPTH)-1:0] ld_addr_i,
    input  logic [31:0]              ld_wdata_i
);

    localparam int ADDR_W = $clog2(DEPTH);

    SK_dp_ram #(.WIDTH(32), .DEPTH(DEPTH)) u_ram (
        .clk     (clk),
        .we_i    (ld_we_i),
        .strb_i  ('1),                      // 装载口整字写入
        .waddr_i (ld_addr_i),
        .wdata_i (ld_wdata_i),
        .re_i    (1'b1),
        .raddr_i (pc_i[ADDR_W-1:0]),
        .rdata_o (insn_o)
    );

    // 和 insn_o 同拍：都是"上一拍的地址"的结果
    always_ff @(posedge clk) begin
        pc_oob_o <= (32'(pc_i) >= 32'(DEPTH));
    end

endmodule
