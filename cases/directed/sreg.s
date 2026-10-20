; 定向：特殊寄存器、VOTE、SHFL、NOP/BAR（单 warp × 4 lane）

        SREAD   r1, S_TID               ; 0,1,2,3
        SREAD   r2, S_LANEID            ; 0,1,2,3
        SREAD   r3, S_WID               ; 0
        SREAD   r4, S_WARPSZ            ; 4
        SREAD   r5, S_NWARP             ; 4（硬件容量）
        SREAD   r6, S_GRID              ; 1
        SREAD   r7, S_BID               ; 0
        SREAD   r8, S_BLOCK_DIM         ; 4
        SREAD   r9, S_ARG0              ; --set ARG0=42
        SREAD   r10, S_PTR_C            ; --set PTR_C=0x3000

        CMP.LT  p0, r2, r4              ; lane < 4 -> 全 lane 成立
        VOTE.ANY r11, p0                ; 1
        VOTE.ALL r12, p0                ; 1
        CMP.GE  p1, r2, r4              ; lane >= 4 -> 全 lane 不成立
        VOTE.ANY r13, p1                ; 0
        VOTE.ALL r14, p1                ; 0

        SHFL.IDX  r15, r9, r4           ; src = 42 % 4 = 2 -> 全 lane 读到 lane2 的 42
        SHFL.UP   r16, r9, r4           ; 越界 -> 自己的值
        SHFL.DOWN r17, r9, r4
        SHFL.BFLY r18, r9, r4

        NOP
        BAR                             ; M 是完整 mask（4 lane 全活跃），直接通过
        SREAD   r19, S_STATUS           ; 0

        EXIT
