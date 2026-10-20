# 把 RTL（rtl/top/SK_afu.sv）打成 Vitis 的 .xo —— 这就是 RTL Kernel Wizard 的
# package_xo 流程，只是工程是我们自己建的（不用图形界面）。
#
# 用法：vivado -mode batch -source syn/u250/package_xo.tcl -tclargs <repo> <out_dir>
#
# 产物：<out_dir>/SK_afu.xo（RTL kernel，s_axi_control + 512-bit m_axi_gmem），
# 之后用 `v++ -l` 和平台链成 .xclbin（syn/u250/link.cfg）。

set repo [lindex $argv 0]
set out  [lindex $argv 1]
set part "xcu250-figd2104-2L-e"

file mkdir $out
create_project -force sk_afu_xo $out/proj -part $part

add_files -norecurse [concat \
    [glob $repo/rtl/SK_pkg.sv] \
    [glob $repo/rtl/lib/*.sv] \
    [glob $repo/rtl/core/*.sv] \
    [glob $repo/rtl/mem/*.sv] \
    [glob $repo/rtl/sched/*.sv] \
    [glob $repo/rtl/perf/*.sv] \
    [glob $repo/rtl/top/*.sv]]
set_property include_dirs [list $repo/rtl] [current_fileset]
set_property top SK_afu [current_fileset]

# RTL kernel 的 IP：接口由端口名推断（ap_clk / ap_rst_n / s_axi_control_* /
# m_axi_gmem_*），和 kernel.xml 里声明的名字对应
ipx::package_project -root_dir $out/SK_afu_ip -vendor skein.com -library kernel \
    -name SK_afu -version 1.0 -taxonomy /KernelIP -import_files -force
set core [ipx::current_core]

puts "== 推断出来的接口 =="
foreach bif [ipx::get_bus_interfaces -of $core] {
    puts "  [get_property NAME $bif] : [get_property BUS_TYPE_VLNV $bif]"
}

# 200 MHz、单 outstanding、一次一行（64 B = 1 个 512-bit beat）：把这些告诉 IP，
# 平台侧的 interconnect 才知道怎么连（和 design.md §9/§11 一致）
set freq_param [ipx::add_bus_parameter FREQ_HZ [ipx::get_bus_interfaces m_axi_gmem -of $core]]
set_property value 200000000 $freq_param
set_property value_source constant $freq_param
foreach {param value} {MAX_BURST_LENGTH 1 NUM_READ_OUTSTANDING 1 NUM_WRITE_OUTSTANDING 1} {
    set p [ipx::add_bus_parameter $param [ipx::get_bus_interfaces m_axi_gmem -of $core]]
    set_property value $value $p
    set_property value_source constant $p
}
set freq_param [ipx::add_bus_parameter FREQ_HZ [ipx::get_bus_interfaces s_axi_control -of $core]]
set_property value 200000000 $freq_param
set_property value_source constant $freq_param
ipx::associate_bus_interfaces -busif m_axi_gmem -clock ap_clk $core
ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
ipx::save_core $core

package_xo -xo_path $out/SK_afu.xo -kernel_name SK_afu \
    -ip_directory $out/SK_afu_ip -kernel_xml $repo/syn/u250/kernel.xml \
    -ctrl_protocol ap_ctrl_hs

puts "== 打包完成：$out/SK_afu.xo =="
exit 0
