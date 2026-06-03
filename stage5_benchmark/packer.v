module packer(
    input wire aclk,
    input wire aresetn,

    input wire [7:0] r,
    input wire [7:0] g,
    input wire [7:0] b,
    input wire eol,
    output wire in_stream_ready,
    input wire valid,
    input wire sof,

    output wire [31:0] out_stream_tdata,
    output wire [3:0] out_stream_tkeep,
    output wire out_stream_tlast,
    input wire out_stream_tready,
    output wire out_stream_tvalid,
    output wire [0:0] out_stream_tuser
);

assign in_stream_ready = out_stream_tready;
assign out_stream_tdata = {8'd0, r, g, b};
assign out_stream_tkeep = 4'b1111;
assign out_stream_tlast = eol;
assign out_stream_tvalid = valid;
assign out_stream_tuser = sof;

endmodule
