#!/usr/bin/env bash
# 把 SK_afu.xo 链成 .xclbin（在安装了 U250 平台的机器上跑）。
#
#   ./build_xclbin.sh [out_dir]        # 先跑 build_xo.sh，再链接
#
# 链接很慢（U250 上 30–90 分钟），脚本用 nohup 挂后台，日志写 <out>/link.log。
# 注意：链接时要把 XILINX_XRT 从环境里去掉，否则最后一步 xclbinutil 会失败
# （practice.md §2.1）。
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/u250}
platform=${PLATFORM:-/opt/xilinx/platforms/xilinx_u250_gen3x16_xdma_4_1_202210_1/xilinx_u250_gen3x16_xdma_4_1_202210_1.xpfm}
log=$out/link.log

mkdir -p "$out"
if [ ! -f "$out/SK_afu.xo" ]; then
    "$repo/syn/u250/build_xo.sh" "$out"
fi

cd "$repo"
echo "链接日志：$log"
setsid nohup env -u XILINX_XRT v++ -l --platform "$platform" --target hw \
    --config "$repo/syn/u250/link.cfg" --kernel_frequency 200 \
    -o "$out/skein.xclbin" "$out/SK_afu.xo" > "$log" 2>&1 &
echo "已在后台启动（pid $!），用 tail -f $log 看进度"
