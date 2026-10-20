#!/usr/bin/env bash
# 把 SK_afu 打进 .xo（RTL kernel）。在安装了 U250 平台的机器上跑。
#
#   ./build_xo.sh [out_dir]
#
# 走 Vivado 的 `ipx::package_project` + `package_xo`（见 package_xo.tcl）。手写 RTL
# 不能交给 `v++ -c`：v++ 会把它当 HLS 编，直接报 "Cannot find any design unit to
# elaborate"（P6.3 踩过）。
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$repo/build/u250}

mkdir -p "$out"
vivado -mode batch -nojournal -nolog -source "$repo/syn/u250/package_xo.tcl" \
    -tclargs "$repo" "$out"
