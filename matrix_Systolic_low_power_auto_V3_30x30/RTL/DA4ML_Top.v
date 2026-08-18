`timescale 1ns/1ps

module DA4ML_Top #(
    parameter DATAWIDTH = 16,
    parameter ARRAY_SIZE = 3,
    parameter ADDRWIDTH =
    (ARRAY_SIZE == 1) ? 1 : $clog2(ARRAY_SIZE)
  )(
    input  wire CLK,
    input  wire RSTn,

    input  wire start,
    input  wire valid_i,

    input  wire [
      DATAWIDTH * ARRAY_SIZE - 1 : 0
    ] A_in,

    input  wire [
      DATAWIDTH * ARRAY_SIZE - 1 : 0
    ] B_in,

    input  wire transfer_start,
    output reg  transfer_done,

    input  wire m2_valid,
    input  wire signed [2:0] m2_weight,
    input  wire [ADDRWIDTH-1:0] m2_idx,
    input  wire m2_first,
    input  wire m2_last,

    output wire [
      DATAWIDTH * 2 * ARRAY_SIZE - 1 : 0
    ] y_out_col,

    output wire y_valid
  );

  localparam TOTAL_ELEMENTS =
             ARRAY_SIZE * ARRAY_SIZE;

  wire [
      DATAWIDTH * 2 * TOTAL_ELEMENTS - 1 : 0
    ] P_out_flat;

  // ============================================================
  // Phase 1 完成時間控制
  // ============================================================
  //
  // Systolic Array 的資料需要逐級傳遞到最遠端 PE。
  // 除了陣列傳遞延遲以外，Booth multiplier 也需要固定週期。
  //
  // 因此不能只依賴 testbench 的固定 repeat 時間，
  // 而是在 top module 內部自行判斷陣列是否已經穩定。
  // ============================================================

  wire sa_done;
  wire valid_o_wave_dummy;

  localparam SKEW_CYCLES =
             2 * (ARRAY_SIZE - 1);

  localparam BOOTH_LATENCY = 8;
  localparam SETTLE_MARGIN = 4;

  localparam SETTLE_CYCLES =
             SKEW_CYCLES +
             BOOTH_LATENCY +
             SETTLE_MARGIN;

  reg        start_d1;
  reg [15:0] settle_cnt;
  reg        array_settled;

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      start_d1      <= 1'b0;
      settle_cnt    <= 16'd0;
      array_settled <= 1'b0;
    end
    else
    begin
      start_d1 <= start;

      if (start)
      begin
        // 輸入資料還在送入陣列時，重新開始計算等待時間。
        settle_cnt    <= 16'd0;
        array_settled <= 1'b0;
      end
      else if (start_d1)
      begin
        // 偵測 start 的下降緣，開始計算 settle 時間。
        settle_cnt    <= 16'd1;
        array_settled <= 1'b0;
      end
      else if (!array_settled)
      begin
        if (settle_cnt >= SETTLE_CYCLES)
        begin
          array_settled <= 1'b1;
        end
        else
        begin
          settle_cnt <= settle_cnt + 1'b1;
        end
      end
    end
  end

  // ============================================================
  // Phase 1：Systolic Array
  // ============================================================

  Systolic_Array #(
                   .DATAWIDTH (DATAWIDTH),
                   .ARRAY_SIZE(ARRAY_SIZE)
                 ) u_phase1_array (
                   .CLK         (CLK),
                   .RSTn        (RSTn),
                   .start       (start),
                   .valid_i     (valid_i),
                   .A_in        (A_in),
                   .B_in        (B_in),
                   .P_out       (P_out_flat),
                   .Done        (sa_done),
                   .valid_o_wave(valid_o_wave_dummy)
                 );

  // ============================================================
  // Phase 1 → Phase 2 資料搬運
  // ============================================================

  reg [ADDRWIDTH-1:0] xfer_cnt;
  reg                 z_we;

  reg [
      DATAWIDTH * ARRAY_SIZE - 1 : 0
    ] z_wdata_col;

  // 中文修正說明：
  //
  // ARRAY_SIZE 是 signed integer parameter，
  // 而 xfer_cnt 是 unsigned vector。
  //
  // 原本直接比較：
  //
  //   xfer_cnt < ARRAY_SIZE - 1
  //
  // 會讓 Design Compiler 產生 VER-318
  // signed-to-unsigned conversion warning。
  //
  // 先把最後位址轉成與 xfer_cnt 相同寬度的 unsigned
  // localparam，即可消除 warning。
  //
  // 此修改只修正型別，不改變資料搬運行為。
  localparam [ADDRWIDTH-1:0] XFER_LAST_ADDR =
             ARRAY_SIZE - 1;

  // ============================================================
  // Transfer request latch
  // ============================================================

  reg transfer_req;

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      transfer_req <= 1'b0;
    end
    else if (transfer_start)
    begin
      // 保存外部送入的 transfer request。
      transfer_req <= 1'b1;
    end
    else if (z_we)
    begin
      // 真正開始搬運後清除 request。
      transfer_req <= 1'b0;
    end
  end

  wire xfer_kickoff;

  assign xfer_kickoff =
         transfer_req &&
         array_settled &&
         !z_we;

  // ============================================================
  // Transfer counter
  // ============================================================

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      xfer_cnt <= {ADDRWIDTH{1'b0}};
    end
    else if (xfer_kickoff)
    begin
      xfer_cnt <= {ADDRWIDTH{1'b0}};
    end
    else if (z_we &&
             xfer_cnt < XFER_LAST_ADDR)
    begin
      xfer_cnt <= xfer_cnt + 1'b1;
    end
  end

  // ============================================================
  // Z-buffer write enable
  // ============================================================

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      z_we <= 1'b0;
    end
    else if (xfer_kickoff)
    begin
      z_we <= 1'b1;
    end
    else if (z_we &&
             xfer_cnt == XFER_LAST_ADDR)
    begin
      z_we <= 1'b0;
    end
  end

  // ============================================================
  // Transfer done pipeline
  // ============================================================
  //
  // sparse_engine 內部的 z-buffer write path 有一級 pipeline。
  // 最後一筆 z_we 發生後，需要再延遲一個 clock 才能宣告
  // transfer_done。
  // ============================================================

  reg last_write_flag_d1;

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      last_write_flag_d1 <= 1'b0;
    end
    else
    begin
      last_write_flag_d1 <=
                         z_we &&
                         (xfer_cnt == XFER_LAST_ADDR);
    end
  end

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      transfer_done <= 1'b0;
    end
    else
    begin
      transfer_done <= last_write_flag_d1;
    end
  end

  // ============================================================
  // 從 P_out_flat 選出目前要搬運的 column
  // ============================================================

  integer r;

  always @(*)
  begin
    // 預設值可避免組合邏輯被誤判為 latch。
    z_wdata_col =
      {(DATAWIDTH * ARRAY_SIZE){1'b0}};

    for (r = 0; r < ARRAY_SIZE; r = r + 1)
    begin
      z_wdata_col[
          r * DATAWIDTH +: DATAWIDTH
        ] =
        P_out_flat[
          (
            (
              r * ARRAY_SIZE +
              xfer_cnt
            ) *
            DATAWIDTH *
            2
          ) +: DATAWIDTH
        ];
    end
  end

  // ============================================================
  // Phase 2：Sparse Engine
  // ============================================================

  sparse_engine #(
                  .DATAWIDTH (DATAWIDTH),
                  .ARRAY_SIZE(ARRAY_SIZE)
                ) u_phase2_engine (
                  .clk        (CLK),
                  .rst_n      (RSTn),

                  .z_we       (z_we),
                  .z_addr     (xfer_cnt),
                  .z_wdata_col(z_wdata_col),

                  .m2_valid   (m2_valid),
                  .m2_weight  (m2_weight),
                  .m2_idx     (m2_idx),
                  .m2_first   (m2_first),
                  .m2_last    (m2_last),

                  .y_out_col  (y_out_col),
                  .y_valid    (y_valid)
                );

endmodule
