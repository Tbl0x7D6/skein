//! 上板主机程序（P6）：XRT 原生 API + AXI-Lite 寄存器访问。
//!
//! 和仿真里 tb_core 走的是同一条主机流程：写 IMEM 镜像 → 写参数（含 BO 的
//! GMEM_BASE）→ 写 CTRL.start → 轮询 CTRL.done → 读 STATUS / 性能计数器 →
//! 比对内存。上面没有 kernel 参数（`krnl(...)`），全部用 `write_register` /
//! `read_register`，寄存器表见 docs/design.md §5.6。
//!
//! 自带两个和 cases/ 一致的负载（vecadd_stream n=1024、sgemm64 int32 64×64），
//! 数据生成器和 tools/src/case.rs 相同，参考值在主机上算，逐位比对。
//!
//! 编译（在板卡机上，XRT 头文件在 /usr/include/xrt）：
//!   g++ -O2 -std=c++17 -Wno-deprecated-declarations skein_run.cpp \
//!       -o skein_run -lxrt_coreutil -luuid -pthread
//! （read_register/write_register 在 XRT 2.21 里标了 deprecated，但仍然是那条
//!   AXI-Lite 通路；换成 xrt::ip 要另开 user-managed IP，v0.1 不做。）
//!
//! 用法：
//!   ./skein_run --xclbin skein.xclbin --image build/sgemm64.bin --workload sgemm64
//!   ./skein_run --xclbin skein.xclbin --image build/vecadd.bin --workload vecadd
//!   ./skein_run --xclbin skein.xclbin --smoke      # 只做寄存器读写 + 形状检查

#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>
#include <xrt/xrt_kernel.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

// 控制寄存器（和 rtl/top/SK_ctrl.sv、docs/design.md §5.6 一致）
constexpr uint32_t REG_CTRL      = 0x000;
constexpr uint32_t REG_GRID      = 0x010;
constexpr uint32_t REG_BLOCK_DIM = 0x014;
constexpr uint32_t REG_PTR_A     = 0x018;
constexpr uint32_t REG_PTR_B     = 0x01C;
constexpr uint32_t REG_PTR_C     = 0x020;
constexpr uint32_t REG_ARG0      = 0x024;
constexpr uint32_t REG_ARG1      = 0x028;
constexpr uint32_t REG_ARG2      = 0x02C;
constexpr uint32_t REG_BASE_LO   = 0x030;
constexpr uint32_t REG_BASE_HI   = 0x034;
constexpr uint32_t REG_IMEM_ADDR = 0x038;
constexpr uint32_t REG_IMEM_DATA = 0x03C;
constexpr uint32_t REG_IMEM_WE   = 0x040;
constexpr uint32_t REG_STATUS    = 0x044;
constexpr uint32_t REG_SHAPE     = 0x048;
constexpr uint32_t REG_DBG_ADDR  = 0x04C;
constexpr uint32_t REG_DBG_SEL   = 0x050;
constexpr uint32_t REG_DBG_DATA  = 0x054;

// 调试扫描地址（docs/design.md §13）
constexpr uint8_t DBG_PERF_CYCLE = 0x30;
constexpr uint8_t DBG_PERF_RETIRED = 0x32;

// kernel.xml 里 `gmem_base`（连 m_axi_gmem 的那个指针参数）的 id 是 8，
// 前面 0..7 全是标量寄存器参数。BO 必须按这个参数的 memory group 分配，
// 早先写成 group_id(0)（= 标量参数 grid_dim）时 XRT 会去分配 host/userptr BO，
// 直接报 "failed to allocate userptr bo: Operation not permitted"。
constexpr int ARG_GMEM_BASE = 8;

// BO 里的布局（字节偏移，和 cases/bench/*.toml 一样）
constexpr uint32_t PTR_A = 0x1000;
constexpr uint32_t PTR_B = 0x8000;
constexpr uint32_t PTR_C = 0x10000;
constexpr uint32_t BO_BYTES = 1u << 20;

struct Args {
    std::string xclbin;
    std::string image;
    std::string workload = "vecadd";
    uint32_t block_dim = 16;
    uint32_t grid = 1;
    bool smoke = false;
};

[[noreturn]] void die(const std::string& message) {
    std::fprintf(stderr, "错误：%s\n", message.c_str());
    std::exit(1);
}

