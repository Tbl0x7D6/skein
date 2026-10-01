//! 块内屏障：所有还活着的 warp 都到了 BAR 就一起放行。
//!
//! 语义和黄金模型一致：有 warp 在 BAR 上等、且没有任何 warp 还在跑（都到了 BAR 或者
//! 已经 EXIT），就放行所有等着的 warp，屏障计数 +1。只剩一条 warp 也会被自己放行。
//! `BAR` 要求 M 是完整 mask，没排空访存就不进屏障——这两条由 `SK_core` 的译码级兜住。

module SK_bar_unit #(
    parameter int WARPS = 4
) (
    input  logic [WARPS-1:0] bar_i,      // 在 BAR 上等着的 warp
    input  logic [WARPS-1:0] done_i,     // 已经结束的 warp
    output logic             release_o
);

    assign release_o = (|bar_i) && ((bar_i | done_i) == '1);

endmodule
