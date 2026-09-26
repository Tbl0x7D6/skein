# SK_core 的综合扫描：同一个核按不同 lane 数各跑一遍，报 LUT / FF / BRAM / URAM / DSP
# 和 200 MHz 约束下的 WNS，用来决定 `SK_NUM_LANES`（见 docs/plan.md 的 P2、
# docs/design.md §12.6）。
#
# 只做到 `opt_design`：面积是综合后的准确值，WNS 是综合后的估计（没布局布线）。
# 作为"能不能收敛"的下界够用——综合后都不收敛，实现完只会更差；真实的 Fmax 等
# P3 拆完流水线之后在实现流程里量。
#
# 用法：vivado -mode batch -source syn/synth_core.tcl -tclargs <lanes> <out_dir>
# 或者直接 `make synth`（默认扫 4 / 8 / 16，报告落在 build/syn/lanes*/）。
#
# lane 数靠 `-verilog_define SK_NUM_LANES=$lanes` 覆盖 SK_config.vh 里的默认值，
# 所以 RTL 只有一份、不改代码。

if {[llength $argv] < 2} {
    puts "用法：vivado -mode batch -source syn/synth_core.tcl -tclargs <lanes> <out_dir>"
    exit 2
}
set lanes  [lindex $argv 0]
set outdir [lindex $argv 1]
set part   "xcu250-figd2104-2L-e"
set period "5.000"

file mkdir $outdir

# read_verilog 没有 define 选项，所以先读一个只有 `define 的小文件，再读 RTL：
# SK_config.vh 里的 ifndef 守卫看到已经定义过就不会覆盖。
set defines "$outdir/defines.v"
set fh [open $defines w]
puts $fh "`define SK_NUM_LANES ${lanes}"
close $fh

# 出上下文综合：核的端口有 800+ 位（sreg / 访存 / 扫描口），当顶层会撞 I/O 上限。
# OOC 不插 I/O buffer，逻辑照样保留（上板时它会被包进 SK_top）。
read_verilog -sv $defines [glob rtl/SK_pkg.sv rtl/lib/*.sv rtl/core/*.sv rtl/mem/*.sv]
synth_design -top SK_core -part $part -include_dirs rtl -flatten_hierarchy rebuilt -mode out_of_context
create_clock -period $period -name aclk [get_ports clk]
opt_design

report_utilization -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing.rpt

# 从利用率报告里抠出四个数字（报告格式跨版本比较稳）
set util [report_utilization -return_string]
proc pick {text pattern} {
    if {[regexp $pattern $text -> value]} { return $value }
    return "?"
}
set lut   [pick $util {CLB LUTs\*?\s*\|\s*(\d+)}]
set ff    [pick $util {CLB Registers\s*\|\s*(\d+)}]
set bram  [pick $util {Block RAM Tile\s*\|\s*(\d+)}]
set uram  [pick $util {URAM\s*\|\s*(\d+)}]
set dsp   [pick $util {DSPs\s*\|\s*(\d+)}]
set wns   [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]

puts "SYNTH lanes=$lanes part=$part period=${period}ns LUT=$lut FF=$ff BRAM=$bram URAM=$uram DSP=$dsp WNS=${wns}ns"
exit 0
