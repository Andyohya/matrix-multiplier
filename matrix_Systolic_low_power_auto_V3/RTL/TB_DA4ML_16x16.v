`timescale 1ns/1ps

module TB_DA4ML_16x16;

  // =========================================================================
  // I. 參數定義
  // =========================================================================
  parameter CURRENT_N = 16;
  parameter DATA_WIDTH = 16;

  parameter ADDRWIDTH =
            (CURRENT_N == 1) ? 1 : $clog2(CURRENT_N);

  parameter ACC_WIDTH =
            (DATA_WIDTH * 2) + ADDRWIDTH;

  parameter FINAL_WIDTH =
            ACC_WIDTH + ADDRWIDTH;

  localparam MEM_DEPTH =
             CURRENT_N * CURRENT_N;

  // =========================================================================
  // II. 記憶體與信號宣告
  // =========================================================================
  reg [DATA_WIDTH-1:0] mem_A  [0:MEM_DEPTH-1];
  reg [DATA_WIDTH-1:0] mem_W  [0:MEM_DEPTH-1];
  reg [DATA_WIDTH-1:0] mem_M1 [0:MEM_DEPTH-1];
  reg [31:0]           mem_Y  [0:MEM_DEPTH-1];

  reg [1023:0] test_dir;
  reg [1023:0] file_path;

  reg CLK;
  reg RSTn;
  reg start;
  reg valid_1;

  reg [DATA_WIDTH*CURRENT_N-1:0] A_in;
  reg [DATA_WIDTH*CURRENT_N-1:0] B_in;

  reg  transfer_start;
  wire transfer_done;

  reg                         m2_valid;
  reg signed [2:0]            m2_weight;
  reg [ADDRWIDTH-1:0]         m2_idx;
  reg                         m2_first;
  reg                         m2_last;

  wire [DATA_WIDTH*2*CURRENT_N-1:0] y_out_col;
  wire y_valid;

  integer i;
  integer wave_clk;
  integer err_count = 0;
  integer f_m2;

  reg stop_reading;

  // 中文修正：
  // M2_stream 使用兩位十六進位文字表示 index/weight。
  // 先讀進 32-bit 暫存器，再轉成硬體位寬，
  // 避免 VCS 出現 hexadecimal truncation warning。
  reg [31:0] scan_idx;
  reg [31:0] scan_weight;
  reg [31:0] scan_first;
  reg [31:0] scan_last;

  // RTL simulation 的 Phase 1 自我檢查變數
  integer phase1_row;
  integer phase1_col;
  integer phase1_k;
  integer phase1_err_count;

  reg signed [63:0] phase1_sum;
  reg signed [DATA_WIDTH-1:0] phase1_a_value;
  reg signed [DATA_WIDTH-1:0] phase1_m1_value;
  reg signed [DATA_WIDTH*2-1:0] phase1_product;
  reg [15:0] phase1_actual;

  // =========================================================================
  // III. DUT
  // =========================================================================
  DA4ML_Top #(
              .DATAWIDTH(DATA_WIDTH),
              .ARRAY_SIZE(CURRENT_N)
            ) U_DUT (
              .CLK            (CLK),
              .RSTn           (RSTn),
              .start          (start),
              .valid_i        (valid_1),
              .A_in           (A_in),
              .B_in           (B_in),
              .transfer_start (transfer_start),
              .transfer_done  (transfer_done),
              .m2_valid       (m2_valid),
              .m2_weight      (m2_weight),
              .m2_idx         (m2_idx),
              .m2_first       (m2_first),
              .m2_last        (m2_last),
              .y_out_col      (y_out_col),
              .y_valid        (y_valid)
            );

  // =========================================================================
  // IV. 200 MHz 時脈
  // =========================================================================
  initial
  begin
    // 中文修正：
    // CLK 必須永遠持續翻轉，避免 testbench 等待 clock edge 時死鎖。
    CLK = 1'b0;

    forever
      #2.5 CLK = ~CLK;
  end

  // =========================================================================
  // V. 主測試流程
  // =========================================================================
  initial
  begin
    // -----------------------------------------------------------------------
    // 1. 測試資料路徑
    // -----------------------------------------------------------------------
    if (!$value$plusargs("TEST_DIR=%s", test_dir))
    begin
      test_dir = "./mem/16x16/test_1";
    end

    $display(
        "[%0t] INFO: TEST_DIR=%0s",
        $time,
        test_dir
      );

    // -----------------------------------------------------------------------
    // 2. 載入測試資料
    // -----------------------------------------------------------------------
    file_path = {test_dir, "/A_matrix.mem"};
    $readmemh(file_path, mem_A);

    file_path = {test_dir, "/W_matrix.mem"};
    $readmemh(file_path, mem_W);

    file_path = {test_dir, "/M1_matrix.mem"};
    $readmemh(file_path, mem_M1);

    file_path = {test_dir, "/Y_golden.mem"};
    $readmemh(file_path, mem_Y);

    // -----------------------------------------------------------------------
    // 3. FSDB
    // -----------------------------------------------------------------------
    file_path = {test_dir, "/wave.fsdb"};
    $fsdbDumpfile(file_path);
    $fsdbDumpvars(0, TB_DA4ML_16x16);

`ifdef SDF

    $sdf_annotate(
        "./Netlist/DA4ML_Top.sdf",
        U_DUT
      );