Args parse_args(int argc, char** argv) {
    Args args;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) die(arg + " 后面还差参数");
            return argv[++i];
        };
        if (arg == "--xclbin") {
            args.xclbin = next();
        } else if (arg == "--image") {
            args.image = next();
        } else if (arg == "--workload") {
            args.workload = next();
        } else if (arg == "--bdim") {
            args.block_dim = (uint32_t)std::strtoul(next().c_str(), nullptr, 0);
        } else if (arg == "--grid") {
            args.grid = (uint32_t)std::strtoul(next().c_str(), nullptr, 0);
        } else if (arg == "--smoke") {
            args.smoke = true;
        } else {
            die("不认识的参数：" + arg);
        }
    }
    if (args.xclbin.empty()) die("要给 --xclbin");
    if (!args.smoke && args.image.empty()) die("要给 --image（IMEM 镜像 .bin）");
    return args;
}

std::vector<uint32_t> load_words(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) die("打不开 " + path);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)),
                            std::istreambuf_iterator<char>());
    if (bytes.size() % 4 != 0) die(path + " 不是 4 字节对齐的镜像");
    std::vector<uint32_t> words;
    for (size_t i = 0; i < bytes.size(); i += 4) {
        uint32_t word = 0;
        std::memcpy(&word, bytes.data() + i, 4);
        words.push_back(word);
    }
    return words;
}

class Runner {
  public:
    Runner(const Args& args)
        : device_(0), xclbin_(args.xclbin) {
        uuid_ = device_.load_xclbin(xclbin_);
        // CU 默认是 shared 访问，XRT 2.21 在 shared 下会拒绝 read_register /
        // write_register（"Cannot read or write kernel with shared access"），
        // 所以显式开 exclusive。
        kernel_ = xrt::kernel(device_, uuid_, "SK_afu", xrt::kernel::cu_access_mode::exclusive);
        bo_ = xrt::bo(device_, BO_BYTES, kernel_.group_id(ARG_GMEM_BASE));
        map_ = bo_.map<uint32_t*>();
        std::memset(map_, 0, BO_BYTES);
    }

    uint32_t read(uint32_t offset) { return kernel_.read_register(offset); }
    void write(uint32_t offset, uint32_t value) { kernel_.write_register(offset, value); }

    uint32_t dbg(uint8_t addr, uint32_t wid = 0, uint32_t lane = 0) {
        write(REG_DBG_SEL, (wid << 2) | lane);   // LANE_W = 2（warpsz = 4）
        write(REG_DBG_ADDR, addr);
        return read(REG_DBG_DATA);
    }

    void load_imem(const std::vector<uint32_t>& image) {
        for (size_t i = 0; i < image.size(); i++) {
            write(REG_IMEM_ADDR, (uint32_t)i);
            write(REG_IMEM_DATA, image[i]);
            write(REG_IMEM_WE, 1);
        }
    }

    void run(uint32_t grid, uint32_t block_dim, uint32_t arg0) {
        uint64_t base = bo_.address();
        write(REG_BASE_LO, (uint32_t)(base & 0xFFFFFFFFu));
        write(REG_BASE_HI, (uint32_t)(base >> 32));
        write(REG_GRID, grid);
        write(REG_BLOCK_DIM, block_dim);
        write(REG_PTR_A, PTR_A);
        write(REG_PTR_B, PTR_B);
        write(REG_PTR_C, PTR_C);
        write(REG_ARG0, arg0);          // vecadd 用它当 n（sgemm 不用）
        write(REG_CTRL, 1);
        uint32_t ctrl = 0;
        // 每次 AXI-Lite 读 ≈ 1–2 µs（PCIe），2 千万次≈ 20–40 s：sgemm 只要几 ms，
        // 真挂了就早点报出来
        for (long poll = 0; poll < 20000000; poll++) {
            ctrl = read(REG_CTRL);
            if (ctrl & 0x2u) break;             // bit1 = done
        }
        if (!(ctrl & 0x2u)) die("等 done 超时");
        uint32_t status = read(REG_STATUS);
        if (status != 0) {
            char buf[64];
            std::snprintf(buf, sizeof buf, "STATUS = %u（0x%x）", status, status);
            die(buf);
        }
        std::printf("跑完：cycles=%u retired=%u\n", dbg(DBG_PERF_CYCLE),
                    dbg(DBG_PERF_RETIRED));
    }

    template <typename T>
    T* map() {
        return reinterpret_cast<T*>(map_);
    }

