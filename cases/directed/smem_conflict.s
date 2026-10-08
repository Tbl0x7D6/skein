; 定向：shared 的 bank 冲突与同地址广播（单 warp × 4 lane）
;   bank = 字地址 mod 4。lane*16 B 的字地址是 4*lane，四条 lane 全落在 bank 0，
;   一次 LDS/STS 要拆成 4 轮（--stats 里的 lds_replay 能看见）。
        LI      r1, 64              ; shared 基址
        SREAD   r2, S_LANEID
        SHLI    r3, r2, 4           ; lane * 16 B → 全在 bank 0
        ADD     r4, r1, r3
        LI      r5, 100
        ADD     r5, r5, r2          ; 每 lane 自己的值
        STS     [r4], r5            ; 4 个 lane 同 bank 不同字：4 轮
        LDS     r6, [r4]            ; 读回：同样 4 轮

        LI      r7, 256
        LDS     r8, [r7]            ; 同地址读：一轮里广播（初态 0x55）
        LI      r9, 0x3333
        STS     [r7], r9            ; 同地址写：去重后 1 轮，最高 lane 胜
        LDS     r10, [r7]
        EXIT
