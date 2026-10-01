; continue：跳过的 lane 在本轮 latch 处 MREST 回来，下一轮照常检查条件（§6.3/§6.4）
        LI      r1, 0               ; i
        LI      r2, 4               ; n
        LI      r3, 0               ; sum
        LI      r6, 2
        MSAVE   r24
        MSAVE   r25
loop:
        MREST   r25
        CMP.LT  p7, r1, r2
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, done
        ADDI    r1, r1, 1           ; i++（continue 之前先自增）
        CMP.EQ  p6, r1, r6          ; i == 2 ?
        MCLR.P  p6                  ; 这些 lane 跳过本轮剩余部分
        ADD     r3, r3, r1
        JMP     loop
done:
        MREST   r24
        EXIT
