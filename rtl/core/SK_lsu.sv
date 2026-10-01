//! 访存单元（非阻塞版）：每个 warp 一个请求槽，轮询服务，一拍一条 lane。
//!
//! 请求由 `SK_core` 的执行级推进来（地址、store 数据、lane 门控都算好了），之后
//! 流水线就不再等它：`LDG/LDS` 的目标寄存器进 scoreboard，谁读谁重发；`STG/STS`
//! 是 posted write，`EXIT`/`BAR` 之前必须排空（靠 `busy_o`）。
//!
//! 服务顺序：轮到哪个 warp 就把它的 lane 0..N-1 一条一条走完（没有 active lane 也
//! 照走），中途不换 warp、不重发。一条访存占 `LANES` 拍，这是 P5 合并器要解决的事。
//! 读数据同拍回来并写回当前 lane 的寄存器堆；写口被同 warp 的流水线提交占用时
//! （`wb_stall_i`），这一拍原地等。
//!
//! 出错即停在这条 lane 上（对齐/越界检查顺序和黄金模型一致：先对齐、再越界）——
//! 这是实现行为，不是架构契约（docs/design.md §5.5）。

module SK_lsu #(
    parameter int WARPS  = 4,
    parameter int LANES  = 4,
    parameter int WARP_W = (WARPS > 1) ? $clog2(WARPS) : 1,
    parameter int LANE_W = (LANES > 1) ? $clog2(LANES) : 1,
    parameter int GPR_W  = 5
) (
    input  logic                            clk,
    input  logic                            aresetn,
    // 请求入口：执行级把这条访存指令推进请求槽
    input  logic                            push_i,
    input  logic [WARP_W-1:0]               push_wid_i,
    input  logic                            push_store_i,
    input  logic                            push_global_i,
    input  logic [GPR_W-1:0]                push_rd_i,
    input  logic [15:0]                     push_pc_i,
    input  logic [LANES-1:0][31:0]          push_addr_i,
    input  logic [LANES-1:0][31:0]          push_wdata_i,
    input  logic [LANES-1:0]                push_mask_i,
    // 状态：`busy_o` 是"该 warp 还有没做完的访存"，`done_o` 是"本拍做完了"
    output logic [WARPS-1:0]                busy_o,
    output logic [WARPS-1:0]                done_o,
    // load 数据回写
    output logic                            wb_we_o,
    output logic [WARP_W-1:0]               wb_wid_o,
    output logic [LANE_W-1:0]               wb_lane_o,
    output logic [GPR_W-1:0]                wb_addr_o,
    output logic [31:0]                     wb_data_o,
    input  logic                            wb_stall_i,
    // 出错：整个 block 停在第一个出错的 lane 上
    output logic                            fault_o,
    output logic [3:0]                      fault_code_o,
    output logic [WARP_W-1:0]               fault_wid_o,
    output logic [15:0]                     fault_pc_o,
    input  logic                            flush_i,
    // 存储端口（读同拍回来，写在时钟沿生效）
    output logic [31:0]                     smem_addr_o,
    output logic [31:0]                     smem_wdata_o,
    output logic                            smem_we_o,
    input  logic [31:0]                     smem_rdata_i,
    input  logic                            smem_fault_i,
    output logic [31:0]                     gmem_addr_o,
    output logic [31:0]                     gmem_wdata_o,
    output logic                            gmem_we_o,
    input  logic [31:0]                     gmem_rdata_i,
    input  logic                            gmem_fault_i
);

    import SK_pkg::*;

    localparam logic [LANE_W-1:0] LANE_LAST = LANE_W'(LANES - 1);

    // 每个 warp 一个请求槽
    logic [WARPS-1:0]                  valid_q;
    logic [WARPS-1:0]                  store_q;
    logic [WARPS-1:0]                  global_q;
    logic [WARPS-1:0][GPR_W-1:0]       rd_q;
    logic [WARPS-1:0][15:0]            pc_q;
    logic [WARPS-1:0][LANES-1:0][31:0] addr_q;
    logic [WARPS-1:0][LANES-1:0][31:0] wdata_q;
    logic [WARPS-1:0][LANES-1:0]       mask_q;

    // 正在服务的那条请求
    logic                  busy_q;
    logic [WARP_W-1:0]     sel_q;
    logic [LANE_W-1:0]     lane_q;
    logic [WARP_W-1:0]     rr_q;          // 下一次从哪个 warp 开始找

    // 本拍服务的 warp / lane
    logic                  start;
    logic [WARP_W-1:0]     sel, sel_next;
    logic                  sel_valid;
    logic [LANE_W-1:0]     lane;
    logic [WARP_W-1:0]     index;

    always_comb begin
        sel_next  = '0;
        sel_valid = 1'b0;
        for (int i = 0; i < WARPS; i++) begin
            index = rr_q + WARP_W'(i);        // WARPS 是 2 的幂，加法自然回绕
            if (!sel_valid && valid_q[index]) begin
                sel_next  = WARP_W'(index);
                sel_valid = 1'b1;
            end
        end
    end

    assign start = !busy_q && sel_valid;
    assign sel   = busy_q ? sel_q : sel_next;
    assign lane  = busy_q ? lane_q : '0;
    // 本拍正在服务一条请求：`start` 那一拍服务的是 lane 0
    logic serving;
    assign serving = busy_q || start;

    // 这一拍真正要动的那条 lane
    logic           active;
    logic [31:0]    addr;
    logic           unaligned;
    logic [3:0]     fault;
    logic           wb_wanted;
    logic           hold;

    assign active    = serving && mask_q[sel][lane];
    assign addr      = addr_q[sel][lane];
    assign unaligned = (addr[1:0] != 2'b00);

    always_comb begin
        fault = SK_STATUS_OK;
        if (active) begin
            if (unaligned) begin
                fault = SK_STATUS_UNALIGNED;
            end else if (global_q[sel] && gmem_fault_i) begin
                fault = SK_STATUS_GMEM_OOB;
            end else if (!global_q[sel] && smem_fault_i) begin
                fault = SK_STATUS_SMEM_OOB;
            end
        end
    end

    assign smem_addr_o  = addr;
    assign smem_wdata_o = wdata_q[sel][lane];
    assign gmem_addr_o  = addr;
    assign gmem_wdata_o = wdata_q[sel][lane];
    assign smem_we_o    = active && store_q[sel] && !global_q[sel] && (fault == SK_STATUS_OK);
    assign gmem_we_o    = active && store_q[sel] &&  global_q[sel] && (fault == SK_STATUS_OK);

    // load 回写：写口被同 warp 的流水线提交占着就原地等一拍
    assign wb_wanted = active && !store_q[sel] && (fault == SK_STATUS_OK);
    assign hold      = wb_wanted && wb_stall_i;

    assign wb_we_o   = wb_wanted && !wb_stall_i;
    assign wb_wid_o  = sel;
    assign wb_lane_o = lane;
    assign wb_addr_o = rd_q[sel];
    assign wb_data_o = global_q[sel] ? gmem_rdata_i : smem_rdata_i;

    assign busy_o    = valid_q;
    assign done_o    = (serving && !hold && (fault == SK_STATUS_OK) && (lane == LANE_LAST))
                     ? (WARPS'(1) << sel) : '0;

    assign fault_o      = serving && (fault != SK_STATUS_OK);
    assign fault_code_o = fault;
    assign fault_wid_o  = sel;
    assign fault_pc_o   = pc_q[sel];

    always_ff @(posedge clk) begin
        if (!aresetn || flush_i) begin
            valid_q <= '0;
            busy_q  <= 1'b0;
            sel_q   <= '0;
            lane_q  <= '0;
            rr_q    <= '0;
        end else begin
            if (push_i) begin
                valid_q[push_wid_i]  <= 1'b1;
                store_q[push_wid_i]  <= push_store_i;
                global_q[push_wid_i] <= push_global_i;
                rd_q[push_wid_i]     <= push_rd_i;
                pc_q[push_wid_i]     <= push_pc_i;
                addr_q[push_wid_i]   <= push_addr_i;
                wdata_q[push_wid_i]  <= push_wdata_i;
                mask_q[push_wid_i]   <= push_mask_i;
            end

            if (serving && (!hold && (fault == SK_STATUS_OK) && (lane == LANE_LAST))) begin
                // 这条请求的最后一条 lane：释放请求槽，下一次从它后面接着轮询
                valid_q[sel] <= 1'b0;
                busy_q       <= 1'b0;
                rr_q         <= sel + WARP_W'(1);
            end else if (serving) begin
                // 继续下一条 lane；held（写口忙）或者出错就停在原地
                busy_q <= 1'b1;
                sel_q  <= sel;
                lane_q <= (hold || (fault != SK_STATUS_OK)) ? lane : (lane + 1'b1);
            end else begin
                busy_q <= 1'b0;
            end
        end
    end

endmodule
