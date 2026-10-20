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

**目标**：把单 lane 复制成 `SK_NUM_LANES` 个 lane，共享 PC 和执行 mask `M`，写回、
访存、谓词写都按 lane 门控；顺手修掉黄金模型允许写 `r0` 的分歧。

**交付物**

- `SK_regfile` 加 `LANES` 维度（每 lane 3 读 1 写 + 扫描口加 lane 选择）；
  `SK_core` 按 lane 例化 `SK_alu`，写回数据/门控都变成 per-lane；`SK_mask` 的 `M`
  和谓词输入扩到 N 位；`SHFL` 走 N×N 交换网络，`VOTE` 是 N 位归约后广播。
- `S_LANEID` / `S_TID = WID × WARPSZ + LANEID` 由核按 lane 算；`shape_o` 输出
  `{NWARP, NUM_LANES}`，testbench 和 runner 都从它拿形状，不再各写一份常量。
- 访存多周期：一条 `LDS/STS/LDG/STG` 占 `SK_NUM_LANES` 拍，按 lane 顺序每拍一条
  （没 active lane 也照走），期间冻结取指和 E 级译码结果；出错即停在这条 lane 上，
  出错之后的架构状态不作为保证（见 [design.md](design.md) §5.5）。
- 黄金模型只修 `r0`：写 `r0` 被丢弃（和 RTL 的寄存器堆一致），访存语义不动。
- 用例框架：`skein-case` 用 `tb_core --print-shape` 探形状做 SKIP 判定；golden 报错时
  只比 `status` 和 `pc`，不再刷一屏无意义的 GPR 差异。8 个单 lane 用例改成单 warp ×
  4 lane，新增 `kernels/matmul/rows4`（多 lane `LDS/STS` + `BAR`）。
- lane 数扫描：`syn/synth_core.tcl` + `make synth`，在 xcu250 上按 4/8/16 lane 各综合
  一遍，记录 LUT/FF/DSP/URAM 和 200 MHz 下的 WNS（数据见 design.md §12.6）。

**验收**：`make regress` 全绿；`make rtl-sim` 是 10 PASS / 4 SKIP / 0 FAIL，SKIP 只剩
需要多 warp 的 `vecadd/warp4` 和 `matmul/{rows16,rows23,bdim8}`；综合数据记录在案。

**状态**：已完成。`SK_NUM_LANES` 冻结在 4（依据见 design.md §12.6）；RTL 仍然只跑
1 条 warp，多 warp 和 5 级流水在 P3。

## P3 — 多 warp 调度 + scoreboard

**目标**：多个 warp 交替执行，用访存延迟隐藏换吞吐。

**交付物**

- 核拆成 5 级：S1 调度 / S2 取指 / S3 译码 / S4 执行 / S5 提交，取指是两级寄存器
  （BRAM 一拍延迟，PC 要和指令一起进 IF/ID）。每条 warp 最多一条指令在流水里：
  发射间隔 4 拍，寄存器堆写一定在下一次读之前落地，所以**不做前递**，也不会中途卡住
  某一级（design.md §7）。
- `rtl/sched/SK_scheduler.sv`：轮询发射 + warp 状态（RUN / BAR / DONE）；
  `rtl/sched/SK_bar_unit.sv`：块内屏障（所有还活着的 warp 到齐才放行）。
- `rtl/sched/SK_scoreboard.sv`：每 warp 一份"哪些 GPR 在等 `LDG`/`LDS`"的 bit；
  译码级查出 RAW / WAR 就把这条指令**重发**（丢空泡 + PC 回退），别的 warp 继续。
- `rtl/core/SK_lsu.sv` 改成非阻塞：每 warp 一个请求槽，轮询服务，一拍一条 lane；
  `LDG/LDS` 的数据回写到寄存器堆（和流水线提交抢同一个写口时让一拍），`STG/STS`
  是 posted write，`BAR`/`EXIT` 之前必须排空。
