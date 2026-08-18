# DA4ML：200MHz、latch+AND clock gating（精簡版，100 行內）
set TOP DA4ML_Top
set N_SIZE [expr {[info exists ::env(CURRENT_N)] ? $::env(CURRENT_N) : 16}]
set CLK_PERIOD 5.0
set RTL_DIR ./RTL
set RPT_DIR ./report_dc
set NET_DIR ./Netlist
set LIB_DIR /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db
set MAX_DB $LIB_DIR/slow.db
set MIN_DB $LIB_DIR/fast.db
proc fatal {msg} {puts "ERROR: $msg"; exit 2}
file mkdir $RPT_DIR
file mkdir $NET_DIR
set_app_var search_path [list . $RTL_DIR $LIB_DIR]
set_app_var target_library [list $MAX_DB]
set_app_var link_library [list * $MAX_DB dw_foundation.sldb]
if {[file exists $MIN_DB]} {set_min_library $MAX_DB -min_version $MIN_DB}

# 自動讀入 RTL，但排除 testbench。
set RTL_FILES {}
foreach f [lsort [glob -nocomplain $RTL_DIR/*.v]] {
  if {![regexp -nocase {(^tb|_tb\.v$|testbench)} [file tail $f]]} {lappend RTL_FILES $f}
}
if {[llength $RTL_FILES] == 0} {fatal "No RTL files found"}
catch {remove_design -all}
if {[catch {set ok [analyze -format verilog $RTL_FILES]} err] || $ok != 1} {fatal "analyze failed: $err"}
if {[catch {set ok [elaborate $TOP -parameters "ARRAY_SIZE=$N_SIZE"]} err] || $ok != 1} {fatal "elaborate failed: $err"}
set old_name [get_object_name [current_design]]
if {$old_name ne $TOP} {rename_design [current_design] $TOP; current_design $TOP}
if {[catch {set ok [link]} err] || $ok != 1} {fatal "link failed: $err"}
uniquify
redirect $RPT_DIR/check_design.rpt {set design_ok [check_design]}
if {$design_ok != 1} {fatal "check_design failed"}

# 200MHz timing constraint。
create_clock -name CLK -period $CLK_PERIOD -waveform {0 2.5} [get_ports CLK]
set_clock_uncertainty -setup 0.20 [get_clocks CLK]
set_clock_uncertainty -hold 0.05 [get_clocks CLK]
set_clock_transition 0.10 [get_clocks CLK]
set data_in [remove_from_collection [all_inputs] [get_ports {CLK RSTn}]]
if {[sizeof_collection $data_in] > 0} {set_input_delay 1.0 -clock CLK $data_in; set_input_transition 0.1 $data_in}
set_output_delay 1.0 -clock CLK [all_outputs]
set_load 0.05 [all_outputs]
set_false_path -from [get_ports RSTn]
set_max_transition 0.5 [current_design]
set_max_fanout 32 [current_design]

# 只能使用 low-level latch + AND，不使用 integrated ICG 或其他 gating 型式。
set_clock_gating_style -sequential_cell latch -positive_edge_logic {and} -control_point before -minimum_bitwidth 4 -max_fanout 32

# 中文修正：z_buffer 與 Booth 疊代暫存器若被拆成不同 gated-clock branch，
# SDF 延遲會造成同緣資料與時脈競爭；只排除這兩群，其他暫存器照常插 latch+AND。
set ZBUF_REGS [get_cells -hierarchical -filter {full_name =~ *z_buffer_reg* && is_sequential == true}]
set BOOTH_REGS [get_cells -hierarchical -filter {full_name =~ *u_radix4* && is_sequential == true}]
set ZBUF_COUNT [sizeof_collection $ZBUF_REGS]
set BOOTH_COUNT [sizeof_collection $BOOTH_REGS]
if {$ZBUF_COUNT == 0} {fatal "Cannot find z_buffer registers"}
if {$BOOTH_COUNT == 0} {fatal "Cannot find u_radix4 sequential registers"}
set CG_EXCLUDE [add_to_collection $ZBUF_REGS $BOOTH_REGS]
set_clock_gating_objects -exclude $CG_EXCLUDE

# 中文修正：保留 0.30ns gating setup 裕量，避免 WNS 只有數 ps 卻誤判可用。
set_clock_gating_check -setup 0.30 -hold 0.10 [get_clocks CLK]
puts "INFO: clock-gating excluded: z_buffer=$ZBUF_COUNT, booth=$BOOTH_COUNT"

if {[file exists ./DA4ML_Top.saif]} {catch {read_saif -input ./DA4ML_Top.saif -instance_name TB_DA4ML_16x16/U_DUT -auto_map_names}}
if {[catch {compile_ultra -gate_clock -timing_high_effort_script} err]} {fatal "compile_ultra failed: $err"}
set_dont_touch_network [get_clocks CLK]

# 必要報告。
redirect $RPT_DIR/area.rpt {report_area -hierarchy}
redirect $RPT_DIR/power.rpt {report_power -hierarchy}
redirect $RPT_DIR/constraints.rpt {report_constraint -all_violators}
redirect $RPT_DIR/timing_setup.rpt {report_timing -delay_type max -max_paths 20}
redirect $RPT_DIR/timing_hold.rpt {report_timing -delay_type min -max_paths 20}
redirect $RPT_DIR/clock_gating.rpt {report_clock_gating -verbose}
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set WNS_SETUP [get_attribute [index_collection $setup_path 0] slack]
set WNS_HOLD [get_attribute [index_collection $hold_path 0] slack]
set CG_COUNT -1
if {[llength [info commands all_clock_gates]] > 0} {set CG_COUNT [sizeof_collection [all_clock_gates]]}

set fp [open $RPT_DIR/timing_sign_off.log w]
puts $fp "TOP=$TOP\nARRAY_SIZE=$N_SIZE\nCLOCK_PERIOD_NS=$CLK_PERIOD\nTARGET_FREQUENCY_MHZ=200.0"
puts $fp "WNS_SETUP_NS=$WNS_SETUP\nWNS_HOLD_NS=$WNS_HOLD\nCLOCK_GATING_IMPLEMENTATION=LATCH_AND"
puts $fp "ZBUFFER_GATING_EXCLUDED_REGS=$ZBUF_COUNT\nBOOTH_GATING_EXCLUDED_REGS=$BOOTH_COUNT\nCLOCK_GATES=$CG_COUNT"
set TIMING_RESULT FAIL
if {$WNS_SETUP >= 0.0 && $WNS_HOLD >= 0.0} {set TIMING_RESULT PASS}
puts $fp "TIMING_RESULT=$TIMING_RESULT"
close $fp

change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output $NET_DIR/DA4ML_Top_gate.v
write_sdf -version 2.1 $NET_DIR/DA4ML_Top.sdf
write_sdc $NET_DIR/DA4ML_Top.sdc
if {$WNS_SETUP < 0.0 || $WNS_HOLD < 0.0} {puts "ERROR: timing failed"; exit 4}
puts "INFO: synthesis PASS, setup=$WNS_SETUP ns, hold=$WNS_HOLD ns, gates=$CG_COUNT"
exit 0