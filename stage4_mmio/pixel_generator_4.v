module pixel_generator_4 #(
    parameter WIDTH = 48,
    parameter HEIGHT = 36
)(
    input  wire clk,
    input  wire rst,
    input  wire ready,

    input  wire signed [31:0] cfg_zr0,
    input  wire signed [31:0] cfg_zi0,
    input  wire signed [31:0] cfg_step,
    input  wire [31:0] cfg_maxit,

    output reg valid,
    output reg [7:0] r,
    output reg [7:0] g,
    output reg [7:0] b,
    output reg done
);

localparam signed [63:0] SCALE = 64'sd4096;
localparam signed [63:0] TOL = 64'sd123;

localparam signed [63:0] R0R = 64'sd4096;
localparam signed [63:0] R0I = 64'sd0;
localparam signed [63:0] R1R = -64'sd2048;
localparam signed [63:0] R1I = 64'sd3547;
localparam signed [63:0] R2R = -64'sd2048;
localparam signed [63:0] R2I = -64'sd3547;

localparam [1:0] S_INIT = 2'd0;
localparam [1:0] S_ITER = 2'd1;
localparam [1:0] S_DONE = 2'd2;

reg [1:0] state;
reg [15:0] x;
reg [15:0] y;
reg [5:0] iter;
reg signed [63:0] zr;
reg signed [63:0] zi;

wire regs_zero = (cfg_zr0 == 0) && (cfg_zi0 == 0) && (cfg_step == 0) && (cfg_maxit == 0);
wire signed [63:0] zr0_use = regs_zero ? -64'sd8192 : {{32{cfg_zr0[31]}}, cfg_zr0};
wire signed [63:0] zi0_use = regs_zero ? -64'sd6144 : {{32{cfg_zi0[31]}}, cfg_zi0};
wire signed [63:0] step_use = regs_zero ? 64'sd26 : {{32{cfg_step[31]}}, cfg_step};
wire [5:0] maxit_use = regs_zero ? 6'd30 : ((cfg_maxit[5:0] == 0) ? 6'd30 : cfg_maxit[5:0]);

function signed [63:0] tdiv64;
    input signed [127:0] a;
    input signed [63:0] d;
    reg sgn;
    reg [127:0] aa;
    reg [63:0] dd;
    reg [127:0] q;
    begin
        sgn = a[127] ^ d[63];
        aa = a[127] ? -a : a;
        dd = d[63] ? -d : d;
        q = aa / dd;
        tdiv64 = sgn ? -$signed(q[63:0]) : $signed(q[63:0]);
    end
endfunction

function signed [63:0] q12_from_q24;
    input signed [127:0] a;
    begin
        q12_from_q24 = tdiv64(a, SCALE);
    end
endfunction

function [1:0] conv_root;
    input signed [63:0] ar;
    input signed [63:0] ai;
    reg signed [63:0] dr;
    reg signed [63:0] di;
    reg signed [127:0] dist2;
    begin
        conv_root = 2'd3;

        dr = ar - R0R;
        di = ai - R0I;
        dist2 = $signed(dr) * $signed(dr) + $signed(di) * $signed(di);
        if (dist2 <= TOL * TOL)
            conv_root = 2'd0;

        dr = ar - R1R;
        di = ai - R1I;
        dist2 = $signed(dr) * $signed(dr) + $signed(di) * $signed(di);
        if (dist2 <= TOL * TOL)
            conv_root = 2'd1;

        dr = ar - R2R;
        di = ai - R2I;
        dist2 = $signed(dr) * $signed(dr) + $signed(di) * $signed(di);
        if (dist2 <= TOL * TOL)
            conv_root = 2'd2;
    end
endfunction

