#!/usr/bin/env bash
# 在板卡机上编译主机程序（开发机的 glibc/boost 可能与 XRT 不匹配）。
# 依赖：/usr/include/xrt + uuid-dev（uuid/uuid.h）
set -euo pipefail
cd "$(dirname "$0")"
g++ -O2 -std=c++17 -Wno-deprecated-declarations skein_run.cpp \
    -o skein_run -lxrt_coreutil -luuid -pthread
echo "编译完成：$(pwd)/skein_run"