- `rtl/perf/SK_perf.sv`：`CYCLE` / `INST_ISSUED` / `INST_RETIRED` / `REPLAY` /
  `BARRIERS` / `STALL_NO_WARP` / `LSU_BUSY`，清单见 [design.md](design.md) §13。
- 用例框架：`perf` 进 dump，`skein-case` 报 IPC，`INST_RETIRED` 和黄金模型的 `steps`
  对拍。

**验收**：4 warp 并发跑 vecadd 结果正确；IPC > 0.5（单 warp 时应当 < 0.3）。
这两条从报告里的 IPC 数字看，不写进 case——case 只描述输入和期望状态，
吞吐是拿 `--stats` 观察的指标。

**状态**：已完成。`make rtl-sim` 14 PASS / 0 SKIP / 0 FAIL（`vecadd/warp4` IPC 0.63、
`matmul/rows16` 0.72、`vecadd/warp1` 0.19）；4 lane 的核在 200 MHz 下综合 WNS
+0.43 ns、24463 LUT / 18662 FF（数据见 design.md §12.6）。

## P4 — mask 控制流单元 + warp 协作指令

**目标**：把 §6 的手写 mask 序列真正跑起来，验证分支、部分 lane 退出循环和
`break/continue`。

**交付物**

- `rtl/core/SK_mask.sv`：`M`（N 位）+ GPR 操作数的 mask 指令
  （`MSAVE/MREST/MMOV/MAND/MANDN/MOR/MNOT/MAND.P/MANDN.P/MOR.P/MCLR.P/
  MAND.PM/MANDN.PM/MOR.PM`）；`.P`/`.PM` 只用 `M` 过滤谓词，`.PM` 同拍写 `M`。
- 统一分支：`BRZ/BRNZ` 在 S4 执行级解析（GPR 里的 mask 值在流水里已知，见 P3 的
  五级流水），`JMP` 无条件跳转。
- kernel 集成：`cases/kernels/mask/` 里的手写 mask 程序直接生成可上板的 IMEM 镜像。
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
  - 汇编器静态检查：不做（P0 已定 asm 只做编码转换），控制流正确性靠模板、用例和审查。
  - 不变式：每个 `ENDIF`/循环出口后，`M` 恢复到预期值；没有 lane 被永久丢失。

**验收**：结构化控制流与 warp 协作（`SHFL.BFLY` 求和、`SHFL.UP` 前缀和、
`VOTE.ANY/ALL` 分叉）在 RTL 和黄金模型上逐 lane 状态一致；非法指令/操作数由汇编器
按现有规则拒绝（不做控制流静态检查）；IF/ELSE 模板的 MASK 类指令计数由测试钉住
（9 条，模板改动会立刻反映）。

**状态**：已完成。`cases/kernels/mask/` 11 条程序（发散/嵌套/无 ELSE 的 IF、统一退出和
按 lane 退出的循环、continue、break、`.PM`、`SHFL`、`VOTE`）双仿真器对拍通过，
`make rtl-sim` 25 PASS / 0 SKIP / 0 FAIL；`make test` 39 条 ISA + 14 条 kernel + 2 条
case 用例。

## P5 — 内存层次

**目标**：从"能跑"到"跑得不难看"。

**交付物**

- `rtl/mem/SK_coalescer.sv`：同一 cache line 的 active lane 合并成一次事务。
- `rtl/mem/SK_smem.sv`：多 bank shared memory + 冲突检测与 replay。
- `rtl/mem/SK_axi_master.sv`：AXI4 主口（P6.2 起 512-bit、一次一整行 64 B，
  上游仍是 64-bit beat 接口）。
