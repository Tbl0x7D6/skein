; .PM：结果同时写 rd（所有 lane）和 M；同拍读旧 M、写新 M，结果仍 & full（§5.4）
        SREAD   r1, S_TID
        LI      r2, 2
        CMP.LTU p1, r1, r2      ; p1 = lane0,1
        LI      r3, 0b1111
        LI      r4, -1
        MREST   r3              ; M = 0b1111
        MAND.PM r24, r3, p1     ; rd = 0b0011，M 也变成 0b0011
        MSAVE   r25             ; 读回 M
        MOR.PM  r26, r24, p1    ; rd = 0b0011 | (p1 & M) = 0b0011，M 不变
        MSAVE   r27
        MREST   r4              ; M = 0xFFFFFFFF & full
        MAND.PM r5, r4, p1      ; rd = 0xFFFFFFFF & (p1 & M) = 0b0011
        MSAVE   r6
        MANDN.PM r28, r24, p1   ; 旧 M = 0b0011 -> rd = 0，M = 0
        MSAVE   r29             ; M = 0，写被门控，r29 保持初值 0
        EXIT
