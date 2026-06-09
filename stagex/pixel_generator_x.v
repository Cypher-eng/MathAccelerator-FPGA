`timescale 1ns / 1ps

module pixel_generator (
    input  wire        out_stream_aclk,
    input  wire        out_stream_aresetn,

    // AXI-Stream interface to VDMA
    output wire [23:0] out_stream_tdata,
    output wire        out_stream_tvalid,
    input  wire        out_stream_tready,
    output wire        out_stream_tuser,    // SOF
    output wire        out_stream_tlast,    // EOL

    // AXI-Lite Regfile / BD constants
    input  wire [31:0] reg_ZR0,
    input  wire [31:0] reg_ZI0,
    input  wire [31:0] reg_STEP,
    input  wire [31:0] reg_MAXIT
);

    // =========================================================================
    // Architecture constants
    // =========================================================================
    parameter WIDTH = 64;
    parameter SCALE = 12;
    parameter DIV_LATENCY = 68;
    parameter CHUNK_SIZE = DIV_LATENCY + 4; // 72

    wire signed [WIDTH-1:0] ZR0   = (reg_ZR0   == 0) ? -64'sd8192 : $signed({{32{reg_ZR0[31]}}, reg_ZR0});
    wire signed [WIDTH-1:0] ZI0   = (reg_ZI0   == 0) ? -64'sd6144 : $signed({{32{reg_ZI0[31]}}, reg_ZI0});
    wire signed [WIDTH-1:0] STEP  = (reg_STEP  == 0) ?  64'sd26   : $signed({{32{reg_STEP[31]}}, reg_STEP});
    wire [31:0]             MAXIT = (reg_MAXIT == 0) ?  32'd30    : reg_MAXIT;

    wire CE = out_stream_tready;

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
    // Batch controller
    // No modulo/divide for x/y. Use registered coordinate counters.
    // =========================================================================
    reg [6:0]  slot;
    reg [5:0]  trip;
    reg [18:0] pixel_idx;

    reg [9:0] base_x;
    reg [9:0] base_y;
    reg [9:0] inject_x_r;
    reg [9:0] inject_y_r;

    wire [18:0] inject_idx = pixel_idx + slot;
    wire [9:0]  inject_x   = inject_x_r;
    wire [9:0]  inject_y   = inject_y_r;
    wire        inject_val = (inject_idx < 19'd307200);

    wire [10:0] base_x_plus_chunk = {1'b0, base_x} + 11'd72;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            slot       <= 7'd0;
            trip       <= 6'd0;
            pixel_idx  <= 19'd0;

            base_x     <= 10'd0;
            base_y     <= 10'd0;
            inject_x_r <= 10'd0;
            inject_y_r <= 10'd0;
        end else if (CE) begin
            if (slot == CHUNK_SIZE - 1) begin
                slot <= 7'd0;

                if (trip >= MAXIT[5:0] - 1'b1) begin
                    trip <= 6'd0;

                    if (pixel_idx + CHUNK_SIZE >= 19'd307200) begin
                        pixel_idx  <= 19'd0;
                        base_x     <= 10'd0;
                        base_y     <= 10'd0;
                        inject_x_r <= 10'd0;
                        inject_y_r <= 10'd0;
                    end else begin
                        pixel_idx <= pixel_idx + CHUNK_SIZE;

                        if (base_x_plus_chunk >= 11'd640) begin
                            base_x     <= base_x_plus_chunk - 11'd640;
                            base_y     <= base_y + 1'b1;
                            inject_x_r <= base_x_plus_chunk - 11'd640;
                            inject_y_r <= base_y + 1'b1;
                        end else begin
                            base_x     <= base_x_plus_chunk[9:0];
                            base_y     <= base_y;
                            inject_x_r <= base_x_plus_chunk[9:0];
                            inject_y_r <= base_y;
                        end
                    end
                end else begin
                    trip       <= trip + 1'b1;
                    inject_x_r <= base_x;
                    inject_y_r <= base_y;
                end
            end else begin
                slot <= slot + 1'b1;

                if (inject_x_r == 10'd639) begin
                    inject_x_r <= 10'd0;
                    inject_y_r <= inject_y_r + 1'b1;
                end else begin
                    inject_x_r <= inject_x_r + 1'b1;
                    inject_y_r <= inject_y_r;
                end
            end
        end
    end

    // =========================================================================
    // Feedback wires
    // =========================================================================
    wire        fb_val;
    wire [18:0] fb_idx;
    wire signed [WIDTH-1:0] fb_zr, fb_zi;
    wire [31:0] fb_iter;
    wire        fb_conv;
    wire [23:0] fb_col;

    wire is_trip0 = (trip == 6'd0);

    // =========================================================================
    // STAGE 0: select new pixel or feedback pixel only
    // No heavy arithmetic here.
    // =========================================================================
    reg        st0_val;
    reg [18:0] st0_idx;
    reg [9:0]  st0_x;
    reg [9:0]  st0_y;
    reg        st0_from_new;

    reg signed [WIDTH-1:0] st0_fb_zr;
    reg signed [WIDTH-1:0] st0_fb_zi;
    reg [31:0] st0_iter;
    reg        st0_conv;
    reg [23:0] st0_col;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            st0_val      <= 1'b0;
            st0_idx      <= 19'd0;
            st0_x        <= 10'd0;
            st0_y        <= 10'd0;
            st0_from_new <= 1'b0;

            st0_fb_zr    <= 64'sd0;
            st0_fb_zi    <= 64'sd0;
            st0_iter     <= 32'd0;
            st0_conv     <= 1'b0;
            st0_col      <= 24'd0;
        end else if (CE) begin
            st0_val      <= is_trip0 ? inject_val : fb_val;
            st0_idx      <= is_trip0 ? inject_idx : fb_idx;
            st0_x        <= inject_x;
            st0_y        <= inject_y;
            st0_from_new <= is_trip0;

            st0_fb_zr    <= fb_zr;
            st0_fb_zi    <= fb_zi;
            st0_iter     <= is_trip0 ? 32'd0 : fb_iter;
            st0_conv     <= is_trip0 ? 1'b0 : fb_conv;
            st0_col      <= is_trip0 ? 24'd0 : fb_col;
        end
    end

    // =========================================================================
    // STAGE 1: compute zr/zi only, registered
    // This breaks slot/x/y -> multiplier timing path.
    // =========================================================================
    reg        st1_val;
    reg [18:0] st1_idx;
    reg signed [WIDTH-1:0] st1_zr;
    reg signed [WIDTH-1:0] st1_zi;
    reg [31:0] st1_iter;
    reg        st1_conv;
    reg [23:0] st1_col;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            st1_val  <= 1'b0;
            st1_idx  <= 19'd0;
            st1_zr   <= 64'sd0;
            st1_zi   <= 64'sd0;
            st1_iter <= 32'd0;
            st1_conv <= 1'b0;
            st1_col  <= 24'd0;
        end else if (CE) begin
            st1_val  <= st0_val;
            st1_idx  <= st0_idx;

            st1_zr   <= st0_from_new ? (ZR0 + $signed({54'd0, st0_x}) * STEP) : st0_fb_zr;
            st1_zi   <= st0_from_new ? (ZI0 + $signed({54'd0, st0_y}) * STEP) : st0_fb_zi;

            st1_iter <= st0_iter;
            st1_conv <= st0_conv;
            st1_col  <= st0_col;
        end
    end

    // =========================================================================
    // STAGE 2: multiplier tree
    // =========================================================================
    reg        st2_val;
    reg [18:0] st2_idx;
    reg signed [WIDTH-1:0] st2_zr;
    reg signed [WIDTH-1:0] st2_zi;
    reg [31:0] st2_iter;
    reg        st2_conv;
    reg [23:0] st2_col;

    reg signed [WIDTH-1:0] m1_zr_sq;
    reg signed [WIDTH-1:0] m1_zi_sq;
    reg signed [WIDTH-1:0] m1_zr_zi;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            st2_val   <= 1'b0;
            st2_idx   <= 19'd0;
            st2_zr    <= 64'sd0;
            st2_zi    <= 64'sd0;
            st2_iter  <= 32'd0;
            st2_conv  <= 1'b0;
            st2_col   <= 24'd0;

            m1_zr_sq  <= 64'sd0;
            m1_zi_sq  <= 64'sd0;
            m1_zr_zi  <= 64'sd0;
        end else if (CE) begin
            st2_val   <= st1_val;
            st2_idx   <= st1_idx;
            st2_zr    <= st1_zr;
            st2_zi    <= st1_zi;
            st2_iter  <= st1_iter;
            st2_conv  <= st1_conv;
            st2_col   <= st1_col;

            m1_zr_sq  <= q_mult(st1_zr, st1_zr);
            m1_zi_sq  <= q_mult(st1_zi, st1_zi);
            m1_zr_zi  <= q_mult(st1_zr, st1_zi);
        end
    end

    // =========================================================================
    // STAGE 3: cubic and derivative terms
    // =========================================================================
    reg        st3_val;
    reg [18:0] st3_idx;
    reg signed [WIDTH-1:0] st3_zr;
    reg signed [WIDTH-1:0] st3_zi;
    reg [31:0] st3_iter;
    reg        st3_conv;
    reg [23:0] st3_col;

    reg signed [WIDTH-1:0] m2_zr3;
    reg signed [WIDTH-1:0] m2_zi3;
    reg signed [WIDTH-1:0] m2_fpr;
    reg signed [WIDTH-1:0] m2_fpi;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            st3_val  <= 1'b0;
            st3_idx  <= 19'd0;
            st3_zr   <= 64'sd0;
            st3_zi   <= 64'sd0;
            st3_iter <= 32'd0;
            st3_conv <= 1'b0;
            st3_col  <= 24'd0;

            m2_zr3   <= 64'sd0;
            m2_zi3   <= 64'sd0;
            m2_fpr   <= 64'sd0;
            m2_fpi   <= 64'sd0;
        end else if (CE) begin
            st3_val  <= st2_val;
            st3_idx  <= st2_idx;
            st3_zr   <= st2_zr;
            st3_zi   <= st2_zi;
            st3_iter <= st2_iter;
            st3_conv <= st2_conv;
            st3_col  <= st2_col;

            m2_fpr <= m1_zr_sq - m1_zi_sq;
            m2_fpi <= m1_zr_zi <<< 1;

            m2_zr3 <= q_mult(m1_zr_sq - m1_zi_sq, st2_zr)
                    - q_mult(m1_zr_zi <<< 1, st2_zi);

            m2_zi3 <= q_mult(m1_zr_sq - m1_zi_sq, st2_zi)
                    + q_mult(m1_zr_zi <<< 1, st2_zr);
        end
    end

    // =========================================================================
    // STAGE 4: divider inputs
    // =========================================================================
    reg        st4_val;
    reg [18:0] st4_idx;
    reg signed [WIDTH-1:0] st4_zr;
    reg signed [WIDTH-1:0] st4_zi;
    reg [31:0] st4_iter;
    reg        st4_conv;
    reg [23:0] st4_col;

    reg signed [WIDTH-1:0] m3_num_r;
    reg signed [WIDTH-1:0] m3_num_i;
    reg signed [WIDTH-1:0] m3_den;
    reg m3_black;

    wire signed [WIDTH-1:0] fpr3 = m2_fpr * 3;
    wire signed [WIDTH-1:0] fpi3 = m2_fpi * 3;
    wire signed [WIDTH-1:0] den_calc = 3 * (q_mult(m2_fpr, m2_fpr) + q_mult(m2_fpi, m2_fpi));

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            st4_val   <= 1'b0;
            st4_idx   <= 19'd0;
            st4_zr    <= 64'sd0;
            st4_zi    <= 64'sd0;
            st4_iter  <= 32'd0;
            st4_conv  <= 1'b0;
            st4_col   <= 24'd0;

            m3_num_r  <= 64'sd0;
            m3_num_i  <= 64'sd0;
            m3_den    <= 64'sd1;
            m3_black  <= 1'b0;
        end else if (CE) begin
            st4_val   <= st3_val;
            st4_idx   <= st3_idx;
            st4_zr    <= st3_zr;
            st4_zi    <= st3_zi;
            st4_iter  <= st3_iter;
            st4_conv  <= st3_conv;
            st4_col   <= st3_col;

            m3_den    <= den_calc;
            m3_num_r  <= (q_mult(m2_zr3 - 64'sd4096, fpr3) + q_mult(m2_zi3, fpi3)) <<< SCALE;
            m3_num_i  <= (q_mult(m2_zi3, fpr3) - q_mult(m2_zr3 - 64'sd4096, fpi3)) <<< SCALE;
            m3_black  <= (den_calc == 64'sd0);
        end
    end

    // =========================================================================
    // Divider IP
    // =========================================================================
    wire [127:0] dout_r;
    wire [127:0] dout_i;

    div_gen_0 u_div_r (
        .aclk(out_stream_aclk),
        .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),
        .s_axis_divisor_tdata(m3_den),
        .s_axis_dividend_tvalid(1'b1),
        .s_axis_dividend_tdata(m3_num_r),
        .m_axis_dout_tvalid(),
        .m_axis_dout_tdata(dout_r)
    );

    div_gen_0 u_div_i (
        .aclk(out_stream_aclk),
        .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),
        .s_axis_divisor_tdata(m3_den),
        .s_axis_dividend_tvalid(1'b1),
        .s_axis_dividend_tdata(m3_num_i),
        .m_axis_dout_tvalid(),
        .m_axis_dout_tdata(dout_i)
    );

    // =========================================================================
    // Context shift register
    // Because we inserted one extra stage before divider,
    // context still follows divider input m3_* from STAGE 4.
    // =========================================================================
    localparam SR_DEPTH = DIV_LATENCY;

    reg        sr_val  [0:SR_DEPTH-1];
    reg [18:0] sr_idx  [0:SR_DEPTH-1];
    reg signed [WIDTH-1:0] sr_zr [0:SR_DEPTH-1];
    reg signed [WIDTH-1:0] sr_zi [0:SR_DEPTH-1];
    reg [31:0] sr_iter [0:SR_DEPTH-1];
    reg        sr_conv [0:SR_DEPTH-1];
    reg [23:0] sr_col  [0:SR_DEPTH-1];
    reg        sr_blk  [0:SR_DEPTH-1];

    integer i;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            for (i = 0; i < SR_DEPTH; i = i + 1) begin
                sr_val[i]  <= 1'b0;
                sr_idx[i]  <= 19'd0;
                sr_zr[i]   <= 64'sd0;
                sr_zi[i]   <= 64'sd0;
                sr_iter[i] <= 32'd0;
                sr_conv[i] <= 1'b0;
                sr_col[i]  <= 24'd0;
                sr_blk[i]  <= 1'b0;
            end
        end else if (CE) begin
            sr_val[0]  <= st4_val;
            sr_idx[0]  <= st4_idx;
            sr_zr[0]   <= st4_zr;
            sr_zi[0]   <= st4_zi;
            sr_iter[0] <= st4_iter;
            sr_conv[0] <= st4_conv;
            sr_col[0]  <= st4_col;
            sr_blk[0]  <= m3_black;

            for (i = 1; i < SR_DEPTH; i = i + 1) begin
                sr_val[i]  <= sr_val[i-1];
                sr_idx[i]  <= sr_idx[i-1];
                sr_zr[i]   <= sr_zr[i-1];
                sr_zi[i]   <= sr_zi[i-1];
                sr_iter[i] <= sr_iter[i-1];
                sr_conv[i] <= sr_conv[i-1];
                sr_col[i]  <= sr_col[i-1];
                sr_blk[i]  <= sr_blk[i-1];
            end
        end
    end

    // =========================================================================
    // END OF PIPELINE
    // =========================================================================
    wire        end_val  = sr_val[SR_DEPTH-1];
    wire [18:0] end_idx  = sr_idx[SR_DEPTH-1];
    wire signed [WIDTH-1:0] end_zr = sr_zr[SR_DEPTH-1];
    wire signed [WIDTH-1:0] end_zi = sr_zi[SR_DEPTH-1];
    wire [31:0] end_iter = sr_iter[SR_DEPTH-1];
    wire        end_conv = sr_conv[SR_DEPTH-1];
    wire [23:0] end_col  = sr_col[SR_DEPTH-1];
    wire        end_blk  = sr_blk[SR_DEPTH-1];

    wire signed [63:0] quot_r = dout_r[63:0];
    wire signed [63:0] quot_i = dout_i[63:0];

    wire signed [63:0] calc_zr = end_zr - quot_r;
    wire signed [63:0] calc_zi = end_zi - quot_i;
    wire [31:0]        calc_iter = end_iter + 1'b1;

    // =========================================================================
    // Fast colour path
    // =========================================================================
    reg        is_just_converged;
    reg [23:0] calc_col;

    always @(*) begin
        is_just_converged = 1'b0;
        calc_col = 24'h000000;

        if (end_blk) begin
            is_just_converged = 1'b1;
            calc_col = 24'h000000;
        end else if (calc_zr > 64'sd3900 && calc_zr < 64'sd4300) begin
            is_just_converged = 1'b1;
            calc_col = 24'hE63946;
        end else if (calc_zr < -64'sd1800 && calc_zi > 64'sd3300) begin
            is_just_converged = 1'b1;
            calc_col = 24'h2A9D8F;
        end else if (calc_zr < -64'sd1800 && calc_zi < -64'sd3300) begin
            is_just_converged = 1'b1;
            calc_col = 24'h457B9D;
        end
    end

    // =========================================================================
    // Feedback state
    // =========================================================================
    assign fb_val  = end_val;
    assign fb_idx  = end_idx;
    assign fb_conv = end_conv || is_just_converged;
    assign fb_col  = end_conv ? end_col : (is_just_converged ? calc_col : 24'd0);
    assign fb_zr   = end_conv ? end_zr : calc_zr;
    assign fb_zi   = end_conv ? end_zi : calc_zi;
    assign fb_iter = end_conv ? end_iter : calc_iter;

    // =========================================================================
    // Registered AXI-Stream output
    // =========================================================================
    reg [23:0] axis_tdata_r;
    reg        axis_tvalid_r;
    reg        axis_tuser_r;
    reg        axis_tlast_r;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            axis_tdata_r  <= 24'd0;
            axis_tvalid_r <= 1'b0;
            axis_tuser_r  <= 1'b0;
            axis_tlast_r  <= 1'b0;
        end else if (CE) begin
            axis_tvalid_r <= (trip == 6'd0) && end_val;
            axis_tdata_r  <= fb_conv ? fb_col : 24'h000000;
            axis_tuser_r  <= (end_idx == 19'd0);
            axis_tlast_r  <= (end_idx[9:0] == 10'd639);
        end
    end

    assign out_stream_tvalid = axis_tvalid_r;
    assign out_stream_tdata  = axis_tdata_r;
    assign out_stream_tuser  = axis_tuser_r;
    assign out_stream_tlast  = axis_tlast_r;

endmodule
