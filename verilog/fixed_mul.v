module fixed_mul #(
    parameter WIDTH = 32,
    parameter FRAC  = 24
)(
    input  signed [WIDTH-1:0] a,
    input  signed [WIDTH-1:0] b,
    output signed [WIDTH-1:0] y
);

    wire signed [(2*WIDTH)-1:0] product;

    assign product = a * b;

    // Q8.24 scaling correction
    assign y = product >>> FRAC;

endmodule
