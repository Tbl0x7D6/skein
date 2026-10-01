//! scoreboard：每条 warp 一组 "哪些 GPR 还在等 load 的数据" 的 bit。
//!
//! 只有 `LDG/LDS` 的目标寄存器会进 scoreboard：ALU 的结果靠"每条 warp 最多一条指令
//! 在流水里"这条规则就已经写回落地了，不需要跟踪（见 SK_scheduler）。译码级（S3）
//! 拿这条指令真正用到的操作数查一次：
//!   - RAW：读的寄存器还在等数据；
//!   - WAR/WAW：写的寄存器还在等数据（老的 load 会更晚写回来）。
//! 查到就让这条指令重发（`hazard_o`），不是把流水卡住。
//!
//! 清位时机：LSU 报"这条请求的最后一条 lane 做完了"的那一拍（`clear_i`）。同一拍
//! 译码的指令还会看到旧值、然后再重发一次，所以数据一定已经进寄存器堆，不会差一拍
//! （见 docs/practice.md §1.9）。

module SK_scoreboard #(
    parameter int WARPS  = 4,
    parameter int NUM_GPR = 32,
    parameter int WARP_W = (WARPS > 1) ? $clog2(WARPS) : 1,
    parameter int GPR_W  = (NUM_GPR > 1) ? $clog2(NUM_GPR) : 1
) (
    input  logic                          clk,
    input  logic                          aresetn,
    input  logic                          start_i,       // 块开始：清空
    // 译码级（S3）的检查
    input  logic                          chk_valid_i,
    input  logic [WARP_W-1:0]             chk_wid_i,
    input  logic [2:0]                    chk_srcs_i,    // bit0 = ra、bit1 = rb、bit2 = rd
    input  logic                          chk_wr_rd_i,
    input  logic [GPR_W-1:0]              chk_ra_i,
    input  logic [GPR_W-1:0]              chk_rb_i,
    input  logic [GPR_W-1:0]              chk_rd_i,
    output logic                          hazard_o,
    // 设置 / 清除
    input  logic                          set_valid_i,   // 译码出一条 load：rd 进 scoreboard
    input  logic [WARP_W-1:0]             set_wid_i,
    input  logic [GPR_W-1:0]              set_rd_i,
    input  logic [WARPS-1:0]              clear_i,       // LSU 报该 warp 的请求做完了
    output logic [WARPS-1:0]              busy_o         // 该 warp 有寄存器在等 load
);

    logic [WARPS-1:0][NUM_GPR-1:0] pend_q;
    logic [NUM_GPR-1:0]            pend_chk;
    logic                          raw, waw;

    always_comb begin
        pend_chk = pend_q[chk_wid_i];
        raw = (chk_srcs_i[0] && pend_chk[chk_ra_i])
           || (chk_srcs_i[1] && pend_chk[chk_rb_i])
           || (chk_srcs_i[2] && pend_chk[chk_rd_i]);
        waw = chk_wr_rd_i && pend_chk[chk_rd_i];

        hazard_o = chk_valid_i && (raw || waw);
        for (int warp = 0; warp < WARPS; warp++) begin
            busy_o[warp] = |pend_q[warp];
        end
    end

    always_ff @(posedge clk) begin
        if (!aresetn || start_i) begin
            pend_q <= '0;
        end else begin
            for (int warp = 0; warp < WARPS; warp++) begin
                if (clear_i[warp]) begin
                    pend_q[warp] <= '0;
                end
                // 置位写在清位后面：真撞上同一拍（理论上不会，一个 warp 只有一个请求槽），
                // 老请求的那一位清掉、新 load 的目标保住，不会把新位一起吞掉。
                if (set_valid_i && (set_wid_i == WARP_W'(warp)) && (set_rd_i != '0)) begin
                    pend_q[warp][set_rd_i] <= 1'b1;
                end
            end
        end
    end

endmodule
