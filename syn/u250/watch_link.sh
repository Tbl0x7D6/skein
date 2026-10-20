#!/usr/bin/env bash
# 看 .xclbin 链接（v++ -l）的进度：当前阶段 / 布线 overlap / 日志新鲜度 / 进程。
#
#   ./watch_link.sh              # 单次
#   ./watch_link.sh 60           # 每 60 秒刷新
#   WATCH_HOST=user@build-host ./watch_link.sh 60   # 从别的机器看（ssh 到该机器上跑同一份脚本）
set -u

REPO=${REPO:-$HOME/skein}
LINK=$REPO/build/u250/link.log
IMPL=$(ls -t "$REPO"/_x/link/vivado/vpl/prj/prj.runs/impl_*/runme.log 2>/dev/null | head -1)

age_min() { echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 60 )); }

probe() {
    echo "=== $(date '+%F %T')${WATCH_HOST:+ @$WATCH_HOST}"

    echo "--- 进程"
    local vpp
    vpp=$(pgrep -f 'v\+\+ -l' | head -1)
    if [ -n "$vpp" ]; then
        ps -o pid=,etime= -p "$vpp" | awk '{printf "  v++ -l : pid %s 已跑 %s\n", $1, $2}'
        ps -eo pcpu=,etime=,pid=,comm= --sort=-pcpu | grep -E 'vivado' | head -2 |
            awk '{printf "  %-7s: pid %s 已跑 %s（cpu %s%%）\n", $4, $3, $2, $1}'
    else
        echo "  v++ -l: 没在跑（链接结束或者被杀）"
    fi

    echo "--- 当前阶段（build/u250/link.log 尾部）"
    tail -n 3 "$LINK" 2>/dev/null || echo "  （读不到 $LINK）"

    echo "--- 布线 overlap（impl runme.log 最后几次，最后一行是最近的状态）"
    grep 'Number of Nodes with overlaps' "$IMPL" 2>/dev/null | tail -6 ||
        echo "  （还没进 route_design，或者读不到 $IMPL）"

    local f age
    for f in "$LINK" "$IMPL"; do
        [ -f "$f" ] || continue
        age=$(age_min "$f")
        echo "  $(basename "$f") 最后写入 $(stat -c %y "$f" | cut -c12-19)（${age} 分钟前）"
    done
    if [ -n "$IMPL" ] && [ "$(age_min "$IMPL")" -gt 45 ]; then
        echo "提示：runme.log 超过 45 分钟没更新 = 当前那一轮 rip-up/reroute 还在跑（一轮 30–60 分钟）"
    fi
}

# 指定了 WATCH_HOST 就在远端跑同一份脚本（远端不会再看到 WATCH_HOST，不会递归）
if [ -n "${WATCH_HOST:-}" ]; then
    if [ "${1:-0}" -gt 0 ] 2>/dev/null; then
        while :; do ssh "$WATCH_HOST" "REPO='$REPO' bash -s" < "$0"; sleep "$1"; done
    else
        ssh "$WATCH_HOST" "REPO='$REPO' bash -s" < "$0"
    fi
    exit
fi

probe
if [ "${1:-0}" -gt 0 ] 2>/dev/null; then
    while :; do sleep "$1"; probe; done
fi
