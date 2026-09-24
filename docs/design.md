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

RTL 宏集中在一个 `SK_config.vh`：

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

执行 mask `M` 是硬件寄存器（N 位），通过 `MSAVE/MREST` 与通用寄存器交换。保存的
mask 值放在 GPR 里，由汇编器分配和复用；GPR 不够时汇编器给出警告并溢出到 shared
memory（具体策略留到写软件/汇编器时实现）。

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
- **汇编器的职责**：把结构化控制流（`IF/ELSE/ENDIF`、`LOOP`、`break/continue`）
  lowering 成 mask 指令序列，做保存 mask 的 GPR 分配和静态检查。这是 P0 的核心交付物，
  也是这套方案里最"像编译器"的部分。

## 5. 指令集

### 5.1 设计原则

- 32 位定长指令，6 位主操作码，PC 每步 +4。定长让取指、分支偏移和译码都很简单。
- 不兼容任何现成 ISA，也不考虑高级编译器：kernel 用手写汇编写，汇编器负责结构化
  控制流 lowering、mask 分配和编码。
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

具体位分配在 P0 冻结；下面是格式框架，立即数和分支偏移都以指令字为单位、PC 相对。

| 格式 | 布局 | 用途 |
|---|---|---|
| R | `op(6) rd(5) ra(5) rb(5) pred(4) func(7)` | 寄存器-寄存器 ALU / 比较 / 选择 |
| RI | `op(6) rd(5) ra(5) pred(4) imm(12)` | ALU + 12 位立即数 |
| M | `op(6) rd(5) ra(5) pred(4) imm(12)` | `LDS/STS/LDG/STG` |
| K | `op(6) rd(5) ra(5) rb(5) pred(4) func(7)` | mask 指令（GPR 操作数，warp 级） |
| B | `op(6) rs(5) off(21)` | 统一条件分支（`BR.Z/BR.NZ`，测试 GPR 里的 warp 一致 mask） |
| J | `op(6) off(22)` | 无条件跳转 |
| SR | `op(6) rd(5) pred(4) sreg(5) …` | `SREAD` |
| S | `op(6) …` | `EXIT` / `BAR` / `NOP` |

`pred` 是 4 位谓词字段：3 位谓词号 + 1 位取反，0 表示无条件执行。
分支的 mask 操作数必须全 lane 相同，由汇编器保证。

### 5.4 指令表

ALU（全部 per-lane、可带 `@p`）：

| 指令 | 语义 |
|---|---|
| `ADD/SUB/AND/OR/XOR/SHL/SHR/SAR/SLT/SLTU/MUL` | 每 lane 算术/逻辑/移位/比较，结果写自己的目标寄存器 |
| `MOV rd, ra` / `LI rd, imm` / `LUI rd, imm` | 搬移和常数装载（拼接出 32 位常数） |
| `CMP.cond p, ra, rb` | 每 lane 比较，写自己的谓词（EQ/NE/LT/GE/LTU/GEU） |
| `SEL rd, ra, rb, p` | 每 lane 按谓词选值，用于短小的条件更新 |

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

mask 指令是 warp 级操作：不受 `M` 门控，除 `MREST` 外不改变 `M`。`.P` 形式的
结果由硬件强制与 `M` 相干，inactive lane 的旧谓词不会把 lane 复活。

控制：

| 指令 | 语义 |
|---|---|
| `BR.Z rs, target` | 统一分支：`rs`（全 lane 一致的 mask 值）全零时跳转 |
| `BR.NZ rs, target` | 统一分支：`rs` 非零时跳转；v0.1 只做零/非零两种条件 |
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

### 5.7 汇编示例：vecadd（汇编器 lowering 之后的样子）

