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
`define SK_NUM_LANES    4      // warpSize；每个 warp 的 lane 数（4/8，综合实验定）
`define SK_NUM_WARPS    4      // 每核 warp 数
`define SK_NUM_GPR      32     // 每 lane 通用寄存器数（r0 恒为 0）
`define SK_NUM_PRED     8      // 每 lane 谓词数
`define SK_SMEM_KB      32     // shared memory 容量
`define SK_IMEM_KB      16     // 指令存储容量
`define SK_MEM_ADDR_W   32     // global 地址宽度
```

执行 mask `M` 是硬件寄存器（N 位），通过 `MSAVE/MREST` 与通用寄存器交换；`M` 的
写入者还有 `MCLR.P` 和 `.PM` 形式（见 §5.4）。保存的 mask 值放在 GPR 里，由 kernel
自己分配和复用（约定用 r24–r31，见 §6.5）；不够时得自己溢出到 shared memory，
策略留到写软件阶段再说。

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

P1 落地的只是其中一部分：`SK_imem`、`SK_decode`、`SK_regfile`、`SK_alu`、`SK_mask`、
`SK_lsu`，加一个 2 级的 `SK_core`（见 §7）。图里其余模块（调度器、scoreboard、
coalescer、AXI、上板壳）随 P2–P6 加，清单见 [plan.md](plan.md)。

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
- **block / CTA**：一次启动跑一个 block，block 之间**串行**执行——前一个 block
  全部 `EXIT` 后，硬件把 PC、寄存器、谓词、mask 复位，再从入口跑下一个 block。
  `BLOCK_DIM`（主机写的 `blockDim.x`）决定 block 有多少线程：`1 ≤ BLOCK_DIM ≤
  NWARP × WARPSZ` 且必须是 `WARPSZ` 的整数倍（不允许部分 warp），非法值在 start 时报
  `BAD_LAUNCH`。block 数由主机的 `GRID_DIM` 决定，`S_BID` 是当前 block 索引（只读），
  对齐 `blockIdx`；shared/global 在 block 之间不清零。
- **warp 的生成与结束**：硬件有 `NWARP` 条 warp、每条 `WARPSZ` 个 lane；一次启动只激活
  前 `BLOCK_DIM / WARPSZ` 条（每条都是满 warp），其余直接 done。每条 warp 从入口
  `0x0000` 开始执行；`EXIT` 是 warp 级指令，执行到就结束整条 warp；所有活跃 warp
  结束后硬件置 done。
- **汇编器的职责**：只做翻译——一行一条指令，认标签，编码成 32 位字。掩码序列
  （`MSAVE`/`MREST`/`MAND.P`/`MCLR.P`）是普通指令，由 kernel 手写；写法模板见 §6，
  完整例子见 [sim/kernels/vecadd.s](../sim/kernels/vecadd.s)。

## 5. 指令集

### 5.1 设计原则

- 32 位定长指令，6 位主操作码，PC 每步 +4。定长让取指、分支偏移和译码都很简单。
- 不兼容任何现成 ISA，也不考虑高级编译器：kernel 用手写汇编写，分歧用 mask 序列
  表达；汇编器只负责编码。
- 指令可以带谓词门控 `@p` / `@!p`（取反）：谓词为假的 lane 不写回、不访存。取反位只
  存在于 R/SR 格式；RI 格式（立即数 ALU 和 `LDS/STS/LDG/STG`）只有不取反的 `@p`。
- 控制流统一：没有 per-lane 分支，分支只测试 GPR 里的 mask 值（零/非零）或无条件跳转。
- 不提供 warp 级**数据**归约指令：归约用 `SHFL.*` 按 log N 步自己搭（也可以走
  shared memory + `BAR`）。warp 级只有谓词投票 `VOTE.*`，没有别的跨 lane 运算。

### 5.2 寄存器与掩码

| 类别 | 数量 | 说明 |
|---|---|---|
| `r0–r31` | 每 lane 32×32b | 通用寄存器，`r0` 恒为 0 |
| `p0–p7` | 每 lane 8×1b | 谓词，由比较指令写；用于 `@p`/`@!p` 门控和 mask 计算 |
| `M` | 每 warp 1 个 N 位 | 执行 mask（唯一的硬件 mask 状态），门控写回和访存 |
| 保存的 mask | 放在 GPR 里 | 由汇编器分配；全 lane 保存同一份副本（warp 一致） |
| 特殊寄存器 | 只读 | `TID/LANEID` 每 lane 不同；`WID/BID/WARPSZ/BLOCK_DIM/NWARP/GRID/PTR0–2/ARG0–2/STATUS` 每条 lane 读出的值相同 |