`endif

    // -----------------------------------------------------------------------
    // 4. 初始化與 reset
    // -----------------------------------------------------------------------
    RSTn           = 1'b0;
    valid_1        = 1'b0;
    start          = 1'b0;
    transfer_start = 1'b0;
    m2_valid       = 1'b0;
    A_in           = 0;
    B_in           = 0;
    m2_weight      = 0;
    m2_idx         = 0;
    m2_first       = 1'b0;
    m2_last        = 1'b0;

    scan_idx       = 0;
    scan_weight    = 0;
    scan_first     = 0;
    scan_last      = 0;

    $display(
        "[%0t] INFO: Reset asserted",
        $time
      );

    // 中文修正：
    // 保持 reset 四拍，於 CLK 負緣解除 reset。
    repeat (4) @(posedge CLK);

    @(negedge CLK);
    RSTn = 1'b1;

    $display(
        "[%0t] INFO: Reset released",
        $time
      );

    // 16×16 額外等待二十拍
    repeat (20) @(negedge CLK);
    #0.1;
    start = 1'b1;
    $display(
        "[%0t] INFO: Starting Phase 1",
        $time
      );

    // -----------------------------------------------------------------------
    // 5. Phase 1：稠密矩陣運算
    // -----------------------------------------------------------------------


    for (
      wave_clk = 0;
      wave_clk < (3 * CURRENT_N);
      wave_clk = wave_clk + 1
    )
    begin
      @(negedge CLK);
      #0.1;

      valid_1 = 1'b1;

      for (i = 0; i < CURRENT_N; i = i + 1)
      begin
        if (
          wave_clk >= i &&
          wave_clk < (i + CURRENT_N)
        )
        begin
          A_in[i*DATA_WIDTH +: DATA_WIDTH]
              = mem_A[
                i*CURRENT_N +
                (wave_clk-i)
              ];

          B_in[i*DATA_WIDTH +: DATA_WIDTH]
              = mem_M1[
                (wave_clk-i)*CURRENT_N +
                i
              ];
        end
        else
        begin
          A_in[i*DATA_WIDTH +: DATA_WIDTH] = 0;
          B_in[i*DATA_WIDTH +: DATA_WIDTH] = 0;
        end
      end

      @(negedge CLK);
      valid_1 = 1'b0;

      repeat (10) @(posedge CLK);
    end

    @(negedge CLK);
    #0.1;
    start = 1'b0;

    $display(
        "[%0t] INFO: Phase 1 input completed",
        $time
      );

    repeat (15) @(posedge CLK);

    // -----------------------------------------------------------------------
    // 6. Phase 1 -> Phase 2 資料搬運
    // -----------------------------------------------------------------------
    @(negedge CLK);
    transfer_start = 1'b1;

    $display(
        "[%0t] INFO: Transfer requested",
        $time
      );

    @(negedge CLK);
    transfer_start = 1'b0;

    wait (transfer_done === 1'b1);

    $display(
        "[%0t] INFO: Transfer completed",
        $time
      );

    `ifndef SDF
            // -----------------------------------------------------------------------
            // RTL-only Phase 1 自我檢查
            // -----------------------------------------------------------------------
            // 中文修正：
            // 直接重算 A×M1 並與 z_buffer 比較。
            // Gate simulation 因合成後階層名稱不同，所以使用 SDF 時不執行。
            phase1_err_count = 0;

    for (
      phase1_row = 0;
      phase1_row < CURRENT_N;
      phase1_row = phase1_row + 1
    )
    begin
      for (
        phase1_col = 0;
        phase1_col < CURRENT_N;
        phase1_col = phase1_col + 1
      )
      begin
        phase1_sum = 64'sd0;

        for (
          phase1_k = 0;
          phase1_k < CURRENT_N;
          phase1_k = phase1_k + 1
        )
        begin
          // 中文修正：
          // 先放入 signed 暫存器，確保乘積保留完整 32-bit。
          phase1_a_value =
            mem_A[
              phase1_row*CURRENT_N +
              phase1_k
            ];

          phase1_m1_value =
            mem_M1[
              phase1_k*CURRENT_N +
              phase1_col
            ];

          phase1_product =
            phase1_a_value *
            phase1_m1_value;

          phase1_sum =
            phase1_sum +
            phase1_product;
        end

        phase1_actual =
          U_DUT.u_phase2_engine.z_buffer[phase1_col]
          [phase1_row*DATA_WIDTH +: DATA_WIDTH];

        if (
          phase1_actual !==
          phase1_sum[15:0]
        )
        begin
          // 最多印出前16筆，避免終端機被大量訊息淹沒
          if (phase1_err_count < 16)
          begin
            $display(
                "[PHASE1 ERROR] (R%0d,C%0d) Expected=%04x Got=%04x",
                phase1_row,
                phase1_col,
                phase1_sum[15:0],
                phase1_actual
              );
          end

          phase1_err_count =
            phase1_err_count + 1;
        end
      end
    end

    if (phase1_err_count == 0)
    begin
      $display(
          "[%0t] INFO: Phase 1 z_buffer check PASS (256/256)",
          $time
        );
    end
    else
    begin
      $display(
          "[%0t] ERROR: Phase 1 z_buffer check found %0d errors",
          $time,
          phase1_err_count
        );
    end
