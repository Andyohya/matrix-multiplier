`timescale 1ns/1ps

module TB_DA4ML_16x16;

  // =========================================================================
  // I. 參數定義 (支援動態覆蓋)[cite: 28]
  // =========================================================================
  parameter CURRENT_N = 16;
  parameter DATA_WIDTH = 16;

  // 🌟 自動計算對應位元寬度[cite: 28]
  parameter ADDRWIDTH = (CURRENT_N == 1) ? 1 : $clog2(CURRENT_N);
  parameter ACC_WIDTH = (DATA_WIDTH * 2) + ADDRWIDTH;
  parameter FINAL_WIDTH = ACC_WIDTH + ADDRWIDTH;
  localparam MEM_DEPTH = CURRENT_N * CURRENT_N;

  // =========================================================================
  // II. 記憶體與信號宣告[cite: 28]
  // =========================================================================
  reg [DATA_WIDTH-1:0] mem_A [0:MEM_DEPTH-1];
  reg [DATA_WIDTH-1:0] mem_W [0:MEM_DEPTH-1];
  reg [DATA_WIDTH-1:0] mem_M1 [0:MEM_DEPTH-1];
  reg [31:0]           mem_Y [0:MEM_DEPTH-1];

  reg [1023:0] test_dir;
  reg [1023:0] file_path;

  reg CLK;
  reg RSTn;
  reg start;
  reg valid_1;
  reg [DATA_WIDTH * CURRENT_N - 1 : 0] A_in;
  reg [DATA_WIDTH * CURRENT_N - 1 : 0] B_in;
  reg transfer_start;
  wire transfer_done;
  reg m2_valid;
  reg signed [2:0] m2_weight;
  reg [ADDRWIDTH-1:0] m2_idx;
  reg m2_first;
  reg m2_last;
  wire [DATA_WIDTH * 2 * CURRENT_N - 1 : 0] y_out_col;
  wire y_valid;

  reg sim_active;
  integer i, wave_clk;
  integer err_count = 0;
  integer f_m2;
  reg stop_reading;

  // =========================================================================
  // III. 實例化頂層模組 (DUT)[cite: 28]
  // 🌟 移除 ADDRWIDTH，由內部 $clog2 自動推導
  // =========================================================================
  DA4ML_Top #(
              .DATAWIDTH(DATA_WIDTH),
              .ARRAY_SIZE(CURRENT_N)
            ) U_DUT (
              .CLK(CLK), .RSTn(RSTn), .start(start), .valid_i(valid_1),
              .A_in(A_in), .B_in(B_in),
              .transfer_start(transfer_start), .transfer_done(transfer_done),
              .m2_valid(m2_valid), .m2_weight(m2_weight), .m2_idx(m2_idx),
              .m2_first(m2_first), .m2_last(m2_last),
              .y_out_col(y_out_col), .y_valid(y_valid)
            );

  // =========================================================================
  // IV. 時脈生成 (100MHz)[cite: 28]
  // =========================================================================
  initial
  begin
    CLK = 0;
    sim_active = 1;
    while(sim_active)
      #10 CLK = ~CLK;
  end

  // =========================================================================
  // V. 主測試流程：資料加載與激勵餵入[cite: 28]
  // =========================================================================
  initial
  begin
    // 1. 設定測資路徑
    if (!$value$plusargs("TEST_DIR=%s", test_dir))
    begin
      test_dir = "./mem/16x16/test_1";
    end

    // 2. 加載記憶體檔案
    file_path = {test_dir, "/A_matrix.mem"};
    $readmemh(file_path, mem_A);
    file_path = {test_dir, "/W_matrix.mem"};
    $readmemh(file_path, mem_W);
    file_path = {test_dir, "/M1_matrix.mem"};
    $readmemh(file_path, mem_M1);
    file_path = {test_dir, "/Y_golden.mem"};
    $readmemh(file_path, mem_Y);

    // 3. 設定波形輸出
    file_path = {test_dir, "/wave.fsdb"};
    $fsdbDumpfile(file_path);
    $fsdbDumpvars(0, TB_DA4ML_16x16);
`ifdef SDF

    $sdf_annotate("./Netlist/DA4ML_Top.sdf", U_DUT);
