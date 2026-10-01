; SHFL.UP 做前缀和：[0,1,2,3] -> [0,1,3,6]
; 越界时 SHFL.UP 返回自己的值，所以先用谓词把越界 lane 的增量清成 0
        SREAD   r1, S_LANEID
        MOV     r4, r1
        LI      r2, 1
        SHFL.UP r3, r1, r2
        CMP.GE  p2, r4, r2
        SEL     r3, r3, r0, p2
        ADD     r1, r1, r3
        LI      r2, 2
        SHFL.UP r3, r1, r2
        CMP.GE  p2, r4, r2
        SEL     r3, r3, r0, p2
        ADD     r1, r1, r3
        EXIT
