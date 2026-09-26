; 错误码：非对齐访问。地址全 lane 一致，所以 4 条 lane 都在同一条指令上出错，
; 两种实现（黄金模型整条指令零副作用 / RTL 遇错即停）的结果一样。
; 错误路径只比 STATUS 和 PC（见 docs/plan.md 的验证方法）。

        SREAD   r1, S_PTR_A             ; --set PTR_A=0x1000
        LDG     r2, [r1+2]              ; 非对齐 -> STATUS = UNALIGNED
        EXIT
