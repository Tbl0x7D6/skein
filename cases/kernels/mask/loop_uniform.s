; 所有 lane 同一轮退出循环（模板见 docs/design.md §6.3）
        LI      r1, 0               ; i
        LI      r2, 5               ; n
        LI      r3, 0               ; sum
        MSAVE   r24
        MSAVE   r25
loop:
        MREST   r25
        CMP.LT  p7, r1, r2          ; i < n
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, done
        ADD     r3, r3, r1
        ADDI    r1, r1, 1
        MREST   r25
        JMP     loop
done:
        MREST   r24
        EXIT
