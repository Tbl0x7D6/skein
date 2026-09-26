# 计划与验证

阶段顺序是 P0 → P7，每个阶段给出目标、交付物和验收标准。当前进度只看
[README](../README.md) 里的一行说明，不在这里维护状态。

## 里程碑

| 里程碑 | 阶段 | 演示内容 |
|---|---|---|
| M1 | P1 | 单 lane 核心算出 45 |
| M2 | P2 | 波形里看到 N 个 lane 同时算 vecadd |
| M3 | P3 | IPC 曲线：单 warp vs 4 warp |
| M4 | P4 | mask 控制流演示：IF/ELSE + 循环里部分 lane 退出 |
| M5 | P5 | 带宽/事务数对比表 |
| M6 | P6 | 板上跑 sgemm，与仿真结果比对 |
| M7 | P7 | 张量单元加速比（可选） |

## P0 — ISA 冻结 + 汇编器 + 黄金模型

**目标**：在写 RTL 之前，先把指令集冻结，写一个只做翻译的汇编器和一个可执行的语义
参考，并用它们跑通手写的 mask 序列。

**交付物**

- 冻结 [design.md](design.md) §5 的编码：类 + 子码的主操作码段分配、`pred`/`func`
  字段、立即数和分支偏移宽度、保留编码、寄存器/谓词/mask 编号、`STATUS` 错误码。
  `tools/src/isa.rs` 是编码的唯一来源，汇编器和黄金模型都从它取定义。
- `tools/src/asm.rs`：Rust 汇编器，编译成 `skein-asm`。
  - 只做翻译：一行一条指令（认标签、去注释、编码成 32 位字），唯一的伪指令是
    `LI rd, imm`（展开成 1–3 条 `ADDI`/`LUI`/`LUM`/`ORI`）。
  - 控制流和掩码序列由 kernel 手写，模板见 [design.md](design.md) §6。
  - 不做编译检查：跨区域跳转、`BAR` 的 mask、掩码寄存器压力都不管
    （`BAR` 由硬件在运行时兜底）。
  - 输出：IMEM 二进制镜像（每字 32 位小端）。
- `tools/src/golden.rs`：黄金模型（`skein-run`）。per-lane 寄存器/谓词、执行 mask `M`、
  保存 mask 的 GPR、统一分支、mask 指令、`SHFL`/`VOTE`、两个地址空间和错误码；支持
  launch 形状（`GRID_DIM`/`BLOCK_DIM`，非法 `BLOCK_DIM` 在 start 时报 `BAD_LAUNCH`）；
  支持 `--trace`、`--stats` 和 `--dump-state`（dump 里包含 `M`、全部 GPR 和 `op_counts`）。
- `tools/tests/`：`cargo test` 跑的集成测试。
  - 定向 ISA 测试：每条指令至少一条，含错误码。
  - kernel 测试：手写的 mask 序列（`IF/ELSE` merge、循环收窄、continue、按 lane 的
    break）、`cases/kernels/vecadd/vecadd.s`，以及 4 warp x 4 lane 协作搬 shared + `BAR`
    的 `cases/kernels/matmul/matmul.s`，都在黄金模型里逐 lane 比对。
- 定稿 `SK_config.vh` 参数。

**验收**：vecadd 在黄金模型里算出正确结果；kernel 测试全部通过；非法的指令和操作数
被汇编器拒绝（控制流正确性靠模板、测试和代码审查）。

**状态**：已完成（`make test` 跑 48 条 Rust 测试：38 条 ISA + 10 条 kernel；
`make asm` 出 `.bin`，`make sim` 用黄金模型跑）。

## P1 — 单 lane 最小核

**目标**：一条 lane 的取指、译码、执行、写回闭环（1 warp × 1 lane）。

**交付物**

- `rtl/SK_pkg.sv`：译码结果、ALU 微操作、mask 指令和 STATUS 的类型定义。
- `rtl/lib/SK_dp_ram.sv`：BRAM 模板（一个写口 + 一个同步读口），IMEM 用它。
- `rtl/mem/SK_imem.sv`：指令存储，PC 取指；主机装载口已经有了（P6 接 AXI-Lite）。
- `rtl/core/`：`SK_decode.sv`（译码 + 保留编码检查）、`SK_regfile.sv`（LUTRAM，3 读 1 写，
  外加一个仿真用扫描口）、`SK_alu.sv`（RALU + 立即数 ALU + 比较器）、`SK_mask.sv`
  （1 位 `M` 的 mask 单元，含 `.P`/`.PM`）、`SK_lsu.sv`（地址、对齐、访存通道），
  以及 2 级流水的 `SK_core.sv`（取指 / 译码+执行+写回，统一分支在执行级解析）。
