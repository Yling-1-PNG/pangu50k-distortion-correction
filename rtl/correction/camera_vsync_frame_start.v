`timescale 1ns/1ps
// Synchronizes the vendor camera VSYNC level into the RGB565 pixel clock
// domain and converts its rising edge into a one-cycle frame_start pulse.
// The source pulse must remain high long enough to cross the two-flop
// synchronizer; the OV5640 frame VSYNC is a level, not a one-pixel pulse.
module camera_vsync_frame_start (
    input  wire pixel_clk,
    input  wire rst_n,
    input  wire vsync_level,
    output reg  frame_start
);
    reg vsync_meta;
    reg vsync_sync;
    reg vsync_sync_d;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_meta <= 1'b0;
            vsync_sync <= 1'b0;
            vsync_sync_d <= 1'b0;
            frame_start <= 1'b0;
        end else begin
            vsync_meta <= vsync_level;
            vsync_sync <= vsync_meta;
            vsync_sync_d <= vsync_sync;
            frame_start <= vsync_sync && !vsync_sync_d;
        end
    end
endmodule
