#!/usr/bin/env bash
# 备用链接：换一个 connectivity 配置再链一遍，输出到单独的目录，
# 和正在跑的主链接互不干扰（各自的 build 目录 + --temp_dir）。
#
#   ./build_xclbin_alt.sh [out_dir] [cfg] [额外的 v++ 参数...]
#
# 默认是 link_slr0.cfg（CU 钉在 SLR0，DDR[0]）。换 SLR 试的时候传别的 cfg，
# 比如 ./build_xclbin_alt.sh build/u250_slr2 syn/u250/link_slr2.cfg。
# 后面跟的额外参数原样传给 v++ -l，比如换布局指令：
#   ./build_xclbin_alt.sh build/u250_ssi syn/u250/link_slr0.cfg \
#       --vivado.prop run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=SSI_SpreadLogic_high
# 要换核时钟就设 KERNEL_FREQ（默认 200 MHz，改成 150 能让时序/布线都松一点）。
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/u250_slr0}
cfg=${2:-$repo/syn/u250/link_slr0.cfg}
shift 2 || true
extra=("$@")
freq=${KERNEL_FREQ:-200}
platform=${PLATFORM:-/opt/xilinx/platforms/xilinx_u250_gen3x16_xdma_4_1_202210_1/xilinx_u250_gen3x16_xdma_4_1_202210_1.xpfm}
log=$out/link.log

mkdir -p "$out"
if [ ! -f "$out/SK_afu.xo" ]; then
    cp "$repo/build/u250/SK_afu.xo" "$out/SK_afu.xo"
fi

cd "$repo"
echo "备用链接日志：$log（config=$cfg，${freq} MHz${extra:+，extra=${extra[*]}}）"
setsid nohup env -u XILINX_XRT v++ -l --platform "$platform" --target hw \
    --config "$cfg" --kernel_frequency "$freq" \
    "${extra[@]}" \
    --temp_dir "$out/_x" \
    -o "$out/skein.xclbin" "$out/SK_afu.xo" > "$log" 2>&1 &
echo "已在后台启动（pid $!）"