- `tb/tb_core.cpp`：Verilator testbench + IMEM/shared/global 内存模型：喂输入、跑、
  dump 状态。定向用例在 `cases/directed/`（`sum.s` + `sum.toml` 这样成对放）。
  汇编器编不出非法程序，所以
  BAD_INSN（保留编码）和 PC_OOB（跳出 IMEM）两个用例直接在 `.toml` 里给指令字。
- 跑通 `sum = 0; for (i = 0; i < 10; i++) sum += i;`，得到 45。

**验收**：`make rtl-sim` 跑通 5 个单 lane 汇编程序（sum / alu / if-else / mem / sreg）、
BAD_INSN / PC_OOB 两个错误码用例和单 lane 版 vecadd，状态与黄金模型逐寄存器一致。

**状态**：已完成。核是 2 级而不是 5 级——BRAM 取指一拍、执行级同拍写回，够跑通单 lane
的全部语义；N lane 和 5 级流水分别在 P2、P3（和调度器、scoreboard 一起）展开。

## P2 — N lane SIMT

**目标**：把单 lane 复制成 `SK_NUM_LANES` 个 lane，共享 PC 和 mask，加入谓词化。

**交付物**

- 每 lane 一套寄存器堆（LUTRAM，3 读 1 写），加上操作数收集和写回分发。
- `M` 门控：写回、访存、谓词写都受 `M`（和 `@p`）约束。
- `CMP` 写谓词；`SEL` 和 `@p` 谓词化指令。
- `SK_mask.sv` 支持 `M` 和 GPR 操作数的 mask 指令；`.P`/`.PM` 的谓词按 `p & M` 读、
  之后是普通位运算（结果不强制 ⊆ `M`），`.PM` 同拍写 `rd` 和 `M`。
- lane 数参数化；做 4/8 lane 的综合实验（顺带记录 16 lane 的参考数据），
  记录 LUT、FF、Fmax，决定最终 lane 数。
- vecadd（N lane）与黄金模型逐元素一致，进回归。

**验收**：N lane vecadd 在 Verilator 里跑通；综合实验数据记录在案。

## P3 — 多 warp 调度 + scoreboard

**目标**：多个 warp 交替执行，用访存延迟隐藏换吞吐。

**交付物**

- `rtl/sched/SK_scheduler.sv`：轮询调度，维护 warp 状态
  （ready / stalled / barrier / done）。
- `rtl/sched/SK_scoreboard.sv`：跟踪 `LDG` 的目标寄存器（4–8 个 slot）。
- `SK_lsu.sv` 改为非阻塞：`LDG` 发出后 warp 让出流水线；`STG` posted write +
  outstanding 计数，内核结束前必须排空。
- `rtl/sched/SK_bar_unit.sv`：块内屏障（只在完整 mask 下执行，汇编器负责检查）。
- 性能计数器：`CYCLE` / `INST_*` / `STALL_*` 一组，清单见
  [design.md](design.md) §13；黄金模型的 `op_counts` 是 RTL 的对拍基准。

**验收**：4 warp 并发跑 vecadd 结果正确；IPC > 0.5（单 warp 时应当 < 0.3）。

## P4 — mask 控制流单元 + warp 协作指令

**目标**：把 §6 的手写 mask 序列真正跑起来，验证分支、部分 lane 退出循环和
`break/continue`。

**交付物**

- `rtl/core/SK_mask.sv`：`M`（N 位）+ GPR 操作数的 mask 指令
  （`MSAVE/MREST/MMOV/MAND/MANDN/MOR/MNOT/MAND.P/MANDN.P/MOR.P/MCLR.P/
  MAND.PM/MANDN.PM/MOR.PM`）；`.P`/`.PM` 只用 `M` 过滤谓词，`.PM` 同拍写 `M`。
- 统一分支：`BRZ/BRNZ` 在译码级解析（GPR 里的 mask 值已知），`JMP` 无条件跳转。
- kernel 集成：`cases/kernels/` 里的手写 mask 程序直接生成可上板的 IMEM 镜像。
- `SHFL.IDX/UP/DOWN/BFLY`：执行级的 N×N lane 交换网络（`src_lane` 由 `rb` 算，
  越界或源 lane 不在 `M` 里时返回自己的值）。
- `VOTE.ANY/ALL`：`M & pred_word` 后面的 OR/AND 树，结果写所有 lane 的 GPR，
  直接接 `BRZ/BRNZ`。两者的语义见 [design.md](design.md) §5.4 和 §12.10。
