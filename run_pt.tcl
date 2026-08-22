# ==============================================================================
# DA4ML PrimeTime 靜態時序與功耗分析腳本
# 分析模式：pre-layout STA + gate-level FSDB time-based power analysis
# 目標時脈：200 MHz（由 Design Compiler 輸出的 SDC 載入）
#
# 整體流程：
#   1. 設定設計名稱、輸入輸出路徑與外部參數
#   2. 載入 slow/fast 標準元件庫與分析 corner
#   3. 載入 gate-level netlist、SDC 與 SDF
#   4. 建立 pre-layout ideal-clock timing model
#   5. 執行時序完整性檢查並產生 STA 報告
#   6. 擷取 setup/hold 最差 slack
#   7. 讀取 gate-level FSDB 並執行 time-based power analysis
#   8. 輸出分析摘要並正常結束 PrimeTime
#
# 注意：
#   本腳本分析的是 DC 合成後、Innovus CTS 與實體佈線前的結果。
#   SDF 尚未包含 routed parasitics，clock 也維持 ideal clock，因此結果只能用於
#   pre-layout 設計檢查與最佳化方向判斷，不能視為晶片最終 sign-off。
# ==============================================================================

# ==============================================================================
# 1. 設計名稱、檔案路徑與外部參數
# ==============================================================================
# 工作原理：
#   TOP 必須和 DC 輸出的 gate-level 最上層模組一致。REPORT_DIR 存放 PT 產生的
#   時序與功耗報告；NETLIST_DIR 指向 DC 輸出的 netlist、SDC 與 SDF。
set TOP          DA4ML_Top
set REPORT_DIR   ./report_pt
set NETLIST_DIR  ./Netlist
set LIB_DB_DIR   /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db
set MAX_DB        ${LIB_DB_DIR}/slow.db
set MIN_DB        ${LIB_DB_DIR}/fast.db

# CURRENT_FSDB、CURRENT_REPORT 與 TOP_INSTANCE 由 Makefile 或執行腳本傳入：
#   CURRENT_FSDB   ：gate-level simulation 產生的 FSDB 波形檔。
#   CURRENT_REPORT ：最終 power report 的輸出檔名。
#   TOP_INSTANCE   ：FSDB 內 testbench 到 DUT 的階層路徑，供 strip_path 使用。
set FSDB_FILE     $::env(CURRENT_FSDB)
set POWER_REPORT  $::env(CURRENT_REPORT)
set TOP_INSTANCE  $::env(TOP_INSTANCE)

file mkdir $REPORT_DIR

# ==============================================================================
# 2. 標準元件庫與 max/min timing corner 設定
# ==============================================================================
# 工作原理：
#   slow.db 的 cell delay 較大，用於最大延遲與 setup 分析；fast.db 的 cell delay
#   較小，用於最小延遲與 hold 分析。set_min_library 建立同一組 cell 在 max/min
#   library 間的對應，使 PT 能在一次分析中分別計算 setup 與 hold timing。
set_app_var search_path [list . $LIB_DB_DIR]
set_app_var link_path   [list * $MAX_DB]
set_min_library $MAX_DB -min_version $MIN_DB

# ==============================================================================
# 3. 載入 gate-level netlist、時序約束與 SDF 延遲
# ==============================================================================
# 工作原理：
#   read_verilog 載入 DC 映射後的標準元件網表；current_design 指定分析目標；
#   link_design 將網表 instance 與 slow.db 元件模型連結，未成功 link 的設計不能
#   進行可信的 timing/power analysis。
read_verilog $NETLIST_DIR/DA4ML_Top_gate.v
current_design $TOP
link_design $TOP

# read_sdc 延續 DC 的時脈與 I/O 約束，其中包含：
#   create_clock -period 5.0 ns
#   set_clock_uncertainty -setup 0.35 ns
#   set_clock_uncertainty -hold 0.05 ns
# 因此 PT 不需要再次設定 uncertainty，避免同一項 margin 被重複施加。
read_sdc $NETLIST_DIR/DA4ML_Top.sdc

# SDF 提供合成後標準元件與已估算路徑的延遲，用於 pre-layout STA。
# 此時尚未經過 Innovus 佈線，所以不包含實際 RC extraction 的 routed parasitics。
read_sdf $NETLIST_DIR/DA4ML_Top.sdf

# ==============================================================================
# 4. 建立 pre-layout ideal-clock timing model
# ==============================================================================
# 工作原理：
#   目前尚未執行 CTS，不使用 set_propagated_clock，讓 PT 保留 SDC 的 ideal clock。
#   若在 CTS 前把 clock 設為 propagated，clock-gating 與未平衡 clock branch 的延遲
#   可能被誤當成最終 clock skew，造成 pre-layout 分析與實際 CTS 結果不一致。
#   update_timing -full 會重新建立完整 timing graph 並更新所有 setup/hold path。
update_timing -full

