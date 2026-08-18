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

  // 1. Ultra-Wide Z Buffer
  reg [DATAWIDTH*ARRAY_SIZE-1:0] z_buffer [0:ARRAY_SIZE-1];
  always @(posedge clk)
  begin
    if (z_we)
      z_buffer[z_addr] <= z_wdata_col;
  end

  // 2. 管線 Stage 1 暫存器
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
    else if (m2_valid)
    begin
      m2_v_d1 <= 1;
      z_read_data_col <= z_buffer[m2_idx];
      m2_w_d1 <= m2_weight;
      m2_first_d1 <= m2_first;
      m2_last_d1 <= m2_last;
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
