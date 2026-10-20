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
  用分布式 RAM（LUTRAM）或 FF 阵列。写使能是**每 lane 一个**（普通指令由 `M & @p`
  门控，多周期 load 只写当前 lane），所以 `SK_regfile` 的端口是 LANES 份的数组，
  不是一条共享写口。
  综合时确认推断成 `RAM32M`/`RAM64X1D` 一类分布式 RAM；不要让它意外落成 BRAM，
  也不要落成纯 LUT 大 mux 导致面积膨胀。多读口的小阵列 Vivado 经常直接给 FF + mux
  （4 lane 的核是 4172 个 FF），这可以接受；lanes 翻倍时看 LUT/FF 的增量。
- **BRAM 的使用者**：IMEM、shared memory、以后的 cache。IMEM 和 shared 都是
  同步读 + 同步写。4096×32 这种形状 Vivado 会优先给 URAM（IMEM 现在是 1 个
  URAM288），看报告时别只盯 `RAMB36`。
- **多 bank shared**（`SK_smem`）：bank 数 = lane 数，一个 bank 一个写口 + 一个同步
  读口，读地址就是本轮那条 lane 的地址。测试台的主机口（装初态 / 读快照）**借道**
  bank 的端口，只在核空闲时用；给主机读的地址和 lane 的地址要显式二选一，别让主机
  的 `host_raddr` 悄悄把某个 bank 的读口从本轮 lane 地址上抢走（P5 调试时踩过这个）。
- **L1**（`SK_l1_cache`）：数据阵列按"整行 512 bit 一个读口 + 一个写口"写，综合
  会给 BRAM；逐出的脏行先读进寄存器再按 beat 流出，填充也是先收集满一行再写回阵列。
  命中路径 = 发读地址 + tag 比较（组合）→ 下一拍数据 → 再一拍回 beat，别把 tag
  比较串到数据回来之后，那样命中要 3 拍。

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
- mask 指令是纯位运算（AND/ANDN/OR/NOT + 谓词组合），`rtl/core/SK_mask.sv` 是**纯组合**
  的：`M` 本身每 warp 一份存在核里，提交级才写回去，这样多 warp 共用一个组合逻辑。
- `M` 是写回和访存的统一门控：有效 lane = `M & @p`；mask 指令本身是 warp 级操作，
  不受 `M` 门控。mask 指令的 GPR 操作数要求全 lane 一致（`MSAVE` 广播出来的值天生
  满足），硬件只取 lane 0 的读数据、不做检查——一致性检查放在黄金模型里当断言。
- `M` 的写入者有 `MREST`（GPR -> `M`，汇编器用它重聚）、`MCLR.P`（`M &= ~p`，
  break/continue 的"跳过本轮剩余部分"）和 `.PM`（同拍写 `rd` 和 `M`，用旧 `M` 算）。
- 统一分支（`BRZ/BRNZ`/`JMP`）在执行级解析，读的是 lane 0 的 GPR；每条 warp 最多一条
  指令在流水里，所以不需要清年轻指令（`x_npc` 直接写回这条 warp 的 PC）。
- `BAR` 的完整 mask 由硬件在运行时检查：`M` 不等于完整 mask 就报 `BAR_INCOMPLETE`。
  v0.1 的汇编器不做静态检查（见 [plan.md](plan.md) 的 P0）。
- 调试试错靠一个只读扫描口：地址选 GPR / `M` / 谓词，`dbg_lane_i` 选 lane，数据是
  读出来的值，testbench 用它和黄金模型逐寄存器对拍；上板前换成 AXI-Lite 读出口或者
  去掉。没有这个口，mask 序列出错时只能靠猜。

### 1.9 多 warp 流水线的实现注意

- 取指要两级寄存器：`SK_imem` 是同步读，地址给出一拍后指令才出来。PC 必须和指令走
  同一条路径进 IF/ID（`f1` → `f2`），否则译码拿到的是"下一条的 PC + 上一条的指令"——
  错位不会报错，只会让分支目标整体错一拍。
