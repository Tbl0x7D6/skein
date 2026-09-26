//! mask 单元：M 寄存器和 mask 指令的位运算，宽度 = lane 数。
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
    input  logic                clk,
    input  logic                aresetn,
    input  logic                init_i,      // 块开始：M = full
    input  logic [LANES-1:0]    full_i,      // warp 生成时的完整 mask
    input  logic                en_i,        // 本拍执行的是 mask 指令
    input  SK_pkg::sk_mask_e    op_i,
    input  logic [31:0]         ra_i,        // lane 0 的 GPR 操作数（warp 一致）
    input  logic [31:0]         rb_i,        // 同上，MAND/MANDN/MOR 的第二个操作数
    input  logic [LANES-1:0]    p_i,         // 谓词字（`.P`/`.PM`/`MCLR.P`）
    output logic [LANES-1:0]    m_o,         // 当前执行 mask M
    output logic [31:0]         rd_o,
    output logic                rd_we_o
);

    import SK_pkg::*;

    logic [LANES-1:0] m_q, m_d;
    logic             m_wr;
    logic [31:0]      value;
    logic             rd_wr;
    logic [31:0]      pred;      // p_i 零扩展
    logic [31:0]      mask;      // M 零扩展

    always_comb begin
        pred  = 32'(p_i);
        mask  = 32'(m_q);
        value = 32'd0;
        m_d   = m_q;
        m_wr  = 1'b0;
        rd_wr = 1'b1;

        unique case (op_i)
            SK_MASK_SAVE:   value = mask;                                // M -> rd
            SK_MASK_REST:   begin value = ra_i; m_wr = 1'b1; rd_wr = 1'b0; end
            SK_MASK_MOV:    value = ra_i;
            SK_MASK_NOT:    value = ~ra_i;
            SK_MASK_AND:    value = ra_i & rb_i;
            SK_MASK_ANDN:   value = ra_i & ~rb_i;
            SK_MASK_OR:     value = ra_i | rb_i;
            SK_MASK_AND_P:  value = ra_i & (pred & mask);
            SK_MASK_ANDN_P: value = ra_i & ~(pred & mask);
            SK_MASK_OR_P:   value = ra_i | (pred & mask);
            SK_MASK_CLR_P:  begin value = mask; m_wr = 1'b1; rd_wr = 1'b0; end
            SK_MASK_AND_PM: begin value = ra_i & (pred & mask); m_wr = 1'b1; end
            SK_MASK_ANDN_PM: begin value = ra_i & ~(pred & mask); m_wr = 1'b1; end
            SK_MASK_OR_PM:  begin value = ra_i | (pred & mask); m_wr = 1'b1; end
            default:        rd_wr = 1'b0;
        endcase

        // rd 一律被完整 mask 夹住
        value = value & 32'(full_i);
        // 写 M 的值：MREST 用 ra、MCLR.P 用 M & ~p、`.PM` 用刚算出来的 rd
        if (m_wr) begin
            unique case (op_i)
                SK_MASK_REST:  m_d = ra_i[LANES-1:0];
                SK_MASK_CLR_P: m_d = m_q & ~p_i;
                default:       m_d = value[LANES-1:0];
            endcase
        end
        m_d = m_d & full_i;
    end

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            m_q <= full_i;
        end else if (init_i) begin
            m_q <= full_i;
        end else if (en_i && m_wr) begin
            m_q <= m_d;
        end
    end

    assign m_o     = m_q;
    assign rd_o    = value;
    assign rd_we_o = en_i && rd_wr;

endmodule
