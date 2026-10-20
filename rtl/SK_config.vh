// Skein 全局参数。参数说明与取舍见 docs/design.md §2。
//
// 每个参数都带 `ifndef` 守卫，这样综合/仿真可以用 `-verilog_define SK_NUM_LANES=8`
// （Verilator 是 `-DSK_NUM_LANES=8`）覆盖，用来做 lane 数的面积/时序对比。

`ifndef SK_CONFIG_VH
`define SK_CONFIG_VH

`ifndef SK_XLEN
`define SK_XLEN         32     // 数据宽度
`endif
`ifndef SK_NUM_LANES
`define SK_NUM_LANES    4      // warpSize：每个 warp 的 lane 数（P2 综合实验定，design.md §12.6）
`endif
`ifndef SK_NUM_WARPS
`define SK_NUM_WARPS    4      // 每核 warp 数
`endif
`ifndef SK_NUM_GPR
`define SK_NUM_GPR      32     // 每 lane 通用寄存器数（r0 恒为 0）
`endif
`ifndef SK_NUM_PRED
`define SK_NUM_PRED     8      // 每 lane 谓词数
`endif
`ifndef SK_SMEM_KB
`define SK_SMEM_KB      32     // shared memory 容量
`endif
`ifndef SK_IMEM_KB
`define SK_IMEM_KB      16     // 指令存储容量
`endif
`ifndef SK_MEM_ADDR_W
`define SK_MEM_ADDR_W   32     // global 地址宽度
`endif

// --- P5 内存层次 ---
`ifndef SK_GMEM_KB
`define SK_GMEM_KB       1024   // 核认为的 global 容量（仿真 1 MB；P6 按实际 DDR 容量改）
`endif
`ifndef SK_COALESCE
`define SK_COALESCE     1      // 1 = 按 64 B 行合并同 warp 的访存；0 = 每 lane 一笔（M5 基线）
`endif
`ifndef SK_L1
`define SK_L1           1      // 1 = global 走 L1；0 = coalescer 直连 AXI（M5 对照）
`endif
`ifndef SK_MEM_LINE_BYTES
`define SK_MEM_LINE_BYTES 64   // cache line / coalescer 合并粒度
`endif
`ifndef SK_AXI_DATA_W
`define SK_AXI_DATA_W   512    // AXI4 数据宽度（bit）：一行 64 B，上板对齐 shell
`endif

`endif
