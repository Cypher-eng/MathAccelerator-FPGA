`timescale 1ns / 1ps

module pixel_generator (
    input  wire        out_stream_aclk,     // FCLK_CLK1 (142 MHz)
    input  wire        out_stream_aresetn,
    
    // AXI-Stream interface to packer
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
    // ARCHITECTURE CONSTANTS
    // =========================================================================
    parameter WIDTH = 40;
    parameter SCALE = 12;
    parameter LANES = 4;
    
    // Default fallback values
    wire signed [WIDTH-1:0] ZR0   = (reg_ZR0   == 0) ? -40'd8192 : $signed({{8{reg_ZR0[31]}}, reg_ZR0});
    wire signed [WIDTH-1:0] ZI0   = (reg_ZI0   == 0) ? -40'd6144 : $signed({{8{reg_ZI0[31]}}, reg_ZI0});
    wire signed [WIDTH-1:0] STEP  = (reg_STEP  == 0) ?  40'd26   : $signed({{8{reg_STEP[31]}}, reg_STEP});
    wire [31:0]             MAXIT = (reg_MAXIT == 0) ?  32'd30   : reg_MAXIT;
    
    // FSM States
    localparam S_INIT = 3'd0;
    localparam S_M1   = 3'd1;
    localparam S_M2   = 3'd2;
    localparam S_M3   = 3'd3;
    localparam S_DIV  = 3'd4;
    localparam S_UPD  = 3'd5;
    localparam S_DONE = 3'd6;

    reg [2:0] state;
    
    // Screen coordinates
    reg [9:0] x_count;
    reg [9:0] y_count;
    wire [9:0] x_next = (x_count + LANES >= 640) ? 0 : x_count + LANES;
    wire [9:0] y_next = (x_count + LANES >= 640) ? (y_count == 479 ? 0 : y_count + 1) : y_count;
    
    // Q-format Multiplier Function
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
    // PER-LANE DATAPATH (Replicated 4 times)
    // =========================================================================
    reg signed [WIDTH-1:0] zr     [0:LANES-1];
    reg signed [WIDTH-1:0] zi     [0:LANES-1];
    reg [31:0]             iter   [0:LANES-1];
    reg                    converged [0:LANES-1];
    reg [23:0]             color  [0:LANES-1];
    
    // M1 Pipeline Registers
    reg signed [WIDTH-1:0] zr_sq  [0:LANES-1];
    reg signed [WIDTH-1:0] zi_sq  [0:LANES-1];
    reg signed [WIDTH-1:0] zr_zi  [0:LANES-1];
    
    // M2 Pipeline Registers
    reg signed [WIDTH-1:0] zr3    [0:LANES-1];
    reg signed [WIDTH-1:0] zi3    [0:LANES-1];
    reg signed [WIDTH-1:0] fpr    [0:LANES-1];
    reg signed [WIDTH-1:0] fpi    [0:LANES-1];
    
    // M3 / Divider Input Registers
    reg signed [WIDTH-1:0] num_r  [0:LANES-1];
    reg signed [WIDTH-1:0] num_i  [0:LANES-1];
    reg signed [WIDTH-1:0] den    [0:LANES-1];
    
    // Divider Instantiations & Wires
    reg div_start;
    wire div_done_r [0:LANES-1];
    wire div_done_i [0:LANES-1];
    wire signed [WIDTH-1:0] quot_r [0:LANES-1];
    wire signed [WIDTH-1:0] quot_i [0:LANES-1];
    
    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : lane_logic
            divider_seq #( .WIDTH(WIDTH) ) u_div_r (
                .clk(out_stream_aclk), .rst(~out_stream_aresetn),
                .start(div_start), .dividend(num_r[i]), .divisor(den[i]),
                .quotient(quot_r[i]), .busy(), .done(div_done_r[i])
            );
            
            divider_seq #( .WIDTH(WIDTH) ) u_div_i (
                .clk(out_stream_aclk), .rst(~out_stream_aresetn),
                .start(div_start), .dividend(num_i[i]), .divisor(den[i]),
                .quotient(quot_i[i]), .busy(), .done(div_done_i[i])
            );
        end
    endgenerate

    wire all_div_done = div_done_r[0] & div_done_i[0] & 
                        div_done_r[1] & div_done_i[1] & 
                        div_done_r[2] & div_done_i[2] & 
                        div_done_r[3] & div_done_i[3];

    // =========================================================================
    // FINITE STATE MACHINE
    // =========================================================================
    integer j;
    reg [2:0] read_ptr; // For pixel readout

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            state <= S_INIT;
            x_count <= 0;
            y_count <= 0;
            out_stream_tvalid <= 0;
            div_start <= 0;
            read_ptr <= 0;
        end else begin
            case (state)
                S_INIT: begin
                    for (j = 0; j < LANES; j = j + 1) begin
                        zr[j] <= ZR0 + $signed((x_count + j) * STEP);
                        zi[j] <= ZI0 + $signed(y_count * STEP);
                        iter[j] <= 0;
                        converged[j] <= 0;
                    end
                    div_start <= 0;
                    out_stream_tvalid <= 0;
                    read_ptr <= 0;
                    state <= S_M1;
                end
                
                S_M1: begin // Multiply Level 1: Squares and cross
                    for (j = 0; j < LANES; j = j + 1) begin
                        if (!converged[j]) begin
                            zr_sq[j] <= q_mult(zr[j], zr[j]);
                            zi_sq[j] <= q_mult(zi[j], zi[j]);
                            zr_zi[j] <= q_mult(zr[j], zi[j]);
                        end
                    end
                    state <= S_M2;
                end
                
                S_M2: begin // Multiply Level 2: z^3 and f'(z) base
                    for (j = 0; j < LANES; j = j + 1) begin
                        if (!converged[j]) begin
                            wire signed [WIDTH-1:0] zr2 = zr_sq[j] - zi_sq[j];
                            wire signed [WIDTH-1:0] zi2 = zr_zi[j] <<< 1;
                            
                            zr3[j] <= q_mult(zr2, zr[j]) - q_mult(zi2, zi[j]);
                            zi3[j] <= q_mult(zr2, zi[j]) + q_mult(zi2, zr[j]);
                            fpr[j] <= zr2; 
                            fpi[j] <= zi2; 
                        end
                    end
                    state <= S_M3;
                end
                
                S_M3: begin // Multiply Level 3: Denominator and Numerator latching
                    for (j = 0; j < LANES; j = j + 1) begin
                        if (!converged[j]) begin
                            // Denom = 3 * |z^2|^2
                            den[j] <= 3 * (q_mult(fpr[j], fpr[j]) + q_mult(fpi[j], fpi[j]));
                            
                            // Num = (z^3 - 1) * conj(3z^2)
                            wire signed [WIDTH-1:0] f_r = zr3[j] - 40'd4096; // -1 in Q12
                            wire signed [WIDTH-1:0] f_i = zi3[j];
                            
                            num_r[j] <= q_mult(f_r, fpr[j]*3) + q_mult(f_i, fpi[j]*3);
                            num_i[j] <= q_mult(f_i, fpr[j]*3) - q_mult(f_r, fpi[j]*3);
                        end
                    end
                    div_start <= 1; // Pulse divider
                    state <= S_DIV;
                end
                
                S_DIV: begin
                    div_start <= 0;
                    if (all_div_done) state <= S_UPD;
                end
                
                S_UPD: begin
                    reg all_done;
                    all_done = 1;
                    
                    for (j = 0; j < LANES; j = j + 1) begin
                        if (!converged[j]) begin
                            zr[j] <= zr[j] - quot_r[j];
                            zi[j] <= zi[j] - quot_i[j];
                            iter[j] <= iter[j] + 1;
                            
                            // Tolerance check (approx root proximity)
                            if (zr[j] > 40'd3900 && zr[j] < 40'd4300) begin
                                converged[j] <= 1; color[j] <= 24'hFF0000; // Root 1 Red
                            end else if (zr[j] < -40'd1800 && zi[j] > 40'd3300) begin
                                converged[j] <= 1; color[j] <= 24'h00FF00; // Root 2 Green
                            end else if (zr[j] < -40'd1800 && zi[j] < -40'd3300) begin
                                converged[j] <= 1; color[j] <= 24'h0000FF; // Root 3 Blue
                            end else if (iter[j] >= MAXIT) begin
                                converged[j] <= 1; color[j] <= 24'h000000; // Black
                            end else begin
                                all_done = 0; // At least one lane still needs iteration
                            end
                        end
                    end
                    
                    if (all_done) state <= S_DONE;
                    else state <= S_M1;
                end
                
                S_DONE: begin
                    // Stream out 4 pixels sequentially to the packer
                    out_stream_tvalid <= 1;
                    out_stream_tdata <= color[read_ptr];
                    out_stream_tuser <= (x_count == 0 && y_count == 0 && read_ptr == 0);
                    out_stream_tlast <= (x_count + read_ptr == 639);
                    
                    if (out_stream_tready) begin
                        if (read_ptr == LANES - 1) begin
                            out_stream_tvalid <= 0;
                            x_count <= x_next;
                            y_count <= y_next;
                            state <= S_INIT;
                        end else begin
                            read_ptr <= read_ptr + 1;
                        end
                    end
                end
            endcase
        end
    end
endmodule
