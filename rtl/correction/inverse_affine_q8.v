// Output pixel -> ideal-image position using an inverse 2x3 affine matrix.
// Matrix coefficients are signed Q2.20; translations and outputs are signed
// Q11.8 pixels. Sum the Q20 products before one arithmetic floor to Q8.
// The PC side computes/inverts the affine matrix; frame-atomic updates and
// Brown/fisheye distortion mapping are separate downstream responsibilities.
module inverse_affine_q8 (
    input  wire               valid_in,
    input  wire [10:0]        out_x,
    input  wire [10:0]        out_y,
    input  wire signed [21:0] a00_q20,
    input  wire signed [21:0] a01_q20,
    input  wire signed [21:0] a10_q20,
    input  wire signed [21:0] a11_q20,
    input  wire signed [19:0] tx_q8,
    input  wire signed [19:0] ty_q8,
    output wire               valid_out,
    output wire signed [19:0] ideal_x_q8,
    output wire signed [19:0] ideal_y_q8
);
    wire signed [11:0] x_signed = {1'b0, out_x};
    wire signed [11:0] y_signed = {1'b0, out_y};
    wire signed [33:0] xx = a00_q20 * x_signed;
    wire signed [33:0] xy = a01_q20 * y_signed;
    wire signed [33:0] yx = a10_q20 * x_signed;
    wire signed [33:0] yy = a11_q20 * y_signed;
    wire signed [40:0] sum_x = {{7{xx[33]}},xx} + {{7{xy[33]}},xy}
                              + ({{21{tx_q8[19]}},tx_q8} <<< 12);
    wire signed [40:0] sum_y = {{7{yx[33]}},yx} + {{7{yy[33]}},yy}
                              + ({{21{ty_q8[19]}},ty_q8} <<< 12);
    wire signed [40:0] x_q8_full = sum_x >>> 12;
    wire signed [40:0] y_q8_full = sum_y >>> 12;
    wire x_fits = x_q8_full[40:20] == {21{x_q8_full[19]}};
    wire y_fits = y_q8_full[40:20] == {21{y_q8_full[19]}};
    assign valid_out = valid_in && x_fits && y_fits;
    assign ideal_x_q8 = valid_out ? x_q8_full[19:0] : 20'sd0;
    assign ideal_y_q8 = valid_out ? y_q8_full[19:0] : 20'sd0;
endmodule
