`timescale 1ns/1ps
// Normalize the 16-bit word produced by the vendor cmos_8_16bit block to the
// RGB565 order used by the reference frame-buffer path. The valid signal is
// in pixel_clk; vsync_level is a level forwarded to the downstream pixel-clock
// synchronizer and is intentionally not sampled here.
module ov5640_rgb565_stream_adapter (
    input  wire        pixel_valid_in,
    input  wire [15:0] vendor_pixel_in,
    input  wire        vsync_level_in,
    output wire        pixel_valid_out,
    output wire [15:0] rgb565_pixel_out,
    output wire        vsync_level_out
);
    assign pixel_valid_out = pixel_valid_in;
    assign rgb565_pixel_out = {
        vendor_pixel_in[4:0],
        vendor_pixel_in[10:5],
        vendor_pixel_in[15:11]
    };
    assign vsync_level_out = vsync_level_in;
endmodule
