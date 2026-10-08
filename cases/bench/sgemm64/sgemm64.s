; int32 矩阵乘：C = A * B（64×64，行主序）
;   A、B 先协作搬进 shared：A 转置成 A_T[k][i]（内层 LDS 的 lane 间连续 -> 无 bank 冲突），
;   B 原样放。每个线程算 4 行：i = tid + 16*m（m = 0..3）。
;   shared 布局（字）：A_T 在 [0, 4096)，B 在 [4096, 8192)，正好 32 KB。
;   参数：PTR_A / PTR_B / PTR_C；N = 64。
;
; mask 序列手写（模板见 docs/design.md §6.3）：r24 = 循环外的 mask，r25 = 继续 mask

        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_TID               ; 0..15
        SREAD   r5, S_BLOCK_DIM         ; stride = 16
        LI      r6, 4096                ; N*N

; --- 搬 A 并转置：idx = i*64 + k -> A_T[k*64 + i] ---
        MOV     r9, r4
        MSAVE   r24
        MSAVE   r25
a_load:
        MREST   r25
        CMP.LT  p7, r9, r6
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, a_done
        SHLI    r10, r9, 2
        ADD     r11, r1, r10
        LDG     r12, [r11]              ; A[idx]（lane 间连续 -> 合并）
        LI      r16, 6
        SHR     r13, r9, r16            ; i = idx / 64
        ANDI    r14, r9, 63             ; k = idx % 64
        SHLI    r15, r14, 6             ; k * 64
        ADD     r15, r15, r13
        SHLI    r15, r15, 2
        STS     [r15], r12              ; A_T[k][i] = A[i][k]
        ADD     r9, r9, r5
        JMP     a_load
a_done:
        MREST   r24

; --- 搬 B：idx -> B[idx]，shared 基址 16384 字节 ---
        MOV     r9, r4
        MSAVE   r25
b_load:
        MREST   r25
        CMP.LT  p7, r9, r6
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, b_done
        SHLI    r10, r9, 2
        ADD     r11, r2, r10
        LDG     r12, [r11]
        LI      r16, 16384
        ADD     r17, r16, r10
        STS     [r17], r12
        ADD     r9, r9, r5
        JMP     b_load
b_done:
        MREST   r24
        BAR

; --- 算 C：i = tid + 16*m，每行 64 列 ---
        LI      r6, 64
        MOV     r9, r4
        LI      r20, 4                  ; 每个线程 4 行
        MSAVE   r25
row_loop:
        MREST   r25
        CMP.LT  p7, r9, r6
        MAND.P  r25, r25, p7
        MREST   r25
        BRZ     r25, row_done
        SHLI    r13, r9, 2              ; i * 4
        LI      r14, 0                  ; j * 4
        LI      r15, 64                 ; j 计数
j_loop:
        LI      r8, 0                   ; acc
        LI      r18, 0                  ; k * 256
        LI      r17, 64                 ; k 计数
k_loop:
        ADD     r21, r18, r13           ; A_T 字节地址 = k*256 + i*4
        LDS     r22, [r21]              ; A_T[k][i]
        LI      r19, 16384
        ADD     r23, r18, r14           ; k*256 + j*4
        ADD     r23, r23, r19
        LDS     r26, [r23]              ; B[k][j]（全 lane 同地址 -> 广播）
        FMA     r8, r22, r26
        ADDI    r18, r18, 256
        ADDI    r17, r17, -1
        BRNZ    r17, k_loop
        SHLI    r21, r9, 8              ; i * 256
        ADD     r21, r21, r14
        ADD     r21, r21, r3
        STG     [r21], r8               ; C[i][j]
        ADDI    r14, r14, 4
        ADDI    r15, r15, -1
        BRNZ    r15, j_loop
        ADD     r9, r9, r5
        ADDI    r20, r20, -1
        BRNZ    r20, row_loop
row_done:
        MREST   r24
        EXIT
