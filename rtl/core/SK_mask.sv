//! mask 单元：mask 指令的位运算。纯组合——`M` 本身每个 warp 一份，存在 `SK_core`
//! 里（`m_q`），提交级才写回去，这样多 warp 共用一个组合逻辑。
//!
//! mask 指令是 warp 级操作，不受 M 门控、结果写所有 lane。`.P`/`.PM` 把谓词按
//! `p & M` 读，之后做普通位运算（结果不强制 ⊆ M）；`.PM` 同一拍写 `rd` 和 `M`，
//! 写入 M 的值用旧 M 算出来。语义见 docs/design.md §5.4。
//!
//! GPR 操作数（MREST/MAND/…）要求全 lane 一致，这里直接取 lane 0 的读数据；一致性
//! 检查是黄金模型的模型侧断言（docs/design.md §6.5），硬件不查。

module SK_mask #(
    parameter int LANES = 4
) (
    input  logic                [LANES-1:0] full_i,     // warp 生成时的完整 mask
    input  logic                [LANES-1:0] m_i,        // 当前执行 mask（旧值）
    input  SK_pkg::sk_mask_e    op_i,
    input  logic                [31:0]      ra_i,       // lane 0 的 GPR 操作数（warp 一致）
    input  logic                [31:0]      rb_i,       // 同上，MAND/MANDN/MOR 的第二个操作数
    input  logic                [LANES-1:0] p_i,        // 谓词字（`.P`/`.PM`/`MCLR.P`）
    output logic                [31:0]      value_o,    // 写 rd 的值
    output logic                            rd_we_o,
    output logic                [LANES-1:0] m_o,        // 写 M 的值（m_we_o 为 1 时有效）
    output logic                            m_we_o
);

    import SK_pkg::*;

    logic [31:0] pred;      // p_i 零扩展
    logic [31:0] mask;      // M 零扩展
    logic [31:0] value;

    always_comb begin
        pred   = 32'(p_i);
        mask   = 32'(m_i);
        value  = 32'd0;
        m_o    = m_i;
        m_we_o = 1'b0;
        rd_we_o = 1'b1;

        unique case (op_i)
            SK_MASK_SAVE:   value = mask;                                 // M -> rd
            SK_MASK_REST:   begin value = ra_i; m_o = ra_i[LANES-1:0]; m_we_o = 1'b1; rd_we_o = 1'b0; end
            SK_MASK_MOV:    value = ra_i;
            SK_MASK_NOT:    value = ~ra_i;
            SK_MASK_AND:    value = ra_i & rb_i;
            SK_MASK_ANDN:   value = ra_i & ~rb_i;
            SK_MASK_OR:     value = ra_i | rb_i;
            SK_MASK_AND_P:  value = ra_i & (pred & mask);
            SK_MASK_ANDN_P: value = ra_i & ~(pred & mask);
            SK_MASK_OR_P:   value = ra_i | (pred & mask);
            SK_MASK_CLR_P:  begin value = mask; m_o = m_i & ~p_i; m_we_o = 1'b1; rd_we_o = 1'b0; end
            SK_MASK_AND_PM: begin value = ra_i & (pred & mask); m_we_o = 1'b1; end
            SK_MASK_ANDN_PM: begin value = ra_i & ~(pred & mask); m_we_o = 1'b1; end
            SK_MASK_OR_PM:  begin value = ra_i | (pred & mask); m_we_o = 1'b1; end
            default:        rd_we_o = 1'b0;
        endcase

        // rd 一律被完整 mask 夹住；写 M 的值用刚算出来的 rd（`.PM`），最后也夹一次
        value = value & 32'(full_i);
        if (m_we_o && (op_i != SK_MASK_REST) && (op_i != SK_MASK_CLR_P)) begin
            m_o = value[LANES-1:0];
        end
        m_o = m_o & full_i;
    end

    assign value_o = value;

endmodule
