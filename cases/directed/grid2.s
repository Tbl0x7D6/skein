; 定向：grid = 2 —— 两个 block 串行跑，用 S_BID 认领各自的活
;   block 0 写 c[0..3] = 100..103，block 1 写 c[4..7] = 104..107。
        SREAD   r1, S_BID               ; 0 / 1
        SREAD   r2, S_BLOCK_DIM         ; 4
        MUL     r3, r1, r2              ; bid * blockDim
        SREAD   r4, S_TID               ; 0..3
        ADD     r5, r3, r4              ; i = bid*4 + tid
        SHLI    r6, r5, 2
        SREAD   r7, S_PTR_C
        ADD     r8, r7, r6
        ADDI    r9, r5, 100
        STG     [r8], r9
        EXIT
