; 定向：global 访存合并的正确性（单 warp × 4 lane）
;   1) 4 条 lane 连续地址：落在同一 cache line，数据要各归各的 lane
;   2) 同一 word 多 lane 写：最高 lane 胜（golden 按 lane 升序写、后写覆盖）
;   3) 一条指令跨两条 line（0x103C 之后就是下一条 line）

        SREAD   r1, S_PTR_A          ; 0x1000，初态 11,22,33,44
        SREAD   r2, S_PTR_B          ; 0x2000
        SREAD   r3, S_PTR_C          ; 0x3000
        SREAD   r4, S_LANEID
        SHLI    r5, r4, 2
        ADD     r6, r1, r5
        LDG     r7, [r6]             ; a[lane]
        ADD     r8, r2, r5
        STG     [r8], r7             ; b[lane] = a[lane]
        LDG     r9, [r8]             ; 读回
        ADD     r10, r3, r5
        STG     [r10], r9            ; c[lane] = b[lane]

        LI      r11, 0x4000          ; 同一 word 冲突写
        STG     [r11], r4
        LDG     r12, [r11]           ; 期望 3（最高 lane）

        LI      r13, 60              ; 0x1000 + 60 + lane*4 -> 跨 line
        ADD     r14, r6, r13
        LDG     r15, [r14]
        ADD     r16, r3, r13
        ADD     r16, r16, r5
        STG     [r16], r15
        EXIT
