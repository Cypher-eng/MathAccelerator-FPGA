module complex_mul #(
    parameter WIDTH = 32,
    parameter FRAC  = 24
)(
    input  signed [WIDTH-1:0] ar,
    input  signed [WIDTH-1:0] ai,
    input  signed [WIDTH-1:0] br,
    input  signed [WIDTH-1:0] bi,

    output signed [WIDTH-1:0] yr,
    output signed [WIDTH-1:0] yi
);

    wire signed [WIDTH-1:0] ac;
    wire signed [WIDTH-1:0] bd;
    wire signed [WIDTH-1:0] ad;
    wire signed [WIDTH-1:0] bc;

    fixed_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) mul_ac (
        .a(ar),
        .b(br),
        .y(ac)
    );

    fixed_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) mul_bd (
        .a(ai),
        .b(bi),
        .y(bd)
    );

    fixed_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) mul_ad (
        .a(ar),
        .b(bi),
        .y(ad)
    );

    fixed_mul #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) mul_bc (
        .a(ai),
        .b(br),
        .y(bc)
    );

    assign yr = ac - bd;
    assign yi = ad + bc;

endmodule
