`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pixel_generator.v  -  Stage 3: Newton fractal, single-pixel state machine.
//
// f(z) = z^3 - 1 ,  Newton:  z <- z - (z^3 - 1)/(3 z^2)
//
// All arithmetic is Q12 fixed point (SCALE = 4096). The AXI-Lite register
// file and the packer instantiation are UNCHANGED from the example. Only the
// pixel-producing logic is replaced with a state machine, because each Newton
// pixel takes many clock cycles instead of one.
//
// Constants come from the Stage 2 golden model (newton_fixed.py) so this
// produces a bit-for-bit identical image.
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
//                    NEWTON FRACTAL PIXEL ENGINE
// =====================================================================

// ---- Fixed-point + algorithm constants (from newton_fixed.py) -------
localparam signed [31:0] SCALE    = 4096;          // Q12
localparam integer       MAX_ITER = 30;
localparam signed [31:0] TOL      = 123;           // 0.03 in Q12
localparam signed [31:0] DRE      = 26;            // Q12 real step per x
localparam signed [31:0] DIM      = 26;            // Q12 imag step per y
localparam signed [31:0] ZR0      = -8192;         // Q12 real at x=0 (-2.0)
localparam signed [31:0] ZI0      = -6144;         // Q12 imag at y=0 (-1.5)

// Three roots of z^3 = 1, in Q12
localparam signed [31:0] ROOT0R = 4096,  ROOT0I = 0;       //  1.0 + 0i
localparam signed [31:0] ROOT1R = -2048, ROOT1I = 3547;    // -0.5 + 0.866i
localparam signed [31:0] ROOT2R = -2048, ROOT2I = -3547;   // -0.5 - 0.866i

// ---- Pixel coordinate counters --------------------------------------
reg [9:0] x;
reg [8:0] y;
wire first = (x == 0) & (y == 0);
wire lastx = (x == X_SIZE - 1);
wire lasty = (y == Y_SIZE - 1);

// ---- State machine --------------------------------------------------
localparam S_INIT = 2'd0;   // load z0 for the current pixel
localparam S_ITER = 2'd1;   // perform Newton iterations
localparam S_DONE = 2'd2;   // hold final colour, wait for packer handshake
reg [1:0] state = S_INIT;

// Wide signed registers. We measured the products need ~57 bits, so use 64.
reg  signed [63:0] zr, zi;          // current z (Q12)
reg  [5:0]         iter;            // iteration counter (0..MAX_ITER)
reg  [1:0]         root_idx;        // 0,1,2 = converged root; 3 = none
reg  [7:0]         pr, pg, pb;      // final pixel colour

// Combinational Newton step on the current (zr,zi) -------------------
wire signed [63:0] zr2 = (zr*zr)/SCALE - (zi*zi)/SCALE;       // Re(z^2)
wire signed [63:0] zi2 = (2*zr*zi)/SCALE;                     // Im(z^2)
wire signed [63:0] zr3 = (zr2*zr)/SCALE - (zi2*zi)/SCALE;     // Re(z^3)
wire signed [63:0] zi3 = (zr2*zi)/SCALE + (zi2*zr)/SCALE;     // Im(z^3)
wire signed [63:0] fr  = zr3 - SCALE;                         // Re(f)
wire signed [63:0] fi  = zi3;                                 // Im(f)
wire signed [63:0] fpr = 3*zr2;                               // Re(f')
wire signed [63:0] fpi = 3*zi2;                               // Im(f')
wire signed [63:0] denom = (fpr*fpr)/SCALE + (fpi*fpi)/SCALE; // |f'|^2
wire signed [63:0] numr  = (fr*fpr)/SCALE + (fi*fpi)/SCALE;   // Re(f*conj(f'))
wire signed [63:0] numi  = (fi*fpr)/SCALE - (fr*fpi)/SCALE;   // Im(f*conj(f'))
// f/f' in Q12.  Guard denom==0 (singularity near z=0).
wire signed [63:0] dr = (denom == 0) ? 64'sd0 : (numr*SCALE)/denom;
wire signed [63:0] di = (denom == 0) ? 64'sd0 : (numi*SCALE)/denom;
wire signed [63:0] zr_next = zr - dr;
wire signed [63:0] zi_next = zi - di;

// Convergence test of zr_next/zi_next against the three roots
function is_close;
    input signed [63:0] a, b, rr, ri;
    begin
        is_close = ((a - rr <  TOL) && (a - rr > -TOL) &&
                    (b - ri <  TOL) && (b - ri > -TOL));
    end
endfunction
wire conv0 = is_close(zr_next, zi_next, ROOT0R, ROOT0I);
wire conv1 = is_close(zr_next, zi_next, ROOT1R, ROOT1I);
wire conv2 = is_close(zr_next, zi_next, ROOT2R, ROOT2I);
wire any_conv = conv0 | conv1 | conv2;

// Integer shade in [64..256], matching newton_fixed.py
wire [8:0] shade = (256 - (iter*256)/MAX_ITER < 64) ? 9'd64
                                                    : (256 - (iter*256)/MAX_ITER);

wire ready;
wire valid_int = (state == S_DONE);

// ---- The state machine + pixel advance ------------------------------
always @(posedge out_stream_aclk) begin
    if (!periph_resetn) begin
        x <= 0; y <= 0;
        state <= S_INIT;
    end else begin
        case (state)
            S_INIT: begin
                zr <= ZR0 + $signed({1'b0, x}) * DRE;  // complex coordinate of this pixel
                zi <= ZI0 + $signed({1'b0, y}) * DIM;  // ($signed keeps x,y from making the expr unsigned)
                iter <= 0;
                root_idx <= 2'd3;        // 3 = "no root yet"
                state <= S_ITER;
            end

            S_ITER: begin
                if (denom == 0) begin
                    // singularity: f'(z)=0 -> non-converging (black)
                    root_idx <= 2'd3;
                    state <= S_DONE;
                end else if (any_conv) begin
                    root_idx <= conv0 ? 2'd0 : (conv1 ? 2'd1 : 2'd2);
                    state <= S_DONE;
                end else if (iter == MAX_ITER-1) begin
                    root_idx <= 2'd3;    // ran out of iterations -> black
                    state <= S_DONE;
                end else begin
                    zr <= zr_next;
                    zi <= zi_next;
                    iter <= iter + 1;
                    state <= S_ITER;
                end
            end

            S_DONE: begin
                // Pixel finished. Hold colour; wait for the packer to take it.
                if (ready & valid_int) begin
                    // advance to next pixel
                    if (lastx) begin
                        x <= 0;
                        if (lasty) y <= 0; else y <= y + 9'd1;
                    end else begin
                        x <= x + 10'd1;
                    end
                    state <= S_INIT;
                end
            end
        endcase
    end
end

// ---- Colour selection (combinational, based on root_idx + shade) ----
// Root colours: red, teal, blue  (match newton_fixed.py COL)
reg [7:0] cr, cg, cb;
always @(*) begin
    case (root_idx)
        2'd0: begin cr = 8'd230; cg = 8'd57;  cb = 8'd70;  end
        2'd1: begin cr = 8'd42;  cg = 8'd157; cb = 8'd143; end
        2'd2: begin cr = 8'd69;  cg = 8'd123; cb = 8'd157; end
        default: begin cr = 8'd0; cg = 8'd0; cb = 8'd0; end   // black
    endcase
end
wire [16:0] rprod = cr * shade;   // full-width product (avoid truncation)
wire [16:0] gprod = cg * shade;
wire [16:0] bprod = cb * shade;
wire [7:0] r = (root_idx == 2'd3) ? 8'd0 : rprod[15:8];   // == (cr*shade)>>8
wire [7:0] g = (root_idx == 2'd3) ? 8'd0 : gprod[15:8];
wire [7:0] b = (root_idx == 2'd3) ? 8'd0 : bprod[15:8];

packer pixel_packer(.aclk(out_stream_aclk),
                    .aresetn(periph_resetn),
                    .r(r), .g(g), .b(b),
                    .eol(lastx), .in_stream_ready(ready), .valid(valid_int), .sof(first),
                    .out_stream_tdata(out_stream_tdata), .out_stream_tkeep(out_stream_tkeep),
                    .out_stream_tlast(out_stream_tlast), .out_stream_tready(out_stream_tready),
                    .out_stream_tvalid(out_stream_tvalid), .out_stream_tuser(out_stream_tuser) );

endmodule
