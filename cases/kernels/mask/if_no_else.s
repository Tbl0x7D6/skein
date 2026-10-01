; 无 ELSE 的 IF：else 路径什么都不做，它的退出 mask 就是入口的 else mask，
; 所以只需要 then 的一次 MSAVE（见 docs/design.md §6.2）
        SREAD   r1, S_TID
        LI      r2, 2
        CMP.LT  p7, r1, r2          ; then = lane0,1
        MSAVE   r24                 ; 入口 mask
        MAND.P  r25, r24, p7        ; then 路径
        MANDN.P r26, r24, p7        ; else 路径（没有 body）
        MREST   r25
        LI      r3, 7               ; then body
        MSAVE   r25                 ; then 退出时的 mask
        MREST   r26
        MOR     r24, r25, r26       ; 合并
        MREST   r24
        LI      r4, 99
        EXIT
