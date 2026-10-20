//! 仿真用 AXI4 从机 + 内存模型：64-bit 数据、INCR 突发、单 outstanding。
//!
//! 延迟可配（`rd_lat_i` / `wr_lat_i` 拍）。内存比架构容量多留 64 B：合并器/ L1 的
//! line 填充可能越过容量上界读一点填充数据，真正的越界由核里的预检查报错
//! （docs/design.md §5.5），不靠从机。
//!
//! 主机口（host_*）给 testbench 装初态和读回比对窗口，读写都是字节地址。

module tb_axi_mem #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 64,
    parameter int BYTES  = (1 << 20) + 64
) (
    input  logic                clk,
    input  logic                aresetn,
    input  logic [7:0]          rd_lat_i,
    input  logic [7:0]          wr_lat_i,
    // 从机自己的地址空间基址：AXI 地址 = addr_base_i + 偏移（和板上 BO 一样）。
    // 主机口还是偏移地址，等于主机直接访问那块 BO。
    input  logic [ADDR_W-1:0]   addr_base_i,
    // AXI4 从口
    input  logic [ADDR_W-1:0]   s_awaddr_i,
    input  logic [7:0]          s_awlen_i,
    input  logic [2:0]          s_awsize_i,
    input  logic [1:0]          s_awburst_i,
    input  logic                s_awvalid_i,
    output logic                s_awready_o,
    input  logic [DATA_W-1:0]   s_wdata_i,
    input  logic [DATA_W/8-1:0] s_wstrb_i,
    input  logic                s_wlast_i,
    input  logic                s_wvalid_i,
    output logic                s_wready_o,
    output logic [1:0]          s_bresp_o,
    output logic                s_bvalid_o,
    input  logic                s_bready_i,
    input  logic [ADDR_W-1:0]   s_araddr_i,
    input  logic [7:0]          s_arlen_i,
    input  logic [2:0]          s_arsize_i,
    input  logic [1:0]          s_arburst_i,
    input  logic                s_arvalid_i,
    output logic                s_arready_o,
    output logic [DATA_W-1:0]   s_rdata_o,
    output logic [1:0]          s_rresp_o,
    output logic                s_rlast_o,
    output logic                s_rvalid_o,
    input  logic                s_rready_i,
    // 主机口
    input  logic                host_we_i,
    input  logic [ADDR_W-1:0]   host_addr_i,
    input  logic [31:0]         host_wdata_i,
    input  logic [ADDR_W-1:0]   host_raddr_i,
    output logic [31:0]         host_rdata_o
);

    localparam int STRB_W = DATA_W / 8;
    // 端口地址是 64 位（上板时核的地址要加基址），这里的内存只有 BYTES 大小：
    // 越界由 *_in_range 判，真正访问内存的索引先截到 IDX_W 位。
    localparam int IDX_W = $clog2(BYTES);
    localparam logic [1:0] AXI_INCR = 2'b01;

    logic [7:0] mem [BYTES];

    logic [ADDR_W-1:0] rd_stride, wr_stride;
    assign rd_stride = ADDR_W'(1) << s_arsize_i;
    assign wr_stride = ADDR_W'(1) << s_awsize_i;

    // --- 主机口：组合读、整字写 ---
    logic host_rd_ok, host_wr_ok;
    assign host_rd_ok = (host_raddr_i + ADDR_W'(4)) <= ADDR_W'(BYTES);
    assign host_wr_ok = (host_addr_i + ADDR_W'(4)) <= ADDR_W'(BYTES);
    assign host_rdata_o = !host_rd_ok ? '0 :
                          {mem[host_raddr_i[IDX_W-1:0] + IDX_W'(3)],
                           mem[host_raddr_i[IDX_W-1:0] + IDX_W'(2)],
                           mem[host_raddr_i[IDX_W-1:0] + IDX_W'(1)],
                           mem[host_raddr_i[IDX_W-1:0]]};

    always_ff @(posedge clk) begin
        if (host_we_i && host_wr_ok) begin
            mem[host_addr_i[IDX_W-1:0]]     <= host_wdata_i[7:0];
            mem[host_addr_i[IDX_W-1:0] + IDX_W'(1)] <= host_wdata_i[15:8];
            mem[host_addr_i[IDX_W-1:0] + IDX_W'(2)] <= host_wdata_i[23:16];
            mem[host_addr_i[IDX_W-1:0] + IDX_W'(3)] <= host_wdata_i[31:24];
        end
    end

    // --- 读通道 ---
    typedef enum logic [1:0] {RD_IDLE, RD_WAIT, RD_BEAT} rd_state_e;
    rd_state_e         rd_q;
    logic [ADDR_W-1:0] rd_addr_q;
    logic [7:0]        rd_len_q;
    logic [7:0]        rd_beat_q;
    logic [7:0]        rd_wait_q;

    assign s_arready_o = (rd_q == RD_IDLE);

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            rd_q     <= RD_IDLE;
            rd_wait_q <= '0;
            rd_beat_q <= '0;
        end else begin
            unique case (rd_q)
                RD_IDLE: begin
                    if (s_arvalid_i) begin
                        rd_addr_q <= s_araddr_i;
                        rd_len_q  <= s_arlen_i;
                        rd_beat_q <= '0;
                        rd_wait_q <= rd_lat_i;
                        rd_q      <= (rd_lat_i == '0) ? RD_BEAT : RD_WAIT;
                    end
                end
                RD_WAIT: begin
                    if (rd_wait_q <= 8'd1) rd_q <= RD_BEAT;
                    else                   rd_wait_q <= rd_wait_q - 8'd1;
                end
                RD_BEAT: begin
                    if (s_rvalid_o && s_rready_i) begin
                        if (rd_beat_q == rd_len_q) rd_q <= RD_IDLE;
                        else                       rd_beat_q <= rd_beat_q + 8'd1;
                    end
                end
                default: rd_q <= RD_IDLE;
            endcase
        end
    end

    logic [ADDR_W-1:0] rd_beat_addr;
    logic [ADDR_W-1:0] rd_off;
    logic              rd_in_range;

    assign rd_beat_addr = rd_addr_q + ADDR_W'(rd_beat_q) * rd_stride;
    assign rd_off        = rd_beat_addr - addr_base_i;
    assign rd_in_range  = (rd_beat_addr >= addr_base_i) &&
                          ((rd_off + ADDR_W'(STRB_W)) <= ADDR_W'(BYTES));

    always_comb begin
        s_rvalid_o = (rd_q == RD_BEAT);
        s_rlast_o  = (rd_q == RD_BEAT) && (rd_beat_q == rd_len_q);
        s_rresp_o  = (rd_in_range && (s_arburst_i == AXI_INCR)) ? 2'b00 : 2'b10;  // DECERR
        s_rdata_o  = '0;
        if (rd_in_range) begin
            for (int b = 0; b < STRB_W; b++) begin
                s_rdata_o[b*8 +: 8] = mem[rd_off[IDX_W-1:0] + IDX_W'(b)];
            end
        end
    end

    // --- 写通道 ---
    typedef enum logic [1:0] {WR_IDLE, WR_BEAT, WR_RESP} wr_state_e;
    wr_state_e         wr_q;
    logic [ADDR_W-1:0] wr_addr_q;
    logic [7:0]        wr_len_q;
    logic [7:0]        wr_beat_q;
    logic [7:0]        wr_wait_q;
    logic              wr_err_q;

    assign s_awready_o = (wr_q == WR_IDLE);
    assign s_wready_o  = (wr_q == WR_BEAT);
    assign s_bvalid_o  = (wr_q == WR_RESP) && (wr_wait_q == 8'd0);
    assign s_bresp_o   = wr_err_q ? 2'b10 : 2'b00;

    logic [ADDR_W-1:0] wr_beat_addr;
    logic [ADDR_W-1:0] wr_off;
    logic              wr_in_range;

    assign wr_beat_addr = wr_addr_q + ADDR_W'(wr_beat_q) * wr_stride;
    assign wr_off        = wr_beat_addr - addr_base_i;
    assign wr_in_range  = (wr_beat_addr >= addr_base_i) &&
                          ((wr_off + ADDR_W'(STRB_W)) <= ADDR_W'(BYTES));

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            wr_q      <= WR_IDLE;
            wr_wait_q <= '0;
            wr_beat_q <= '0;
            wr_err_q  <= 1'b0;
        end else begin
            unique case (wr_q)
                WR_IDLE: begin
                    if (s_awvalid_i) begin
                        wr_addr_q <= s_awaddr_i;
                        wr_len_q  <= s_awlen_i;
                        wr_beat_q <= '0;
                        wr_err_q  <= (s_awburst_i != AXI_INCR);
                        wr_q      <= WR_BEAT;
                    end
                end
                WR_BEAT: begin
                    if (s_wvalid_i) begin
                        if (!wr_in_range) wr_err_q <= 1'b1;
                        if (s_wlast_i || (wr_beat_q == wr_len_q)) begin
                            wr_wait_q <= wr_lat_i;
                            wr_q      <= WR_RESP;
                        end else begin
                            wr_beat_q <= wr_beat_q + 8'd1;
                        end
                    end
                end
                WR_RESP: begin
                    if (wr_wait_q != 8'd0) begin
                        wr_wait_q <= wr_wait_q - 8'd1;
                    end else if (s_bready_i) begin
                        wr_q <= WR_IDLE;
                    end
                end
                default: wr_q <= WR_IDLE;
            endcase
        end
    end

    // 写数据在时钟沿写进内存（越界的 beat 丢弃）
    always_ff @(posedge clk) begin
        if ((wr_q == WR_BEAT) && s_wvalid_i && wr_in_range) begin
            for (int b = 0; b < STRB_W; b++) begin
                if (s_wstrb_i[b]) mem[wr_off[IDX_W-1:0] + IDX_W'(b)] <= s_wdata_i[b*8 +: 8];
            end
        end
    end

endmodule
