// Ideal-image Q11.8 pixel -> distorted source Q11.8 pixel.
// Brown k1,k2,p1,p2 only (k3 fixed to zero). Coefficients are Q4.18.
// Host provides K (Q11.8) and 1/f (unsigned Q0.22). The radius guard
// r^2 < 8 avoids truncating an out-of-range polynomial intermediate.
// Source-frame bounds/four-neighbour validity are checked downstream.
module brown_source_q8 (
    input wire valid_in,
    input wire signed [19:0] ideal_x_q8, ideal_y_q8,
    input wire signed [19:0] fx_q8, fy_q8, cx_q8, cy_q8,
    input wire [21:0] inv_fx_q22, inv_fy_q22,
    input wire signed [21:0] k1_q18, k2_q18, p1_q18, p2_q18,
    output wire valid_out,
    output wire signed [19:0] src_x_q8, src_y_q8
);
    wire signed [20:0] dx_q8 = {ideal_x_q8[19],ideal_x_q8} - {cx_q8[19],cx_q8};
    wire signed [20:0] dy_q8 = {ideal_y_q8[19],ideal_y_q8} - {cy_q8[19],cy_q8};
    wire signed [43:0] xnorm_product = dx_q8 * $signed({1'b0,inv_fx_q22});
    wire signed [43:0] ynorm_product = dy_q8 * $signed({1'b0,inv_fy_q22});
    wire signed [43:0] xnorm_full = xnorm_product >>> 12;
    wire signed [43:0] ynorm_full = ynorm_product >>> 12;
    wire norm_fits = (xnorm_full[43:22] == {22{xnorm_full[21]}})
                  && (ynorm_full[43:22] == {22{ynorm_full[21]}});
    wire signed [21:0] x = xnorm_full[21:0], y = ynorm_full[21:0];
    wire signed [43:0] xx = x*x, yy = y*y;
    wire signed [44:0] square_sum = {1'b0,xx} + {1'b0,yy};
    wire signed [44:0] r2_full = square_sum >>> 18;
    wire radius_fits = r2_full < 45'sd2097152; // 8 in Q18
    wire signed [21:0] r2 = r2_full[21:0];
    wire signed [43:0] r4_product = r2*r2;
    wire signed [25:0] r4 = r4_product >>> 18;
    wire signed [43:0] kr2_product = k1_q18*r2;
    wire signed [47:0] kr4_product = k2_q18*r4;
    wire signed [25:0] kr2 = kr2_product >>> 18;
    wire signed [29:0] kr4 = kr4_product >>> 18;
    wire signed [31:0] radial = 32'sd262144
                              + {{6{kr2[25]}},kr2} + {{2{kr4[29]}},kr4};
    // Equivalent Brown tangential form:
    // t=p1*y+p2*x; xd=x*(radial+2*t)+p2*r2; yd=y*(radial+2*t)+p1*r2.
    // Sharing the common factor avoids the separate xy product.
    wire signed [43:0] p1y_product = p1_q18*y, p2x_product = p2_q18*x;
    wire signed [25:0] p1y = p1y_product >>> 18, p2x = p2x_product >>> 18;
    wire signed [26:0] t = {p1y[25],p1y} + {p2x[25],p2x};
    wire signed [31:0] common = radial + ({{5{t[26]}},t} <<< 1);
    wire signed [53:0] xcommon_product = x*common, ycommon_product = y*common;
    wire signed [35:0] xcommon = xcommon_product >>> 18;
    wire signed [35:0] ycommon = ycommon_product >>> 18;
    wire signed [43:0] p2r2_product = p2_q18*r2, p1r2_product = p1_q18*r2;
    wire signed [25:0] p2r2 = p2r2_product >>> 18, p1r2 = p1r2_product >>> 18;
    wire signed [36:0] xd = {xcommon[35],xcommon} + {{11{p2r2[25]}},p2r2};
    wire signed [36:0] yd = {ycommon[35],ycommon} + {{11{p1r2[25]}},p1r2};
    wire signed [56:0] src_x_product = fx_q8 * xd, src_y_product = fy_q8 * yd;
    wire signed [57:0] src_x_full = src_x_product >>> 18;
    wire signed [57:0] src_y_full = src_y_product >>> 18;
    wire signed [57:0] sx = src_x_full + {{38{cx_q8[19]}},cx_q8};
    wire signed [57:0] sy = src_y_full + {{38{cy_q8[19]}},cy_q8};
    wire output_fits = (sx[57:20] == {38{sx[19]}})
                      && (sy[57:20] == {38{sy[19]}});
    assign valid_out = valid_in && norm_fits && radius_fits && output_fits;
    assign src_x_q8 = valid_out ? sx[19:0] : 20'sd0;
    assign src_y_q8 = valid_out ? sy[19:0] : 20'sd0;
endmodule
