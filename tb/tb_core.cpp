//! P1 单 lane 核的 Verilator testbench：喂输入、跑到底、dump 状态。
//!
//! 这里不做比对——`skein-case`（tools/src/bin/skein-case.rs）把这份 dump 和黄金模型逐项
//! 比对。testbench 只负责：装载 IMEM 镜像和 shared/global 初态、驱动特殊寄存器、
//! 跑到 done 或者报错，然后按 --mem-window 把架构状态和内存窗口写成 JSON，
//! 字段和 `skein-run --dump-state` 对齐（多一个 "mem"）。
//!
//! 用法：
//!   tb_core --image <image.bin> [--set NAME=VALUE]...
//!           [--gmem-init ADDR FILE]... [--smem-init ADDR FILE]...
//!           [--mem-window SPACE ADDR WORDS]... [--max-cycles N] [--trace]
//!           [--dump-state <file>] [--dump-wave <file.fst>]
//!
//! 形状固定 1 warp × 1 lane（WARPSZ/NWARP/BLOCK_DIM/GRID 都是 1，TID/LANEID/WID/BID
//! 都是 0）；多 warp / 多 lane 的 case 由 runner 跳过。
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

#include "VSK_core.h"
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
constexpr uint8_t DBG_PC_E = 0x22;
constexpr uint8_t DBG_STATUS = 0x23;
constexpr uint8_t DBG_INSN = 0x24;
constexpr uint8_t DBG_RUN = 0x25;
constexpr uint8_t DBG_PC_ARCH = 0x26;

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
    bool trace = false;
};

void usage() {
    std::cerr << "用法：tb_core --image <image.bin> [--set NAME=VALUE]... "
                 "[--gmem-init ADDR FILE]... [--smem-init ADDR FILE]... "
                 "[--mem-window SPACE ADDR WORDS]... [--max-cycles N] [--trace] "
                 "[--dump-state <file>] [--dump-wave <file.fst>]\n";
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
        } else if (arg == "--trace") {
            opt.trace = true;
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
    if (opt.image.empty()) {
        usage();
        return false;
    }
    return true;
}

/// IMEM 镜像：每字 32 位小端。
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

/// 把初态文件写进内存模型；越界或者没对齐直接报错。
bool apply_init(const MemInit& init, std::vector<uint32_t>& smem, std::vector<uint32_t>& gmem) {
    std::vector<uint32_t> words;
    if (!load_words(init.file, words)) {
        return false;
    }
    std::vector<uint32_t>& memory = init.smem ? smem : gmem;
    uint32_t bytes = (uint32_t)(memory.size() * 4);
    if (init.addr % 4 != 0 || init.addr + words.size() * 4 > bytes) {
        std::cerr << init.file << ": 初态写到 0x" << std::hex << init.addr << std::dec
                  << " 越界或者没对齐\n";
        return false;
    }
    for (size_t i = 0; i < words.size(); i++) {
        memory[init.addr / 4 + i] = words[i];
    }
    return true;
}