特殊寄存器用 `SREAD rd, sreg` 读入通用寄存器。`WARPSZ` 是 warpSize（每个 warp 的 lane
数，硬件上是 `SK_NUM_LANES`），`BLOCK_DIM` 是主机给的 block 线程数（= `blockDim.x`），
`TID = WID × WARPSZ + LANEID` 是 block 内的线程号（活跃范围 0 … `BLOCK_DIM - 1`，
对齐 `threadIdx`），`BID` 是当前 block 索引（对齐 `blockIdx`），`GRID`/`NWARP` 是总数。

### 5.3 编码格式

P0 冻结。位序从低位写起，立即数和分支/跳转偏移都以**指令字**为单位：

| 格式 | 位分配 | 用途 |
|---|---|---|
| R | `op[5:0] rd[10:6] ra[15:11] rb[20:16] pred[24:21] func[28:25] pinv[29]` | 类 `00`：ALU/`CMP`/`SEL`/`SHFL`/`VOTE`；类 `11_1`：mask |
| RI | `op[5:0] rd[10:6] ra[15:11] pred[19:16] imm[31:20]` | 类 `01`：立即数 ALU/`LUI`/`LUM`；类 `10`：`LDS/STS/LDG/STG`（没有 `pinv`） |
| BR | `op[5:0] rs[10:6] off[31:11]`（21 位有符号） | 类 `11_0`：`BRZ` / `BRNZ` |
| J | `op[5:0] off[31:6]`（26 位有符号） | 类 `11_0`：`JMP` |
| SR | `op[5:0] rd[10:6] sreg[15:11] pred[24:21] pinv[29]` | 类 `11_1`：`SREAD` |
| SYS | `op[5:0] func[28:25]` | 类 `11_1`：`NOP` / `BAR` / `EXIT` |

- `func` 是 4 位：各指令组最多 16 个编码（ALU 用 13 个、mask 用 11 个、条件用 6 个）。
- `pred` 字段：0 = 无谓词，1..8 = `@p0..@p7`，9..15 保留。`pinv` 位为 1 表示
  `@!p`，所以取反不占用谓词号，也不需要把条件反过来写。
- `@!p` 只对带 `pinv` 的格式有效：R（ALU/`CMP`/mask）和 SR（`SREAD`）。RI 格式的
  bit29 属于 `imm`，只有 `@p`；`@!p` 要改用相反的比较条件（`GE`↔`LT`、`NE`↔`EQ`、
  `GEU`↔`LTU`）。汇编器遇到硬件不支持的门控直接报错，不静默降级。
- R/SR/SYS 的 bit31:30 保留，必须写 0。
- 跳转目标 = `PC + 4 + off × 4`，即相对下一条指令；`BR` 范围 ±2²⁰ 条指令，
  `JMP` 范围 ±2²⁵ 条。分支的操作数必须全 lane 相同，由汇编器保证。
- mask 指令的 `.P` 形式把谓词号放在 `rb` 字段（0..7）。
- `SEL` 的 `pred` 字段是**操作数**（按哪个谓词选值），不是 `@p` 门控；`SEL`
  本身仍受 `M` 门控。

主操作码按"类 + 类内子码"分配：`op[5:4]` 是类，`op[3:0]` 是子码。新指令只在已有的
段里分配，不新开类；不占用的子码保持预留（保留编码被硬件当非法指令拒绝）。

| `op[5:4]` | 类 | `op[3:0]` 分配 |
|---|---|---|
| `00` | R 向量执行 | `0000` RALU（`func` 选）；`0100`–`0111` `CMP`（`bop = op[1:0]`：00 直接赋值 / 01 AND / 10 OR / 11 XOR）；`1000` `SEL`；`1001` `SHFL`；`1010` `VOTE`；其余预留 |
| `01` | RI 立即数 ALU | `0000`–`0110` = `ADDI/ANDI/ORI/SHLI/SLTI/LUI/LUM`；其余预留 |
| `10` | RI 访存 | `0000`–`0011` = `LDS/STS/LDG/STG`；其余留给字节/半字和原子（`0x24`–`0x2F`） |
| `11_0` | 控制流 | `000`–`010` = `BRZ/BRNZ/JMP`（`0x30`–`0x32`）；其余留给更多统一分支条件 |
| `11_1` | warp 级 / 系统 | `000`–`010` = `MASK/SREAD/SYS`（`0x38`–`0x3A`）；其余预留 |

