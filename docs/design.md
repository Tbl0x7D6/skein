# 设计说明书

这份文档描述 Skein 要造的东西，以及为什么这么造。参数、接口和指令编码以本文为准；
设计变更时同步更新这里。阶段安排见 [plan.md](plan.md)，上板步骤见 [practice.md](practice.md)。

## 1. 目标与约束

| 项 | v0.1 目标 | 说明 |
|---|---|---|
| 功能 | 跑通 vecadd / reduction / sgemm 三类 kernel | 覆盖访存型与计算型 |
| 规模 | 1 核，4 warp × 4–8 lane | lane 数由综合实验定 |
| 频率 | 综合后 ≥ 200 MHz（U250，-2L） | 能收敛比频率重要 |
| 面积 | ≤ 30K LUT（不含 BRAM） | 留出后续加 cache 的余量 |
| 上板 | U250 上以 Vitis RTL kernel 形式运行 | P6 阶段 |

## 2. 顶层参数

RTL 宏集中在 [SK_config.vh](../rtl/SK_config.vh)：

```systemverilog
`define SK_XLEN        32      // 数据宽度
`define SK_NUM_LANES    4      // 每个 warp 的 lane 数（4/8，综合实验定）
`define SK_NUM_WARPS    4      // 每核 warp 数
`define SK_NUM_GPR      32     // 每 lane 通用寄存器数（r0 恒为 0）
`define SK_NUM_PRED     8      // 每 lane 谓词数
`define SK_SMEM_KB      32     // shared memory 容量
`define SK_IMEM_KB      16     // 指令存储容量
`define SK_MEM_ADDR_W   32     // global 地址宽度
```

执行 mask `M` 是硬件寄存器（N 位），通过 `MSAVE/MREST` 与通用寄存器交换；`M` 的
写入者还有 `MCLR.P`（见 §5.4）。保存的 mask 值放在 GPR 里，由 kernel 自己分配和
复用（约定用 r24–r31，见 §6.5）；不够时得自己溢出到 shared memory，策略留到写软件
阶段再说。

`sim/src/isa.rs` 里的常量与这份参数保持一致。

## 3. 结构

```
                 ┌──────────────────────── SK_top ─────────────────────────┐
   host ──AXI-Lite──► SK_ctrl (args, start/done/status, IMEM 装载口)         │
                 │                                                         │
                 │  ┌──────────────── SK_core ─────────────────┐           │
                 │  │  SK_scheduler（warp 轮询调度）             │           │
                 │  │        │                                  │           │
                 │  │  SK_fetch ──► SK_imem（BRAM）              │           │
                 │  │        │                                  │           │
                 │  │  SK_decode（统一分支在这里解析）            │           │
                 │  │        │                                  │           │
                 │  │  SK_regfile（LUTRAM，每 lane 32×32b）      │           │
                 │  │        │                                  │           │
                 │  │  SK_execute: ALU │ LSU                    │           │
                 │  │        │                                  │           │
                 │  │  SK_mask（执行 mask M + mask 指令）         │           │
                 │  │        │                                  │           │
                 │  │  SK_scoreboard（LDG 目标寄存器）           │           │
                 │  │        │                                  │           │
                 │  │  SK_commit（写回，受 M 和谓词约束）         │           │
                 │  └──────┬─────────────────┬──────────────────┘           │
                 │         │                 │                              │
                 │  SK_smem（多 bank BRAM）  SK_coalescer ──AXI4──► DDR4      │
                 └─────────────────────────────────────────────────────────┘
```

## 4. 执行模型

- **lane（thread）**：有自己的 32 个通用寄存器和 8 个谓词；没有独立 PC。
- **warp**：`SK_NUM_LANES` 个 lane 共享 PC 和执行 mask `M`；保存的 mask 值放在
  GPR 里（全 lane 同一副本，由汇编器分配）。每周期发射一条指令，所有 `M` 中的
  lane 一起执行。
- **没有统一/标量执行通路**：ALU、访存、控制流都在每条 lane 上执行。指针、循环计数、
  stride、kernel 参数这类 warp 级一致的值，在每条 lane 的寄存器里各存一份、各算一遍，
  结果自然一致。
