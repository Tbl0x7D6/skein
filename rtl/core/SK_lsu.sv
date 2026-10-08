//! 访存单元：每个 warp 一个请求槽，轮询服务，一次一条请求。
//!
//! 请求由 `SK_core` 的执行级推进来（地址、store 数据、lane 门控都算好了），之后
//! 流水线就不再等它：`LDG/LDS` 的目标寄存器进 scoreboard，谁读谁重发；`STG/STS`
//! 是 posted write，`EXIT`/`BAR` 之前必须排空（靠 `busy_o`）。
//!
//! 服务前先把整条请求预检查一遍（对齐 + 地址范围，取最低的出错 lane），把错误挡在
//! 访存之前——和黄金模型"先检查、出错指令零副作用"一致（docs/design.md §5.5）。
//! 通过之后按地址空间分流：
//!   - shared：按 bank 冲突把活跃 lane 分成若干轮，每轮并行访问 `SK_smem`；
//!     写请求先做同地址去重（最高 lane 胜），同地址读做广播；
//!   - global：交给 `SK_coalescer`，它按 64 B 行合并、走 L1/AXI。
//!
//! 回写口是 per-lane 的（`wb_mask_o` + 每 lane 数据），一次可以写回多条 lane；
//! 写口被同 warp 的流水线提交占着时（`wb_stall_i`）原地等。

