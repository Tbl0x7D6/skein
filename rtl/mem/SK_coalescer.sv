//! coalescer：把一条 warp 级访存请求按 64 B cache line 分组，交给下游（L1 或 AXI）。
//!
//! 一条请求可能落到多条 line（最多 `LANES` 条），一次服务一组：
//!   - `ROUND` 状态算这一组：选还没服务的最低 lane，取和它同 line 的 lane；
//!     组的 beat 区间 = 组内 lane 地址在 line 内的最小..最大 64-bit beat 号；
//!   - `TXN` 状态发一次 line 内突发：写用 `WSTRB`（同 word 多 lane 时最高 lane 胜），
//!     读的 beat 回来时按每条 lane 的 word 偏移选数据、同拍回写多条 lane。
//!
//! 分组的组合逻辑在 `ROUND` 结尾寄存一拍，`TXN` 里的回写路径只依赖寄存器
//! （group_q / addr_q / 计数器），所以不会把 line 比较链拖进寄存器堆的写使能
//! （P5 综合时踩过一次 200 MHz 违例）。
//!
//! `ENABLE=0` 时每组只含一个 lane —— 用来造 M5 的"未合并"基线，语义完全一样。

`include "SK_config.vh"

module SK_coalescer #(
    parameter int  LANES   = 4,
    parameter int  ENABLE  = `SK_COALESCE,
    parameter int  ADDR_W  = 32,
    parameter int  LEN_W   = 4
) (
    input  logic                      clk,
    input  logic                      aresetn,
    input  logic                      flush_i,
    // 请求：LSU 已完成对齐/越界预检查，这里只管合并和搬运
    input  logic                      req_start_i,
    input  logic                      req_we_i,
    input  logic [LANES-1:0]          req_mask_i,
    input  logic [LANES-1:0][31:0]    req_addr_i,
    input  logic [LANES-1:0][31:0]    req_wdata_i,
    // 下游突发接口（L1 或 AXI master）
    output logic                      dn_req_valid_o,
    input  logic                      dn_req_ready_i,
    output logic                      dn_req_we_o,
    output logic [ADDR_W-1:3]         dn_req_addr_o,     // beat 对齐
    output logic [LEN_W-1:0]          dn_req_len_o,
    output logic [63:0]               dn_wdata_o,
    output logic [7:0]                dn_wstrb_o,
    input  logic                      dn_wbeat_taken_i,
    input  logic                      dn_rbeat_valid_i,
    input  logic [63:0]               dn_rbeat_data_i,
    input  logic                      dn_rbeat_last_i,
    output logic                      dn_rbeat_ready_o,
    input  logic                      dn_done_i,
    input  logic                      dn_fault_i,
    // 读数据回写（per lane）
    output logic [LANES-1:0]          wb_we_o,
    output logic [LANES-1:0][31:0]    wb_data_o,
    input  logic                      wb_stall_i,
    // 到 LSU
    output logic                      done_o,      // 一拍脉冲
    output logic                      fault_o      // 一拍脉冲
);

    typedef enum logic [1:0] {ST_IDLE, ST_ROUND, ST_TXN} state_e;

    state_e  state_q;
    logic    we_q;
    logic [LANES-1:0]       mask_q;
    logic [LANES-1:0][31:0] addr_q, wdata_q;
    logic [LANES-1:0]       served_q;
    // 当前组（ROUND 结尾寄存）
    logic [LANES-1:0]       group_q;
    logic [ADDR_W-7:0]      line_base_q;      // 行基址（addr[31:6]，低 6 位是行内偏移）
    logic [2:0]             first_beat_q, last_beat_q;
    logic    req_taken_q;
    logic [2:0] wcnt_q, rcnt_q;

    // --- ROUND：算这一组 ---
    logic [LANES-1:0] cand;
    logic [LANES-1:0] group;
    logic             sel_found;
    logic [ADDR_W-7:0] sel_line;
    logic [2:0]       first_beat, last_beat;

    // 剩余需要被处理的 lane
    assign cand = mask_q & ~served_q;

    // 找最低的一个 candidate lane
    always_comb begin
        sel_found = 1'b0;
        sel_line  = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            if (!sel_found && cand[lane]) begin
                sel_found = 1'b1;
                sel_line  = addr_q[lane][ADDR_W-1:6];
            end
        end
    end

    // 把更高的 lane 但是同 64B cacheline 合并到 group
    always_comb begin
        logic group_taken;
        group       = '0;
        group_taken = 1'b0;
        for (int lane = 0; lane < LANES; lane++) begin
            if (cand[lane]) begin
                if (ENABLE == 0) begin
                    if (!group_taken) begin
                        group[lane] = 1'b1;
                        group_taken = 1'b1;
                    end
                end else if (addr_q[lane][ADDR_W-1:6] == sel_line) begin
                    group[lane] = 1'b1;
                end
            end
        end
    end

    // 计算 first/last_beat，拍数 = 闭区间内 beat 数，空 beat 丢弃（读）或者 wstrb = 0（写）
    always_comb begin
        logic group_seen;
        first_beat = 3'd0;
        last_beat  = 3'd0;
        group_seen = 1'b0;
        for (int lane = 0; lane < LANES; lane++) begin
            if (group[lane]) begin
                if (!group_seen) begin
                    first_beat = addr_q[lane][5:3];
                    last_beat  = addr_q[lane][5:3];
                    group_seen = 1'b1;
                end else begin
                    if (addr_q[lane][5:3] < first_beat) first_beat = addr_q[lane][5:3];
                    if (addr_q[lane][5:3] > last_beat)  last_beat  = addr_q[lane][5:3];
                end
            end
        end
    end

    // --- TXN：当前 beat 的写数据 / 读回写 ---
    logic [2:0] cur_wbeat, cur_rbeat;

    assign cur_wbeat = first_beat_q + wcnt_q;
    assign cur_rbeat = first_beat_q + rcnt_q;

    // ST 的话拼接 8B 数据
    always_comb begin
        logic lo_wr, hi_wr;
        logic [31:0] lo_data, hi_data;
        lo_wr = 1'b0; hi_wr = 1'b0;
        lo_data = '0; hi_data = '0;
        if (we_q) begin
            for (int lane = 0; lane < LANES; lane++) begin
                if (group_q[lane] && (addr_q[lane][5:3] == cur_wbeat)) begin
                    if (addr_q[lane][2]) begin hi_data = wdata_q[lane]; hi_wr = 1'b1; end
                    else                 begin lo_data = wdata_q[lane]; lo_wr = 1'b1; end
                end
            end
        end
        dn_wdata_o = {hi_data, lo_data};
        dn_wstrb_o = {hi_wr ? 4'hF : 4'h0, lo_wr ? 4'hF : 4'h0};
    end

    logic            beat_has_wb;
    logic [LANES-1:0] beat_lanes;

    // LD 的话判断这个 beat 有哪些 lane 要写回
    always_comb begin
        beat_lanes  = '0;
        beat_has_wb = 1'b0;
        if ((state_q == ST_TXN) && !we_q) begin
            for (int lane = 0; lane < LANES; lane++) begin
                if (group_q[lane] && (addr_q[lane][5:3] == cur_rbeat)) begin
                    beat_lanes[lane] = 1'b1;
                    beat_has_wb      = 1'b1;
                end
            end
        end
    end

    // 要写回且上游写口忙（core commit 和 lsu 处理的 warp 抢同一个 GPR 写口）的时候反压
    // 否则持续告诉下游接收这一个 beat
    assign dn_rbeat_ready_o = !(wb_stall_i && beat_has_wb);

    always_comb begin
        wb_we_o   = '0;
        wb_data_o = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            if (beat_lanes[lane]) begin
                wb_we_o[lane]   = dn_rbeat_valid_i && dn_rbeat_ready_o;
                wb_data_o[lane] = addr_q[lane][2] ? dn_rbeat_data_i[63:32]
                                                  : dn_rbeat_data_i[31:0];
            end
        end
    end

    // --- 下游请求 ---
    assign dn_req_valid_o = (state_q == ST_TXN) && !req_taken_q;
    assign dn_req_we_o    = we_q;
    assign dn_req_addr_o  = {line_base_q, first_beat_q};
    assign dn_req_len_o   = LEN_W'(last_beat_q - first_beat_q);

    // 组做完：读看最后一拍握手，写看 B 响应
    logic group_done, req_done;
    assign group_done = (state_q == ST_TXN) &&
                        (we_q ? dn_done_i
                              : (dn_rbeat_valid_i && dn_rbeat_ready_o && dn_rbeat_last_i));
    assign req_done   = group_done && ((served_q | group_q) == mask_q) && (mask_q != '0);
    assign done_o     = req_done;
    assign fault_o    = dn_fault_i && (state_q == ST_TXN);

    always_ff @(posedge clk) begin
        if (!aresetn || flush_i) begin
            state_q     <= ST_IDLE;
            we_q        <= 1'b0;
            mask_q      <= '0;
            served_q    <= '0;
            group_q     <= '0;
            req_taken_q <= 1'b0;
            wcnt_q      <= '0;
            rcnt_q      <= '0;
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (req_start_i) begin
                        we_q      <= req_we_i;
                        mask_q    <= req_mask_i;
                        addr_q    <= req_addr_i;
                        wdata_q   <= req_wdata_i;
                        served_q  <= '0;
                        state_q   <= ST_ROUND;
                    end
                end
                ST_ROUND: begin
                    // 分组结果寄存一拍：line 比较链不进 TXN 的回写路径
                    group_q      <= group;
                    line_base_q  <= sel_line;
                    first_beat_q <= first_beat;
                    last_beat_q  <= last_beat;
                    req_taken_q  <= 1'b0;
                    wcnt_q       <= '0;
                    rcnt_q       <= '0;
                    state_q      <= ST_TXN;
                end
                ST_TXN: begin
                    if (dn_req_valid_o && dn_req_ready_i) req_taken_q <= 1'b1;

                    if (we_q) begin
                        if (dn_wbeat_taken_i) wcnt_q <= wcnt_q + 3'd1;
                    end else if (dn_rbeat_valid_i && dn_rbeat_ready_o) begin
                        rcnt_q <= rcnt_q + 3'd1;
                    end

                    if (fault_o) begin
                        state_q <= ST_IDLE;            // 出错整台核就停了，这里只收尾
                    end else if (group_done) begin
                        served_q <= served_q | group_q;
                        if ((served_q | group_q) == mask_q) begin
                            state_q <= ST_IDLE;        // 这条请求做完了
                        end else begin
                            state_q <= ST_ROUND;       // 还有下一组
                        end
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