- **控制流始终是 warp 级统一的**：所有分支都是统一分支——按 GPR 里的 mask 值的
  零/非零条件跳转，或者无条件跳转。不存在 per-lane 分支，也没有分歧栈。
- **per-lane 条件只更新 mask 和谓词**：比较结果写进每 lane 的谓词 `p`；谓词有两个
  用途：(a) 指令谓词化 `@p`；(b) 通过 mask 指令与 mask 逐 lane 组合。
- **重汇聚由代码显式完成**：`IF/ELSE` 在 merge 点恢复保存的 mask；循环在退出点恢复
  进入循环时的 mask；`break/continue` 用 mask 更新表达。这些都由汇编器生成。
- **mask 与谓词分工**：`M` 表示"哪些 lane 当前可执行"，由 mask 指令维护，硬件用它
  门控写回和访存；谓词表示"这条 lane 这个条件是否成立"，用于 `@p` 和 mask 计算。
- **block / CTA**：v0.1 一核跑一个 block；grid 由主机顺序启动，v0.1 只用 1 个 block。
- **warp 的生成与结束**：硬件按 `BLOCK_DIM`/`NWARP` 生成 warp，每条 warp 从入口
  `0x0000` 开始执行；`EXIT` 是 warp 级指令，执行到就结束整条 warp；所有 warp 结束后
  硬件置 done。
- **汇编器的职责**：只做翻译——一行一条指令，认标签，编码成 32 位字。掩码序列
  （`MSAVE`/`MREST`/`MAND.P`/`MCLR.P`）是普通指令，由 kernel 手写；写法模板见 §6，
  完整例子见 [sim/kernels/vecadd.s](../sim/kernels/vecadd.s)。

## 5. 指令集

### 5.1 设计原则

- 32 位定长指令，6 位主操作码，PC 每步 +4。定长让取指、分支偏移和译码都很简单。
- 不兼容任何现成 ISA，也不考虑高级编译器：kernel 用手写汇编写，分歧用 mask 序列
  表达；汇编器只负责编码。
- 指令可以带谓词（`@p`）：谓词为假的 lane 不写回、不访存。
- 控制流统一：没有 per-lane 分支，分支只测试 GPR 里的 mask 值（零/非零）或无条件跳转。
- 指令集不提供 warp 级归约指令；需要归约时用 shared memory + `BAR` 自己搭。

### 5.2 寄存器与掩码

| 类别 | 数量 | 说明 |
|---|---|---|
| `r0–r31` | 每 lane 32×32b | 通用寄存器，`r0` 恒为 0 |
| `p0–p7` | 每 lane 8×1b | 谓词，由比较指令写；用于 `@p` 谓词化和 mask 计算 |
| `M` | 每 warp 1 个 N 位 | 执行 mask（唯一的硬件 mask 状态），门控写回和访存 |
| 保存的 mask | 放在 GPR 里 | 由汇编器分配；全 lane 保存同一份副本（warp 一致） |
| 特殊寄存器 | 只读 | `TID/LANEID` 每 lane 不同；`WID/NTID/NWARP/GRID/PTR0–2/ARG0–2/STATUS` 每条 lane 读出的值相同 |

特殊寄存器用 `SREAD rd, sreg` 读入通用寄存器。

### 5.3 编码格式

P0 冻结。位序从低位写起，立即数和分支/跳转偏移都以**指令字**为单位：

| 格式 | 位分配 | 用途 |
|---|---|---|
| R | `op[5:0] rd[10:6] ra[15:11] rb[20:16] pred[24:21] func[31:25]` | ALU / `CMP` / `SEL` / mask |
| RI | `op[5:0] rd[10:6] ra[15:11] pred[19:16] imm[31:20]` | 立即数 ALU / 访存 / `LUI` / `LUM` |
| BR | `op[5:0] rs[10:6] off[31:11]`（21 位有符号） | `BRZ` / `BRNZ` |
| J | `op[5:0] off[31:6]`（26 位有符号） | `JMP` |
| SR | `op[5:0] rd[10:6] sreg[15:11]` | `SREAD` |
| SYS | `op[5:0] func[31:25]` | `NOP` / `BAR` / `EXIT` |