```asm
        ; 特殊寄存器：PTR_A/B/C、N、NTID/NWARP/WID 所有 lane 相同；TID 每 lane 不同
        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_N
        SREAD   r5, S_NTID
        SREAD   r6, S_NWARP
        SREAD   r7, S_WID
        SREAD   r8, S_TID
        MUL     r9, r6, r5          ; T = NWARP * NTID（每条 lane 冗余计算）
        MUL     r10, r7, r5         ; wid * NTID
        ADD     r11, r8, r10        ; i = tid + wid*NTID
        MSAVE   m_outer             ; 进入循环前的 mask
        MSAVE   m_loop              ; 循环继续 mask
loop:
        MREST   m_loop              ; M = 仍在循环里的 lane
        CMP.LT  p1, r11, r4         ; p1 = (i < n)，每 lane 自己判断
        MAND.P  m_loop, m_loop, p1  ; 只保留还需要迭代的 lane
        MREST   m_loop              ; M = 收窄后的 mask
        BR.Z    m_loop, done        ; 统一分支：没有 lane 需要继续就退出
        SHL     r12, r11, 2         ; 字节偏移 = i * 4
        ADD     r13, r12, r1
        LDG     r14, [r13]          ; a[i]
        ADD     r13, r12, r2
        LDG     r15, [r13]          ; b[i]
        ADD     r16, r14, r15
        ADD     r13, r12, r3
        STG     [r13], r16          ; c[i] = a[i] + b[i]
        ADD     r11, r11, r9        ; i += T
        JMP     loop
done:
        MREST   m_outer             ; 重聚：恢复进入循环时的 mask
        EXIT
```

这段代码等价于源码里的 `LOOP { ... }`，由汇编器生成；手写汇编时只需要写结构化
宏（见 §6.4），保存 mask 的 GPR 分配和序列生成由汇编器负责。`m_outer`、`m_loop`
是汇编器分配的 GPR 别名，值在每条 lane 上相同。

## 6. 控制流：汇编器管理 mask

### 6.1 模型

- 硬件只有执行 mask `M` 和 per-lane 谓词 `p0..p7`；保存的 mask 值放在 GPR 里，
  由汇编器分配。
- 所有控制流都是统一的：`BR.Z/BR.NZ` 测试 GPR 里的 warp 一致 mask 值，
  `JMP` 无条件跳转；v0.1 的分支条件只有零/非零两种。
- per-lane 条件先写谓词，再由 mask 指令组合进 mask；mask 变窄意味着"这些 lane
  暂时不参与"，mask 恢复意味着重聚。
- `.P` 类 mask 指令的结果由硬件强制与当前 `M` 相干（`rd = ... & M`），防止
  inactive lane 的旧谓词把 lane 复活。
- 汇编器把 `IF/ELSE/ENDIF`、`LOOP`、`break/continue` 展开成 mask 序列，做保存
  mask 的 GPR 分配和静态检查。

### 6.2 IF/ELSE 的 lowering 模板

```asm
        ; IF cond ... ELSE ... ENDIF
        CMP.cond  p, ra, rb
        MSAVE     m_s
        MAND.P    m_then, m_s, p   ; then 路径的 lane
        MREST     m_then           ; M = m_then
        <then body>
        MANDN.P   m_else, m_s, p   ; else 路径的 lane
        MREST     m_else           ; M = m_else
        <else body>
        MREST     m_s              ; merge：恢复两条路径的所有 lane
```

没有 `ELSE` 时省掉 `m_else` 两行，then body 之后直接 `MREST m_s`。空路径可以加
`BR.Z m_then, ...` / `BR.Z m_else, ...` 跳过，属于汇编器的优化。

### 6.3 LOOP 的 lowering 模板

```asm
        ; LOOP ... ENDLOOP（条件在头部检查）
        MSAVE     m_outer             ; 进入循环时的 mask，退出后用它重聚
        MSAVE     m_loop              ; 循环继续 mask
L_head:
        MREST     m_loop              ; M = 仍在循环里的 lane
        CMP.cond  p, ra, rb
        MAND.P    m_loop, m_loop, p   ; 收窄：条件不成立的 lane 退出循环
        MREST     m_loop              ; M = 收窄后的 mask
        BR.Z      m_loop, L_done      ; 统一分支：没有 lane 继续就退出
        <body>
L_latch:
        MREST     m_loop              ; 恢复到循环 mask（continue 的 lane 在这里回归）
        <increment>
        JMP       L_head
L_done:
        MREST     m_outer             ; 重聚：恢复进入循环时的 mask
```