# ==============================================================================
# 5. 時序完整性檢查與 STA 報告
# ==============================================================================
# 工作原理：
#   check_timing 檢查時脈、未約束端點、組合迴路與 timing exception 等完整性；
#   report_clock 顯示時脈定義與目前 skew；report_constraint 列出所有 constraint
#   violation；analysis_coverage 用於確認有多少 timing check 已被完整分析。
redirect $REPORT_DIR/check_timing.rpt {
  check_timing -verbose
}
redirect $REPORT_DIR/clocks.rpt {
  report_clock -skew
}
redirect $REPORT_DIR/constraints.rpt {
  report_constraint -all_violators
}

# setup 使用最大延遲路徑，hold 使用最小延遲路徑。-max_paths 50 與 -nworst 5
# 可保留多組端點的最差路徑；input_pins、nets、transition_time、capacitance
# 提供 cell、net、slew 與負載資料，方便後續找出真正的 critical path 原因。
redirect $REPORT_DIR/timing_setup.rpt {
  report_timing \
    -delay_type max \
    -max_paths 50 \
    -nworst 5 \
    -input_pins \
    -nets \
    -transition_time \
    -capacitance
}
redirect $REPORT_DIR/timing_hold.rpt {
  report_timing \
    -delay_type min \
    -max_paths 50 \
    -nworst 5 \
    -input_pins \
    -nets \
    -transition_time \
    -capacitance
}
redirect $REPORT_DIR/analysis_coverage.rpt {
  report_analysis_coverage
}

# ==============================================================================
# 6. 擷取 setup 與 hold 最差 slack
# ==============================================================================
# 工作原理：
#   setup path 使用 delay_type=max；hold path 使用 delay_type=min。各取得一條
#   最差路徑，並從 path collection 的第一個物件讀取 slack：
#     slack >= 0：資料在要求時間內到達，該項 timing check 通過。
#     slack <  0：資料超出要求時間，代表存在 timing violation。
set SETUP_PATH [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set HOLD_PATH  [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
set WNS_SETUP  [get_attribute [index_collection $SETUP_PATH 0] slack]
set WNS_HOLD   [get_attribute [index_collection $HOLD_PATH 0] slack]

# ==============================================================================
# 7. Gate-level FSDB time-based power analysis
# ==============================================================================
# 工作原理：
#   time-based mode 會使用 FSDB 中每個時間點的實際訊號切換活動，而不是只使用
#   平均 toggle rate，因此能反映不同運算 phase、clock gating 開關與暫存器活動。
#   read_fsdb 的 strip_path 會移除 testbench/DUT 階層前綴，使 FSDB signal 能映射
#   到 PT 中以 DA4ML_Top 為根節點的 gate-level netlist。
set power_enable_analysis true
set power_analysis_mode time_based
read_fsdb -strip_path $TOP_INSTANCE $FSDB_FILE

# check_power 檢查 library power model、activity annotation 與未映射訊號；
# update_power 根據 cell internal、switching 與 leakage model 計算功耗。
check_power
update_power

# hierarchy report 顯示各模組功耗分布，便於比較 Systolic Array、Booth multiplier、
# sparse engine 等區塊；POWER_REPORT 則是由 Makefile 指定的完整功耗輸出檔。
redirect $REPORT_DIR/power_hierarchy.rpt {
  report_power -hierarchy
}
report_power > $POWER_REPORT

# ==============================================================================
# 8. 產生 pre-layout 分析摘要並結束
# ==============================================================================
# 工作原理：
#   將 setup/hold WNS 以 key=value 格式寫入 timing_sign_off.log，方便 Makefile、
#   shell script 或試算表擷取。WNS 無論正負都如實記錄，本腳本不會因負 slack
#   中止 power flow，確保時序未收斂時仍可取得功耗資料供設計權衡。
set SUMMARY [open $REPORT_DIR/timing_sign_off.log w]
puts $SUMMARY "TOP=$TOP"
puts $SUMMARY "WNS_SETUP_NS=$WNS_SETUP"
puts $SUMMARY "WNS_HOLD_NS=$WNS_HOLD"
puts $SUMMARY "ANALYSIS_STATUS=COMPLETED"
puts $SUMMARY "NOTE=Pre-layout ideal-clock SDF analysis; final sign-off requires CTS, routed parasitics and MCMM corners."
close $SUMMARY

# 終端機顯示主要分析結果。exit 0 表示 PrimeTime 流程已完整執行，不代表 WNS
# 必然為正；是否通過 timing 必須依 timing_sign_off.log 與詳細 timing report 判斷。
puts "INFO: PrimeTime setup WNS = $WNS_SETUP ns"
puts "INFO: PrimeTime hold WNS = $WNS_HOLD ns"
puts "INFO: PrimeTime timing and power reports completed."
exit 0