#=============================================================================
# build_ip.tcl  -  Package pixel_generator_6.v (+ divider_seq.v, packer.v) as a
#                  Vivado IP that the block design can drop in.
#
# RUN THIS ON YOUR MACHINE WITH VIVADO (it was NOT run in the dev container --
# the container has no Vivado). From a shell:
#
#     vivado -mode batch -source build_ip.tcl
#
# Produces an IP repo under ./ip_repo/pixel_generator that base.tcl consumes.
# Adjust PART to your board (PYNQ-Z1 = xc7z020clg400-1).
#=============================================================================

set PART     xc7z020clg400-1
set IP_NAME  pixel_generator
set IP_VER   1.0
set SRC_DIR  [file normalize "./rtl"]
set IP_DIR   [file normalize "./ip_repo/$IP_NAME"]

# RTL sources that make up the IP (copy your verified files into ./rtl first)
set SOURCES [list \
    "$SRC_DIR/pixel_generator_6.v" \
    "$SRC_DIR/divider_seq.v" \
    "$SRC_DIR/packer.v" \
]

file mkdir $IP_DIR

create_project -force ${IP_NAME}_pkg ./_ip_pkg_proj -part $PART

add_files -norecurse $SOURCES
update_compile_order -fileset sources_1

# top module is `pixel_generator`
set_property top pixel_generator [current_fileset]

# Package the current project as an IP
ipx::package_project -root_dir $IP_DIR -vendor imperial -library user \
    -taxonomy /UserIP -import_files -set_current true

set core [ipx::current_core]
set_property name    $IP_NAME       $core
set_property version $IP_VER        $core
set_property display_name "Newton Fractal Pixel Generator" $core
set_property description   "Q12 Newton fractal, AXI-Lite control + AXI-Stream out, multi-lane + pipelined divider" $core

# ---- Infer the AXI interfaces so the block designer auto-connects them ----
# AXI4-Lite slave (control). The HDL port prefix is s_axi_lite.
ipx::infer_bus_interface { \
  s_axi_lite_awaddr s_axi_lite_awvalid s_axi_lite_awready \
  s_axi_lite_wdata  s_axi_lite_wvalid  s_axi_lite_wready \
  s_axi_lite_bresp  s_axi_lite_bvalid  s_axi_lite_bready \
  s_axi_lite_araddr s_axi_lite_arvalid s_axi_lite_arready \
  s_axi_lite_rdata  s_axi_lite_rresp   s_axi_lite_rvalid s_axi_lite_rready \
} xilinx.com:interface:aximm_rtl:1.0 $core

# AXI4-Stream master (video out). HDL port prefix is out_stream.
ipx::infer_bus_interface { \
  out_stream_tdata out_stream_tkeep out_stream_tlast \
  out_stream_tvalid out_stream_tready out_stream_tuser \
} xilinx.com:interface:axis_rtl:1.0 $core

# Clock/reset association so Vivado knows which clock drives each interface
ipx::associate_bus_interfaces -busif s_axi_lite -clock s_axi_lite_aclk $core
ipx::associate_bus_interfaces -busif out_stream -clock out_stream_aclk $core

ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::save_core         $core

puts "================================================================"
puts "IP packaged at: $IP_DIR"
puts "Now run:  vivado -mode batch -source base.tcl"
puts "================================================================"

close_project
