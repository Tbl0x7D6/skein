; vecadd：c[i] = a[i] + b[i]
; 参数：PTR_A/PTR_B/PTR_C 是设备端地址，ARG0 = n
; TID 是 block 内的全局线程号（= wid * NTID + laneid），stride = NWARP * NTID
;
; 循环的 mask 序列手写，模板见 docs/design.md §6.3：
;   r24 = 进入循环时的 mask（退出后用 r24 重聚）
;   r25 = 跨迭代的继续 mask

        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_ARG0          ; n
        SREAD   r5, S_NWARP
        SREAD   r6, S_NTID
        SREAD   r11, S_TID          ; i = wid * NTID + laneid
        MUL     r9, r5, r6          ; stride = NWARP * NTID

        MSAVE   r24                 ; 循环外的 mask
        MSAVE   r25                 ; 继续 mask
loop:
        MREST   r25                 ; M = 还在循环里的 lane
        CMP.LT  p7, r11, r4         ; 每 lane 判断 i < n
        MAND.P  r25, r25, p7        ; 不满足的 lane 退出循环
        MREST   r25
        BRZ     r25, done           ; 没有 lane 需要继续就退出

        SHLI    r12, r11, 2         ; 字节偏移 = i * 4
        ADD     r13, r12, r1
        LDG     r14, [r13]          ; a[i]
        ADD     r13, r12, r2
        LDG     r15, [r13]          ; b[i]
        ADD     r16, r14, r15
        ADD     r13, r12, r3
        STG     [r13], r16          ; c[i] = a[i] + b[i]
        ADD     r11, r11, r9

        MREST   r25                 ; 下一轮
        JMP     loop

done:
        MREST   r24                 ; 重聚：恢复进入循环时的 mask
        EXIT
