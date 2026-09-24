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

## P0 — ISA 冻结 + 汇编器 lowering + 黄金模型

**目标**：在写 RTL 之前，先把指令集冻结，把结构化控制流 lowering 成 mask 序列的
汇编器写出来，并有一个可执行的语义参考。

**交付物**

- 冻结 [design.md](design.md) §5 的编码：操作码表、谓词字段、mask 字段、立即数和
  分支偏移宽度、保留编码、寄存器/谓词/mask 编号。
- `sim/asm.py`：Python 汇编器。
  - 解析结构化语法：`IF/ELSE/ENDIF`、`LOOP`、`break/continue`、标签。
  - 控制流 lowering：按 [design.md](design.md) §6 的模板生成 mask 序列；
    处理 `break/continue` 修改 continuation mask 的数据流。
  - 保存 mask 的 GPR 分配：优先用简单栈式分配，后续再做复用优化；GPR 不够时给出
    警告并标记溢出到 shared（具体策略留到软件阶段）。
  - 静态检查：`BAR` 区域的 mask 必须是完整 mask；`break/continue` 的支持范围由
    汇编器定义（v0.1 先支持最内层循环）；不允许跳进/跳出结构化区域；mask GPR
    压力过高时给出警告并走溢出路径。
  - 输出：IMEM 镜像 + 带 mask 注释的 listing（每个标签处的 mask 状态）。
- `sim/golden/simt_golden.py`：黄金模型。per-lane 寄存器/谓词、执行 mask `M`、
  保存 mask 的 GPR、统一分支、mask 指令、两个地址空间和错误码；支持 `--trace` 和
  `--dump-state`（dump 里包含 `M` 和汇编器列出的 mask GPR）。
- `sim/tests/`：
  - 定向 ISA 测试：每条指令至少一条。
  - lowering 测试：结构化源码 → 汇编器输出的 mask 序列 → 黄金模型执行 →
    与预期状态比对。
  - 负例测试：非法的 `break/continue`、`BAR` 在收窄区域、mask GPR 压力告警、
    跳进/跳出区域。
- 定稿 `SK_config.vh` 参数。

**验收**：vecadd 在黄金模型里算出正确结果；lowering 测试全部通过；非法程序全部
被汇编器拒绝。

## P1 — 单 lane 最小核

**目标**：一条 lane 的取指、译码、执行、写回闭环（1 warp × 1 lane）。

**交付物**

- `rtl/lib/`：`SK_elastic_buffer.sv`、`SK_dp_ram.sv`、`SK_generic_arbiter.sv`。
- `rtl/core/`：`SK_fetch.sv`、`SK_decode.sv`、`SK_regfile.sv`（LUTRAM，2 读 1 写）、
  `SK_alu.sv`、`SK_lsu.sv`、`SK_branch.sv`（统一分支）、`SK_mask.sv`（1 位 mask 版本）、
  `SK_commit.sv`；`rtl/top/SK_core.sv`。
- `tb/tb_core.cpp`：Verilator testbench + IMEM/shared/global 内存模型 + 黄金模型
  dump 比对。
- 跑通 `sum = 0; for (i = 0; i < 10; i++) sum += i;`，得到 45。

**验收**：Verilator 里跑通 5 个单 lane 汇编程序，结果与黄金模型逐寄存器一致。

## P2 — N lane SIMT

**目标**：把单 lane 复制成 `SK_NUM_LANES` 个 lane，共享 PC 和 mask，加入谓词化。

**交付物**

- 每 lane 一套寄存器堆（LUTRAM，2 读 1 写），加上操作数收集和写回分发。
- `M` 门控：写回、访存、谓词写都受 `M`（和 `@p`）约束。
- `CMP` 写谓词；`SEL` 和 `@p` 谓词化指令。
- `SK_mask.sv` 支持 `M` 和 GPR 操作数的 mask 指令；`.P` 形式的结果硬件强制与
  当前 `M` 相干。
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
- `SK_bar_unit.sv`：块内屏障（只在完整 mask 下执行，汇编器负责检查）。
- 性能计数器：每 warp 指令数、stall 周期数、mask 指令数。

**验收**：4 warp 并发跑 vecadd 结果正确；IPC > 0.5（单 warp 时应当 < 0.3）。

## P4 — mask 控制流单元

**目标**：把汇编器 lowering 出来的 mask 序列真正跑起来，验证结构化控制流、
部分 lane 退出循环和 `break/continue`。

**交付物**

- `rtl/simt/SK_mask.sv`：`M`（N 位）+ GPR 操作数的 mask 指令
  （`MSAVE/MREST/MMOV/MAND/MANDN/MOR/MNOT/MAND.P/MANDN.P/MOR.P`）；
  `.P` 结果硬件强制与 `M` 相干。
