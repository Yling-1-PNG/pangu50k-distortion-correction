// Elastic, one-pixel-per-cycle inverse-affine + Brown coordinate mapper.
// Arithmetic and truncation intentionally mirror inverse_affine_q8 and
// brown_source_q8. The eleven registered stages separate the long multiply
// chain; all map parameters are captured with the accepted pixel.
module brown_affine_source_pipeline #(
    parameter integer IDENTITY_MAP_DIAGNOSTIC = 0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire in_valid,
    output wire in_ready,
    input  wire [10:0] out_x,
    input  wire [10:0] out_y,
    input  wire signed [21:0] a00_q20, a01_q20, a10_q20, a11_q20,
    input  wire signed [19:0] tx_q8, ty_q8,
    input  wire signed [19:0] fx_q8, fy_q8, cx_q8, cy_q8,
    input  wire [21:0] inv_fx_q22, inv_fy_q22,
    input  wire signed [21:0] k1_q18, k2_q18, p1_q18, p2_q18,
    output wire out_valid,
    output wire map_valid,
    output wire pipe_empty,
    input  wire out_ready,
    output wire signed [19:0] src_x_q8, src_y_q8
);
    reg [10:0] token_pipe, map_pipe;
    reg [120:0] identity_x_pipe, identity_y_pipe;
    wire pipe_advance = !token_pipe[10] || out_ready;
    assign in_ready = rst_n && pipe_advance;
    assign out_valid = token_pipe[10];
    assign map_valid = IDENTITY_MAP_DIAGNOSTIC != 0 ? token_pipe[10] : map_pipe[10];
    assign pipe_empty = token_pipe == 11'd0;

    wire affine_valid;
    wire signed [19:0] affine_x_q8, affine_y_q8;
    inverse_affine_q8 affine (
        .valid_in(in_valid && in_ready), .out_x(out_x), .out_y(out_y),
        .a00_q20(a00_q20), .a01_q20(a01_q20),
        .a10_q20(a10_q20), .a11_q20(a11_q20),
        .tx_q8(tx_q8), .ty_q8(ty_q8),
        .valid_out(affine_valid), .ideal_x_q8(affine_x_q8),
        .ideal_y_q8(affine_y_q8)
    );

    // Stage 0: register inverse-affine output and this pixel's Brown K/D.
    reg signed [19:0] s0_x, s0_y;
    reg signed [19:0] s0_fx, s0_fy, s0_cx, s0_cy;
    reg [21:0] s0_inv_fx, s0_inv_fy;
    reg signed [21:0] s0_k1, s0_k2, s0_p1, s0_p2;

    // Stage 1: split the inverse-focal normalization multiply. The zero
    // extended high half preserves the original positive 23-bit operand.
    wire signed [20:0] s1_dx = {s0_x[19],s0_x} - {s0_cx[19],s0_cx};
    wire signed [20:0] s1_dy = {s0_y[19],s0_y} - {s0_cy[19],s0_cy};
    wire signed [37:0] s1_x_low_product =
        s1_dx * $signed({1'b0,s0_inv_fx[15:0]});
    wire signed [37:0] s1_y_low_product =
        s1_dy * $signed({1'b0,s0_inv_fy[15:0]});
    wire signed [27:0] s1_x_high_product =
        s1_dx * $signed({1'b0,s0_inv_fx[21:16]});
    wire signed [27:0] s1_y_high_product =
        s1_dy * $signed({1'b0,s0_inv_fy[21:16]});
    reg signed [37:0] s1_x_low_q, s1_y_low_q;
    reg signed [27:0] s1_x_high_q, s1_y_high_q;

    // Stage 2: reconstruct the exact normalization product, shift to Q18,
    // and apply the original signed-fit gate.
    wire signed [43:0] s1_x_product =
        {{6{s1_x_low_q[37]}},s1_x_low_q} +
        {{16{s1_x_high_q[27]}},s1_x_high_q,16'b0};
    wire signed [43:0] s1_y_product =
        {{6{s1_y_low_q[37]}},s1_y_low_q} +
        {{16{s1_y_high_q[27]}},s1_y_high_q,16'b0};
    wire signed [43:0] s1_x_full = s1_x_product >>> 12;
    wire signed [43:0] s1_y_full = s1_y_product >>> 12;
    wire s1_norm_fits = (s1_x_full[43:22] == {22{s1_x_full[21]}}) &&
                        (s1_y_full[43:22] == {22{s1_y_full[21]}});
    wire signed [21:0] s1_x = s1_x_full[21:0];
    wire signed [21:0] s1_y = s1_y_full[21:0];
    reg s1_valid;
    reg signed [21:0] s1_x_q18, s1_y_q18;
    reg signed [19:0] s1_fx, s1_fy, s1_cx, s1_cy;
    reg signed [21:0] s1_k1, s1_k2, s1_p1, s1_p2;
    reg signed [19:0] s1_norm_fx, s1_norm_fy, s1_norm_cx, s1_norm_cy;
    reg signed [21:0] s1_norm_k1, s1_norm_k2, s1_norm_p1, s1_norm_p2;

    // Stage 2: split x*x and y*y into low/high partial products. This keeps
    // the 22x22 square from becoming one long APM cascade before the radius
    // guard. The registered partial products reconstruct the exact product
    // in stage 3.
    wire signed [32:0] s2_x_low_product =
        s1_x_q18 * $signed({1'b0,s1_x_q18[10:0]});
    wire signed [32:0] s2_y_low_product =
        s1_y_q18 * $signed({1'b0,s1_y_q18[10:0]});
    wire signed [32:0] s2_x_high_product =
        s1_x_q18 * $signed(s1_x_q18[21:11]);
    wire signed [32:0] s2_y_high_product =
        s1_y_q18 * $signed(s1_y_q18[21:11]);
    reg s2_valid;
    reg signed [32:0] s2_x_low_q, s2_y_low_q;
    reg signed [32:0] s2_x_high_q, s2_y_high_q;
    reg signed [21:0] s2_x, s2_y;
    reg signed [19:0] s2_fx, s2_fy, s2_cx, s2_cy;
    reg signed [21:0] s2_k1, s2_k2, s2_p1, s2_p2;

    // Stage 3: reconstruct the exact squares, apply the radius guard, and
    // register the Q18 radius for the Brown polynomial stage.
    wire signed [54:0] s3_x_product =
        {{22{s2_x_low_q[32]}},s2_x_low_q} +
        {{11{s2_x_high_q[32]}},s2_x_high_q,11'b0};
    wire signed [54:0] s3_y_product =
        {{22{s2_y_low_q[32]}},s2_y_low_q} +
        {{11{s2_y_high_q[32]}},s2_y_high_q,11'b0};
    wire signed [43:0] s3_xx = s3_x_product[43:0];
    wire signed [43:0] s3_yy = s3_y_product[43:0];
    wire signed [44:0] s3_sum = {1'b0,s3_xx} + {1'b0,s3_yy};
    wire signed [44:0] s3_r2_full = s3_sum >>> 18;
    wire s3_radius_fits = s3_r2_full < 45'sd2097152;
    reg s3_valid;
    reg signed [21:0] s3_x, s3_y, s3_r2;
    reg signed [19:0] s3_fx, s3_fy, s3_cx, s3_cy;
    reg signed [21:0] s3_k1, s3_k2, s3_p1, s3_p2;

    // Stage 4: parallel polynomial products. Every path has at most one
    // multiply before this register.
    wire signed [43:0] s4_r4_product = s3_r2 * s3_r2;
    wire signed [43:0] s4_kr2_product = s3_k1 * s3_r2;
    wire signed [43:0] s4_p1y_product = s3_p1 * s3_y;
    wire signed [43:0] s4_p2x_product = s3_p2 * s3_x;
    wire signed [43:0] s4_p2r2_product = s3_p2 * s3_r2;
    wire signed [43:0] s4_p1r2_product = s3_p1 * s3_r2;
    wire signed [25:0] s4_r4 = s4_r4_product >>> 18;
    wire signed [25:0] s4_kr2 = s4_kr2_product >>> 18;
    wire signed [25:0] s4_p1y = s4_p1y_product >>> 18;
    wire signed [25:0] s4_p2x = s4_p2x_product >>> 18;
    wire signed [25:0] s4_p2r2 = s4_p2r2_product >>> 18;
    wire signed [25:0] s4_p1r2 = s4_p1r2_product >>> 18;
    wire signed [26:0] s4_t = {s4_p1y[25],s4_p1y} + {s4_p2x[25],s4_p2x};
    reg s4_valid;
    reg signed [25:0] s4_r4_q, s4_kr2_q, s4_p2r2_q, s4_p1r2_q;
    reg signed [26:0] s4_t_q;
    reg signed [21:0] s4_x, s4_y, s4_k2;
    reg signed [19:0] s4_fx, s4_fy, s4_cx, s4_cy;

    // Stage 5: final radial term and common tangential factor.
    wire signed [47:0] s5_kr4_product = s4_k2 * s4_r4_q;
    wire signed [29:0] s5_kr4 = s5_kr4_product >>> 18;
    wire signed [31:0] s5_radial = 32'sd262144 +
        {{6{s4_kr2_q[25]}},s4_kr2_q} + {{2{s5_kr4[29]}},s5_kr4};
    wire signed [31:0] s5_t_extended = {{5{s4_t_q[26]}},s4_t_q};
    wire signed [31:0] s5_common = s5_radial + (s5_t_extended <<< 1);
    reg s5_valid;
    reg signed [31:0] s5_common_q;
    reg signed [25:0] s5_p2r2, s5_p1r2;
    reg signed [21:0] s5_x, s5_y;
    reg signed [19:0] s5_fx, s5_fy, s5_cx, s5_cy;

    // Stage 6: split the wide signed multiply into 16-bit partial products.
    wire signed [38:0] s6_x_low_product =
        s5_x * $signed({1'b0,s5_common_q[15:0]});
    wire signed [38:0] s6_y_low_product =
        s5_y * $signed({1'b0,s5_common_q[15:0]});
    wire signed [37:0] s6_x_high_product =
        s5_x * $signed(s5_common_q[31:16]);
    wire signed [37:0] s6_y_high_product =
        s5_y * $signed(s5_common_q[31:16]);
    reg s6_valid;
    reg signed [38:0] s6_x_low_q, s6_y_low_q;
    reg signed [37:0] s6_x_high_q, s6_y_high_q;
    reg signed [25:0] s6_p2r2, s6_p1r2;
    reg signed [19:0] s6_fx, s6_fy, s6_cx, s6_cy;

    // Stage 7: exact partial-product reduction and tangential offset.
    wire signed [53:0] s7_x_product =
        {{15{s6_x_low_q[38]}},s6_x_low_q} + {s6_x_high_q,16'b0};
    wire signed [53:0] s7_y_product =
        {{15{s6_y_low_q[38]}},s6_y_low_q} + {s6_y_high_q,16'b0};
    wire signed [35:0] s7_x_common = s7_x_product >>> 18;
    wire signed [35:0] s7_y_common = s7_y_product >>> 18;
    wire signed [36:0] s7_xd = {s7_x_common[35],s7_x_common} +
                                {{11{s6_p2r2[25]}},s6_p2r2};
    wire signed [36:0] s7_yd = {s7_y_common[35],s7_y_common} +
                                {{11{s6_p1r2[25]}},s6_p1r2};
    reg s7_valid;
    reg signed [36:0] s7_xd_q, s7_yd_q;
    reg signed [19:0] s7_fx, s7_fy, s7_cx, s7_cy;

    // Stage 8: keep the complete signed focal product in one expression.
    // PDS 2022.2-SP1's mapped functional check diverges for the former
    // split/recombine form; this equivalent form matches the Q8 oracle.
    // Retain the stage-9 reduction and token latency for the downstream queue.
    wire signed [56:0] s8_x_low_product =
        s7_xd_q * s7_fx;
    wire signed [56:0] s8_y_low_product =
        s7_yd_q * s7_fy;
    wire signed [56:0] s8_x_high_product =
        57'sd0;
    wire signed [56:0] s8_y_high_product =
        57'sd0;
    reg s8_valid;
    reg signed [56:0] s8_x_low_q, s8_y_low_q;
    reg signed [56:0] s8_x_high_q, s8_y_high_q;
    reg signed [19:0] s8_cx, s8_cy;

    // Stage 9: reconstruct the focal product and apply principal-point
    // translation. This is the final coordinate guard before map_valid.
    wire signed [72:0] s9_x_product =
        {{16{s8_x_low_q[56]}},s8_x_low_q} + {s8_x_high_q,16'b0};
    wire signed [72:0] s9_y_product =
        {{16{s8_y_low_q[56]}},s8_y_low_q} + {s8_y_high_q,16'b0};
    wire signed [72:0] s9_x_full = s9_x_product >>> 18;
    wire signed [72:0] s9_y_full = s9_y_product >>> 18;
    wire signed [72:0] s9_x = s9_x_full + {{53{s8_cx[19]}},s8_cx};
    wire signed [72:0] s9_y = s9_y_full + {{53{s8_cy[19]}},s8_cy};
    wire s9_output_fits = (s9_x[72:20] == {53{s9_x[19]}}) &&
                          (s9_y[72:20] == {53{s9_y[19]}});
    reg signed [19:0] out_x_reg, out_y_reg;
    // The diagnostic path reuses the accepted output pixel coordinate as a
    // Q8 source coordinate.  The 11-bit pixel coordinate occupies bits
    // [120:110] after the eleven-token shift; keep all 11 bits and append
    // eight fractional zeros to form the 20-bit signed Q8 value.
    assign src_x_q8 = IDENTITY_MAP_DIAGNOSTIC != 0 ?
                      {1'b0, identity_x_pipe[120:110], 8'b0} :
                      (map_pipe[10] ? out_x_reg : 20'sd0);
    assign src_y_q8 = IDENTITY_MAP_DIAGNOSTIC != 0 ?
                      {1'b0, identity_y_pipe[120:110], 8'b0} :
                      (map_pipe[10] ? out_y_reg : 20'sd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            token_pipe <= 11'd0;
            map_pipe <= 11'd0;
            identity_x_pipe <= 121'd0;
            identity_y_pipe <= 121'd0;
            s1_x_low_q <= 38'sd0;
            s1_y_low_q <= 38'sd0;
            s1_x_high_q <= 28'sd0;
            s1_y_high_q <= 28'sd0;
            s1_norm_fx <= 20'sd0; s1_norm_fy <= 20'sd0;
            s1_norm_cx <= 20'sd0; s1_norm_cy <= 20'sd0;
            s1_norm_k1 <= 22'sd0; s1_norm_k2 <= 22'sd0;
            s1_norm_p1 <= 22'sd0; s1_norm_p2 <= 22'sd0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            s5_valid <= 1'b0;
            s6_valid <= 1'b0;
            s7_valid <= 1'b0;
            s8_valid <= 1'b0;
            out_x_reg <= 20'sd0;
            out_y_reg <= 20'sd0;
        end else if (pipe_advance) begin
            token_pipe[0] <= in_valid && in_ready;
            token_pipe[10:1] <= token_pipe[9:0];
            identity_x_pipe <= {identity_x_pipe[109:0], out_x};
            identity_y_pipe <= {identity_y_pipe[109:0], out_y};
            map_pipe[0] <= affine_valid;
            map_pipe[10:1] <= map_pipe[9:0];
            s1_valid <= map_pipe[1] && s1_norm_fits;
            s2_valid <= s1_valid;
            s3_valid <= s2_valid && s3_radius_fits;
            s4_valid <= s3_valid;
            s5_valid <= s4_valid;
            s6_valid <= s5_valid;
            s7_valid <= s6_valid;
            s8_valid <= s7_valid;
            map_pipe[10] <= s8_valid && s9_output_fits;

            s0_x <= affine_x_q8; s0_y <= affine_y_q8;
            s0_fx <= fx_q8; s0_fy <= fy_q8;
            s0_cx <= cx_q8; s0_cy <= cy_q8;
            s0_inv_fx <= inv_fx_q22; s0_inv_fy <= inv_fy_q22;
            s0_k1 <= k1_q18; s0_k2 <= k2_q18;
            s0_p1 <= p1_q18; s0_p2 <= p2_q18;

            s1_x_low_q <= s1_x_low_product; s1_y_low_q <= s1_y_low_product;
            s1_x_high_q <= s1_x_high_product;
            s1_y_high_q <= s1_y_high_product;
            s1_norm_fx <= s1_fx; s1_norm_fy <= s1_fy;
            s1_norm_cx <= s1_cx; s1_norm_cy <= s1_cy;
            s1_norm_k1 <= s1_k1; s1_norm_k2 <= s1_k2;
            s1_norm_p1 <= s1_p1; s1_norm_p2 <= s1_p2;

            s1_x_q18 <= s1_x; s1_y_q18 <= s1_y;
            s1_fx <= s0_fx; s1_fy <= s0_fy;
            s1_cx <= s0_cx; s1_cy <= s0_cy;
            s1_k1 <= s0_k1; s1_k2 <= s0_k2;
            s1_p1 <= s0_p1; s1_p2 <= s0_p2;

            s2_x_low_q <= s2_x_low_product; s2_y_low_q <= s2_y_low_product;
            s2_x_high_q <= s2_x_high_product;
            s2_y_high_q <= s2_y_high_product;
            s2_x <= s1_x_q18; s2_y <= s1_y_q18;
            s2_fx <= s1_norm_fx; s2_fy <= s1_norm_fy;
            s2_cx <= s1_norm_cx; s2_cy <= s1_norm_cy;
            s2_k1 <= s1_norm_k1; s2_k2 <= s1_norm_k2;
            s2_p1 <= s1_norm_p1; s2_p2 <= s1_norm_p2;

            s3_x <= s2_x; s3_y <= s2_y;
            s3_r2 <= s3_r2_full[21:0];
            s3_fx <= s2_fx; s3_fy <= s2_fy;
            s3_cx <= s2_cx; s3_cy <= s2_cy;
            s3_k1 <= s2_k1; s3_k2 <= s2_k2;
            s3_p1 <= s2_p1; s3_p2 <= s2_p2;

            s4_r4_q <= s4_r4; s4_kr2_q <= s4_kr2;
            s4_p2r2_q <= s4_p2r2; s4_p1r2_q <= s4_p1r2;
            s4_t_q <= s4_t;
            s4_x <= s3_x; s4_y <= s3_y; s4_k2 <= s3_k2;
            s4_fx <= s3_fx; s4_fy <= s3_fy;
            s4_cx <= s3_cx; s4_cy <= s3_cy;

            s5_common_q <= s5_common;
            s5_p2r2 <= s4_p2r2_q; s5_p1r2 <= s4_p1r2_q;
            s5_x <= s4_x; s5_y <= s4_y;
            s5_fx <= s4_fx; s5_fy <= s4_fy;
            s5_cx <= s4_cx; s5_cy <= s4_cy;

            s6_x_low_q <= s6_x_low_product; s6_y_low_q <= s6_y_low_product;
            s6_x_high_q <= s6_x_high_product;
            s6_y_high_q <= s6_y_high_product;
            s6_p2r2 <= s5_p2r2; s6_p1r2 <= s5_p1r2;
            s6_fx <= s5_fx; s6_fy <= s5_fy;
            s6_cx <= s5_cx; s6_cy <= s5_cy;

            s7_xd_q <= s7_xd; s7_yd_q <= s7_yd;
            s7_fx <= s6_fx; s7_fy <= s6_fy;
            s7_cx <= s6_cx; s7_cy <= s6_cy;

            s8_x_low_q <= s8_x_low_product;
            s8_y_low_q <= s8_y_low_product;
            s8_x_high_q <= s8_x_high_product;
            s8_y_high_q <= s8_y_high_product;
            s8_cx <= s7_cx;
            s8_cy <= s7_cy;

            out_x_reg <= s8_valid && s9_output_fits ? s9_x[19:0] : 20'sd0;
            out_y_reg <= s8_valid && s9_output_fits ? s9_y[19:0] : 20'sd0;
        end
    end
endmodule
