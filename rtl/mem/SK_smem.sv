//! shared memory：`BANKS` 个 bank 的片上 SRAM（默认 bank 数 = lane 数）。
//!
//! 访问是"一轮一次"的：LSU 先把活跃 lane 按 bank 冲突分成若干轮；同一轮里落在
//! 同一个 bank 的 lane 地址必须相同（同地址广播），这由 LSU 保证。每个 bank 一个
//! 写口 + 一个同步读口，读数据下一拍有效；写当拍生效。
//!
//! 主机口（`host_*`，字节地址）给 testbench 装初态 / 读快照，只在核空闲时用：
//! 写当拍生效，读是同步读（给地址后下一拍出数据）。P6 可以直接 tie 掉。

`include "SK_config.vh"

module SK_smem #(
    parameter int LANES  = 4,
    parameter int BANKS  = LANES,          // 2 的幂
    parameter int KBYTES = `SK_SMEM_KB,
    parameter int W_W    = $clog2(KBYTES * 1024 / 4)
) (
    input  logic                   clk,
    input  logic                   aresetn,
    // lane 访问（一轮）
    input  logic [LANES-1:0]       req_mask_i,
    input  logic [LANES-1:0]       we_i,
    input  logic [LANES-1:0][31:0] addr_i,      // 32位：[ROW_W: lane_row][BANK_W: lane_bank][2: offset]
    input  logic [LANES-1:0][31:0] wdata_i,
    output logic [LANES-1:0][31:0] rdata_o,     // 同步读，下一拍有效
    // 主机口（字节地址）
    input  logic                   host_we_i,
    input  logic [W_W-1:0]         host_waddr_i,     // 字地址
    input  logic [31:0]            host_wdata_i,
    input  logic [W_W-1:0]         host_raddr_i,     // 字地址
    input  logic                   host_re_i,
    output logic [31:0]            host_rdata_o
);

    localparam int BANK_W   = (BANKS > 1) ? $clog2(BANKS) : 1;
    localparam int LANES_W  = (LANES > 1) ? $clog2(LANES) : 1;
    localparam int WORDS_PER_BANK = (KBYTES * 1024 / 4) / BANKS;
    localparam int ROW_W    = $clog2(WORDS_PER_BANK);

    logic [31:0] mem_q [BANKS][WORDS_PER_BANK];
    logic [31:0] rd_q  [BANKS];

    // 每条 lane 落在哪个 bank / 哪一行
    logic [BANK_W-1:0] lane_bank [LANES];
    logic [ROW_W-1:0]  lane_row  [LANES];
    always_comb begin
        for (int lane = 0; lane < LANES; lane++) begin
            lane_bank[lane] = addr_i[lane][2+BANK_W-1:2];
            lane_row[lane]  = addr_i[lane][2+BANK_W+ROW_W-1:2+BANK_W];
        end
    end

    // 每个 bank 选一条本轮要服务的 lane
    logic [BANKS-1:0]    bank_any;
    logic [LANES_W-1:0]  bank_lane [BANKS];
    always_comb begin
        for (int b = 0; b < BANKS; b++) begin
            bank_any[b]  = 1'b0;
            bank_lane[b] = '0;
            for (int lane = 0; lane < LANES; lane++) begin
                if (!bank_any[b] && req_mask_i[lane]
                    && (lane_bank[lane] == BANK_W'(b))) begin
                    bank_any[b]  = 1'b1;
                    bank_lane[b] = LANES_W'(lane);
                end
            end
        end
    end

    logic [BANK_W-1:0] host_wbank, host_rbank;
    assign host_wbank = host_waddr_i[BANK_W-1:0];
    assign host_rbank = host_raddr_i[BANK_W-1:0];

    generate
        for (genvar b = 0; b < BANKS; b++) begin : g_bank
            logic             wr_en;
            logic [ROW_W-1:0] wr_row, rd_row;
            logic [31:0]      wr_data;
            logic             host_hit;
            logic [LANES_W-1:0] sel_lane;

            assign host_hit = host_we_i && (host_wbank == BANK_W'(b));
            assign sel_lane = bank_lane[b];

            always_comb begin
                // 主机写优先（调用方保证核空闲，两者不会同时来）
                if (host_hit) begin
                    wr_en   = 1'b1;
                    wr_row  = host_waddr_i[W_W-1:BANK_W];
                    wr_data = host_wdata_i;
                end else begin
                    wr_en   = bank_any[b] && we_i[sel_lane];
                    wr_row  = lane_row[sel_lane];
                    wr_data = wdata_i[sel_lane];
                end

                // 读口：主机读借道（核空闲时 bank_any 全 0）
                if (host_re_i && (host_rbank == BANK_W'(b))) begin
                    rd_row = host_raddr_i[W_W-1:BANK_W];
                end else begin
                    rd_row = lane_row[sel_lane];
                end
            end

            always_ff @(posedge clk) begin
                // 复位只清读寄存器：主机口在复位期间就要能写初态
                if (wr_en) mem_q[b][wr_row] <= wr_data;
                if (!aresetn) rd_q[b] <= '0;
                else          rd_q[b] <= mem_q[b][rd_row];
            end
        end
    endgenerate

    // 每条 lane 取自己 bank 的读数据
    always_comb begin
        for (int lane = 0; lane < LANES; lane++) begin
            rdata_o[lane] = rd_q[lane_bank[lane]];
        end
        host_rdata_o = rd_q[host_rbank];
    end

endmodule