task set_colour;
    input [1:0] rid;
    input [5:0] it;
    reg [15:0] shade;
    reg [15:0] cr;
    reg [15:0] cg;
    reg [15:0] cb;
    begin
        if (rid == 2'd3) begin
            r <= 8'd0;
            g <= 8'd0;
            b <= 8'd0;
        end else begin
            shade = 16'd256 - ((it * 16'd256) / maxit_use);
            if (shade < 16'd64)
                shade = 16'd64;

            if (rid == 2'd0) begin
                cr = 16'd230; cg = 16'd57; cb = 16'd70;
            end else if (rid == 2'd1) begin
                cr = 16'd42; cg = 16'd157; cb = 16'd143;
            end else begin
                cr = 16'd69; cg = 16'd123; cb = 16'd157;
            end

            r <= (cr * shade) >> 8;
            g <= (cg * shade) >> 8;
            b <= (cb * shade) >> 8;
        end
    end
endtask

reg signed [63:0] zr2;
reg signed [63:0] zi2;
reg signed [63:0] zr3;
reg signed [63:0] zi3;
reg signed [63:0] fr;
reg signed [63:0] fi;
reg signed [63:0] fpr;
reg signed [63:0] fpi;
reg signed [127:0] denom;
reg signed [127:0] numr;
reg signed [127:0] numi;
reg signed [63:0] dzr;
reg signed [63:0] dzi;
reg signed [63:0] nzr;
reg signed [63:0] nzi;
reg [1:0] rid;

always @(posedge clk) begin
    if (rst) begin
        state <= S_INIT;
        x <= 0;
        y <= 0;
        iter <= 0;
        valid <= 0;
        done <= 0;
        r <= 0;
        g <= 0;
        b <= 0;
        zr <= 0;
        zi <= 0;
    end else begin
        case (state)
            S_INIT: begin
                valid <= 0;
                zr <= zr0_use + $signed({1'b0, x}) * step_use;
                zi <= zi0_use + $signed({1'b0, y}) * step_use;
                iter <= 0;
                state <= S_ITER;
            end

            S_ITER: begin
                zr2 = q12_from_q24($signed(zr) * $signed(zr) - $signed(zi) * $signed(zi));
                zi2 = tdiv64(2 * $signed(zr) * $signed(zi), SCALE);

                zr3 = q12_from_q24($signed(zr2) * $signed(zr) - $signed(zi2) * $signed(zi));
                zi3 = q12_from_q24($signed(zr2) * $signed(zi) + $signed(zi2) * $signed(zr));

                fr = zr3 - SCALE;
                fi = zi3;
                fpr = 3 * zr2;
                fpi = 3 * zi2;

                denom = $signed(fpr) * $signed(fpr) + $signed(fpi) * $signed(fpi);

                if (denom == 0) begin
                    set_colour(2'd3, iter);
                    valid <= 1;
                    state <= S_DONE;
                end else begin
                    numr = $signed(fr) * $signed(fpr) + $signed(fi) * $signed(fpi);
                    numi = $signed(fi) * $signed(fpr) - $signed(fr) * $signed(fpi);

                    dzr = tdiv64(numr * SCALE, denom[63:0]);
                    dzi = tdiv64(numi * SCALE, denom[63:0]);

                    nzr = zr - dzr;
                    nzi = zi - dzi;
                    rid = conv_root(nzr, nzi);

                    if (rid != 2'd3) begin
                        set_colour(rid, iter);
                        valid <= 1;
                        state <= S_DONE;
                    end else if (iter == maxit_use - 1) begin
                        set_colour(2'd3, iter);
                        valid <= 1;
                        state <= S_DONE;
                    end else begin
                        zr <= nzr;
                        zi <= nzi;
                        iter <= iter + 1;
                    end
                end
            end

            S_DONE: begin
                valid <= 1;
                if (ready) begin
                    valid <= 0;

                    if (x == WIDTH - 1) begin
                        x <= 0;
                        if (y == HEIGHT - 1) begin
                            y <= 0;
                            done <= 1;
                        end else begin
                            y <= y + 1;
                        end
                    end else begin
                        x <= x + 1;
                    end

                    state <= S_INIT;
                end
            end

            default: begin
                state <= S_INIT;
            end
        endcase
    end
end

endmodule
