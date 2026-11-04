// Unpack signed Q11.8 source coordinates for four-neighbour RGB565 sampling.
// Combinational contract only: the inverse-map producer and DDR3 reads are separate.
module coordinate_q8_split #(
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720
) (
    input  wire               valid_in,
    input  wire signed [19:0] src_x_q8,
    input  wire signed [19:0] src_y_q8,
    output wire               valid_out,
    output wire [10:0]       x0,
    output wire [10:0]       y0,
    output wire [7:0]        frac_x,
    output wire [7:0]        frac_y
);
    localparam signed [19:0] X_LIMIT_Q8 = (IMG_WIDTH - 1) << 8;
    localparam signed [19:0] Y_LIMIT_Q8 = (IMG_HEIGHT - 1) << 8;

    assign valid_out = valid_in && src_x_q8 >= 0 && src_y_q8 >= 0
                     && src_x_q8 < X_LIMIT_Q8 && src_y_q8 < Y_LIMIT_Q8;
    assign x0 = valid_out ? src_x_q8[18:8] : 11'd0;
    assign y0 = valid_out ? src_y_q8[18:8] : 11'd0;
    assign frac_x = valid_out ? src_x_q8[7:0] : 8'd0;
    assign frac_y = valid_out ? src_y_q8[7:0] : 8'd0;
endmodule
