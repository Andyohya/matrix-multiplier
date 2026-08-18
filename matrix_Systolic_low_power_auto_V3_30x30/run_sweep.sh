#!/bin/bash

# ==========================================
# 🌟 DA4ML 終極參數掃描腳本 (Sweep Script)
# ==========================================

# 🌟 控制面板：在這裡修改你要跑的矩陣大小與測資數量！
MATRIX_SIZES="4 16"
NUM_TESTS=5

# 先砍掉舊的總表與報告，確保這次跑的是全新數據
rm -f power_summary.csv avg_power_summary.csv avg_power_report.txt
echo "🚀 準備開始執行矩陣規模掃描: $MATRIX_SIZES (每個規模跑 $NUM_TESTS 筆測資)"

for SIZE in $MATRIX_SIZES; do
    echo "=================================================="
    echo "  🔥 現在正在處理: ${SIZE}x${SIZE} 矩陣架構"
    echo "=================================================="
    
    # 1. 執行完整的底層硬體合成 (傳遞參數 N=$SIZE 給 Makefile)
    echo "⏳ 正在執行 RTL模擬 -> 萃取SAIF -> 邏輯合成..."
    make clean rtl_sim saif syn N=$SIZE
    
    # 2. 確保合成沒報錯後，丟給運算節點跑批次功耗分析
    echo "⏳ 正在提交 ${SIZE}x${SIZE} 的功耗分析任務給運算節點..."
    bsub -Ip -n 8 ./run_flow.sh $SIZE $NUM_TESTS

    echo "✅ ${SIZE}x${SIZE} 分析完成！"
    echo ""
done

echo "🎉🎉🎉 所有規模全數執行完畢！"
echo "👉 詳細單筆數據：power_summary.csv"
echo "👉 平均結算報表：avg_power_report.txt"