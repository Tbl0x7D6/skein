#!/usr/bin/env bash
# 精简版 .xo：把 L1 和 coalescer 关掉（SK_L1=0 SK_COALESCE=0）。
#
# 用途：P6 上板时布线堵在 SLR0（拥堵等级 6、几小时不收敛）。关掉这两个缓存通路
# 后核从 33.2K LUT 降到 27.4K LUT、BRAM 16→8（见 syn/synth_area.tcl），给布线留
# 余量。语义没变（M5 的 base 配置就是这两个开关全关，case 全过），只是访存变慢。
#
#   ./build_xo_lean.sh [out_dir]     # 默认 build/u250_lean
#
# 做法：把仓库拷到 <out_dir>/src（build/ 下面，不进 git），改掉 SK_config.vh 里
# 两个开关的默认值，再用同一套 rtl + kernel.xml 走 package_xo.tcl 打包（`.xo` 里
# 带的是 RTL 源码，所以只要这份源码的 SK_config.vh 是精简配置就行）。
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/u250_lean}
src=$out/src

mkdir -p "$src"
cp -r "$repo/rtl" "$src/rtl"
mkdir -p "$src/syn/u250"
cp "$repo/syn/u250/kernel.xml" "$src/syn/u250/kernel.xml"

# 只改默认值，ifndef 守卫保留（v++ 里没别的地方定义它们）
sed -i 's/^`define SK_COALESCE     1/`define SK_COALESCE     0/; s/^`define SK_L1           1/`define SK_L1           0/' \
    "$src/rtl/SK_config.vh"
grep -n "SK_COALESCE\|SK_L1" "$src/rtl/SK_config.vh"

vivado -mode batch -nojournal -nolog -source "$repo/syn/u250/package_xo.tcl" \
    -tclargs "$src" "$out"
echo "精简版 .xo：$out/SK_afu.xo"
