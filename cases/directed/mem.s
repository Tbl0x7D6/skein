; P1：shared/global 读写、立即数偏移，最后用一条非对齐访问检查 UNALIGNED 错误码

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

        LDG     r11, [r9+2]             ; 非对齐 -> STATUS = UNALIGNED，在这里结束
        EXIT
