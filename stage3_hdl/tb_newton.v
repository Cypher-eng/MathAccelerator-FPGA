`timescale 1ns / 1ps
// tb_newton.v  -  Stage 3 testbench
// Each Newton pixel takes MANY clock cycles, so we must capture a pixel only when it is actually produced
// i.e. on the handshake (dut.ready & dut.valid_int), not on every clock edge.
module tb_newton;

    reg clk = 0;
    always #5 clk = ~clk; // 100 MHz

    reg rstn = 0;
    initial begin
        rstn = 1'b0;
        #20 rstn = 1'b1;
    end

    wire [31:0] tdata;
    wire [3:0]  tkeep;
    wire        tlast, tvalid;
    wire [0:0]  tuser;
    reg tready = 1'b1; // receiver always ready

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
        .s_axi_lite_araddr (8'h0),  .s_axi_lite_arready(), .s_axi_lite_arvalid(1'b0),
        .s_axi_lite_awaddr (8'h0),  .s_axi_lite_awready(), .s_axi_lite_awvalid(1'b0),
        .s_axi_lite_bready (1'b0),  .s_axi_lite_bresp(),   .s_axi_lite_bvalid(),
        .s_axi_lite_rdata  (),      .s_axi_lite_rready(1'b0), .s_axi_lite_rresp(), .s_axi_lite_rvalid(),
        .s_axi_lite_wdata  (32'h0), .s_axi_lite_wready(),  .s_axi_lite_wvalid(1'b0)
    );

    integer fh;
    integer pixel_count = 0;
    integer cyc = 0;
    localparam TOTAL = 640*480;

    initial fh = $fopen("frame.txt", "w");

    always @(posedge clk) begin
        if (rstn) begin
            cyc = cyc + 1;
            // Capture exactly when the packer takes a finished pixel
            if (dut.ready & dut.valid_int) begin
                if (pixel_count < TOTAL) begin
                    $fwrite(fh, "%0d %0d %0d\n", dut.r, dut.g, dut.b);
                    pixel_count = pixel_count + 1;
                end
                if (pixel_count == TOTAL) begin
                    $display("Captured full frame: %0d pixels in %0d clock cycles", pixel_count, cyc);
                    $display("Average cycles/pixel = %0d", cyc/pixel_count);
                    $fclose(fh);
                    $finish;
                end
            end
        end
    end

    // generous timeout (Newton ~ up to 30 cycles/pixel * 307200 pixels)
    initial begin
        #2000000000;
        $display("Timeout (captured %0d pixels)", pixel_count);
        $fclose(fh);
        $finish;
    end

endmodule
