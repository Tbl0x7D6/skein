; 出错：global 地址越界（1 MB 容量的上界就是 0x100000）
        LI      r1, 0x100000
        LDG     r2, [r1]
        EXIT
