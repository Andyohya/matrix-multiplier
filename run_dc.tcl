# ==============================================================================
# DA4ML Design Compiler 合成腳本
# 目標規格：200 MHz（5.0 ns）、latch + AND clock gating
# 使用方式：由環境變數 CURRENT_N 指定矩陣尺寸；未指定時預設為 16。
#
# 整體流程：
#   1. 設定專案參數與輸出目錄
#   2. 載入 TSMC 0.18 um 標準元件庫
#   3. 讀取 RTL，執行 analyze、elaborate、link
#   4. 檢查展開後的設計完整性
#   5. 建立 200 MHz 時序與電氣約束
#   6. 設定 latch + AND clock gating 架構
#   7. 排除不適合插入 clock gating 的敏感暫存器
#   8. 讀取切換活動並執行高強度合成
#   9. 產生面積、功耗、時序與 clock gating 報告
#  10. 輸出 gate-level netlist、SDF 與 SDC
# ==============================================================================

# ==============================================================================
# 1. 專案參數與目錄設定
# ==============================================================================
# 工作原理：
#   TOP 指定最上層模組；CURRENT_N 用來傳入 ARRAY_SIZE，使同一份腳本可合成
#   16x16、32x32 或其他矩陣尺寸。時脈週期設為 5.0 ns，對應 200 MHz。
set TOP DA4ML_Top
set N_SIZE [expr {[info exists ::env(CURRENT_N)] ? $::env(CURRENT_N) : 16}]
set CLK_PERIOD 5.0
set RTL_DIR ./RTL
set RPT_DIR ./report_dc
set NET_DIR ./Netlist
set LIB_DIR /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/SynopsysDC/db
set MAX_DB $LIB_DIR/slow.db
set MIN_DB $LIB_DIR/fast.db

# 集中處理致命錯誤，避免前一階段失敗後仍繼續產生不可信的輸出檔案。
proc fatal {msg} {
  puts "ERROR: $msg"
  exit 2
}
file mkdir $RPT_DIR
file mkdir $NET_DIR

# ==============================================================================
# 2. 標準元件庫與搜尋路徑設定
# ==============================================================================
# 工作原理：
#   target_library 使用 slow.db 進行邏輯映射與 setup 分析；fast.db 作為 min library
#   檢查 hold。link_library 加入 DesignWare，供乘法、加法等運算元件連結使用。
set_app_var search_path [list . $RTL_DIR $LIB_DIR]
set_app_var target_library [list $MAX_DB]
set_app_var link_library [list * $MAX_DB dw_foundation.sldb]
if {[file exists $MIN_DB]} {
  set_min_library $MAX_DB -min_version $MIN_DB
}

