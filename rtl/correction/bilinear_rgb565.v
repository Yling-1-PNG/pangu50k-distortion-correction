// Four-neighbour RGB565 interpolation. Fractions are unsigned Q0.8:
// 0 selects the left/top sample; 255 is 255/256 of a pixel step.
// Samples are p00=top-left, p10=top-right, p01=bottom-left, p11=bottom-right.
// Three clocks from valid_in to valid_out; one sample per cycle, no backpressure.
module bilinear_rgb565 (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] p00,
    input  wire [15:0] p10,
    input  wire [15:0] p01,
    input  wire [15:0] p11,
    input  wire [7:0]  frac_x,
    input  wire [7:0]  frac_y,
    output reg         valid_out,
    output reg  [15:0] pixel_out
);
    // Stage 1 registers samples and interpolation weights. Computing the
    // x-complement here keeps its subtractor out of the multiplier input path.
    reg [15:0] p00_stage1, p10_stage1, p01_stage1, p11_stage1;
    reg [7:0] frac_x_stage1, frac_y_stage1;
    reg [8:0] frac_x_left_stage1;
    reg valid_stage1;

    // Stage 2: interpolate horizontally, retaining the Q0.8 scale.
    function [14:0] horizontal_interpolate;
        input [5:0] a, b;
        input [8:0] left;
        input [7:0] fx;
        begin
            horizontal_interpolate = a * left + b * {1'b0, fx};
        end
    endfunction

    function [5:0] vertical_interpolate;
        input [14:0] upper, lower;
        input [7:0] fy;
        reg [8:0] top;
        reg [22:0] weighted;
        begin
            top = 9'd256 - {1'b0, fy};
            weighted = upper * top + lower * {1'b0, fy};
            vertical_interpolate = weighted[21:16];
        end
    endfunction

    reg [14:0] upper_red, lower_red;
    reg [14:0] upper_green, lower_green;
    reg [14:0] upper_blue, lower_blue;
    reg [7:0] frac_y_stage2;
    reg valid_stage2;

    wire [5:0] red = vertical_interpolate(upper_red, lower_red, frac_y_stage2);
    wire [5:0] green = vertical_interpolate(upper_green, lower_green, frac_y_stage2);
    wire [5:0] blue = vertical_interpolate(upper_blue, lower_blue, frac_y_stage2);

    always @(posedge clk) begin
        if (rst) begin
            p00_stage1 <= 16'd0;
            p10_stage1 <= 16'd0;
            p01_stage1 <= 16'd0;
            p11_stage1 <= 16'd0;
            frac_x_stage1 <= 8'd0;
            frac_y_stage1 <= 8'd0;
            frac_x_left_stage1 <= 9'd256;
            valid_stage1 <= 1'b0;
            valid_stage2 <= 1'b0;
            valid_out <= 1'b0;
            pixel_out <= 16'b0;
            upper_red <= 15'd0;
            lower_red <= 15'd0;
            upper_green <= 15'd0;
            lower_green <= 15'd0;
            upper_blue <= 15'd0;
            lower_blue <= 15'd0;
            frac_y_stage2 <= 8'd0;
        end else begin
            valid_stage1 <= valid_in;
            valid_stage2 <= valid_stage1;
            valid_out <= valid_stage2;
            if (valid_in) begin
                p00_stage1 <= p00;
                p10_stage1 <= p10;
                p01_stage1 <= p01;
                p11_stage1 <= p11;
                frac_x_stage1 <= frac_x;
                frac_x_left_stage1 <= 9'd256 - {1'b0, frac_x};
                frac_y_stage1 <= frac_y;
            end
            if (valid_stage1) begin
                upper_red <= horizontal_interpolate(
                    {1'b0, p00_stage1[15:11]}, {1'b0, p10_stage1[15:11]},
                    frac_x_left_stage1, frac_x_stage1);
                lower_red <= horizontal_interpolate(
                    {1'b0, p01_stage1[15:11]}, {1'b0, p11_stage1[15:11]},
                    frac_x_left_stage1, frac_x_stage1);
                upper_green <= horizontal_interpolate(
                    p00_stage1[10:5], p10_stage1[10:5],
                    frac_x_left_stage1, frac_x_stage1);
                lower_green <= horizontal_interpolate(
                    p01_stage1[10:5], p11_stage1[10:5],
                    frac_x_left_stage1, frac_x_stage1);
                upper_blue <= horizontal_interpolate(
                    {1'b0, p00_stage1[4:0]}, {1'b0, p10_stage1[4:0]},
                    frac_x_left_stage1, frac_x_stage1);
                lower_blue <= horizontal_interpolate(
                    {1'b0, p01_stage1[4:0]}, {1'b0, p11_stage1[4:0]},
                    frac_x_left_stage1, frac_x_stage1);
                frac_y_stage2 <= frac_y_stage1;
            end
            if (valid_stage2)
                pixel_out <= {red[4:0], green, blue[4:0]};
        end
    end
endmodule
