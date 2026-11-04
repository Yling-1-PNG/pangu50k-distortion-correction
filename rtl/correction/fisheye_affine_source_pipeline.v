// Elastic, one-pixel-per-cycle inverse-affine + OpenCV-fisheye mapper.
// The affine, normalization, radius/ROM, scale interpolation, normalized
// scaling, and source-K stages are separated. Arithmetic and truncation match
// inverse_affine_q8 + fisheye_source_with_rom_q8. Parameters travel with each
// accepted pixel. The ROM has an enable so its synchronous data stays aligned
// when the elastic pipeline is stalled.
module fisheye_affine_source_pipeline #(
    parameter INIT_FILE = "rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter INIT_FILE_HI = "rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter INIT_FILE_DELTA = "rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem",
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
    input  wire signed [19:0] src_fx_q8, src_fy_q8, src_cx_q8, src_cy_q8,
    input  wire signed [19:0] out_cx_q8, out_cy_q8,
    input  wire [21:0] inv_out_fx_q22, inv_out_fy_q22,
    output wire out_valid,
    output wire map_valid,
    output wire pipe_empty,
    input  wire out_ready,
    output wire signed [19:0] src_x_q8, src_y_q8
);
    reg [10:0] token_pipe;
    reg [10:0] map_pipe;
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

    // Stage 0: latch the affine result and fish-eye model parameters.
    reg signed [19:0] s0_ideal_x, s0_ideal_y;
    reg signed [19:0] s0_src_fx, s0_src_fy, s0_src_cx, s0_src_cy;
    reg signed [19:0] s0_out_cx, s0_out_cy;
    reg [21:0] s0_inv_out_fx, s0_inv_out_fy;

    // Stage 1: compute low/high partial products for output-camera normalization.
    wire signed [20:0] s1_dx = {s0_ideal_x[19],s0_ideal_x} -
                                {s0_out_cx[19],s0_out_cx};
    wire signed [20:0] s1_dy = {s0_ideal_y[19],s0_ideal_y} -
                                {s0_out_cy[19],s0_out_cy};
    // Keep only the multipliers in this stage; reconstruction and Q12 shift
    // are registered in stage 2 to avoid a multiplier-plus-wide-adder cone.
    wire signed [31:0] s1_x_product_lo =
        s1_dx * $signed({1'b0,s0_inv_out_fx[10:0]});
    wire signed [31:0] s1_x_product_hi =
        s1_dx * $signed({1'b0,s0_inv_out_fx[21:11]});
    wire signed [31:0] s1_y_product_lo =
        s1_dy * $signed({1'b0,s0_inv_out_fy[10:0]});
    wire signed [31:0] s1_y_product_hi =
        s1_dy * $signed({1'b0,s0_inv_out_fy[21:11]});
    reg s1_valid;
    reg signed [31:0] s1_x_product_lo_q, s1_x_product_hi_q;
    reg signed [31:0] s1_y_product_lo_q, s1_y_product_hi_q;
    reg signed [19:0] s1_src_fx, s1_src_fy, s1_src_cx, s1_src_cy;

    // Stage 2: reconstruct the exact 21x22 products, shift to Q18, and check
    // the same signed range as the original combined multiply.
    wire signed [43:0] s2_x_product =
        {{12{s1_x_product_lo_q[31]}},s1_x_product_lo_q} +
        {{1{s1_x_product_hi_q[31]}},s1_x_product_hi_q,11'b0};
    wire signed [43:0] s2_y_product =
        {{12{s1_y_product_lo_q[31]}},s1_y_product_lo_q} +
        {{1{s1_y_product_hi_q[31]}},s1_y_product_hi_q,11'b0};
    wire signed [43:0] s2_x_full = s2_x_product >>> 12;
    wire signed [43:0] s2_y_full = s2_y_product >>> 12;
    wire s2_norm_fits = (s2_x_full[43:22] == {22{s2_x_full[21]}}) &&
                        (s2_y_full[43:22] == {22{s2_y_full[21]}});
    reg s2_valid;
    reg signed [21:0] s2_x_q18, s2_y_q18;
    reg signed [19:0] s2_src_fx, s2_src_fy, s2_src_cx, s2_src_cy;

    // Stage 3: square the normalized coordinates. Register the products
    // before radius accumulation/address generation to break the long
    // multiply-add-to-ROM-address path.
    wire signed [43:0] s3_xx = s2_x_q18 * s2_x_q18;
    wire signed [43:0] s3_yy = s2_y_q18 * s2_y_q18;
    reg s3_valid;
    reg signed [43:0] s3_xx_q, s3_yy_q;
    reg signed [21:0] s3_x, s3_y;
    reg signed [19:0] s3_src_fx, s3_src_fy, s3_src_cx, s3_src_cy;

    // Stage 4: radius accumulation and scale-ROM address. The ROM samples
    // the computed addresses on this edge.
    wire signed [44:0] s4_sum = {1'b0,s3_xx_q} + {1'b0,s3_yy_q};
    wire signed [44:0] s4_r2_full = s4_sum >>> 18;
    wire s4_radius_fits = s4_r2_full >= 0 && s4_r2_full < (45'sd8 <<< 18);
    wire s4_address_valid = s3_valid && s4_radius_fits;
    wire [9:0] rom_addr0 = s4_address_valid ? {1'b0,s4_r2_full[20:12]} : 10'd0;
    wire [17:0] rom_scale0_q16;
    wire signed [11:0] rom_scale_delta_s12;
    reg s4_valid;
    reg signed [21:0] s4_x, s4_y;
    reg [11:0] s4_fraction;
    reg signed [19:0] s4_src_fx, s4_src_fy, s4_src_cx, s4_src_cy;
    fisheye_scale_rom_q16_ce #(
        .INIT_FILE(INIT_FILE), .INIT_FILE_HI(INIT_FILE_HI),
        .INIT_FILE_DELTA(INIT_FILE_DELTA)
    ) scale_rom (
        .clk(clk), .enable(pipe_advance), .addr0(rom_addr0),
        .scale0_q16(rom_scale0_q16), .scale_delta_s12(rom_scale_delta_s12)
    );

    // Adjacent-table deltas are generated and range-checked offline. Reading
    // the signed 12-bit delta beside the base scale removes the wide ROM-output
    // subtract/carry chain from the critical interpolation-multiply path.
    wire signed [24:0] s5_interp_product_narrow =
        $signed(rom_scale_delta_s12) * $signed({1'b0,s4_fraction});
    wire signed [31:0] s5_interp_product =
        {{7{s5_interp_product_narrow[24]}},s5_interp_product_narrow};
    reg signed [31:0] s5_interp_product_q;
    reg [17:0] s5_scale_base_q;
    reg s5_valid;
    reg signed [21:0] s5_x, s5_y;
    reg signed [19:0] s5_src_fx, s5_src_fy, s5_src_cx, s5_src_cy;

    // Stage 6: finish radial-scale interpolation after its multiply has been
    // registered, keeping the ROM-to-multiplier cone out of the scale adder.
    wire signed [31:0] s6_scale_full =
        $signed({14'd0,s5_scale_base_q}) + (s5_interp_product_q >>> 12);
    wire signed [19:0] s6_scale_q16 = s6_scale_full[19:0];
    reg s6_valid;
    reg signed [21:0] s6_x, s6_y;
    reg signed [19:0] s6_scale;
    reg signed [19:0] s6_src_fx, s6_src_fy, s6_src_cx, s6_src_cy;

    // Stage 7: form narrow signed/unsigned partial products. Splitting the
    // 22x20 normalized-scale multiply prevents a long APM cascade in one cycle.
    wire signed [32:0] s7_x_low_product =
        s6_x * $signed({1'b0,s6_scale[9:0]});
    wire signed [32:0] s7_y_low_product =
        s6_y * $signed({1'b0,s6_scale[9:0]});
    wire signed [31:0] s7_x_high_product =
        s6_x * $signed(s6_scale[19:10]);
    wire signed [31:0] s7_y_high_product =
        s6_y * $signed(s6_scale[19:10]);
    reg s7_valid;
    reg signed [32:0] s7_x_low_q, s7_y_low_q;
    reg signed [31:0] s7_x_high_q, s7_y_high_q;
    reg signed [19:0] s7_src_fx, s7_src_fy, s7_src_cx, s7_src_cy;

    // Stage 8: reconstruct the exact signed products and retain the original
    // Q16 truncation before the source-camera focal-length multiply.
    wire signed [41:0] s8_x_product =
        {{9{s7_x_low_q[32]}},s7_x_low_q} + {s7_x_high_q,10'b0};
    wire signed [41:0] s8_y_product =
        {{9{s7_y_low_q[32]}},s7_y_low_q} + {s7_y_high_q,10'b0};
    wire signed [25:0] s8_xd = s8_x_product >>> 16;
    wire signed [25:0] s8_yd = s8_y_product >>> 16;
    reg s8_valid;
    reg signed [25:0] s8_xd_q, s8_yd_q;
    reg signed [19:0] s8_src_fx, s8_src_fy, s8_src_cx, s8_src_cy;

    // Stage 9: source-camera K multiply. Register the APM products before
    // adding the principal point so the final coordinate stage is not an
    // APM-plus-wide-adder cone.
    wire signed [45:0] s9_x_product = s8_src_fx * s8_xd_q;
    wire signed [45:0] s9_y_product = s8_src_fy * s8_yd_q;
    wire signed [45:0] s9_cx_extended = {{26{s8_src_cx[19]}},s8_src_cx};
    wire signed [45:0] s9_cy_extended = {{26{s8_src_cy[19]}},s8_src_cy};
    reg s9_valid;
    reg signed [45:0] s9_x_product_q, s9_y_product_q;
    reg signed [45:0] s9_cx_q, s9_cy_q;

    // Stage 10: finish source-coordinate reconstruction and range checking.
    wire signed [45:0] s10_x = (s9_x_product_q >>> 18) + s9_cx_q;
    wire signed [45:0] s10_y = (s9_y_product_q >>> 18) + s9_cy_q;
    wire s10_output_fits = (s10_x[45:20] == {26{s10_x[19]}}) &&
                           (s10_y[45:20] == {26{s10_y[19]}});
    reg signed [19:0] out_x_reg, out_y_reg;
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
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            s4_valid <= 1'b0;
            s5_valid <= 1'b0;
            s6_valid <= 1'b0;
            s7_valid <= 1'b0;
            s8_valid <= 1'b0;
            s9_valid <= 1'b0;
            out_x_reg <= 20'sd0;
            out_y_reg <= 20'sd0;
        end else if (pipe_advance) begin
            token_pipe[0] <= in_valid && in_ready;
            token_pipe[10:1] <= token_pipe[9:0];
            identity_x_pipe <= {identity_x_pipe[109:0], out_x};
            identity_y_pipe <= {identity_y_pipe[109:0], out_y};
            map_pipe[0] <= affine_valid;
            map_pipe[9:1] <= map_pipe[8:0];
            map_pipe[10] <= s9_valid && s10_output_fits;
            s1_valid <= map_pipe[0];
            s2_valid <= s1_valid && s2_norm_fits;
            s3_valid <= s2_valid;
            s4_valid <= s3_valid && s4_radius_fits;
            s5_valid <= s4_valid;
            s6_valid <= s5_valid;
            s7_valid <= s6_valid;
            s8_valid <= s7_valid;

            s0_ideal_x <= affine_x_q8; s0_ideal_y <= affine_y_q8;
            s0_src_fx <= src_fx_q8; s0_src_fy <= src_fy_q8;
            s0_src_cx <= src_cx_q8; s0_src_cy <= src_cy_q8;
            s0_out_cx <= out_cx_q8; s0_out_cy <= out_cy_q8;
            s0_inv_out_fx <= inv_out_fx_q22;
            s0_inv_out_fy <= inv_out_fy_q22;

            s1_x_product_lo_q <= s1_x_product_lo;
            s1_x_product_hi_q <= s1_x_product_hi;
            s1_y_product_lo_q <= s1_y_product_lo;
            s1_y_product_hi_q <= s1_y_product_hi;
            s1_src_fx <= s0_src_fx; s1_src_fy <= s0_src_fy;
            s1_src_cx <= s0_src_cx; s1_src_cy <= s0_src_cy;

            s2_x_q18 <= s2_x_full[21:0]; s2_y_q18 <= s2_y_full[21:0];
            s2_src_fx <= s1_src_fx; s2_src_fy <= s1_src_fy;
            s2_src_cx <= s1_src_cx; s2_src_cy <= s1_src_cy;

            s3_xx_q <= s3_xx; s3_yy_q <= s3_yy;
            s3_x <= s2_x_q18; s3_y <= s2_y_q18;
            s3_src_fx <= s2_src_fx; s3_src_fy <= s2_src_fy;
            s3_src_cx <= s2_src_cx; s3_src_cy <= s2_src_cy;

            s4_x <= s3_x; s4_y <= s3_y;
            s4_fraction <= s4_r2_full[11:0];
            s4_src_fx <= s3_src_fx; s4_src_fy <= s3_src_fy;
            s4_src_cx <= s3_src_cx; s4_src_cy <= s3_src_cy;

            s5_interp_product_q <= s5_interp_product;
            s5_scale_base_q <= rom_scale0_q16;
            s5_x <= s4_x; s5_y <= s4_y;
            s5_src_fx <= s4_src_fx; s5_src_fy <= s4_src_fy;
            s5_src_cx <= s4_src_cx; s5_src_cy <= s4_src_cy;

            s6_x <= s5_x; s6_y <= s5_y;
            s6_scale <= s6_scale_q16;
            s6_src_fx <= s5_src_fx; s6_src_fy <= s5_src_fy;
            s6_src_cx <= s5_src_cx; s6_src_cy <= s5_src_cy;

            s7_x_low_q <= s7_x_low_product; s7_y_low_q <= s7_y_low_product;
            s7_x_high_q <= s7_x_high_product; s7_y_high_q <= s7_y_high_product;
            s7_src_fx <= s6_src_fx; s7_src_fy <= s6_src_fy;
            s7_src_cx <= s6_src_cx; s7_src_cy <= s6_src_cy;

            s8_xd_q <= s8_xd; s8_yd_q <= s8_yd;
            s8_src_fx <= s7_src_fx; s8_src_fy <= s7_src_fy;
            s8_src_cx <= s7_src_cx; s8_src_cy <= s7_src_cy;

            s9_valid <= s8_valid;
            s9_x_product_q <= s9_x_product;
            s9_y_product_q <= s9_y_product;
            s9_cx_q <= s9_cx_extended;
            s9_cy_q <= s9_cy_extended;

            out_x_reg <= s9_valid && s10_output_fits ? s10_x[19:0] : 20'sd0;
            out_y_reg <= s9_valid && s10_output_fits ? s10_y[19:0] : 20'sd0;
        end
    end
endmodule

// Dual synchronous ROM with a common clock-enable for elastic-pipeline stalls.
module fisheye_scale_rom_q16_ce #(
    parameter INIT_FILE = "rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter INIT_FILE_HI = "rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter INIT_FILE_DELTA = "rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem"
) (
    input wire clk,
    input wire enable,
    input wire [9:0] addr0,
    output reg [17:0] scale0_q16,
    output reg signed [11:0] scale_delta_s12
);
    reg [15:0] rom_low [0:512];
    reg [3:0] rom_high [0:512];
    reg [11:0] rom_delta [0:512];
    initial begin
        $readmemh(INIT_FILE, rom_low);
        $readmemh(INIT_FILE_HI, rom_high);
        $readmemh(INIT_FILE_DELTA, rom_delta);
    end
    always @(posedge clk) begin
        if (enable) begin
            scale0_q16 <= {rom_high[addr0][1:0],rom_low[addr0]};
            scale_delta_s12 <= rom_delta[addr0];
        end
    end
endmodule
