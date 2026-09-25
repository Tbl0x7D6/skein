; P1：IF/ELSE 的手写 mask 序列（docs/design.md §6.2），条件成立、不成立各一次

        LI      r1, 1
        LI      r2, 2
        LI      r10, 0                  ; then 路径的标记
        LI      r11, 0                  ; else 路径的标记

        ; 第一次：1 < 2 成立
        CMP.LT  p7, r1, r2
        MSAVE   r24                     ; 入口 mask
        MAND.P  r25, r24, p7            ; then 路径
        MANDN.P r26, r24, p7            ; else 路径
        MREST   r25
        LI      r10, 10                 ; then body
        MSAVE   r25                     ; then 退出时的 mask
        MREST   r26
        LI      r11, 20                 ; else body（M = 0，不写回）
        MSAVE   r26
        MOR     r24, r25, r26           ; 合并两条路径
        MREST   r24                     ; 重汇聚

        ; 第二次：2 < 1 不成立
        CMP.LT  p7, r2, r1
        MSAVE   r24
        MAND.P  r25, r24, p7
        MANDN.P r26, r24, p7
        MREST   r25
        LI      r12, 30                 ; then body（M = 0，不写回）
        MSAVE   r25
        MREST   r26
        LI      r12, 40                 ; else body
        MSAVE   r26
        MOR     r24, r25, r26
        MREST   r24

        EXIT
