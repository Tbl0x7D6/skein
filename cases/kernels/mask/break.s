; break：MANDN.P 的谓词按 p & M 读，所以直接写 r25 也只会删当前 M 内的 lane；
; MCLR.P 再把本迭代剩余部分清掉（见 docs/design.md §6.4）。
; limit 按 lane 不同（3 - tid），所以各 lane 在不同迭代退出。
        SREAD   r7, S_TID
        LI      r1, 0               ; i
        LI      r2, 6               ; n
        LI      r3, 0               ; sum
        LI      r4, 3
        SUB     r4, r4, r7          ; limit = 3 - tid
        MSAVE   r24
        MSAVE   r25
loop:
        MREST   r25
        CMP.LT  p7, r1, r2
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, done
        ADDI    r1, r1, 1           ; i++
        CMP.EQ  p6, r1, r4          ; i == limit ?
        MANDN.P r25, r25, p6        ; 这些 lane 永久退出循环
        MCLR.P  p6                  ; 本迭代剩余部分不再执行
        ADD     r3, r3, r1
        JMP     loop
done:
        MREST   r24
        EXIT