- 测试：
  - `IF/ELSE`、嵌套 `IF/ELSE`、无 `ELSE` 的 `IF`。
  - `LOOP`：部分 lane 在不同迭代退出；所有 lane 同一轮退出。
  - `break/continue`：最内层循环、嵌在 `IF/ELSE` 里的 `break/continue`；
    终止型语句改变 continuation mask 的数据流；`break` 写在 `IF/ELSE` 的 then 里时
    else 路径的 lane 不能被误删。
  - `.PM`：`rd` 和 `M` 同拍更新，且用的是旧 `M`；结果被 `& full` 夹住。
  - mask 指令的 GPR 操作数要求 warp 一致（模型侧检查，硬件不查）。
  - 汇编器静态检查（可选，见 P0 状态）：`BAR` 在收窄 mask 区域、跨层 `break/continue`、
    mask GPR 压力告警。
  - 不变式：每个 `ENDIF`/循环出口后，`M` 恢复到预期值；没有 lane 被永久丢失。

**验收**：结构化控制流测试与黄金模型逐 lane 状态一致；所有非法程序被汇编器拒绝；
mask 指令计数和理论值一致（汇编器的开销可见、可统计）；warp 内归约（`SHFL.BFLY`
求和、`SHFL.UP` 前缀和）和 `VOTE` 分叉与黄金模型一致。

## P5 — 内存层次

**目标**：从"能跑"到"跑得不难看"。

**交付物**

- `rtl/mem/SK_coalescer.sv`：同一 cache line 的 active lane 合并成一次事务。
- `rtl/mem/SK_smem.sv`：多 bank shared memory + 冲突检测与 replay。
- `rtl/mem/SK_axi_master.sv`：AXI4 突发读写（先 64-bit，后 128/512-bit）。
- `AXI_*` 性能计数器（事务 / beat / 字节 / 停顿，M5 的对比表用，见 §13）。
- `rtl/mem/SK_l1_cache.sv`（可选）：直接映射或 2 路组相联。
- 优化版 vecadd/sgemm，测量与理论带宽的差距。

**验收**：sgemm（64×64 单精度，整数模拟亦可）跑通；访存合并后总线事务数相比
未合并版本下降 ≥ 4 倍。

## P6 — 上板 U250

**目标**：把 GPU 变成一张真正的加速卡。

**交付物**

- `rtl/top/SK_afu.v`：Vitis RTL kernel 壳（AXI-Lite 控制 + AXI4 主 + `ap_ctrl`）。
- `rtl/top/SK_top.sv`、`rtl/top/SK_ctrl.sv`：核与主机接口的集成（AXI-Lite 参数、
  IMEM 装载口、start/done/error）。
- `syn/u250/`：`v++` 打包脚本（kernel → `.xo` → `.xclbin`）。
- `sw/runtime/`：XRT 原生 API 主机程序，负责装载 IMEM、写参数、轮询 done/error。
- `sw/tests/`：vecadd → sgemm 逐个上板验证。
- 目标机准备：XRT + 4.1 shell + 部署包；确认 `host-mem` 和时钟，先按 200 MHz 跑通。

**验收**：U250 上跑通 sgemm，结果与仿真逐字节一致，并记录实际频率与资源占用。

**限制**：U250 上只有单条 DDR4 通道（16 GB，约 19 GB/s），工作集要压小。

## P7 — 张量单元（可选）

**目标**：探索矩阵乘加速，不改变 SIMT 主流水线。

**交付物**

- 阶段一：内存映射加速器（AXI-Lite 控制 + 独立 DMA），不侵入 SIMT 指令流，可独立验证。
  包含 8×8 INT8 MAC 阵列（先用 DSP48 推断）和操作数暂存、分片搬运。
- 阶段二：提升为 warp 级指令 `VMMA`，由 SIMT 核发射。

**验收**：与黄金模型对比，验证 INT8 累加的正确性（含溢出/饱和语义）。

---

## 验证方法

### 三层验证

| 层 | 工具 | 速度 | 用途 |
|---|---|---|---|
| 黄金模型 | `tools/src/golden.rs` | 毫秒 | 语义正确性的唯一裁判 |
| RTL 仿真 | Verilator + `tb/`（`make rtl-sim`） | 秒～分钟 | 每次改动后的回归 |
| 上板 | Vivado + XRT | 小时 | 真实硬件与真实频率 |

任何 RTL 改动都必须在"RTL 仿真 vs 黄金模型"这一层验证过，才允许进入综合或上板。

### case（双仿真器对拍）

`cases/` 下的 `*.toml` 是唯一的用例输入描述：黄金模型和 RTL testbench 吃同一份，
`make rtl-sim` 逐个跑，`skein-case` 负责比对并汇总。case 在报告里的名字是它相对
`cases/` 的路径（`directed/sum`、`kernels/vecadd/warp4`），`program` 之类的路径相对
case 文件本身解析。

