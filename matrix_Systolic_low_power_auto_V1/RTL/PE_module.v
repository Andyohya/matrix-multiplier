module PE_module#(
    parameter DATAWIDTH = 16
  )
  (
    input                        CLK,
    input                        RSTn,
    input                        valid_i, // 告訴這個 PE 可以開始算了
    input  [ DATAWIDTH - 1 : 0 ] A,
    input  [ DATAWIDTH - 1 : 0 ] B,
    output [ DATAWIDTH - 1 : 0 ] Next_A,
    output [ DATAWIDTH - 1 : 0 ] Next_B,
    output [ DATAWIDTH * 2 - 1 : 0 ] PE_out,
    output                       valid_o  // 告訴外面這個 PE 算完了
  );

  reg [ DATAWIDTH - 1 : 0 ]     Next_A_reg;
  reg [ DATAWIDTH - 1 : 0 ]     Next_B_reg;
  reg [ DATAWIDTH * 2 - 1 : 0 ] PE_reg;
  wire [ DATAWIDTH * 2 - 1 : 0 ] PE_net;

  // 呼叫我們剛剛改寫好的 mult_add
  mult_add #(.DATAWIDTH(DATAWIDTH)) multadd (
             .clk     (CLK),
             .rst_n   (RSTn),
             .valid_i (valid_i),
             .A       (A),
             .B       (B),
             .C       (PE_reg),
             .P       (PE_net),
             .valid_o (valid_o)
           );

  // 🌟 核心防護機制：
  // 只有當 Radix-4 歷經 8 拍運算結束，valid_o 拉高時，
  // PE 才會更新累積值，並把 A 和 B 傳給鄰居！

  // --- Next_A_reg 暫存器 ---
  always @ (posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      Next_A_reg <= 0;
    end
    else if (valid_o)
    begin
      Next_A_reg <= A;
    end
  end

  // --- Next_B_reg 暫存器 ---
  always @ (posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      Next_B_reg <= 0;
    end
    else if (valid_o)
    begin
      Next_B_reg <= B;
    end
  end

  // --- PE_reg 暫存器 ---
  always @ (posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      PE_reg <= 0;
    end
    else if (valid_o)
    begin
      PE_reg <= PE_net;
    end
  end

  assign PE_out = PE_reg;
  assign Next_A = Next_A_reg;
  assign Next_B = Next_B_reg;

endmodule