- PC 的更新必须逐 warp 写：发射（+1）、重发（回退）、分支（跳目标）三件事各改各的
  warp，不能写成 `if (issue) … else if (replay) …`。写成全局 if/else 时，只要同一拍
  有别的 warp 发射，重发的 PC 回退就被吃掉，那条 warp 会静默跳过一条指令。
- 重发（replay）只丢 S3 那条指令、回退 PC，不动别的状态：所有写（寄存器、谓词、`M`、
  访存请求）都在 S4/S5，所以重发天生没有副作用。
- `BAR`/`EXIT` 要等提交（S5）才能让 warp 再发射：它们到提交级才改 warp 状态，早放出去
  会让 warp 取到 `EXIT` 后面那条已经越过程序末尾的 PC，假报 `PC_OOB` 把别的 warp 带走。
- 轮询扫描不能在"第一条没准备好的 warp"上停下：卡住的 warp 只应该被跳过，不能挡住它
  后面已经 ready 的 warp。P3 在这里踩过一次——顺手加停顿归因时把扫描写成了遇阻即停，
  4 warp 的 matmul 用例 IPC 从 0.72 掉到 0.65。
- scoreboard 的位在"请求最后一条 lane 做完"那一拍清，同一拍译码的指令还会看到旧值、
  再重发一次，这样数据一定已经进了寄存器堆；提前一拍清就会出现偶发的"读到旧值"。
- `LDG` 的回写和流水线提交抢同一个寄存器堆写口：按 warp 判冲突（`lsu_wb_stall`），让
  LSU 等一拍，而不是给寄存器堆加第二个写口（FF 阵列的第二写口是每个 bit 一组 mux）。
- 多周期访存（shared 的分轮、global 的合并/L1）里，"原地等"的状态必须把所有 fed
  给存储器的地址保持住：只要那些地址是"从当前状态组合算出来"的，等一拍就会变成别的
  地址，读口已经把正确的数据冲掉了（P5 在 shared 的 bank 读口上踩过）。要么在等待
  状态里继续驱动同一组地址，要么把读数据先锁进寄存器。
- 取指越界（`PC_OOB`）在 S3 判：这条指令直接丢掉、报错，trap 记的是被取的那个地址
  （黄金模型也是"PC 不前进"这个语义）。

### 1.10 禁止事项速查

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

### 2.1 打包

手写 RTL kernel 的打包走 Vivado 的 `package_xo` 流程（RTL Kernel Wizard 背后
那套），**不是**把 `.sv` 丢给 `v++ -c`——那条路会把文件当 HLS 源码，报
`Cannot find any design unit to elaborate`。脚本都在 `syn/u250/`：

```bash
./syn/u250/build_xo.sh          # RTL → build/u250/SK_afu.xo（Vivado，几十秒）
./syn/u250/build_xclbin.sh      # .xo → .xclbin（v++ -l，30–90 分钟，挂后台写 link.log）
```

踩过的点：

1. `kernel.xml` 里每个 `m_axi` 端口至少要有一个 `addressQualifier="1"` 的指针参数
   映射上去，否则链接第一步报 *port is not mapped from any kernel argument*；
   我们的 `gmem_base` 就是那个指针（主机仍用 `write_register` 写它）。
2. `kernel.xml` 的 `vlnv` 必须和 IP 的 vendor:library:name:version 一致
   （脚本用 `-vendor skein.com -library kernel -name SK_afu -version 1.0`）。
3. 登录 profile 里设了 `XILINX_XRT`，链接前要 `env -u XILINX_XRT v++ -l ...`。
4. 平台默认 kernel 时钟 300 MHz，我们只收敛到 200 MHz：链接带
   `--kernel_frequency 200`。
5. IP 要显式关联时钟（`ipx::associate_bus_interfaces -busif … -clock ap_clk`），
   并给 `m_axi_gmem` 声明 `MAX_BURST_LENGTH=1` 和单 outstanding，interconnect
   才知道怎么连。

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

