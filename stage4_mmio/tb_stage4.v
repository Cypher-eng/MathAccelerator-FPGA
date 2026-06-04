`timescale 1ns/1ps

module tb_stage4;

reg clk = 0;
reg rst = 1;
reg ready = 1;
integer zr0;
integer zi0;
integer step;
integer maxit;
integer out_file;
integer count;

wire valid;
wire [7:0] r;
wire [7:0] g;
wire [7:0] b;
wire done;

always #5 clk = ~clk;

pixel_generator_4 dut (
    .clk(clk),
    .rst(rst),
    .ready(ready),
    .cfg_zr0(zr0),
    .cfg_zi0(zi0),
    .cfg_step(step),
    .cfg_maxit(maxit),
    .valid(valid),
    .r(r),
    .g(g),
    .b(b),
    .done(done)
);

initial begin
    zr0 = -8192;
    zi0 = -6144;
    step = 26;
    maxit = 30;
    if (!$value$plusargs("ZR0=%d", zr0)) zr0 = -8192;
    if (!$value$plusargs("ZI0=%d", zi0)) zi0 = -6144;
    if (!$value$plusargs("STEP=%d", step)) step = 26;
    if (!$value$plusargs("MAXIT=%d", maxit)) maxit = 30;
    out_file = $fopen("verilog_out.txt", "w");
    count = 0;
    repeat (5) @(posedge clk);
    rst = 0;
end

always @(posedge clk) begin
    if (!rst && valid && ready) begin
        $fwrite(out_file, "%0d %0d %0d\n", r, g, b);
        count = count + 1;
    end
    if (!rst && done) begin
        $fclose(out_file);
        $display("wrote %0d pixels", count);
        $finish;
    end
end

initial begin
    #200000000;
    $display("timeout");
    $finish;
end

endmodule
