; 定向：shared/global 读写和立即数偏移（单 warp × 4 lane，地址全 lane 一致）

        LI      r1, 64                  ; shared 字节地址
        LI      r2, 0x12345678
        STS     [r1], r2                ; shared[64] = 0x12345678
        LDS     r3, [r1]

        LI      r4, 4096                ; global 字节地址
        STG     [r4], r3
        LDG     r5, [r4]
        LDG     r6, [r4+8]              ; 没写过的地址 -> 0
        ADDI    r7, r4, 12
        STG     [r7], r5
        LDG     r8, [r4+12]

        SREAD   r9, S_PTR_A             ; --set PTR_A=0x1000
        STG     [r9], r5
        LDG     r10, [r9]
        EXIT