- `pred` 字段：0 = 无谓词，1..8 = `@p0..@p7`，9..15 保留。谓词取反用相反的比较
  条件表达（`GE` 代替 `LT`、`NE` 代替 `EQ`），不占单独的取反位。
- 跳转目标 = `PC + 4 + off × 4`，即相对下一条指令；`BR` 范围 ±2²⁰ 条指令，
  `JMP` 范围 ±2²⁵ 条。分支的操作数必须全 lane 相同，由汇编器保证。
- mask 指令的 `.P` 形式把谓词号放在 `rb` 字段（0..7）。
- `SEL` 的 `pred` 字段是**操作数**（按哪个谓词选值），不是 `@p` 门控；`SEL`
  本身仍受 `M` 门控。

主操作码：

| op | 指令 | op | 指令 | op | 指令 |
|---|---|---|---|---|---|
| `01` | `ADD…MUL` 等 R 格式 ALU | `08` | `SLTI` | `0F` | `BRZ` |
| `02` | `CMP.cond` | `09` | `LDS` | `10` | `BRNZ` |
| `03` | `SEL` | `0A` | `STS` | `11` | `JMP` |
| `04` | `ADDI` | `0B` | `LDG` | `12` | `SREAD` |
| `05` | `ANDI` | `0C` | `STG` | `13` | `SYS`（`NOP/BAR/EXIT`） |
| `06` | `ORI` | `0D` | `LUI` | `14` | `LUM` |
| `07` | `SHLI` | `0E` | mask 指令（`func` 选） | 其余 | 保留 |

`func` 字段（保留值不使用）：

| 组 | func |
|---|---|
| ALU（`op=01`） | `ADD=0 SUB=1 AND=2 OR=3 XOR=4 SHL=5 SHR=6 SAR=7 SLT=8 SLTU=9 MUL=A MOV=B` |
| 比较（`op=02`） | `EQ=0 NE=1 LT=2 GE=3 LTU=4 GEU=5` |
| mask（`op=0E`） | `MSAVE=0 MREST=1 MMOV=2 MAND=3 MANDN=4 MOR=5 MNOT=6 MAND.P=7 MANDN.P=8 MOR.P=9 MCLR.P=A` |
| 系统（`op=13`） | `NOP=0 BAR=1 EXIT=2` |

### 5.4 指令表

ALU（全部 per-lane、可带 `@p`）：

| 指令 | 语义 |
|---|---|
| `ADD/SUB/AND/OR/XOR/SHL/SHR/SAR/SLT/SLTU/MUL` | 每 lane 算术/逻辑/移位/比较，结果写自己的目标寄存器 |
| `MOV rd, ra` | 每 lane 搬移 |
| `ADDI/ANDI/ORI/SHLI/SLTI rd, ra, imm` | 12 位立即数 ALU（`imm` 有符号或零扩展按指令定） |
| `LUI rd, imm12` / `LUM rd, ra, imm12` / `ORI` | 常数分段装载：`imm<<20` / `ra \| imm<<12` / `ra \| imm` |
| `LI rd, imm` | 伪指令：1–3 条 `ADDI/LUI/LUM/ORI` 拼出任意 32 位常数 |
| `CMP.cond p, ra, rb` | 每 lane 比较，写自己的谓词（EQ/NE/LT/GE/LTU/GEU） |
| `SEL rd, ra, rb, p` | 每 lane 按 `p` 选值（`p` 是操作数），用于短小的条件更新 |

`LI` 用顺序无关的三段拼装：`LUI` 放 bits31:20，`LUM` 放 bits23:12，`ORI` 放
bits11:0；三段都带 `pred`，所以在收窄的 mask 里也能安全装载常数。

访存（per-lane、可带 `@p`，v0.1 只支持 32 位字）：

| 指令 | 空间 | 语义 |
|---|---|---|
| `LDS rd, [ra + imm]` / `STS [ra + imm], rs` | shared | 片上 shared memory |
| `LDG rd, [ra + imm]` / `STG [ra + imm], rs` | global | 片外全局内存（AXI4） |

mask 指令（warp 级，不受 `M` 门控）：

