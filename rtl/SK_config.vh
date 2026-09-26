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

`endif
