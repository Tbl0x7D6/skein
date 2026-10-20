#!/usr/bin/env bash
# 上板验收脚本（在板卡机上跑）：先 smoke，再 vecadd、sgemm64。
#
#   ./board_run.sh <xclbin> <arm 目录>      # arm 目录里放 vecadd.bin / sgemm64.bin
#
# 第一次上板建议按顺序：--smoke（确认 xclbin 能加载、寄存器读写正常）→ vecadd
# （最简单）→ sgemm64（大一点的负载）。结果和仿真/黄金模型的 case 一致。
set -euo pipefail

xclbin=${1:?用法：board_run.sh <xclbin> <arm 目录>}
arm=${2:?用法：board_run.sh <xclbin> <arm 目录>}
run=$(cd "$(dirname "$0")/../runtime" && pwd)/skein_run

if [ ! -x "$run" ]; then
    echo "先编译主机程序：sw/runtime/build.sh"
    exit 2
fi

echo "== 1/3 smoke（xclbin 加载 + 寄存器读写 + SHAPE）"
sudo "$run" --xclbin "$xclbin" --smoke

echo "== 2/3 vecadd（n=1024，和 cases/bench/vecadd_stream 同一份数据）"
sudo "$run" --xclbin "$xclbin" --image "$arm/vecadd.bin" --workload vecadd

echo "== 3/3 sgemm64（int32 64×64）"
sudo "$run" --xclbin "$xclbin" --image "$arm/sgemm64.bin" --workload sgemm64