| 指令 | 语义 |
|---|---|
| `MSAVE rd` | `rd = M`（每个 lane 写入同一份副本） |
| `MREST rs` | `M = rs`（`rs` 必须是全 lane 一致的 mask 值） |
| `MMOV rd, ra` | `rd = ra` |
| `MAND rd, ra, rb` | `rd = ra & rb` |
| `MANDN rd, ra, rb` | `rd = ra & ~rb` |
| `MOR rd, ra, rb` | `rd = ra \| rb` |
| `MNOT rd, ra` | `rd = ~ra` |
| `MAND.P rd, ra, p` | `rd = ra & p & M`（硬件强制与当前 `M` 相干） |
| `MANDN.P rd, ra, p` | `rd = ra & ~p & M` |
| `MOR.P rd, ra, p` | `rd = (ra \| p) & M` |
| `MCLR.P p` | `M = M & ~p`（break/continue 序列用，见 §6.4） |

mask 指令是 warp 级操作：不受 `M` 门控，除 `MREST` 外不改变 `M`。`.P` 形式的
结果由硬件强制与 `M` 相干，inactive lane 的旧谓词不会把 lane 复活。
`M` 的写入者只有 `MREST` 和 `MCLR.P`。

控制：

| 指令 | 语义 |
|---|---|
| `BRZ rs, target` | 统一分支：`rs`（全 lane 一致的 mask 值）全零时跳转 |
| `BRNZ rs, target` | 统一分支：`rs` 非零时跳转；v0.1 只做零/非零两种条件 |
| `JMP target` | 无条件跳转 |
| `BAR` | 块内屏障；要求 `M` 等于 warp 生成时的完整 mask，否则报错 |
| `EXIT` | warp 级结束指令，执行到就结束整条 warp |
| `NOP` | 空操作 |

特殊：

| 指令 | 语义 |
|---|---|
| `SREAD rd, sreg` | 读特殊寄存器到每 lane 的通用寄存器 |

刻意没有的指令：per-lane 分支、分支重聚点字段、重聚栈、warp 级归约指令；
`M` 只能通过 `MREST` 修改。

### 5.5 地址空间与对齐

| 空间 | 指令 | 地址 | 实现 |
|---|---|---|---|
| shared memory | `LDS/STS` | 16 位字节地址（默认 32 KB，上限 64 KB） | 片上 BRAM，多 bank |
| global memory | `LDG/STG` | 32 位字节地址 | AXI4 → U250 DDR4 |
| 指令存储 | 取指 | 16 位 PC，入口 `0x0000` | 独立 IMEM（BRAM），主机预装载 |
| kernel 参数 | `SREAD` | — | AXI-Lite 控制寄存器映射到特殊寄存器 |

shared 和 global 不统一编址：指令本身决定访问哪个空间。访存必须自然对齐；
非对齐、越界和访问错误码都写进 `STATUS`，然后报错并结束 kernel。

`STATUS` 取值（P0 冻结，非 0 表示 kernel 已经报错结束）：

| 值 | 名字 | 含义 |
|---|---|---|
| 0 | `OK` | 正常结束 |
| 1 | `BAD_INSN` | 保留编码、非法 `func`、非法特殊寄存器 |
| 2 | `UNALIGNED` | 访存地址不是 4 字节对齐 |
| 3 | `SMEM_OOB` | shared 地址越界 |
| 4 | `GMEM_OOB` | global 地址越界 |
| 5 | `BAR_INCOMPLETE` | `BAR` 时 `M` 不是完整 mask |
| 6 | `PC_OOB` | 取指超出 IMEM |

### 5.6 Kernel 调用约定

主机通过 AXI-Lite 写这些寄存器，然后置 `ap_start`：

| 偏移 | 名称 | 含义 |
|---|---|---|
| `0x00` | `CTRL` | bit0=start，bit1=done(只读)，bit2=idle(只读)，bit3=error(只读) |
| `0x08` | `GRID_DIM` | block 数（v0.1 固定 1） |
| `0x10` | `BLOCK_DIM` | 每 block 线程数（≤ `SK_NUM_LANES × SK_NUM_WARPS`） |
| `0x18/0x20/0x28` | `PTR_A/B/C` | 设备端 global 地址 |
| `0x30/0x38/0x40` | `ARG0/1/2` | 标量参数（如 `n`） |
| `0x48/0x50/0x58` | `IMEM_ADDR/WDATA/WE` | 指令镜像装载口 |