# ==============================================================================
# 3. RTL 蒐集、語法分析、參數展開與設計連結
# ==============================================================================
# 工作原理：
#   蒐集 RTL_DIR 下的 Verilog 並排除 testbench。analyze 解析語法；elaborate 依
#   ARRAY_SIZE 建立硬體階層；link 連結所有模組與元件庫；uniquify 讓重複使用的
#   參數化 instance 可以分別進行最佳化。
set RTL_FILES {}
foreach f [lsort [glob -nocomplain $RTL_DIR/*.v]] {
  if {![regexp -nocase {(^tb|_tb\.v$|testbench)} [file tail $f]]} {
    lappend RTL_FILES $f
  }
}
if {[llength $RTL_FILES] == 0} {
  fatal "No RTL files found"
}
catch {remove_design -all}
if {[catch {set ok [analyze -format verilog $RTL_FILES]} err] || $ok != 1} {
  fatal "analyze failed: $err"
}
if {[catch {set ok [elaborate $TOP -parameters "ARRAY_SIZE=$N_SIZE"]} err] || $ok != 1} {
  fatal "elaborate failed: $err"
}

# 參數化展開可能產生 DA4ML_Top_ARRAY_SIZExx 等名稱；統一改回 TOP，使網表、
# SDF、testbench 與 PrimeTime 都能持續使用固定的 DA4ML_Top 模組名稱。
set old_name [get_object_name [current_design]]
if {$old_name ne $TOP} {
  rename_design [current_design] $TOP
  current_design $TOP
}
if {[catch {set ok [link]} err] || $ok != 1} {
  fatal "link failed: $err"
}
uniquify

# ==============================================================================
# 4. 設計完整性檢查
# ==============================================================================
# 工作原理：
#   check_design 檢查未連接腳位、多重驅動、未解析 reference 與階層連結問題。
#   只有設計完整時才進入約束與 compile，避免前端錯誤被最佳化流程掩蓋。
redirect $RPT_DIR/check_design.rpt {
  set design_ok [check_design]
}
if {$design_ok != 1} {
  fatal "check_design failed"
}

# ==============================================================================
# 5. 200 MHz 時序與電氣約束
# ==============================================================================
# 工作原理：
#   5.0 ns 時脈代表 200 MHz，占空比為 50%。setup uncertainty=0.35 ns 會從
#   setup 可用時間扣除 0.35 ns，以預留 clock jitter、skew 與實體繞線誤差。
#   數值提高代表約束更嚴格，會促使 DC 更積極縮短資料路徑；hold uncertainty
#   0.05 ns 則替最短路徑保留安全裕量。
create_clock -name CLK -period $CLK_PERIOD -waveform {0 2.5} [get_ports CLK]
set_clock_uncertainty -setup 0.35 [get_clocks CLK]
set_clock_uncertainty -hold 0.05 [get_clocks CLK]
set_clock_transition 0.10 [get_clocks CLK]

# CLK 與非同步 reset 不屬於一般資料輸入。I/O delay 模擬晶片外部邏輯占用的時間，
# transition 與 output load 避免 DC 以理想零延遲介面進行不切實際的最佳化。
set data_in [remove_from_collection [all_inputs] [get_ports {CLK RSTn}]]
if {[sizeof_collection $data_in] > 0} {
  set_input_delay 1.0 -clock CLK $data_in
  set_input_transition 0.1 $data_in
}
set_output_delay 1.0 -clock CLK [all_outputs]
set_load 0.05 [all_outputs]

# RSTn 為非同步控制訊號，不當成一般資料路徑分析。transition 與 fanout 上限可
# 避免產生驅動能力不足、負載過大或實體布局難以收斂的網路。
set_false_path -from [get_ports RSTn]
set_max_transition 0.5 [current_design]
set_max_fanout 32 [current_design]

# ==============================================================================
# 6. Latch + AND clock gating 插入規則
# ==============================================================================
# 工作原理：
#   latch 在 CLK 低電位期間擷取 enable，在 CLK 高電位期間保持 enable 穩定，
#   再由 AND gate 產生 gated clock，避免 enable 於高電位期間改變而形成 glitch。
#   此方法不依賴 library 內建 ICG cell，符合只能使用 latch-based gating 的條件。
#
# 參數：latch 指定鎖存式 gating；and 對應正緣時脈；before 在暫存器群前插入；
# minimum_bitwidth=4 表示至少四個暫存器共用 enable 才插入；每支最大 fanout=32。
set_clock_gating_style \
  -sequential_cell latch \
  -positive_edge_logic {and} \
  -control_point before \
  -minimum_bitwidth 4 \
  -max_fanout 32

# ==============================================================================
# 7. 排除 SDF gate sim 敏感暫存器
# ==============================================================================
# 工作原理：
#   z_buffer 與 Booth Radix-4 迭代暫存器具有緊密的同週期資料相依性。若被拆到
#   不同 gated-clock branch，SDF 回標後的 clock/data delay 差異可能造成
#   setup/hold violation、X propagation 或錯誤計算。因此只排除這兩群，
#   其餘暫存器仍可自動插入 latch + AND clock gating。
set ZBUF_REGS [get_cells -hierarchical \
  -filter {full_name =~ *z_buffer_reg* && is_sequential == true}]
set BOOTH_REGS [get_cells -hierarchical \
  -filter {full_name =~ *u_radix4* && is_sequential == true}]
set ZBUF_COUNT [sizeof_collection $ZBUF_REGS]
set BOOTH_COUNT [sizeof_collection $BOOTH_REGS]

# 找不到目標代表 RTL 階層或名稱可能已改變；立即停止，避免排除規則失效後產生
# 可能無法通過 SDF gate sim 的網表。
if {$ZBUF_COUNT == 0} {
  fatal "Cannot find z_buffer registers"
}
if {$BOOTH_COUNT == 0} {
  fatal "Cannot find u_radix4 sequential registers"
}
set CG_EXCLUDE [add_to_collection $ZBUF_REGS $BOOTH_REGS]
set_clock_gating_objects -exclude $CG_EXCLUDE

# 要求 enable 在 latch 關閉與時脈作用邊緣附近保持穩定，以降低布局與 SDF 延遲
# 造成 gated-clock glitch 或 clock-gating timing violation 的風險。
set_clock_gating_check -setup 0.30 -hold 0.10 [get_clocks CLK]
puts "INFO: clock-gating excluded: z_buffer=$ZBUF_COUNT, booth=$BOOTH_COUNT"

# ==============================================================================
# 8. 切換活動讀取與高強度合成
# ==============================================================================
# 工作原理：
#   SAIF 提供 RTL simulation 的訊號切換率，使功耗估算更接近實際操作；讀取失敗
#   由 catch 保護，不影響功能與時序合成。compile_ultra 執行邏輯最佳化、元件
#   映射與時序修復；-gate_clock 插入 gating；timing_high_effort 對大型矩陣採用
#   較高強度的時序最佳化。
if {[file exists ./DA4ML_Top.saif]} {
  catch {
    read_saif -input ./DA4ML_Top.saif \
      -instance_name TB_DA4ML_16x16/U_DUT \
      -auto_map_names
  }
}
if {[catch {compile_ultra -gate_clock -timing_high_effort_script} err]} {
  fatal "compile_ultra failed: $err"
}

# 合成完成後保護主時脈網路，避免後續處理改動 clock network 結構。
set_dont_touch_network [get_clocks CLK]

# ==============================================================================
# 9. 報告產生與 pre-layout timing sign-off 摘要
# ==============================================================================
# 工作原理：
#   area/power 評估硬體成本；constraint 列出違規；setup/hold report 分別檢查
#   最大與最小延遲；clock_gating report 確認 clock gate 與 gated registers。
redirect $RPT_DIR/area.rpt {
  report_area -hierarchy
}
redirect $RPT_DIR/power.rpt {
  report_power -hierarchy
}
redirect $RPT_DIR/constraints.rpt {
  report_constraint -all_violators
}
redirect $RPT_DIR/timing_setup.rpt {
  report_timing -delay_type max -max_paths 20
}
redirect $RPT_DIR/timing_hold.rpt {
  report_timing -delay_type min -max_paths 20
}
redirect $RPT_DIR/clock_gating.rpt {
  report_clock_gating -verbose
}

# WNS 是最差負 slack；setup 與 hold 皆大於等於 0 才判定 timing PASS。
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
set WNS_SETUP [get_attribute [index_collection $setup_path 0] slack]
set WNS_HOLD [get_attribute [index_collection $hold_path 0] slack]

# 部分 DC 版本沒有 all_clock_gates，故先設 -1，再依指令是否存在取得數量。
set CG_COUNT -1
if {[llength [info commands all_clock_gates]] > 0} {
  set CG_COUNT [sizeof_collection [all_clock_gates]]
}

# 以 key=value 產生容易由 shell script、Makefile 或試算表解析的摘要。
set fp [open $RPT_DIR/timing_sign_off.log w]
puts $fp "TOP=$TOP\nARRAY_SIZE=$N_SIZE\nCLOCK_PERIOD_NS=$CLK_PERIOD\nTARGET_FREQUENCY_MHZ=200.0"
puts $fp "WNS_SETUP_NS=$WNS_SETUP\nWNS_HOLD_NS=$WNS_HOLD\nCLOCK_GATING_IMPLEMENTATION=LATCH_AND"
puts $fp "ZBUFFER_GATING_EXCLUDED_REGS=$ZBUF_COUNT\nBOOTH_GATING_EXCLUDED_REGS=$BOOTH_COUNT\nCLOCK_GATES=$CG_COUNT"
set TIMING_RESULT FAIL
if {$WNS_SETUP >= 0.0 && $WNS_HOLD >= 0.0} {
  set TIMING_RESULT PASS
}
puts $fp "TIMING_RESULT=$TIMING_RESULT"
close $fp

# ==============================================================================
# 10. Gate-level netlist、SDF、SDC 輸出與最終判定
# ==============================================================================
# 工作原理：
#   change_names 將名稱轉成合法 Verilog 格式；gate.v 是閘級網表；SDF 回標元件
#   延遲供 gate sim 使用；SDC 供 PrimeTime 或 Innovus 延續相同約束。若 setup
#   或 hold WNS 為負值，腳本以錯誤碼 4 結束，不把違反時序的結果當作成功。
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output $NET_DIR/DA4ML_Top_gate.v
write_sdf -version 2.1 $NET_DIR/DA4ML_Top.sdf
write_sdc $NET_DIR/DA4ML_Top.sdc
if {$WNS_SETUP < 0.0 || $WNS_HOLD < 0.0} {
  puts "ERROR: timing failed"
  exit 4
}
puts "INFO: synthesis PASS, setup=$WNS_SETUP ns, hold=$WNS_HOLD ns, gates=$CG_COUNT"
exit 0