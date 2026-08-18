`timescale 1ns/1ps

module sparse_engine #(
    parameter DATAWIDTH = 16,
    parameter ARRAY_SIZE = 16,
    parameter ADDRWIDTH = (ARRAY_SIZE == 1) ? 1 : $clog2(ARRAY_SIZE) // 🌟 自動計算[cite: 23]
  )(
    input  wire                         clk, rst_n,
    input  wire                         z_we,
    input  wire [ADDRWIDTH-1:0]         z_addr,
    input  wire [DATAWIDTH*ARRAY_SIZE-1:0] z_wdata_col,
    input  wire                         m2_valid,
    input  wire signed [2:0]            m2_weight,
    input  wire [ADDRWIDTH-1:0]         m2_idx,
    input  wire                         m2_first, m2_last,
    output wire [DATAWIDTH*2*ARRAY_SIZE-1:0] y_out_col,
    output wire                              y_valid
  );

  // 0. 寫入路徑 Pipeline 緩衝暫存器
  // 🌟 修正：原本 z_we/z_addr/z_wdata_col 是「當拍組合邏輯算完、當拍直接寫入」，
  // 256-bit 寬的欄位多工器 (z_wdata_col 由 DA4ML_Top 內的 16 選 1 mux 產生)
  // 直接落到 4096-bit 的 z_buffer 陣列上，在 200MHz(5ns) 下時序餘裕過薄，
  // 造成 gate-level 模擬出現 $setuphold 違規。這裡先把寫入所需的三個訊號
  // (z_we, z_addr, z_wdata_col) 打一拍，讓組合邏輯多工器的輸出有一整個
  // clock cycle 可以穩定下來，下一拍才真正寫進暫存器陣列。
  reg                              z_we_d1;
  reg [ADDRWIDTH-1:0]              z_addr_d1;
  reg [DATAWIDTH*ARRAY_SIZE-1:0]   z_wdata_col_d1;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      z_we_d1        <= 1'b0;
      z_addr_d1      <= {ADDRWIDTH{1'b0}};
      z_wdata_col_d1 <= {(DATAWIDTH*ARRAY_SIZE){1'b0}};
    end
    else
    begin
      z_we_d1        <= z_we;
      z_addr_d1      <= z_addr;
      z_wdata_col_d1 <= z_wdata_col;
    end
  end

  // 1. Ultra-Wide Z Buffer
  // 🌟 修正：改吃 pipeline 過的 _d1 訊號，寫入邏輯本身只剩下「暫存器load」，
  // 不再與 256-bit 多工器共用同一個 clock edge，藉此打斷長路徑。
  reg [DATAWIDTH*ARRAY_SIZE-1:0] z_buffer [0:ARRAY_SIZE-1];
  always @(posedge clk)
  begin
    if (z_we_d1)
      z_buffer[z_addr_d1] <= z_wdata_col_d1;
  end

  // 1.5 讀取路徑 Pipeline 緩衝暫存器
  // 🌟 修正：z_read_data_col_reg 出現的 $setuphold 違規，成因跟 z_buffer 寫入端
  // 是同一類問題 —— m2_idx 是直接從外部(頂層 port)進來的訊號，且 run_dc.tcl
  // 有下 set_input_delay 1.0，等於這條「m2_idx -> 16選1(256-bit) mux ->
  // z_read_data_col 暫存器」的路徑本來可用時間就先被扣掉 1ns 的 I/O 延遲假設，
  // 對一個 4 級邏輯深度的 256-bit 寬多工器來說餘裕太薄。這裡先把 m2_valid/
  // m2_idx/m2_weight/m2_first/m2_last 打一拍，讓「多工器讀取 z_buffer」這個動作
  // 變成乾淨的 register-to-register 路徑，拿回完整一個 clock period 的時間預算。
  reg                   m2_v_in0;
  reg signed [2:0]      m2_w_in0;
  reg [ADDRWIDTH-1:0]   m2_idx_in0;
  reg                   m2_first_in0, m2_last_in0;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      m2_v_in0     <= 1'b0;
      m2_w_in0     <= 3'sd0;
      m2_idx_in0   <= {ADDRWIDTH{1'b0}};
      m2_first_in0 <= 1'b0;
      m2_last_in0  <= 1'b0;
    end
    else
    begin
      m2_v_in0     <= m2_valid;
      m2_w_in0     <= m2_weight;
      m2_idx_in0   <= m2_idx;
      m2_first_in0 <= m2_first;
      m2_last_in0  <= m2_last;
    end
  end

  // 2. 管線 Stage 1 暫存器
  // 🌟 修正：改吃 pipeline 過的 _in0 訊號（延後 1 拍），而不是直接吃外部
  // m2_valid/m2_idx 原始訊號，藉此打斷長路徑。
  reg [DATAWIDTH*ARRAY_SIZE-1:0] z_read_data_col;
  reg signed [2:0] m2_w_d1;
  reg m2_v_d1, m2_first_d1, m2_last_d1;

  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      m2_v_d1 <= 0;
      z_read_data_col <= 0;
      m2_w_d1 <= 0;
      m2_first_d1 <= 0;
      m2_last_d1 <= 0;
    end
    else if (m2_v_in0)
    begin
      m2_v_d1 <= 1;
      z_read_data_col <= z_buffer[m2_idx_in0];
      m2_w_d1 <= m2_w_in0;
      m2_first_d1 <= m2_first_in0;
      m2_last_d1 <= m2_last_in0;
    end
    else
    begin
      m2_v_d1 <= 0;
    end
  end

  // 3. SIMD PE Array 生成
  wire [DATAWIDTH*2*ARRAY_SIZE-1:0] pe_out_col;
  wire [ARRAY_SIZE-1:0] pe_valid_arr;
  genvar i;
  generate
    for (i = 0; i < ARRAY_SIZE; i = i + 1)
    begin : SIMD_PE
      wire signed [DATAWIDTH*2-1:0] pe_acc_in = m2_first_d1 ? 0 : pe_out_col[i*(DATAWIDTH*2) +: (DATAWIDTH*2)];
      sparse_pe #(.DATAWIDTH(DATAWIDTH)) u_pe (
                  .clk(clk), .rst_n(rst_n), .valid_i(m2_v_d1),
                  .Z_in(z_read_data_col[i*DATAWIDTH +: DATAWIDTH]),
                  .M2_weight(m2_w_d1), .partial_sum_in(pe_acc_in),
                  .partial_sum_out(pe_out_col[i*(DATAWIDTH*2) +: (DATAWIDTH*2)]),
                  .valid_o(pe_valid_arr[i])
                );
    end
  endgenerate

  // 4. 輸出處理邏輯[cite: 23]
  reg m2_last_d2;
  reg [DATAWIDTH*2*ARRAY_SIZE-1:0] y_out_col_reg;
  reg y_valid_reg;
  always @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      y_out_col_reg <= 0;
      y_valid_reg <= 0;
      m2_last_d2 <= 0;
    end
    else
    begin
      m2_last_d2 <= m2_last_d1;
      if (pe_valid_arr[0] && m2_last_d2)
      begin
        y_out_col_reg <= pe_out_col;
        y_valid_reg <= 1;
      end
      else
      begin
        y_valid_reg <= 0;
      end
    end
  end
  assign y_out_col = y_out_col_reg;
  assign y_valid = y_valid_reg;
endmodule