启动顺序：主机写 IMEM 镜像 → 写参数 → 置 start → 轮询 done/error。入口固定 `0x0000`。

### 5.7 汇编示例：vecadd

`S_TID` 是 block 内的全局线程号（`wid * NTID + laneid`），`S_LANEID` 是 lane 在
warp 内的编号。handwritten 部分：

```asm
        ; PTR_A/B/C、ARG0、NTID/NWARP/WID 每条 lane 读出的值相同；TID 每条 lane 不同
        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_ARG0          ; n
        SREAD   r5, S_NWARP
        SREAD   r6, S_NTID
        SREAD   r11, S_TID          ; i = wid * NTID + laneid
        MUL     r9, r5, r6          ; stride = NWARP * NTID（每条 lane 冗余计算）
```

循环在源码里就是这段手写的 mask 序列（`sim/kernels/vecadd.s` 的内容，`r24` 是循环外的
mask、`r25` 是继续 mask）：

```asm
        MSAVE   r24                 ; 进入循环时的 mask，退出后用它重聚
        MSAVE   r25                 ; 跨迭代的继续 mask
loop:
        MREST   r25                 ; M = 仍在循环里的 lane
        CMP.LT  p7, r11, r4         ; 每 lane 自己判断
        MAND.P  r25, r25, p7        ; 条件不成立的 lane 退出循环
        MREST   r25
        BRZ     r25, done           ; 统一分支：没有 lane 需要继续就退出
        SHLI    r12, r11, 2         ; 字节偏移 = i * 4
        ADD     r13, r12, r1
        LDG     r14, [r13]          ; a[i]
        ADD     r13, r12, r2
        LDG     r15, [r13]          ; b[i]
        ADD     r16, r14, r15
        ADD     r13, r12, r3
        STG     [r13], r16          ; c[i] = a[i] + b[i]
        ADD     r11, r11, r9        ; i += stride
        MREST   r25                 ; 下一轮
        JMP     loop

done:
        MREST   r24                 ; 重聚：恢复进入循环时的 mask
        EXIT
```

## 6. 控制流：手写 mask 序列

### 6.1 模型

- 硬件只有执行 mask `M` 和 per-lane 谓词 `p0..p7`；保存的 mask 值放在 GPR 里，
  kernel 自己挑寄存器（约定 `r24–r31`）。
- 所有控制流都是统一的：`BRZ/BRNZ` 测试 GPR 里的 warp 一致 mask 值，
  `JMP` 无条件跳转；v0.1 的分支条件只有零/非零两种。
- per-lane 条件先写谓词，再由 mask 指令组合进 mask；mask 变窄意味着"这些 lane
  暂时不参与"，mask 恢复意味着重聚。
- `.P` 类 mask 指令的结果由硬件强制与当前 `M` 相干（`rd = ... & M`），防止
  inactive lane 的旧谓词把 lane 复活。
- 汇编器不认识结构化语法：`IF/LOOP/break/continue` 只是写 kernel 时的思路，落到源码
  里就是 mask 指令加统一分支。下面几节给的是手写模板，抄就行。

### 6.2 IF/ELSE 模板

```asm
        ; IF cond ... ELSE ... ENDIF（r24 = 入口 mask，r25 = then，r26 = else）
        CMP.cond  p, ra, rb        ; 在当前 M 下算谓词
        MSAVE     r24              ; 入口 mask
        MAND.P    r25, r24, p      ; then 路径的 lane（此刻 M 仍等于 r24）
        MANDN.P   r26, r24, p      ; else 路径的 lane
        MREST     r25              ; M = then 路径
        <then body>
        MSAVE     r25              ; then 路径退出时的 mask（可能被 break/continue 收窄）
        MREST     r26
        <else body>
        MSAVE     r26
        MOR       r24, r25, r26    ; 合并两条路径的 lane
        MREST     r24              ; 重汇聚
```

三个要点：

- 两条分支 mask 必须在 `MREST` 之前算出来。`.P` 形式带着 `& M`，一旦先切到 `r25`，
  `MANDN.P r26, r24, p` 就会被 `& r25` 清成空集。
