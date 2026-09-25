//! 简单双口 RAM：一个写端口、一个同步读端口，读数据寄存一拍。
//!
//! 综合模板见 docs/practice.md §1.6：读地址和读数据都寄存才能落成 BRAM；数据通路
//! 不加复位，靠"没有有效请求就不会读"。

module SK_dp_ram #(
    parameter int WIDTH  = 32,
    parameter int DEPTH  = 1024,          // 字数
    parameter int STRB_W = WIDTH / 8      // 写字节使能
) (
    input  logic                     clk,
    // 写端口
    input  logic                     we_i,
    input  logic [STRB_W-1:0]        strb_i,
    input  logic [$clog2(DEPTH)-1:0] waddr_i,
    input  logic [WIDTH-1:0]         wdata_i,
    // 读端口（同步读）
    input  logic                     re_i,
    input  logic [$clog2(DEPTH)-1:0] raddr_i,
    output logic [WIDTH-1:0]         rdata_o
);

    logic [WIDTH-1:0] mem_q [DEPTH];

    always_ff @(posedge clk) begin
        if (we_i) begin
            for (int i = 0; i < STRB_W; i++) begin
                if (strb_i[i]) begin
                    mem_q[waddr_i][8*i +: 8] <= wdata_i[8*i +: 8];
                end
            end
        end
        if (re_i) begin
            rdata_o <= mem_q[raddr_i];
        end
    end

endmodule