`CMP` 的谓词组合修饰（`AND`/`OR`/`XOR`）直接用主操作码的子码区分，不放进 `func`：
`func` 只有 4 位，装不下 6 个条件 × 4 种修饰。

类决定格式：类 `01`/`10` 是 RI（`pred` 在 `[19:16]`、没有 `pinv`），其余是 R/BR/J/SR/SYS。

`func` 字段（保留值不使用）：

| 组 | 操作码 | func |
|---|---|---|
| ALU | 类 `00` / 子码 `0000` | `ADD=0 SUB=1 AND=2 OR=3 XOR=4 SHL=5 SHR=6 SAR=7 SLT=8 SLTU=9 MUL=A MOV=B FMA=C` |
| 比较 | 类 `00` / 子码 `0100`–`0111` | `EQ=0 NE=1 LT=2 GE=3 LTU=4 GEU=5`（`func` 是条件，`bop` 看子码） |
| mask | 类 `11_1` / 子码 `000` | `MSAVE=0 MREST=1 MMOV=2 MAND=3 MANDN=4 MOR=5 MNOT=6 MAND.P=7 MANDN.P=8 MOR.P=9 MCLR.P=A MAND.PM=B MANDN.PM=C MOR.PM=D` |
| 系统 | 类 `11_1` / 子码 `010` | `NOP=0 BAR=1 EXIT=2` |
| SHFL | 类 `00` / 子码 `1001` | `IDX=0 UP=1 DOWN=2 BFLY=3` |
| VOTE | 类 `00` / 子码 `1010` | `ANY=0 ALL=1` |

### 5.4 指令表

ALU（全部 per-lane、可带 `@p`/`@!p`）：

| 指令 | 语义 |
|---|---|
| `ADD/SUB/AND/OR/XOR/SHL/SHR/SAR/SLT/SLTU/MUL` | 每 lane 算术/逻辑/移位/比较，结果写自己的目标寄存器 |
| `FMA rd, ra, rb` | 每 lane 乘加：`rd = rd + ra × rb`（低 32 位回绕；`rd` 既读又写，所以寄存器堆要 3 个读端口） |
| `MOV rd, ra` | 每 lane 搬移 |
| `ADDI/ANDI/ORI/SHLI/SLTI rd, ra, imm` | 12 位立即数 ALU（`imm` 有符号或零扩展按指令定） |
| `LUI rd, imm12` / `LUM rd, ra, imm12` / `ORI` | 常数分段装载：`imm<<20` / `ra \| imm<<12` / `ra \| imm` |
| `LI rd, imm` | 伪指令：1–3 条 `ADDI/LUI/LUM/ORI` 拼出任意 32 位常数 |
| `CMP.cond[.AND\|.OR\|.XOR] p, ra, rb` | 每 lane 比较写谓词（EQ/NE/LT/GE/LTU/GEU）；带修饰时是读改写：`p &= / \|= / ^= cond(ra, rb)`，不带修饰直接赋值 |
| `SEL rd, ra, rb, p` | 每 lane 按 `p` 选值（`p` 是操作数），用于短小的条件更新 |

`LI` 用顺序无关的三段拼装：`LUI` 放 bits31:20，`LUM` 放 bits23:12，`ORI` 放
bits11:0；三段都带 `pred`，所以在收窄的 mask 里也能安全装载常数。

访存（per-lane、可带 `@p`；RI 格式，没有 `@!p`；v0.1 只支持 32 位字）：

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
| `MAND.P rd, ra, p` | `rd = ra & (p & M)` |
| `MANDN.P rd, ra, p` | `rd = ra & ~(p & M)` |
| `MOR.P rd, ra, p` | `rd = ra \| (p & M)` |
| `MAND.PM rd, ra, p` | 同 `MAND.P`，并且 `M = rd` |
| `MANDN.PM rd, ra, p` | 同 `MANDN.P`，并且 `M = rd` |
| `MOR.PM rd, ra, p` | 同 `MOR.P`，并且 `M = rd` |
| `MCLR.P p` | `M = M & ~p`（break/continue 序列用，见 §6.4） |

