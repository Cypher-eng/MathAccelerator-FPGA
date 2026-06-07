`timescale 1ns / 1ps

module pixel_generator (
    input  wire        out_stream_aclk,     // FCLK_CLK1 (142 MHz)
    input  wire        out_stream_aresetn,
    
    // AXI-Stream interface
    output reg  [23:0] out_stream_tdata,
    output reg         out_stream_tvalid,
    input  wire        out_stream_tready,
    output reg         out_stream_tuser,    // SOF
    output reg         out_stream_tlast,    // EOL
    
    // AXI-Lite Regfile
    input  wire [31:0] reg_ZR0,
    input  wire [31:0] reg_ZI0,
    input  wire [31:0] reg_STEP,
    input  wire [31:0] reg_MAXIT
);

    // =========================================================================
    // =========================================================================
    parameter WIDTH = 64;   // 64-bit to safely hold 57-bit intermediates
    parameter SCALE = 12;   // Q12, 4096
    
    wire signed [WIDTH-1:0] ZR0   = (reg_ZR0   == 0) ? -64'd8192 : $signed({{32{reg_ZR0[31]}}, reg_ZR0});
    wire signed [WIDTH-1:0] ZI0   = (reg_ZI0   == 0) ? -64'd6144 : $signed({{32{reg_ZI0[31]}}, reg_ZI0});
    wire signed [WIDTH-1:0] STEP  = (reg_STEP  == 0) ?  64'd26   : $signed({{32{reg_STEP[31]}}, reg_STEP});
    wire [5:0]              MAXIT = (reg_MAXIT == 0) ?  6'd30    : reg_MAXIT[5:0]; // Clamped to <=63
    
    // FSM States
    localparam S_INIT = 3'd0;
    localparam S_M1   = 3'd1;
    localparam S_M2   = 3'd2;
    localparam S_M3   = 3'd3;
    localparam S_DIV  = 3'd4;
    localparam S_UPD  = 3'd5;
    localparam S_DONE = 3'd6;

    reg [2:0] state;
    
    reg [9:0] x_count;
    reg [9:0] y_count;
    wire [9:0] x_next = (x_count == 639) ? 0 : x_count + 1;
    wire [9:0] y_next = (x_count == 639) ? (y_count == 479 ? 0 : y_count + 1) : y_count;
    
    // Q12 Multiplier (Restored to 64-bit full width)
    function signed [WIDTH-1:0] q_mult;
        input signed [WIDTH-1:0] a;
        input signed [WIDTH-1:0] b;
        reg signed [2*WIDTH-1:0] full;
        begin
            full = a * b;
            q_mult = full[WIDTH+SCALE-1 : SCALE];
        end
    endfunction

    // =========================================================================
    // DATAPATH REGISTERS
    // =========================================================================
    reg signed [WIDTH-1:0] zr, zi;
    reg [5:0]              iter;
    reg [23:0]             pixel_color;
    
    // Pipeline intermediate registers
    reg signed [WIDTH-1:0] zr_sq, zi_sq, zr_zi;
    reg signed [WIDTH-1:0] zr3, zi3, fpr, fpi;
    reg signed [WIDTH-1:0] num_r, num_i, den;
    
    // Divider
    reg div_start;
    wire div_done_r, div_done_i;
    wire signed [WIDTH-1:0] quot_r, quot_i;
    
    divider_seq #( .WIDTH(WIDTH) ) u_div_r (
        .clk(out_stream_aclk), .rst(~out_stream_aresetn),
        .start(div_start), .dividend(num_r), .divisor(den),
        .quotient(quot_r), .busy(), .done(div_done_r)
    );
    
    divider_seq #( .WIDTH(WIDTH) ) u_div_i (
        .clk(out_stream_aclk), .rst(~out_stream_aresetn),
        .start(div_start), .dividend(num_i), .divisor(den),
        .quotient(quot_i), .busy(), .done(div_done_i)
    );

    wire all_div_done = div_done_r & div_done_i;

    // =========================================================================
    // FSM LOGIC
    // =========================================================================
    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            state <= S_INIT;
            x_count <= 0;
            y_count <= 0;
            out_stream_tvalid <= 0;
            div_start <= 0;
        end else begin
            case (state)
                S_INIT: begin
                    zr <= ZR0 + $signed({1'b0, x_count}) * STEP; // Safe signed cast
                    zi <= ZI0 + $signed({1'b0, y_count}) * STEP;
                    iter <= 0;
                    div_start <= 0;
                    out_stream_tvalid <= 0;
                    state <= S_M1;
                end
                
                S_M1: begin
                    zr_sq <= q_mult(zr, zr);
                    zi_sq <= q_mult(zi, zi);
                    zr_zi <= q_mult(zr, zi);
                    state <= S_M2;
                end
                
                S_M2: begin
                    // z^2 = (zr^2 - zi^2) + i(2*zr*zi)
                    fpr <= zr_sq - zi_sq; 
                    fpi <= zr_zi <<< 1;
                    
                    // z^3 = z^2 * z
                    zr3 <= q_mult(fpr, zr) - q_mult(fpi, zi);
                    zi3 <= q_mult(fpr, zi) + q_mult(fpi, zr);
                    state <= S_M3;
                end
                
                S_M3: begin
                    // denom = 3 * |z^2|^2
                    den <= 3 * (q_mult(fpr, fpr) + q_mult(fpi, fpi));
                    
                    // num = (z^3 - 1) * conj(3z^2)
                    num_r <= q_mult(zr3 - 64'd4096, fpr*3) + q_mult(zi3, fpi*3);
                    num_i <= q_mult(zi3, fpr*3) - q_mult(zr3 - 64'd4096, fpi*3);
                    
                    div_start <= 1;
                    state <= S_DIV;
                end
                
                S_DIV: begin
                    div_start <= 0;
                    // Check singularity: exactly equal to 0 matching Golden Model
                    if (den == 0) begin
                        pixel_color <= 24'h000000;
                        state <= S_DONE;
                    end else if (all_div_done) begin
                        state <= S_UPD;
                    end
                end
                
                S_UPD: begin
                    zr <= zr - quot_r;
                    zi <= zi - quot_i;
                    iter <= iter + 1;
                    
                    // Convergence Check (TOL = ~123 in Q12)
                    if (zr > 64'd3900 && zr < 64'd4300) begin
                        // Root 0: Red
                        pixel_color <= { 
                            (8'd230 * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd57  * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd70  * (8'd256 - (iter*256)/MAXIT)) >> 8 
                        };
                        state <= S_DONE;
                    end else if (zr < -64'd1800 && zi > 64'd3300) begin
                        // Root 1: Teal
                        pixel_color <= { 
                            (8'd42  * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd157 * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd143 * (8'd256 - (iter*256)/MAXIT)) >> 8 
                        };
                        state <= S_DONE;
                    end else if (zr < -64'd1800 && zi < -64'd3300) begin
                        // Root 2: Blue
                        pixel_color <= { 
                            (8'd69  * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd123 * (8'd256 - (iter*256)/MAXIT)) >> 8, 
                            (8'd157 * (8'd256 - (iter*256)/MAXIT)) >> 8 
                        };
                        state <= S_DONE;
                    end else if (iter >= MAXIT - 1) begin
                        pixel_color <= 24'h000000; // Hit limit -> Black
                        state <= S_DONE;
                    end else begin
                        state <= S_M1; // Loop back for next iteration
                    end
                end
                
                S_DONE: begin
                    out_stream_tvalid <= 1;
                    out_stream_tdata  <= pixel_color;
                    out_stream_tuser  <= (x_count == 0 && y_count == 0);
                    out_stream_tlast  <= (x_count == 639);
                    
                    if (out_stream_tready) begin
                        out_stream_tvalid <= 0;
                        x_count <= x_next;
                        y_count <= y_next;
                        state <= S_INIT;
                    end
                end
            endcase
        end
    end
endmodule
