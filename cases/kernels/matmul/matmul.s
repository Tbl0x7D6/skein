; 整数矩阵乘：C = A * B（行主序 int32）
;   A: ROWS x N    B: N x N    C: ROWS x N
;   N = 16；线程按 stride = BLOCK_DIM 认领 C 的行
;
; 流程：
;   1) 协作把 A、B 从 global 搬进 shared（A 从 0 开始，B 从 ROWS*N*4 开始）
;   2) BAR
;   3) 每个线程算自己认领的行：C[i][j] = sum_k A[i][k] * B[k][j]
;
; 掩码序列手写（模板见 docs/design.md §6.3）：
;   r24 = 循环外的 mask，r25 = 继续 mask
; 注意：BRZ/BRNZ 读的是 lane 0 的寄存器，所以内层循环用统一计数器、
; 外层的行循环才按 lane 收窄（行号 i = TID + m*stride 保证 lane 0 最后退出）。

        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_TID               ; 0..15
        SREAD   r5, S_BLOCK_DIM         ; stride = 整个 block 的线程数
        SREAD   r6, S_ARG0              ; ROWS
        LI      r7, 16                  ; N
        MUL     r8, r6, r7              ; A 的字数 = ROWS * N

; --- 搬 A：idx = tid, idx += stride ---
        MOV     r9, r4
        MSAVE   r24                     ; 循环外的 mask
        MSAVE   r25                     ; 继续 mask
a_load:
        MREST   r25
        CMP.LT  p7, r9, r8              ; idx < ROWS*N ?
        MAND.P  r25, r25, p7            ; 搬完的 lane 退出
        MREST   r25
        BRZ     r25, a_done
        SHLI    r10, r9, 2              ; idx * 4
        ADD     r11, r1, r10
        LDG     r12, [r11]
        STS     [r10], r12              ; shared[idx*4] = A[idx]
        ADD     r9, r9, r5
        JMP     a_load
a_done:
        MREST   r24                     ; 循环退出时 M 已被收窄到 0，先恢复
        SHLI    r13, r8, 2              ; B 的 shared 基址 = A 字数 * 4

; --- 搬 B：idx = tid, idx += stride ---
        MUL     r8, r7, r7              ; B 的字数 = N*N
        MOV     r9, r4
        MSAVE   r25
b_load:
        MREST   r25
        CMP.LT  p7, r9, r8
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, b_done
        SHLI    r10, r9, 2
        ADD     r11, r2, r10
        LDG     r12, [r11]
        ADD     r14, r13, r10
        STS     [r14], r12
        ADD     r9, r9, r5
        JMP     b_load
b_done:
        MREST   r24
        BAR                             ; shared 里的 A、B 都齐了

; --- 算 C：行 i = tid, tid+stride, ... ---
        MOV     r9, r4
        MSAVE   r25
row_loop:
        MREST   r25
        CMP.LT  p7, r9, r6              ; i < ROWS ?
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, row_done
        SHLI    r14, r9, 6              ; i * N * 4（一行的字节数）
        LI      r15, 0                  ; j * 4
        LI      r16, 16                 ; j 计数
j_loop:
        LI      r8, 0                   ; acc
        LI      r17, 0                  ; k * N * 4（B 的行偏移）
        LI      r19, 0                  ; k * 4（A 的列偏移）
        LI      r18, 16                 ; k 计数
k_loop:
        ADD     r23, r19, r14
        LDS     r20, [r23]              ; A[i][k]
        ADD     r21, r13, r17
        ADD     r21, r21, r15
        LDS     r22, [r21]              ; B[k][j]
        FMA     r8, r20, r22            ; acc += A[i][k] * B[k][j]
        ADDI    r19, r19, 4
        ADDI    r17, r17, 64
        ADDI    r18, r18, -1
        BRNZ    r18, k_loop
        ADD     r21, r14, r15
        ADD     r21, r21, r3
        STG     [r21], r8               ; C[i][j] = acc
        ADDI    r15, r15, 4
        ADDI    r16, r16, -1
        BRNZ    r16, j_loop
        ADD     r9, r9, r5              ; i += stride
        JMP     row_loop
row_done:
        MREST   r24
        EXIT
