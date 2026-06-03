`timescale 1ns / 1ps
// Test bench drives simulates the operation of the pynq board, 
// captures every pixel it produces into a plain text file so we
// can turn it into a PNG image a Python script
module tb_view;

    // A 100 MHz clock = 10 ns period (toggle every 5 ns)
    reg clk = 0;
    always #5 clk = ~clk;

    // Reset: held low briefly, then released
    reg rstn = 0;
    initial begin
        rstn = 1'b0;
        #20 rstn = 1'b1;     // release reset after 20 ns
        dut.regfile[0] = 32'd0;// initialise register value with known value (ie 0)
    end

    // Wires for the stream output
    wire [31:0] tdata;
    wire [3:0]  tkeep;
    wire        tlast, tvalid;
    wire [0:0]  tuser;

    // out_stream_tready = 1 means "the receiver is always ready"
    reg tready = 1'b1;

    // instantiate the pixel generator (device under test)
    pixel_generator dut (
        .out_stream_aclk (clk),
        .s_axi_lite_aclk (clk),
        .axi_resetn      (rstn),
        .periph_resetn   (rstn),

        .out_stream_tdata (tdata),
        .out_stream_tkeep (tkeep),
        .out_stream_tlast (tlast),
        .out_stream_tready(tready),
        .out_stream_tvalid(tvalid),
        .out_stream_tuser (tuser),

        // AXI-Lite tied off (we are not writing any registers in Stage 0)
        .s_axi_lite_araddr (8'h0),  .s_axi_lite_arready(), .s_axi_lite_arvalid(1'b0),
        .s_axi_lite_awaddr (8'h0),  .s_axi_lite_awready(), .s_axi_lite_awvalid(1'b0),
        .s_axi_lite_bready (1'b0),  .s_axi_lite_bresp(),   .s_axi_lite_bvalid(),
        .s_axi_lite_rdata  (),      .s_axi_lite_rready(1'b0), .s_axi_lite_rresp(), .s_axi_lite_rvalid(),
        .s_axi_lite_wdata  (32'h0), .s_axi_lite_wready(),  .s_axi_lite_wvalid(1'b0)
    );

    // Capture pixels into a text file
    // The example advances to the next pixel whenever (ready & valid_int).
    // We reach INTO the DUT (hierarchical reference) to read its internal
    // r, g, b and the advance condition. One line per pixel: "R G B".
    integer fh;
    integer pixel_count = 0;
    localparam TOTAL = 640*480;   // one full frame

    initial fh = $fopen("frame.txt", "w");

    always @(posedge clk) begin
        if (rstn) begin
            // dut.ready is the packer's back-pressure; dut.valid_int is 1 in the example.
            if (dut.ready & dut.valid_int) begin
                if (pixel_count < TOTAL) begin
                    $fwrite(fh, "%0d %0d %0d\n", dut.r, dut.g, dut.b);
                    pixel_count = pixel_count + 1;
                end
                if (pixel_count == TOTAL) begin
                    $display("Captured a full frame: %0d pixels", pixel_count);
                    $fclose(fh);
                    $finish;
                end
            end
        end
    end

    // Safety timeout so the sim can never hang forever
    initial begin
        #50000000;  // 50 ms of sim time is way more than one frame needs
        $display("Timeout reached (captured %0d pixels)", pixel_count);
        $fclose(fh);
        $finish;
    end

endmodule
