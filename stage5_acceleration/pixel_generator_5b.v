`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pixel_generator_5b.v  -  Stage 5B: ACCELERATED, board-interface Newton engine.
//
// f(z) = z^3 - 1 ,  Newton:  z <- z - (z^3 - 1)/(3 z^2)
//
// This is the MERGED Stage 5 deliverable. It keeps the exact board-interface of
// the verified Stage 4 design (full AXI-Lite register file + AXI-Stream/packer
// output, driven with periph_resetn held low during MMIO configuration) and
// adds the Stage 5B acceleration: LANES independent Newton engines running in
// parallel. Pixels are partitioned by residue class (lane g handles pixel
// indices p with p % LANES == g); an output FSM emits them round-robin to keep
// the raster scan order the packer expects. Throughput rises ~LANES x, measured
// in iverilog as cycles/frame, and every configuration is verified bit-exact
// against the Q12 Python golden model.
//
// It also exposes a Stage 5A instrumentation port (debug_iter / debug_iter_valid)
// so the same engine produces the pre-acceleration iteration histogram.
//
// The complementary FMAX lever - a pipelined multi-cycle divider that shortens
// the long combinational divide critical path so the clock can run faster - is
// delivered as a separate, separately-verified module (divider_seq.v) and is
// confirmed with Vivado timing in Stage 6, because iverilog cannot measure Fmax.
//
// Register map (unchanged from Stage 4):
//   regfile[0]=ZR0 (Q12 pan x)  regfile[1]=ZI0 (Q12 pan y)
//   regfile[2]=STEP (Q12 zoom)   regfile[3]=MAXIT (1..63)
// An all-zero register falls back to the Stage 3 default, so the default image
// is bit-identical to Stages 3 and 4.
//////////////////////////////////////////////////////////////////////////////////

module pixel_generator(
input           out_stream_aclk,
input           s_axi_lite_aclk,
input           axi_resetn,
input           periph_resetn,

//Stream output
output [31:0]   out_stream_tdata,
output [3:0]    out_stream_tkeep,
output          out_stream_tlast,
input           out_stream_tready,
output          out_stream_tvalid,
output [0:0]    out_stream_tuser,

// ---- Stage 5A instrumentation (simulation only; ignored by synthesis tools
//      that don't connect it). Exposes the iteration count of the pixel being
//      emitted this cycle, so the benchmark testbench can build a histogram. ----
output [5:0]    debug_iter,
output          debug_iter_valid,

//AXI-Lite S
input [AXI_LITE_ADDR_WIDTH-1:0]     s_axi_lite_araddr,
output          s_axi_lite_arready,
input           s_axi_lite_arvalid,

input [AXI_LITE_ADDR_WIDTH-1:0]     s_axi_lite_awaddr,
output          s_axi_lite_awready,
input           s_axi_lite_awvalid,

input           s_axi_lite_bready,
output [1:0]    s_axi_lite_bresp,
output          s_axi_lite_bvalid,

output [31:0]   s_axi_lite_rdata,
input           s_axi_lite_rready,
output [1:0]    s_axi_lite_rresp,
output          s_axi_lite_rvalid,

input  [31:0]   s_axi_lite_wdata,
output          s_axi_lite_wready,
input           s_axi_lite_wvalid

);

localparam X_SIZE = 640;
localparam Y_SIZE = 480;
parameter  LANES  = 1;             // number of parallel Newton engines
parameter  REG_FILE_SIZE = 8;
localparam REG_FILE_AWIDTH = $clog2(REG_FILE_SIZE);
parameter  AXI_LITE_ADDR_WIDTH = 8;

localparam AWAIT_WADD_AND_DATA = 3'b000;
localparam AWAIT_WDATA = 3'b001;
localparam AWAIT_WADD = 3'b010;
localparam AWAIT_WRITE = 3'b100;
localparam AWAIT_RESP = 3'b101;

localparam AWAIT_RADD = 2'b00;
localparam AWAIT_FETCH = 2'b01;
localparam AWAIT_READ = 2'b10;

localparam AXI_OK = 2'b00;
localparam AXI_ERR = 2'b10;

reg [31:0]                          regfile [REG_FILE_SIZE-1:0];
reg [REG_FILE_AWIDTH-1:0]           writeAddr, readAddr;
reg [31:0]                          readData, writeData;
reg [1:0]                           readState = AWAIT_RADD;
reg [2:0]                           writeState = AWAIT_WADD_AND_DATA;

//Read from the register file
always @(posedge s_axi_lite_aclk) begin
    readData <= regfile[readAddr];
    if (!axi_resetn) begin
        readState <= AWAIT_RADD;
    end
    else case (readState)
        AWAIT_RADD: begin
            if (s_axi_lite_arvalid) begin
                readAddr <= s_axi_lite_araddr[2+:REG_FILE_AWIDTH];
                readState <= AWAIT_FETCH;
            end
        end
        AWAIT_FETCH: readState <= AWAIT_READ;
        AWAIT_READ: if (s_axi_lite_rready) readState <= AWAIT_RADD;
        default: readState <= AWAIT_RADD;
    endcase
end

assign s_axi_lite_arready = (readState == AWAIT_RADD);
assign s_axi_lite_rresp = (readAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;
assign s_axi_lite_rvalid = (readState == AWAIT_READ);
assign s_axi_lite_rdata = readData;

//Write to the register file
always @(posedge s_axi_lite_aclk) begin
    if (!axi_resetn) begin
        writeState <= AWAIT_WADD_AND_DATA;
    end
    else case (writeState)
        AWAIT_WADD_AND_DATA: begin
            case ({s_axi_lite_awvalid, s_axi_lite_wvalid})
                2'b10: begin
                    writeAddr <= s_axi_lite_awaddr[2+:REG_FILE_AWIDTH];
                    writeState <= AWAIT_WDATA;
                end
                2'b01: begin
                    writeData <= s_axi_lite_wdata;
                    writeState <= AWAIT_WADD;
                end
                2'b11: begin
                    writeData <= s_axi_lite_wdata;
                    writeAddr <= s_axi_lite_awaddr[2+:REG_FILE_AWIDTH];
                    writeState <= AWAIT_WRITE;
                end
                default: writeState <= AWAIT_WADD_AND_DATA;
            endcase
        end
        AWAIT_WDATA: if (s_axi_lite_wvalid) begin
            writeData <= s_axi_lite_wdata;
            writeState <= AWAIT_WRITE;
        end
        AWAIT_WADD: if (s_axi_lite_awvalid) begin
            writeAddr <= s_axi_lite_awaddr[2+:REG_FILE_AWIDTH];
            writeState <= AWAIT_WRITE;
        end
        AWAIT_WRITE: begin
            regfile[writeAddr] <= writeData;
            writeState <= AWAIT_RESP;
        end
        AWAIT_RESP: if (s_axi_lite_bready) writeState <= AWAIT_WADD_AND_DATA;
        default: writeState <= AWAIT_WADD_AND_DATA;
    endcase
end

assign s_axi_lite_awready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WADD);
assign s_axi_lite_wready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WDATA);
assign s_axi_lite_bvalid = (writeState == AWAIT_RESP);
assign s_axi_lite_bresp = (writeAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;

// =====================================================================
//             PARALLEL NEWTON FRACTAL PIXEL ENGINE (LANES wide)
// =====================================================================

localparam signed [31:0] SCALE = 4096;          // Q12
localparam signed [31:0] TOL   = 123;           // 0.03 in Q12

localparam integer       DEF_MAXIT = 30;
localparam signed [31:0] DEF_STEP  = 26;
localparam signed [31:0] DEF_ZR0   = -8192;
localparam signed [31:0] DEF_ZI0   = -6144;

localparam signed [31:0] ROOT0R = 4096,  ROOT0I = 0;
localparam signed [31:0] ROOT1R = -2048, ROOT1I = 3547;
localparam signed [31:0] ROOT2R = -2048, ROOT2I = -3547;

// ---- Live parameters resolved from the register file (same as Stage 4) ----
wire signed [31:0] reg_zr0   = regfile[0];
wire signed [31:0] reg_zi0   = regfile[1];
wire signed [31:0] reg_step  = regfile[2];
wire        [31:0] reg_maxit = regfile[3];

wire signed [31:0] ZR0  = (reg_zr0  == 32'sd0) ? DEF_ZR0  : reg_zr0;
wire signed [31:0] ZI0  = (reg_zi0  == 32'sd0) ? DEF_ZI0  : reg_zi0;
wire signed [31:0] STEP = (reg_step == 32'sd0) ? DEF_STEP : reg_step;
wire        [5:0]  MAX_ITER = (reg_maxit == 32'd0) ? DEF_MAXIT[5:0]
                            : (reg_maxit > 32'd63) ? 6'd63 : reg_maxit[5:0];

// ---- Per-lane state ----
localparam S_INIT = 2'd0;
localparam S_ITER = 2'd1;
localparam S_DONE = 2'd2;

reg  signed [63:0] zr   [0:LANES-1];
reg  signed [63:0] zi   [0:LANES-1];
reg  [5:0]         iter [0:LANES-1];
reg  [1:0]         ridx [0:LANES-1];
reg  [1:0]         lst  [0:LANES-1];   // lane state
reg  [9:0]         lx   [0:LANES-1];   // pixel x of this lane's current pixel
reg  [8:0]         ly   [0:LANES-1];   // pixel y

// ---- Output (emit) FSM: round-robin over lanes, preserves raster order ----
reg  [$clog2(LANES)-1:0] emit_lane = 0;

wire        ready;                          // from packer (= in_stream_ready)
wire        valid_int = (lst[emit_lane] == S_DONE);   // emitted pixel ready?
wire        consume   = ready & valid_int;            // packer takes it now

wire [9:0]  emit_x = lx[emit_lane];
wire [8:0]  emit_y = ly[emit_lane];
wire        sof_emit = (emit_x == 0) & (emit_y == 0);
wire        eol_emit = (emit_x == X_SIZE - 1);
wire        is_last  = (emit_x == X_SIZE - 1) & (emit_y == Y_SIZE - 1);
wire        frame_restart = consume & is_last;

// advance[g] : lane g's current pixel was just consumed -> move to next pixel
wire [LANES-1:0] advance;
genvar gi;
generate
  for (gi = 0; gi < LANES; gi = gi + 1) begin : adv
    assign advance[gi] = consume & (emit_lane == gi) & ~frame_restart;
  end
endgenerate

// emit_lane sequencing
always @(posedge out_stream_aclk) begin
    if (!periph_resetn || frame_restart) begin
        emit_lane <= 0;
    end else if (consume) begin
        emit_lane <= (emit_lane == LANES-1) ? 0 : emit_lane + 1;
    end
end

// ---- Per-lane Newton datapath + FSM (generate) ----
genvar g;
generate
  for (g = 0; g < LANES; g = g + 1) begin : lane
    // combinational Newton step on this lane's (zr[g], zi[g])
    wire signed [63:0] zr2 = (zr[g]*zr[g])/SCALE - (zi[g]*zi[g])/SCALE;
    wire signed [63:0] zi2 = (2*zr[g]*zi[g])/SCALE;
    wire signed [63:0] zr3 = (zr2*zr[g])/SCALE - (zi2*zi[g])/SCALE;
    wire signed [63:0] zi3 = (zr2*zi[g])/SCALE + (zi2*zr[g])/SCALE;
    wire signed [63:0] fr  = zr3 - SCALE;
    wire signed [63:0] fi  = zi3;
    wire signed [63:0] fpr = 3*zr2;
    wire signed [63:0] fpi = 3*zi2;
    wire signed [63:0] denom = (fpr*fpr)/SCALE + (fpi*fpi)/SCALE;
    wire signed [63:0] numr  = (fr*fpr)/SCALE + (fi*fpi)/SCALE;
    wire signed [63:0] numi  = (fi*fpr)/SCALE - (fr*fpi)/SCALE;
    wire signed [63:0] dr = (denom == 0) ? 64'sd0 : (numr*SCALE)/denom;
    wire signed [63:0] di = (denom == 0) ? 64'sd0 : (numi*SCALE)/denom;
    wire signed [63:0] zr_n = zr[g] - dr;
    wire signed [63:0] zi_n = zi[g] - di;

    wire c0 = (zr_n-ROOT0R < TOL)&&(zr_n-ROOT0R > -TOL)&&(zi_n-ROOT0I < TOL)&&(zi_n-ROOT0I > -TOL);
    wire c1 = (zr_n-ROOT1R < TOL)&&(zr_n-ROOT1R > -TOL)&&(zi_n-ROOT1I < TOL)&&(zi_n-ROOT1I > -TOL);
    wire c2 = (zr_n-ROOT2R < TOL)&&(zr_n-ROOT2R > -TOL)&&(zi_n-ROOT2I < TOL)&&(zi_n-ROOT2I > -TOL);
    wire anyc = c0|c1|c2;

    // next-pixel coordinates for this lane (advance by LANES, single row-wrap)
    wire [10:0] nx = lx[g] + LANES;
    wire        wrap = (nx >= X_SIZE);

    always @(posedge out_stream_aclk) begin
        if (!periph_resetn || frame_restart) begin
            // start of frame: lane g owns pixel index g
            lx[g]   <= g[9:0];
            ly[g]   <= 9'd0;
            iter[g] <= 0;
            ridx[g] <= 2'd3;
            lst[g]  <= S_INIT;
        end else begin
            case (lst[g])
                S_INIT: begin
                    zr[g]   <= ZR0 + $signed({1'b0, lx[g]}) * STEP;
                    zi[g]   <= ZI0 + $signed({1'b0, ly[g]}) * STEP;
                    iter[g] <= 0;
                    ridx[g] <= 2'd3;
                    lst[g]  <= S_ITER;
                end
                S_ITER: begin
                    if (denom == 0) begin
                        ridx[g] <= 2'd3;
                        lst[g]  <= S_DONE;
                    end else if (anyc) begin
                        ridx[g] <= c0 ? 2'd0 : (c1 ? 2'd1 : 2'd2);
                        lst[g]  <= S_DONE;
                    end else if (iter[g] == MAX_ITER-1) begin
                        ridx[g] <= 2'd3;
                        lst[g]  <= S_DONE;
                    end else begin
                        zr[g]   <= zr_n;
                        zi[g]   <= zi_n;
                        iter[g] <= iter[g] + 1;
                        lst[g]  <= S_ITER;
                    end
                end
                S_DONE: begin
                    if (advance[g]) begin
                        // move to this lane's next residue-class pixel
                        if (wrap) begin
                            lx[g] <= nx - X_SIZE;
                            ly[g] <= ly[g] + 9'd1;
                        end else begin
                            lx[g] <= nx[9:0];
                        end
                        lst[g] <= S_INIT;
                    end
                end
            endcase
        end
    end
  end
endgenerate

// ---- Colour of the emitted pixel (combinational mux over lanes) ----
wire [1:0] e_ridx = ridx[emit_lane];
wire [5:0] e_iter = iter[emit_lane];
wire [8:0] shade = (256 - (e_iter*256)/MAX_ITER < 64) ? 9'd64
                                                      : (256 - (e_iter*256)/MAX_ITER);
reg [7:0] cr, cg, cb;
always @(*) begin
    case (e_ridx)
        2'd0: begin cr = 8'd230; cg = 8'd57;  cb = 8'd70;  end
        2'd1: begin cr = 8'd42;  cg = 8'd157; cb = 8'd143; end
        2'd2: begin cr = 8'd69;  cg = 8'd123; cb = 8'd157; end
        default: begin cr = 8'd0; cg = 8'd0; cb = 8'd0; end
    endcase
end
wire [16:0] rprod = cr * shade;
wire [16:0] gprod = cg * shade;
wire [16:0] bprod = cb * shade;
wire [7:0] r = (e_ridx == 2'd3) ? 8'd0 : rprod[15:8];
wire [7:0] g_o = (e_ridx == 2'd3) ? 8'd0 : gprod[15:8];
wire [7:0] b = (e_ridx == 2'd3) ? 8'd0 : bprod[15:8];

// Stage 5A histogram probe: emit the iteration count whenever a pixel is taken.
assign debug_iter       = e_iter;
assign debug_iter_valid = consume;

packer pixel_packer(.aclk(out_stream_aclk),
                    .aresetn(periph_resetn),
                    .r(r), .g(g_o), .b(b),
                    .eol(eol_emit), .in_stream_ready(ready), .valid(valid_int), .sof(sof_emit),
                    .out_stream_tdata(out_stream_tdata), .out_stream_tkeep(out_stream_tkeep),
                    .out_stream_tlast(out_stream_tlast), .out_stream_tready(out_stream_tready),
                    .out_stream_tvalid(out_stream_tvalid), .out_stream_tuser(out_stream_tuser) );

endmodule
