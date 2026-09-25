# Skein 顶层入口。阶段划分和验收标准见 docs/plan.md。
CARGO  ?= cargo
SRC    ?= sim/kernels/vecadd.s
BUILD  ?= build
ARGS   ?=
K      ?=
KERNEL := $(basename $(notdir $(SRC)))
RTL_SRCS := rtl/SK_pkg.sv $(wildcard rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv)
RTL_TOP  ?= SK_core

.PHONY: help asm sim test lint rtl-lint regress clean

help:
	@echo "make asm [SRC=...]   汇编 kernel 到 $(BUILD)/<kernel>.bin"
	@echo "make sim [SRC=...]   先汇编再用黄金模型跑，ARGS 透传（--trace/--set ...）"
	@echo "make test            跑 Rust 测试（ISA / lowering），K 过滤关键字"
	@echo "make lint            cargo fmt --check + clippy"
	@echo "make rtl-lint        verilator --lint-only 查 RTL"
	@echo "make regress         lint + test + rtl-lint"
	@echo "make clean           清理构建产物"

asm:
	$(CARGO) run --quiet --manifest-path sim/Cargo.toml --bin skein-asm -- \
	    $(SRC) -o $(BUILD)/$(KERNEL).bin

sim: asm
	$(CARGO) run --quiet --manifest-path sim/Cargo.toml --bin skein-run -- \
	    $(BUILD)/$(KERNEL).bin $(ARGS)

test:
	$(CARGO) test --manifest-path sim/Cargo.toml $(K)

lint:
	$(CARGO) fmt --manifest-path sim/Cargo.toml --check
	$(CARGO) clippy --manifest-path sim/Cargo.toml --all-targets -- -D warnings

rtl-lint:
	verilator --lint-only -Wall --top-module $(RTL_TOP) -Irtl $(RTL_SRCS)

regress: lint test rtl-lint

clean:
	rm -rf $(BUILD) obj_dir sim/target
