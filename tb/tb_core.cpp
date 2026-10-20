//! Verilator testbench（顶层是 tb_top：AXI-Lite 主机 + SK_top + AXI 从机内存模型）。
//!
//! 这里不做比对——`skein-case`（tools/src/bin/skein-case.rs）把这份 dump 和黄金模型逐项
//! 比对。testbench 只负责：装载 IMEM 镜像和 shared/global 初态、驱动特殊寄存器、
//! 跑到 done 或者报错，然后按 --mem-window 把架构状态、性能计数器和内存窗口写成 JSON，
//! 字段和 `skein-run --dump-state` 对齐（多一个 "mem"、"perf" 和 "fault"）。
//!
//! 和板上一致的主机流程：IMEM 镜像、参数、start 全部走 AXI-Lite 控制寄存器（`SK_ctrl`），
//! done/STATUS 也从控制寄存器轮询；架构状态和性能计数器从调试扫描口读。
//! global memory 走核的 AXI4 主口，由 tb_axi_mem.sv 应答，主机侧通过它的 host 口装初态、
//! 读回比对窗口；shared memory 在核内，用 testbench 专用口装初态 / 读快照。
//!
//! 用法：
//!   tb_core --image <image.bin> [--bdim N] [--grid N] [--nwarp N] [--set NAME=VALUE]...
//!           [--gmem-init ADDR FILE]... [--smem-init ADDR FILE]...
//!           [--mem-window SPACE ADDR WORDS]... [--max-cycles N] [--trace]
//!           [--axi-rd-latency N] [--axi-wr-latency N]
//!           [--dump-state <file>] [--dump-wave <file.fst>]
//!   tb_core --print-shape                      # 只打印核的形状，不跑
//!
//! 形状来自控制寄存器的 SHAPE（就是核的 `shape_o`）：warp 大小 `SK_NUM_LANES`、
//! warp 数 `SK_NUM_WARPS`；`max_grid` 是 GRID_DIM 字段的宽度（多 block 串行跑）。
//! `skein-case` 先用 `--print-shape` 探形状，超过这个形状的 case 报 SKIP。
//! `NWARP`/`WARPSZ` 固定报硬件容量；`--nwarp` 只决定 dump 几条 warp（黄金模型是更小
//! 的机器时，多出来的 warp 不用比），`--bdim` 给 block 线程数、`--grid` 给 block 数。
//! `TID/LANEID/WID/BID` 由硬件按启动参数算。
//!
//! `--dump-wave` 要带波形支持的模型（`make tb-trace` 出来的 `tb_core_trace`），普通
//! 模型的时序逻辑不带 trace 代码，用它会直接报错。

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "Vtb_top.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_fst_c.h"
#endif