- `rtl/mem/SK_l1_cache.sv`：16 KB 直接映射、写回 + 写分配、单 MSHR，跑完 flush 脏行。
- `tb/tb_top.sv` + `tb/tb_axi_mem.sv`：核 + AXI 从机的仿真顶层，延迟可配（M5 用 20 拍）。
- `AXI_*` / `L1_*` / 指令分类性能计数器（M5 的对比表用，见 design.md §13）。
- `cases/bench/`：streaming vecadd（n=1024）和 64×64 int32 sgemm（ISA 没有 FPU，
  先用整数模拟），加 `make m5` 出 base / coal / full 对照表。

**验收**：64×64 int32 sgemm 跑通且逐元素和参考一致；访存合并后总线事务数相比
未合并版本下降 ≥ 4 倍（vecadd 读写各 4×，sgemm 读 4×）。

**状态**：已完成。`cases/bench/` 里是 streaming vecadd（n=1024）和 int32
sgemm 64×64（A 转置进 shared，内层 LDS 无 bank 冲突）；`make m5` 用 base / coal /
full 三种配置出对照表（design.md §12.11）：vecadd 的读+写事务下降到 1/4，
sgemm 的读事务下降到 1/4、写由 L1 从 4096 笔压到 256 笔；20 拍延迟下 full 相比
coal：vecadd 21086 → 14540 拍、sgemm 1075168 → 995036 拍。定向用例补了
`directed/coalesce`（同 line 合并 / 同 word 冲突写 / 跨 line）和 `directed/smem_conflict`
（4 轮 bank 冲突 + 同地址广播），越界由 `errors/gmem_oob` 覆盖。`make rtl-sim` 30 PASS。
4 lane + 默认配置的综合结果 WNS +0.538 ns @200 MHz（LUT 32.3K、BRAM 16），
§1 的面积预算跟着放宽到 35K LUT（P6 加了主机接口/512-bit master 之后是
33.2K LUT、WNS +0.523 ns，见 design.md §12.6）。

## P6 — 上板 U250

**目标**：把 GPU 变成一张真正的加速卡。

**交付物**

- `rtl/top/SK_ctrl.sv`：AXI-Lite 控制口（§5.6 的寄存器表、IMEM 装载口、调试扫描口，
  多 block 的启动序列）。
- `rtl/top/SK_top.sv`：`SK_ctrl` + `SK_core` + AXI 主口，仿真和上板共用的一层。
- `rtl/top/SK_afu.sv`：Vitis RTL kernel 壳（`ap_clk`/`ap_rst_n` + 标准控制口 +
  512-bit AXI 主口）。
- `syn/u250/`：`v++` 打包脚本（kernel → `.xo` → `.xclbin`）。
- `sw/runtime/`：XRT 原生 API 主机程序，负责装载 IMEM、写参数、轮询 done/error。
- `sw/tests/`：vecadd → sgemm 逐个上板验证。
- 目标机准备：XRT + 4.1 shell + 部署包；确认 `host-mem` 和时钟，先按 200 MHz 跑通。

**验收**：U250 上跑通 sgemm，结果与仿真逐字节一致，并记录实际频率与资源占用。

**限制**：U250 上只有单条 DDR4 通道（16 GB，约 19 GB/s），工作集要压小。

**状态**：P6.1（主机接口）和 P6.2（512-bit AXI + `GMEM_BASE`）已完成：

- `SK_ctrl`/`SK_top`/`SK_afu` 落地，仿真 testbench 改成走 AXI-Lite 主机流程
  （写 IMEM、写参数、start、轮询 done、扫描口读状态），
  `make rtl-sim` 33 PASS / 0 SKIP / 0 FAIL（新增 `directed/grid2` 多 block、
  `directed/gmem_base` 64 位基址、`errors/bad_launch`）。
- master 改成 512-bit、一次一整行 64 B：上游（coalescer 组 / L1 整行）压成
  len=0、size=6 的事务，读回来再切片；`GMEM_BASE`（主机写 0x30/0x34）加到核内
  32 位偏移上——U250 的 BO 地址可能超过 4 GB。M5 的数字按新口径重测过（§12.11）。
