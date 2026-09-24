# Skein

Skein 是一个从零手写的小型 SIMT 处理器（GPGPU），目标是把 FPGA 加速器的完整流程走一遍：
指令集定义 → RTL 实现 → 仿真验证 → 时序/面积收敛 → Alveo U250 上板。

指令集是自己设计的 32 位定长 ISA，不依赖现成编译器；kernel 用手写汇编，配一个
Python 汇编器和一个黄金模型。目前项目里只有设计文档，处在 P0 起步阶段。

## 目标

- 一个真正能跑的 SIMT 处理器：多 warp、warp 调度、mask 管理的分歧与重聚、屏障、访存合并。
- 完整闭环：黄金模型 → Verilator 仿真 → Vivado 综合 → Vitis RTL kernel → XRT 上板。
- 每个阶段结束时都有一个能演示的结果。

## 不做什么

图形管线、虚拟内存、精确异常、多核一致性、原子操作；张量单元留到 P7。
暂时不做高级编译器（控制流 lowering 由汇编器完成）、不做统一编址、不做字节/半字
访存、不做 cache（P5 视情况再加）。取舍理由记在[设计说明书](docs/design.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/design.md](docs/design.md) | 设计说明书：ISA、执行模型、mask 控制流、存储、关键决策 |
| [docs/plan.md](docs/plan.md) | 阶段计划与验证方法：P0–P7 的交付物、验收标准 |
| [docs/practice.md](docs/practice.md) | 工程手册：RTL 编码规范、U250 上板 |

文档里出现的 `rtl/`、`sim/`、`tb/`、`syn/`、`sw/` 都是计划中的项目结构，
随对应阶段创建。

## 命名

RTL 模块前缀 `SK_`，文件名与模块名一致（例如 `SK_scoreboard.sv`）。
