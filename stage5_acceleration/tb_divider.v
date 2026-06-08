`timescale 1ns/1ps

module tb_divider;

localparam WIDTH = 64;

reg clk = 0;
reg rstn = 0;
reg start = 0;
reg signed [WIDTH-1:0] numer = 0;
reg signed [WIDTH-1:0] denom = 1;

wire signed [WIDTH-1:0] quot;
wire done;
wire busy;

integer errors = 0;
integer tests = 0;

always #5 clk = ~clk;

divider_seq #(
    .WIDTH(WIDTH)
) dut (
    .clk(clk),
    .rstn(rstn),
    .start(start),
    .numer(numer),
    .denom(denom),
    .quot(quot),
    .done(done),
    .busy(busy)
);

task run_case;
    input signed [WIDTH-1:0] n;
    input signed [WIDTH-1:0] d;
    reg signed [WIDTH-1:0] expected;
    begin
        expected = n / d;

        @(posedge clk);
        numer <= n;
        denom <= d;
        start <= 1'b1;

        @(posedge clk);
        start <= 1'b0;

        while (!done) begin
            @(posedge clk);
        end

        tests = tests + 1;

        if (quot !== expected) begin
            errors = errors + 1;
            $display("DIVIDER MISMATCH n=%0d d=%0d expected=%0d got=%0d", n, d, expected, quot);
        end
    end
endtask

initial begin
    repeat (5) @(posedge clk);
    rstn = 1'b1;

    run_case(64'sd0, 64'sd1);
    run_case(64'sd1, 64'sd1);
    run_case(64'sd10, 64'sd3);
    run_case(-64'sd10, 64'sd3);
    run_case(64'sd10, -64'sd3);
    run_case(-64'sd10, -64'sd3);

    run_case(64'sd4096, 64'sd123);
    run_case(-64'sd4096, 64'sd123);
    run_case(64'sd4096, -64'sd123);
    run_case(-64'sd4096, -64'sd123);

    run_case(64'sd123456789, 64'sd4096);
    run_case(-64'sd123456789, 64'sd4096);
    run_case(64'sd987654321, 64'sd12345);
    run_case(-64'sd987654321, 64'sd12345);

    run_case(64'sd35184372088832, 64'sd4096);
    run_case(-64'sd35184372088832, 64'sd4096);
    run_case(64'sd35184372088832, -64'sd4096);
    run_case(-64'sd35184372088832, -64'sd4096);

    run_case(64'sd576460752303423487, 64'sd1234567);
    run_case(-64'sd576460752303423487, 64'sd1234567);
    run_case(64'sd576460752303423487, -64'sd1234567);
    run_case(-64'sd576460752303423487, -64'sd1234567);

    if (errors == 0) begin
        $display("DIVIDER BIT-EXACT MATCH: %0d tests passed", tests);
    end else begin
        $display("DIVIDER FAILED: %0d / %0d tests failed", errors, tests);
    end

    $finish;
end

initial begin
    #200000;
    $display("DIVIDER TIMEOUT");
    $finish;
end

endmodule
