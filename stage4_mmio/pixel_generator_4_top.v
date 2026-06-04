`timescale 1ns / 1ps

module pixel_generator_4_top(
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
        readAddr  <= 0;
        readData  <= 0;
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
integer i;
always @(posedge s_axi_lite_aclk) begin
    if (!axi_resetn) begin
        writeState <= AWAIT_WADD_AND_DATA;
        writeAddr  <= 0;
        writeData  <= 0;

        for (i = 0; i < REG_FILE_SIZE; i = i + 1) begin
            regfile[i] <= 32'd0;
        end
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
        //Received address, waiting for data
        AWAIT_WDATA: if (s_axi_lite_wvalid) begin
            writeData <= s_axi_lite_wdata;
            writeState <= AWAIT_WRITE;
        end
        //Received data, waiting for address
        AWAIT_WADD: if (s_axi_lite_awvalid) begin
            writeAddr <= s_axi_lite_awaddr[2+:REG_FILE_AWIDTH];
            writeState <= AWAIT_WRITE;
        end
        //Perform the write
        AWAIT_WRITE: begin
            regfile[writeAddr] <= writeData;
            writeState <= AWAIT_RESP;
        end
        //Wait to send response
        AWAIT_RESP: if (s_axi_lite_bready) writeState <= AWAIT_WADD_AND_DATA;
        default: writeState <= AWAIT_WADD_AND_DATA;
    endcase
end

wire signed [31:0] cfg_zr0   = regfile[1]; // left right panning
wire signed [31:0] cfg_zi0   = regfile[2]; // up down panning
wire signed [31:0] cfg_step  = regfile[3]; // pixel spacing/zoom
wire        [31:0] cfg_maxit = regfile[4]; // maximum iteration depth

assign s_axi_lite_awready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WADD);
assign s_axi_lite_wready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WDATA);
assign s_axi_lite_bvalid = (writeState == AWAIT_RESP);
assign s_axi_lite_bresp = (writeAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;

wire core_valid;
wire [7:0] core_r, core_g, core_b;
wire core_done;
wire [15:0] core_x, core_y;

wire ready;
wire valid_int;
wire first;
wire lastx;

assign valid_int = core_valid;
assign first     = core_valid && (core_x == 16'd0) && (core_y == 16'd0);
assign lastx     = core_valid && (core_x == X_SIZE - 1);

pixel_generator_4_old #(.WIDTH(640), .HEIGHT(480)) newton_core(
    .clk(out_stream_aclk),
    .rst(!periph_resetn),
    .ready(ready),

    .cfg_zr0(cfg_zr0),
    .cfg_zi0(cfg_zi0),
    .cfg_step(cfg_step),
    .cfg_maxit(cfg_maxit),

    .valid(core_valid),
    .r(core_r),
    .g(core_g),
    .b(core_b),
    .done(core_done),
    .x_out(core_x),
    .y_out(core_y)
);

packer pixel_packer(.aclk(out_stream_aclk),
                    .aresetn(periph_resetn),
                    .r(core_r), .g(core_g), .b(core_b),
                    .eol(lastx), .in_stream_ready(ready), .valid(valid_int), .sof(first),
                    .out_stream_tdata(out_stream_tdata), .out_stream_tkeep(out_stream_tkeep),
                    .out_stream_tlast(out_stream_tlast), .out_stream_tready(out_stream_tready),
                    .out_stream_tvalid(out_stream_tvalid), .out_stream_tuser(out_stream_tuser) );

endmodule