# Skein 顶层入口。阶段划分和验收标准见 docs/plan.md。
CARGO  ?= cargo
SRC    ?= cases/kernels/vecadd/vecadd.s
BUILD  ?= build
ARGS   ?=
K      ?=
KERNEL := $(basename $(notdir $(SRC)))
RTL_SRCS := rtl/SK_pkg.sv $(wildcard rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv)
RTL_TOP  ?= SK_core
RTL_TB   := $(BUILD)/obj_core/tb_core
RTL_TB_TRACE := $(BUILD)/obj_core_trace/tb_core_trace
CASES    ?= cases
CASE     ?=
WAVE     ?= $(BUILD)/$(basename $(notdir $(CASE))).fst

.PHONY: help asm sim test lint rtl-lint rtl-sim tb-trace wave regress clean

help:
	@echo "make asm [SRC=...]   汇编 kernel 到 $(BUILD)/<kernel>.bin"
	@echo "make sim [SRC=...]   先汇编再用黄金模型跑，ARGS 透传（--trace/--set ...）"
	@echo "make test            跑 Rust 测试（ISA / lowering），K 过滤关键字"
	@echo "make lint            cargo fmt --check + clippy"
	@echo "make rtl-lint        verilator --lint-only 查 RTL"
	@echo "make rtl-sim         编译 Verilator 模型，跑 $(CASES)/ 的用例，与黄金模型对拍"
	@echo "make tb-trace        编译带 FST 波形的模型：tb_core_trace --dump-wave <file.fst>"
	@echo "make wave            跑单个 case 并存波形：make wave CASE=cases/directed/sum.toml"
	@echo "make regress         lint + test + rtl-lint + rtl-sim"
	@echo "make clean           清理构建产物"

$(BUILD):
	mkdir -p $(BUILD)

asm:
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-asm -- \
	    $(SRC) -o $(BUILD)/$(KERNEL).bin

sim: asm
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-run -- \
	    $(BUILD)/$(KERNEL).bin $(ARGS)

test:
	$(CARGO) test --manifest-path tools/Cargo.toml $(K)

lint:
	$(CARGO) fmt --manifest-path tools/Cargo.toml --check
	$(CARGO) clippy --manifest-path tools/Cargo.toml --all-targets -- -D warnings

rtl-lint:
	verilator --lint-only -Wall --top-module $(RTL_TOP) -Irtl $(RTL_SRCS)

$(RTL_TB): $(RTL_SRCS) tb/tb_core.cpp | $(BUILD)
	verilator --cc --exe --build -j 4 -Wall --top-module $(RTL_TOP) -Irtl \
	    -Mdir $(BUILD)/obj_core -o tb_core $(RTL_SRCS) tb/tb_core.cpp

# case 驱动的双仿真器对拍：golden 在 skein-case 里跑，RTL 由它调 $(RTL_TB)
rtl-sim: $(RTL_TB)
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-case -- \
	    --rtl-tb $(RTL_TB) $(CASES)

# 带波形的模型单独一份；regress 跑的仍然是不带 trace 的轻量版
$(RTL_TB_TRACE): $(RTL_SRCS) tb/tb_core.cpp | $(BUILD)
	verilator --cc --exe --build -j 4 -Wall --top-module $(RTL_TOP) -Irtl \
	    --trace-fst --trace-structs \
	    -Mdir $(BUILD)/obj_core_trace -o tb_core_trace $(RTL_SRCS) tb/tb_core.cpp

tb-trace: $(RTL_TB_TRACE)

# 手动跑一个 case 并 dump 波形：make wave CASE=cases/directed/sum.toml [WAVE=build/sum.fst]
wave: $(RTL_TB_TRACE)
	@test -n "$(CASE)" || { echo "用法：make wave CASE=<cases/.../x.toml> [WAVE=<file.fst>]"; exit 1; }
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-case -- \
	    --rtl-tb $(RTL_TB_TRACE) --wave $(WAVE) $(CASE)

regress: lint test rtl-lint rtl-sim

clean:
	rm -rf $(BUILD) obj_dir tools/target
