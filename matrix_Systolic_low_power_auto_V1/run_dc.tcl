# run_dc.tcl - 移除 TCL 位元計算，由 RTL 自動推導[cite: 18]

# --- 1. 環境與參數設定 ---
set search_path ". /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db"
set target_library "slow.db"
set link_library "* $target_library dw_foundation.sldb"
set symbol_library "slow.db"

# 🌟 接收外部環境變數傳入的矩陣大小
set N_SIZE [getenv "CURRENT_N"]

# --- 2. 讀入設計 ---
analyze -format verilog { \
    ./RTL/DA4ML_Top.v \
    ./RTL/sparse_engine.v \
    ./RTL/sparse_pe.v \
    ./RTL/Systolic_Array.v \
    ./RTL/PE_module.v \
    ./RTL/mult_add.v \
    ./RTL/booth_radix4.v \
}

# 🌟 關鍵覆寫：僅傳遞 ARRAY_SIZE，ADDRWIDTH 由 RTL 內部 $clog2 自動計算[cite: 11, 18]
elaborate DA4ML_Top -parameters "ARRAY_SIZE=$N_SIZE"

rename_design DA4ML_Top_ARRAY_SIZE${N_SIZE} DA4ML_Top

current_design DA4ML_Top
link
check_design > ./report_dc/check_design.rpt

# --- 4. 設定時脈與約束 ---
create_clock -name "CLK" -period 10 -waveform {0 5} [get_ports CLK]
set_dont_touch_network [get_clocks CLK]
set_fix_hold [get_clocks CLK]
set_input_delay 6 -clock CLK [all_inputs]
set_output_delay 6 -clock CLK [all_outputs]

# --- 6. 執行合成與報表輸出 ---
compile -map_effort medium
exec mkdir -p report_dc
report_timing > ./report_dc/DA4ML_Top_timing.rpt
report_area > ./report_dc/DA4ML_Top_area.rpt
report_power > ./report_dc/DA4ML_Top_power.rpt

# --- 8. 輸出合成檔案 ---
exec mkdir -p Netlist
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output ./Netlist/DA4ML_Top_gate.v
write_sdf -version 2.1 ./Netlist/DA4ML_Top.sdf
write_sdc ./Netlist/DA4ML_Top.sdc
exit