- merge 用 `MOR` 合并两条路径的**退出 mask**，不是直接 `MREST r24`。这样路径里的
  `break/continue` 收窄的 lane 不会在 merge 点被复活。
- 没有 `ELSE` 时 else 路径什么都没做，它的退出 mask 就是 `r26` 本身，省一条 `MSAVE`。

### 6.3 循环模板

```asm
        ; LOOP ... ENDLOOP（条件在头部检查；r24 = 循环外的 mask，r25 = 继续 mask）
        MSAVE     r24                 ; 进入循环时的 mask，退出后用它重聚
        MSAVE     r25                 ; 循环继续 mask
L_head:
        MREST     r25                 ; M = 仍在循环里的 lane
        CMP.cond  p, ra, rb
        MAND.P    r25, r25, p         ; 收窄：条件不成立的 lane 退出循环
        MREST     r25                 ; M = 收窄后的 mask
        BRZ       r25, L_done         ; 统一分支：没有 lane 继续就退出
        <body>
L_latch:
        MREST     r25                 ; 恢复 continue 的 lane
        JMP       L_head
L_done:
        MREST     r24                 ; 重聚：恢复进入循环时的 mask
```

循环是 while 语义：`continue` 跳过本轮剩余部分（包括写在 body 末尾的自增），
下一轮从头部条件重新开始。头部收窄 `r25` 是永久性的——这些 lane 已经算出
"不必再迭代"，只有 `L_done` 的 `MREST r24` 才把它们放回来。

### 6.4 break/continue 序列

`break`（`q` 是 break 条件谓词，`r5` 是临时 mask 寄存器）：

```asm
        CMP.cond  q, ra, rb
        MSAVE     r5                  ; 当前活跃 lane（r5 是临时数据寄存器，别和 kernel 的撞）
        MAND.P    r5, r5, q           ; 其中满足 break 条件的
        MANDN     r25, r25, r5        ; 这些 lane 永久退出循环
        MCLR.P    q                   ; 本迭代剩余部分不再执行
```

不能直接写 `MANDN.P r25, r25, q`：`.P` 形式会 `& M`，而 `M` 往往比 `r25` 窄（比如
break 写在 `IF` 的 then 路径里），那样会把 else 路径的 lane 也从循环里删掉。所以先用
`MSAVE`+`MAND.P` 组合出"正在退出"的 lane 集合，再用不带 `.P` 的 `MANDN` 减掉。

`continue`（`q` 是 continue 条件谓词）：

```asm
        CMP.cond  q, ra, rb
        MCLR.P    q                   ; 本迭代剩余部分不再执行，但仍留在 r25 里
```

continue 的 lane 在 `L_latch` 的 `MREST r25` 回归，下一轮照常从头部开始；
break 的 lane 已经不在 `r25` 里，直到 `L_done` 的 `MREST r24` 才回归。
`break/continue` 写在 `IF/ELSE` 里面时，收窄会穿过 §6.2 的 `MSAVE`+`MOR` merge，
所以 merge 之后只有"还该继续执行"的 lane 留在 `M` 里。

无条件写法：`BREAK` 用 `MMOV r25, r0` + `MREST r0`，`CONTINUE` 用 `MREST r0`。

### 6.5 重聚与限制

- 重聚是显式的：每个结构化区域在 merge 点用 `MREST` 恢复 mask。没有重聚栈，
  也没有栈深限制；硬件不知道也不关心嵌套层级。
- 保存 mask 的 GPR 约定用 `r24–r31`（8 个），kernel 自己分配和复用；数据寄存器用
  `r1–r23`，别撞上。模板里的临时谓词用 `p6`/`p7`，把低编号谓词留给数据。
- 嵌套深度受这 8 个掩码寄存器限制，不够就把 mask 值溢出到 shared memory（还没做，
  见 §11）。
- `BAR` 要求 `M` 等于 warp 生成时的完整 mask，由**硬件在运行时**检查，不满足就报
  `BAR_INCOMPLETE`。汇编器不做这个静态检查。
- `EXIT` 是 warp 级指令，执行到就结束整条 warp；不要求 `M` 是完整 mask。
- mask 指令是 warp 级操作，不受 `M` 门控；普通 ALU/访存同时受 `M` 和 `@p` 门控。
- 不要随便跳进/跳出 mask 区域：标签在映像里就是地址，跳错了没有编译错误，只有跑飞。

