# 工程手册

写 RTL、上板时看这份。设计参数和接口约定在 [design.md](design.md)。

## 1. RTL 编码规范

### 1.1 命名

| 对象 | 规则 | 例 |
|---|---|---|
| 模块 | `SK_<功能>`，文件名 = 模块名 | `SK_scoreboard.sv` |
| 接口信号 | `*_valid` / `*_ready` / `*_data` / `*_addr` | `req_valid` |
| 低有效 | `_n` 后缀 | `aresetn` |
| 寄存器 | `_q` 后缀（可选，但同一模块内保持一致） | `state_q` |
| 参数/宏 | `SK_` 前缀，全大写 | `SK_NUM_WARPS` |

### 1.2 时钟与复位

- 单时钟域。要跨域时先停下来想清楚，用异步 FIFO，不要随手打两拍。
- 同步复位，低有效（`aresetn`）。所有时序逻辑统一用 `if (!aresetn)` 分支。
- 复位树不要太大：只复位控制路径，数据通路的寄存器可以不复位（省面积、利于时序），
  但要保证"没有有效数据就不会被读"。

```systemverilog
always_ff @(posedge clk) begin
    if (!aresetn) begin
        state_q <= IDLE;
    end else begin
        state_q <= state_d;
    end
end
```

### 1.3 握手（valid/ready）

统一采用 valid 不被 ready 阻塞的协议：

- `valid` 一旦拉起，必须保持到握手完成（`valid && ready`）。
- `data` 在 `valid` 期间必须稳定。
- 接收方可以"不 ready"，但不能"先 ready 后反悔"。
- 不允许组合路径穿透：`ready` 不能组合依赖下游的 `ready` 再回头影响本级的 `valid`
  （会形成组合环）。

接口归属原则：谁驱动接口，谁负责在自己的输出端打拍。下游消费方不许给别人的接口
再插一级寄存器，那会让数据和控制信号不同步。需要缓冲时，在拥有接口的那一级的
输出处插 `SK_elastic_buffer`。

### 1.4 组合逻辑

- 用 `always_comb`，所有分支必须赋值（否则综合出 latch）。
- 不用 `always @(*)` 加不完整赋值。
- 禁止组合环；跨模块的组合路径只允许出现在叶子模块内部。
- 三目运算符能表达清楚的，就用连续赋值 `assign`。

### 1.5 状态机

- 用三段式：状态寄存器 / 次态组合逻辑 / 输出逻辑。
- 状态用 `typedef enum logic [N:0] {…}`，不要用散落的 `parameter` 魔数。
- 每个状态都要考虑复位和非法状态的兜底（`default: state_d = IDLE;`）。

### 1.6 存储与 DSP

- **寄存器堆不用 BRAM**：每 lane 32×32b、3 读 1 写（`FMA` 的 `rd` 既读又写），
  用分布式 RAM（LUTRAM）或 FF 阵列。
  综合时确认推断成 `RAM32M`/`RAM64X1D` 一类分布式 RAM；不要让它意外落成 BRAM，
  也不要落成纯 LUT 大 mux 导致面积膨胀。
- **BRAM 的使用者**：IMEM、shared memory、以后的 cache。IMEM 和 shared 都是
  同步读 + 同步写。

BRAM 推断模板：

```systemverilog
// 同步读 + 同步写 → 综合成 BRAM
always_ff @(posedge clk) begin
    if (we) begin
        mem[addr_w] <= data_in;
    end
    rdata <= mem[addr_r];      // 独立的读端口，必须寄存输出
end
```

- 想让它变成 BRAM：读地址也必须寄存（`do_reg=1` 风格）。
- 想让它变成分布式 RAM：小容量、异步读。
- 始终检查综合报告：`report_utilization` 里的 `RAMB36/RAMB18` 是否真的被推断出来。
  只用 LUT 实现的"内存"会吃掉几千 LUT，这是最常见的面积灾难。
- 乘法写成 `a * b` 并加寄存器打拍，让 Vivado 映射到 DSP48。一个 DSP48E2 可以做
  27×18 乘法或两个 INT8 乘加，做张量单元时要利用这一点。

### 1.7 面积与时序意识

- 写代码时就想"这条路径要穿过几个模块"：跨模块的组合逻辑是 P&R 的头号敌人。
- 宽总线（> 128 bit）要打拍，并尽量走同一个区域。
- 优先级链越长，时序越差；超过 4–5 级的优先级改用仲裁器。
- 每完成一个阶段跑一次综合，把 LUT/FF/BRAM/DSP 记下来。面积会悄悄膨胀，
  三个月后突然发现放不下就来不及了。

### 1.8 mask 单元的实现注意

- `M` 是每 warp 一个 N 位 FF 寄存器；保存的 mask 值放在 GPR 里（全 lane 同一副本），
  不要为 mask 单独做寄存器堆。谓词 `p0..p7` 是每 lane 1 位 FF。
- `.P`/`.PM` 类 mask 指令把谓词按 `p & M` 读（inactive lane 的旧谓词不会把 lane
  复活），之后是普通位运算——结果**不**再与 `M` 相干，要交集就显式把当前 `M` 当 `ra`。
  mask 指令是 warp 级操作，不受 `M` 门控。
- mask 指令是纯位运算（AND/ANDN/OR/NOT + 谓词组合），做成一个小 ALU，
  不需要多周期；mask 写入在提交级生效，避免和分支重定向同拍竞争。
- `M` 是写回和访存的统一门控：有效 lane = `M & @p`；mask 指令本身是 warp 级操作，
  不受 `M` 门控。
- `M` 的写入者有 `MREST`（GPR -> `M`，汇编器用它重聚）、`MCLR.P`（`M &= ~p`，
  break/continue 的"跳过本轮剩余部分"）和 `.PM`（同拍写 `rd` 和 `M`，用旧 `M` 算）。
