`timescale 1ns / 1ps

module tb_complex_mul;

    localparam WIDTH = 32;
    localparam FRAC  = 24;

    reg  signed [WIDTH-1:0] ar;
    reg  signed [WIDTH-1:0] ai;
    reg  signed [WIDTH-1:0] br;
    reg  signed [WIDTH-1:0] bi;

    wire signed [WIDTH-1:0] yr;
    wire signed [WIDTH-1:0] yi;

    complex_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) dut (
        .ar(ar),
        .ai(ai),
        .br(br),
        .bi(bi),
        .yr(yr),
        .yi(yi)
    );

    initial begin
        $dumpfile("tb_complex_mul.vcd");
        $dumpvars(0, tb_complex_mul);

        // Test 1:
        // (1 + 2i) * (3 + 4i)
        // real = 1*3 - 2*4 = -5
        // imag = 1*4 + 2*3 = 10

        ar = 32'sd16777216;   // 1.0
        ai = 32'sd33554432;   // 2.0
        br = 32'sd50331648;   // 3.0
        bi = 32'sd67108864;   // 4.0

        #10;

        $display("Test1 yr = %0d", yr);
        $display("Test1 yi = %0d", yi);
        $display("Expected yr = %0d", -32'sd83886080);
        $display("Expected yi = %0d",  32'sd167772160);

        if (yr !== -32'sd83886080) begin
            $display("FAILED TEST 1 REAL");
            $finish;
        end

        if (yi !== 32'sd167772160) begin
            $display("FAILED TEST 1 IMAG");
            $finish;
        end

        // Test 2:
        // (0.5 - 0.5i) * (0.5 + 0.5i)
        // real = 0.25 - (-0.25) = 0.5
        // imag = 0.25 + (-0.25) = 0

        ar =  32'sd8388608;   //  0.5
        ai = -32'sd8388608;   // -0.5
        br =  32'sd8388608;   //  0.5
        bi =  32'sd8388608;   //  0.5

        #10;

        $display("Test2 yr = %0d", yr);
        $display("Test2 yi = %0d", yi);
        $display("Expected yr = %0d", 32'sd8388608);
        $display("Expected yi = %0d", 32'sd0);

        if (yr !== 32'sd8388608) begin
            $display("FAILED TEST 2 REAL");
            $finish;
        end

        if (yi !== 32'sd0) begin
            $display("FAILED TEST 2 IMAG");
            $finish;
        end

        $display("ALL COMPLEX MUL TESTS PASSED");
        $finish;
    end

endmodule
