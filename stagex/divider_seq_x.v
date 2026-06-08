`timescale 1ns / 1ps

module divider_seq #(
    parameter WIDTH = 64  
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input  wire signed [WIDTH-1:0] dividend,
    input  wire signed [WIDTH-1:0] divisor,
    output reg  signed [WIDTH-1:0] quotient,
    output reg  busy,
    output reg  done
);

    reg [WIDTH-1:0] a_reg;
    reg [WIDTH-1:0] b_reg;
    reg [WIDTH-1:0] q_reg;
    reg [WIDTH:0]   acc;
    
    // 【修复点 1】6位只能存到63，WIDTH=64时必须升级到7位
    reg [6:0]       count; 
    
    reg             sign_diff;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 0;
            done <= 0;
            quotient <= 0;
        end else begin
            done <= 0;
            if (start && !busy) begin
                // Load & take absolute values
                a_reg <= (dividend[WIDTH-1]) ? -dividend : dividend;
                b_reg <= (divisor[WIDTH-1])  ? -divisor  : divisor;
                sign_diff <= dividend[WIDTH-1] ^ divisor[WIDTH-1];
                acc <= 0;
                q_reg <= 0;
                count <= WIDTH;
                busy <= 1;
            end else if (busy) begin
                if (count > 0) begin
                    // Restoring division shift & subtract
                    reg [WIDTH:0] acc_next;
                    acc_next = {acc[WIDTH-1:0], a_reg[WIDTH-1]};
                    
                    if (acc_next >= {1'b0, b_reg}) begin
                        acc <= acc_next - {1'b0, b_reg};
                        q_reg <= {q_reg[WIDTH-2:0], 1'b1};
                    end else begin
                        acc <= acc_next;
                        q_reg <= {q_reg[WIDTH-2:0], 1'b0};
                    end
                    a_reg <= {a_reg[WIDTH-2:0], 1'b0};
                    count <= count - 1;
                end else begin
                    // Finish
                    quotient <= sign_diff ? -q_reg : q_reg;
                    busy <= 0;
                    done <= 1;
                end
            end
        end
    end
endmodule