namespace {

// 和黄金模型的默认值保持一致（tools/src/case.rs 的 SMEM_BYTES / GMEM_BYTES）
constexpr uint32_t SMEM_BYTES = 32 * 1024;
constexpr uint32_t GMEM_BYTES = 1 << 20;

// 调试扫描口（见 rtl/core/SK_core.sv）
constexpr uint8_t DBG_M = 0x20;
constexpr uint8_t DBG_PRED = 0x21;
constexpr uint8_t DBG_PC_WARP = 0x22;
constexpr uint8_t DBG_STATUS = 0x23;
constexpr uint8_t DBG_INSN = 0x24;
constexpr uint8_t DBG_RUN = 0x25;
constexpr uint8_t DBG_PC_S4 = 0x26;
constexpr uint8_t DBG_S4_WID = 0x28;
constexpr uint8_t DBG_TRAP_VALID = 0x29;
constexpr uint8_t DBG_TRAP_WID = 0x2A;
constexpr uint8_t DBG_TRAP_PC = 0x2B;
constexpr uint8_t DBG_PERF = 0x30;
constexpr uint8_t DBG_CLASS = 0x44;

/// 性能计数器的下标（和 rtl/perf/SK_perf.sv 一致）。
constexpr int PERF_CYCLE = 0;
constexpr int PERF_ISSUED = 1;
constexpr int PERF_RETIRED = 2;
constexpr int PERF_REPLAY = 3;
constexpr int PERF_BARRIER = 4;
constexpr int PERF_STALL_NO_WARP = 5;
constexpr int PERF_LSU_BUSY = 6;
constexpr int PERF_LDS_TXN = 7;
constexpr int PERF_STS_TXN = 8;
constexpr int PERF_LDS_REPLAY = 9;
constexpr int PERF_AXI_RD_TXN = 10;
constexpr int PERF_AXI_WR_TXN = 11;
constexpr int PERF_AXI_RD_BEATS = 12;
constexpr int PERF_AXI_WR_BEATS = 13;
constexpr int PERF_AXI_STALL = 14;
constexpr int PERF_L1_RD_HIT = 15;
constexpr int PERF_L1_RD_MISS = 16;
constexpr int PERF_L1_WR_HIT = 17;
constexpr int PERF_L1_WR_MISS = 18;
constexpr int PERF_L1_WB = 19;
constexpr int NUM_PERF = 20;
constexpr int NUM_CLASS = 15;

// 特殊寄存器编号，和 tools/src/isa.rs 的 Sreg 一致
constexpr int SREG_TID = 0x00;
constexpr int SREG_LANEID = 0x01;
constexpr int SREG_WID = 0x02;
constexpr int SREG_WARPSZ = 0x03;
constexpr int SREG_NWARP = 0x04;
constexpr int SREG_GRID = 0x05;
constexpr int SREG_PTR_A = 0x06;
constexpr int SREG_PTR_B = 0x07;
constexpr int SREG_PTR_C = 0x08;
constexpr int SREG_ARG0 = 0x09;
constexpr int SREG_ARG1 = 0x0A;
constexpr int SREG_ARG2 = 0x0B;
constexpr int SREG_STATUS = 0x0C;
constexpr int SREG_BID = 0x0D;
constexpr int SREG_BLOCK_DIM = 0x0E;

constexpr int NUM_GPR = 32;
constexpr int NUM_PRED = 8;

/// AXI-Lite 控制寄存器偏移，和 rtl/top/SK_ctrl.sv / docs/design.md §5.6 一致。
constexpr uint32_t REG_CTRL = 0x000;
constexpr uint32_t REG_GRID = 0x010;
constexpr uint32_t REG_BLOCK_DIM = 0x014;
constexpr uint32_t REG_PTR_A = 0x018;
constexpr uint32_t REG_PTR_B = 0x01C;
constexpr uint32_t REG_PTR_C = 0x020;
constexpr uint32_t REG_ARG0 = 0x024;
constexpr uint32_t REG_ARG1 = 0x028;
constexpr uint32_t REG_ARG2 = 0x02C;
constexpr uint32_t REG_BASE_LO = 0x030;
constexpr uint32_t REG_BASE_HI = 0x034;
constexpr uint32_t REG_IMEM_ADDR = 0x038;
constexpr uint32_t REG_IMEM_DATA = 0x03C;
constexpr uint32_t REG_IMEM_WE = 0x040;
constexpr uint32_t REG_STATUS = 0x044;
constexpr uint32_t REG_SHAPE = 0x048;
constexpr uint32_t REG_DBG_ADDR = 0x04C;
constexpr uint32_t REG_DBG_SEL = 0x050;
constexpr uint32_t REG_DBG_DATA = 0x054;

/// 核的形状：warp 大小、warp 数、一次启动的 block 容量、block 数容量
/// （来自 `SK_core.shape_o`）。
struct Shape {
    uint32_t warpsz = 1;
    uint32_t nwarp = 1;
    uint32_t max_block_dim = 1;
    uint32_t max_grid = 1;
};

/// 跑完之后一条 warp 的架构状态。
struct WarpState {
    uint32_t wid = 0;
    uint32_t pc = 0;
    uint32_t m = 0;
    std::vector<std::vector<uint32_t>> gpr;
    std::vector<uint32_t> pred;
};

struct SregValue {
    int index = 0;
    uint32_t value = 0;
};

/// 一段初态：把 FILE 里的 32 位小端字写到 ADDR（字节地址）。
struct MemInit {
    bool smem = false;
    uint32_t addr = 0;
    std::string file;
};

/// 跑完要比对的内存窗口。
struct MemWindow {
    bool smem = false;
    uint32_t addr = 0;
    uint32_t words = 0;
};

struct Options {
    std::string image;
    std::vector<SregValue> sregs;
    std::vector<MemInit> inits;
    std::vector<MemWindow> windows;
    std::string state;
    std::string wave;
    long max_cycles = 200000;
    long bdim = -1;             // < 0 = 用满容量（0 是合法的"非法值"，要能原样传给硬件）
    long grid = 1;              // block 数（多 block 串行跑）
    long nwarp = 0;             // 0 = 报硬件容量
    long axi_rd_latency = 2;
    long axi_wr_latency = 2;
    uint64_t gmem_base = 0;      // 设备地址基址（0 = 用核内偏移当绝对地址）
    bool trace = false;
    bool print_shape = false;
};

void usage() {
    std::cerr << "用法：tb_core --image <image.bin> [--bdim N] [--nwarp N] [--set NAME=VALUE]... "
                 "[--gmem-init ADDR FILE]... [--smem-init ADDR FILE]... "
                 "[--mem-window SPACE ADDR WORDS]... [--max-cycles N] [--trace] "
                 "[--axi-rd-latency N] [--axi-wr-latency N] "
                 "[--dump-state <file>] [--dump-wave <file.fst>]\n"
                 "       tb_core --print-shape\n";
}

uint32_t parse_number(const std::string& text) {
    return (uint32_t)strtoul(text.c_str(), nullptr, 0);
}

/// 空间名 -> 是否 shared。
bool parse_space(const std::string& text, bool& smem) {
    if (text == "smem" || text == "shared") {
        smem = true;
        return true;
    }
    if (text == "gmem" || text == "global") {
        smem = false;
        return true;
    }
    std::cerr << "空间只能是 smem / gmem：" << text << "\n";
    return false;
}

/// 特殊寄存器名 -> 编号（只认主机能写的那些）。
int parse_sreg(const std::string& name, uint32_t value, SregValue& out) {
    std::string upper = name;
    for (char& ch : upper) {
        ch = (char)std::toupper((unsigned char)ch);
    }
    if (upper.rfind("S_", 0) == 0) {
        upper = upper.substr(2);
    }
    if (upper == "PTR_A") out.index = SREG_PTR_A;
    else if (upper == "PTR_B") out.index = SREG_PTR_B;
    else if (upper == "PTR_C") out.index = SREG_PTR_C;
    else if (upper == "ARG0") out.index = SREG_ARG0;
    else if (upper == "ARG1") out.index = SREG_ARG1;
    else if (upper == "ARG2") out.index = SREG_ARG2;
    else {
        std::cerr << "--set 只支持 PTR_A/PTR_B/PTR_C/ARG0/ARG1/ARG2：" << name << "\n";
        return 1;
    }
    out.value = value;
    return 0;
}

bool parse_args(int argc, char** argv, Options& opt) {
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        auto need = [&](int count) {
            if (i + count >= argc) {
                std::cerr << arg << " 后面还差参数\n";
                return false;
            }
            return true;
        };
        if (arg == "--image") {
            if (!need(1)) return false;
            opt.image = argv[++i];
        } else if (arg == "--set") {
            if (!need(1)) return false;
            std::string pair = argv[++i];
            size_t equal = pair.find('=');
            if (equal == std::string::npos) {
                std::cerr << "--set 的写法应为 NAME=VALUE：" << pair << "\n";
                return false;
            }
            SregValue sreg;
            if (parse_sreg(pair.substr(0, equal), parse_number(pair.substr(equal + 1)), sreg)) {
                return false;
            }
            opt.sregs.push_back(sreg);
        } else if (arg == "--gmem-init" || arg == "--smem-init") {
            if (!need(2)) return false;
            MemInit init;
            init.smem = (arg == "--smem-init");
            init.addr = parse_number(argv[++i]);
            init.file = argv[++i];
            opt.inits.push_back(init);
        } else if (arg == "--mem-window") {
            if (!need(3)) return false;
            MemWindow window;
            if (!parse_space(argv[++i], window.smem)) return false;
            window.addr = parse_number(argv[++i]);
            window.words = parse_number(argv[++i]);
            opt.windows.push_back(window);
        } else if (arg == "--max-cycles") {
            if (!need(1)) return false;
            opt.max_cycles = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--bdim") {
            if (!need(1)) return false;
            opt.bdim = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--grid") {
            if (!need(1)) return false;
            opt.grid = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--nwarp") {
            if (!need(1)) return false;
            opt.nwarp = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--axi-rd-latency") {
            if (!need(1)) return false;
            opt.axi_rd_latency = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--axi-wr-latency") {
            if (!need(1)) return false;
            opt.axi_wr_latency = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--gmem-base") {
            if (!need(1)) return false;
            opt.gmem_base = strtoull(argv[++i], nullptr, 0);
        } else if (arg == "--trace") {
            opt.trace = true;
        } else if (arg == "--print-shape") {
            opt.print_shape = true;
        } else if (arg == "--dump-state") {
            if (!need(1)) return false;
            opt.state = argv[++i];
        } else if (arg == "--dump-wave") {
            if (!need(1)) return false;
            opt.wave = argv[++i];
#if !VM_TRACE
            std::cerr << "这个模型没编波形：用 `make tb-trace` 出来的 tb_core_trace\n";
            return false;
#endif
        } else {
            std::cerr << "不认识的参数：" << arg << "\n";
            return false;
        }
    }
    if (opt.image.empty() && !opt.print_shape) {
        usage();
        return false;
    }
    return true;
}

