//! L1 data cache：16 KB、直接映射、行 64 B、写回 + 写分配，阻塞式单 MSHR。
//!
//! 位置在 coalescer 和 AXI master 之间，两边都是同一套"burst 接口"：
//!   - 上游一条请求 = 一次 line 内的 beat 区间（coalescer 分好组）；
//!   - 下游只会发整行的填充（读 8 beat）和脏行回写（写 8 beat）。
//! `ENABLE=0` 时整个模块退化成直通（coalescer 直接接 AXI），给 M5 当对照。
//!
//! 命中约 2 拍；miss 先逐出脏行再填充。`clear_i` 在 block 开始时全表 invalidate；
//! `flush_i` 在整台核跑完、LSU 排空后把脏行写回，写完才给 `flush_done_o`——
//! 这样主机（和 case 的内存窗口）看到的内存才是最终值。
//!
//! 地址划分（16 KB / 64 B）：index = addr[13:6]，tag = addr[31:14]，offset = addr[5:0]。

`include "SK_config.vh"

module SK_l1_cache #(
    parameter int  ENABLE      = `SK_L1,
    parameter int  SETS        = 256,
    parameter int  LINE_WORDS  = 16,
    parameter int  ADDR_W      = 32
) (
    input  logic               clk,
    input  logic               aresetn,
    input  logic               clear_i,        // 块开始：全表 invalidate
    input  logic               flush_i,        // 排空脏行
    output logic               flush_busy_o,
    output logic               flush_done_o,   // 一拍脉冲
    // 上游 burst 接口（来自 coalescer）
    input  logic               up_valid_i,
    output logic               up_ready_o,
    input  logic               up_we_i,
    input  logic [ADDR_W-1:3]  up_addr_i,      // beat 对齐，低 3 位恒 0
    input  logic [2:0]         up_len_i,
    input  logic [63:0]        up_wdata_i,
    input  logic [7:0]         up_wstrb_i,
    output logic               up_wbeat_taken_o,
    output logic               up_rvalid_o,
    output logic [63:0]        up_rdata_o,
    output logic               up_rlast_o,
    input  logic               up_rready_i,
    output logic               up_done_o,
    output logic               up_fault_o,
    // 下游 burst 接口（到 AXI master）
    output logic               dn_valid_o,
    input  logic               dn_ready_i,
    output logic               dn_we_o,
    output logic [ADDR_W-1:0]  dn_addr_o,
    output logic [2:0]         dn_len_o,
    output logic [63:0]        dn_wdata_o,
    output logic [7:0]         dn_wstrb_o,
    input  logic               dn_wbeat_taken_i,
    input  logic               dn_rvalid_i,
    input  logic [63:0]        dn_rdata_i,
    input  logic               dn_rlast_i,
    output logic               dn_rready_o,
    input  logic               dn_done_i,
    input  logic               dn_fault_i,
    // 性能事件
    output logic               ev_rd_hit_o,
    output logic               ev_rd_miss_o,
    output logic               ev_wr_hit_o,
    output logic               ev_wr_miss_o,
    output logic               ev_wb_o
);

    localparam int IDX_W = $clog2(SETS);              // 8
    localparam int TAG_W = ADDR_W - IDX_W - 6;        // 18
    localparam int BEATS = LINE_WORDS / 2;            // 8 beat = 64 B

    generate
    if (ENABLE == 0) begin : g_bypass
        // 直通：coalescer 的 burst 原样交给 AXI master
        assign up_ready_o       = dn_ready_i;
        assign dn_valid_o       = up_valid_i;
        assign dn_we_o          = up_we_i;
        assign dn_addr_o        = {up_addr_i, 3'b0};
        assign dn_len_o         = up_len_i;
        assign dn_wdata_o       = up_wdata_i;
        assign dn_wstrb_o       = up_wstrb_i;
        assign up_wbeat_taken_o = dn_wbeat_taken_i;
        assign up_rvalid_o      = dn_rvalid_i;
        assign up_rdata_o       = dn_rdata_i;
        assign up_rlast_o       = dn_rlast_i;
        assign dn_rready_o      = up_rready_i;
        assign up_done_o        = dn_done_i;
        assign up_fault_o       = dn_fault_i;
        // 没有缓存也没有脏行：flush 走一拍寄存器，当拍和下拍都给完成脉冲
        logic flush_done_q;
        always_ff @(posedge clk) begin
            if (!aresetn || clear_i) flush_done_q <= 1'b0;
            else                     flush_done_q <= flush_i;
        end
        assign flush_busy_o     = flush_i;
        assign flush_done_o     = flush_i || flush_done_q;
        assign ev_rd_hit_o      = 1'b0;
        assign ev_rd_miss_o     = 1'b0;
        assign ev_wr_hit_o      = 1'b0;
        assign ev_wr_miss_o     = 1'b0;
        assign ev_wb_o          = 1'b0;
    end else begin : g_cache

    typedef enum logic [3:0] {
        ST_IDLE, ST_WR_BEATS, ST_LOOKUP, ST_RD_DATA, ST_EVICT_REQ, ST_EVICT,
        ST_FILL_REQ, ST_FILL, ST_WRITE_LINE, ST_RESP,
        ST_FLUSH_NEXT, ST_FLUSH_READ, ST_FLUSH_REQ, ST_FLUSH_WR
    } state_e;

    state_e state_q;

    logic [SETS-1:0]  valid_q, dirty_q;
    logic [TAG_W-1:0] tag_q [SETS];
    logic [LINE_WORDS*32-1:0] line_rd_q;         // 数据 RAM 的同步读输出
    logic [LINE_WORDS-1:0][31:0] rd_line_q;      // 数据 RAM 的同步读输出

    // 当前请求
    logic              we_q;
    logic [2:0]        len_q;
    logic [ADDR_W-1:6] line_addr_q;
    logic [IDX_W-1:0]  idx_q;
    logic [TAG_W-1:0]  req_tag_q, victim_tag_q;
    logic [2:0]        first_beat_q;
    logic              hit_q;

    // 数据缓冲
    logic [BEATS-1:0][63:0] wbuf_q;
    logic [BEATS-1:0][7:0]  wstrb_q;
    logic [LINE_WORDS-1:0][31:0] line_q;         // 命中读出的行 / 被逐出的脏行
    logic [LINE_WORDS-1:0][31:0] fill_q;         // 填充收集

    logic [3:0] wcnt_q, rcnt_q, fcnt_q;
    logic [IDX_W-1:0] flush_idx_q;
    logic       flush_active_q, flush_done_q;
    logic       flush_beats_done_q;      // 本行 beat 交完了，等下游事务真正做完
    logic       fault_q;

    // --- 数据 RAM：一个读口 + 一个整行写口（走 SK_dp_ram 模板，保证落进 BRAM）---
    logic                 ram_we;
    logic [IDX_W-1:0]     ram_widx, ram_ridx;
    logic [LINE_WORDS-1:0][31:0] ram_wdata;

    assign ram_we   = (state_q == ST_WRITE_LINE);
    assign ram_widx = idx_q;
    always_comb begin
        if ((state_q == ST_FLUSH_NEXT) || (state_q == ST_FLUSH_READ)) ram_ridx = flush_idx_q;
        else                                                          ram_ridx = idx_q;
    end

    // 行数据来源：命中用刚读出的行，miss 用填充回来的行
    logic [LINE_WORDS-1:0][31:0] line_src;
    assign line_src = ((state_q == ST_WRITE_LINE) && !hit_q) ? fill_q : line_q;

    // store 合并：wbuf 的第 k 拍对应 line 的第 first_beat + k 拍
    logic [LINE_WORDS-1:0][31:0] merge_data;
    always_comb begin
        merge_data = line_src;
        if (we_q) begin
            for (int b = 0; b < BEATS; b++) begin
                // 只有前 len+1 拍是这条请求写的，wbuf 其它拍是上一条请求留下的
                if (3'(b) <= len_q) begin
                    for (int bi = 0; bi < 8; bi++) begin
                        // off = (line 内 beat) * 8 + beat 内字节偏移
                        automatic logic [5:0] off = {first_beat_q + 3'(b), 3'(bi)};
                        if (wstrb_q[b][bi]) begin
                            merge_data[off[5:2]][{off[1:0], 3'b0} +: 8] =
                                wbuf_q[b][bi*8 +: 8];
                        end
                    end
                end
            end
        end
    end
    assign ram_wdata = merge_data;

    SK_dp_ram #(.WIDTH(LINE_WORDS * 32), .DEPTH(SETS)) u_line_ram (
        .clk     (clk),
        .we_i    (ram_we),
        .strb_i  ('1),
        .waddr_i (ram_widx),
        .wdata_i (ram_wdata),
        .re_i    (1'b1),
        .raddr_i (ram_ridx),
        .rdata_o (line_rd_q)
    );
    assign rd_line_q = line_rd_q;

    // --- tag / valid / dirty ---
    always_ff @(posedge clk) begin
        if (!aresetn || clear_i) begin
            valid_q <= '0;
            dirty_q <= '0;
        end else begin
            if (state_q == ST_WRITE_LINE) begin
                valid_q[idx_q] <= 1'b1;
                dirty_q[idx_q] <= we_q;
                tag_q[idx_q]   <= req_tag_q;
            end
            if ((state_q == ST_FLUSH_WR) && dn_wbeat_taken_i
                && (dn_beat == 3'(BEATS - 1))) begin
                dirty_q[flush_idx_q] <= 1'b0;
            end
        end
    end

    // --- 上游响应 ---
    logic [2:0] rsp_beat;
    assign rsp_beat = first_beat_q + rcnt_q[2:0];

    always_comb begin
        up_rvalid_o = (state_q == ST_RESP);
        up_rlast_o  = (state_q == ST_RESP) && (rcnt_q[2:0] == len_q);
        up_rdata_o  = {line_q[rsp_beat*2 + 1], line_q[rsp_beat*2]};
    end

    assign up_ready_o       = (state_q == ST_IDLE) && !flush_active_q;
    assign up_wbeat_taken_o = (state_q == ST_WR_BEATS);

    // --- 下游：填充 / 脏行回写 ---
    logic       dn_is_wb;
    logic [2:0] dn_beat;

    assign dn_is_wb  = (state_q == ST_EVICT_REQ) || (state_q == ST_EVICT)
                    || (state_q == ST_FLUSH_REQ) || (state_q == ST_FLUSH_WR);
    assign dn_valid_o = (state_q == ST_EVICT_REQ) || (state_q == ST_FILL_REQ)
                     || (state_q == ST_FLUSH_REQ);
    assign dn_we_o    = dn_is_wb;
    assign dn_addr_o  = (state_q == ST_FLUSH_REQ)
                      ? {tag_q[flush_idx_q], flush_idx_q, 6'b0}
                      : (dn_is_wb ? {victim_tag_q, idx_q, 6'b0}
                                  : {line_addr_q, 6'b0});
    assign dn_len_o   = 3'(BEATS - 1);

    always_comb begin
        dn_wdata_o = '0;
        dn_wstrb_o = '0;
        if ((state_q == ST_EVICT) || (state_q == ST_FLUSH_WR)) begin
            dn_wdata_o = {line_q[dn_beat*2 + 1], line_q[dn_beat*2]};
            dn_wstrb_o = 8'hFF;
        end
    end

    assign dn_rready_o = (state_q == ST_FILL);

    always_ff @(posedge clk) begin
        if ((state_q == ST_FILL) && dn_rvalid_i && dn_rready_o) begin
            fill_q[{fcnt_q[2:0], 1'b0}]     <= dn_rdata_i[31:0];
            fill_q[{fcnt_q[2:0], 1'b0} + 1] <= dn_rdata_i[63:32];
        end
    end

    always_ff @(posedge clk) begin
        if (state_q == ST_FILL) begin
            if (dn_rvalid_i && dn_rready_o && dn_rlast_i) fcnt_q <= '0;
            else if (dn_rvalid_i && dn_rready_o)          fcnt_q <= fcnt_q + 4'd1;
        end else begin
            fcnt_q <= '0;
        end

        if ((state_q == ST_EVICT) || (state_q == ST_FLUSH_WR)) begin
            if (dn_wbeat_taken_i) dn_beat <= dn_beat + 3'd1;
        end else begin
            dn_beat <= '0;
        end
    end

    // --- 事件 / 完成 ---
    assign ev_rd_hit_o  = (state_q == ST_RD_DATA) && hit_q && !we_q;
    assign ev_rd_miss_o = (state_q == ST_RD_DATA) && !hit_q && !we_q;
    assign ev_wr_hit_o  = (state_q == ST_RD_DATA) && hit_q && we_q;
    assign ev_wr_miss_o = (state_q == ST_RD_DATA) && !hit_q && we_q;
    assign ev_wb_o      = ((state_q == ST_EVICT_REQ) || (state_q == ST_FLUSH_REQ))
                       && dn_ready_i;

    assign up_done_o  = ((state_q == ST_WRITE_LINE) && we_q)
                     || ((state_q == ST_RESP) && up_rvalid_o && up_rready_i
                         && (rcnt_q[2:0] == len_q));
    assign up_fault_o = fault_q;
    assign flush_busy_o = flush_active_q;
    assign flush_done_o = flush_done_q;

    // --- 主状态机 ---
    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state_q        <= ST_IDLE;
            we_q           <= 1'b0;
            len_q          <= '0;
            line_addr_q    <= '0;
            idx_q          <= '0;
            req_tag_q      <= '0;
            victim_tag_q   <= '0;
            first_beat_q   <= '0;
            hit_q          <= 1'b0;
            wcnt_q         <= '0;
            rcnt_q         <= '0;
            flush_idx_q    <= '0;
            flush_active_q <= 1'b0;
            flush_done_q   <= 1'b0;
            flush_beats_done_q <= 1'b0;
            fault_q        <= 1'b0;
        end else begin
            flush_done_q <= 1'b0;
            fault_q      <= 1'b0;

            unique case (state_q)
                ST_IDLE: begin
                    if (up_valid_i && up_ready_o) begin
                        we_q         <= up_we_i;
                        len_q        <= up_len_i;
                        line_addr_q  <= up_addr_i[ADDR_W-1:6];
                        idx_q        <= up_addr_i[IDX_W+5:6];
                        req_tag_q    <= up_addr_i[ADDR_W-1:IDX_W+6];
                        first_beat_q <= up_addr_i[5:3];
                        wcnt_q       <= '0;
                        rcnt_q       <= '0;
                        state_q      <= up_we_i ? ST_WR_BEATS : ST_LOOKUP;
                    end else if (flush_i && !flush_active_q && !up_valid_i) begin
                        flush_active_q <= 1'b1;
                        flush_idx_q    <= '0;
                        state_q        <= ST_FLUSH_NEXT;
                    end
                end
                ST_WR_BEATS: begin
                    wbuf_q[wcnt_q[2:0]]  <= up_wdata_i;
                    wstrb_q[wcnt_q[2:0]] <= up_wstrb_i;
                    if (wcnt_q[2:0] == len_q) state_q <= ST_LOOKUP;
                    else                 wcnt_q <= wcnt_q + 4'd1;
                end
                ST_LOOKUP: begin
                    hit_q        <= valid_q[idx_q] && (tag_q[idx_q] == req_tag_q);
                    victim_tag_q <= tag_q[idx_q];
                    state_q      <= ST_RD_DATA;
                end
                ST_RD_DATA: begin
                    line_q <= rd_line_q;
                    if (hit_q) begin
                        state_q <= we_q ? ST_WRITE_LINE : ST_RESP;
                    end else begin
                        state_q <= dirty_q[idx_q] ? ST_EVICT_REQ : ST_FILL_REQ;
                    end
                end
                ST_EVICT_REQ: if (dn_ready_i) state_q <= ST_EVICT;
                ST_EVICT: begin
                    if (dn_wbeat_taken_i && (dn_beat == 3'(BEATS - 1))) begin
                        state_q <= ST_FILL_REQ;
                    end
                end
                ST_FILL_REQ: if (dn_ready_i) state_q <= ST_FILL;
                ST_FILL: begin
                    if (dn_done_i) state_q <= ST_WRITE_LINE;
                end
                ST_WRITE_LINE: begin
                    line_q <= merge_data;
                    state_q <= we_q ? ST_IDLE : ST_RESP;
                    if (we_q) flush_done_q <= 1'b0;
                end
                ST_RESP: begin
                    if (up_rvalid_o && up_rready_i) begin
                        if (rcnt_q[2:0] == len_q) state_q <= ST_IDLE;
                        else                 rcnt_q <= rcnt_q + 4'd1;
                    end
                end
                ST_FLUSH_NEXT: begin
                    if (dirty_q[flush_idx_q]) begin
                        state_q <= ST_FLUSH_READ;
                    end else if (flush_idx_q == IDX_W'(SETS - 1)) begin
                        flush_active_q <= 1'b0;
                        flush_done_q   <= 1'b1;
                        state_q        <= ST_IDLE;
                    end else begin
                        flush_idx_q <= flush_idx_q + IDX_W'(1);
                    end
                end
                ST_FLUSH_READ: begin
                    line_q  <= rd_line_q;
                    state_q <= ST_FLUSH_REQ;
                end
                ST_FLUSH_REQ: if (dn_ready_i) state_q <= ST_FLUSH_WR;
                ST_FLUSH_WR: begin
                    // 关键：要等下游事务做完（dn_done_i，写完收到 B），不能只看
                    // beat 交完——新的 AXI master 会先把整行攒起来再发总线，
                    // beat 交完时写还在它的缓冲里。早报 done 的话，主机可能在
                    // 最后一笔写回落到内存之前就读 BO。
                    if (dn_wbeat_taken_i && (dn_beat == 3'(BEATS - 1))) begin
                        flush_beats_done_q <= 1'b1;
                    end
                    if ((flush_beats_done_q ||
                         (dn_wbeat_taken_i && (dn_beat == 3'(BEATS - 1)))) && dn_done_i) begin
                        flush_beats_done_q <= 1'b0;
                        if (flush_idx_q == IDX_W'(SETS - 1)) begin
                            flush_active_q <= 1'b0;
                            flush_done_q   <= 1'b1;
                            state_q        <= ST_IDLE;
                        end else begin
                            flush_idx_q <= flush_idx_q + IDX_W'(1);
                            state_q     <= ST_FLUSH_NEXT;
                        end
                    end
                end
                default: state_q <= ST_IDLE;
            endcase

            if (dn_fault_i) begin
                fault_q <= 1'b1;
                state_q <= ST_IDLE;
            end
        end
    end

    end
    endgenerate

endmodule
