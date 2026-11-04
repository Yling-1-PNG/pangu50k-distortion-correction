// Convert one Q11.8 source position into four frame-relative pixel offsets.
// Addresses and 256-bit beat indices are relative to an aligned frame base,
// not DDR bus addresses. Each 256-bit beat contains 16 RGB565 pixels.
// STRIDE_PIXELS >= IMG_WIDTH and STRIDE_PIXELS * IMG_HEIGHT <= 2^22 are assumed.
// No DDR3 command scheduling or cache behavior is implemented here.
module four_neighbor_address_q8 #(
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter STRIDE_PIXELS = IMG_WIDTH
) (
    input  wire               valid_in,
    input  wire signed [19:0] src_x_q8,
    input  wire signed [19:0] src_y_q8,
    output wire               valid_out,
    output wire [21:0]        addr00,
    output wire [21:0]        addr10,
    output wire [21:0]        addr01,
    output wire [21:0]        addr11,
    output wire [17:0]        beat00,
    output wire [17:0]        beat10,
    output wire [17:0]        beat01,
    output wire [17:0]        beat11,
    output wire [3:0]         lane00,
    output wire [3:0]         lane10,
    output wire [3:0]         lane01,
    output wire [3:0]         lane11,
    output wire [7:0]         frac_x,
    output wire [7:0]         frac_y
);
    wire [10:0] x0, y0;
    coordinate_q8_split #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT)
    ) split (
        .valid_in(valid_in), .src_x_q8(src_x_q8), .src_y_q8(src_y_q8),
        .valid_out(valid_out), .x0(x0), .y0(y0),
        .frac_x(frac_x), .frac_y(frac_y)
    );

    wire [21:0] top_left = y0 * STRIDE_PIXELS + x0;
    assign addr00 = valid_out ? top_left : 22'd0;
    assign addr10 = valid_out ? top_left + 22'd1 : 22'd0;
    assign addr01 = valid_out ? top_left + STRIDE_PIXELS : 22'd0;
    assign addr11 = valid_out ? top_left + STRIDE_PIXELS + 22'd1 : 22'd0;
    assign {beat00, lane00} = addr00;
    assign {beat10, lane10} = addr10;
    assign {beat01, lane01} = addr01;
    assign {beat11, lane11} = addr11;
endmodule
