//! warp 调度器：轮询发射 + warp 状态机（RUN / BAR / DONE）。
//!
//! 每条 warp 每次只能有一条指令在流水里（`busy_i`），所以发射间隔至少 4 拍；这正好
//! 让"寄存器堆写在下一次读之前落地"，不需要前递。没准备好的 warp 直接跳过，别的
//! warp 继续发——这里是多 warp 藏延迟的唯一入口。`WARPS` 取 2 的幂（本设计固定 4），
//! 轮询指针加一就自然回绕。

module SK_scheduler #(
    parameter int WARPS  = 4,
    parameter int WARP_W = (WARPS > 1) ? $clog2(WARPS) : 1
) (
    input  logic                    clk,
    input  logic                    aresetn,
    input  logic                    start_i,          // 块开始
    // 这个 block 起来几条 warp：要比 WARP_W 宽一位，"4 条全起来"才表达得出来
    input  logic [WARP_W:0]         active_warps_i,
    // 每条 warp 能不能发
    input  logic [WARPS-1:0]        busy_i,           // 指令还在 S2..S4
    input  logic [WARPS-1:0]        wait_i,           // 重发过，等自己的访存排空
    // 提交级的动作
    input  logic [WARPS-1:0]        arrive_bar_i,
    input  logic [WARPS-1:0]        exit_i,
    input  logic                    bar_release_i,
    // 输出
    output SK_pkg::sk_warp_state_e  state_o [WARPS],
    output logic                    issue_valid_o,
    output logic [WARP_W-1:0]       issue_wid_o
);

    import SK_pkg::*;

    sk_warp_state_e state_q [WARPS];
    logic [WARP_W-1:0] rr_q;          // 轮询起点

    logic [WARPS-1:0]  ready;         // 这一拍可以发射
    logic [WARP_W-1:0] index;
    logic              found;

    always_comb begin
        for (int warp = 0; warp < WARPS; warp++) begin
            ready[warp] = (state_q[warp] == SK_WARP_RUN) && !busy_i[warp] && !wait_i[warp];
        end

        // 从 rr_q 开始找第一条 ready 的 warp：没准备好的直接跳过，不挡后面的。
        // 注意别在这里提前结束扫描——在第一条卡住的 warp 上停下，后面已经能发的
        // warp 也会跟着白等一拍（P3 踩过：IPC 从 0.72 掉到 0.65）。
        issue_valid_o = 1'b0;
        issue_wid_o   = '0;
        found         = 1'b0;
        for (int i = 0; i < WARPS; i++) begin
            index = rr_q + WARP_W'(i);        // WARPS 是 2 的幂，加法自然回绕
            if (!found && ready[index]) begin
                issue_valid_o = 1'b1;
                issue_wid_o   = WARP_W'(index);
                found         = 1'b1;
            end
        end
    end

    assign state_o = state_q;

    always_ff @(posedge clk) begin
        if (!aresetn || start_i) begin
            for (int warp = 0; warp < WARPS; warp++) begin
                state_q[warp] <= ((WARP_W+1)'(warp) < active_warps_i) ? SK_WARP_RUN
                                                                    : SK_WARP_DONE;
            end
            rr_q <= '0;
        end else begin
            if (issue_valid_o) begin
                rr_q <= issue_wid_o + WARP_W'(1);
            end
            for (int warp = 0; warp < WARPS; warp++) begin
                if (arrive_bar_i[warp]) begin
                    state_q[warp] <= SK_WARP_BAR;
                end else if (exit_i[warp]) begin
                    state_q[warp] <= SK_WARP_DONE;
                end else if (bar_release_i && (state_q[warp] == SK_WARP_BAR)) begin
                    state_q[warp] <= SK_WARP_RUN;
                end
            end
        end
    end

endmodule
