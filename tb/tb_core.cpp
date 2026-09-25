//! P1 单 lane 核的 Verilator testbench。
//!
//! 装载 IMEM 镜像、驱动特殊寄存器和 shared/global 内存模型，跑到 done 或者出错，
//! 然后和 `skein-run --dump-state` 出来的黄金模型状态逐寄存器比对。内存模型和黄金
//! 模型的默认容量一致（shared 32 KB、global 1 MB），越界由这里报给核。
//!
//! 用法：
//!   tb_core <image.bin> [--expect <state.json>] [--set NAME=VALUE]...
//!           [--max-cycles N] [--trace] [--dump-state <file>]

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "VSK_core.h"
#include "verilated.h"

namespace {

// 和黄金模型的默认值保持一致（skein-run --smem-bytes/--gmem-bytes）
constexpr uint32_t SMEM_BYTES = 32 * 1024;
constexpr uint32_t GMEM_BYTES = 1 << 20;

constexpr uint8_t DBG_M      = 0x20;
constexpr uint8_t DBG_PRED   = 0x21;
constexpr uint8_t DBG_PC_E   = 0x22;
constexpr uint8_t DBG_STATUS = 0x23;
constexpr uint8_t DBG_INSN   = 0x24;
constexpr uint8_t DBG_RUN    = 0x25;
constexpr uint8_t DBG_PC_ARCH = 0x26;

// 特殊寄存器编号，和 sim/src/isa.rs 的 Sreg 一致
constexpr int SREG_TID = 0x00, SREG_LANEID = 0x01, SREG_WID = 0x02, SREG_WARPSZ = 0x03;
constexpr int SREG_NWARP = 0x04, SREG_GRID = 0x05, SREG_PTR_A = 0x06, SREG_PTR_B = 0x07;
constexpr int SREG_PTR_C = 0x08, SREG_ARG0 = 0x09, SREG_ARG1 = 0x0A, SREG_ARG2 = 0x0B;
constexpr int SREG_STATUS = 0x0C, SREG_BID = 0x0D, SREG_BLOCK_DIM = 0x0E;

const char* status_name(int code) {
    switch (code) {
        case 0: return "OK";
        case 1: return "BAD_INSN";
        case 2: return "UNALIGNED";
        case 3: return "SMEM_OOB";
        case 4: return "GMEM_OOB";
        case 5: return "BAR_INCOMPLETE";
        case 6: return "PC_OOB";
        case 7: return "BAD_LAUNCH";
        default: return "?";
    }
}

std::string base_name(const std::string& path) {
    size_t slash = path.find_last_of('/');
    std::string name = (slash == std::string::npos) ? path : path.substr(slash + 1);
    size_t dot = name.find_last_of('.');
    return (dot == std::string::npos) ? name : name.substr(0, dot);
}

bool read_file(const std::string& path, std::string& text) {
    std::ifstream file(path);
    if (!file) {
        std::cerr << "打不开 " << path << "\n";
        return false;
    }
    text.assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    return true;
}

uint32_t parse_number(const std::string& text) {
    return (uint32_t)strtoul(text.c_str(), nullptr, 0);
}

/// IMEM 镜像：每字 32 位小端。
bool load_image(const std::string& path, std::vector<uint32_t>& words) {
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

/// 黄金模型 dump 里的一个标量字段。
bool json_int(const std::string& text, const std::string& key, long& value) {
    size_t pos = text.find(key);
    if (pos == std::string::npos) {
        return false;
    }
    pos += key.size();
    while (pos < text.size() && !std::isdigit((unsigned char)text[pos]) && text[pos] != '-') {
        pos++;
    }
    if (pos >= text.size()) {
        return false;
    }
    value = strtol(text.c_str() + pos, nullptr, 10);
    return true;
}

/// 黄金模型 dump 里的数组字段（如 gpr / pred），按出现顺序取所有整数。
bool json_ints(const std::string& text, const std::string& key, std::vector<long>& values) {
    size_t pos = text.find(key);
    if (pos == std::string::npos) {
        return false;
    }
    while (pos < text.size() && text[pos] != '[') {
        pos++;
    }
    if (pos >= text.size()) {
        return false;
    }
    int depth = 0;
    for (; pos < text.size(); pos++) {
        char ch = text[pos];
        if (ch == '[') {
            depth++;
        } else if (ch == ']') {
            depth--;
            if (depth == 0) {
                return true;
            }
        } else if (std::isdigit((unsigned char)ch) || ch == '-') {
            size_t end = pos;
            if (text[end] == '-') {
                end++;
            }
            while (end < text.size() && std::isdigit((unsigned char)text[end])) {
                end++;
            }
            values.push_back(strtol(text.substr(pos, end - pos).c_str(), nullptr, 10));
            pos = end - 1;
        }
    }
    return false;
}

struct Golden {
    long status = 0;
    long pc = 0;
    uint32_t m = 0;
    std::vector<uint32_t> gpr;
    std::vector<int> pred;
};

bool load_golden(const std::string& path, Golden& golden) {
    std::string text;
    if (!read_file(path, text)) {
        return false;
    }
    std::vector<long> gpr, pred;
    long mask = 0;
    if (!json_int(text, "\"status\":", golden.status) || !json_int(text, "\"pc\":", golden.pc)
        || !json_int(text, "\"m\":", mask) || !json_ints(text, "\"gpr\":", gpr)
        || !json_ints(text, "\"pred\":", pred)) {
        std::cerr << path << ": 解析失败（不是 skein-run --dump-state 的输出？）\n";
        return false;
    }
    golden.m = (uint32_t)mask;
    for (long value : gpr) {
        golden.gpr.push_back((uint32_t)value);
    }
    for (long value : pred) {
        golden.pred.push_back((int)value);
    }
    return true;
}

struct Options {
    std::string image;
    std::string expect;
    std::string dump;
    std::vector<std::pair<int, uint32_t>> sregs;
    long max_cycles = 200000;
    bool trace = false;
};

bool parse_args(int argc, char** argv, Options& opt) {
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--expect" && i + 1 < argc) {
            opt.expect = argv[++i];
        } else if (arg == "--dump-state" && i + 1 < argc) {
            opt.dump = argv[++i];
        } else if (arg == "--max-cycles" && i + 1 < argc) {
            opt.max_cycles = strtol(argv[++i], nullptr, 0);
        } else if (arg == "--trace") {
            opt.trace = true;
        } else if (arg == "--set" && i + 1 < argc) {
            std::string pair = argv[++i];
            size_t equal = pair.find('=');
            if (equal == std::string::npos) {
                std::cerr << "--set 的写法应为 NAME=VALUE：" << pair << "\n";
                return false;
            }
            std::string name = pair.substr(0, equal);
            uint32_t value = parse_number(pair.substr(equal + 1));
            int index = -1;
            if (name == "PTR_A") index = SREG_PTR_A;
            else if (name == "PTR_B") index = SREG_PTR_B;
            else if (name == "PTR_C") index = SREG_PTR_C;
            else if (name == "ARG0") index = SREG_ARG0;
            else if (name == "ARG1") index = SREG_ARG1;
            else if (name == "ARG2") index = SREG_ARG2;
            else {
                std::cerr << "--set 只支持 PTR_A/PTR_B/PTR_C/ARG0/ARG1/ARG2：" << name << "\n";
                return false;
            }
            opt.sregs.emplace_back(index, value);
        } else if (!arg.empty() && arg[0] == '-') {
            std::cerr << "不认识的参数：" << arg << "\n";
            return false;
        } else {
            opt.image = arg;
        }
    }
    if (opt.image.empty()) {
        std::cerr << "用法：tb_core <image.bin> [--expect <state.json>] [--set NAME=VALUE]...\n";
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt;
    if (!parse_args(argc, argv, opt)) {
        return 2;
    }
    std::vector<uint32_t> image;
    if (!load_image(opt.image, image)) {
        return 2;
    }
    Golden golden;
    if (!opt.expect.empty() && !load_golden(opt.expect, golden)) {
        return 2;
    }

    VerilatedContext context;
    context.commandArgs(argc, argv);
    VSK_core* dut = new VSK_core{&context};

    std::vector<uint32_t> smem(SMEM_BYTES / 4, 0);
    std::vector<uint32_t> gmem(GMEM_BYTES / 4, 0);

    // 单 lane：WARPSZ/NWARP/BLOCK_DIM/GRID 都是 1，TID/LANEID/WID/BID 都是 0
    for (int i = 0; i < 16; i++) {
        dut->sreg_i[i] = 0;
    }
    dut->sreg_i[SREG_WARPSZ] = 1;
    dut->sreg_i[SREG_NWARP] = 1;
    dut->sreg_i[SREG_BLOCK_DIM] = 1;
    dut->sreg_i[SREG_GRID] = 1;
    for (auto& [index, value] : opt.sregs) {
        dut->sreg_i[index] = value;
    }

    auto drive_memory = [&]() {
        uint32_t sa = dut->smem_addr_o;
        dut->smem_rdata_i = (sa <= SMEM_BYTES - 4) ? smem[sa >> 2] : 0;
        dut->smem_fault_i = (sa > SMEM_BYTES - 4);
        uint32_t ga = dut->gmem_addr_o;
        dut->gmem_rdata_i = (ga <= GMEM_BYTES - 4) ? gmem[ga >> 2] : 0;
        dut->gmem_fault_i = (ga > GMEM_BYTES - 4);
    };
    auto low_phase = [&]() {
        dut->clk = 0;
        dut->eval();
        drive_memory();
        dut->eval();
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
    for (int i = 0; i < 32; i++) {
        gpr.push_back(dbg((uint8_t)i));
    }
    uint32_t status = dbg(DBG_STATUS);
    uint32_t m = dbg(DBG_M);
    uint32_t pred = dbg(DBG_PRED);
    uint32_t pc = dbg(DBG_PC_ARCH);

    if (!opt.dump.empty()) {
        std::ofstream out(opt.dump);
        out << "{\n";
        out << "  \"status\": " << status << ",\n";
        out << "  \"cycles\": " << cycles << ",\n";
        out << "  \"pc\": " << pc << ",\n";
        out << "  \"m\": " << m << ",\n";
        out << "  \"gpr\": [[";
        for (size_t i = 0; i < gpr.size(); i++) {
            out << (i ? ", " : "") << gpr[i];
        }
        out << "]],\n  \"pred\": [[";
        for (int i = 0; i < 8; i++) {
            out << (i ? ", " : "") << ((pred >> i) & 1u);
        }
        out << "]]\n}\n";
    }

    std::string name = base_name(opt.image);
    if (!dut->done_o) {
        printf("%s: FAIL（%ld 拍还没结束，status=%s）\n", name.c_str(), cycles,
               status_name((int)status));
        return 1;
    }
    if (opt.expect.empty()) {
        printf("%s: status=%s cycles=%ld pc=%u\n", name.c_str(), status_name((int)status), cycles,
               pc);
        return 0;
    }

    std::vector<std::string> errors;
    if ((long)status != golden.status) {
        errors.push_back("status 期望 " + std::string(status_name((int)golden.status)) + "("
                         + std::to_string(golden.status) + ")，实际 "
                         + status_name((int)status) + "(" + std::to_string(status) + ")");
    }
    if ((long)pc != golden.pc) {
        errors.push_back("pc 期望 " + std::to_string(golden.pc) + "，实际 " + std::to_string(pc));
    }
    if (m != golden.m) {
        errors.push_back("M 期望 " + std::to_string(golden.m) + "，实际 " + std::to_string(m));
    }
    for (size_t i = 0; i < golden.gpr.size() && i < gpr.size(); i++) {
        if (gpr[i] != golden.gpr[i]) {
            errors.push_back("r" + std::to_string(i) + " 期望 " + std::to_string(golden.gpr[i])
                             + "，实际 " + std::to_string(gpr[i]));
        }
    }
    for (size_t i = 0; i < golden.pred.size() && i < 8; i++) {
        int actual = (pred >> i) & 1u;
        if (actual != golden.pred[i]) {
            errors.push_back("p" + std::to_string(i) + " 期望 " + std::to_string(golden.pred[i])
                             + "，实际 " + std::to_string(actual));
        }
    }
    if (!errors.empty()) {
        printf("%s: FAIL（cycles=%ld）\n", name.c_str(), cycles);
        for (const std::string& error : errors) {
            printf("  %s\n", error.c_str());
        }
        return 1;
    }
    printf("%s: PASS（cycles=%ld, status=%s）\n", name.c_str(), cycles, status_name((int)status));
    delete dut;
    return 0;
}
