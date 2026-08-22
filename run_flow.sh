#!/bin/bash

echo "=========================================="
echo "🚀 EDA 2.0: 批次模擬與運算功耗分析啟動"
echo "=========================================="

# 建立存放報告的資料夾
mkdir -p rpt_power

# --- 檔案初始化區 ---
CSV_FILE="power_summary.csv"
AVG_CSV_FILE="avg_power_summary.csv"
AVG_TXT_FILE="avg_power_report.txt"

if [ ! -f "$CSV_FILE" ]; then
    echo "Matrix_Size,Test_ID,Operational_Power_mW,Waveform_Time_ns" > $CSV_FILE
fi

if [ ! -f "$AVG_CSV_FILE" ]; then
    echo "Matrix_Size,Valid_Tests,Avg_Waveform_Time_ns,Avg_Clock_Network,Avg_Register,Avg_Combinational,Avg_Total_Power" > $AVG_CSV_FILE
fi

if [ ! -f "$AVG_TXT_FILE" ]; then
    echo "==========================================" > $AVG_TXT_FILE
    echo "   📊 矩陣功耗與波形時間平均結算報告" >> $AVG_TXT_FILE
    echo "==========================================" >> $AVG_TXT_FILE
fi

# 1. 設定測試參數與矩陣維度
TARGET_N=${1:-16}
SIZES=($TARGET_N)

