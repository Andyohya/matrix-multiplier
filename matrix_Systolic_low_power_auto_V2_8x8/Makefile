all: run_all

N ?= 4
T ?= 1

# 🌟 已修正：括號語法錯誤
TARGET_WAVE = ./mem/$(N)x$(N)/test_$(T)/wave.fsdb
TARGET_RPT = ./rpt_power/power_$(N)x$(N)_test_$(T).rpt

run_all: clean rtl_sim saif syn gate_sim power

# 🌟 已修正：加入動態參數與測資路徑，且維持單行避免斷行空白錯誤
rtl_sim:
	bsub -Ip -n 8 vcs -full64 -R -debug_access+all -pvalue+TB_DA4ML_16x16.CURRENT_N=$(N) +TEST_DIR=./mem/$(N)x$(N)/test_$(T) RTL/TB_DA4ML_16x16.v RTL/DA4ML_Top.v RTL/sparse_engine.v RTL/sparse_pe.v RTL/Systolic_Array.v RTL/PE_module.v RTL/mult_add.v RTL/booth_radix4.v

saif:
	bsub -Ip -n 8 fsdb2saif $(TARGET_WAVE) -o DA4ML_Top.saif

syn:
	CURRENT_N=$(N) bsub -Ip -n 8 dc_shell -f run_dc.tcl

gate_sim:
	bsub -Ip -n 8 vcs -full64 -R \
	+define+SDF \
	+no_notifier \
	-pvalue+TB_DA4ML_16x16.CURRENT_N=$(N) \
	-pvalue+TB_DA4ML_16x16.U_DUT.ARRAY_SIZE=$(N) \
	+TEST_DIR=./mem/$(N)x$(N)/test_$(T) \
	RTL/TB_DA4ML_16x16.v \
	./Netlist/DA4ML_Top_gate.v \
	-debug_access+all \
	-v /process/T18/IP/CBDK_TSMC018_Arm_v4.0/CIC/Verilog/tsmc18_neg.v +neg_tchk +maxdelays

power:
	@mkdir -p rpt_power
	CURRENT_FSDB="$(TARGET_WAVE)" \
	CURRENT_REPORT="$(TARGET_RPT)" \
	TOP_INSTANCE="TB_DA4ML_16x16/U_DUT" \
	bsub -Ip -n 8 pt_shell -f run_pt.tcl

verdi:
	bsub -Ip -n 8 verdi -ssf $(TARGET_WAVE)

clean:
	rm -rf csrc simv* *.log *.fsdb *.saif *.key *.rep ucli.key DVEfiles ./Netlist/*

auto:
	@chmod +x run_sweep.sh run_flow.sh
	./run_sweep.sh