- P6.3：`.xo` 能稳定产出（Vivado `package_xo` 流程，手写 RTL 不能走 `v++ -c`）。
  布线阶段试了 7 条链接，只有 **150 MHz + SLR2 + DDR[1]** 这条收敛：
  `build/u250_150/skein.xclbin`（44 MB，时序 WNS +0.012 ns / WHS +0.010 ns @150 MHz）；
  同样配置在 200 MHz（不钉 SLR / SLR0 / SLR2 / SLR3）全部 "Kernel link failed to
  complete"。原因见 practice.md §2.4：CU 连 `DDR[0]` 会落在最挤的 SLR0，200 MHz
  下布线拥堵等级 6 收不住；降到 150 MHz 既松了时序也松了布线。
- P6.4（上板）**完成**：`build/u250_150/skein.xclbin` 在 U250 上跑通——
  smoke（寄存器读写 + SHAPE=0x0404）PASS、vecadd n=1024 PASS（20474 cycles /
  4160 retired）、sgemm64 PASS（1016740 cycles / 696616 retired，4096 个输出全对）。
  数字和踩坑写在 design.md §12.12、practice.md §2.6/§2.7（DFX-2RP 的 shell 分区
  编程、BO 的 memory group、CU 独占访问）。
- `sw/runtime/skein_run.cpp`（XRT 主机程序：寄存器写 IMEM/参数、轮询 done、用和 case
  一样的生成器比对 vecadd/sgemm64）已在板卡机上编译通过，`build/board/{vecadd,sgemm64}.bin`
  用 `skein-asm` 从 case 的 kernel 编出。
- 后备手段：L1 + coalescer 关掉（`SK_L1=0 SK_COALESCE=0`）后核从 33.2K LUT 降到
  27.4K LUT、BRAM 16→8（`syn/synth_area.tcl` 量的）。这个精简配置在 Verilator 模型上
  跑完整 case 集也是 33 PASS / 0 SKIP / 0 FAIL，所以可以作为上板的后备 `.xo`
  （`syn/u250/build_xo_lean.sh`），只是访存慢。
- 编译与上板环境已验过：v++ 2022.1 + U250 平台；XRT 2.21.75 + shell 4.1 + Ready。

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

面积/时序扫描用 `make synth`（`syn/synth_core.tcl`）：在 xcu250 上按 `SYN_LANES`
（默认 `4 8 16`）各综合一遍（`opt_design` 为止，只有综合后的 WNS 估计），
LUT/FF/DSP/URAM 和 WNS 落在 `build/syn/lanes*/`。它是手动目标，不进 `regress`。

内存层次的对照实验用 `make m5`：同一个 testbench 按 `SK_COALESCE`/`SK_L1` 编出
base / coal / full 三份模型，跑 `cases/bench/`，把 cycles、IPC、AXI 事务/字节/等待、
L1 命中率和 LDS replay 写进 `build/m5/report.txt`（AXI 延迟按 DDR4 的 20 拍算）。
也是手动目标，不进 `regress`；结论抄在 design.md §12.11。

### case（双仿真器对拍）

`cases/` 下的 `*.toml` 是唯一的用例输入描述：黄金模型和 RTL testbench 吃同一份，
`make rtl-sim` 逐个跑，`skein-case` 负责比对并汇总。case 在报告里的名字是它相对
`cases/` 的路径（`directed/sum`、`kernels/vecadd/warp4`），`program` 之类的路径相对
case 文件本身解析。

```
cases/
  directed/          单条指令或小序列的定向用例（单 warp × 4 lane，RTL 全跑）
  errors/            错误码：保留编码、非对齐、取指越界（只比 status/trap）
  kernels/<kernel>/  真 kernel 的用例，按 kernel 分目录（vecadd / matmul / mask）
  bench/             M5 的对照负载（streaming vecadd、sgemm64），也进回归
```

