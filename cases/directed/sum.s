; P1：sum = 0 + 1 + ... + 9 = 45
; 循环用 docs/design.md §6.3 的 mask 模板：r24 = 循环外的 mask，r25 = 继续 mask

        LI      r1, 0                   ; i
        LI      r2, 0                   ; sum
        LI      r3, 10

        MSAVE   r24                     ; 进入循环时的 mask，退出后用它重聚
        MSAVE   r25                     ; 跨迭代的继续 mask

loop:
        MREST   r25                     ; M = 还在循环里的 lane
        CMP.LT  p7, r1, r3              ; 每 lane 判断 i < 10
        MAND.P  r25, r25, p7            ; 不满足的 lane 退出循环
        MREST   r25
        BRZ     r25, done               ; 统一分支：没有 lane 需要继续就退出

        ADD     r2, r2, r1              ; sum += i
        ADDI    r1, r1, 1               ; i++

        MREST   r25                     ; 下一轮
        JMP     loop

done:
        MREST   r24                     ; 重聚：恢复进入循环时的 mask
        EXIT
