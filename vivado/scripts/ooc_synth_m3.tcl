# -----------------------------------------------------------------------------
# ooc_synth_m3.tcl — M3 gate: out-of-context synthesis of phy_xact_engine_top
# Target: xc7z020clg484-1 (ZC702). Run from repo root:
#   vivado -mode batch -source vivado/scripts/ooc_synth_m3.tcl
# Evidence lands in vivado/reports/m3_phyif/
# -----------------------------------------------------------------------------
set part        xc7z020clg484-1
set rpt_dir     [file normalize [file join [file dirname [info script]] .. reports m3_phyif]]
set root        [file normalize [file join $rpt_dir .. .. ..]]

file mkdir $rpt_dir

read_verilog -sv [list \
  [file join $root rtl common serdes_phy_ctrl_pkg.sv] \
  [file join $root rtl phy_if  phy_arbiter.sv] \
  [file join $root rtl phy_if  phy_xact_core.sv] \
  [file join $root rtl phy_if  phy_xact_engine_top.sv]]

synth_design -top phy_xact_engine_top -part $part -mode out_of_context

# 100 MHz control-plane target for meaningful OOC timing evidence
create_clock -name clk -period 10.000 [get_ports clk]

report_utilization    -file [file join $rpt_dir util_m3_phyif_ooc.rpt]
report_timing_summary -file [file join $rpt_dir timing_m3_phyif_ooc.rpt]

puts "M3_OOC_SYNTH_DONE rpt_dir=$rpt_dir"