### 6.4 break/continue 的 lowering

`break`（当前循环里，`q` 是 break 条件谓词）：

```asm
        CMP.cond  q, ra, rb
        MANDN.P   m_loop, m_loop, q   ; 这些 lane 永久退出循环
        MANDN.P   M, M, q             ; 本迭代剩余部分不再执行
```

`continue`（`r` 是 continue 条件谓词）：

```asm
        CMP.cond  r, ra, rb
        MANDN.P   M, M, r             ; 本迭代剩余部分不再执行，但仍留在 m_loop
```

continue 的 lane 在 `L_latch` 的 `MREST m_loop` 回归，然后照常执行 increment；
break 的 lane 已经不在 `m_loop` 里，直到 `L_done` 的 `MREST m_outer` 才回归。
`break/continue` 里嵌在 `IF/ELSE` 内部时，IF 的 merge mask 必须由汇编器根据两条
路径的 continuation mask 重新计算（不是简单 `MREST m_s`），这部分数据流分析是
汇编器的核心工作。

### 6.5 重聚与限制

- 重聚是显式的：每个结构化区域在 merge 点用 `MREST` 恢复 mask。没有重聚栈，
  也没有栈深限制；硬件不知道也不关心嵌套层级。
- 嵌套深度受保存 mask 的 GPR 压力限制。汇编器分配 GPR；不够时给出警告并溢出到
  shared memory，具体策略留到写软件/汇编器时实现。
- `BAR` 要求 `M` 等于 warp 生成时的完整 mask；汇编器静态检查 `BAR` 不在 mask
  收窄的区域里，硬件保留运行时兜底。
- `EXIT` 是 warp 级指令，执行到就结束整条 warp；不要求 `M` 是完整 mask。
- mask 指令是 warp 级操作，不受 `M` 门控；普通 ALU/访存同时受 `M` 和 `@p` 门控。
- 不允许跳进/跳出结构化区域（汇编器检查）。`break/continue` 的语言支持范围
  （最内层、带标签、跨层）是汇编器/语言的事，硬件不限制。

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
  默认策略等汇编器/编译器实现时再定。
- `break/continue` 的语言支持范围（最内层、标签、跨层）——硬件不做限制，属于
  汇编器/语言设计。
- 保存 mask 的 GPR 压力、溢出到 shared 的策略和告警方式（软件阶段再定）。
- 是否需要 mask 零/非零之外的统一分支条件（v0.1 先不做，需要时再加指令）。
- `SK_NUM_LANES` 取 4 还是 8（综合实验定）。
- IMEM 16 KB、shared 32 KB 是否够用；shared bank 数取 lane 数还是 2×lane 数。
- scoreboard 需要多少个 outstanding slot。
- sgemm 是否需要 `MUL` 之外的整数除法，还是用移位/循环代替。
- 字节/半字访存什么时候加（v0.1 只做 32 位字）。
- 指令编码里的谓词字段、mask 字段、立即数宽度、保留编码的最终分配。
- 错误码的具体取值和主机可见方式。
- 是否在 P5 加一个小 L1 或只做 coalescer。

## 12. 关键决策

### 12.1 自定义 32 位定长 ISA，不用 RISC-V

指令集完全自己设计，不背 RISC-V 兼容包袱，也不考虑高级编译器：kernel 手写汇编，
工具链只有 Python 汇编器和黄金模型。好处是编码、译码、汇编全部在掌控之中，
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

**代价**：汇编器变成一个小型控制流编译器，要做 lowering、保存 mask 的 GPR 分配、
break/continue 的数据流分析和静态检查；mask 指令本身有指令数开销（每个 IF/ELSE
大约几条 mask 指令，循环每轮几条），保存 mask 的 GPR 也会增加寄存器压力（不够时
溢出到 shared，留到软件阶段处理）；验证负担从硬件转移到"汇编器生成的 mask 序列"
上——必须给汇编器配独立的 lowering 测试和 mask 序列检查。

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