    void sync_to_device() { bo_.sync(XCL_BO_SYNC_BO_TO_DEVICE); }
    void sync_from_device() { bo_.sync(XCL_BO_SYNC_BO_FROM_DEVICE); }

  private:
    xrt::device device_;
    xrt::uuid uuid_;
    std::string xclbin_;
    xrt::kernel kernel_{};
    xrt::bo bo_{};
    uint32_t* map_ = nullptr;
};

// 和 tools/src/case.rs 一样的生成器
uint32_t vecadd_a(uint32_t i) { return (uint32_t)((int32_t)(i * 3u) + 1); }
uint32_t vecadd_b(uint32_t i) { return (uint32_t)((int32_t)(i * 7u) + 2); }
uint32_t matmul_a(uint32_t i) { return (uint32_t)((int32_t)(i % 7) - 3); }
uint32_t matmul_b(uint32_t i) { return (uint32_t)((int32_t)(i % 5) - 2); }

int run_vecadd(Runner& runner, uint32_t block_dim) {
    constexpr uint32_t N = 1024;
    uint32_t* mem = runner.map<uint32_t>();
    for (uint32_t i = 0; i < N; i++) {
        mem[PTR_A / 4 + i] = vecadd_a(i);
        mem[PTR_B / 4 + i] = vecadd_b(i);
    }
    runner.sync_to_device();
    runner.run(1, block_dim, N);
    runner.sync_from_device();
    int bad = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t want = vecadd_a(i) + vecadd_b(i);
        uint32_t got = mem[PTR_C / 4 + i];
        if (got != want) {
            if (bad < 5) std::printf("c[%u] 期望 %u 实际 %u\n", i, want, got);
            bad++;
        }
    }
    std::printf("vecadd n=%u：%s（%d 个不匹配）\n", N, bad ? "FAIL" : "PASS", bad);
    return bad ? 1 : 0;
}

int run_sgemm64(Runner& runner, uint32_t block_dim) {
    constexpr uint32_t N = 64;
    uint32_t* mem = runner.map<uint32_t>();
    for (uint32_t i = 0; i < N * N; i++) {
        mem[PTR_A / 4 + i] = matmul_a(i);
        mem[PTR_B / 4 + i] = matmul_b(i);
    }
    runner.sync_to_device();
    runner.run(1, block_dim, N);
    runner.sync_from_device();
    int bad = 0;
    for (uint32_t i = 0; i < N; i++) {
        for (uint32_t j = 0; j < N; j++) {
            int32_t acc = 0;
            for (uint32_t k = 0; k < N; k++) {
                acc += (int32_t)matmul_a(i * N + k) * (int32_t)matmul_b(k * N + j);
            }
            uint32_t got = mem[PTR_C / 4 + i * N + j];
            if (got != (uint32_t)acc) {
                if (bad < 5) {
                    std::printf("c[%u][%u] 期望 %d 实际 %d\n", i, j, acc, (int32_t)got);
                }
                bad++;
            }
        }
    }
    std::printf("sgemm64：%s（%d 个不匹配）\n", bad ? "FAIL" : "PASS", bad);
    return bad ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
    Args args = parse_args(argc, argv);
    Runner runner(args);

    uint32_t shape = runner.read(REG_SHAPE);
    std::printf("xclbin: %s\n", args.xclbin.c_str());
    std::printf("SHAPE：%u lane/warp × %u warp（0x%04x）\n", shape & 0xffu,
                (shape >> 8) & 0xffu, shape);

    if (args.smoke) {
        // 寄存器读写 smoke：GMEM_BASE_HI 是普通的 R/W 寄存器，写回原值就行
        uint32_t saved = runner.read(REG_BASE_HI);
        runner.write(REG_BASE_HI, 0xDEADBEEFu);
        uint32_t got = runner.read(REG_BASE_HI);
        runner.write(REG_BASE_HI, saved);
        std::printf("寄存器读写：%s（写了 0xdeadbeef，读回 0x%08x）\n",
                    got == 0xDEADBEEFu ? "PASS" : "FAIL", got);
        return got == 0xDEADBEEFu ? 0 : 1;
    }

    runner.load_imem(load_words(args.image));
    if (args.workload == "vecadd") {
        return run_vecadd(runner, args.block_dim);
    }
    if (args.workload == "sgemm64") {
        return run_sgemm64(runner, args.block_dim);
    }
    die("不认识的 workload：" + args.workload);
}
