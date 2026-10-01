; 按 lane 发散的 IF/ELSE，手写 mask 序列（模板见 docs/design.md §6.2）
        SREAD   r1, S_TID
        LI      r2, 2
        CMP.LT  p7, r1, r2          ; p7 = lane0,1
        MSAVE   r24                 ; 入口 mask
        MAND.P  r25, r24, p7        ; then 路径的 lane
        MANDN.P r26, r24, p7        ; else 路径的 lane
        MREST   r25
        LI      r3, 10              ; then body
        MSAVE   r25                 ; then 退出时的 mask
        MREST   r26
        LI      r3, 20              ; else body
        MSAVE   r26
        MOR     r24, r25, r26       ; 合并两条路径
        MREST   r24                 ; 重汇聚
        LI      r4, 99
        EXIT
