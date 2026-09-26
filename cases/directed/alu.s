; P1：算术、立即数、移位、比较、谓词组合修饰和门控

        LI      r1, 0x12345678          ; LUI + LUM + ORI 三段拼
        LI      r2, -1
        LI      r3, 1000

        ADDI    r4, r1, -1
        ANDI    r5, r4, 0xFF
        ORI     r6, r5, 0x100
        SHLI    r7, r6, 4
        SLTI    r8, r2, 0               ; -1 < 0 -> 1
        LUI     r9, r0, 0xABC           ; 0xABC00000
        LUM     r10, r9, 0x12           ; 0xABC12000

        SUB     r11, r3, r2             ; 1000 - (-1)
        AND     r12, r1, r2
        OR      r13, r1, r2
        XOR     r14, r1, r2
        SHL     r15, r8, r11            ; 1 << (1001 & 31)
        SHR     r16, r1, r6
        SAR     r17, r2, r8             ; 算术右移保留符号
        SLT     r18, r2, r3
        SLTU    r19, r2, r3
        MUL     r20, r3, r3
        MOV     r21, r10
        FMA     r22, r3, r3             ; r22 = 0 + 1000 * 1000

        ; 比较 + 谓词组合修饰（AND/OR/XOR）
        CMP.LT    p0, r2, r3            ; p0 = 1
        CMP.GE    p0, r2, r3            ; 直接赋值 -> 0
        CMP.NE.AND p0, r3, r3           ; 0 & 0 -> 0
        CMP.LT.OR  p1, r2, r3           ; 0 | 1 -> 1
        CMP.NE.XOR p1, r3, r3           ; 1 ^ 0 -> 1
        CMP.GE.AND p1, r3, r3           ; 1 & 1 -> 1
        SEL     r23, r3, r2, p1         ; p1 = 1 -> r23 = 1000

        ; 谓词门控：@p 和 @!p
        CMP.GE  p2, r3, r3              ; 1
        @p2     MOV  r23, r0            ; 执行 -> r23 = 0
        @!p2    MOV  r23, r3            ; 取反为假 -> 不执行
        CMP.GE  p3, r2, r3              ; -1 >= 1000 -> 0
        @p3     ADDI r23, r23, 100      ; 不执行（RI 只有 @p，取反要换条件）
        CMP.LT  p3, r2, r3              ; -1 < 1000 -> 1
        @p3     ADDI r23, r23, 7        ; 执行 -> r23 = 7

        EXIT
