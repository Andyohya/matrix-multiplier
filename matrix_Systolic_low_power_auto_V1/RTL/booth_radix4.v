`timescale 1ns/1ps

module booth_radix4(
    input  wire clk,
    input  wire rst_n,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    input  wire        valid_i,
    output wire signed [31:0] ans,
    output reg         valid_o
  );

  localparam HIGH_VOLT = 1'b1;
  localparam LOW_VOLT  = 1'b0;

  localparam DATA_WIDTH = 16;
  localparam ACC_LEN    = DATA_WIDTH + 3;

  reg [(ACC_LEN + DATA_WIDTH):0] p_reg;
  reg [15:0] a_reg;
  reg [4:0]  cnt;

  // 🌟 關鍵新增：睡眠模式旗標
  reg sleep_mode;

  reg [1:0] current_state, next_state;
  localparam IDLE = 2'd0, CAL = 2'd1, DONE = 2'd2;

  // =========================================================================
  // 1. 內建 Booth Encoder 邏輯
  // =========================================================================
  wire [2:0] encoder_in = p_reg[2:0];
  reg op_add, op_sub, is_x2;

  always @(*)
  begin
    op_add = 0;
    op_sub = 0;
    is_x2 = 0;
    case (encoder_in)
      3'b001, 3'b010:
      begin
        op_add = 1;
        is_x2 = 0;
      end
      3'b011:
      begin
        op_add = 1;
        is_x2 = 1;
      end
      3'b100:
      begin
        op_sub = 1;
        is_x2 = 1;
      end
      3'b101, 3'b110:
      begin
        op_sub = 1;
        is_x2 = 0;
      end
      default:
      begin
        op_add = 0;
        op_sub = 0;
        is_x2 = 0;
      end // 000, 111 不動作
    endcase
  end

  // =========================================================================
  // 2. ALU (算術邏輯單元) - 🌟 加入運算元隔離防護網
  // =========================================================================
  wire signed [ACC_LEN-1:0] current_acc = p_reg[(ACC_LEN + DATA_WIDTH) : DATA_WIDTH+1];
  reg signed [ACC_LEN-1:0] sum_out;
  reg signed [ACC_LEN-1:0] alu_op2;
  reg signed [ACC_LEN-1:0] raw_op;

  always @(*)
  begin
    if (!op_add && !op_sub)
      raw_op = {(ACC_LEN){1'b0}};
    else if (is_x2)
      raw_op = { {2{a_reg[15]}}, a_reg, 1'b0 };
    else
      raw_op = { {3{a_reg[15]}}, a_reg };

    if (op_sub)
      alu_op2 = ~raw_op;
    else
      alu_op2 = raw_op;
  end

  always @(*)
  begin
    // 🌟 運算元隔離：如果在睡覺，直接把加法器輸出強制壓在 0，不讓它翻轉耗電！
    if (sleep_mode)
      sum_out = {(ACC_LEN){1'b0}};
    else
      sum_out = current_acc + alu_op2 + op_sub;
  end

  // =========================================================================
  // 3. 下一階移位邏輯 (Datapath)
  // =========================================================================
  wire [(ACC_LEN + DATA_WIDTH):0] next_p_reg_val;

  // 🌟 睡眠期間，讓管線暫存器直接塞 0，避免無意義的 Shift 動作造成翻轉
  assign next_p_reg_val = sleep_mode ?
         {(ACC_LEN + DATA_WIDTH + 1){1'b0}} :
         { {2{sum_out[ACC_LEN-1]}}, sum_out, p_reg[DATA_WIDTH:2] };

  assign ans = p_reg[DATA_WIDTH*2 : 1];

  // =========================================================================
  // 4. 下一狀態邏輯 (FSM)
  // =========================================================================
  always @(*)
  begin
    next_state = IDLE;
    case (current_state)
      IDLE:
        next_state = (valid_i) ? CAL : IDLE;
      CAL:
        next_state = (cnt == 5'd7) ? IDLE : CAL;
      DONE:
        next_state = IDLE;
      default:
        next_state = IDLE;
    endcase
  end

  // =========================================================================
  // 5. 循序邏輯 (Registers) - 已修改為獨立變數 Block 寫法
  // =========================================================================

  // --- current_state 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      current_state <= IDLE;
    end
    else
    begin
      current_state <= next_state;
    end
  end

  // --- p_reg 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      p_reg <= 0;
    end
    else
    begin
      if (current_state == IDLE && valid_i)
      begin
        p_reg <= { {(ACC_LEN){1'b0}}, b, 1'b0 };
      end
      else if (current_state == CAL)
      begin
        p_reg <= next_p_reg_val;
      end
    end
  end

  // --- a_reg 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      a_reg <= 0;
    end
    else
    begin
      if (current_state == IDLE && valid_i)
      begin
        a_reg <= a;
      end
    end
  end

  // --- cnt 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      cnt <= 5'b0;
    end
    else
    begin
      if (current_state == IDLE && valid_i)
      begin
        cnt <= 5'b0;
      end
      else if (current_state == CAL)
      begin
        if (cnt == 5'd7)
          cnt <= 5'b0;
        else
          cnt <= cnt + 1'b1;
      end
      else if (current_state != IDLE && current_state != CAL)
      begin
        // 對應原本 default 狀態將 cnt 歸零的行為 (例如處於 DONE 狀態時)
        cnt <= 5'b0;
      end
    end
  end

  // --- valid_o 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      valid_o <= LOW_VOLT;
    end
    else
    begin
      if (current_state == IDLE)
      begin
        valid_o <= LOW_VOLT;
      end
      else if (current_state == CAL)
      begin
        if (cnt == 5'd7)
          valid_o <= HIGH_VOLT;
        else
          valid_o <= LOW_VOLT;
      end
    end
  end

  // --- sleep_mode 暫存器 ---
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      sleep_mode <= 1'b0;
    end
    else
    begin
      if (current_state == IDLE)
      begin
        if (valid_i)
        begin
          // 🌟 偵測是否有 0 進入：只要 A 或 B 是 0，就進入睡眠模式！
          sleep_mode <= (a == 16'sd0) || (b == 16'sd0);
        end
        else
        begin
          sleep_mode <= 1'b0;
        end
      end
    end
  end

endmodule