mask 指令是 warp 级操作：不受 `M` 门控，结果写所有 lane。`.P`/`.PM` 的谓词按
`p & M` 读，之后是普通位运算——`M` 只过滤谓词，**不再对结果 `& M`**：inactive lane
的旧谓词不会把 lane 复活（`p & M` 已经把它们清掉），但结果里 `ra` 原有的位不会被
`M` 截掉；要交集就显式把当前 mask 当 `ra`（break 模板就是这么写的）。
`M` 的写入者是 `MREST`、`MCLR.P` 和 `.PM` 形式：`.PM` 用旧 `M` 算完新值后，
同一拍把 `rd` 和 `M` 都写成 `结果 & full`。

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
| `SREAD rd, sreg` | 读特殊寄存器到每 lane 的通用寄存器；可带 `@p`/`@!p` 门控 |

warp 协作（R 格式；`SHFL` 是 per-lane 写回，`VOTE` 是 warp 级写回）：

| 指令 | 语义 |
|---|---|
| `SHFL.IDX rd, ra, rb` | `rd = ra[src]`，`src = rb % WARPSZ` |
| `SHFL.UP rd, ra, rb` | `src = lane - rb` |
| `SHFL.DOWN rd, ra, rb` | `src = lane + rb` |
| `SHFL.BFLY rd, ra, rb` | `src = lane ^ rb`（蝴蝶归约） |
| `VOTE.ANY rd, p` | `M` 里有 lane 满足 `p` 就 `rd = 1`，否则 `0` |
| `VOTE.ALL rd, p` | `M` 里所有 lane 都满足 `p` 就 `rd = 1`（`M` 为空也算 1），否则 `0` |

`SHFL` 的边界规则照抄 NV：源 lane 越界（`UP` 下溢、`DOWN` 溢出、`BFLY` 超出 warp）或者
源 lane 不在 `M` 里，就返回**自己的值**，不报错——inactive lane 的寄存器内容没有意义。
`SHFL` 读的是同一拍所有 lane 的旧值（写回不会影响别的 lane 的源值），写回本身受 `M`
和 `@p`/`@!p` 门控。`VOTE` 是 warp 级指令：**结果写所有 lane 的 GPR**、不受 `M` 写回
门控，所以 `BRNZ/BRZ` 读 lane 0 也一定能拿到结果；`VOTE` 自己不接受 `@p` 门控。
`rb` 是寄存器（没有立即数变体）；`VOTE` 的谓词号放 `rb` 字段，和 mask 的 `.P` 形式一致。

刻意没有的指令：per-lane 分支、分支重聚点字段、重聚栈、warp 级数据归约指令
（`VOTE` 只投谓词票，不做数据归约）；
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
| 7 | `BAD_LAUNCH` | 启动参数非法：`BLOCK_DIM` 为 0、超过 `SK_NUM_LANES × SK_NUM_WARPS`，或不是 `SK_NUM_LANES` 的整数倍 |

### 5.6 Kernel 调用约定

主机通过 AXI-Lite 写这些寄存器，然后置 `ap_start`：

| 偏移 | 名称 | 含义 |
|---|---|---|
| `0x00` | `CTRL` | bit0=start，bit1=done(只读)，bit2=idle(只读)，bit3=error(只读) |
| `0x08` | `GRID_DIM` | block 数；硬件按 block 顺序执行，kernel 用 `S_BID` 取当前索引 |
| `0x10` | `BLOCK_DIM` | `blockDim.x`（主机写）：`1 ≤ x ≤ SK_NUM_LANES × SK_NUM_WARPS` 且是 `SK_NUM_LANES` 的整数倍；start 时校验，非法则 `STATUS = BAD_LAUNCH` |
| `0x18/0x20/0x28` | `PTR_A/B/C` | 设备端 global 地址 |
| `0x30/0x38/0x40` | `ARG0/1/2` | 标量参数（如 `n`） |
| `0x48/0x50/0x58` | `IMEM_ADDR/WDATA/WE` | 指令镜像装载口 |

启动顺序：主机写 IMEM 镜像 → 写参数（`GRID_DIM`/`BLOCK_DIM`/`PTR_*`/`ARG*`）→ 置
start → 轮询 done/error。入口固定 `0x0000`。

### 5.7 汇编示例：vecadd

