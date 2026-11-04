`timescale 1ns/1ps
// Connect a corrected RGB565 FIFO to the pixel-domain timing signals.
// timing_* are the registered outputs of sync_vg, not its early de_re request.
// One additional output register delays RGB and sync together to the HDMI pins.
module corrected_hdmi_output #(
    parameter integer FRAME_PIXELS = 1280*720,
    parameter integer PREFILL_PIXELS = 1024
) (
    input  wire        wr_clk,
    input  wire        pix_clk,
    input  wire        rst_n,
    input  wire        wr_frame_begin,
    input  wire        wr_pixel_fire,
    input  wire        wr_frame_done,
    output wire        wr_frame_ready,
    output wire        wr_fault,
    input  wire        timing_vs,
    input  wire        timing_hs,
    input  wire        timing_de,
    input  wire        fifo_rd_valid,
    input  wire [15:0] fifo_rd_pixel,
    output wire        fifo_rd_take,
    output wire        frame_pending,
    output wire        pix_frame_done,
    output wire        pix_fault,
    output reg         hdmi_vs,
    output reg         hdmi_hs,
    output reg         hdmi_de,
    output reg  [7:0]  hdmi_r,
    output reg  [7:0]  hdmi_g,
    output reg  [7:0]  hdmi_b
);
    reg timing_vs_d;
    wire [15:0] display_pixel;

    video_frame_gate #(
        .FRAME_PIXELS(FRAME_PIXELS), .PREFILL_PIXELS(PREFILL_PIXELS)
    ) gate (
        .wr_clk(wr_clk), .pix_clk(pix_clk), .rst_n(rst_n),
        .wr_frame_begin(wr_frame_begin), .wr_pixel_fire(wr_pixel_fire),
        .wr_frame_done(wr_frame_done), .wr_frame_ready(wr_frame_ready),
        .wr_fault(wr_fault),
        .pix_frame_start(timing_vs && !timing_vs_d),
        .pix_active(timing_de),
        .fifo_rd_valid(fifo_rd_valid), .fifo_rd_pixel(fifo_rd_pixel),
        .fifo_rd_take(fifo_rd_take), .display_valid(),
        .display_pixel(display_pixel), .frame_pending(frame_pending),
        .pix_frame_done(pix_frame_done), .pix_fault(pix_fault)
    );

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            timing_vs_d <= 1'b0;
            hdmi_vs <= 1'b0;
            hdmi_hs <= 1'b0;
            hdmi_de <= 1'b0;
            hdmi_r <= 8'd0;
            hdmi_g <= 8'd0;
            hdmi_b <= 8'd0;
        end else begin
            timing_vs_d <= timing_vs;
            hdmi_vs <= timing_vs;
            hdmi_hs <= timing_hs;
            hdmi_de <= timing_de;
            hdmi_r <= {display_pixel[15:11], 3'b0};
            hdmi_g <= {display_pixel[10:5], 2'b0};
            hdmi_b <= {display_pixel[4:0], 3'b0};
        end
    end
endmodule
