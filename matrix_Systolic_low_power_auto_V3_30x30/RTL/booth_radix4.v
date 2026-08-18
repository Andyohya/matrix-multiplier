module booth_radix4 #(
    parameter DATAWIDTH = 16
  )(
    input  wire                   CLK,
    input  wire                   RSTn,
    input  wire                   start,
    input  wire [DATAWIDTH-1:0]   A,
    input  wire [DATAWIDTH-1:0]   B,
    output reg  [DATAWIDTH*2-1:0] P,
    output reg                    valid
  );

  localparam TOTAL_BITS = DATAWIDTH;
  localparam SHIFT_CNT  = TOTAL_BITS / 2;

  reg [2:0] state, next_state;
  reg [4:0] count;

  reg signed [DATAWIDTH*2-1:0]
      M_pos1, M_neg1, M_pos2, M_neg2;

  reg signed [DATAWIDTH*2-1:0] p_reg;
  reg [DATAWIDTH:0] b_reg;

  // 中文修正說明：
  // TSRI 的 Presto Verilog 編譯器要求訊號必須先宣告才能在循序區塊中使用。
  // 原本 partial_product 宣告在使用位置之後，會產生 VER-956 undefined symbol。
  // 此處只提前宣告位置，不改變任何乘法運算或時序行為。
  reg signed [DATAWIDTH*2-1:0] partial_product;

  localparam IDLE = 3'b000;
  localparam CALC = 3'b001;
  localparam DONE = 3'b010;

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      state <= IDLE;
      count <= 0;
      valid <= 0;
    end
    else
    begin
      state <= next_state;

      if (state == IDLE && start)
      begin
        count <= 0;
        valid <= 0;
      end
      else if (state == CALC)
      begin
        count <= count + 1;
      end
      else if (state == DONE)
      begin
        valid <= 1;
      end
      else
      begin
        valid <= 0;
      end
    end
  end

  always @(*)
  begin
    case (state)
      IDLE:
        next_state = start ? CALC : IDLE;

      CALC:
        next_state =
        (count == SHIFT_CNT - 1) ? DONE : CALC;

      DONE:
        next_state = IDLE;

      default:
        next_state = IDLE;
    endcase
  end

  wire signed [DATAWIDTH*2-1:0] sext_A =
       {{DATAWIDTH{A[DATAWIDTH-1]}}, A};

  always @(posedge CLK or negedge RSTn)
  begin
    if (!RSTn)
    begin
      b_reg  <= 0;
      p_reg  <= 0;
      M_pos1 <= 0;
      M_neg1 <= 0;
      M_pos2 <= 0;
      M_neg2 <= 0;
      P      <= 0;
    end
    else if (state == IDLE && start)
    begin
      b_reg <= {B, 1'b0};
      p_reg <= 0;

      M_pos1 <= sext_A;
      M_neg1 <= -sext_A;
      M_pos2 <= sext_A << 1;
      M_neg2 <= -(sext_A << 1);
    end
    else if (state == CALC)
    begin
      p_reg <= p_reg + partial_product;
      b_reg <= b_reg >> 2;

      M_pos1 <= M_pos1 << 2;
      M_neg1 <= M_neg1 << 2;
      M_pos2 <= M_pos2 << 2;
      M_neg2 <= M_neg2 << 2;
    end
    else if (state == DONE)
    begin
      P <= p_reg;
    end
  end

  always @(*)
  begin
    case (b_reg[2:0])
      3'b000, 3'b111:
        partial_product = 0;

      3'b001, 3'b010:
        partial_product = M_pos1;

      3'b011:
        partial_product = M_pos2;

      3'b100:
        partial_product = M_neg2;

      3'b101, 3'b110:
        partial_product = M_neg1;

      default:
        partial_product = 0;
    endcase
  end

endmodule