`endif

    // 4. 硬體復位
    RSTn = 0;
    valid_1 = 0;
    start = 0;
    transfer_start = 0;
    m2_valid = 0;
    A_in = 0;
    B_in = 0;
    m2_weight = 0;
    m2_idx = 0;
    m2_first = 0;
    m2_last = 0;

    #5 RSTn = 0;
    #10 RSTn = 1;
    #5;

    // ---------------------------------------------------------
    // Phase 1: 稠密矩陣運算 (Systolic Array)[cite: 28]
    // ---------------------------------------------------------
    start = 1;
    for (wave_clk = 0; wave_clk < (3 * CURRENT_N); wave_clk = wave_clk + 1)
    begin
      @(negedge CLK);
      valid_1 = 1;
      for (i = 0; i < CURRENT_N; i = i + 1)
      begin
        if (wave_clk >= i && wave_clk < i + CURRENT_N)
        begin
          A_in[i*DATA_WIDTH +: DATA_WIDTH] = mem_A[i*CURRENT_N + (wave_clk - i)];
          B_in[i*DATA_WIDTH +: DATA_WIDTH] = mem_M1[(wave_clk - i)*CURRENT_N + i];
        end
        else
        begin
          A_in[i*DATA_WIDTH +: DATA_WIDTH] = 0;
          B_in[i*DATA_WIDTH +: DATA_WIDTH] = 0;
        end
      end
      @(negedge CLK);
      valid_1 = 0;
      repeat(10) @(posedge CLK);
    end
    start = 0;
    repeat(15) @(posedge CLK);

    // ---------------------------------------------------------
    // 資料搬運控制[cite: 28]
    // ---------------------------------------------------------
    @(negedge CLK);
    transfer_start = 1;
    @(negedge CLK);
    transfer_start = 0;
    wait(transfer_done == 1);

    // ---------------------------------------------------------
    // Phase 2: 稀疏權重流 (Sparse Engine)[cite: 28]
    // ---------------------------------------------------------
    file_path = {test_dir, "/M2_stream.mem"};
    f_m2 = $fopen(file_path, "r");
    stop_reading = 0;

    while (!$feof(f_m2) && !stop_reading)
    begin
      @(negedge CLK);
      // 🌟 關鍵修正：改用 %d 讀取，解決位元截斷警告[cite: 1, 18, 28]
      if ($fscanf(f_m2, "%h %h %b %b\n", m2_idx, m2_weight, m2_first, m2_last) == 4)
      begin
        m2_valid = 1;
        @(negedge CLK);
        m2_valid = 0;
      end
      else
      begin
        stop_reading = 1;
      end
    end
    $fclose(f_m2);
  end

  // =========================================================================
  // VI. 自動化檢查器 (精準比對)[cite: 28]
  // =========================================================================
  integer y_col_cnt;
  integer r;
  reg [31:0] actual_y, expected_y;
  reg [15:0] actual_lower, expected_lower;

  initial
  begin
    y_col_cnt = 0;
    wait (transfer_done == 1);

    while (y_col_cnt < CURRENT_N)
    begin
      @(negedge CLK);
      if (y_valid)
      begin
        for (r = 0; r < CURRENT_N; r = r + 1)
        begin
          actual_y = y_out_col[r * 32 +: 32];
          expected_y = mem_Y[r * CURRENT_N + y_col_cnt];
          actual_lower = actual_y[15:0];
          expected_lower = expected_y[15:0];

          if (actual_lower !== expected_lower)
          begin
            $display("[ERROR] (Row %0d, Col %0d) -> Expected Lower: %04x, Got Lower: %04x",
                     r, y_col_cnt, expected_lower, actual_lower);
            err_count = err_count + 1;
          end
        end
        y_col_cnt = y_col_cnt + 1;
      end
    end

    #500;
    if (err_count == 0)
      $display("\n🎉 [ULTIMATE SUCCESS] All %0d results (Lower 16-bits) matched perfectly!", CURRENT_N * CURRENT_N);
    else
      $display("\n💀 [FAIL] Found %0d mismatches.", err_count);

    sim_active = 0;
    $finish;
  end

endmodule
