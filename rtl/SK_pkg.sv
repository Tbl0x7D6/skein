//! Skein 公共类型：译码结果、ALU 微操作、状态码。
//!
//! 指令编码的唯一来源是 tools/src/isa.rs（对应 docs/design.md §5.3），这里只放 RTL
//! 译码需要的类型；改编码时两处一起改。全局参数见 SK_config.vh。

package SK_pkg;

    /// 译码后的指令类别：决定走哪条执行通路。
    typedef enum logic [3:0] {
        SK_OP_ILLEGAL = 4'd0,
        SK_OP_ALU     = 4'd1,   // RALU 和立即数 ALU（微操作见 sk_alu_e）
        SK_OP_CMP     = 4'd2,   // 比较写谓词，`.AND/.OR/.XOR` 看 bop
        SK_OP_SEL     = 4'd3,   // 按谓词选值，pred 字段是操作数
        SK_OP_LOAD    = 4'd4,   // LDS / LDG
        SK_OP_STORE   = 4'd5,   // STS / STG，源寄存器在 rd 字段
        SK_OP_MASK    = 4'd6,   // warp 级 mask 指令，见 sk_mask_e
        SK_OP_BRZ     = 4'd7,
        SK_OP_BRNZ    = 4'd8,
        SK_OP_JMP     = 4'd9,
        SK_OP_SREAD   = 4'd10,  // 特殊寄存器编号在 ra 字段
        SK_OP_SYS     = 4'd11,  // NOP / BAR / EXIT，func 见 SK_SYS_*
        SK_OP_SHFL    = 4'd12,
        SK_OP_VOTE    = 4'd13   // func 见 SK_VOTE_*
    } sk_op_e;

    /// 算术微操作：译码把 RALU 的 func 和立即数 ALU 的操作码都翻译到这一组。
    typedef enum logic [4:0] {
        SK_ALU_ADD  = 5'd0,  SK_ALU_SUB  = 5'd1,  SK_ALU_AND  = 5'd2,  SK_ALU_OR   = 5'd3,
        SK_ALU_XOR  = 5'd4,  SK_ALU_SHL  = 5'd5,  SK_ALU_SHR  = 5'd6,  SK_ALU_SAR  = 5'd7,
        SK_ALU_SLT  = 5'd8,  SK_ALU_SLTU = 5'd9,  SK_ALU_MUL  = 5'd10, SK_ALU_MOV  = 5'd11,
        SK_ALU_FMA  = 5'd12,
        SK_ALU_ADDI = 5'd13, SK_ALU_ANDI = 5'd14, SK_ALU_ORI  = 5'd15, SK_ALU_SHLI = 5'd16,
        SK_ALU_SLTI = 5'd17, SK_ALU_LUI  = 5'd18, SK_ALU_LUM  = 5'd19
    } sk_alu_e;

    /// 比较条件（和 isa.rs 的 Cmp 同码）。
    typedef enum logic [2:0] {
        SK_CMP_EQ = 3'd0, SK_CMP_NE = 3'd1, SK_CMP_LT = 3'd2,
        SK_CMP_GE = 3'd3, SK_CMP_LTU = 3'd4, SK_CMP_GEU = 3'd5
    } sk_cmp_e;

    /// mask 指令（和 isa.rs 的 MaskOp 同码）。
    typedef enum logic [3:0] {
        SK_MASK_SAVE   = 4'd0,  SK_MASK_REST  = 4'd1,  SK_MASK_MOV    = 4'd2,
        SK_MASK_AND    = 4'd3,  SK_MASK_ANDN  = 4'd4,  SK_MASK_OR     = 4'd5,
        SK_MASK_NOT    = 4'd6,  SK_MASK_AND_P = 4'd7,  SK_MASK_ANDN_P = 4'd8,
        SK_MASK_OR_P   = 4'd9,  SK_MASK_CLR_P = 4'd10,
        SK_MASK_AND_PM = 4'd11, SK_MASK_ANDN_PM = 4'd12, SK_MASK_OR_PM = 4'd13
    } sk_mask_e;

    /// STATUS 错误码（和 isa.rs 的 Status 同码）。
    typedef enum logic [3:0] {
        SK_STATUS_OK             = 4'd0,
        SK_STATUS_BAD_INSN       = 4'd1,
        SK_STATUS_UNALIGNED      = 4'd2,
        SK_STATUS_SMEM_OOB       = 4'd3,
        SK_STATUS_GMEM_OOB       = 4'd4,
        SK_STATUS_BAR_INCOMPLETE = 4'd5,
        SK_STATUS_PC_OOB         = 4'd6,
        SK_STATUS_BAD_LAUNCH     = 4'd7
    } sk_status_e;

    /// 指令分类（和 tools/src/isa.rs 的 OpClass 同码），按类 retired 计数用。
    typedef enum logic [3:0] {
        SK_CLASS_ALU    = 4'd0,  SK_CLASS_CMP   = 4'd1,  SK_CLASS_SEL   = 4'd2,
        SK_CLASS_IMM    = 4'd3,  SK_CLASS_LDS   = 4'd4,  SK_CLASS_STS   = 4'd5,
        SK_CLASS_LDG    = 4'd6,  SK_CLASS_STG   = 4'd7,  SK_CLASS_MASK  = 4'd8,
        SK_CLASS_BRANCH = 4'd9,  SK_CLASS_JMP   = 4'd10, SK_CLASS_SREAD = 4'd11,
        SK_CLASS_SYS    = 4'd12, SK_CLASS_SHFL  = 4'd13, SK_CLASS_VOTE  = 4'd14
    } sk_class_e;

    /// `CMP` 的谓词组合修饰（主操作码低 2 位）。
    localparam logic [1:0] SK_BOP_SET = 2'd0, SK_BOP_AND = 2'd1,
                           SK_BOP_OR  = 2'd2, SK_BOP_XOR = 2'd3;

    /// 系统指令的 func。
    localparam logic [3:0] SK_SYS_NOP = 4'd0, SK_SYS_BAR = 4'd1, SK_SYS_EXIT = 4'd2;

    /// SHFL 的 func。
    localparam logic [3:0] SK_SHFL_IDX  = 4'd0, SK_SHFL_UP = 4'd1,
                           SK_SHFL_DOWN = 4'd2, SK_SHFL_BFLY = 4'd3;

    /// VOTE 的 func。
    localparam logic [3:0] SK_VOTE_ANY = 4'd0, SK_VOTE_ALL = 4'd1;

    /// 特殊寄存器编号：完整清单在 tools/src/isa.rs 的 Sreg（编号的唯一来源，两个文件
    /// 必须同码）。RTL 只列自己译码时要用的几个——其余编号（PTR_*/ARG* 等）是主机写、
    /// 由 `sreg_i` 直接读出来的，核不需要知道它们叫什么。
    /// 单个编号是数组下标（4 位），`SK_SREG_MAX` 要和译码里的 5 位 `ra` 比，所以是 5 位。
    localparam logic [3:0] SK_SREG_TID       = 4'd0,
                           SK_SREG_LANEID    = 4'd1,
                           SK_SREG_WID       = 4'd2,
                           SK_SREG_WARPSZ    = 4'd3,
                           SK_SREG_BLOCK_DIM = 4'd14;
    localparam logic [4:0] SK_SREG_MAX       = 5'd14;

    /// 调度器里一个 warp 的状态。`BAR` 是"到了屏障在等"，`DONE` 是"EXIT 了或者
    /// 这次 block 没让它起来"。见 docs/design.md §7。
    typedef enum logic [1:0] {
        SK_WARP_RUN  = 2'd0,
        SK_WARP_BAR  = 2'd1,
        SK_WARP_DONE = 2'd2
    } sk_warp_state_e;

    /// 译码结果：执行级的全部控制信号。
    typedef struct packed {
        sk_op_e      op;
        sk_alu_e     alu_op;      // op == SK_OP_ALU
        sk_cmp_e     cmp_op;      // op == SK_OP_CMP
        sk_mask_e    mask_op;     // op == SK_OP_MASK
        logic [1:0]  bop;         // CMP 的谓词组合修饰
        logic [4:0]  rd;          // 目的寄存器；STORE 是源寄存器；CMP 是谓词号
        logic [4:0]  ra;          // 源 A；BRZ/BRNZ 的分支寄存器；SREAD 的特殊寄存器号
        logic [4:0]  rb;          // 源 B；`.P` 类 mask 指令的谓词号
        logic [3:0]  pred;        // 谓词字段：0 = 无门控，1..8 = @p0..@p7
        logic        pinv;        // @!p（只有 R/SR 格式有）
        logic [3:0]  func;        // SHFL/VOTE/SYS 的模式
        logic [4:0]  sreg;        // SREAD 的特殊寄存器号
        logic        imm_sel;     // 源 B 用立即数（立即数 ALU）
        logic        mem_global;  // LDG/STG
        logic [31:0] imm;         // 已扩展的立即数 / 访存偏移
        logic [31:0] off;         // 已符号扩展的跳转偏移（单位：指令字）
        logic [2:0]  srcs;        // 读哪些 GPR：bit0 = ra、bit1 = rb、bit2 = rd
        logic        wr_rd;       // 写 GPR rd（CMP 写的是谓词，不算）
    } sk_ctrl_t;

    /// ID/EX 里真正要带到执行级的控制信号：`ra`/`pinv`/`srcs`/`wr_rd` 只在译码级
    /// （读寄存器地址、`@!p` 门控、scoreboard 冒险检查）用得到，不占流水线寄存器。
    typedef struct packed {
        sk_op_e      op;
        sk_alu_e     alu_op;
        sk_cmp_e     cmp_op;
        sk_mask_e    mask_op;
        logic [1:0]  bop;
        logic [4:0]  rd;
        logic [4:0]  rb;
        logic [3:0]  pred;
        logic [3:0]  func;
        logic [4:0]  sreg;
        logic        mem_global;
        logic [31:0] imm;
        logic [31:0] off;
    } sk_exec_t;

    /// 12 位立即数符号扩展。
    function automatic logic [31:0] sk_sext12(logic [11:0] value);
        return {{20{value[11]}}, value};
    endfunction

    /// 21 位分支偏移符号扩展。
    function automatic logic [31:0] sk_sext21(logic [20:0] value);
        return {{11{value[20]}}, value};
    endfunction

    /// 26 位跳转偏移符号扩展。
    function automatic logic [31:0] sk_sext26(logic [25:0] value);
        return {{6{value[25]}}, value};
    endfunction

endpackage
