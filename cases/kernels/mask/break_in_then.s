; break 写在 IF/ELSE 的 then 里时，不能把 else 路径的 lane 从循环 mask 里删掉
; （MANDN.P 只作用于当前 M；见 docs/design.md §6.4）
        SREAD   r7, S_TID           ; tid 0..3
        LI      r1, 0               ; i
        LI      r2, 2               ; 阈值：tid >= 2 走 then
        LI      r3, 4               ; 循环 n 轮
        LI      r4, 0               ; else 路径执行了几轮
        MSAVE   r24
        MSAVE   r25
loop:
        MREST   r25
        CMP.LT  p7, r1, r3          ; i < n
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, done
        ADDI    r1, r1, 1           ; i++
        CMP.GE  p1, r7, r2          ; then = tid >= 2
        MSAVE   r26                 ; 入口 mask
        MAND.P  r27, r26, p1        ; then 路径
        MANDN.P r28, r26, p1        ; else 路径
        MREST   r27
        LI      r5, 2
        CMP.EQ  p6, r1, r5          ; 第 2 轮时 then 里的 break
        MANDN.P r25, r25, p6        ; 只删 M 内的 lane
        MCLR.P  p6
        MSAVE   r27                 ; then 退出时的 mask
        MREST   r28
        ADDI    r4, r4, 1           ; else 路径的计数
        MSAVE   r28
        MOR     r26, r27, r28       ; 合并两条路径
        MREST   r26
        JMP     loop
done:
        MREST   r24
        EXIT
