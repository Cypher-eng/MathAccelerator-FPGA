`timescale 1ns / 1ps

module tb_fixed_mul;

    localparam WIDTH = 32;
    localparam FRAC  = 24;

    reg  signed [WIDTH-1:0] a;
    reg  signed [WIDTH-1:0] b;
    wire signed [WIDTH-1:0] y;

    fixed_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) dut (
        .a(a),
        .b(b),
        .y(y)
    );

    initial begin

        $dumpfile("tb_fixed_mul.vcd");
        $dumpvars(0, tb_fixed_mul);

        // ==========================================
        // Test 1 : 1.5 * 2.0 = 3.0
        // ==========================================

        a = 32'sd25165824;   // 1.5 in Q8.24
        b = 32'sd33554432;   // 2.0 in Q8.24

        #10;

        $display("Test1 result = %0d", y);
        $display("Expected     = %0d", 32'sd50331648);

        if (y !== 32'sd50331648) begin
            $display("FAILED TEST 1");
            $finish;
        end

        // ==========================================
        // Test 2 : -0.5 * 0.5 = -0.25
        // ==========================================

        a = -32'sd8388608;   // -0.5
        b =  32'sd8388608;   //  0.5

        #10;

        $display("Test2 result = %0d", y);
        $display("Expected     = %0d", -32'sd4194304);

        if (y !== -32'sd4194304) begin
            $display("FAILED TEST 2");
            $finish;
        end

        $display("ALL TESTS PASSED");
        $finish;

    end

endmodule
