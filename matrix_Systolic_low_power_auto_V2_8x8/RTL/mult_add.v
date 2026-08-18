module mult_add#(
    parameter DATAWIDTH = 16 // 配合你 Radix-4 的 16-bit 寬度
  )
  (
    input                            clk,
    input                            rst_n,
    input                            valid_i, // 啟動運算訊號
    input  [ DATAWIDTH - 1 : 0 ]     A,
    input  [ DATAWIDTH - 1 : 0 ]     B,
    input  [ DATAWIDTH * 2 - 1 : 0 ] C,       // 來自 PE_reg 的累積部分和
    output [ DATAWIDTH * 2 - 1 : 0 ] P,       // 新的累積結果
    output                           valid_o  // 運算完成訊號
  );

  wire [31:0] mult_out; // 接收 Radix-4 的 32-bit 結果

  // ==========================================
  // 🌟 實例化你的 Radix-4 Booth 乘法器
  // ==========================================
  booth_radix4 u_radix4 (
                 .clk     (clk),
                 .rst_n   (rst_n),
                 .a       (A),
                 .b       (B),
                 .valid_i (valid_i),
                 .ans     (mult_out),
                 .valid_o (valid_o)
               );

  // ==========================================
  // 累積加法：將本次乘積加上原本的部分和 (C)
  // ==========================================
  assign P = mult_out + C;

endmodule
