# SK_core 的面积扫描：和 synth_core.tcl 一样做一次 OOC 综合，但可以额外覆盖
# SK_config.vh 里的开关（比如 SK_L1=0 / SK_COALESCE=0），用来量化某个特性值多少
# LUT。P6 上板时用它决定"精简版"核（关掉 L1/coalescer）能省下多少资源。
#
# 用法：vivado -mode batch -source syn/synth_area.tcl -tclargs <lanes> <out_dir> <extra_defines...>
#   例：-tclargs 4 /tmp/area_full {}   /   -tclargs 4 /tmp/area_lean {SK_L1=0 SK_COALESCE=0}

if {[llength $argv] < 3} {
    puts "用法：vivado -mode batch -source syn/synth_area.tcl -tclargs <lanes> <out_dir> {<extra_defines>}"
    exit 2
}
set lanes  [lindex $argv 0]
set outdir [lindex $argv 1]
set extra  [lindex $argv 2]
set part   "xcu250-figd2104-2L-e"

file mkdir $outdir

# 和 synth_core.tcl 一样：先读一个只有 `define 的小文件，靠 SK_config.vh 的
# ifndef 守卫覆盖默认值。
set defines "$outdir/defines.v"
set fh [open $defines w]
puts $fh "`define SK_NUM_LANES ${lanes}"
foreach d [regexp -all -inline {\S+} $extra] {
    set kv [split $d =]
    puts $fh "`define [lindex $kv 0] [lindex $kv 1]"
}
close $fh
puts "AREA extra_defines={$extra}"

read_verilog -sv $defines [glob rtl/SK_pkg.sv rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv \
                               rtl/sched/*.sv rtl/perf/*.sv]
synth_design -top SK_core -part $part -include_dirs rtl -flatten_hierarchy rebuilt -mode out_of_context
report_utilization -file $outdir/utilization.rpt

set util [report_utilization -return_string]
proc pick {text pattern} {
    if {[regexp $pattern $text -> value]} { return $value }
    return "?"
}
puts "AREA lanes=$lanes extra={$extra} LUT=[pick $util {CLB LUTs\*?\s*\|\s*(\d+)}] FF=[pick $util {CLB Registers\s*\|\s*(\d+)}] BRAM=[pick $util {Block RAM Tile\s*\|\s*(\d+)}] URAM=[pick $util {URAM\s*\|\s*(\d+)}] DSP=[pick $util {DSPs\s*\|\s*(\d+)}]"
exit 0
