`timescale 1ns / 1ps
// ============================================================================
// divider_seq.v  -  multi-cycle signed restoring divider (truncates toward 0).
//
// WHY THIS EXISTS (the Fmax lever for Stage 5/6):
// In Stages 3-5 the Newton step uses Verilog's combinational '/'. A ~57-bit by
// ~41-bit combinational divide is an enormous logic cone and it sets the
// maximum clock frequency (Fmax) of the whole design -- the single longest
// path. This module computes the SAME result (bit-for-bit) but spreads it over
// WIDTH+1 clock cycles, so each cycle's logic is tiny and the clock can run
// much faster. The trade is latency-per-divide for clock speed; with the
// parallel lanes of Stage 5 hiding that latency, the net board effect is higher
// throughput AND higher Fmax. iverilog cannot measure Fmax, so here we verify
// only that the result is numerically identical to '/'. The Fmax gain itself is
// confirmed with Vivado timing in Stage 6.
//
// Semantics: quotient = trunc(numer / denom) toward zero, exactly like Verilog
// signed '/' and like the Python golden model's tdiv(). denom must be non-zero
// (the engine already guards denom==0 as the singularity case).
//
// Handshake: pulse `start` for one cycle with numer/denom valid; `busy` is high
// while computing; `done` pulses for one cycle when `quot` is valid.
// ============================================================================
module divider_seq #(
    parameter WIDTH = 64
)(
    input                         clk,
    input                         rstn,
    input                         start,
    input  signed [WIDTH-1:0]     numer,
    input  signed [WIDTH-1:0]     denom,    // assumed non-zero
    output reg signed [WIDTH-1:0] quot,
    output reg                    done,
    output                        busy
);
    localparam IDLE = 2'd0, RUN = 2'd1, FIN = 2'd2;
    reg [1:0] state = IDLE;

    reg [WIDTH-1:0] absN, absD, q;
    reg [WIDTH:0]   rem;
    reg [$clog2(WIDTH+1)-1:0] cnt;
    reg             qsign;

    assign busy = (state != IDLE);

    wire [$clog2(WIDTH)-1:0] bidx = (WIDTH-1) - cnt;          // MSB-first bit index
    wire [WIDTH:0] rem_shift = {rem[WIDTH-1:0], absN[bidx]};  // bring down one bit
    wire           ge = (rem_shift >= {1'b0, absD});

    always @(posedge clk) begin
        if (!rstn) begin
            state <= IDLE; done <= 1'b0; quot <= 0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    absN  <= numer[WIDTH-1] ? (~numer + 1'b1) : numer;
                    absD  <= denom[WIDTH-1] ? (~denom + 1'b1) : denom;
                    qsign <= numer[WIDTH-1] ^ denom[WIDTH-1];
                    rem   <= 0;  q <= 0;  cnt <= 0;
                    state <= RUN;
                end
                RUN: begin
                    if (ge) begin
                        rem      <= rem_shift - {1'b0, absD};
                        q[bidx]  <= 1'b1;
                    end else begin
                        rem      <= rem_shift;
                    end
                    if (cnt == WIDTH-1) state <= FIN;
                    else                cnt   <= cnt + 1'b1;
                end
                FIN: begin
                    quot  <= qsign ? (~q + 1'b1) : q;   // apply sign (trunc toward 0)
                    done  <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