`include "SK_config.vh"

module SK_lsu #(
    parameter int WARPS  = 4,
    parameter int LANES  = 4,
    parameter int WARP_W = (WARPS > 1) ? $clog2(WARPS) : 1,
    parameter int GPR_W  = 5,
    parameter int BANK_W = (LANES > 1) ? $clog2(LANES) : 1,
    parameter int SMEM_BYTES = `SK_SMEM_KB * 1024,
    parameter int GMEM_BYTES = `SK_GMEM_KB * 1024
) (
    input  logic                            clk,
    input  logic                            aresetn,
    // 请求入口：执行级把这条访存指令推进请求槽
    input  logic                            push_i,                  // push 一条访存请求
    input  logic [WARP_W-1:0]               push_wid_i,
    input  logic                            push_store_i,            // is store?
    input  logic                            push_global_i,           // is global?
    input  logic [GPR_W-1:0]                push_rd_i,               // write back 的时候返还给 wb_addr_o
    input  logic [15:0]                     push_pc_i,               // 这个只是存下来，出错报给 core trap
    input  logic [LANES-1:0][31:0]          push_addr_i,
    input  logic [LANES-1:0][31:0]          push_wdata_i,
    input  logic [LANES-1:0]                push_mask_i,
    // 状态：`busy_o` 是"该 warp 还有没做完的访存"，`done_o` 是"本拍做完了"
    output logic [WARPS-1:0]                busy_o,
    output logic [WARPS-1:0]                done_o,
    // load 数据回写（per lane）
    output logic [LANES-1:0]                wb_mask_o,
    output logic [WARP_W-1:0]               wb_wid_o,
    output logic [GPR_W-1:0]                wb_addr_o,
    output logic [LANES-1:0][31:0]          wb_data_o,
    input  logic                            wb_stall_i,
    // 出错：整个 block 停在第一个出错的 lane 上
    output logic                            fault_o,
    output logic [3:0]                      fault_code_o,
    output logic [WARP_W-1:0]               fault_wid_o,
    output logic [15:0]                     fault_pc_o,
    input  logic                            flush_i,
    // shared memory：一轮一次（LSU 保证同 bank 同地址）
    output logic [LANES-1:0]                smem_req_mask_o,
    output logic [LANES-1:0]                smem_we_o,
    output logic [LANES-1:0][31:0]          smem_addr_o,
    output logic [LANES-1:0][31:0]          smem_wdata_o,
    input  logic [LANES-1:0][31:0]          smem_rdata_i,
    // global 请求：交给核里的 SK_coalescer
    output logic                            gm_req_start_o,
    output logic                            gm_req_we_o,
    output logic [LANES-1:0][31:0]          gm_req_addr_o,
    output logic [LANES-1:0][31:0]          gm_req_wdata_o,
    output logic [LANES-1:0]                gm_req_mask_o,
    input  logic                            gm_done_i,
    input  logic                            gm_fault_i,
    input  logic [LANES-1:0]                gm_wb_mask_i,
    input  logic [LANES-1:0][31:0]          gm_wb_data_i,
    // 性能事件
    output logic                            ev_lds_txn_o,
    output logic                            ev_sts_txn_o,
    output logic                            ev_lds_replay_o
);

    import SK_pkg::*;

    // 每个 warp 一个请求槽，在时序逻辑里面从 push_xxx_i 打拍赋值
    logic [WARPS-1:0]                  valid_q;
    logic [WARPS-1:0]                  store_q;
    logic [WARPS-1:0]                  global_q;
    logic [WARPS-1:0][GPR_W-1:0]       rd_q;
    logic [WARPS-1:0][15:0]            pc_q;
    logic [WARPS-1:0][LANES-1:0][31:0] addr_q;
    logic [WARPS-1:0][LANES-1:0][31:0] wdata_q;
    logic [WARPS-1:0][LANES-1:0]       mask_q;

    // 正在服务的请求
    typedef enum logic [2:0] {
        ST_IDLE, ST_FAULT, ST_SMEM_ROUND, ST_SMEM_ISSUE, ST_SMEM_WAIT, ST_GMEM
    } svc_e;
    svc_e              svc_q;         // 状态
    logic [WARP_W-1:0] sel_q;
    logic [WARP_W-1:0] rr_q;          // 下一次从哪个 warp 开始找
    logic [3:0]        check_code_q;  // 预检查出的错误码（ST_FAULT 用）
    logic [LANES-1:0]  rem_q;         // shared：还没服务的活跃 lane
    logic [LANES-1:0]  round_q;       // shared：本轮的 lane（寄存一拍，缩短回写路径）
    logic              gm_started_q;

    logic [WARP_W-1:0] sel, sel_next;
    logic              sel_valid;
    logic [WARP_W-1:0] index;
    logic              start;

    // round-robin 选择有积压请求的 warp
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

    // 这一拍可以发起一条新的访存请求
    assign start = (svc_q == ST_IDLE) && sel_valid;
    // 没有 IDLE 的时候先把 sel_q 做完，到 IDLE 切下一条请求
    assign sel   = (svc_q == ST_IDLE) ? sel_next : sel_q;

    // --- 选中请求的字段 ---
    logic              cur_store, cur_global;
    logic [LANES-1:0]  cur_mask;
    logic [LANES-1:0][31:0] cur_addr, cur_wdata;

    assign cur_store  = store_q[sel];
    assign cur_global = global_q[sel];
    assign cur_mask   = mask_q[sel];
    assign cur_addr   = addr_q[sel];
    assign cur_wdata  = wdata_q[sel];

    // --- 预检查：最低的出错 lane 决定错误码（和黄金模型的 lane 升序检查一致）---
    logic       chk_fault;
    logic [3:0] chk_code;
    always_comb begin
        logic [3:0] lane_code;
        chk_fault = 1'b0;
        chk_code  = SK_STATUS_OK;
        for (int lane = 0; lane < LANES; lane++) begin
            lane_code = SK_STATUS_OK;
            if (cur_mask[lane]) begin
                if (cur_addr[lane][1:0] != 2'b00) begin
                    lane_code = SK_STATUS_UNALIGNED;
                end else if (cur_global && (cur_addr[lane] > 32'(GMEM_BYTES - 4))) begin
                    lane_code = SK_STATUS_GMEM_OOB;
                end else if (!cur_global && (cur_addr[lane] > 32'(SMEM_BYTES - 4))) begin
                    lane_code = SK_STATUS_SMEM_OOB;
                end
            end
            if (!chk_fault && (lane_code != SK_STATUS_OK)) begin
                chk_fault = 1'b1;
                chk_code  = lane_code;
            end
        end
    end

    // --- shared memory 分轮：先把同地址的写去重（最高 lane 胜），再按 bank 贪心 ---
    // 这一段代码目标是仲裁得出 round_mask（本轮需要处理的 lane）和 next_rem（下一轮还剩哪些 lane）
    logic [LANES-1:0] eff_mask, drop_mask, round_mask, next_rem;
    logic [BANK_W-1:0] bank_of_lane [LANES];

    always_comb begin
        for (int lane = 0; lane < LANES; lane++) begin
            bank_of_lane[lane] = cur_addr[lane][2+BANK_W-1:2];
        end
    end

    always_comb begin
        logic [LANES-1:0] bank_used;
        logic [LANES-1:0][31:0] bank_addr;

        // 写：同一个 word 只留最高 lane（golden 按 lane 升序写、后写覆盖）
        eff_mask = rem_q;
        if (cur_store) begin
            for (int lane = 0; lane < LANES; lane++) begin
                if (rem_q[lane]) begin
                    for (int other = lane + 1; other < LANES; other++) begin
                        if (rem_q[other] && (cur_addr[other] == cur_addr[lane])) begin
                            eff_mask[lane] = 1'b0;
                        end
                    end
                end
            end
        end

        round_mask = '0;      // 这一轮可以解决掉的 lane
        bank_used  = '0;
        bank_addr  = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            if (eff_mask[lane]) begin
                if (!bank_used[bank_of_lane[lane]]) begin
                    round_mask[lane] = 1'b1;      // 初次访问某个 bank
                    bank_used[bank_of_lane[lane]] = 1'b1;
                    bank_addr[bank_of_lane[lane]] = cur_addr[lane];
                end else if (bank_addr[bank_of_lane[lane]] == cur_addr[lane]) begin
                    round_mask[lane] = 1'b1;      // 广播
                end
            end
        end
    end

    assign drop_mask = rem_q & ~eff_mask;                   // 低 lane 的重复地址写无意义
    assign next_rem  = rem_q & ~(round_mask | drop_mask);   // 连同（广播后）本轮解决的 lane 一起置零

    always_comb begin
        smem_req_mask_o = ((svc_q == ST_SMEM_ISSUE) || (svc_q == ST_SMEM_WAIT))
                          ? round_q : '0;
        for (int lane = 0; lane < LANES; lane++) begin
            smem_we_o[lane]    = (svc_q == ST_SMEM_ISSUE) && cur_store && round_q[lane];
            smem_addr_o[lane]  = cur_addr[lane];
            smem_wdata_o[lane] = cur_wdata[lane];
        end
    end

    // --- global 通路：交给 coalescer ---
    assign gm_req_start_o = (svc_q == ST_GMEM) && !gm_started_q;
    assign gm_req_we_o    = cur_store;
    assign gm_req_addr_o  = cur_addr;
    assign gm_req_wdata_o = cur_wdata;
    assign gm_req_mask_o  = cur_mask;

    // --- 回写源：shared 一次本轮全部 lane，global 由 coalescer 给 ---
    logic [LANES-1:0]       smem_wb_mask;
    logic [LANES-1:0][31:0] smem_wb_data;

    always_comb begin
        smem_wb_mask = '0;
        smem_wb_data = '0;
        if ((svc_q == ST_SMEM_WAIT) && !cur_store && !wb_stall_i) begin
            smem_wb_mask = round_q;
            for (int lane = 0; lane < LANES; lane++) begin
                smem_wb_data[lane] = smem_rdata_i[lane];
            end
        end
    end

    assign wb_mask_o = (svc_q == ST_SMEM_WAIT) ? smem_wb_mask : gm_wb_mask_i;
    assign wb_data_o = (svc_q == ST_SMEM_WAIT) ? smem_wb_data : gm_wb_data_i;
    assign wb_wid_o  = sel;
    assign wb_addr_o = rd_q[sel];

    assign busy_o = valid_q;
    assign done_o = req_done ? (WARPS'(1) << sel) : '0;

    assign fault_o      = (svc_q == ST_FAULT);
    assign fault_code_o = check_code_q;
    assign fault_wid_o  = sel_q;
    assign fault_pc_o   = pc_q[sel_q];

    // 这一拍就能完成，下一拍 IDLE
    logic req_done;

    // 对应时序逻辑部分会出现 svc_q <= ST_IDLE 的地方
    always_comb begin
        req_done = 1'b0;
        if (svc_q == ST_IDLE) begin
            req_done = start && (cur_mask == '0);
        end else if (svc_q == ST_SMEM_ISSUE) begin
            // 写请求在 ISSUE 当拍生效；load 还要等读数据
            req_done = cur_store && (rem_q == '0);
        end else if (svc_q == ST_SMEM_WAIT) begin
            req_done = !wb_stall_i && (rem_q == '0);
        end else if (svc_q == ST_GMEM) begin
            req_done = gm_done_i && !gm_fault_i;
        end
    end

    assign ev_lds_txn_o    = (svc_q == ST_SMEM_WAIT) && req_done && !cur_store;
    assign ev_sts_txn_o    = (svc_q == ST_SMEM_ISSUE) && req_done && cur_store;
    assign ev_lds_replay_o = (svc_q == ST_SMEM_ROUND) && !cur_store && (rem_q != cur_mask);

    // --- 顺序逻辑 ---
    always_ff @(posedge clk) begin
        if (!aresetn || flush_i) begin
            valid_q      <= '0;
            svc_q        <= ST_IDLE;
            sel_q        <= '0;
            rr_q         <= '0;
            check_code_q <= SK_STATUS_OK;
            rem_q        <= '0;
            round_q      <= '0;
            gm_started_q <= 1'b0;
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

            unique case (svc_q)
                ST_IDLE: begin
                    gm_started_q <= 1'b0;
                    if (start) begin
                        sel_q <= sel_next;
                        if (cur_mask == '0) begin
                            // 一条 lane 都不活跃：不算访问，直接完成
                            valid_q[sel_next] <= 1'b0;
                            rr_q              <= sel_next + WARP_W'(1);
                        end else if (chk_fault) begin
                            svc_q        <= ST_FAULT;
                            check_code_q <= chk_code;
                        end else if (cur_global) begin
                            svc_q <= ST_GMEM;
                        end else begin
                            svc_q <= ST_SMEM_ROUND;
                            rem_q <= cur_mask;
                        end
                    end
                end
                ST_FAULT: begin
                    // 整台核停在第一个出错的 lane 上；等 flush 清掉
                end
                ST_SMEM_ROUND: begin
                    // 先把本轮要服务的 lane 定下来并寄存：bank 冲突逻辑不进回写路径
                    round_q <= round_mask;
                    rem_q   <= next_rem;
                    svc_q   <= ST_SMEM_ISSUE;
                end
                ST_SMEM_ISSUE: begin
                    if (cur_store) begin
                        // 写当拍生效：本轮做完就排下一轮
                        if (rem_q == '0) begin
                            valid_q[sel_q] <= 1'b0;
                            rr_q           <= sel_q + WARP_W'(1);
                            svc_q          <= ST_IDLE;
                        end else begin
                            svc_q <= ST_SMEM_ROUND;
                        end
                    end else begin
                        svc_q <= ST_SMEM_WAIT;
                    end
                end
                ST_SMEM_WAIT: begin
                    // 读数据有效；写口忙就原地等
                    if (!wb_stall_i) begin
                        if (rem_q == '0) begin
                            valid_q[sel_q] <= 1'b0;
                            rr_q           <= sel_q + WARP_W'(1);
                            svc_q          <= ST_IDLE;
                        end else begin
                            svc_q <= ST_SMEM_ROUND;
                        end
                    end
                end
                ST_GMEM: begin
                    if (!gm_started_q) gm_started_q <= 1'b1;
                    if (gm_fault_i) begin
                        svc_q        <= ST_FAULT;
                        check_code_q <= SK_STATUS_GMEM_OOB;
                    end else if (gm_done_i) begin
                        valid_q[sel_q] <= 1'b0;
                        rr_q           <= sel_q + WARP_W'(1);
                        svc_q          <= ST_IDLE;
                        gm_started_q   <= 1'b0;
                    end
                end
                default: svc_q <= ST_IDLE;
            endcase
        end
    end

endmodule
