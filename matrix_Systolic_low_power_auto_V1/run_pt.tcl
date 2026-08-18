# run_pt.tcl - PrimeTime Power Analysis Script for mat_mult_direct

# 1. 環境與 Library 設定 (需與 run_dc.tcl 保持一致)
set search_path ". /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db"
set target_library "slow.db"
set link_library "* $target_library"

# 2. 啟用功耗分析模式
set power_enable_analysis true
set power_analysis_mode time_based

# 3. 讀取設計 (Gate-Level Netlist)
read_verilog ./Netlist/DA4ML_Top_gate.v
current_design DA4ML_Top
link

read_sdf ./Netlist/DA4ML_Top.sdf
read_sdc ./Netlist/DA4ML_Top.sdc

set fsdb_file    [getenv "CURRENT_FSDB"]
set report_file  [getenv "CURRENT_REPORT"]
set top_instance [getenv "TOP_INSTANCE"]

# 4. 讀取波形檔 (Switching Activity)
read_fsdb -strip_path $top_instance $fsdb_file

# 6. 執行功耗計算
check_power
update_power

# 7. 產生報告
# 報告會存成 power_report.txt
report_power -hierarchy > power_report.txt
report_power > $report_file
# (選用) 如果想看詳細的時序報告，可以取消下面這行的註解
report_timing > timing_report.txt

exit