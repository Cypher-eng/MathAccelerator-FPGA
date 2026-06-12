`timescale 1ns / 1ps


module pixel_generator (
    input  wire        out_stream_aclk,
    input  wire        out_stream_aresetn,

    // AXI-Stream -> VDMA S2MM
    output wire [23:0] out_stream_tdata,
    output wire        out_stream_tvalid,
    input  wire        out_stream_tready,
    output wire        out_stream_tuser,    // SOF
    output wire        out_stream_tlast,    // EOL

    input  wire [31:0] reg_ZR0,
    input  wire [31:0] reg_ZI0,
    input  wire [31:0] reg_STEP,
    input  wire [31:0] reg_MAXIT
);

  
    parameter WIDTH       = 64;
    parameter SCALE       = 12;
    parameter DIV_LATENCY = 68;   

    localparam PRE_STAGES  = 15;                                     // S0..S14
    localparam POST_STAGES = 1;                                      // E1
    localparam CHUNK_SIZE  = PRE_STAGES + DIV_LATENCY + POST_STAGES; // 84
    localparam SR_DEPTH    = DIV_LATENCY;

    localparam [10:0] CHUNK11 = CHUNK_SIZE;
    localparam [18:0] CHUNK19 = CHUNK_SIZE;

    localparam HI = WIDTH + SCALE - 1;   
    localparam LO = SCALE;              

    localparam signed [WIDTH-1:0] ONE_Q = 64'sd4096;   // 1.0 in Q12

    wire signed [WIDTH-1:0] ZR0   = (reg_ZR0   == 0) ? -64'sd8192 : $signed({{32{reg_ZR0[31]}},  reg_ZR0});
    wire signed [WIDTH-1:0] ZI0   = (reg_ZI0   == 0) ? -64'sd6144 : $signed({{32{reg_ZI0[31]}},  reg_ZI0});
    wire signed [WIDTH-1:0] STEP  = (reg_STEP  == 0) ?  64'sd26   : $signed({{32{reg_STEP[31]}}, reg_STEP});
    wire [31:0]             MAXIT = (reg_MAXIT == 0) ?  32'd30    : reg_MAXIT;

  
    wire signed [23:0] STEP_S = STEP[23:0];

    wire CE = out_stream_tready;


    reg [6:0]  slot       = 7'd0;
    reg [5:0]  trip       = 6'd0;
    reg [18:0] pixel_idx  = 19'd0;

    reg [9:0]  base_x     = 10'd0;
    reg [9:0]  base_y     = 10'd0;
    reg [9:0]  inject_x_r = 10'd0;
    reg [9:0]  inject_y_r = 10'd0;

    wire [18:0] inject_idx = pixel_idx + {12'd0, slot};
    wire [9:0]  inject_x   = inject_x_r;
    wire [9:0]  inject_y   = inject_y_r;
    wire        inject_val = (inject_idx < 19'd307200);

    wire [10:0] base_x_plus_chunk = {1'b0, base_x} + CHUNK11;
    wire [10:0] base_x_wrap       = base_x_plus_chunk - 11'd640;

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
                        pixel_idx <= pixel_idx + CHUNK19;

                        if (base_x_plus_chunk >= 11'd640) begin
                            base_x     <= base_x_wrap[9:0];
                            base_y     <= base_y + 1'b1;
                            inject_x_r <= base_x_wrap[9:0];
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

    wire is_trip0 = (trip == 6'd0);

    wire                    fb_val;
    wire [18:0]             fb_idx;
    wire                    fb_eol;
    wire signed [WIDTH-1:0] fb_zr, fb_zi;
    wire [31:0]             fb_iter;
    wire                    fb_conv;
    wire [23:0]             fb_col;


    reg [PRE_STAGES-1:0]    ctx_val_v  = {PRE_STAGES{1'b0}};   
    reg [PRE_STAGES*19-1:0] ctx_idx_v  = {PRE_STAGES*19{1'b0}};
    reg [PRE_STAGES-1:0]    ctx_eol_v  = {PRE_STAGES{1'b0}};
    reg [PRE_STAGES*32-1:0] ctx_iter_v = {PRE_STAGES*32{1'b0}};
    reg [PRE_STAGES-1:0]    ctx_conv_v = {PRE_STAGES{1'b0}};
    reg [PRE_STAGES*24-1:0] ctx_col_v  = {PRE_STAGES*24{1'b0}};
    reg [PRE_STAGES-1:0]    ctx_fin_v  = {PRE_STAGES{1'b0}};

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn)
            ctx_val_v <= {PRE_STAGES{1'b0}};
        else if (CE)
            ctx_val_v <= {ctx_val_v[PRE_STAGES-2:0], (is_trip0 ? inject_val : fb_val)};
    end

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            ctx_idx_v  <= {ctx_idx_v [(PRE_STAGES-1)*19-1:0], (is_trip0 ? inject_idx            : fb_idx)};
            ctx_eol_v  <= {ctx_eol_v [PRE_STAGES-2:0],        (is_trip0 ? (inject_x == 10'd639) : fb_eol)};
            ctx_iter_v <= {ctx_iter_v[(PRE_STAGES-1)*32-1:0], (is_trip0 ? 32'd0                 : fb_iter)};
            ctx_conv_v <= {ctx_conv_v[PRE_STAGES-2:0],        (is_trip0 ? 1'b0                  : fb_conv)};
            ctx_col_v  <= {ctx_col_v [(PRE_STAGES-1)*24-1:0], (is_trip0 ? 24'd0                 : fb_col)};
            ctx_fin_v  <= {ctx_fin_v [PRE_STAGES-2:0],        (trip == MAXIT[5:0] - 1'b1)};  
        end
    end

    wire                    pre_val  = ctx_val_v [PRE_STAGES-1];
    wire [18:0]             pre_idx  = ctx_idx_v [PRE_STAGES*19-1 -: 19];
    wire                    pre_eol  = ctx_eol_v [PRE_STAGES-1];
    wire [31:0]             pre_iter = ctx_iter_v[PRE_STAGES*32-1 -: 32];
    wire                    pre_conv = ctx_conv_v[PRE_STAGES-1];
    wire [23:0]             pre_col  = ctx_col_v [PRE_STAGES*24-1 -: 24];
    wire                    pre_fin  = ctx_fin_v [PRE_STAGES-1];

  
    reg                    st0_from_new = 1'b0;
    reg [9:0]              st0_x        = 10'd0;
    reg [9:0]              st0_y        = 10'd0;
    reg signed [WIDTH-1:0] st0_fb_zr    = 64'sd0;
    reg signed [WIDTH-1:0] st0_fb_zi    = 64'sd0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            st0_from_new <= is_trip0;
            st0_x        <= inject_x;
            st0_y        <= inject_y;
            st0_fb_zr    <= fb_zr;
            st0_fb_zi    <= fb_zi;
        end
    end

 
    reg signed [34:0]      s1_xs       = 35'sd0;
    reg signed [34:0]      s1_ys       = 35'sd0;
    reg                    s1_from_new = 1'b0;
    reg signed [WIDTH-1:0] s1_fb_zr    = 64'sd0;
    reg signed [WIDTH-1:0] s1_fb_zi    = 64'sd0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s1_xs       <= $signed({1'b0, st0_x}) * STEP_S;
            s1_ys       <= $signed({1'b0, st0_y}) * STEP_S;
            s1_from_new <= st0_from_new;
            s1_fb_zr    <= st0_fb_zr;
            s1_fb_zi    <= st0_fb_zi;
        end
    end

 
    localparam ZQN = PRE_STAGES - 2;   // 13

    reg [ZQN*WIDTH-1:0] zq_zr_v = {ZQN*WIDTH{1'b0}};
    reg [ZQN*WIDTH-1:0] zq_zi_v = {ZQN*WIDTH{1'b0}};

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            zq_zr_v <= {zq_zr_v[(ZQN-1)*WIDTH-1:0],
                        (s1_from_new ? (ZR0 + {{(WIDTH-35){s1_xs[34]}}, s1_xs}) : s1_fb_zr)};
            zq_zi_v <= {zq_zi_v[(ZQN-1)*WIDTH-1:0],
                        (s1_from_new ? (ZI0 + {{(WIDTH-35){s1_ys[34]}}, s1_ys}) : s1_fb_zi)};
        end
    end

    wire signed [WIDTH-1:0] zr_s2  = $signed(zq_zr_v[WIDTH-1:0]);            
    wire signed [WIDTH-1:0] zi_s2  = $signed(zq_zi_v[WIDTH-1:0]);
    wire signed [WIDTH-1:0] zr_s6  = $signed(zq_zr_v[5*WIDTH-1 -: WIDTH]);  
    wire signed [WIDTH-1:0] zi_s6  = $signed(zq_zi_v[5*WIDTH-1 -: WIDTH]);
    wire signed [WIDTH-1:0] zr_s14 = $signed(zq_zr_v[ZQN*WIDTH-1 -: WIDTH]); 
    wire signed [WIDTH-1:0] zi_s14 = $signed(zq_zi_v[ZQN*WIDTH-1 -: WIDTH]);


    reg signed [2*WIDTH-1:0] s3_zr2 = 0, s3_zi2 = 0, s3_zrzi = 0;
    reg signed [2*WIDTH-1:0] s4_zr2 = 0, s4_zi2 = 0, s4_zrzi = 0;
    reg signed [2*WIDTH-1:0] s5_zr2 = 0, s5_zi2 = 0, s5_zrzi = 0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s3_zr2  <= zr_s2 * zr_s2;
            s3_zi2  <= zi_s2 * zi_s2;
            s3_zrzi <= zr_s2 * zi_s2;
            s4_zr2  <= s3_zr2;   s4_zi2  <= s3_zi2;   s4_zrzi <= s3_zrzi;
            s5_zr2  <= s4_zr2;   s5_zi2  <= s4_zi2;   s5_zrzi <= s4_zrzi;
        end
    end

    wire signed [WIDTH-1:0] sq_zr  = $signed(s5_zr2 [HI:LO]);
    wire signed [WIDTH-1:0] sq_zi  = $signed(s5_zi2 [HI:LO]);
    wire signed [WIDTH-1:0] m_zrzi = $signed(s5_zrzi[HI:LO]);

  
    localparam FPN = 5;

    reg [FPN*WIDTH-1:0] fp_r_v = {FPN*WIDTH{1'b0}};
    reg [FPN*WIDTH-1:0] fp_i_v = {FPN*WIDTH{1'b0}};

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            fp_r_v <= {fp_r_v[(FPN-1)*WIDTH-1:0], (sq_zr - sq_zi)};
            fp_i_v <= {fp_i_v[(FPN-1)*WIDTH-1:0], (m_zrzi <<< 1)};
        end
    end

    wire signed [WIDTH-1:0] fpr_s6  = $signed(fp_r_v[WIDTH-1:0]);             
    wire signed [WIDTH-1:0] fpi_s6  = $signed(fp_i_v[WIDTH-1:0]);
    wire signed [WIDTH-1:0] fpr_s10 = $signed(fp_r_v[FPN*WIDTH-1 -: WIDTH]); 
    wire signed [WIDTH-1:0] fpi_s10 = $signed(fp_i_v[FPN*WIDTH-1 -: WIDTH]);


    reg signed [2*WIDTH-1:0] s7_fr_zr = 0, s7_fi_zi = 0, s7_fr_zi = 0, s7_fi_zr = 0, s7_fr_fr = 0, s7_fi_fi = 0;
    reg signed [2*WIDTH-1:0] s8_fr_zr = 0, s8_fi_zi = 0, s8_fr_zi = 0, s8_fi_zr = 0, s8_fr_fr = 0, s8_fi_fi = 0;
    reg signed [2*WIDTH-1:0] s9_fr_zr = 0, s9_fi_zi = 0, s9_fr_zi = 0, s9_fi_zr = 0, s9_fr_fr = 0, s9_fi_fi = 0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s7_fr_zr <= fpr_s6 * zr_s6;
            s7_fi_zi <= fpi_s6 * zi_s6;
            s7_fr_zi <= fpr_s6 * zi_s6;
            s7_fi_zr <= fpi_s6 * zr_s6;
            s7_fr_fr <= fpr_s6 * fpr_s6;
            s7_fi_fi <= fpi_s6 * fpi_s6;

            s8_fr_zr <= s7_fr_zr; s8_fi_zi <= s7_fi_zi; s8_fr_zi <= s7_fr_zi;
            s8_fi_zr <= s7_fi_zr; s8_fr_fr <= s7_fr_fr; s8_fi_fi <= s7_fi_fi;

            s9_fr_zr <= s8_fr_zr; s9_fi_zi <= s8_fi_zi; s9_fr_zi <= s8_fr_zi;
            s9_fi_zr <= s8_fi_zr; s9_fr_fr <= s8_fr_fr; s9_fi_fi <= s8_fi_fi;
        end
    end

    wire signed [WIDTH-1:0] q_fr_zr = $signed(s9_fr_zr[HI:LO]);
    wire signed [WIDTH-1:0] q_fi_zi = $signed(s9_fi_zi[HI:LO]);
    wire signed [WIDTH-1:0] q_fr_zi = $signed(s9_fr_zi[HI:LO]);
    wire signed [WIDTH-1:0] q_fi_zr = $signed(s9_fi_zr[HI:LO]);
    wire signed [WIDTH-1:0] q_fr_fr = $signed(s9_fr_fr[HI:LO]);
    wire signed [WIDTH-1:0] q_fi_fi = $signed(s9_fi_fi[HI:LO]);


    reg signed [WIDTH-1:0] s10_zr3m1 = 64'sd0;
    reg signed [WIDTH-1:0] s10_zi3   = 64'sd0;
    reg signed [WIDTH-1:0] s10_dsum  = 64'sd0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s10_zr3m1 <= q_fr_zr - q_fi_zi - ONE_Q;
            s10_zi3   <= q_fr_zi + q_fi_zr;
            s10_dsum  <= q_fr_fr + q_fi_fi;
        end
    end


    reg signed [2*WIDTH-1:0] s11_a = 0, s11_b = 0, s11_c = 0, s11_d = 0;
    reg signed [2*WIDTH-1:0] s12_a = 0, s12_b = 0, s12_c = 0, s12_d = 0;
    reg signed [2*WIDTH-1:0] s13_a = 0, s13_b = 0, s13_c = 0, s13_d = 0;
    reg signed [WIDTH-1:0]   s11_den = 64'sd1, s12_den = 64'sd1, s13_den = 64'sd1;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s11_a   <= s10_zr3m1 * fpr_s10;
            s11_b   <= s10_zi3   * fpi_s10;
            s11_c   <= s10_zi3   * fpr_s10;
            s11_d   <= s10_zr3m1 * fpi_s10;
            s11_den <= (s10_dsum <<< 1) + s10_dsum;

            s12_a <= s11_a; s12_b <= s11_b; s12_c <= s11_c; s12_d <= s11_d;
            s12_den <= s11_den;

            s13_a <= s12_a; s13_b <= s12_b; s13_c <= s12_c; s13_d <= s12_d;
            s13_den <= s12_den;
        end
    end

    wire signed [WIDTH-1:0] q_a = $signed(s13_a[HI:LO]);
    wire signed [WIDTH-1:0] q_b = $signed(s13_b[HI:LO]);
    wire signed [WIDTH-1:0] q_c = $signed(s13_c[HI:LO]);
    wire signed [WIDTH-1:0] q_d = $signed(s13_d[HI:LO]);


    reg signed [WIDTH-1:0] s14_num_r = 64'sd0;
    reg signed [WIDTH-1:0] s14_num_i = 64'sd0;
    reg signed [WIDTH-1:0] s14_den   = 64'sd1;
    reg                    s14_black = 1'b0;

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            s14_num_r <= (q_a + q_b) <<< SCALE;
            s14_num_i <= (q_c - q_d) <<< SCALE;
            s14_den   <= s13_den;
            s14_black <= (s13_den == 64'sd0);
        end
    end

 
    wire [127:0] dout_r;
    wire [127:0] dout_i;

    div_gen_0 u_div_r (
        .aclk(out_stream_aclk),
        .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),
        .s_axis_divisor_tdata(s14_den),
        .s_axis_dividend_tvalid(1'b1),
        .s_axis_dividend_tdata(s14_num_r),
        .m_axis_dout_tvalid(),
        .m_axis_dout_tdata(dout_r)
    );

    div_gen_0 u_div_i (
        .aclk(out_stream_aclk),
        .aclken(CE),
        .s_axis_divisor_tvalid(1'b1),
        .s_axis_divisor_tdata(s14_den),
        .s_axis_dividend_tvalid(1'b1),
        .s_axis_dividend_tdata(s14_num_i),
        .m_axis_dout_tvalid(),
        .m_axis_dout_tdata(dout_i)
    );

   
    wire signed [WIDTH-1:0] quot_r = $signed(dout_r[127:64]);
    wire signed [WIDTH-1:0] quot_i = $signed(dout_i[127:64]);


    reg [SR_DEPTH-1:0]    sr_val_v = {SR_DEPTH{1'b0}};
    reg [SR_DEPTH*19-1:0] sr_idx_v = {SR_DEPTH*19{1'b0}};
    reg [SR_DEPTH-1:0]    sr_eol_v = {SR_DEPTH{1'b0}};
    reg [SR_DEPTH-1:0]    sr_fin_v = {SR_DEPTH{1'b0}};
    reg [SR_DEPTH*WIDTH-1:0] sr_zr_v = {SR_DEPTH*WIDTH{1'b0}};
    reg [SR_DEPTH*WIDTH-1:0] sr_zi_v = {SR_DEPTH*WIDTH{1'b0}};
    reg [SR_DEPTH*32-1:0] sr_iter_v = {SR_DEPTH*32{1'b0}};
    reg [SR_DEPTH-1:0]    sr_conv_v = {SR_DEPTH{1'b0}};
    reg [SR_DEPTH*24-1:0] sr_col_v  = {SR_DEPTH*24{1'b0}};
    reg [SR_DEPTH-1:0]    sr_blk_v  = {SR_DEPTH{1'b0}};

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn)
            sr_val_v <= {SR_DEPTH{1'b0}};
        else if (CE)
            sr_val_v <= {sr_val_v[SR_DEPTH-2:0], pre_val};
    end

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            sr_idx_v  <= {sr_idx_v [(SR_DEPTH-1)*19-1:0],    pre_idx};
            sr_eol_v  <= {sr_eol_v [SR_DEPTH-2:0],           pre_eol};
            sr_fin_v  <= {sr_fin_v [SR_DEPTH-2:0],           pre_fin};
            sr_zr_v   <= {sr_zr_v  [(SR_DEPTH-1)*WIDTH-1:0], zr_s14};
            sr_zi_v   <= {sr_zi_v  [(SR_DEPTH-1)*WIDTH-1:0], zi_s14};
            sr_iter_v <= {sr_iter_v[(SR_DEPTH-1)*32-1:0],    pre_iter};
            sr_conv_v <= {sr_conv_v[SR_DEPTH-2:0],           pre_conv};
            sr_col_v  <= {sr_col_v [(SR_DEPTH-1)*24-1:0],    pre_col};
            sr_blk_v  <= {sr_blk_v [SR_DEPTH-2:0],           s14_black};
        end
    end

    wire                    end_val  = sr_val_v [SR_DEPTH-1];
    wire [18:0]             end_idx  = sr_idx_v [SR_DEPTH*19-1 -: 19];
    wire                    end_eol  = sr_eol_v [SR_DEPTH-1];
    wire                    end_fin  = sr_fin_v [SR_DEPTH-1];
    wire signed [WIDTH-1:0] end_zr   = $signed(sr_zr_v[SR_DEPTH*WIDTH-1 -: WIDTH]);
    wire signed [WIDTH-1:0] end_zi   = $signed(sr_zi_v[SR_DEPTH*WIDTH-1 -: WIDTH]);
    wire [31:0]             end_iter = sr_iter_v[SR_DEPTH*32-1 -: 32];
    wire                    end_conv = sr_conv_v[SR_DEPTH-1];
    wire [23:0]             end_col  = sr_col_v [SR_DEPTH*24-1 -: 24];
    wire                    end_blk  = sr_blk_v [SR_DEPTH-1];

 
    reg                    e1_val   = 1'b0;
    reg                    e1_fin   = 1'b0;
    reg [18:0]             e1_idx   = 19'd0;
    reg                    e1_eol   = 1'b0;
    reg signed [WIDTH-1:0] e1_zr    = 64'sd0;
    reg signed [WIDTH-1:0] e1_zi    = 64'sd0;
    reg [31:0]             e1_iter  = 32'd0;
    reg                    e1_conv0 = 1'b0;
    reg [23:0]             e1_col0  = 24'd0;
    reg                    e1_blk   = 1'b0;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn)
            e1_val <= 1'b0;
        else if (CE)
            e1_val <= end_val;
    end

    always @(posedge out_stream_aclk) begin
        if (CE) begin
            e1_fin   <= end_fin;
            e1_idx   <= end_idx;
            e1_eol   <= end_eol;
            e1_iter  <= end_conv ? end_iter : (end_iter + 32'd1);
            e1_zr    <= end_conv ? end_zr   : (end_zr - quot_r);
            e1_zi    <= end_conv ? end_zi   : (end_zi - quot_i);
            e1_conv0 <= end_conv;
            e1_col0  <= end_col;
            e1_blk   <= end_blk;
        end
    end


    wire in_r1 = (e1_zr >  64'sd3900) && (e1_zr <  64'sd4300);
    wire in_r2 = (e1_zr < -64'sd1800) && (e1_zi >  64'sd3300);
    wire in_r3 = (e1_zr < -64'sd1800) && (e1_zi < -64'sd3300);

    wire        just_conv = (!e1_conv0) && (e1_blk || in_r1 || in_r2 || in_r3);
    wire [23:0] win_col   = e1_blk ? 24'h000000 :
                            in_r1  ? 24'hE63946 :
                            in_r2  ? 24'h2A9D8F :
                            in_r3  ? 24'h457B9D : 24'h000000;

    assign fb_val  = e1_val;
    assign fb_idx  = e1_idx;
    assign fb_eol  = e1_eol;
    assign fb_conv = e1_conv0 || just_conv;
    assign fb_col  = e1_conv0 ? e1_col0 : (just_conv ? win_col : 24'd0);
    assign fb_zr   = e1_zr;
    assign fb_zi   = e1_zi;
    assign fb_iter = e1_iter;

    wire emit = e1_val && e1_fin;

    reg [23:0] axis_tdata_r  = 24'd0;
    reg        axis_tvalid_r = 1'b0;
    reg        axis_tuser_r  = 1'b0;
    reg        axis_tlast_r  = 1'b0;

    always @(posedge out_stream_aclk) begin
        if (!out_stream_aresetn)
            axis_tvalid_r <= 1'b0;
        else if (CE)
            axis_tvalid_r <= emit;
    end

    always @(posedge out_stream_aclk) begin
        if (CE && emit) begin
            axis_tdata_r <= fb_conv ? fb_col : 24'h000000;
            axis_tuser_r <= (e1_idx == 19'd0);
            axis_tlast_r <= e1_eol;
        end
    end

    assign out_stream_tvalid = axis_tvalid_r;
    assign out_stream_tdata  = axis_tdata_r;
    assign out_stream_tuser  = axis_tuser_r;
    assign out_stream_tlast  = axis_tlast_r;

endmodule