`S_TID` 是 block 内的线程号（`wid * WARPSZ + laneid`），`S_LANEID` 是 lane 在 warp 内的
编号。`S_BLOCK_DIM` 就是 `blockDim.x`，kernel 认领工作直接拿 `BLOCK_DIM` 当 stride，
不用自己乘 `NWARP × WARPSZ`。handwritten 部分：

```asm
        ; PTR_A/B/C、ARG0、BLOCK_DIM/NWARP/WARPSZ/WID 每条 lane 读出的值相同；TID 每 lane 不同
        SREAD   r1, S_PTR_A
        SREAD   r2, S_PTR_B
        SREAD   r3, S_PTR_C
        SREAD   r4, S_ARG0          ; n
        SREAD   r6, S_BLOCK_DIM     ; stride = blockDim.x
        SREAD   r11, S_TID          ; i = wid * WARPSZ + laneid
        MOV     r9, r6              ; 每条 lane 冗余计算
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
- `.P`/`.PM` 类 mask 指令把谓词按 `p & M` 读，之后再做普通位运算：inactive lane 的
  旧谓词不会把 lane 复活；结果也不强制 ⊆ `M`，要交集就显式把当前 mask 当 `ra`。
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

- 两条分支 mask 都在切 `M` 之前算，读的是同一个入口 `M`（顺序现在不敏感，`.P` 不再
  对结果 `& M`，但放一起更清楚）。
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
        MAND.PM   r25, r25, p         ; 收窄继续 mask，同时把 M 切过去
        BRZ       r25, L_done         ; 统一分支：没有 lane 继续就退出
        <body>
L_latch:
        MREST     r25                 ; 恢复 continue 的 lane
        JMP       L_head
L_done:
        MREST     r24                 ; 重聚：恢复进入循环时的 mask
```

`MAND.PM` 只是省掉紧跟的 `MREST r25`：不想动 `M` 的话，写 `MAND.P r25, r25, p` 再
补一条 `MREST r25` 效果一样。

循环是 while 语义：`continue` 跳过本轮剩余部分（包括写在 body 末尾的自增），
下一轮从头部条件重新开始。头部收窄 `r25` 是永久性的——这些 lane 已经算出
"不必再迭代"，只有 `L_done` 的 `MREST r24` 才把它们放回来。

### 6.4 break/continue 序列

`break`（`q` 是 break 条件谓词）：

```asm
        CMP.cond  q, ra, rb
        MANDN.P   r25, r25, q         ; 这些 lane 永久退出循环（只在当前 M 内生效）
        MCLR.P    q                   ; 本迭代剩余部分不再执行
```

`MANDN.P` 的谓词按 `q & M` 读，而 `M` 往往比 `r25` 窄（比如 break 写在 `IF` 的 then
路径里）：`M` 外的 lane（else 路径）不会被误删，`r25` 里它们的那一位会留着。

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
- mask 指令的 GPR 操作数（`MREST` 的 `rs`，`MMOV/MNOT/MAND/MANDN/MOR` 的 `ra`/`rb`，
  `.P`/`.PM` 的 `ra`）必须是 warp 一致的 mask 值——这是 ISA 的要求，但**硬件不查**；
  黄金模型会查，不一致就报出 PC、指令和出错的 lane 值。这是模型侧的调试检查，
  用来抓"每条 lane 各自一套 mask"的写法错误，不是硬件行为。
- 不要随便跳进/跳出 mask 区域：标签在映像里就是地址，跳错了没有编译错误，只有跑飞。

## 7. 流水线

v0.1 采用 5 级流水线；lane 数取 8 时可以在 S3/S4 之间加一级操作数读，变成 6 级：

| 级 | 职责 |
|---|---|
| S1 Schedule | 轮询选 warp、发出 PC |
| S2 Fetch | 从 IMEM 取指 |
| S3 Decode | 译码、读寄存器和谓词；统一分支在这里解析（GPR 里的 mask 值已知） |
| S4 Execute | ALU / LSU / mask / `SHFL`（lane 交换网络）/ `VOTE`（OR/AND 树）；LDG 发出后由 scoreboard 跟踪 |
| S5 Commit | 受 `M` 和谓词门控写回；分支重定向、清年轻指令 |

不预测分支：统一分支在 S3 解析，命中则重定向并清掉年轻指令；解析前该 warp 停止
发射，其他 warp 继续。每个 warp 一个 scoreboard（4–8 个 slot）跟踪 `LDG` 的目标
寄存器；`STG` 是 posted write，用 outstanding 计数在内核结束前排空。

