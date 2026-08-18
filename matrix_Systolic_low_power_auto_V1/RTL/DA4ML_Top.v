`timescale 1ns/1ps

module DA4ML_Top #(
    parameter DATAWIDTH = 16,
    parameter ARRAY_SIZE = 3, // 🌟 規模參數[cite: 20]
    // 🌟 透過 $clog2 自動計算位址寬度[cite: 11, 20]
    parameter ADDRWIDTH = (ARRAY_SIZE == 1) ? 1 : $clog2(ARRAY_SIZE)
  )(
    input  wire CLK, RSTn,
    input  wire start, valid_i,
    input  wire [DATAWIDTH * ARRAY_SIZE - 1 : 0] A_in, B_in,
    input  wire transfer_start,
    output reg  transfer_done,
    input  wire m2_valid,
    input  wire signed [2:0] m2_weight,
    input  wire [ADDRWIDTH-1:0] m2_idx,
    input  wire m2_first, m2_last,
    output wire [DATAWIDTH*2*ARRAY_SIZE-1:0] y_out_col,
    output wire y_valid
  );

  localparam TOTAL_ELEMENTS = ARRAY_SIZE * ARRAY_SIZE;
  wire [ DATAWIDTH * 2 * TOTAL_ELEMENTS - 1 : 0 ] P_out_flat;
  wire sa_done_dummy, valid_o_wave_dummy;

  // 1. 實例化 Phase 1 (Systolic Array)
  Systolic_Array #(.DATAWIDTH(DATAWIDTH), .ARRAY_SIZE(ARRAY_SIZE)) u_phase1_array (
                   .CLK(CLK), .RSTn(RSTn), .start(start), .valid_i(valid_i),
                   .A_in(A_in), .B_in(B_in), .P_out(P_out_flat),
                   .Done(sa_done_dummy), .valid_o_wave(valid_o_wave_dummy)
                 );

  // 2. 向量化資料搬運邏輯[cite: 11]
  reg [ADDRWIDTH-1:0] xfer_cnt;
  reg z_we;
  reg [DATAWIDTH*ARRAY_SIZE-1:0] z_wdata_col;

  always @(posedge CLK or negedge RSTn) begin
    if (!RSTn) xfer_cnt <= 0;
    else if (transfer_start) xfer_cnt <= 0;
    else if (z_we && xfer_cnt < ARRAY_SIZE - 1) xfer_cnt <= xfer_cnt + 1;
  end

  always @(posedge CLK or negedge RSTn) begin
    if (!RSTn) z_we <= 0;
    else if (transfer_start) z_we <= 1;
    else if (z_we && xfer_cnt == ARRAY_SIZE - 1) z_we <= 0;
  end

  always @(posedge CLK or negedge RSTn) begin
    if (!RSTn) transfer_done <= 0;
    else if (z_we && xfer_cnt == ARRAY_SIZE - 1) transfer_done <= 1;
    else transfer_done <= 0;
  end

  integer r;
  always @(*) begin
    for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
      z_wdata_col[r*DATAWIDTH +: DATAWIDTH] =
                 P_out_flat[ ((r * ARRAY_SIZE + xfer_cnt) * DATAWIDTH * 2) +: DATAWIDTH ];
    end
  end

  // 3. 實例化 Phase 2 (Sparse Engine)
  sparse_engine #(
                  .DATAWIDTH(DATAWIDTH),
                  .ARRAY_SIZE(ARRAY_SIZE)
                ) u_phase2_engine (
                  .clk(CLK), .rst_n(RSTn), .z_we(z_we), .z_addr(xfer_cnt), 
                  .z_wdata_col(z_wdata_col), .m2_valid(m2_valid), 
                  .m2_weight(m2_weight), .m2_idx(m2_idx),
                  .m2_first(m2_first), .m2_last(m2_last),
                  .y_out_col(y_out_col), .y_valid(y_valid)
                );
endmodule