# 讓測資數量變成可控參數 (預設 5)
TESTS_PER_SIZE=${2:-5}
TOTAL_TASKS=$((${#SIZES[@]} * TESTS_PER_SIZE))
CURRENT_TASK=0

echo "📋 總任務數: $TOTAL_TASKS 筆動態功耗分析"
echo "------------------------------------------"

# 2. 開始主迴圈
for N in "${SIZES[@]}"; do
    for t in $(seq 1 $TESTS_PER_SIZE); do
        DIR_PATH="./mem/${N}x${N}/test_${t}"
        CURRENT_TASK=$((CURRENT_TASK + 1))

        if [ ! -d "$DIR_PATH" ]; then
            echo -e "\n❌ 找不到資料夾路徑: $DIR_PATH (跳過)"
            continue
        fi

        # 繪製進度條
        PERCENT=$((CURRENT_TASK * 100 / TOTAL_TASKS))
        BAR_LEN=20
        FILLED=$((PERCENT * BAR_LEN / 100))
        EMPTY=$((BAR_LEN - FILLED))
        BAR=$(printf "%${FILLED}s" | tr ' ' '#')
        SPACE=$(printf "%${EMPTY}s" | tr ' ' '-')
        echo -ne "\r⌛ 進度: [$BAR$SPACE] $PERCENT% ($CURRENT_TASK/$TOTAL_TASKS) - 正在執行 ${N}x${N} Test $t ..."

        # 執行模擬
        # run_flow.sh 修正部分
        # 🌟 核心修正：加入 U_DUT.ARRAY_SIZE 的參數覆寫，消除寬度不匹配
        vcs -full64 -R +define+SDF -pvalue+TB_DA4ML_16x16.CURRENT_N=$N \
            -pvalue+TB_DA4ML_16x16.U_DUT.ARRAY_SIZE=$N \
            +TEST_DIR=$DIR_PATH \
            RTL/TB_DA4ML_16x16.v ./Netlist/DA4ML_Top_gate.v -debug_access+all \
            -v /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/Verilog/tsmc18_neg.v +neg_tchk +maxdelays \
            > $DIR_PATH/sim.log 2>&1

        # 執行功耗分析
        export CURRENT_FSDB="$DIR_PATH/wave.fsdb"
        export CURRENT_REPORT="./rpt_power/power_${N}x${N}_test_${t}.rpt"
        export TOP_INSTANCE="TB_DA4ML_16x16/U_DUT"
        pt_shell -f run_pt.tcl > $DIR_PATH/pt.log 2>&1

        # 🛡️ 關鍵修正：強制同步硬碟並等待，確保 Log 完整寫入
        sync && sleep 2

        # 1. 抓取時間：優先找 Total，找不到則找最後一個 Last event
        SIM_TIME_NS=$(grep "Total simulation time =" $DIR_PATH/pt.log | awk '{print $6}')
        if [ -z "$SIM_TIME_NS" ]; then
            SIM_TIME_NS=$(grep "Last event time =" $DIR_PATH/pt.log | tail -n 1 | awk '{print $6}')
        fi
        [ -z "$SIM_TIME_NS" ] && SIM_TIME_NS="0"

        # 2. 抓取總功耗 (修正對位：PrimeTime 報表通常 $4 是數值)
        OP_POWER=$(grep "^Total Power" $CURRENT_REPORT | awk '{print $4}')
        [ -z "$OP_POWER" ] && OP_POWER="N/A"

        # 3. 寫入單筆記錄並「偷渡」時間標記進報告供 awk 結算
        echo "Internal_Sim_Time_ns $SIM_TIME_NS" >> $CURRENT_REPORT
        echo "${N}x${N},test_${t},${OP_POWER},${SIM_TIME_NS}" >> $CSV_FILE
        echo -e "\n  ✅ 波形長度: ${SIM_TIME_NS} ns, 運算功耗: ${OP_POWER} W"
    done

# ==========================================
    # 🌟 數據抓取專用修正版 (根據 power_summary.rpt 格式)
    # ==========================================
    echo -e "\n📊 正在結算 ${N}x${N} 的各項平均數據..."
    
    awk -v size="${N}x${N}" -v csv="$AVG_CSV_FILE" -v txt="$AVG_TXT_FILE" '
    BEGIN { clk=0; reg=0; comb=0; tot=0; sim_time=0; cnt=0; }
    {
        sub(/\r$/, ""); # 清除換行符號防呆

        # 1. 抓取 Clock Network (對應第 18 行，取第 5 欄)
        if ($1 == "clock_network") { clk += $5; }
        
        # 2. 抓取 Register (對應第 19 行，取第 5 欄)
        else if ($1 == "register") { reg += $5; }
        
        # 3. 抓取 Combinational (對應第 20 行，取第 5 欄)
        else if ($1 == "combinational") { comb += $5; }
        
        # 4. 抓取 Total Power (對應第 30 行，格式為 Total Power = 0.2422，取第 4 欄)
        else if ($1 == "Total" && $2 == "Power" && $3 == "=") { tot += $4; }
        
        # 5. 抓取先前偷渡的時間參數
        else if ($1 == "Internal_Sim_Time_ns") { sim_time += $2; cnt++; }
    }
    END {
        if (cnt == 0) cnt = 1;
        
        avg_t = sim_time/cnt; 
        avg_c = clk/cnt; 
        avg_r = reg/cnt; 
        avg_m = comb/cnt; 
        avg_p = tot/cnt;

        # 格式化輸出報告
        rep = sprintf("  ------------------------------------------\n  🎯 %s 功耗與波形時間結算 (共 %d 筆)\n  ------------------------------------------\n  ➤ Avg Waveform Time : %.2f ns\n  ➤ Clock Network     : %.3f mW\n  ➤ Register          : %.3f mW\n  ➤ Combinational     : %.3f mW\n  ➤ Total Power       : %.3f mW  <-- (平均總功耗)\n  ==========================================\n\n", size, cnt, avg_t, avg_c * 1000, avg_r * 1000, avg_m * 1000, avg_p * 1000);
        
        printf "%s", rep;
        printf "%s", rep >> txt;
        printf "%s, %d, %.2f, %.6f, %.6f, %.6f, %.6f\n", size, cnt, avg_t, avg_c, avg_r, avg_m, avg_p >> csv;
    }' ./rpt_power/power_${N}x${N}_test_*.rpt
done

echo "------------------------------------------"
echo "🎉 全部分析完畢！"