`endif

    // -----------------------------------------------------------------------
    // 7. Phase 2：稀疏權重資料流
    // -----------------------------------------------------------------------
    file_path = {
                test_dir,
                "/M2_stream.mem"
              };

    f_m2 = $fopen(file_path, "r");
    stop_reading = 1'b0;

    if (f_m2 == 0)
    begin
      $display(
          "[%0t] FATAL: Cannot open %0s",
          $time,
          file_path
        );

      $finish;
    end

    $display(
        "[%0t] INFO: Starting Phase 2",
        $time
      );

    while (
      !$feof(f_m2) &&
      !stop_reading
    )
    begin
      @(negedge CLK);

      if (
        $fscanf(
          f_m2,
          "%h %h %b %b\n",
          scan_idx,
          scan_weight,
          scan_first,
          scan_last
        ) == 4
      )
      begin
        // 中文修正：
        // 從32位讀檔暫存器切出實際硬體位寬。
        m2_idx =
          scan_idx[ADDRWIDTH-1:0];

        m2_weight =
          scan_weight[2:0];

        m2_first =
          scan_first[0];

        m2_last =
          scan_last[0];

        m2_valid = 1'b1;

        @(negedge CLK);
        #0.1;
        m2_valid = 1'b0;
      end
      else
      begin
        stop_reading = 1'b1;
      end
    end

    $fclose(f_m2);

    $display(
        "[%0t] INFO: Phase 2 input completed",
        $time
      );
  end

  // =========================================================================
  // VI. 自動結果比對
  // =========================================================================
  integer y_col_cnt;
  integer r;

  reg [31:0] actual_y;
  reg [31:0] expected_y;
  reg [15:0] actual_lower;
  reg [15:0] expected_lower;

  initial
  begin
    y_col_cnt = 0;

    wait (transfer_done === 1'b1);

    $display(
        "[%0t] INFO: Starting result comparison",
        $time
      );

    while (y_col_cnt < CURRENT_N)
    begin
      @(negedge CLK);

      if (y_valid === 1'b1)
      begin
        $display(
            "[%0t] INFO: Comparing output column %0d",
            $time,
            y_col_cnt
          );

        for (
          r = 0;
          r < CURRENT_N;
          r = r + 1
        )
        begin
          actual_y =
            y_out_col[
              r*32 +: 32
            ];

          expected_y =
            mem_Y[
              r*CURRENT_N +
              y_col_cnt
            ];

          actual_lower =
            actual_y[15:0];

          expected_lower =
            expected_y[15:0];

          if (
            actual_lower !==
            expected_lower
          )
          begin
            $display(
                "[ERROR] Index %0d (R%0d,C%0d) -> Expected Lower: %04x, Got Lower: %04x",
                r*CURRENT_N + y_col_cnt,
                r,
                y_col_cnt,
                expected_lower,
                actual_lower
              );

            err_count =
              err_count + 1;
          end
        end

        y_col_cnt =
          y_col_cnt + 1;
      end
    end

    #500;

    if (err_count == 0)
    begin
      $display(
          "\n[PASS] All %0d results matched perfectly!",
          CURRENT_N * CURRENT_N
        );
    end
    else
    begin
      $display(
          "\n[FAIL] Found %0d mismatches.",
          err_count
        );
    end

    $finish;
  end

  // =========================================================================
  // VII. Timeout 防護
  // =========================================================================
  initial
  begin
    // 正常16×16測試遠小於100 us。
    #100000;

    $display(
        "[%0t] FATAL: Simulation timeout",
        $time
      );

    $display(
        "CLK=%b RSTn=%b start=%b valid_1=%b",
        CLK,
        RSTn,
        start,
        valid_1
      );

    $display(
        "transfer_start=%b transfer_done=%b y_valid=%b",
        transfer_start,
        transfer_done,
        y_valid
      );

    $finish;
  end

endmodule
