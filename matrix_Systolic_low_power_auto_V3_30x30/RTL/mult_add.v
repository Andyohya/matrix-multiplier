module mult_add#(
    parameter DATAWIDTH = 16 // 配合 Radix-4 的資料寬度
  )
  (
    input                            clk,
    input                            rst_n,
    input                            valid_i,
    input  [DATAWIDTH-1:0]           A,
    input  [DATAWIDTH-1:0]           B,
    input  [DATAWIDTH*2-1:0]         C,
    output [DATAWIDTH*2-1:0]         P,
    output                           valid_o
  );

  wire [DATAWIDTH*2-1:0] mult_out;

  // =========================================================
  // 中文修正：
  // 最新 booth_radix4 的 port 名稱為 CLK/RSTn/start/A/B/P/valid。
  // Verilog 的 named port 有大小寫之分，原本的 clk/rst_n/
  // valid_i/ans/valid_o 會連到不存在的 port。
  // =========================================================
  booth_radix4 #(
                 .DATAWIDTH(DATAWIDTH)
               ) u_radix4 (
                 .CLK   (clk),
                 .RSTn  (rst_n),
                 .start (valid_i),
                 .A     (A),
                 .B     (B),
                 .P     (mult_out),
                 .valid (valid_o)
               );

  // 本次乘積加上 PE 原有的累積結果
  assign P = mult_out + C;

endmodule
