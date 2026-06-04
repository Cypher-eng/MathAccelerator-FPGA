#=============================================================================
# base.tcl  -  Build the full block design around the pixel_generator IP and
#              generate the bitstream for the PYNQ-Z1.
#
# RUN ON YOUR VIVADO MACHINE (NOT run in the dev container):
#     vivado -mode batch -source base.tcl
#
# This follows the standard PYNQ-Z1 video-pipeline flow used by the course:
#   pixel_generator (AXI-Stream master)
#     -> AXI4-Stream Subset Converter / VDMA (S2MM)  -> DDR frame buffer
#   Zynq PS supplies clocks, DDR, and the AXI-Lite control path.
#   HDMI/video timing is provided by the board's video subsystem.
#
# It assumes build_ip.tcl has already produced ./ip_repo/pixel_generator.
# Adjust the board preset / part to your exact PYNQ-Z1 board files.
#
# IMPORTANT: this script wires the standard structure and runs synthesis,
# implementation and bitstream generation. The Fmax, LUT/DSP/BRAM utilisation
# and timing-closure result come out of THIS run on your machine -- record them
# (see start_guide_6.md). Nothing here is faked or pre-filled.
#=============================================================================

set PART        xc7z020clg400-1
set BOARD       www.digilentinc.com:pynq-z1:part0:1.0   ;# adjust if needed
set DESIGN      newton_top
set IP_REPO     [file normalize "./ip_repo"]
set OUT_DIR     [file normalize "./vivado_build"]

file mkdir $OUT_DIR
create_project -force $DESIGN $OUT_DIR -part $PART
catch { set_property board_part $BOARD [current_project] }

# make our packaged IP visible
set_property ip_repo_paths $IP_REPO [current_project]
update_ip_catalog

# ---------------- block design ----------------
create_bd_design "system"

# Zynq PS
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    [get_bd_cells ps7]
# enable one GP master (AXI-Lite control) and one HP slave (VDMA -> DDR)
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
] [get_bd_cells ps7]

# our pixel generator
create_bd_cell -type ip -vlnv imperial:user:pixel_generator:1.0 pixgen

# VDMA to write the stream into DDR (S2MM path)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 vdma
set_property -dict [list \
    CONFIG.c_include_mm2s {0} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_num_fstores {1} \
    CONFIG.c_s2mm_genlock_mode {0} \
    CONFIG.c_s2mm_linebuffer_depth {512} \
] [get_bd_cells vdma]

# AXI interconnects (control + memory)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ctrl
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_ic_ctrl]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_mem
set_property CONFIG.NUM_SI {1} [get_bd_cells axi_ic_mem]

# ---- clocks / resets via automation ----
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk "/ps7/FCLK_CLK0 (100 MHz)" } [get_bd_pins pixgen/out_stream_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk "/ps7/FCLK_CLK0 (100 MHz)" } [get_bd_pins pixgen/s_axi_lite_aclk]

# ---- AXI-Lite control: PS GP0 -> interconnect -> pixgen + vdma ----
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0]      [get_bd_intf_pins axi_ic_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_ctrl/M00_AXI] [get_bd_intf_pins pixgen/s_axi_lite]
connect_bd_intf_net [get_bd_intf_pins axi_ic_ctrl/M01_AXI] [get_bd_intf_pins vdma/S_AXI_LITE]

# ---- video stream: pixgen -> vdma S2MM ----
connect_bd_intf_net [get_bd_intf_pins pixgen/out_stream] [get_bd_intf_pins vdma/S_AXIS_S2MM]

# ---- memory: vdma -> interconnect -> PS HP0 (DDR) ----
connect_bd_intf_net [get_bd_intf_pins vdma/M_AXI_S2MM]    [get_bd_intf_pins axi_ic_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_mem/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

# let Vivado finish clock/reset hookup on the interconnects + vdma
apply_bd_automation -rule xilinx.com:bd_rule:clkrst -config { Clk "/ps7/FCLK_CLK0 (100 MHz)" } [get_bd_pins vdma/s_axi_lite_aclk]
regenerate_bd_layout

# ---- address map ----
assign_bd_address
# (After this, note the assigned base addresses; the pixel_generator AXI-Lite
#  base is what the PYNQ notebook writes ZR0/ZI0/STEP/MAXIT to.)

validate_bd_design
save_bd_design

# ---------------- HDL wrapper + implementation ----------------
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $OUT_DIR ${DESIGN}.srcs sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ---------------- collect the REAL numbers ----------------
open_run impl_1
puts "==================== TIMING ===================="
report_timing_summary -file $OUT_DIR/timing_summary.rpt
# Worst Negative Slack (WNS) at the 100 MHz (10 ns) target; Fmax = 1/(10ns - WNS)
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "Worst setup slack (WNS) = $wns ns at 10 ns period"
puts "If WNS >= 0 : timing MET at 100 MHz."
puts "Estimated Fmax = 1000 / (10 - WNS)  MHz   (compute with your WNS)"
puts "==================== UTILISATION ===================="
report_utilization -file $OUT_DIR/utilization.rpt
puts "See utilization.rpt for LUT / FF / DSP / BRAM counts (record these)."

# export bitstream + hwh for PYNQ
file mkdir $OUT_DIR/overlay
set bit [glob -nocomplain $OUT_DIR/${DESIGN}.runs/impl_1/system_wrapper.bit]
set hwh [glob -nocomplain $OUT_DIR/${DESIGN}.gen/sources_1/bd/system/hw_handoff/system.hwh]
if {$bit ne ""} { file copy -force $bit $OUT_DIR/overlay/newton.bit }
if {$hwh ne ""} { file copy -force $hwh $OUT_DIR/overlay/newton.hwh }
puts "Overlay files (if generated) copied to: $OUT_DIR/overlay/  (newton.bit + newton.hwh)"
puts "Copy BOTH to the board, same basename, for PYNQ Overlay()."

close_project
