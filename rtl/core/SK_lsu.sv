//! 访存单元：地址计算、对齐检查、shared/global 两条通道的读写使能。
//!
//! 越界由存储侧报（`*_fault_i`：片上存储知道自己的容量，片外由 AXI 从设备报错），
//! 对齐由这里查；先报对齐再报越界，和黄金模型的顺序一致（docs/design.md §5.5）。
//! P1 是阻塞式访问：数据同一拍回来，没有 scoreboard。

module SK_lsu (
    input  logic        op_en_i,      // 本条指令是访存而且本拍有效（lane 活跃）
    input  logic        store_i,
    input  logic        global_i,
    input  logic [31:0] base_i,
    input  logic [31:0] imm_i,
    input  logic [31:0] wdata_i,
    input  logic [31:0] smem_rdata_i,
    input  logic        smem_fault_i,
    input  logic [31:0] gmem_rdata_i,
    input  logic        gmem_fault_i,
    output logic [31:0] addr_o,
    output logic [31:0] wdata_o,
    output logic        smem_we_o,
    output logic        gmem_we_o,
    output logic [31:0] rdata_o,
    output logic [3:0]  fault_o       // SK_STATUS_*，OK 表示没出错
);

    import SK_pkg::*;

    logic unaligned;
    logic wr_en;

    assign addr_o    = base_i + imm_i;
    assign wdata_o   = wdata_i;
    assign unaligned = (addr_o[1:0] != 2'b00);
    assign rdata_o   = global_i ? gmem_rdata_i : smem_rdata_i;

    always_comb begin
        fault_o = SK_STATUS_OK;
        if (op_en_i) begin
            if (unaligned) begin
                fault_o = SK_STATUS_UNALIGNED;
            end else if (global_i && gmem_fault_i) begin
                fault_o = SK_STATUS_GMEM_OOB;
            end else if (!global_i && smem_fault_i) begin
                fault_o = SK_STATUS_SMEM_OOB;
            end
        end
    end

    // 报错就不落存储：黄金模型也是在检查地址时就结束，不会写出去
    assign wr_en     = op_en_i && store_i && (fault_o == SK_STATUS_OK);
    assign smem_we_o = wr_en && !global_i;
    assign gmem_we_o = wr_en && global_i;

endmodule
