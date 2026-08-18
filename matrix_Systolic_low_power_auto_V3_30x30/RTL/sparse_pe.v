`timescale 1ns/1ps

module sparse_pe #(
    parameter DATAWIDTH = 16
  )(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         valid_i,
    input  wire signed [DATAWIDTH-1:0]  Z_in,           // 來自 Phase 1 算好的中間資料 (X * M1)
    input  wire signed [2:0]            M2_weight,      // 🌟 稀疏權重: 3-bit 有號數 (-2, -1, 0, 1, 2)
    input  wire signed [DATAWIDTH*2-1:0] partial_sum_in,// 從上一個 PE 傳遞過來的累積部分和

    output reg  signed [DATAWIDTH*2-1:0] partial_sum_out,
    output reg                           valid_o
  );

  // =========================================================================
  // 1. 資料寬度擴展 (Sign Extension)
  // 將 16-bit 的 Z_in 擴展為 32-bit，確保加法過程不會溢位 (Overflow)
  // =========================================================================
  wire signed [DATAWIDTH*2-1:0] Z_ext = { {(DATAWIDTH){Z_in[DATAWIDTH-1]}}, Z_in };

  // =========================================================================
  // 2. 無乘法器邏輯 (Multiplier-less MUX) & 運算元隔離 (Operand Isolation)
  // =========================================================================
  reg signed [DATAWIDTH*2-1:0] alu_op;
  reg                          do_sub;

  always @(*)
  begin
    // 🌟 運算元隔離預設值：一旦遇到預期外的輸入，強制為 0，阻止後方加法器不必要的翻轉耗電
    alu_op = 0;
    do_sub = 0;
    case (M2_weight)
      3'b000:
      begin
        alu_op = 0;
        do_sub = 0;
      end // 權重 = 0
      3'b001:
      begin
        alu_op = Z_ext;
        do_sub = 0;
      end // 權重 = 1 (加 1 倍的 Z_in)
      3'b010:
      begin
        alu_op = Z_ext <<< 1;
        do_sub = 0;
      end // 權重 = 2 (加 2 倍的 Z_in ➜ 硬體上直接左移 1 bit！)
      3'b111:
      begin
        alu_op = Z_ext;
        do_sub = 1;
      end // 權重 = -1 (二補數表示法，減 1 倍的 Z_in)
      3'b110:
      begin
        alu_op = Z_ext <<< 1;
        do_sub = 1;
      end // 權重 = -2 (二補數表示法，減 2 倍的 Z_in)
      default:
      begin
        alu_op = 0;
        do_sub = 0;
      end // 其他未定義的狀態 (如 3 或 -3) 強制視為 0
    endcase
  end

  // =========================================================================
  // 3. 核心加減法器 (單一 Adder 榨乾面積效益)
  // =========================================================================
  wire signed [DATAWIDTH*2-1:0] adder_out;

  // 根據 do_sub 決定是要加還是減
  assign adder_out = do_sub ? (partial_sum_in - alu_op) : (partial_sum_in + alu_op);

  // =========================================================================
  // 4. 管線化暫存器與交握邏輯 (Pipeline & Handshake)
  // =========================================================================

  // --- partial_sum_out 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      partial_sum_out <= 0;
    end
    else if (valid_i)
    begin
      // 🌟 只需要 1 個 Clock 就能算出結果！遠超 Radix-4 的 8 個 Clock！
      partial_sum_out <= adder_out;
    end
  end

  // --- valid_o 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      valid_o <= 1'b0;
    end
    else
    begin
      if (valid_i)
      begin
        valid_o <= 1'b1;
      end
      else
      begin
        // 沒有收到 valid_i 時，拉低 valid_o，保持管線安靜
        valid_o <= 1'b0;
      end
    end
  end

endmodule