- 统一分支：`BR.Z/BR.NZ` 在译码级解析（GPR 里的 mask 值已知），`JMP` 无条件跳转。
- 汇编器 lowering 集成：结构化测试程序直接生成可上板的 IMEM 镜像。
- 测试：
  - `IF/ELSE`、嵌套 `IF/ELSE`、无 `ELSE` 的 `IF`。
  - `LOOP`：部分 lane 在不同迭代退出；所有 lane 同一轮退出。
  - `break/continue`：最内层循环、嵌在 `IF/ELSE` 里的 `break/continue`；
    终止型语句改变 continuation mask 的数据流。
  - 静态检查：`BAR` 在收窄 mask 区域（应报错）、跨层 `break/continue`
    （v0.1 汇编器报"不支持"）、mask GPR 压力告警/溢出路径（如果实现）。
  - 不变式：每个 `ENDIF`/循环出口后，`M` 恢复到预期值；没有 lane 被永久丢失。

**验收**：结构化控制流测试与黄金模型逐 lane 状态一致；所有非法程序被汇编器拒绝；
mask 指令计数和理论值一致（汇编器的开销可见、可统计）。

## P5 — 内存层次

**目标**：从"能跑"到"跑得不难看"。

**交付物**

- `rtl/mem/SK_coalescer.sv`：同一 cache line 的 active lane 合并成一次事务。
- `rtl/mem/SK_smem.sv`：多 bank shared memory + 冲突检测与 replay。
- `rtl/mem/SK_axi_master.sv`：AXI4 突发读写（先 64-bit，后 128/512-bit）。
- `rtl/mem/SK_l1_cache.sv`（可选）：直接映射或 2 路组相联。
- 优化版 vecadd/sgemm，测量与理论带宽的差距。

**验收**：sgemm（64×64 单精度，整数模拟亦可）跑通；访存合并后总线事务数相比
未合并版本下降 ≥ 4 倍。

## P6 — 上板 U250

**目标**：把 GPU 变成一张真正的加速卡。

**交付物**

- `rtl/top/SK_afu.v`：Vitis RTL kernel 壳（AXI-Lite 控制 + AXI4 主 + `ap_ctrl`）。
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
| 黄金模型 | `sim/golden/simt_golden.py` | 毫秒 | 语义正确性的唯一裁判 |
| RTL 仿真 | Verilator + `tb/` | 秒～分钟 | 每次改动后的回归 |
| 上板 | Vivado + XRT | 小时 | 真实硬件与真实频率 |

任何 RTL 改动都必须在"RTL 仿真 vs 黄金模型"这一层验证过，才允许进入综合或上板。

### 黄金模型

- 纯 Python，无依赖，可断点调试。
- 状态包括：每 lane 的 GPR、谓词、PC、执行 mask `M`、保存 mask 的 GPR、
  shared/global 内存和错误码。
- `--trace` 输出每条指令的执行轨迹；`--dump-state` 输出结束时的完整状态，
  供 RTL testbench 逐行 diff。
- ISA 有歧义时以黄金模型为准，然后同步更新 [design.md](design.md)。

### 汇编器 lowering 测试

这是这套方案新增的验证层，也是分歧正确性的主要抓手：

- **正向测试**：结构化源码 → 汇编器 → mask 序列 → 黄金模型执行 → 与预期状态比对。
  覆盖 `IF/ELSE`、嵌套、`LOOP`、部分 lane 退出、`break/continue`。
- **序列检查**：对每个结构化模板，检查生成的 mask 指令数量、保存 mask 的 GPR 使用
  是否符合预期；优化（空路径跳过、if-conversion）后重新跑一遍。
- **负例测试**：`BAR` 在收窄 mask 区域、跨层 `break/continue`（v0.1 汇编器报
  "不支持"）、mask GPR 压力告警、
  跳进/跳出结构化区域——全部必须报编译错误。
- **不变式检查**：在每个 merge 点检查 `M` 是否恢复到预期集合；没有 lane 被永久
  丢失或在 merge 后被意外激活。

### RTL 仿真

- Lint：每次改完 RTL 先跑，抓 latch、位宽不匹配、多驱动。
- 单元测试：模块级，例如仲裁器、FIFO、mask 单元（小 lane 数可以穷举 mask 组合）。
- 定向测试：每条指令一个程序，覆盖边界值（0、-1、最大值、移位量等于位宽）。
- 随机测试：随机但结构合法的指令流（生成器和汇编器共用同一套 lowering/mask
  分配规则），两边比对完整状态。
- Kernel 测试：vecadd / reduce / sgemm 端到端。

### 自动比对

测试程序结束后，testbench 从 DUT 抽出状态快照（每个 lane 的 GPR、谓词、`M`、
保存 mask 的 GPR + 关键内存区间），和黄金模型 `--dump-state` 的输出逐行 diff。
不一致时打印第一条差异的位置（寄存器号、lane、期望值、实际值）。

### 上板验证

- 先用小规模输入（例如 sgemm `-n16`）跑通，再放大。
- 与仿真结果逐字节比对，比对脚本复用黄金模型的 dump 格式。
- 排查顺序：先确认平台、时钟、host-mem 正常（`xbutil examine`），再确认控制寄存器
  读写正常（读回 `CTRL` 的 idle 位），最后才怀疑数据通路。

### 回归

```bash
make regress          # lint + 全部定向测试 + lowering 测试 + kernel 测试
```

每次阶段验收跑一次完整回归。失败的测试留在仓库里，改到变绿为止，不要注释掉。
