//! 译码：指令字 -> 控制信号。纯组合，和 tools/src/isa.rs 的 Insn::decode 一一对应。
//!
//! 主操作码按"类 + 类内子码"分配（docs/design.md §5.3）：`op[5:4]` 是类、`op[3:0]`
//! 是子码。这里同时做保留编码检查：不认识的类/子码/func、非法的谓词字段和特殊
//! 寄存器号都译成 `SK_OP_ILLEGAL`，由执行级报 `BAD_INSN`。

`include "SK_config.vh"

module SK_decode (
    input  logic       [31:0] insn_i,
    output SK_pkg::sk_ctrl_t  ctrl_o
);

    import SK_pkg::*;

    // 类（op[5:4]）
    localparam logic [1:0] CLS_R    = 2'b00;   // R 向量执行
    localparam logic [1:0] CLS_IAL  = 2'b01;   // RI 立即数 ALU
    localparam logic [1:0] CLS_MEM  = 2'b10;   // RI 访存
    localparam logic [1:0] CLS_MISC = 2'b11;   // 11_0 控制流；11_1 warp 级 / 系统

    // RALU 的 func（§5.3）；立即数 ALU 的操作码就是类 01 的子码
    localparam logic [3:0] SUB_RALU = 4'h0;
    localparam logic [3:0] SUB_SEL  = 4'h8;
    localparam logic [3:0] SUB_SHFL = 4'h9;
    localparam logic [3:0] SUB_VOTE = 4'hA;

    localparam logic [3:0] PRED_MAX = 4'd8;    // pred 字段 9..15 保留

    logic [1:0]  cls;
    logic [3:0]  sub;
    logic [4:0]  rd, ra, rb;
    logic [3:0]  func, pred;
    logic        is_ri, pinv;
    logic [31:0] imm_s, imm_u, off_br, off_j;
    logic [11:0] imm12;

    assign cls   = insn_i[5:4];
    assign sub   = insn_i[3:0];
    assign rd    = insn_i[10:6];
    assign ra    = insn_i[15:11];
    assign rb    = insn_i[20:16];
    assign func  = insn_i[28:25];
    assign imm12 = insn_i[31:20];
    // RI 格式的谓词在 [19:16]（bit29 属于立即数），其余格式在 [24:21]
    assign is_ri = (cls == CLS_IAL) || (cls == CLS_MEM);
    assign pred  = is_ri ? insn_i[19:16] : insn_i[24:21];
    assign pinv  = !is_ri && insn_i[29];

    assign imm_s  = sk_sext12(imm12);
    assign imm_u  = {20'd0, imm12};
    assign off_br = sk_sext21(insn_i[31:11]);   // BR：21 位有符号
    assign off_j  = sk_sext26(insn_i[31:6]);    // J：26 位有符号

    always_comb begin
        ctrl_o          = '0;
        ctrl_o.op       = SK_OP_ILLEGAL;
        ctrl_o.rd       = rd;
        ctrl_o.ra       = ra;
        ctrl_o.rb       = rb;
        ctrl_o.pred     = pred;
        ctrl_o.pinv     = pinv;
        ctrl_o.func     = func;
        ctrl_o.sreg     = ra;                            // SREAD 的编号在 ra 字段
        ctrl_o.bop      = sub[1:0];
        ctrl_o.imm      = imm_s;
        ctrl_o.off      = off_j;

        unique case (cls)
        CLS_R: begin
            unique case (sub)
            SUB_RALU: begin                                  // ADD..FMA
                ctrl_o.op = SK_OP_ALU;
                unique case (func)
                    4'h0: ctrl_o.alu_op = SK_ALU_ADD;
                    4'h1: ctrl_o.alu_op = SK_ALU_SUB;
                    4'h2: ctrl_o.alu_op = SK_ALU_AND;
                    4'h3: ctrl_o.alu_op = SK_ALU_OR;
                    4'h4: ctrl_o.alu_op = SK_ALU_XOR;
                    4'h5: ctrl_o.alu_op = SK_ALU_SHL;
                    4'h6: ctrl_o.alu_op = SK_ALU_SHR;
                    4'h7: ctrl_o.alu_op = SK_ALU_SAR;
                    4'h8: ctrl_o.alu_op = SK_ALU_SLT;
                    4'h9: ctrl_o.alu_op = SK_ALU_SLTU;
                    4'hA: ctrl_o.alu_op = SK_ALU_MUL;
                    4'hB: ctrl_o.alu_op = SK_ALU_MOV;
                    4'hC: ctrl_o.alu_op = SK_ALU_FMA;
                    default: ctrl_o.op = SK_OP_ILLEGAL;
                endcase
            end
            4'h4, 4'h5, 4'h6, 4'h7: begin                    // CMP[.AND|.OR|.XOR]
                if (func <= 4'h5 && rd < 5'(`SK_NUM_PRED)) begin
                    ctrl_o.op     = SK_OP_CMP;
                    ctrl_o.cmp_op = sk_cmp_e'(func[2:0]);    // 条件和 sk_cmp_e 同码
                end
            end
            SUB_SEL: begin                                   // pred 字段是操作数
                if (pred != 4'd0) begin
                    ctrl_o.op = SK_OP_SEL;
                end
            end
            SUB_SHFL: if (func <= 4'h3) ctrl_o.op = SK_OP_SHFL;
            SUB_VOTE: if (func <= 4'h1 && rb < 5'(`SK_NUM_PRED)) ctrl_o.op = SK_OP_VOTE;
            default: ;
            endcase
        end
        CLS_IAL: begin                                       // 立即数 ALU
            ctrl_o.op      = SK_OP_ALU;
            ctrl_o.imm_sel = 1'b1;
            unique case (sub)
                4'h0: ctrl_o.alu_op = SK_ALU_ADDI;                        // 有符号
                4'h1: begin ctrl_o.alu_op = SK_ALU_ANDI; ctrl_o.imm = imm_u; end
                4'h2: begin ctrl_o.alu_op = SK_ALU_ORI;  ctrl_o.imm = imm_u; end
                4'h3: begin ctrl_o.alu_op = SK_ALU_SHLI; ctrl_o.imm = imm_u; end
                4'h4: ctrl_o.alu_op = SK_ALU_SLTI;                        // 有符号
                4'h5: begin ctrl_o.alu_op = SK_ALU_LUI;  ctrl_o.imm = {imm12, 20'd0}; end
                4'h6: begin ctrl_o.alu_op = SK_ALU_LUM;  ctrl_o.imm = {8'd0, imm12, 12'd0}; end
                default: ctrl_o.op = SK_OP_ILLEGAL;
            endcase
        end
        CLS_MEM: begin                                       // 访存
            ctrl_o.op         = (sub[0] == 1'b0) ? SK_OP_LOAD : SK_OP_STORE;
            ctrl_o.mem_global = sub[1];
            if (sub > 4'h3) begin
                ctrl_o.op = SK_OP_ILLEGAL;                   // 0x24-0x2F 留给字节/半字/原子
            end
        end
        CLS_MISC: begin                                      // 11_0 控制流 / 11_1 warp 级、系统
            unique case (sub)
            4'h0: begin                                      // 11_0：BRZ
                ctrl_o.op  = SK_OP_BRZ;
                ctrl_o.ra  = rd;                             // BR 格式：rs 在 rd 字段
                ctrl_o.off = off_br;
            end
            4'h1: begin                                      // 11_0：BRNZ
                ctrl_o.op  = SK_OP_BRNZ;
                ctrl_o.ra  = rd;
                ctrl_o.off = off_br;
            end
            4'h2: begin                                      // 11_0：JMP
                ctrl_o.op  = SK_OP_JMP;
                ctrl_o.off = off_j;
            end
            4'h8: begin                                      // 11_1：MASK
                // `.P`/`.PM`/`MCLR.P` 的谓词号在 rb 字段
                if (func <= 4'hD && !(func >= 4'h7 && rb >= 5'(`SK_NUM_PRED))) begin
                    ctrl_o.op      = SK_OP_MASK;
                    ctrl_o.mask_op = sk_mask_e'(func);
                end
            end
            4'h9: if (ra <= SK_SREG_MAX) ctrl_o.op = SK_OP_SREAD;   // 11_1：SREAD
            4'hA: if (func <= 4'h2) ctrl_o.op = SK_OP_SYS;          // 11_1：NOP/BAR/EXIT
            default: ;
            endcase
        end
        endcase

        // 谓词字段 9..15 保留。BR/J 的这几个位属于偏移，SYS 字段为 0，都不检查
        if ((cls == CLS_R || ctrl_o.op == SK_OP_SREAD) && pred > PRED_MAX) begin
            ctrl_o.op = SK_OP_ILLEGAL;
        end

        // 读哪些 GPR、写不写 rd：scoreboard 的 RAW/WAR 检查和这两组位对齐
        // （docs/design.md §7）。这里只列真实用到的操作数，宁可少标也不能多标。
        unique case (ctrl_o.op)
            SK_OP_ALU: begin
                ctrl_o.srcs  = ctrl_o.imm_sel ? 3'b001 : 3'b011;
                ctrl_o.wr_rd = 1'b1;
                if (!ctrl_o.imm_sel && ctrl_o.alu_op == SK_ALU_FMA) begin
                    ctrl_o.srcs[2] = 1'b1;      // FMA 的 rd 是累加器，先读后写
                end
            end
            SK_OP_CMP:   ctrl_o.srcs = 3'b011;
            SK_OP_SEL:   begin ctrl_o.srcs = 3'b011; ctrl_o.wr_rd = 1'b1; end
            SK_OP_LOAD:  begin ctrl_o.srcs = 3'b001; ctrl_o.wr_rd = 1'b1; end
            SK_OP_STORE: ctrl_o.srcs = 3'b101;      // ra 是基址，rd 是要写出去的数据
            SK_OP_MASK: begin
                unique case (ctrl_o.mask_op)
                    SK_MASK_SAVE, SK_MASK_CLR_P: ;
                    SK_MASK_AND, SK_MASK_ANDN, SK_MASK_OR: ctrl_o.srcs = 3'b011;
                    default: ctrl_o.srcs = 3'b001;
                endcase
                ctrl_o.wr_rd = (ctrl_o.mask_op != SK_MASK_REST)
                            && (ctrl_o.mask_op != SK_MASK_CLR_P);
            end
            SK_OP_BRZ, SK_OP_BRNZ: ctrl_o.srcs = 3'b001;   // 读 lane 0 的寄存器
            SK_OP_SREAD: ctrl_o.wr_rd = 1'b1;
            SK_OP_SHFL:  begin ctrl_o.srcs = 3'b011; ctrl_o.wr_rd = 1'b1; end
            SK_OP_VOTE:  ctrl_o.wr_rd = 1'b1;
            default: ;
        endcase
    end

endmodule