/// 状态 + 内存窗口写成 JSON（形状对齐 skein-run --dump-state）。
bool write_state(const Options& opt, uint32_t status, long cycles, const std::vector<uint32_t>& gpr,
                 uint32_t pred, uint32_t m, uint32_t pc, const std::vector<uint32_t>& smem,
                 const std::vector<uint32_t>& gmem) {
    std::ofstream out(opt.state);
    if (!out) {
        std::cerr << "写不了 " << opt.state << "\n";
        return false;
    }
    out << "{\n";
    out << "  \"status\": " << status << ",\n";
    out << "  \"cycles\": " << cycles << ",\n";
    out << "  \"warps\": [\n";
    out << "    {\n      \"wid\": 0,\n      \"pc\": " << pc << ",\n      \"m\": " << m << ",\n";
    out << "      \"gpr\": [[";
    for (size_t i = 0; i < gpr.size(); i++) {
        out << (i ? ", " : "") << gpr[i];
    }
    out << "]],\n      \"pred\": [[";
    for (int i = 0; i < NUM_PRED; i++) {
        out << (i ? ", " : "") << ((pred >> i) & 1u);
    }
    out << "]]\n    }\n  ],\n";
    out << "  \"mem\": [\n";
    for (size_t index = 0; index < opt.windows.size(); index++) {
        const MemWindow& window = opt.windows[index];
        const std::vector<uint32_t>& memory = window.smem ? smem : gmem;
        out << "    {\"space\": \"" << (window.smem ? "smem" : "gmem") << "\", \"addr\": "
            << window.addr << ", \"words\": [";
        for (uint32_t offset = 0; offset < window.words; offset++) {
            out << (offset ? ", " : "") << memory[window.addr / 4 + offset];
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
    std::vector<uint32_t> image;
    if (!load_words(opt.image, image)) {
        return 2;
    }

    VerilatedContext context;
    context.commandArgs(argc, argv);
    VSK_core* dut = new VSK_core{&context};

    std::vector<uint32_t> smem(SMEM_BYTES / 4, 0);
    std::vector<uint32_t> gmem(GMEM_BYTES / 4, 0);
    for (const MemInit& init : opt.inits) {
        if (!apply_init(init, smem, gmem)) {
            return 2;
        }
    }
    for (const MemWindow& window : opt.windows) {
        const std::vector<uint32_t>& memory = window.smem ? smem : gmem;
        if (window.addr % 4 != 0
            || window.addr / 4 + window.words > (uint32_t)(memory.size())) {
            std::cerr << "比对窗口 0x" << std::hex << window.addr << std::dec
                      << " 越界或者没对齐\n";
            return 2;
        }
    }

    // 单 lane：WARPSZ/NWARP/BLOCK_DIM/GRID 都是 1，TID/LANEID/WID/BID 都是 0
    for (int i = 0; i < 16; i++) {
        dut->sreg_i[i] = 0;
    }
    dut->sreg_i[SREG_WARPSZ] = 1;
    dut->sreg_i[SREG_NWARP] = 1;
    dut->sreg_i[SREG_BLOCK_DIM] = 1;
    dut->sreg_i[SREG_GRID] = 1;
    for (const SregValue& sreg : opt.sregs) {
        dut->sreg_i[sreg.index] = sreg.value;
    }

    auto drive_memory = [&]() {
        uint32_t sa = dut->smem_addr_o;
        dut->smem_rdata_i = (sa <= SMEM_BYTES - 4) ? smem[sa >> 2] : 0;
        dut->smem_fault_i = (sa > SMEM_BYTES - 4);
        uint32_t ga = dut->gmem_addr_o;
        dut->gmem_rdata_i = (ga <= GMEM_BYTES - 4) ? gmem[ga >> 2] : 0;
        dut->gmem_fault_i = (ga > GMEM_BYTES - 4);
    };

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

    auto low_phase = [&]() {
        dut->clk = 0;
        dut->eval();
        drive_memory();
        dut->eval();
        dump_wave();
    };
    auto clock_edge = [&]() {
        bool smem_we = dut->smem_we_o, gmem_we = dut->gmem_we_o;
        uint32_t sa = dut->smem_addr_o, ga = dut->gmem_addr_o;
        uint32_t sd = dut->smem_wdata_o, gd = dut->gmem_wdata_o;
        dut->clk = 1;
        dut->eval();
        if (smem_we && sa <= SMEM_BYTES - 4) {
            smem[sa >> 2] = sd;
        }
        if (gmem_we && ga <= GMEM_BYTES - 4) {
            gmem[ga >> 2] = gd;
        }
        dump_wave();
    };
    auto tick = [&]() {
        low_phase();
        clock_edge();
    };
    auto dbg = [&](uint8_t addr) -> uint32_t {
        dut->dbg_addr_i = addr;
        dut->eval();
        return dut->dbg_data_o;
    };

    // 复位
    dut->clk = 0;
    dut->aresetn = 0;
    dut->start_i = 0;
    dut->imem_we_i = 0;
    dut->imem_addr_i = 0;
    dut->imem_wdata_i = 0;
    dut->dbg_addr_i = 0;
    for (int i = 0; i < 4; i++) {
        tick();
    }

    // 装载 IMEM 镜像
    dut->imem_we_i = 1;
    for (size_t i = 0; i < image.size(); i++) {
        dut->imem_addr_i = (uint32_t)i;
        dut->imem_wdata_i = image[i];
        tick();
    }
    dut->imem_we_i = 0;
    dut->aresetn = 1;

    // 启动
    dut->start_i = 1;
    low_phase();
    clock_edge();
    dut->start_i = 0;

    long cycles = 0;
    while (!dut->done_o && cycles < opt.max_cycles) {
        low_phase();
        if (opt.trace && (dbg(DBG_RUN) & 1u)) {
            printf("cyc=%-4ld pc=%04x insn=%08x m=%u\n", cycles, dbg(DBG_PC_E), dbg(DBG_INSN),
                   dbg(DBG_M) & 1u);
        }
        clock_edge();
        cycles++;
    }

    std::vector<uint32_t> gpr;
    for (int i = 0; i < NUM_GPR; i++) {
        gpr.push_back(dbg((uint8_t)i));
    }
    uint32_t status = dbg(DBG_STATUS);
    uint32_t m = dbg(DBG_M);
    uint32_t pred = dbg(DBG_PRED);
    uint32_t pc = dbg(DBG_PC_ARCH);

    if (!opt.state.empty()) {
        if (!write_state(opt, status, cycles, gpr, pred, m, pc, smem, gmem)) {
            return 2;
        }
    }
    if (!dut->done_o) {
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
