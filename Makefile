# Skein 顶层入口。阶段划分和验收标准见 docs/plan.md。
CARGO  ?= cargo
SRC    ?= sim/kernels/vecadd.s
BUILD  ?= build
ARGS   ?=
K      ?=
KERNEL := $(basename $(notdir $(SRC)))
RTL_SRCS := rtl/SK_pkg.sv $(wildcard rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv)
RTL_TOP  ?= SK_core
RTL_TB   := $(BUILD)/obj_core/tb_core

# P1 的单 lane 测试：汇编出来的 5 个程序，加两个手工编的错误码用例
P1_PROGS := p1_sum p1_alu p1_if_else p1_mem p1_sreg
P1_BAD   := p1_bad
P1_OOB   := p1_oob
P1_RAW   := $(P1_BAD) $(P1_OOB)
P1_CASES := $(P1_PROGS) $(P1_RAW)
P1_SET   := --set PTR_A=0x1000 --set PTR_B=0x2000 --set PTR_C=0x3000 --set ARG0=42
P1_BINS  := $(addprefix $(BUILD)/,$(addsuffix .bin,$(P1_CASES)))
P1_GOLDEN := $(addprefix $(BUILD)/,$(addsuffix .golden.json,$(P1_CASES)))
P1_ASM_BINS := $(addprefix $(BUILD)/,$(addsuffix .bin,$(P1_PROGS)))

.PHONY: help asm sim test lint rtl-lint rtl-sim regress clean

help:
	@echo "make asm [SRC=...]   汇编 kernel 到 $(BUILD)/<kernel>.bin"
	@echo "make sim [SRC=...]   先汇编再用黄金模型跑，ARGS 透传（--trace/--set ...）"
	@echo "make test            跑 Rust 测试（ISA / lowering），K 过滤关键字"
	@echo "make lint            cargo fmt --check + clippy"
	@echo "make rtl-lint        verilator --lint-only 查 RTL"
	@echo "make rtl-sim         编译 Verilator 模型，跑 P1 的单 lane 用例，与黄金模型对拍"
	@echo "make regress         lint + test + rtl-lint + rtl-sim"
	@echo "make clean           清理构建产物"

$(BUILD):
	mkdir -p $(BUILD)

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

# 静态模式规则：产物是显式目标，不会被 make 当中间文件删掉
$(P1_ASM_BINS): $(BUILD)/%.bin: tb/programs/%.s | $(BUILD)
	$(CARGO) run --quiet --manifest-path sim/Cargo.toml --bin skein-asm -- $< -o $@

# 汇编器不给编非法/越界的程序，这两个镜像直接写字节：
#   p1_bad：0x3B 是保留编码（类 11_1 的空子码），后面跟 EXIT -> BAD_INSN
#   p1_oob：JMP +4096 跳出 IMEM -> PC_OOB
$(BUILD)/$(P1_BAD).bin: | $(BUILD)
	printf '\073\000\000\000\072\000\000\000' > $@

$(BUILD)/$(P1_OOB).bin: | $(BUILD)
	printf '\062\000\004\000' > $@

# 黄金模型的状态 dump；出错结束时 skein-run 返回非 0，只要 dump 写出来就行
$(P1_GOLDEN): $(BUILD)/%.golden.json: $(BUILD)/%.bin
	$(CARGO) run --quiet --manifest-path sim/Cargo.toml --bin skein-run -- \
	    $< --warpsz 1 --nwarp 1 $(P1_SET) --dump-state $@ > /dev/null; test -s $@

$(RTL_TB): $(RTL_SRCS) tb/tb_core.cpp | $(BUILD)
	verilator --cc --exe --build -j 4 -Wall --top-module $(RTL_TOP) -Irtl \
	    -Mdir $(BUILD)/obj_core -o tb_core $(RTL_SRCS) tb/tb_core.cpp

rtl-sim: $(RTL_TB) $(P1_BINS) $(P1_GOLDEN)
	@for p in $(P1_CASES); do \
	    $(RTL_TB) $(BUILD)/$$p.bin --expect $(BUILD)/$$p.golden.json $(P1_SET) || exit 1; \
	done

regress: lint test rtl-lint rtl-sim

clean:
	rm -rf $(BUILD) obj_dir sim/target
