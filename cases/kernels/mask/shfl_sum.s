; warp 内归约：SHFL.BFLY 两轮求和，4 lane 的 laneid 之和 = 0+1+2+3 = 6
        SREAD     r1, S_LANEID
        LI        r2, 1
        SHFL.BFLY r3, r1, r2
        ADD       r1, r1, r3
        LI        r2, 2
        SHFL.BFLY r3, r1, r2
        ADD       r1, r1, r3
        EXIT
