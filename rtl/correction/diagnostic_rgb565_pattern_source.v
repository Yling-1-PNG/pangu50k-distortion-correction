`timescale 1ns/1ps

// One deterministic row-major RGB565 frame for a DDR/HDMI link diagnostic.
// The edge is white; interior colors encode both the row and column.
module diagnostic_rgb565_pattern_source #(
    parameter integer H_PIXELS = 1280,
    parameter integer V_LINES = 720
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    output wire        frame_ready,
    output wire        pixel_valid,
    input  wire        pixel_ready,
    output wire [15:0] pixel_data,
    output reg         frame_done,
    output reg         fault
);
    localparam integer SHAPE_OK = H_PIXELS > 0 && H_PIXELS <= 2048 &&
                                  V_LINES > 0 && V_LINES <= 2048;
    reg active;
    reg [10:0] x, y;
    wire pixel_fire = pixel_valid && pixel_ready;
    wire edge_pixel = x == 0 || y == 0 ||
                      x == H_PIXELS-1 || y == V_LINES-1;
    wire [4:0] red = x[4:0] ^ x[9:5];
    wire [5:0] green = y[5:0] ^ y[10:6];
    wire [4:0] blue = x[4:0] ^ y[4:0];

    assign frame_ready = SHAPE_OK && !active && !fault;
    assign pixel_valid = active && !fault;
    assign pixel_data = edge_pixel ? 16'hffff : {red, green, blue};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            x <= 11'd0;
            y <= 11'd0;
            frame_done <= 1'b0;
            fault <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (frame_start && !frame_ready) begin
                fault <= 1'b1;
                active <= 1'b0;
            end else if (frame_start) begin
                active <= 1'b1;
                x <= 11'd0;
                y <= 11'd0;
            end else if (pixel_fire) begin
                if (x == H_PIXELS-1) begin
                    x <= 11'd0;
                    if (y == V_LINES-1) begin
                        active <= 1'b0;
                        frame_done <= 1'b1;
                    end else
                        y <= y + 1'b1;
                end else
                    x <= x + 1'b1;
            end
        end
    end
endmodule
