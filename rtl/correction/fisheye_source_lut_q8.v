// OpenCV-fisheye ideal pinhole Q11.8 -> distorted source Q11.8.
// A separate synchronous, two-read-port Q2.16 scale ROM must return both
// addressed words after the input clock edge. One input may arrive per edge;
// its result appears after the following edge. K and ROM contents must be
// frame-atomic. This block does not implement/initialize the ROM itself.
module fisheye_source_lut_q8 (
    input  wire clk, rst_n,
    input  wire valid_in,
    input  wire signed [19:0] ideal_x_q8, ideal_y_q8,
    input  wire signed [19:0] src_fx_q8, src_fy_q8, src_cx_q8, src_cy_q8,
    input  wire signed [19:0] out_cx_q8, out_cy_q8,
    input  wire [21:0] inv_out_fx_q22, inv_out_fy_q22,
    output wire [9:0] rom_addr0, rom_addr1,
    input  wire [17:0] rom_scale0_q16, rom_scale1_q16,
    output reg valid_out,
    output reg signed [19:0] src_x_q8, src_y_q8
);
    wire signed [20:0] dx = {ideal_x_q8[19],ideal_x_q8} -
                            {out_cx_q8[19],out_cx_q8};
    wire signed [20:0] dy = {ideal_y_q8[19],ideal_y_q8} -
                            {out_cy_q8[19],out_cy_q8};
    wire signed [43:0] x_product = dx * $signed({1'b0,inv_out_fx_q22});
    wire signed [43:0] y_product = dy * $signed({1'b0,inv_out_fy_q22});
    wire signed [43:0] x_full = x_product >>> 12;
    wire signed [43:0] y_full = y_product >>> 12;
    wire norm_fits = (x_full[43:22] == {22{x_full[21]}}) &&
                     (y_full[43:22] == {22{y_full[21]}});
    wire signed [21:0] x = x_full[21:0], y = y_full[21:0];
    wire signed [43:0] xx = x * x, yy = y * y;
    wire signed [44:0] sum = {1'b0,xx} + {1'b0,yy};
    wire signed [44:0] r2_full = sum >>> 18;
    wire radius_fits = r2_full >= 0 && r2_full < (45'sd8 <<< 18);
    wire address_valid = valid_in && norm_fits && radius_fits;
    assign rom_addr0 = address_valid ? {1'b0,r2_full[20:12]} : 10'd0;
    assign rom_addr1 = rom_addr0 + 10'd1;

    reg meta_valid;
    reg signed [21:0] x_meta, y_meta;
    reg [11:0] fraction_meta;
    reg signed [19:0] fx_meta, fy_meta, cx_meta, cy_meta;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_valid <= 0;
            x_meta <= 0; y_meta <= 0;
            fraction_meta <= 0;
            fx_meta <= 0; fy_meta <= 0;
            cx_meta <= 0; cy_meta <= 0;
        end else begin
            meta_valid <= address_valid;
            x_meta <= x; y_meta <= y;
            fraction_meta <= r2_full[11:0];
            fx_meta <= src_fx_q8; fy_meta <= src_fy_q8;
            cx_meta <= src_cx_q8; cy_meta <= src_cy_q8;
        end
    end

    wire signed [18:0] scale_delta =
        $signed({1'b0,rom_scale1_q16}) - $signed({1'b0,rom_scale0_q16});
    wire signed [31:0] interp_product =
        scale_delta * $signed({1'b0,fraction_meta});
    wire signed [31:0] scale_full =
        $signed({14'd0,rom_scale0_q16}) + (interp_product >>> 12);
    wire signed [19:0] scale_q16 = scale_full[19:0];
    wire signed [41:0] x_scaled = x_meta * scale_q16;
    wire signed [41:0] y_scaled = y_meta * scale_q16;
    wire signed [25:0] xd = x_scaled >>> 16;
    wire signed [25:0] yd = y_scaled >>> 16;
    wire signed [45:0] source_x_product = fx_meta * xd;
    wire signed [45:0] source_y_product = fy_meta * yd;
    wire signed [45:0] cx_extended = {{26{cx_meta[19]}},cx_meta};
    wire signed [45:0] cy_extended = {{26{cy_meta[19]}},cy_meta};
    wire signed [45:0] sx = (source_x_product >>> 18) +
                            cx_extended;
    wire signed [45:0] sy = (source_y_product >>> 18) +
                            cy_extended;
    wire output_fits = (sx[45:20] == {26{sx[19]}}) &&
                       (sy[45:20] == {26{sy[19]}});
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 0;
            src_x_q8 <= 0; src_y_q8 <= 0;
        end else begin
            valid_out <= meta_valid && output_fits;
            src_x_q8 <= meta_valid && output_fits ? sx[19:0] : 20'sd0;
            src_y_q8 <= meta_valid && output_fits ? sy[19:0] : 20'sd0;
        end
    end
endmodule