P1 先做 2 级：BRAM 取指一拍，加一个执行级，执行级同拍写回（寄存器堆是"写在下一条
指令读之前"，不用前递）；统一分支也在这一级解析，命中就把在途的取指丢掉，代价是一个
空泡。拆成 5 级和 P3 的调度器、scoreboard 一起做。

## 8. 存储层次

| 存储 | 实现 | 说明 |
|---|---|---|
| 通用寄存器堆 | 每 lane 32×32b LUTRAM（3 读 1 写） | 不用 BRAM；`FMA` 的 `rd` 既读又写，所以是 3 读 |
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
- `SHFL.IDX` 的取模：v0.1 的 `WARPSZ` 是 4/8（2 的幂），硬件用低位掩码就够；将来
  `WARPSZ` 不是 2 的幂时要真取模（比较链或除法器）。
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
分配和复用）；硬件只有执行 mask `M`，`.P`/`.PM` 类 mask 指令把谓词按 `p & M` 读、
之后做普通位运算（结果不强制 ⊆ `M`，`.PM` 还同拍写 `M`）。重汇聚由汇编器在 merge
点显式 `MREST`，循环用 mask 收窄 + "已退出 lane"掩码处理 `break/continue`；
`break/continue` 的支持范围由汇编器/语言决定，硬件不限制。`BAR` 要求完整 mask。

**好处**：硬件非常简单——没有重聚栈、没有重聚比较器、没有栈深限制、分支在译码级
就能解析；分歧的正确性主要落在生成出来的 mask 序列上，硬件可以做成一组很简单的
位运算。mask 值用 GPR 保存，不需要专用 mask 寄存器堆。

**代价**：mask 序列要手写——每个 `IF/ELSE` 大约几条 mask 指令、循环每轮几条，寄存器
压力也落在写 kernel 的人身上（`r24–r31` 八个掩码寄存器，不够就溢出到 shared，留到
软件阶段处理）；验证负担从硬件转移到"手写的 mask 序列"上，所以 §6 的模板和
`sim/kernels/` 里的例子就是规范，测试也跟着测这些序列。

具体做法（P0）：汇编器只做编码（`sim/src/asm.rs`，一行一条指令）；掩码序列按 §6 的
模板手写。`IF` 的 merge 用两条路径退出 mask 的 `MOR`，这样路径里的 break/continue
收窄不会被 merge 撤销。`.P` 的 `M` 只作用在谓词上（`p & M`），所以从比 `M` 宽的外层
mask 里删 lane 可以直接写（见 §6.4）；要交集就显式把当前 mask 当 `ra`。`M` 的写入者
是 `MREST`、`MCLR.P` 和 `.PM`。

### 12.4 两个地址空间、独立 load/store

shared memory（`LDS/STS`，16 位地址，片上 BRAM 多 bank）和 global memory
（`LDG/STG`，32 位地址，AXI4）各自独立编址，指令本身区分空间。好处是访存路径
清晰、不依赖地址译码；代价是两套访存指令和两套地址计算。

### 12.5 寄存器堆用 LUTRAM，不用 BRAM

寄存器堆需要每 lane 3 读 1 写、组合读，BRAM 的端口数、延迟和粒度都不合适；
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

### 12.9 谓词门控对齐 NV 风格：`@!p` + `CMP` 组合修饰

- `func` 从 7 位收到 4 位（每组最多 16 个编码）；省出的 bit29 做 `pinv`（`@!p`），
  bit31:30 保留。
- R/SR 格式有取反位，RI 没有（立即数 + pred 已经占满）：汇编器对 RI 上的 `@!p` 直接
  报错，要取反就写互补条件（`GE`↔`LT`、`NE`↔`EQ`、`GEU`↔`LTU`）。
- RI 维持 12 位立即数、**不**为了 `@!p` 收缩到 11 位（`ORI` 会够不到 bit11，`LI` 的
  三段拼装也得跟着改）：RI 上只支持 `@p`。
- `CMP` 的 `AND/OR/XOR` 修饰用**主操作码的子码**区分（类 `00` 的 `0100`–`0111`，
  `bop = op[1:0]`）：4 位 `func` 装不下 6 个条件 × 4 种修饰，而子码段还有空位。
- 好处：取反不占谓词号、写 kernel 少一条 `CMP`+`MANDN` 的绕行；硬件只多一个位和一条
  读改写路径。代价：子码多花 3 个；RI 上的 `@!p` 要用互补条件。
