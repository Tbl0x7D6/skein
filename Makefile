# Skein 顶层入口。阶段划分和验收标准见 docs/plan.md。
CARGO  ?= cargo
SRC    ?= cases/kernels/vecadd/vecadd.s
BUILD  ?= build
ARGS   ?=
K      ?=
VIVADO ?= $(firstword $(wildcard /tools/Xilinx/Vivado/*/bin/vivado) vivado)
SYN_LANES ?= 4 8 16
KERNEL := $(basename $(notdir $(SRC)))
RTL_SRCS := rtl/SK_pkg.sv $(wildcard rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv rtl/sched/*.sv rtl/perf/*.sv)
TB_SRCS  := tb/tb_top.sv tb/tb_axi_mem.sv
RTL_TOP  ?= SK_core
TB_TOP   ?= tb_top
RTL_TB   := $(BUILD)/obj_core/tb_core
RTL_TB_TRACE := $(BUILD)/obj_core_trace/tb_core_trace
CASES    ?= cases
CASE     ?=
WAVE     ?= $(BUILD)/$(basename $(notdir $(CASE))).fst

.PHONY: help asm sim test lint rtl-lint rtl-sim tb-trace wave synth m5 regress clean

help:
	@echo "make asm [SRC=...]   汇编 kernel 到 $(BUILD)/<kernel>.bin"
	@echo "make sim [SRC=...]   先汇编再用黄金模型跑，ARGS 透传（--trace/--set ...）"
	@echo "make test            跑 Rust 测试（ISA / lowering），K 过滤关键字"
	@echo "make lint            cargo fmt --check + clippy"
	@echo "make rtl-lint        verilator --lint-only 查 RTL"
	@echo "make rtl-sim         编译 Verilator 模型，跑 $(CASES)/ 的用例，与黄金模型对拍"
	@echo "make tb-trace        编译带 FST 波形的模型：tb_core_trace --dump-wave <file.fst>"
	@echo "make wave            跑单个 case 并存波形：make wave CASE=cases/directed/sum.toml"
	@echo "make synth           按 lane 数扫综合/实现（SYN_LANES=\"4 8 16\"），报告在 $(BUILD)/syn/"
	@echo "make m5              跑 M5 对照（base/coal/full 三种配置），报告在 $(BUILD)/m5/report.txt"
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
	verilator --lint-only -Wall --top-module $(TB_TOP) -Irtl -Itb $(RTL_SRCS) $(TB_SRCS)

$(RTL_TB): $(RTL_SRCS) $(TB_SRCS) tb/tb_core.cpp | $(BUILD)
	verilator --cc --exe --build -j 4 -Wall --top-module $(TB_TOP) -Irtl -Itb \
	    -Mdir $(BUILD)/obj_core -o tb_core $(RTL_SRCS) $(TB_SRCS) tb/tb_core.cpp

# case 驱动的双仿真器对拍：golden 在 skein-case 里跑，RTL 由它调 $(RTL_TB)
rtl-sim: $(RTL_TB)
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-case -- \
	    --rtl-tb $(RTL_TB) $(CASES)

# 带波形的模型单独一份；regress 跑的仍然是不带 trace 的轻量版
$(RTL_TB_TRACE): $(RTL_SRCS) $(TB_SRCS) tb/tb_core.cpp | $(BUILD)
	verilator --cc --exe --build -j 4 -Wall --top-module $(TB_TOP) -Irtl -Itb \
	    --trace-fst --trace-structs \
	    -Mdir $(BUILD)/obj_core_trace -o tb_core_trace $(RTL_SRCS) $(TB_SRCS) tb/tb_core.cpp

tb-trace: $(RTL_TB_TRACE)

# lane 数扫描：只用来决定 SK_NUM_LANES，不进 regress
synth:
	@for lanes in $(SYN_LANES); do \
	    echo "--- lanes=$$lanes"; \
	    $(VIVADO) -mode batch -nojournal -nolog -source syn/synth_core.tcl \
	        -tclargs $$lanes $(BUILD)/syn/lanes$$lanes || exit 1; \
	done

# 手动跑一个 case 并 dump 波形：make wave CASE=cases/directed/sum.toml [WAVE=build/sum.fst]
wave: $(RTL_TB_TRACE)
	@test -n "$(CASE)" || { echo "用法：make wave CASE=<cases/.../x.toml> [WAVE=<file.fst>]"; exit 1; }
	$(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-case -- \
	    --rtl-tb $(RTL_TB_TRACE) --wave $(WAVE) $(CASE)

# M5：coalescer / L1 的对照表。三种配置各编一个模型，跑 cases/bench/，AXI 延迟按 20 拍算：
#   base = 不合并不缓存（每 lane 一笔事务）
#   coal = 只开 coalescer，L1 关
#   full = 默认配置（coalescer + 16 KB L1 写回）
m5:
	@mkdir -p $(BUILD)/m5
	@for mode in base coal full; do \
	    case $$mode in \
	        base) defs="-DSK_COALESCE=0 -DSK_L1=0" ;; \
	        coal) defs="-DSK_COALESCE=1 -DSK_L1=0" ;; \
	        full) defs="" ;; \
	    esac; \
	    echo "=== $$mode"; \
	    verilator --cc --exe --build -j 4 -Wall --top-module $(TB_TOP) -Irtl -Itb $$defs \
	        -Mdir $(BUILD)/obj_m5_$$mode -o tb_m5_$$mode \
	        $(RTL_SRCS) $(TB_SRCS) tb/tb_core.cpp \
	        > $(BUILD)/m5/$$mode.build.log 2>&1 || { cat $(BUILD)/m5/$$mode.build.log; exit 1; }; \
	    $(CARGO) run --quiet --manifest-path tools/Cargo.toml --bin skein-case -- \
	        --rtl-tb $(BUILD)/obj_m5_$$mode/tb_m5_$$mode --axi-latency 20 --stats $(CASES)/bench; \
	done | tee $(BUILD)/m5/report.txt

regress: lint test rtl-lint rtl-sim

clean:
	rm -rf $(BUILD) obj_dir tools/target