```
cases/
  directed/          单条指令或小序列的定向用例（单 lane，RTL 全跑）
  errors/            错误码：保留编码、取指越界
  kernels/<kernel>/  真 kernel 的用例，按 kernel 分目录（vecadd / matmul）
```

```toml
program = "sum.s"           # 或 words = [0x3b, 0x3a]（汇编器编不出的编码）
warpsz = 1                  # 默认 4（warpSize；RTL 现在只支持 1）
nwarp = 1                   # 默认 4
block_dim = 1               # 可选，默认用满容量
grid = 1
max_steps = 100000          # 可选，黄金模型的步数上限

[sreg]                      # 主机写的特殊寄存器
PTR_A = 0x1000
ARG0 = 4

[[init]]                    # 初态：words 或 gen + args 二选一
space = "gmem"              # gmem / smem，addr 是字节地址
addr = 0x1000
gen = "vecadd_a"            # 生成器见 tools/src/case.rs
args = { n = 4 }

[[check]]                   # 跑完要比对的窗口（RTL vs 黄金模型逐字比）
space = "gmem"
addr = 0x3000
words = 4

[expect]                    # 可选；语义期望（c[i]=a[i]+b[i]）写在 Rust 测试里
status = "OK"
barriers = 1
max_steps = 20480
```

- `make rtl-sim`：每个 case 先跑黄金模型、再跑 RTL，逐项比 status / pc / `M` / GPR /
  谓词 / `[[check]]` 窗口；形状超过 1 warp × 1 lane（RTL 还没做到）的 case 报 SKIP
  并注明原因，最后打印 PASS/SKIP/FAIL 计数。
- `make test` 里的 `tests/cases.rs` 不依赖 Verilator：每个 case 都跑一遍黄金模型并检查
  `[expect]`，保证 case 本身是有效的测试。
- 调试单个 case：`cargo run --bin skein-run -- --case cases/directed/sum.toml --trace`，
  RTL 侧 `build/obj_core/tb_core --image … --dump-state state.json` 看快照。

### 黄金模型

- Rust，黄金模型本身只用标准库；命令行用 clap，case 文件用 toml/serde，可断点调试。
- 状态包括：每 lane 的 GPR、谓词、PC、执行 mask `M`、保存 mask 的 GPR、
  shared/global 内存和错误码。
- `--trace` 输出每条指令的执行轨迹；`--dump-state` 输出结束时的完整状态，
  供 RTL testbench 逐行 diff。
- ISA 有歧义时以黄金模型为准，然后同步更新 [design.md](design.md)。

### mask 序列 / kernel 测试

分歧的正确性主要落在手写的 mask 序列上：

- **kernel 测试**：手写 mask 序列 → 黄金模型执行 → 与预期逐 lane 比对。覆盖
  `IF/ELSE` 的 merge、循环收窄、`continue`、按 lane 的 `break`、以及 vecadd。
- **模板对照**：kernel 里的序列要和 [design.md](design.md) §6 的模板一致；改模板就
  同步改 kernel 和测试。
- **不变式检查**：在每个 merge 点检查 `M` 是否恢复到预期集合；没有 lane 被永久丢失
  或在 merge 后被意外激活。

### RTL 仿真

- Lint：每次改完 RTL 先跑，抓 latch、位宽不匹配、多驱动。
- 单元测试：模块级，例如仲裁器、FIFO、mask 单元（小 lane 数可以穷举 mask 组合）。
- 定向测试：每条指令一个程序，覆盖边界值（0、-1、最大值、移位量等于位宽）。
- 随机测试：随机但合法的指令流（生成器和黄金模型共用编码定义），两边比对完整状态。
- Kernel 测试：vecadd / reduce / sgemm 端到端。

### 自动比对

`skein-case`（`make rtl-sim`）逐个跑 `cases/`：黄金模型在进程里跑，RTL 由 testbench
跑完 dump 出状态快照（每个 warp 的 pc、GPR、谓词、`M` + case 声明的内存窗口），
和黄金模型逐项比。不一致时打印寄存器号/lane/地址、期望值和实际值。

### 上板验证

- 先用小规模输入（例如 sgemm `-n16`）跑通，再放大。
- 与仿真结果逐字节比对，比对脚本复用黄金模型的 dump 格式。
- 排查顺序：先确认平台、时钟、host-mem 正常（`xbutil examine`），再确认控制寄存器
  读写正常（读回 `CTRL` 的 idle 位），最后才怀疑数据通路。

### 回归

```bash
make regress          # lint + 全部测试
```

每次阶段验收跑一次完整回归。失败的测试留在仓库里，改到变绿为止，不要注释掉。
