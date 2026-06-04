`timescale 1ns/1ps

module tb_stage5_benchmark;

reg clk = 0;
reg axi_resetn = 0;
reg periph_resetn = 0;

wire [31:0] tdata;
wire [3:0] tkeep;
wire tlast;
reg tready = 1;
wire tvalid;
wire [0:0] tuser;

reg [7:0] araddr = 0;
wire arready;
reg arvalid = 0;
reg [7:0] awaddr = 0;
wire awready;
reg awvalid = 0;
reg bready = 0;
wire [1:0] bresp;
wire bvalid;
wire [31:0] rdata;
reg rready = 0;
wire [1:0] rresp;
wire rvalid;
reg [31:0] wdata = 0;
wire wready;
reg wvalid = 0;

integer out_file;
integer hist_file;
integer count;
integer zr0;
integer zi0;
integer step;
integer maxit;
integer target_pixels;

integer cycle_count;
integer first_pixel_cycle;
integer last_pixel_cycle;
integer total_cycles;
integer started;
integer k;
integer hist [0:63];

always #5 clk = ~clk;

pixel_generator dut (
    .out_stream_aclk(clk),
    .s_axi_lite_aclk(clk),
    .axi_resetn(axi_resetn),
    .periph_resetn(periph_resetn),

    .out_stream_tdata(tdata),
    .out_stream_tkeep(tkeep),
    .out_stream_tlast(tlast),
    .out_stream_tready(tready),
    .out_stream_tvalid(tvalid),
    .out_stream_tuser(tuser),

    .s_axi_lite_araddr(araddr),
    .s_axi_lite_arready(arready),
    .s_axi_lite_arvalid(arvalid),
    .s_axi_lite_awaddr(awaddr),
    .s_axi_lite_awready(awready),
    .s_axi_lite_awvalid(awvalid),
    .s_axi_lite_bready(bready),
    .s_axi_lite_bresp(bresp),
    .s_axi_lite_bvalid(bvalid),
    .s_axi_lite_rdata(rdata),
    .s_axi_lite_rready(rready),
    .s_axi_lite_rresp(rresp),
    .s_axi_lite_rvalid(rvalid),
    .s_axi_lite_wdata(wdata),
    .s_axi_lite_wready(wready),
    .s_axi_lite_wvalid(wvalid)
);

defparam dut.X_SIZE = 48;
defparam dut.Y_SIZE = 36;

task axi_write;
    input [7:0] addr;
    input [31:0] data;
    begin
        @(posedge clk);
        awaddr <= addr;
        wdata <= data;
        awvalid <= 1;
        wvalid <= 1;
        bready <= 1;

        while (!(awready && wready))
            @(posedge clk);

        @(posedge clk);
        awvalid <= 0;
        wvalid <= 0;

        while (!bvalid)
            @(posedge clk);

        @(posedge clk);
        bready <= 0;
    end
endtask

initial begin
    zr0 = -8192;
    zi0 = -6144;
    step = 26;
    maxit = 30;

    if (!$value$plusargs("ZR0=%d", zr0)) zr0 = -8192;
    if (!$value$plusargs("ZI0=%d", zi0)) zi0 = -6144;
    if (!$value$plusargs("STEP=%d", step)) step = 26;
    if (!$value$plusargs("MAXIT=%d", maxit)) maxit = 30;

    target_pixels = 48 * 36;
    count = 0;
    cycle_count = 0;
    first_pixel_cycle = 0;
    last_pixel_cycle = 0;
    total_cycles = 0;
    started = 0;

    for (k = 0; k < 64; k = k + 1)
        hist[k] = 0;

    out_file = $fopen("verilog_board_out.txt", "w");

    repeat (5) @(posedge clk);
    axi_resetn = 1;
    periph_resetn = 0;

    axi_write(8'h00, zr0);
    axi_write(8'h04, zi0);
    axi_write(8'h08, step);
    axi_write(8'h0c, maxit);

    repeat (5) @(posedge clk);
    periph_resetn = 1;
end

always @(posedge clk) begin
    if (periph_resetn)
        cycle_count = cycle_count + 1;
end

always @(posedge clk) begin
    if (periph_resetn && dut.valid_int && dut.ready) begin
        if (!started) begin
            started = 1;
            first_pixel_cycle = cycle_count;
        end

        $fwrite(out_file, "%0d %0d %0d\n", dut.r, dut.g, dut.b);
        hist[dut.debug_iter_out] = hist[dut.debug_iter_out] + 1;
        count = count + 1;

        if (count == target_pixels) begin
            last_pixel_cycle = cycle_count;
            total_cycles = last_pixel_cycle - first_pixel_cycle + 1;

            $fclose(out_file);

            hist_file = $fopen("iter_hist.txt", "w");
            for (k = 0; k < 64; k = k + 1) begin
                if (hist[k] != 0)
                    $fwrite(hist_file, "%0d %0d\n", k, hist[k]);
            end
            $fclose(hist_file);

            $display("wrote %0d pixels", count);
            $display("first_pixel_cycle = %0d", first_pixel_cycle);
            $display("last_pixel_cycle  = %0d", last_pixel_cycle);
            $display("total_cycles      = %0d", total_cycles);
            $display("cycles_per_pixel  = %0f", total_cycles * 1.0 / target_pixels);
            $display("iteration histogram written to iter_hist.txt");

            $finish;
        end
    end
end

initial begin
    #500000000;
    $display("timeout");
    $finish;
end

endmodule
