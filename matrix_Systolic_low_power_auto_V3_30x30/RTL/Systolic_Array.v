`timescale 1ns / 1ps

module Systolic_Array#(
    parameter DATAWIDTH = 16,
    parameter ARRAY_SIZE = 3  // 🌟 新增：陣列規模參數，預設為 3 (即 3x3)
  )(
    input                            CLK,
    input                            RSTn,
    input                            start,
    input                            valid_i,

    // 🌟 將原本獨立的 A0, A1... 合併為一維的扁平化陣列 (Flattened Array)
    // A_in 的長度為 DATAWIDTH * ARRAY_SIZE
    // B_in 的長度為 DATAWIDTH * ARRAY_SIZE
    input      [ DATAWIDTH * ARRAY_SIZE - 1 : 0 ] A_in,
    input      [ DATAWIDTH * ARRAY_SIZE - 1 : 0 ] B_in,

    // 🌟 將原本獨立的 P11, P12... 合併為一個超長的輸出陣列
    // 長度為 (DATAWIDTH*2) * (ARRAY_SIZE * ARRAY_SIZE)
    output wire [ DATAWIDTH * 2 * ARRAY_SIZE * ARRAY_SIZE - 1 : 0 ] P_out,

    output                           Done,
    output                           valid_o_wave
  );

  // =========================================================
  // 內部接線網 (Internal Routing Network)
  // =========================================================
  // 宣告 2D 的 wire 陣列來負責 PE 之間的資料傳遞
  // row_a 負責橫向傳遞 A，col_b 負責縱向傳遞 B
  wire [DATAWIDTH-1:0] row_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
  wire [DATAWIDTH-1:0] col_b [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
  wire valid_o_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

  genvar i, j;
  generate
    // =========================================================
    // 邊界接線 (Border Connections)
    // 將外部輸入的 A_in 和 B_in 拆解並接入陣列的最左邊與最上面
    // =========================================================
    for (i = 0; i < ARRAY_SIZE; i = i + 1)
    begin : borders
      assign row_a[i][0] = A_in[(i+1)*DATAWIDTH-1 : i*DATAWIDTH];
      assign col_b[0][i] = B_in[(i+1)*DATAWIDTH-1 : i*DATAWIDTH];
    end

    // =========================================================
    // 自動生成 PE 陣列 (Automated PE Generation)
    // 雙層迴圈自動實例化 ARRAY_SIZE * ARRAY_SIZE 個 PE
    // =========================================================
    for (i = 0; i < ARRAY_SIZE; i = i + 1)
    begin : row
      for (j = 0; j < ARRAY_SIZE; j = j + 1)
      begin : col
        PE_module #(.DATAWIDTH(DATAWIDTH)) u_PE (
                    .CLK(CLK),
                    .RSTn(RSTn),
                    .valid_i(valid_i),

                    // 輸入資料：來自左邊與上面的線
                    .A(row_a[i][j]),
                    .B(col_b[i][j]),

                    // 輸出資料：傳給右邊與下面的線
                    .Next_A(row_a[i][j+1]),
                    .Next_B(col_b[i+1][j]),

                    // 計算結果：對應到 P_out 的特定區塊
                    .PE_out(P_out[((i*ARRAY_SIZE+j)+1)*(DATAWIDTH*2)-1 : (i*ARRAY_SIZE+j)*(DATAWIDTH*2)]),

                    .valid_o(valid_o_wire[i][j])
                  );
      end
    end
  endgenerate

  // =========================================================
  // 控制訊號輸出
  // =========================================================
  // 追蹤第一顆 PE (左上角) 的完成訊號，做為波浪傳遞的基準
  assign valid_o_wave = valid_o_wire[0][0];

  // Radix-4 的運算延遲固定為 8 個 Clock (與矩陣大小無關)
  // 所以 wave_cnt 維持原樣，計數 0~7
  reg [3:0] wave_cnt;
  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
      wave_cnt <= 0;
    else if (start && valid_i)
    begin
      if (wave_cnt == 7)
        wave_cnt <= 0;
      else
        wave_cnt <= wave_cnt + 1;
    end
  end

  assign Done = (wave_cnt == 7) ? 1'b1 : 1'b0;

endmodule
