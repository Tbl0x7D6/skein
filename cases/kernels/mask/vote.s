; VOTE.ANY/ALL 的结果写所有 lane 的 GPR，直接接 BRZ/BRNZ（§5.4/§12.10）；
; 这里三种投票结果各走一次分支，覆盖 taken 和 not-taken。
        SREAD   r1, S_TID
        LI      r2, 2
        CMP.LT  p1, r1, r2      ; p1 = lane0,1
        VOTE.ANY r3, p1         ; r3 = 1（有 lane 成立）
        BRNZ    r3, L_any
        LI      r4, 20
        JMP     L_any_done
L_any:
        LI      r4, 10
L_any_done:
        VOTE.ALL r5, p1         ; r5 = 0（不是所有 lane 都成立）
        BRZ     r5, L_not_all
        LI      r6, 40
        JMP     L_all_done
L_not_all:
        LI      r6, 30
L_all_done:
        LI      r2, 4
        CMP.LT  p2, r1, r2      ; p2 = 所有 lane
        VOTE.ALL r7, p2         ; r7 = 1
        BRNZ    r7, L_all
        LI      r8, 50
        JMP     L_done
L_all:
        LI      r8, 60
L_done:
        EXIT