```toml
program = "sum.s"           # 或 words = [0x3b, 0x3a]（汇编器编不出的编码）
warpsz = 4                  # 默认 4 = SK_NUM_LANES（RTL 的硬件 warp 大小）
nwarp = 1                   # 默认 4（黄金模型模拟的机器容量；RTL 是 4）
block_dim = 4               # 可选，默认用满容量（nwarp × warpsz）；RTL 按它激活 warp
grid = 1
max_steps = 100000          # 可选，黄金模型的步数上限
max_cycles = 200000         # 可选，RTL 的时钟上限（默认 testbench 的 200000）

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

`[expect]` 只放语义和形状上的期望；IPC 这种吞吐指标不写进 case，跑完从报告里看
（`make rtl-sim` 每行都带 IPC，`--stats` 再展开计数器）。

- 形状：`skein-case` 先用 `tb_core --print-shape` 问一次核的容量（来自
  `SK_ctrl` 的 `SHAPE` 寄存器，就是核的 `shape_o`），`warpsz` 对不上、`block_dim`
  超过一次能激活的线程数、或者 `nwarp` 超过硬件容量的 case 报 SKIP 并注明原因；
  runner 和 Makefile 里都不写死 lane 数。P6 起 RTL 按 `GRID_DIM` 串行跑多 block，
  `grid > 1` 的 case 也进回归（`directed/grid2`）。
- 主机流程在仿真里就验：`tb_core` 不直接驱动核，而是像板上 XRT 一样写 AXI-Lite
  控制寄存器（写 IMEM、写参数、写 `CTRL.start`、轮询 done），状态和计数器从调试
  扫描口读——寄存器映射、IMEM 装载、start/done 握手在上板前就被回归覆盖了。
- `make rtl-sim`：每个 case 先跑黄金模型、再跑 RTL，逐项比 status / pc / `M` / GPR /
  谓词 / `[[check]]` 窗口，外加 RTL 的 `INST_RETIRED` 和黄金模型的 `steps`、
  `BARRIERS` 和黄金模型的屏障次数，以及 15 个指令分类的 retired 计数和黄金模型的
  `op_counts` 逐类对拍。
- 黄金模型报错（`status != OK`）时只比 status 和 trap（`SK_core` 里"停在哪条 warp
  的哪个 PC"的寄存器）：出错之后哪些 lane 已经提交、内存写进去多少属于实现行为，
  不是架构契约（[design.md](design.md) §5.5），逐字节比只会得到假 FAIL。报告里会
  标出"只比 status/trap"。
- 最后打印 PASS/SKIP/FAIL 计数和每个 case 的 RTL 周期数、IPC；加 `--stats` 还能看
  发射 / 提交 / 重发 / 没发射 / LSU 排队，以及 LDS/STS/AXI/L1 的分解（IPC 曲线、
  "为什么只有 0.6"、事务数都从这里看）。
- 核容量比 case 大时（4 条 warp 的核跑单 warp 用例），多出来的 warp 必须是"没跑过"
  的样子（pc = 0、`M` = 完整 mask、GPR/谓词全 0），否则报 FAIL。
- `make test` 里的 `tests/cases.rs` 不依赖 Verilator：每个 case 都跑一遍黄金模型并检查
  `[expect]`，保证 case 本身是有效的测试。
- 调试单个 case：`cargo run --bin skein-run -- --case cases/directed/sum.toml --trace`；
  RTL 侧 `build/obj_core/tb_core --image … --dump-state state.json` 看状态快照。
- 看波形：`make wave CASE=cases/directed/sum.toml` 直接跑一个 case 并把 FST 写到
  `build/sum.fst`（`WAVE=` 改路径）；要手动跑单个 bin，就用 `make tb-trace` 出来的
  `build/obj_core_trace/tb_core_trace --dump-wave out.fst`。FST 用 GTKWave 打开。

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
跑完 dump 出状态快照（每个 warp 的 pc、GPR、谓词、`M`、出错时的 trap + case 声明的
内存窗口），和黄金模型逐项比。不一致时打印寄存器号/lane/地址、期望值和实际值。

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
