module pixel_generator #(
    parameter AXI_LITE_ADDR_WIDTH = 8,
    parameter REG_FILE_SIZE = 8
)(
    input           out_stream_aclk,
    input           s_axi_lite_aclk,
    input           axi_resetn,
    input           periph_resetn,

    // Stream output
    output [31:0]   out_stream_tdata,
    output [3:0]    out_stream_tkeep,
    output          out_stream_tlast,
    input           out_stream_tready,
    output          out_stream_tvalid,
    output [0:0]    out_stream_tuser, 

    // AXI-Lite read address channel
    input [AXI_LITE_ADDR_WIDTH-1:0] s_axi_lite_araddr,
    output          s_axi_lite_arready,
    input           s_axi_lite_arvalid,

    // AXI-Lite write address channel
    input [AXI_LITE_ADDR_WIDTH-1:0] s_axi_lite_awaddr,
    output          s_axi_lite_awready,
    input           s_axi_lite_awvalid,

    // AXI-Lite write response channel
    input           s_axi_lite_bready,
    output [1:0]    s_axi_lite_bresp,
    output          s_axi_lite_bvalid,

    // AXI-Lite read data channel
    output [31:0]   s_axi_lite_rdata,
    input           s_axi_lite_rready,
    output [1:0]    s_axi_lite_rresp,
    output          s_axi_lite_rvalid,

    // AXI-Lite write data channel
    input  [31:0]   s_axi_lite_wdata,
    output          s_axi_lite_wready,
    input           s_axi_lite_wvalid
);

localparam X_SIZE = 640;
localparam Y_SIZE = 480;

localparam REG_FILE_AWIDTH = $clog2(REG_FILE_SIZE);

localparam AWAIT_WADD_AND_DATA = 3'b000;
localparam AWAIT_WDATA         = 3'b001;
localparam AWAIT_WADD          = 3'b010;
localparam AWAIT_WRITE         = 3'b100;
localparam AWAIT_RESP          = 3'b101;

localparam AWAIT_RADD  = 2'b00;
localparam AWAIT_FETCH = 2'b01;
localparam AWAIT_READ  = 2'b10;

localparam AXI_OK  = 2'b00;
localparam AXI_ERR = 2'b10;

reg [31:0]                regfile [REG_FILE_SIZE-1:0];
reg [REG_FILE_AWIDTH-1:0] writeAddr, readAddr;
reg [31:0]                readData, writeData;
reg [1:0]                 readState  = AWAIT_RADD;
reg [2:0]                 writeState = AWAIT_WADD_AND_DATA;


// AXI-Lite register file read logic
always @(posedge s_axi_lite_aclk) begin
    readData <= regfile[readAddr];

    if (!axi_resetn) begin
        readState <= AWAIT_RADD;
        readAddr  <= {REG_FILE_AWIDTH{1'b0}};
        readData  <= 32'd0;
    end
    else begin
        case (readState)
            AWAIT_RADD: begin
                if (s_axi_lite_arvalid) begin
                    readAddr  <= s_axi_lite_araddr[2 +: REG_FILE_AWIDTH];
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
end

assign s_axi_lite_arready = (readState == AWAIT_RADD);
assign s_axi_lite_rresp   = (readAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;
assign s_axi_lite_rvalid  = (readState == AWAIT_READ);
assign s_axi_lite_rdata   = readData;

// AXI-Lite register file write logic
always @(posedge s_axi_lite_aclk) begin
    if (!axi_resetn) begin
        writeState <= AWAIT_WADD_AND_DATA;
        writeAddr  <= {REG_FILE_AWIDTH{1'b0}};
        writeData  <= 32'd0;
    end
    else begin
        case (writeState)
            AWAIT_WADD_AND_DATA: begin
                case ({s_axi_lite_awvalid, s_axi_lite_wvalid})
                    2'b10: begin
                        writeAddr  <= s_axi_lite_awaddr[2 +: REG_FILE_AWIDTH];
                        writeState <= AWAIT_WDATA;
                    end

                    2'b01: begin
                        writeData  <= s_axi_lite_wdata;
                        writeState <= AWAIT_WADD;
                    end

                    2'b11: begin
                        writeData  <= s_axi_lite_wdata;
                        writeAddr  <= s_axi_lite_awaddr[2 +: REG_FILE_AWIDTH];
                        writeState <= AWAIT_WRITE;
                    end

                    default: begin
                        writeState <= AWAIT_WADD_AND_DATA;
                    end
                endcase        
            end

            AWAIT_WDATA: begin
                if (s_axi_lite_wvalid) begin
                    writeData  <= s_axi_lite_wdata;
                    writeState <= AWAIT_WRITE;
                end
            end

            AWAIT_WADD: begin
                if (s_axi_lite_awvalid) begin
                    writeAddr  <= s_axi_lite_awaddr[2 +: REG_FILE_AWIDTH];
                    writeState <= AWAIT_WRITE;
                end
            end

            AWAIT_WRITE: begin
                if (writeAddr < REG_FILE_SIZE) begin
                    regfile[writeAddr] <= writeData;
                end
                writeState <= AWAIT_RESP;
            end

            AWAIT_RESP: begin
                if (s_axi_lite_bready) begin
                    writeState <= AWAIT_WADD_AND_DATA;
                end
            end

            default: begin
                writeState <= AWAIT_WADD_AND_DATA;
            end
        endcase
    end
end

assign s_axi_lite_awready = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WADD);
assign s_axi_lite_wready  = (writeState == AWAIT_WADD_AND_DATA || writeState == AWAIT_WDATA);
assign s_axi_lite_bvalid  = (writeState == AWAIT_RESP);
assign s_axi_lite_bresp   = (writeAddr < REG_FILE_SIZE) ? AXI_OK : AXI_ERR;

// Pixel generator
reg [9:0] x;
reg [8:0] y;

wire ready;
wire valid_int;

wire first = (x == 10'd0) && (y == 9'd0);
wire lastx = (x == X_SIZE - 1);
wire lasty = (y == Y_SIZE - 1);

wire [7:0] frame = regfile[0][7:0];

assign valid_int = 1'b1;

always @(posedge out_stream_aclk) begin
    if (!periph_resetn) begin
        x <= 10'd0;
        y <= 9'd0;
    end
    else begin
        if (ready && valid_int) begin
            if (lastx) begin
                x <= 10'd0;
                if (lasty) begin
                    y <= 9'd0;
                end
                else begin
                    y <= y + 9'd1;
                end
            end
            else begin
                x <= x + 10'd1;
            end
        end
    end
end

wire [7:0] r, g, b;

assign r = x[7:0] + frame;
assign g = y[7:0] + frame;
assign b = x[6:0] ^ y[6:0] + frame;

// Pack RGB pixels into AXI stream words
packer pixel_packer(
    .aclk(out_stream_aclk),
    .aresetn(periph_resetn),

    .r(r),
    .g(g),
    .b(b),

    .eol(lastx),
    .in_stream_ready(ready),
    .valid(valid_int),
    .sof(first),

    .out_stream_tdata(out_stream_tdata),
    .out_stream_tkeep(out_stream_tkeep),
    .out_stream_tlast(out_stream_tlast),
    .out_stream_tready(out_stream_tready),
    .out_stream_tvalid(out_stream_tvalid),
    .out_stream_tuser(out_stream_tuser)
);

endmodule