## 7. 流水线

v0.1 采用 5 级流水线；lane 数取 8 时可以在 S3/S4 之间加一级操作数读，变成 6 级：

| 级 | 职责 |
|---|---|
| S1 Schedule | 轮询选 warp、发出 PC |
| S2 Fetch | 从 IMEM 取指 |
| S3 Decode | 译码、读寄存器和谓词；统一分支在这里解析（GPR 里的 mask 值已知） |
| S4 Execute | ALU / LSU / mask 指令；LDG 发出后由 scoreboard 跟踪 |
| S5 Commit | 受 `M` 和谓词门控写回；分支重定向、清年轻指令 |

不预测分支：统一分支在 S3 解析，命中则重定向并清掉年轻指令；解析前该 warp 停止
发射，其他 warp 继续。每个 warp 一个 scoreboard（4–8 个 slot）跟踪 `LDG` 的目标
寄存器；`STG` 是 posted write，用 outstanding 计数在内核结束前排空。

## 8. 存储层次

| 存储 | 实现 | 说明 |
|---|---|---|
| 通用寄存器堆 | 每 lane 32×32b LUTRAM（2 读 1 写） | 不用 BRAM；8 lane × 4 warp 约 32 Kb |
| mask 单元 | `M`（N 位 FF）+ mask 指令 | 保存的 mask 值占 GPR；`M` 是唯一的硬件 mask 状态 |
| IMEM | BRAM，16 KB | 主机通过 AXI-Lite 装载，取指只从这里 |
| shared memory | BRAM，多 bank，默认 32 KB | `LDS/STS`；bank 数 ≥ lane 数，冲突 replay |
| global memory | AXI4 master（先 64-bit）→ DDR4 | `LDG/STG`；coalescer 合并同一 cache line |

访存合并是性能的第一来源（P5 做）：同一 warp 内多条 active lane 的地址落在同一
cache line 时合并成一次总线事务。v0.1 的 kernel 先用小工作集，性能差是预期行为。

## 9. 主机接口（P6）

GPU 顶层做成标准 Vitis RTL kernel：

- `s_axi_control`（AXI-Lite）：参数、start/done/error，以及 IMEM 装载口。
- `m_axi_gmem`（AXI4）：global memory 访存。
- 可选 `m_axi_host`：命令环 / 主机内存，v0.1 不需要。

所有 AXI 通道严格遵守 AXI4 握手（`valid` 不能因为 `ready` 撤销）。打包和上板步骤见
[practice.md](practice.md) §2。

## 10. 时钟与复位

- 单时钟域 `aclk`；同步复位、低有效（`aresetn`）。
- 上板时平台提供 `aclk_kernel_00`（U250 默认 300 MHz，先降到 200 MHz 跑通）。
- 所有跨模块信号必须寄存，规则见 [practice.md](practice.md) §1。

## 11. 开放问题

- `IF/ELSE` 和简单分支是否用 if-conversion（`SEL`/`@p`）替代 mask 序列，阈值和
  默认策略等写汇编器优化时再定。
- 要不要把 `IF/ELSE/ENDIF`、`LOOP` 这类结构化语法和 mask 寄存器分配做进汇编器——
  现在只做翻译、掩码序列手写；写起来太啰嗦再说。
- 汇编器静态检查（跨区域跳转、`BAR` 的 mask、掩码寄存器压力）——同上，先不加，
  靠代码审查和硬件运行时兜底。
- 掩码寄存器组只有 8 个：更深的嵌套要不要溢出到 shared、怎么溢出（软件阶段再定）。
- 是否需要 mask 零/非零之外的统一分支条件（v0.1 先不做，需要时再加指令）。
- `SK_NUM_LANES` 取 4 还是 8（综合实验定）。
- IMEM 16 KB、shared 32 KB 是否够用；shared bank 数取 lane 数还是 2×lane 数。
- scoreboard 需要多少个 outstanding slot。
- sgemm 是否需要 `MUL` 之外的整数除法，还是用移位/循环代替。
- 字节/半字访存什么时候加（v0.1 只做 32 位字）。
- 是否在 P5 加一个小 L1 或只做 coalescer。