/// 镜像/初态文件：每字 32 位小端。
bool load_words(const std::string& path, std::vector<uint32_t>& words) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        std::cerr << "打不开 " << path << "\n";
        return false;
    }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());
    if (bytes.size() % 4 != 0) {
        std::cerr << path << ": 不是 4 字节对齐的镜像\n";
        return false;
    }
    for (size_t i = 0; i < bytes.size(); i += 4) {
        words.push_back((uint32_t)bytes[i] | ((uint32_t)bytes[i + 1] << 8)
                        | ((uint32_t)bytes[i + 2] << 16) | ((uint32_t)bytes[i + 3] << 24));
    }
    return true;
}

/// 出错停机时的 trap（`SK_core.trap_*`）：正常结束 valid 为 false。
struct Trap {
    bool valid = false;
    uint32_t wid = 0;
    uint32_t pc = 0;
};

/// 状态 + 性能计数器 + 内存窗口写成 JSON（形状对齐 skein-run --dump-state）。
/// `windows` 是已经读好的各窗口数据，顺序和 `opt.windows` 一致。
bool write_state(const Options& opt, const Shape& shape, uint32_t status, long cycles,
                 const std::vector<WarpState>& warps, const uint32_t* perf,
                 const uint32_t* class_cnt, const Trap& trap,
                 const std::vector<std::vector<uint32_t>>& windows) {
    std::ofstream out(opt.state);
    if (!out) {
        std::cerr << "写不了 " << opt.state << "\n";
        return false;
    }
    out << "{\n";
    out << "  \"status\": " << status << ",\n";
    out << "  \"cycles\": " << cycles << ",\n";
    out << "  \"fault\": ";
    if (trap.valid) {
        out << "{\"wid\": " << trap.wid << ", \"pc\": " << trap.pc << "},\n";
    } else {
        out << "null,\n";
    }
    out << "  \"warpsz\": " << shape.warpsz << ",\n";
    out << "  \"nwarp\": " << shape.nwarp << ",\n";
    out << "  \"perf\": {";
    out << "\"cycles\": " << perf[PERF_CYCLE]
        << ", \"issued\": " << perf[PERF_ISSUED]
        << ", \"retired\": " << perf[PERF_RETIRED]
        << ", \"replay\": " << perf[PERF_REPLAY]
        << ", \"barriers\": " << perf[PERF_BARRIER]
        << ", \"stall_no_warp\": " << perf[PERF_STALL_NO_WARP]
        << ", \"lsu_busy\": " << perf[PERF_LSU_BUSY]
        << ", \"lds_txn\": " << perf[PERF_LDS_TXN]
        << ", \"sts_txn\": " << perf[PERF_STS_TXN]
        << ", \"lds_replay\": " << perf[PERF_LDS_REPLAY]
        << ", \"axi_rd_txn\": " << perf[PERF_AXI_RD_TXN]
        << ", \"axi_wr_txn\": " << perf[PERF_AXI_WR_TXN]
        << ", \"axi_rd_beats\": " << perf[PERF_AXI_RD_BEATS]
        << ", \"axi_wr_beats\": " << perf[PERF_AXI_WR_BEATS]
        << ", \"axi_stall\": " << perf[PERF_AXI_STALL]
        << ", \"l1_rd_hit\": " << perf[PERF_L1_RD_HIT]
        << ", \"l1_rd_miss\": " << perf[PERF_L1_RD_MISS]
        << ", \"l1_wr_hit\": " << perf[PERF_L1_WR_HIT]
        << ", \"l1_wr_miss\": " << perf[PERF_L1_WR_MISS]
        << ", \"l1_wb\": " << perf[PERF_L1_WB];
    out << ", \"class\": [";
    for (int i = 0; i < NUM_CLASS; i++) {
        out << (i ? ", " : "") << class_cnt[i];
    }
    out << "]},\n";
    out << "  \"warps\": [\n";
    for (size_t index = 0; index < warps.size(); index++) {
        const WarpState& warp = warps[index];
        out << "    {\n      \"wid\": " << warp.wid << ",\n      \"pc\": " << warp.pc
            << ",\n      \"m\": " << warp.m << ",\n";
        out << "      \"gpr\": [";
        for (size_t lane = 0; lane < warp.gpr.size(); lane++) {
            out << (lane ? ", [" : "[");
            for (size_t reg = 0; reg < warp.gpr[lane].size(); reg++) {
                out << (reg ? ", " : "") << warp.gpr[lane][reg];
            }
            out << "]";
        }
        out << "],\n      \"pred\": [";
        for (size_t lane = 0; lane < warp.pred.size(); lane++) {
            out << (lane ? ", [" : "[");
            for (int i = 0; i < NUM_PRED; i++) {
                out << (i ? ", " : "") << ((warp.pred[lane] >> i) & 1u);
            }
            out << "]";
        }
        out << "]\n    }" << (index + 1 == warps.size() ? "" : ",") << "\n";
    }
    out << "  ],\n";
    out << "  \"mem\": [\n";
    for (size_t index = 0; index < windows.size(); index++) {
        const MemWindow& window = opt.windows[index];
        out << "    {\"space\": \"" << (window.smem ? "smem" : "gmem") << "\", \"addr\": "
            << window.addr << ", \"words\": [";
        for (uint32_t offset = 0; offset < window.words; offset++) {
            uint32_t word = windows[index][offset];
            out << (offset ? ", " : "") << word;
        }
        out << "]}" << (index + 1 == opt.windows.size() ? "" : ",") << "\n";
    }
    out << "  ]\n}\n";
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt;
    if (!parse_args(argc, argv, opt)) {
        return 2;
    }

    VerilatedContext context;
    context.commandArgs(argc, argv);
    Vtb_top* dut = new Vtb_top{&context};

    // 复位状态：主机侧只驱动 AXI-Lite 命令口和内存的主机口
    dut->clk = 0;
    dut->aresetn = 0;
    dut->cmd_valid_i = 0;
    dut->cmd_wr_i = 0;
    dut->cmd_addr_i = 0;
    dut->cmd_wdata_i = 0;
    dut->smem_ld_we_i = 0;
    dut->smem_ld_addr_i = 0;
    dut->smem_ld_wdata_i = 0;
    dut->smem_rd_addr_i = 0;
    dut->smem_rd_en_i = 0;
    dut->host_we_i = 0;
    dut->host_addr_i = 0;
    dut->host_wdata_i = 0;
    dut->host_raddr_i = 0;
    // 端口是 8 bit：夹到量程内，别让 CLI 的越界值静默截断（P5 用过 4 bit 端口，
    // --axi-latency 20 被截成 4，M5 的"延迟 20 拍"名不副实）
    auto clamp_latency = [](long value) -> uint32_t {
        if (value < 0) return 0;
        if (value > 255) return 255;
        return static_cast<uint32_t>(value);
    };
    dut->rd_lat_i = clamp_latency(opt.axi_rd_latency);
    dut->wr_lat_i = clamp_latency(opt.axi_wr_latency);
    // 从机按这个基址解码（等于主机写进 GMEM_BASE 的值）；0 = 直接用偏移
    dut->addr_base_i = opt.gmem_base;
    dut->eval();

    // 波形：只有 trace 版模型（make tb-trace）才有，每个半周期 dump 一次
#if VM_TRACE
    std::unique_ptr<VerilatedFstC> fst;
    if (!opt.wave.empty()) {
        Verilated::traceEverOn(true);
        fst = std::make_unique<VerilatedFstC>();
        dut->trace(fst.get(), 99);
        fst->open(opt.wave.c_str());
    }
    vluint64_t wave_time = 0;
    auto dump_wave = [&]() {
        if (fst) {
            fst->dump(wave_time);
        }
        wave_time++;
    };
#else
    auto dump_wave = []() {};
#endif

    // 时钟和主机访问。AXI-Lite 的每一笔读写都要几个时钟，所以单独记 tick 数，
    // 报出来的 cycles 是"从写 CTRL.start 到看见 done"的时钟数（含轮询开销）。
    long ticks = 0;
    auto tick = [&]() {
        dut->clk = 0;
        dut->eval();
        dump_wave();
        dut->clk = 1;
        dut->eval();
        dump_wave();
        ticks++;
    };
    auto axil_write = [&](uint32_t addr, uint32_t data) {
        while (!dut->cmd_ready_o) tick();
        dut->cmd_valid_i = 1;
        dut->cmd_wr_i = 1;
        dut->cmd_addr_i = addr & 0xfffu;
        dut->cmd_wdata_i = data;
        tick();
        dut->cmd_valid_i = 0;
        while (!dut->rsp_valid_o) tick();
        if (dut->rsp_error_o) {
            std::cerr << "AXI-Lite 写 0x" << std::hex << addr << " 回了非 OKAY\n";
        }
        tick();
    };
    auto axil_read = [&](uint32_t addr) -> uint32_t {
        while (!dut->cmd_ready_o) tick();
        dut->cmd_valid_i = 1;
        dut->cmd_wr_i = 0;
        dut->cmd_addr_i = addr & 0xfffu;
        dut->cmd_wdata_i = 0;
        tick();
        dut->cmd_valid_i = 0;
        while (!dut->rsp_valid_o) tick();
        uint32_t value = dut->rsp_rdata_o;
        tick();
        return value;
    };

    for (int i = 0; i < 4; i++) tick();
    dut->aresetn = 1;
    for (int i = 0; i < 2; i++) tick();

    Shape shape;
    uint32_t shape_reg = axil_read(REG_SHAPE);
    shape.warpsz = shape_reg & 0xffu;
    shape.nwarp = (shape_reg >> 8) & 0xffu;
    shape.max_block_dim = shape.warpsz * shape.nwarp;
    shape.max_grid = 0xFFFFu;    // GRID_DIM 是 16 位寄存器，block 之间串行
    if (shape.warpsz == 0 || shape.nwarp == 0) {
        std::cerr << "核报了 warpsz = 0 或者 nwarp = 0\n";
        return 2;
    }
    if (opt.print_shape) {
        printf("{\"warpsz\": %u, \"nwarp\": %u, \"max_block_dim\": %u, \"max_grid\": %u}\n",
               shape.warpsz, shape.nwarp, shape.max_block_dim, shape.max_grid);
        delete dut;
        return 0;
    }

    // BLOCK_DIM 默认用满容量（也可以 --bdim 给小一点的 block），GRID 默认 1；
    // WARPSZ/NWARP/BID 由硬件按启动参数算
    uint32_t bdim = opt.bdim >= 0 ? (uint32_t)opt.bdim : shape.max_block_dim;

    // 参数走 AXI-Lite 控制寄存器（和板上一样）
    axil_write(REG_GRID, opt.grid > 0 ? (uint32_t)opt.grid : 1u);
    axil_write(REG_BLOCK_DIM, bdim);
    // 设备地址基址：上板时这里写 BO 的地址（可能 > 4 GB），核里的指针是 32 位偏移
    axil_write(REG_BASE_LO, (uint32_t)(opt.gmem_base & 0xFFFFFFFFull));
    axil_write(REG_BASE_HI, (uint32_t)(opt.gmem_base >> 32));
    for (const SregValue& sreg : opt.sregs) {
        switch (sreg.index) {
            case SREG_PTR_A: axil_write(REG_PTR_A, sreg.value); break;
            case SREG_PTR_B: axil_write(REG_PTR_B, sreg.value); break;
            case SREG_PTR_C: axil_write(REG_PTR_C, sreg.value); break;
            case SREG_ARG0: axil_write(REG_ARG0, sreg.value); break;
            case SREG_ARG1: axil_write(REG_ARG1, sreg.value); break;
            case SREG_ARG2: axil_write(REG_ARG2, sreg.value); break;
            default: break;
        }
    }

    std::vector<uint32_t> image;
    if (!load_words(opt.image, image)) {
        return 2;
    }

    // shared / global 初态都通过各自的主机口写进硬件
    std::vector<std::pair<uint32_t, uint32_t>> smem_init;
    std::vector<std::pair<uint32_t, uint32_t>> gmem_init;
    for (const MemInit& init : opt.inits) {
        std::vector<uint32_t> words;
        if (!load_words(init.file, words)) {
            return 2;
        }
        if (init.smem) {
            if (init.addr % 4 != 0 || init.addr + words.size() * 4 > SMEM_BYTES) {
                std::cerr << init.file << ": shared 初态越界或者没对齐\n";
                return 2;
            }
            for (size_t i = 0; i < words.size(); i++) {
                smem_init.emplace_back(init.addr + (uint32_t)i * 4, words[i]);
            }
        } else {
            if (init.addr % 4 != 0 || init.addr + words.size() * 4 > GMEM_BYTES) {
                std::cerr << init.file << ": global 初态越界或者没对齐\n";
                return 2;
            }
            for (size_t i = 0; i < words.size(); i++) {
                gmem_init.emplace_back(init.addr + (uint32_t)i * 4, words[i]);
            }
        }
    }
    for (const MemWindow& window : opt.windows) {
        uint32_t bytes = window.smem ? SMEM_BYTES : GMEM_BYTES;
        if (window.addr % 4 != 0 || window.addr / 4 + window.words > bytes / 4) {
            std::cerr << "比对窗口 0x" << std::hex << window.addr << std::dec
                      << " 越界或者没对齐\n";
            return 2;
        }
    }

    // 装载 IMEM 镜像：走控制寄存器（地址 → 数据 → 写脉冲）
    for (size_t i = 0; i < image.size(); i++) {
        axil_write(REG_IMEM_ADDR, (uint32_t)i);
        axil_write(REG_IMEM_DATA, image[i]);
        axil_write(REG_IMEM_WE, 1);
    }

    // shared 初态：核的主机口（写当拍生效，tick 一拍）
    for (const auto& [addr, word] : smem_init) {
        dut->smem_ld_we_i = 1;
        dut->smem_ld_addr_i = (addr & 0x1FFFu) >> 2;
        dut->smem_ld_wdata_i = word;
        tick();
        dut->smem_ld_we_i = 0;
    }

    // global 初态：AXI 从机的 host 口
    for (const auto& [addr, word] : gmem_init) {
        dut->host_we_i = 1;
        dut->host_addr_i = addr;
        dut->host_wdata_i = word;
        tick();
        dut->host_we_i = 0;
    }

    // 调试扫描口：选 (warp, lane) + 扫描地址，再读数据
    uint32_t dbg_wid = 0, dbg_lane = 0;
    uint32_t lane_w = 0;
    while ((1u << lane_w) < shape.warpsz) lane_w++;
    auto dbg = [&](uint8_t addr) -> uint32_t {
        axil_write(REG_DBG_SEL, (dbg_wid << lane_w) | dbg_lane);
        axil_write(REG_DBG_ADDR, addr);
        return axil_read(REG_DBG_DATA);
    };

    // 启动：写 CTRL.start，然后轮询 CTRL.done
    long cycles_start = ticks;
    axil_write(REG_CTRL, 1);
    long cycles = 0;
    while (cycles < opt.max_cycles) {
        uint32_t ctrl = axil_read(REG_CTRL);
        cycles = ticks - cycles_start;
        if (ctrl & 2u) break;                     // bit1 = done
        // --trace：每轮轮询顺手看一眼执行级。AXI-Lite 读要几个时钟，所以这是
        // 抽样而不是逐指令（要逐指令看波形用 --dump-wave）
        if (opt.trace && (dbg(DBG_RUN) & 1u)) {
            uint32_t s4 = dbg(DBG_S4_WID);
            if (s4 & 4u) {                       // bit2 = 这一级真的有指令
                uint32_t wid  = s4 & 3u;
                uint32_t pc   = dbg(DBG_PC_S4);
                uint32_t insn = dbg(DBG_INSN);
                uint32_t keep_wid = dbg_wid, keep_lane = dbg_lane;
                dbg_wid = wid;
                dbg_lane = 0;
                uint32_t m = dbg(DBG_M);
                dbg_wid = keep_wid;
                dbg_lane = keep_lane;
                printf("cyc=%-5ld w%u pc=%04x insn=%08x m=%x\n", cycles, wid, pc, insn, m);
            }
        }
    }

    // 按 warp × lane 扫一遍：GPR 和谓词都是每 (warp, lane) 一份，M 是每 warp N 位
    uint32_t dump_warps = (opt.nwarp > 0) ? (uint32_t)opt.nwarp : shape.nwarp;
    if (dump_warps > shape.nwarp) dump_warps = shape.nwarp;
    std::vector<WarpState> warps;
    for (uint32_t wid = 0; wid < dump_warps; wid++) {
        WarpState warp;
        warp.wid = wid;
        dbg_wid = wid;
        dbg_lane = 0;
        warp.pc = dbg(DBG_PC_WARP);
        warp.m = dbg(DBG_M);
        for (uint32_t lane = 0; lane < shape.warpsz; lane++) {
            dbg_lane = lane;
            std::vector<uint32_t> gpr;
            for (int i = 0; i < NUM_GPR; i++) {
                gpr.push_back(dbg((uint8_t)i));
            }
            warp.gpr.push_back(gpr);
            warp.pred.push_back(dbg(DBG_PRED));
        }
        warps.push_back(warp);
    }
    dbg_wid = 0;
    dbg_lane = 0;
    uint32_t perf[NUM_PERF] = {};
    for (int i = 0; i < NUM_PERF; i++) {
        perf[i] = dbg((uint8_t)(DBG_PERF + i));
    }
    uint32_t class_cnt[NUM_CLASS] = {};
    for (int i = 0; i < NUM_CLASS; i++) {
        class_cnt[i] = dbg((uint8_t)(DBG_CLASS + i));
    }
    uint32_t status = axil_read(REG_STATUS);
    Trap trap;
    trap.valid = dbg(DBG_TRAP_VALID) != 0;
    trap.wid = dbg(DBG_TRAP_WID);
    trap.pc = dbg(DBG_TRAP_PC);

    if (!opt.state.empty()) {
        // 读比对窗口：global 走 AXI 从机的 host 口（组合读），
        // shared 走核的主机口（同步读，给地址后 tick 一拍）
        std::vector<std::vector<uint32_t>> windows_data;
        for (const MemWindow& window : opt.windows) {
            std::vector<uint32_t> words;
            for (uint32_t offset = 0; offset < window.words; offset++) {
                uint32_t addr = window.addr + offset * 4;
                if (window.smem) {
                    dut->smem_rd_addr_i = (addr & 0x1FFFu) >> 2;
                    dut->smem_rd_en_i = 1;
                    tick();
                    words.push_back(dut->smem_rd_data_o);
                    dut->smem_rd_en_i = 0;
                } else {
                    dut->host_raddr_i = addr;
                    dut->eval();
                    words.push_back(dut->host_rdata_o);
                }
            }
            windows_data.push_back(words);
        }
        if (!write_state(opt, shape, status, cycles, warps, perf, class_cnt, trap,
                         windows_data)) {
            return 2;
        }
    }
    if (cycles >= opt.max_cycles) {
        std::cerr << opt.image << ": " << cycles << " 拍还没结束（status=" << status << "）\n";
        return 1;
    }
#if VM_TRACE
    if (fst) {
        fst->close();
    }
#endif
    return 0;
}