# 3) 确认（新版 XRT 里 xbutil 改叫 xrt-smi）
sudo xrt-smi examine    # Device Ready 应为 Yes，Shell 是 ..._shell_4_1
```

在板卡机上跑 XRT 通常要特权（用户不在 render 组时），命令前面加 `sudo`。
编译主机程序前先装 `uuid-dev`（XRT 头文件依赖 `uuid/uuid.h`）。

### 2.3 主机程序

主机程序在 `sw/runtime/skein_run.cpp`（XRT 原生 API）。要点是**不通过 `krnl(...)`
传参**，全部走 `s_axi_control` 的寄存器（`write_register`/`read_register`，在
XRT 2.21 里标了 deprecated 但仍然是那条 AXI-Lite 通路）：IMEM 镜像、参数、
`GMEM_BASE`（BO 的设备地址，写 0x30/0x34）、`CTRL.start`，然后轮询 `CTRL.done`。
核里的指针是 32 位偏移，AXI 地址由 master 加上 `GMEM_BASE`——BO 的地址可能
超过 4 GB，所以不能把 BO 地址直接当 kernel 里的指针用。

```cpp
xrt::device device(0);
auto uuid = device.load_xclbin("skein.xclbin");
xrt::kernel krnl(device, uuid, "SK_afu");

// 一块 BO 装下 A/B/C（偏移和 case 里一样）
xrt::bo bo(device, 1 << 20, krnl.group_id(0));
uint64_t base = bo.address();
// 写 IMEM 镜像（ADDR → WDATA → WE=1 每个字一次）、写参数，再写 GMEM_BASE
krnl.write_register(0x030, (uint32_t)base);
krnl.write_register(0x034, (uint32_t)(base >> 32));
krnl.write_register(0x000, 1);                  // CTRL.start
while (!(krnl.read_register(0x000) & 2)) {}     // 轮询 done
```

在板卡机上编译（开发机的 glibc/boost 可能与 XRT 不匹配）：

```bash
g++ -O2 -std=c++17 -Wno-deprecated-declarations skein_run.cpp \
    -o skein_run -lxrt_coreutil -luuid -pthread
```

### 2.4 板卡限制与 SLR/DDR 映射

- 平台的三个 DDR4 子系统按 `preopt.tcl` 里的 pblock 分别落在 **SLR0（`DDR[0]`/mem00）**、
  **SLR2（`DDR[1]`/mem01）**、**SLR3（`DDR[2]`/mem02）**；SLR1 没有内存控制器。
  `--connectivity.slr` 把 CU 钉到哪个 SLR，`--connectivity.sp` 就把它的数据绑到那个
  SLR 的内存上（`syn/u250/link_slr*.cfg`）。
- SLR0 最挤：XDMA/interconnect/`clkwiz_aclk_kernel_*` 都在里面，整个设计在 SLR0 已经
  占到约 28% 的 CLB；SLR2 约 6%，SLR3 基本是空的。P6.3 把 CU 钉在 SLR0 时，512-bit
  AXI 打进去会堵到拥堵等级 6、全局布线几小时不收敛；换 SLR 是首选手段。
- 板上有 16 GB × 4 个 bank（bank3 报成 MEM_DRAM）+ 4 × 128 KB PLRAM，v0.1 只用其中
  一个 bank。主机把 BO 地址写进 `GMEM_BASE`（0x30/0x34）告诉核，所以换 bank 不用改
  RTL：BO 由 XRT 按 kernel 的 `sp` 映射分配，基址可能是 0x4/0x5/0x6_0000_0000。
- 平台 shell 占掉约 15% 资源，U250 留给用户的是 1,488,120 LUT / 10,634 DSP（空闲
  SLR2/SLR3 的 LUT/BRAM 都在这个预算里，钉 SLR 只是选地方放）。

### 2.5 上板调试顺序

1. `xbutil examine`：平台和 shell 版本对不对。
2. `xbutil validate`：卡本身是否健康（跑官方带宽/校验测试）。
3. 加载 xclbin 是否成功（`load_xclbin` 抛异常大多是 shell 版本不匹配）。
4. 控制寄存器能否读写（读回 `CTRL` 的 `ap_idle` 位）。
5. IMEM 装载和入口 PC 是否正确（先跑一个只做 `EXIT` 的空 kernel）。
6. 小规模数据与仿真 dump 逐字节比对。
7. 放大规模，记录实际频率与带宽。

### 2.6 让卡跑在 xdma shell 上（DFX-2RP 的 shell 分区编程）

这个平台是 **DFX-2RP**：flash 里是 **base 平台**（`xilinx_u250_gen3x16_base_4`，
逻辑 UUID `F8DAC62E…`、接口 UUID `807a580e…`），它只提供 PCIe + ICAP；核要的
**xdma shell**（`xilinx_u250_gen3x16_xdma_shell_4_1`，接口 UUID `a8880c23…`）是
运行时编进 RP 分区的。两者不匹配时 xocl 直接拒收（Xilinx 自带的
`xdma-shell/test/verify.xclbin` 也一样，所以不是我们 xclbin 的问题）：

```
xocl_fdt_check_uuids: Can not find uuid a8880c2311a2a42b5fb76899d385acee
xocl_read_axlf_helper: interface uuids do not match   →  err -22
```

**能用的办法**（XRT 2.21 不会自动下载 shell；`xbmgmt program --base shell --image=
<shell xsabin>` 走的是写 flash，要 MCS 镜像，包装里没有）——直接走驱动的 ICAP
字符设备 + `rp_program`（语义见 `driver/xocl/subdev/icap.c` 的 `icap_write_rp` 和
`driver/xocl/mgmtpf/mgmt-sysfs.c` 的 `rp_program_store`）：

```bash
# 1) 把 shell 的 xsabin 暂存给驱动（它会解析 axlf、存下 bit + SC 固件）
sudo sh -c 'cat /lib/firmware/xilinx/a8880c2311a2a42b5fb76899d385acee/partition.xsabin \
            > /dev/xfpga/icap.m256.0'
