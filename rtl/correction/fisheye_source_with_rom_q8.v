// Arithmetic stage plus the synchronous candidate scale ROM. K, reciprocal
// output focal length and table selection must remain frame-atomic. This is
// not connected to the camera/DDR/HDMI stream or a parameter-update protocol.
module fisheye_source_with_rom_q8 #(
    parameter INIT_FILE = "../../rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter INIT_FILE_HI = "../../rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem"
) (
    input  wire clk, rst_n,
    input  wire valid_in,
    input  wire signed [19:0] ideal_x_q8, ideal_y_q8,
    input  wire signed [19:0] src_fx_q8, src_fy_q8, src_cx_q8, src_cy_q8,
    input  wire signed [19:0] out_cx_q8, out_cy_q8,
    input  wire [21:0] inv_out_fx_q22, inv_out_fy_q22,
    output wire valid_out,
    output wire signed [19:0] src_x_q8, src_y_q8
);
    wire [9:0] addr0, addr1;
    wire [17:0] scale0_q16, scale1_q16;
    fisheye_scale_rom_q16 #(.INIT_FILE(INIT_FILE), .INIT_FILE_HI(INIT_FILE_HI)) scale_rom (
        .clk(clk), .addr0(addr0), .addr1(addr1),
        .scale0_q16(scale0_q16), .scale1_q16(scale1_q16)
    );
    fisheye_source_lut_q8 map (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .ideal_x_q8(ideal_x_q8), .ideal_y_q8(ideal_y_q8),
        .src_fx_q8(src_fx_q8), .src_fy_q8(src_fy_q8),
        .src_cx_q8(src_cx_q8), .src_cy_q8(src_cy_q8),
        .out_cx_q8(out_cx_q8), .out_cy_q8(out_cy_q8),
        .inv_out_fx_q22(inv_out_fx_q22), .inv_out_fy_q22(inv_out_fy_q22),
        .rom_addr0(addr0), .rom_addr1(addr1),
        .rom_scale0_q16(scale0_q16), .rom_scale1_q16(scale1_q16),
        .valid_out(valid_out), .src_x_q8(src_x_q8), .src_y_q8(src_y_q8)
    );
endmodule
