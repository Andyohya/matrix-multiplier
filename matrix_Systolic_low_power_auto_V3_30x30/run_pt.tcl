# =============================================================================
# DA4ML PrimeTime：pre-layout STA 與 time-based power analysis
# 200 MHz 約束由 DC 產生的 SDC 載入；此腳本不以負 slack 中斷 power flow。
# =============================================================================

set TOP          DA4ML_Top
set REPORT_DIR   ./report_pt
set NETLIST_DIR  ./Netlist
set LIB_DB_DIR   /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db
set MAX_DB        ${LIB_DB_DIR}/slow.db
set MIN_DB        ${LIB_DB_DIR}/fast.db
set FSDB_FILE     $::env(CURRENT_FSDB)
set POWER_REPORT  $::env(CURRENT_REPORT)
set TOP_INSTANCE  $::env(TOP_INSTANCE)

file mkdir $REPORT_DIR

# 載入 slow/fast corner；max 用於 setup，min 用於 hold。
set_app_var search_path [list . $LIB_DB_DIR]
set_app_var link_path   [list * $MAX_DB]
set_min_library $MAX_DB -min_version $MIN_DB

read_verilog $NETLIST_DIR/DA4ML_Top_gate.v
current_design $TOP
link_design $TOP
read_sdc $NETLIST_DIR/DA4ML_Top.sdc
read_sdf $NETLIST_DIR/DA4ML_Top.sdf

# 目前尚未 CTS／佈線，保留 SDC 的 ideal-clock 模式。
# 不啟用 propagated clock，避免把未平衡的 clock-gating 路徑誤當成最終 skew。
update_timing -full

redirect $REPORT_DIR/check_timing.rpt      {check_timing -verbose}
redirect $REPORT_DIR/clocks.rpt            {report_clock -skew}
redirect $REPORT_DIR/constraints.rpt       {report_constraint -all_violators}
redirect $REPORT_DIR/timing_setup.rpt      {report_timing -delay_type max -max_paths 50 -nworst 5 -input_pins -nets -transition_time -capacitance}
redirect $REPORT_DIR/timing_hold.rpt       {report_timing -delay_type min -max_paths 50 -nworst 5 -input_pins -nets -transition_time -capacitance}
redirect $REPORT_DIR/analysis_coverage.rpt {report_analysis_coverage}

set SETUP_PATH [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set HOLD_PATH  [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set WNS_SETUP  [get_attribute [index_collection $SETUP_PATH 0] slack]
set WNS_HOLD   [get_attribute [index_collection $HOLD_PATH 0] slack]

# 直接使用 Makefile 傳入的 gate-level FSDB 與 DUT hierarchy。
set power_enable_analysis true
set power_analysis_mode time_based
read_fsdb -strip_path $TOP_INSTANCE $FSDB_FILE
check_power
update_power
redirect $REPORT_DIR/power_hierarchy.rpt {report_power -hierarchy}
report_power > $POWER_REPORT

# WNS 無論正負都如實記錄；pre-layout 結果供優化判讀，不宣告 final sign-off。
set SUMMARY [open $REPORT_DIR/timing_sign_off.log w]
puts $SUMMARY "TOP=$TOP"
puts $SUMMARY "WNS_SETUP_NS=$WNS_SETUP"
puts $SUMMARY "WNS_HOLD_NS=$WNS_HOLD"
puts $SUMMARY "ANALYSIS_STATUS=COMPLETED"
puts $SUMMARY "NOTE=Pre-layout ideal-clock SDF analysis; final sign-off requires CTS, routed parasitics and MCMM corners."
close $SUMMARY

puts "INFO: PrimeTime setup WNS = $WNS_SETUP ns"
puts "INFO: PrimeTime hold WNS = $WNS_HOLD ns"
puts "INFO: PrimeTime timing and power reports completed."
exit 0