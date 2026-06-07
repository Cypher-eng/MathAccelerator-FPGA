`timescale 1ns / 1ps

module pixel_generator (
    input  wire        out_stream_aclk,
    input  wire        out_stream_aresetn,
    
    // AXI-Stream interface to packer
    output reg  [23:0] out_stream_tdata,
    output reg         out_stream_tvalid,
    input  wire        out_stream_tready,
    output reg         out_stream_tuser,    // SOF (Start of Frame)
    output reg         out_stream_tlast,    // EOL (End of Line)
    
    // AXI-Lite Regfile
    input  wire [31:0] reg_ZR0,
    input  wire [31:0] reg_ZI0,
    input  wire [31:0] reg_STEP,
    input  wire [31:0] reg_MAXIT
);

    // =========================================================================
    // ARCHITECTURE CONSTANTS
    // =========================================================================
    parameter WIDTH = 64;
    parameter SCALE = 12;
    parameter DIV_LATENCY = 68; // 严格匹配你 div_gen_0 的 Latency
    
    // Sign-extended default fallbacks
    wire signed [WIDTH-1:0] ZR0   = (reg_ZR0   == 0) ? -64'd8192 : $signed({{32{reg_ZR0[31]}}, reg_ZR0});
    wire signed [WIDTH-1:0] ZI0   = (reg_ZI0   == 0) ? -64'd6144 : $signed({{32{reg_ZI0[31]}}, reg_ZI0});
    wire signed [WIDTH-1:0] STEP  = (reg_STEP  == 0) ?  64'd26   : $signed({{32{reg_STEP[31]}}, reg_STEP});
    wire [31:0]             MAXIT = (reg_MAXIT == 0) ?  32'd30   : reg_MAXIT;
    
    wire CE = out_stream_tready;

    // Q12 Multiplier (64-bit safe)
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
    // INJECTOR STAGE: Frame & Slot Management
    // =========================================================================
    reg [9:0] next_x, next_y;
    reg eof_reached;
    
    wire fb_valid;
    wire fb_converged;
    wire fb_is_eof_pixel = (fb_x == 639 && fb_y == 479);
    
    // Slot is empty if pipeline bubble OR pixel successfully converged/outputted
    wire slot_empty = !fb_valid || fb_converged;
    wire actual_insert = slot_empty && !eof_reached;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            next_x <= 0; next_y <= 0; eof_reached <= 0;
        end else if (CE) begin
            if (eof_reached && fb_is_eof_pixel && out_stream_tvalid) begin
                eof_reached <= 0; // Reset frame
            end else if (actual_insert) begin
                if (next_x == 639 && next_y == 479) begin
                    eof_reached <= 1;
                    next_x <= 0; next_y <= 0;
                end else if (next_x == 639) begin
                    next_x <= 0; next_y <= next_y + 1;
                end else begin
                    next_x <= next_x + 1;
                end
            end
        end
    end

    // =========================================================================
    // STAGE 0: Context Multiplexer (New Pixel vs Looping Pixel)
    // =========================================================================
    reg st0_valid; reg [9:0] st0_x, st0_y; reg signed [WIDTH-1:0] st0_zr, st0_zi; reg [31:0] st0_iter;
    
    wire [9:0] fb_x, fb_y;
    wire signed [WIDTH-1:0] fb_zr, fb_zi;
    wire [31:0] fb_iter;

    always @(posedge out_stream_aclk) if(CE) begin
        if (!out_stream_aresetn) st0_valid <= 0;
        else st0_valid <= actual_insert ? 1'b1 : (fb_valid && !fb_converged);
        
        st0_x     <= actual_insert ? next_x : fb_x;
        st0_y     <= actual_insert ? next_y : fb_y;
        st0_zr    <= actual_insert ? (ZR0 + $signed({1'b0, next_x}) * STEP) : fb_zr;
        st0_zi    <= actual_insert ? (ZI0 + $signed({1'b0, next_y}) * STEP) : fb_zi;
        st0_iter  <= actual_insert ? 0 : fb_iter;
    end

    // =========================================================================
    // STAGE 1: Multiplier Level 1
    // =========================================================================
    reg st1_valid; reg [9:0] st1_x, st1_y; reg signed [WIDTH-1:0] st1_zr, st1_zi; reg [31:0] st1_iter;
    reg signed [WIDTH-1:0] m1_zr_sq, m1_zi_sq, m1_zr_zi;

    always @(posedge out_stream_aclk) if(CE) begin
        st1_valid <= st0_valid; st1_x <= st0_x; st1_y <= st0_y; st1_zr <= st0_zr; st1_zi <= st0_zi; st1_iter <= st0_iter;
        m1_zr_sq <= q_mult(st0_zr, st0_zr);
        m1_zi_sq <= q_mult(st0_zi, st0_zi);
        m1_zr_zi <= q_mult(st0_zr, st0_zi);
    end

    // =========================================================================
    // STAGE 2: Multiplier Level 2
    // =========================================================================
    reg st2_valid; reg [9:0] st2_x, st2_y; reg signed [WIDTH-1:0] st2_zr, st2_zi; reg [31:0] st2_iter;
    reg signed [WIDTH-1:0] m2_zr3, m2_zi3, m2_fpr, m2_fpi;

    always @(posedge out_stream_aclk) if(CE) begin
        st2_valid <= st1_valid; st2_x <= st1_x; st2_y <= st1_y; st2_zr <= st1_zr; st2_zi <= st1_zi; st2_iter <= st1_iter;
        m2_fpr <= m1_zr_sq - m1_zi_sq;
        m2_fpi <= m1_zr_zi <<< 1;
        m2_zr3 <= q_mult(m1_zr_sq - m1_zi_sq, st1_zr) - q_mult(m1_zr_zi <<< 1, st1_zi);
        m2_zi3 <= q_mult(m1_zr_sq - m1_zi_sq, st1_zi) + q_mult(m1_zr_zi <<< 1, st1_zr);
    end

    // =========================================================================
    // STAGE 3: Multiplier Level 3 & Divider Latch
    // =========================================================================
    reg st3_valid; reg [9:0] st3_x, st3_y; reg signed [WIDTH-1:0] st3_zr, st3_zi; reg [31:0] st3_iter;
    reg signed [WIDTH-1:0] m3_num_r, m3_num_i, m3_den;
    reg st3_black;

    always @(posedge out_stream_aclk) if(CE) begin
        st3_valid <= st2_valid; st3_x <= st2_x; st3_y <= st2_y; st3_zr <= st2_zr; st3_zi <= st2_zi; st3_iter <= st2_iter;
        m3_den   <= 3 * (q_mult(m2_fpr, m2_fpr) + q_mult(m2_fpi, m2_fpi));
        
        // 关键：左移 SCALE 保留 Q12 除法精度
        m3_num_r <= (q_mult(m2_zr3 - 64'd4096, m2_fpr * 3) + q_mult(m2_zi3, m2_fpi * 3)) <<< SCALE;
        m3_num_i <= (q_mult(m2_zi3, m2_fpr * 3) - q_mult(m2_zr3 - 64'd4096, m2_fpi * 3)) <<< SCALE;
        
        // 奇点检查
        st3_black <= (3 * (q_mult(m2_fpr, m2_fpr) + q_mult(m2_fpi, m2_fpi)) == 0);
    end

    // =========================================================================
    // STAGE 4 to N: Divider IPs & Context Shift Register 
    // =========================================================================
    wire [127:0] dout_r, dout_i;
    
    div_gen_0 u_div_r (
        .aclk(out_stream_aclk),  .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),       .s_axis_divisor_tdata(m3_den),
        .s_axis_dividend_tvalid(1'b1),      .s_axis_dividend_tdata(m3_num_r),
        .m_axis_dout_tvalid(),              .m_axis_dout_tdata(dout_r)
    );
    
    div_gen_0 u_div_i (
        .aclk(out_stream_aclk),  .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),       .s_axis_divisor_tdata(m3_den),
        .s_axis_dividend_tvalid(1'b1),      .s_axis_dividend_tdata(m3_num_i),
        .m_axis_dout_tvalid(),              .m_axis_dout_tdata(dout_i)
    );

    // Parallel Shift Register array to carry pixel context alongside the IP
    reg sr_valid [0:DIV_LATENCY-1]; 
    reg [9:0] sr_x [0:DIV_LATENCY-1]; reg [9:0] sr_y [0:DIV_LATENCY-1];
    reg signed [WIDTH-1:0] sr_zr [0:DIV_LATENCY-1]; reg signed [WIDTH-1:0] sr_zi [0:DIV_LATENCY-1];
    reg [31:0] sr_iter [0:DIV_LATENCY-1]; reg sr_black [0:DIV_LATENCY-1];
    
    integer i;
    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            for (i=0; i<DIV_LATENCY; i=i+1) sr_valid[i] <= 0;
        end else if(CE) begin
            sr_valid[0] <= st3_valid; sr_x[0] <= st3_x; sr_y[0] <= st3_y;
            sr_zr[0] <= st3_zr; sr_zi[0] <= st3_zi; sr_iter[0] <= st3_iter; sr_black[0] <= st3_black;
            
            for (i=1; i<DIV_LATENCY; i=i+1) begin
                sr_valid[i] <= sr_valid[i-1]; sr_x[i] <= sr_x[i-1]; sr_y[i] <= sr_y[i-1];
                sr_zr[i] <= sr_zr[i-1]; sr_zi[i] <= sr_zi[i-1]; sr_iter[i] <= sr_iter[i-1]; sr_black[i] <= sr_black[i-1];
            end
        end
    end

    // =========================================================================
    // END OF PIPELINE: Output & Convergence Evaluation
    // =========================================================================
    // 64-bit divisor means quotient is on the lower 64 bits [63:0]
    wire signed [63:0] quot_r = dout_r[63:0]; 
    wire signed [63:0] quot_i = dout_i[63:0];
    
    wire out_valid = sr_valid[DIV_LATENCY-1];
    wire out_black = sr_black[DIV_LATENCY-1];
    
    wire signed [WIDTH-1:0] new_zr = sr_zr[DIV_LATENCY-1] - quot_r;
    wire signed [WIDTH-1:0] new_zi = sr_zi[DIV_LATENCY-1] - quot_i;
    wire [31:0]             new_iter = sr_iter[DIV_LATENCY-1] + 1;

    // Golden Model Shading Logic
    wire [31:0] shade256 = 32'd256 - (new_iter * 32'd256) / MAXIT;
    wire [31:0] shade_clamp = (shade256 < 64) ? 64 : shade256;
    
    reg is_converged;
    reg [23:0] final_color;
    
    always @(*) begin
        if (out_black || new_iter >= MAXIT) begin
            is_converged = 1; final_color = 24'h000000;
        end else if (new_zr > 64'd3900 && new_zr < 64'd4300) begin
            is_converged = 1; final_color = { (8'd230 * shade_clamp) >> 8, (8'd57 * shade_clamp) >> 8, (8'd70 * shade_clamp) >> 8 };
        end else if (new_zr < -64'd1800 && new_zi > 64'd3300) begin
            is_converged = 1; final_color = { (8'd42 * shade_clamp) >> 8, (8'd157 * shade_clamp) >> 8, (8'd143 * shade_clamp) >> 8 };
        end else if (new_zr < -64'd1800 && new_zi < -64'd3300) begin
            is_converged = 1; final_color = { (8'd69 * shade_clamp) >> 8, (8'd123 * shade_clamp) >> 8, (8'd157 * shade_clamp) >> 8 };
        end else begin
            is_converged = 0; final_color = 24'h000000;
        end
    end

    // Loopback to Injector / Forward to AXIS
    assign fb_valid     = out_valid;
    assign fb_converged = is_converged;
    assign fb_zr        = new_zr;
    assign fb_zi        = new_zi;
    assign fb_iter      = new_iter;
    assign fb_x         = sr_x[DIV_LATENCY-1];
    assign fb_y         = sr_y[DIV_LATENCY-1];

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn) begin
            out_stream_tvalid <= 0;
        end else if (CE) begin
            out_stream_tvalid <= (out_valid && is_converged);
            out_stream_tdata  <= final_color;
            out_stream_tuser  <= (fb_x == 0 && fb_y == 0);
            out_stream_tlast  <= (fb_x == 639);
        end
    end

endmodule