- 统一分支（`BRZ/BRNZ`）在译码/执行级解析并重定向（P1 的 2 级核就在执行级），清掉
  年轻指令；没有重聚栈、没有比较器、没有栈深限制。
- `BAR` 的完整 mask 由硬件在运行时检查：`M` 不等于完整 mask 就报 `BAR_INCOMPLETE`。
  v0.1 的汇编器不做静态检查（见 [plan.md](plan.md) 的 P0）。
- 调试试错靠一个只读扫描口：地址选 GPR / `M` / 谓词，数据是读出来的值，testbench
  用它和黄金模型逐寄存器对拍（P1 的 `SK_core` 就是这么做）；上板前换成 AXI-Lite
  读出口或者去掉。没有这个口，mask 序列出错时只能靠猜。

### 1.9 禁止事项速查

| 禁止 | 替代 |
|---|---|
| latch（不完整 if/case） | `always_comb` 全赋值 |
| 异步复位 | 同步复位 |
| 跨模块组合路径 | 输出端打拍 |
| `#delay` 等仿真专用语法 | testbench 里用，RTL 里禁用 |
| 同一信号多驱动 | 单一驱动源 |
| 用 `integer` 做可综合循环变量 | `genvar` / `for` + 常量边界 |
| 手写魔数位宽（`data[31:8]`） | 用 `$bits` / 参数化宽度 |

## 2. U250 上板（P6）

### 2.1 打包（开发机）

打包前先让 `$PLATFORM` 指向 U250 的 `.xpfm`。接口约定见 [design.md](design.md) §9，
`SK_afu` 的 RTL 直接交给 `v++`：

```bash
cd syn/u250

v++ -c --platform $PLATFORM --target hw --kernel SK_afu \
    -o build/SK_afu.xo rtl/top/SK_afu.v ...      # RTL kernel：.v 直接给 v++

v++ -l --platform $PLATFORM --target hw \
    --config link.cfg -o build/skein.xclbin build/SK_afu.xo
```

注意事项：

1. RTL kernel 不必先走"综合成 `.xo`"的传统流程，可以直接用 `v++ -l` 打包 RTL。
2. 环境里不要导出 `XILINX_XRT`，否则打包最后一步会用到 XRT 的 xclbinutil 而失败。
3. 链接很慢，U250 上一次 1 核设计预计 30–90 分钟，用 `setsid nohup … &` 挂着跑。

### 2.2 目标机准备

```bash
# 1) 装 XRT
sudo apt install ./xrt_202220.2.14.354_22.04-amd64-xrt.deb
source /opt/xilinx/xrt/setup.sh

# 2) 装 shell / 固件（首次或换版本时）
cd deploy && sudo apt install ./xilinx-*.deb
sudo xbmgmt program --base -d <BDF> \
     --image /lib/firmware/xilinx/f8dac62e49d9b0aae9fc6f260d9d0dfb
sudo reboot

# 3) 确认
xbutil examine          # Platform 一行应显示 xilinx_u250_gen3x16_xdma_4_1_202210_1
```

### 2.3 主机程序

主机程序用 XRT 原生 API（`xrt::device` / `xrt::bo` / `xrt::kernel`）。和旧方案的
区别是：**启动前要先通过 `s_axi_control` 的 IMEM 装载口把指令镜像写进去**，
然后再写 kernel 参数。

```cpp
#include <xrt/xrt_device.h>
#include <xrt/xrt_bo.h>
#include <xrt/xrt_kernel.h>

xrt::device device(0);
auto uuid = device.load_xclbin("skein.xclbin");
xrt::kernel krnl(device, uuid, "SK_afu");

// 1) 通过 register map 装载 IMEM 镜像（每字一个 AXI-Lite 写）
// 2) 写 GRID_DIM / BLOCK_DIM / PTR_A/B/C / ARG0..（BLOCK_DIM 必须是 SK_NUM_LANES 的整数倍）

// 3) 数据缓冲
xrt::bo bo_a(device, bytes, krnl.group_id(0));
...
bo_a.sync(XCL_BO_SYNC_BO_TO_DEVICE);
auto run = krnl(bo_a, bo_b, bo_c, n);      // 参数顺序 = kernel 形参顺序
run.wait();
bo_c.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
```

在目标机上编译（本机 Arch 的 glibc/boost 和 XRT 不匹配）：

```bash
g++ -g -O2 -std=c++17 -I$XILINX_XRT/include host.cpp \
    -o skein_run -L$XILINX_XRT/lib -lxrt_coreutil -pthread
```

### 2.4 板卡限制

- v0.1 只使用 `DDR[0]`（16 GB，理论约 19 GB/s）。多 bank 需要编译期未知的 XRT
  虚拟地址偏移，先不做。
- Vitis 平台会把 `gmem0` 默认映射到某个 bank，要用
  `--connectivity.sp SK_afu_1.m_axi_gmem:DDR[0]` 显式指定到 `DDR[0]`。
- 平台 shell 占掉约 15% 资源，U250 留给用户的是 1,488,120 LUT / 10,634 DSP。

### 2.5 上板调试顺序

1. `xbutil examine`：平台和 shell 版本对不对。
2. `xbutil validate`：卡本身是否健康（跑官方带宽/校验测试）。
3. 加载 xclbin 是否成功（`load_xclbin` 抛异常大多是 shell 版本不匹配）。
4. 控制寄存器能否读写（读回 `CTRL` 的 `ap_idle` 位）。
5. IMEM 装载和入口 PC 是否正确（先跑一个只做 `EXIT` 的空 kernel）。
6. 小规模数据与仿真 dump 逐字节比对。
7. 放大规模，记录实际频率与带宽。
