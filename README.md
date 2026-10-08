# Skein

Skein 是一个从零手写的小型 SIMT 处理器（GPGPU），目标是把 FPGA 加速器的完整流程走一遍：
指令集定义 → RTL 实现 → 仿真验证 → 时序/面积收敛 → Alveo U250 上板。

指令集是自己设计的 32 位定长 ISA，不依赖现成编译器；kernel 用手写汇编，配一个
汇编器和一个黄金模型。ISA 编码已经冻结（[design.md](docs/design.md) §5）；汇编器、
黄金模型和测试在 `tools/`（Rust），核在 `rtl/`（P3 完成：4 warp × 4 lane、5 级流水、
非阻塞访存），两者用同一份程序逐寄存器对拍。

## 快速上手

```bash
make test                                                        # Rust 测试：ISA + kernel
make asm SRC=cases/kernels/vecadd/vecadd.s                       # 汇编成 build/vecadd.bin
make sim SRC=cases/kernels/vecadd/vecadd.s ARGS="--trace"        # 在黄金模型里跑
make sim SRC=cases/kernels/vecadd/vecadd.s ARGS="--help"         # 两个工具的完整选项（clap 生成）
make rtl-sim                                                    # 把 cases/ 逐个送进 RTL 和黄金模型对拍
make tb-trace                                                   # 编译带 FST 波形的模型（手动跑 tb_core_trace）
make wave CASE=cases/directed/sum.toml                          # 跑单个 case，波形 dump 到 build/sum.fst
make synth                                                       # 按 lane 数扫综合/实现（Vivado，几分钟起步）
make m5                                                          # M5 对照：base / coal / full 三种内存配置
make regress                                                    # 上面全跑一遍：fmt + clippy + test + lint + 仿真
```

`make rtl-sim` 每行是 `case 名 + cycles + IPC`（`--stats` 还能看发射 / 提交 / 重发 /
没发射 / LSU 排队 / LDS / AXI / L1 的分解），30 个 case 全 PASS。想单独看某个 case：

```bash
cargo run --manifest-path tools/Cargo.toml --bin skein-case -- \
    --rtl-tb build/obj_core/tb_core --stats cases/kernels/vecadd/warp4.toml
```

## 目标

- 一个真正能跑的 SIMT 处理器：多 warp、warp 调度、mask 管理的分歧与重聚、屏障、访存合并。
- 完整闭环：黄金模型 → Verilator 仿真 → Vivado 综合 → Vitis RTL kernel → XRT 上板。
- 每个阶段结束时都有一个能演示的结果。

## 不做什么

图形管线、虚拟内存、精确异常、多核一致性、原子操作；张量单元留到 P7。
暂时不做高级编译器（控制流和 mask 序列手写）、不做统一编址、不做字节/半字
访存、不做多级 cache（P5 只有一个 16 KB 的 L1）。取舍理由记在[设计说明书](docs/design.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/design.md](docs/design.md) | 设计说明书：ISA、执行模型、mask 控制流、存储、关键决策 |
| [docs/plan.md](docs/plan.md) | 阶段计划与验证方法：P0–P7 的交付物、验收标准 |
| [docs/practice.md](docs/practice.md) | 工程手册：RTL 编码规范、U250 上板 |

## 目录结构

```
rtl/       可综合 RTL。lib/ 通用原语，core/ 译码执行提交与 SK_core，sched/ warp
           调度与 scoreboard，mem/ IMEM、4 bank shared、coalescer、16 KB L1 与
           AXI4 master，top/ 上板壳；SK_config.vh 是全局参数，SK_pkg.sv 是公共类型
tools/     Rust 工具链（一个 cargo crate）：src/isa.rs 编码定义、src/asm.rs 汇编器
           （一行一条指令）、src/golden.rs 黄金模型、src/case.rs 用例加载、
           src/bin/ 里的 skein-asm / skein-run / skein-case（命令行用 clap）、
           tests/ 测试
cases/     用例：程序 + launch 形状 + 初态 + 比对窗口，golden 和 RTL 共用（*.toml）；
           directed/ 定向、errors/ 错误码、kernels/<kernel>/ 按 kernel 分目录
           （kernel 汇编源码和它的用例放一起）、bench/ 是 M5 的对照负载
tb/        Verilator testbench：tb_top = SK_core + tb_axi_mem（AXI 从机 + 内存模型），
           tb_core.cpp 喂输入、跑、dump 状态；--print-shape 报核的形状，skein-case
           用它决定哪些 case 能跑
syn/       综合脚本：synth_core.tcl 按 lane 数扫面积/时序；u250/ 是 P6 的 v++ 打包
           脚本与链接配置
sw/        主机程序：runtime/ XRT 驱动、tests/ 上板用例
```

每个文件在对应阶段创建，清单见 [docs/plan.md](docs/plan.md)。

## 命名

RTL 模块前缀 `SK_`，文件名与模块名一致（例如 `SK_scoreboard.sv`）。
