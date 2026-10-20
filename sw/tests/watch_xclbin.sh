#!/usr/bin/env bash
# P6 上板看门狗：盯着编译机上几个链接目录，谁先产出可用的 .xclbin，就在板卡机上
# 自动跑一遍 smoke → vecadd → sgemm64，结果记到 build/p6_watch/<tag>.log。
#
#   BUILD_HOST=user@build-host BOARD_HOST=user@board-host \
#   BUILD_REPO=/path/to/skein BOARD_REPO=/path/to/skein \
#   ./watch_xclbin.sh [最多等多少小时] [轮询间隔秒]
#
# 每个 .xclbin 只测一次（跑过就写 <tag>.done）。判断"链接完成"的条件：
#   1) 编译机上没有对应的 `v++ -l` 进程（避免拿到还在写的文件）；
#   2) <dir>/skein.xclbin 存在，且大小连续两轮不变。
#
# 需要本机能 ssh 到编译机和板卡机（板卡机上要有 sudo 权限）。
# 前台跑或 `nohup ./watch_xclbin.sh > /dev/null 2>&1 &` 都行。
set -uo pipefail

build_host=${BUILD_HOST:?请设置 BUILD_HOST（编译机，例如 user@host）}
board_host=${BOARD_HOST:?请设置 BOARD_HOST（板卡机，例如 user@host）}
build_repo=${BUILD_REPO:?请设置 BUILD_REPO（编译机上的仓库路径）}
board_repo=${BOARD_REPO:?请设置 BOARD_REPO（板卡机上的仓库路径）}

hours=${1:-12}
interval=${2:-60}
# 目录名 = 编译机上 build/<tag>/ 里放了 SK_afu.xo 的链接目录，每轮重新扫，
# 这样中途新开的链接（换 SLR、换配置）不用改脚本、不用重启看门狗。
tags=()
scan_tags() {
    local found
    found=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$build_host" \
        "ls -d '$build_repo'/build/*/SK_afu.xo 2>/dev/null" 2>/dev/null) || return 0
    local path
    for path in $found; do
        tags+=("$(basename "$(dirname "$path")")")
    done
}

repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$repo/build/p6_watch
mkdir -p "$out"

declare -A last_size=()
declare -A done=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

remaining=$((hours * 3600))
while [ "$remaining" -gt 0 ]; do
    tags=()
    scan_tags
    all_done=true
    for tag in "${tags[@]}"; do
        [ -n "${done[$tag]:-}" ] && continue
        all_done=false

        dir=$build_repo/build/$tag
        # 注意 pgrep 的模式要写成 skein[.]xclbin：直接写 skein.xclbin 的话，远端
        # shell 自己的命令行里就带着这个字符串，pgrep 会匹配到自己，永远报"还在跑"
        # （P6.3 踩过：看门狗整晚误报，xclbin 落地了也没测）。
        state=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$build_host" \
            "if pgrep -f 'build/${tag}/skein[.]xclbin' > /dev/null; then echo RUNNING; \
             elif [ -f '$dir/skein.xclbin' ]; then echo \"SIZE \$(stat -c %s '$dir/skein.xclbin')\"; \
             else echo NONE; fi" 2>/dev/null) || { log "$tag: 编译机连不上，跳过这轮"; continue; }

        case "$state" in
            RUNNING*) log "$tag: v++ 还在链接" ; continue ;;
            NONE*)    log "$tag: 还没有 xclbin" ; continue ;;
        esac

        size=${state#SIZE }
        if [ "${last_size[$tag]:-x}" != "$size" ]; then
            last_size[$tag]=$size
            log "$tag: xclbin 出现（$size 字节），等一轮确认写完"
            continue
        fi

        # 链接进程已退出 + 大小稳定 → 拉下来，送到板卡机测
        log "$tag: 开始上板（xclbin $size 字节）"
        marker=$out/$tag.done
        if [ -f "$marker" ]; then
            done[$tag]=1
            continue
        fi

        if ! ssh -o BatchMode=yes "$build_host" "cat '$dir/skein.xclbin'" > "$out/$tag.xclbin" 2>/dev/null; then
            log "$tag: 取 xclbin 失败"
            continue
        fi
        if ! tar czf - -C "$out" "$tag.xclbin" -C "$repo/build/board" \
                vecadd.bin sgemm64.bin 2>/dev/null |
                ssh -o BatchMode=yes "$board_host" "mkdir -p '$board_repo/p6' && tar xzf - -C '$board_repo/p6'" 2>/dev/null; then
            log "$tag: 传到板卡机失败"
            continue
        fi

        {
            echo "==== $tag 上板测试 $(date '+%F %T') ===="
            echo "---- xclbin: $out/$tag.xclbin ($size 字节)"
            echo "---- 0/4 设备信息"
            ssh -o BatchMode=yes "$board_host" 'sudo xrt-smi examine -r platform 2>&1 | head -20'
            for step in "1/4 smoke:--smoke" \
                        "2/4 vecadd:--image $board_repo/p6/vecadd.bin --workload vecadd" \
                        "3/4 sgemm64:--image $board_repo/p6/sgemm64.bin --workload sgemm64"; do
                name=${step%%:*}; extra=${step#*:}
                echo "---- $name"
                # shellcheck disable=SC2086
                ssh -o BatchMode=yes "$board_host" "cd '$board_repo' && sudo sw/runtime/skein_run \
                    --xclbin '$board_repo/p6/$tag.xclbin' $extra 2>&1 | tail -30"
            done
        } > "$out/$tag.log" 2>&1

        if grep -q 'PASS' "$out/$tag.log" 2>/dev/null; then
            log "$tag: 日志见 $out/$tag.log（PASS）"
        else
            log "$tag: 日志见 $out/$tag.log（有 FAIL/报错，脚本继续盯别的 xclbin）"
        fi
        touch "$marker"
        done[$tag]=1
    done

    [ "$all_done" = true ] && { log "所有 xclbin 都测过了，退出"; exit 0; }
    sleep "$interval"
    remaining=$((remaining - interval))
done
log "等待超时（${hours} 小时），退出"
