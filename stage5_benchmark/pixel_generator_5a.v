
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.05.2024 22:03:08
// Design Name: 
// Module Name: test_block_v
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
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
input [7:0]     s_axi_lite_araddr,
output          s_axi_lite_arready,
input           s_axi_lite_arvalid,

input [7:0]     s_axi_lite_awaddr,
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

parameter  REG_FILE_SIZE = 8;
localparam REG_FILE_AWIDTH = $clog2(REG_FILE_SIZE);
parameter AXI_LITE_ADDR_WIDTH = 8;
parameter X_SIZE = 640;
parameter Y_SIZE = 480;

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

reg [31:0] regfile [REG_FILE_SIZE-1:0];
integer ri;
initial begin
    for (ri = 0; ri < REG_FILE_SIZE; ri = ri + 1)
        regfile[ri] = 32'h0;
end
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

        AWAIT_FETCH: begin
            readState <= AWAIT_READ;
        end

        AWAIT_READ: begin
            if (s_axi_lite_rready) begin
                readState <= AWAIT_RADD;
            end
        end

        default: begin
            readState <= AWAIT_RADD;
        end

    endcase
end

assign s_axi_lite_arready = (readState == AWAIT_RADD);
assign s_axi_lite_rresp = (readAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;
assign s_axi_lite_rvalid = (readState == AWAIT_READ);
assign s_axi_lite_rdata = readData;

//Write to the register file, use a state machine to track address write, data write and response read events
always @(posedge s_axi_lite_aclk) begin

    if (!axi_resetn) begin
        writeState <= AWAIT_WADD_AND_DATA;
    end

    else case (writeState)

        AWAIT_WADD_AND_DATA: begin  //Idle, awaiting a write address or data
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
                default: begin
                    writeState <= AWAIT_WADD_AND_DATA;
                end
            endcase        
        end

        AWAIT_WDATA: begin //Received address, waiting for data
            if (s_axi_lite_wvalid) begin
                writeData <= s_axi_lite_wdata;
                writeState <= AWAIT_WRITE;
            end
        end

        AWAIT_WADD: begin //Received data, waiting for address
            if (s_axi_lite_awvalid) begin
                writeAddr <= s_axi_lite_awaddr[2+:REG_FILE_AWIDTH];
                writeState <= AWAIT_WRITE;
            end
        end

        AWAIT_WRITE: begin //Perform the write
            regfile[writeAddr] <= writeData;
            writeState <= AWAIT_RESP;
        end

        AWAIT_RESP: begin //Wait to send response
            if (s_axi_lite_bready) begin
                writeState <= AWAIT_WADD_AND_DATA;
            end
        end

        default: begin
            writeState <= AWAIT_WADD_AND_DATA;
        end
    endcase
end

assign s_axi_lite_awready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WADD);
assign s_axi_lite_wready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WDATA);
assign s_axi_lite_bvalid = (writeState == AWAIT_RESP);
assign s_axi_lite_bresp = (writeAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;


localparam signed [63:0] SCALE = 64'sd4096;
localparam signed [63:0] TOL = 64'sd123;
localparam signed [63:0] R0R = 64'sd4096;
localparam signed [63:0] R0I = 64'sd0;
localparam signed [63:0] R1R = -64'sd2048;
localparam signed [63:0] R1I = 64'sd3547;
localparam signed [63:0] R2R = -64'sd2048;
localparam signed [63:0] R2I = -64'sd3547;

localparam S_INIT = 2'd0;
localparam S_ITER = 2'd1;
localparam S_DONE = 2'd2;

reg [1:0] state;
reg [9:0] x;
reg [8:0] y;
reg [5:0] iter;
reg [5:0] debug_iter_out;
reg signed [63:0] zr;
reg signed [63:0] zi;
reg valid_int;
reg [7:0] r;
reg [7:0] g;
reg [7:0] b;

wire ready;
wire first = (x == 0) && (y == 0);
wire lastx = (x == X_SIZE - 1);
wire lasty = (y == Y_SIZE - 1);

wire regs_zero = (regfile[0] == 0) && (regfile[1] == 0) && (regfile[2] == 0) && (regfile[3] == 0);
wire signed [63:0] zr0_use = regs_zero ? -64'sd8192 : {{32{regfile[0][31]}}, regfile[0]};
wire signed [63:0] zi0_use = regs_zero ? -64'sd6144 : {{32{regfile[1][31]}}, regfile[1]};
wire signed [63:0] step_use = regs_zero ? 64'sd26 : {{32{regfile[2][31]}}, regfile[2]};
wire [5:0] maxit_use = regs_zero ? 6'd30 : ((regfile[3][5:0] == 0) ? 6'd30 : regfile[3][5:0]);

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

always @(posedge out_stream_aclk) begin
    if (!periph_resetn) begin
        state <= S_INIT;
        x <= 0;
        y <= 0;
        iter <= 0;
        zr <= 0;
        zi <= 0;
        r <= 0;
        g <= 0;
        b <= 0;
        valid_int <= 0;
    end else begin
        case (state)
            S_INIT: begin
                valid_int <= 0;
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
                    debug_iter_out <= iter;
                    valid_int <= 1;
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
                        debug_iter_out <= iter;
                        valid_int <= 1;
                        state <= S_DONE;
                    end else if (iter == maxit_use - 1) begin
                        set_colour(2'd3, iter);
                        debug_iter_out <= iter;
                        valid_int <= 1;
                        state <= S_DONE;
                    end else begin
                        zr <= nzr;
                        zi <= nzi;
                        iter <= iter + 1;
                    end
                end
            end

            S_DONE: begin
                valid_int <= 1;
                if (ready) begin
                    valid_int <= 0;

                    if (lastx) begin
                        x <= 0;
                        if (lasty)
                            y <= 0;
                        else
                            y <= y + 1;
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

packer pixel_packer(    .aclk(out_stream_aclk),
                        .aresetn(periph_resetn),
                        .r(r), .g(g), .b(b),
                        .eol(lastx), .in_stream_ready(ready), .valid(valid_int), .sof(first),
                        .out_stream_tdata(out_stream_tdata), .out_stream_tkeep(out_stream_tkeep),
                        .out_stream_tlast(out_stream_tlast), .out_stream_tready(out_stream_tready),
                        .out_stream_tvalid(out_stream_tvalid), .out_stream_tuser(out_stream_tuser) );

 
endmodule
