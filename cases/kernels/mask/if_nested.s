; 嵌套 IF/ELSE：外层 then（tid 0,1）里再按 tid == 0 分内层两路。
; 每层用自己的一组 mask 寄存器，模板见 docs/design.md §6.2/§6.5
        SREAD   r1, S_TID
        LI      r2, 2
        CMP.LT  p7, r1, r2          ; outer then = tid 0,1
        MSAVE   r24
        MAND.P  r25, r24, p7
        MANDN.P r26, r24, p7
        MREST   r25
        CMP.EQ  p6, r1, r0          ; inner then = tid 0
        MSAVE   r27
        MAND.P  r28, r27, p6
        MANDN.P r29, r27, p6
        MREST   r28
        LI      r3, 1               ; inner then
        MSAVE   r28
        MREST   r29
        LI      r3, 2               ; inner else
        MSAVE   r29
        MOR     r27, r28, r29
        MREST   r27                 ; 内层重汇聚：M = lane0,1
        MSAVE   r25                 ; 外层 then 退出时的 mask
        MREST   r26
        LI      r3, 3               ; outer else：tid 2,3
        MSAVE   r26
        MOR     r24, r25, r26
        MREST   r24
        LI      r4, 99
        EXIT