# 2) 请求编程 RP：1 = 从暂存的镜像装 shell，2 = 走「重编 shell」的完整流程
echo 1 | sudo tee /sys/class/xrt_mgmt/xclmgmt256/device/rp_program
# 3) 确认（约 20–40 秒后）
sudo xrt-smi examine -r platform | grep -E "XSA Name|Logic UUID"
# 期望：xilinx_u250_gen3x16_xdma_shell_4_1 / 12C8FAFB-0632-499D-B1C0-C6676271B8A6
```

注意：

- **shell 是易失的**：`rmmod/modprobe xclmgmt`、host 重启、`xbmgmt program --boot …`
  都会让卡回到 flash 里的 base 平台，要重新做上面三步（每次约 1 分钟）。
- `rp_program` 在**没暂存镜像**时写 1 会失败（`Invalid reprogram request`）并且把标志
  卡在 REQ（之后写 1 报 EBUSY）——重载一次 xclmgmt 清状态、先暂存再写 1 即可。
- 装 shell 时驱动会等 MIG 校准（10 秒）并可能报 `program prp failed -62`（ETIMEDOUT）；
  这个时候 shell 其实**已经装进去了**（platform 显示 xdma shell），DDR 也能用
  （`xrt-smi examine -r memory` 能列出 bank0–3 的温度就是证明）。别急着重来。
- 上板前先看 `xrt-smi examine -r platform` 的 `XSA Name`：是 base 就先把 shell 装上。

### 2.7 主机程序（XRT 原生 API）的两个坑

写 `skein_run` 时踩到、并且和 `kernel.xml` 的写法直接相关的两条：

1. **BO 要按连 m_axi 的那个参数分配**。我们的 `kernel.xml` 里指针参数
   `gmem_base` 的 id 是 **8**（0..7 都是标量寄存器参数），所以必须
   `kernel.group_id(8)`；写成 `group_id(0)` 时 XRT 会拿标量参数的内存组，去分配
   host/userptr BO，报 `failed to allocate userptr bo: Operation not permitted`。
2. **`read_register`/`write_register` 要 CU 独占访问**：`xrt::kernel` 默认是 shared，
   XRT 2.21 下会抛 `Cannot read or write kernel with shared access`；构造时传
   `xrt::kernel::cu_access_mode::exclusive`。
