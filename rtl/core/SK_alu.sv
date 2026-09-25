//! 算术单元 + 比较器：RALU、立即数 ALU 和 `CMP` 的条件判断都在这里。
//!
//! 译码已经把立即数扩展好（`ADDI`/`SLTI` 有符号、`ANDI`/`ORI`/`SHLI` 零扩展、
//! `LUI`/`LUM` 已经移位），所以这里只做位运算。`FMA` 的累加值从 `acc_i` 来。

module SK_alu (
    input  SK_pkg::sk_alu_e alu_op_i,
    input  SK_pkg::sk_cmp_e cmp_op_i,
    input  logic [31:0]     a_i,
    input  logic [31:0]     b_i,
    input  logic [31:0]     acc_i,       // FMA 的 rd 旧值
    output logic [31:0]     alu_o,
    output logic            cmp_o        // CMP 的结果（0/1）
);

    import SK_pkg::*;

    logic eq, lt, ltu;

    assign eq  = (a_i == b_i);
    assign lt  = ($signed(a_i) < $signed(b_i));
    assign ltu = (a_i < b_i);

    always_comb begin
        unique case (alu_op_i)
            SK_ALU_ADD, SK_ALU_ADDI: alu_o = a_i + b_i;
            SK_ALU_SUB:              alu_o = a_i - b_i;
            SK_ALU_AND, SK_ALU_ANDI: alu_o = a_i & b_i;
            SK_ALU_OR, SK_ALU_ORI:   alu_o = a_i | b_i;
            SK_ALU_XOR:              alu_o = a_i ^ b_i;
            SK_ALU_SHL, SK_ALU_SHLI: alu_o = a_i << b_i[4:0];
            SK_ALU_SHR:              alu_o = a_i >> b_i[4:0];
            SK_ALU_SAR:              alu_o = $signed(a_i) >>> b_i[4:0];
            SK_ALU_SLT, SK_ALU_SLTI: alu_o = {31'd0, lt};
            SK_ALU_SLTU:             alu_o = {31'd0, ltu};
            SK_ALU_MUL:              alu_o = a_i * b_i;
            SK_ALU_MOV:              alu_o = a_i;
            SK_ALU_FMA:              alu_o = acc_i + a_i * b_i;
            SK_ALU_LUI:              alu_o = b_i;
            SK_ALU_LUM:              alu_o = a_i | b_i;
            default:                 alu_o = 32'd0;
        endcase
    end

    always_comb begin
        unique case (cmp_op_i)
            SK_CMP_EQ:  cmp_o = eq;
            SK_CMP_NE:  cmp_o = !eq;
            SK_CMP_LT:  cmp_o = lt;
            SK_CMP_GE:  cmp_o = !lt;
            SK_CMP_LTU: cmp_o = ltu;
            SK_CMP_GEU: cmp_o = !ltu;
            default:    cmp_o = 1'b0;
        endcase
    end

endmodule
