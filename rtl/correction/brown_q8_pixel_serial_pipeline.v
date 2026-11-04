// Output pixel -> inverse affine -> Brown k1/k2/p1/p2 -> one RGB565 pixel.
// This is a single-pixel DDR transaction baseline, not a streaming video pipe.
// The host must keep coefficients stable around each accepted input pixel;
// frame-atomic parameter updates, real HMIC IP and cache are outside this top.
module brown_q8_pixel_serial_pipeline (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [10:0]  out_x,
    input  wire [10:0]  out_y,
    input  wire signed [21:0] a00_q20, a01_q20, a10_q20, a11_q20,
    input  wire signed [19:0] tx_q8, ty_q8,
    input  wire signed [19:0] fx_q8, fy_q8, cx_q8, cy_q8,
    input  wire [21:0]  inv_fx_q22, inv_fy_q22,
    input  wire signed [21:0] k1_q18, k2_q18, p1_q18, p2_q18,
    input  wire [27:0]  frame_base_ctrl_addr,
    output wire         req_valid,
    input  wire         req_ready,
    output wire [27:0]  req_addr,
    input  wire         rsp_valid,
    input  wire [255:0] rsp_data,
    input  wire         rsp_error,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [15:0]  out_pixel,
    output wire         out_error
);
    wire affine_valid, brown_valid;
    wire signed [19:0] ideal_x_q8, ideal_y_q8;
    wire signed [19:0] brown_x_q8, brown_y_q8;
    wire signed [19:0] source_x_q8 = brown_valid ? brown_x_q8 : -20'sd1;
    wire signed [19:0] source_y_q8 = brown_valid ? brown_y_q8 : -20'sd1;

    inverse_affine_q8 affine (
        .valid_in(in_valid), .out_x(out_x), .out_y(out_y),
        .a00_q20(a00_q20), .a01_q20(a01_q20),
        .a10_q20(a10_q20), .a11_q20(a11_q20),
        .tx_q8(tx_q8), .ty_q8(ty_q8),
        .valid_out(affine_valid), .ideal_x_q8(ideal_x_q8),
        .ideal_y_q8(ideal_y_q8)
    );
    brown_source_q8 brown (
        .valid_in(affine_valid), .ideal_x_q8(ideal_x_q8),
        .ideal_y_q8(ideal_y_q8), .fx_q8(fx_q8), .fy_q8(fy_q8),
        .cx_q8(cx_q8), .cy_q8(cy_q8),
        .inv_fx_q22(inv_fx_q22), .inv_fy_q22(inv_fy_q22),
        .k1_q18(k1_q18), .k2_q18(k2_q18),
        .p1_q18(p1_q18), .p2_q18(p2_q18),
        .valid_out(brown_valid), .src_x_q8(brown_x_q8),
        .src_y_q8(brown_y_q8)
    );
    q8_pixel_serial_pipeline pixel (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(in_ready),
        .src_x_q8(source_x_q8), .src_y_q8(source_y_q8),
        .frame_base_ctrl_addr(frame_base_ctrl_addr),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_error(rsp_error),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_pixel(out_pixel), .out_error(out_error)
    );
endmodule
