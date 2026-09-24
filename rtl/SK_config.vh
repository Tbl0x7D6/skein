// Skein 全局参数。参数说明与取舍见 docs/design.md §2。

`ifndef SK_CONFIG_VH
`define SK_CONFIG_VH

`define SK_XLEN         32     // 数据宽度
`define SK_NUM_LANES    4      // 每个 warp 的 lane 数（4/8 由综合实验定）
`define SK_NUM_WARPS    4      // 每核 warp 数
`define SK_NUM_GPR      32     // 每 lane 通用寄存器数（r0 恒为 0）
`define SK_NUM_PRED     8      // 每 lane 谓词数
`define SK_SMEM_KB      32     // shared memory 容量
`define SK_IMEM_KB      16     // 指令存储容量
`define SK_MEM_ADDR_W   32     // global 地址宽度

`endif