## 12. 关键决策

### 12.1 自定义 32 位定长 ISA，不用 RISC-V

指令集完全自己设计，不背 RISC-V 兼容包袱，也不考虑高级编译器：kernel 手写汇编，
工具链只有汇编器和黄金模型。好处是编码、译码、汇编全部在掌控之中，
教学覆盖面完整；代价是没有现成工具链，汇编器和黄金模型必须在 P0 先写好。

### 12.2 去掉统一/标量通路

所有指令都在每条 lane 上执行，统一值靠冗余计算。好处是只有一条执行通路，
流水线和验证都简单；代价是地址计算、循环计数这类工作被重复执行 N 遍，
面积和功耗上有浪费。

### 12.3 控制流统一 + 汇编器管理 mask

分支只做 warp 级统一判断，v0.1 只有 mask 零/非零两种条件加无条件跳转；per-lane
条件只写谓词、只更新 mask。保存的 mask 值放在 GPR 里（全 lane 同一副本，由汇编器
分配和复用）；硬件只有执行 mask `M`，`.P` 类 mask 指令的结果由硬件强制与 `M` 相干
（`rd = ... & M`）。重汇聚由汇编器在 merge 点显式 `MREST`，循环用 mask 收窄 +
"已退出 lane"掩码处理 `break/continue`；`break/continue` 的支持范围由汇编器/语言
决定，硬件不限制。`BAR` 要求完整 mask。

**好处**：硬件非常简单——没有重聚栈、没有重聚比较器、没有栈深限制、分支在译码级
就能解析；分歧的正确性主要落在生成出来的 mask 序列上，硬件可以做成一组很简单的
位运算。mask 值用 GPR 保存，不需要专用 mask 寄存器堆。

**代价**：mask 序列要手写——每个 `IF/ELSE` 大约几条 mask 指令、循环每轮几条，寄存器
压力也落在写 kernel 的人身上（`r24–r31` 八个掩码寄存器，不够就溢出到 shared，留到
软件阶段处理）；验证负担从硬件转移到"手写的 mask 序列"上，所以 §6 的模板和
`sim/kernels/` 里的例子就是规范，测试也跟着测这些序列。

具体做法（P0）：汇编器只做编码（`sim/src/asm.rs`，一行一条指令）；掩码序列按 §6 的
模板手写。`IF` 的 merge 用两条路径退出 mask 的 `MOR`，这样路径里的 break/continue
收窄不会被 merge 撤销。`.P` 形式的 `& M` 是坑：从比 `M` 宽的外层 mask 里删 lane 必须
绕开 `.P`（见 §6.4）。

### 12.4 两个地址空间、独立 load/store

shared memory（`LDS/STS`，16 位地址，片上 BRAM 多 bank）和 global memory
（`LDG/STG`，32 位地址，AXI4）各自独立编址，指令本身区分空间。好处是访存路径
清晰、不依赖地址译码；代价是两套访存指令和两套地址计算。

### 12.5 寄存器堆用 LUTRAM，不用 BRAM

寄存器堆需要每 lane 2 读 1 写、组合读，BRAM 的端口数、延迟和粒度都不合适；
LUTRAM/FF 阵列更匹配，也更容易随 lane 数扩展。BRAM 留给 shared memory、IMEM
和以后的 cache。

### 12.6 起始配置 1 核 4 warp × 4–8 lane

warp 宽度直接决定寄存器堆、操作数网络、ALU 和 shared bank 的规模；先用 4 lane
跑通，再用综合实验决定是否上 8 lane。面积预算 30K LUT，先用实际数据说话。

### 12.7 内存层次分步走

v0.1–P4 只用 shared memory + 简单 AXI；P5 再做 coalescer、多 bank 和可选 cache。
访存合并的收益远大于 cache，实现和验证却简单得多；早期性能差是预期行为。

### 12.8 上板走 Vitis RTL kernel + XRT

Vitis RTL kernel + XRT 是 Xilinx 官方支持的上板路线，平台、shell 和驱动都有正式
发布包，不需要自己维护平台。代价是 GPU 顶层必须符合 AXI-Lite 控制 + AXI4 主 +
`ap_ctrl` 的约定（见 §9）。