- 主操作码按"类 + 子码"重排（[§5.3](#53-编码格式)）：`op[5:4]` = 类、`op[3:0]` = 子码，
  新指令只在段内分配。`func` 的价值在于"同一段里的变体"（ALU 的 13 种、条件码、mask 的
  11 种），主操作码的类只回答"用哪个执行单元、什么格式"。
- 执行模型同步对齐 CUDA：`GRID_DIM` 生效、block 之间串行、新增只读 `S_BID`；`BLOCK_DIM`
  （主机写）就是 `blockDim.x`、`WARPSZ` 就是 `warpSize`、`BID` = `blockIdx`、
  `TID` = `threadIdx`。`BLOCK_DIM` 必须是 `WARPSZ` 的整数倍，不支持部分 warp，
  所以 `full` mask 仍然是常量、`BAR` 规则不变。

### 12.10 warp 协作指令：`SHFL` + `VOTE`

- `SHFL.IDX/UP/DOWN/BFLY` 做 warp 内 lane 间传值，`VOTE.ANY/ALL` 做谓词投票；两者都在
  R 格式里（`func` 选模式），不动访存和掩码单元。
- 修订 §5.1、§5.4 里"不提供 warp 级归约指令"的说法：改成"不提供 warp 级**数据**归约
  指令；归约由软件用 `SHFL.*` 按 log N 步搭"。理由：没有统一通路、warp 只有 4 条，
  走 shared 归约要两次全块同步；代价是执行级多一个 N×N lane 交换网络（N = 4 是每 lane
  一个 4:1 mux、N = 8 是 8:1），面积和时序压力随 N² 长，所以这条只在 `WARPSZ ≤ 8` 时
  划算，要综合实验（见 §12.6、§11）。
- `VOTE` 的结果落在 **GPR**（0/1、写所有 lane）而不是谓词：本 ISA 的统一分支
  `BRZ/BRNZ` 读 GPR，这样投完票不用再搬一次就能分叉；写所有 lane 是为了 lane 0 不在
  `M` 里时也能读到结果。硬件只是 `M & pred_word` 后面接一棵 OR/AND 树。
- 落地阶段：P4（和 mask 控制流单元同一批，见 [plan.md](plan.md)）。

## 13. 性能计数器

计数器是 M3（IPC 曲线）和 M5（带宽/事务对比表）的数据来源，不改 ISA；黄金模型和 RTL
用同一份指令分类，方便对拍。

| 组 | 计数 | 用途 |
|---|---|---|
| 周期/发射 | `CYCLE`、`INST_ISSUED`、`INST_RETIRED`、`WARP_READY`、`BLOCKS_DONE` | IPC = `INST_RETIRED / CYCLE`；M3 用同一个 kernel 跑 `NWARP = 1/2/4` 各一遍画曲线 |
| 停顿（互斥） | `STALL_FETCH`、`STALL_SCOREBOARD`、`STALL_BRANCH`、`STALL_LSU`、`STALL_BAR`、`STALL_NO_WARP` | 判断 IPC 低是缺 warp 还是访存卡住 |
| shared | `LDS_TXN`、`STS_TXN`、`LDS_REPLAY` | bank 冲突的代价 |
| global/AXI | `AXI_RD_TXN`、`AXI_WR_TXN`、`AXI_RD_BEATS`、`AXI_WR_BEATS`、`AXI_RD_BYTES`、`AXI_WR_BYTES`、`AXI_STALL`、`LDG_INFLIGHT_MAX` | M5 的对比表：开/关 coalescer 各一行 |

- 黄金模型已经按分类统计指令条数（`skein-run --stats` 和 `--dump-state` 里的
  `op_counts`），RTL 的 `INST_RETIRED` 分类要和它对得上——对不上就是 RTL 的 bug，这比
  "结果正确"更早暴露吞吐问题。
- RTL 侧：`SK_perf.sv` 放一组 32 位计数器，各流水级给 one-hot 事件；读出口复用
  AXI-Lite（`PERF_ADDR`/`PERF_DATA` 一对寄存器，和 IMEM 装载口同一套），`CTRL.start`
  清零、`done` 冻结。200 MHz 下 32 位要 20 s 才回绕，够用。
- 落地阶段：`CYCLE`/`INST_*`/`STALL_*` 在 P3，`AXI_*` 在 P5（见 [plan.md](plan.md)）。
