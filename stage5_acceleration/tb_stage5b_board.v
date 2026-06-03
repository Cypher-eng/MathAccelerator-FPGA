`timescale 1ns / 1ps
// ============================================================================
// tb_stage5b_board.v  -  Board-interface testbench for the accelerated Stage 5B
// parallel-lane Newton engine.
//
// This testbench follows the SAME board-interface protocol the team verified in
// Stage 4 (tb_stage4_board.v):
//   1. Release AXI reset first, but keep periph_resetn LOW.
//   2. Write the four MMIO registers (ZR0, ZI0, STEP, MAXIT) over AXI-Lite via
//      axi_write(), exactly as the PYNQ Python layer would.
//   3. ONLY THEN release periph_resetn, so the engine never generates pixels
//      from partially-configured registers (this was the pixel-0/1 bug).
//
// It additionally:
//   - counts total clock cycles for the frame (Stage 5A cycles/pixel),
//   - records the cycle of the first and last accepted pixel,
//   - builds an iteration histogram from debug_iter/debug_iter_valid,
//   - writes the RGB frame to frame.txt for bit-exact diffing.
//
// RGB is captured on (dut.valid_int && dut.ready), per the team note that the
// post-packer tvalid/tready do not align with dut.r/g/b.
//
// LANES is overridden at BUILD time by sed-ing the engine's `parameter LANES`
// line (see run_stage5b.sh), the same way resolution is overridden.
// ============================================================================
module tb_stage5b_board;

    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz nominal

    reg axi_resetn    = 0;
    reg periph_resetn = 0;

    // AXI-Lite write channel
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg wvalid;   wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;

    // unused AXI-Lite read channel
    wire arready, rvalid;  wire [1:0] rresp;  wire [31:0] rdata;

    // AXI-Stream output
    wire [31:0] tdata;  wire [3:0] tkeep;  wire tlast, tvalid;  wire [0:0] tuser;
    reg tready = 1'b1;

    // histogram probe
    wire [5:0] debug_iter;
    wire       debug_iter_valid;

    pixel_generator dut (
        .out_stream_aclk (clk),
        .s_axi_lite_aclk (clk),
        .axi_resetn      (axi_resetn),
        .periph_resetn   (periph_resetn),
        .out_stream_tdata (tdata), .out_stream_tkeep (tkeep),
        .out_stream_tlast (tlast), .out_stream_tready(tready),
        .out_stream_tvalid(tvalid), .out_stream_tuser (tuser),
        .debug_iter(debug_iter), .debug_iter_valid(debug_iter_valid),
        .s_axi_lite_araddr (8'h0),    .s_axi_lite_arready(arready), .s_axi_lite_arvalid(1'b0),
        .s_axi_lite_awaddr (awaddr),  .s_axi_lite_awready(awready), .s_axi_lite_awvalid(awvalid),
        .s_axi_lite_bready (bready),  .s_axi_lite_bresp(bresp),     .s_axi_lite_bvalid(bvalid),
        .s_axi_lite_rdata  (rdata),   .s_axi_lite_rready(1'b0),     .s_axi_lite_rresp(rresp), .s_axi_lite_rvalid(rvalid),
        .s_axi_lite_wdata  (wdata),   .s_axi_lite_wready(wready),   .s_axi_lite_wvalid(wvalid)
    );

    integer fh, hh;
    integer pixel_count = 0;
    integer cyc = 0;
    integer first_cycle = -1;
    integer last_cycle  = -1;
    integer W, H, ZR0, ZI0, STEP, MAXIT;
    integer i;
    integer hist [0:63];

    // ---- AXI-Lite single write (address in bytes: reg index << 2) ----
    task axi_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr <= addr; awvalid <= 1; wdata <= data; wvalid <= 1; bready <= 1;
            // wait for both address and data to be accepted
            wait (awready && wready);
            @(posedge clk);
            awvalid <= 0; wvalid <= 0;
            wait (bvalid);
            @(posedge clk);
            bready <= 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("W=%d",     W))     W     = 48;
        if (!$value$plusargs("H=%d",     H))     H     = 36;
        if (!$value$plusargs("ZR0=%d",   ZR0))   ZR0   = -8192;
        if (!$value$plusargs("ZI0=%d",   ZI0))   ZI0   = -6144;
        if (!$value$plusargs("STEP=%d",  STEP))  STEP  = 26;
        if (!$value$plusargs("MAXIT=%d", MAXIT)) MAXIT = 30;

        for (i = 0; i < 64; i = i + 1) hist[i] = 0;

        fh = $fopen("frame.txt", "w");

        awvalid = 0; wvalid = 0; bready = 0; awaddr = 0; wdata = 0;

        // Step 1: release AXI reset, keep periph_resetn LOW
        axi_resetn    = 0;
        periph_resetn = 0;
        repeat (4) @(posedge clk);
        axi_resetn = 1;
        repeat (2) @(posedge clk);

        // Step 2: write the four MMIO registers (byte address = index*4)
        axi_write(8'd0,  ZR0);
        axi_write(8'd4,  ZI0);
        axi_write(8'd8,  STEP);
        axi_write(8'd12, MAXIT);
        repeat (2) @(posedge clk);

        // Step 3: NOW release the pixel engine
        periph_resetn = 1;
    end

    // cycle counter + capture, active once the engine is running
    always @(posedge clk) begin
        if (periph_resetn) begin
            cyc = cyc + 1;

            // iteration histogram (every accepted pixel)
            if (debug_iter_valid) begin
                hist[debug_iter] = hist[debug_iter] + 1;
            end

            if (dut.valid_int && dut.ready) begin
                if (pixel_count < W*H) begin
                    $fwrite(fh, "%0d %0d %0d\n", dut.r, dut.g_o, dut.b);
                    if (first_cycle < 0) first_cycle = cyc;
                    last_cycle = cyc;
                    pixel_count = pixel_count + 1;
                end
                if (pixel_count == W*H) begin
                    $display("Captured full frame: %0d pixels in %0d clock cycles", pixel_count, cyc);
                    $display("cycles_per_pixel = %f", $itor(cyc) / $itor(pixel_count));
                    $display("first_pixel_cycle = %0d  last_pixel_cycle = %0d", first_cycle, last_cycle);
                    $fclose(fh);
                    // dump histogram
                    hh = $fopen("hist.txt", "w");
                    for (i = 0; i < 64; i = i + 1)
                        if (hist[i] > 0) $fwrite(hh, "%0d %0d\n", i, hist[i]);
                    $fclose(hh);
                    $finish;
                end
            end
        end
    end

    initial begin
        #5000000000;
        $display("Timeout (captured %0d pixels)", pixel_count);
        $fclose(fh);
        $finish;
    end

endmodule
