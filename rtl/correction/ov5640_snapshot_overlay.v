`timescale 1ns/1ps

// Small HDMI diagnostic overlay for the OV5640 register snapshot.
//
// The overlay is intentionally text-free and deterministic: the first 14
// rows correspond to the register order in ov5640_sccb_snapshot.v, and each
// row contains eight 32-pixel bit cells, MSB on the left. A green cell is a
// one, a red cell is a zero, and gray means the snapshot is not valid yet.
// This module does not alter the production video path by itself.

module ov5640_snapshot_overlay #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720
) (
    input  wire         pix_clk,
    input  wire         rst_n,
    input  wire         timing_de,
    input  wire [11:0]  timing_x,
    input  wire [11:0]  timing_y,
    input  wire         snapshot_valid,
    input  wire [111:0] snapshot_data,
    input  wire [7:0]   base_r,
    input  wire [7:0]   base_g,
    input  wire [7:0]   base_b,
    output wire         overlay_on,
    output wire [7:0]   out_r,
    output wire [7:0]   out_g,
    output wire [7:0]   out_b
);

    reg [111:0] data_sync1;
    reg [111:0] data_sync2;
    reg         valid_sync1;
    reg         valid_sync2;
    wire [3:0]  row_index = timing_y[7:4];
    wire [2:0]  bit_index = timing_x[7:5];
    wire        in_panel = timing_x < 12'd256 && timing_y < 12'd224;
    wire        selected_bit = data_sync2[row_index*8 + (3'd7 - bit_index)];

    assign overlay_on = timing_de && in_panel;
    assign out_r = !overlay_on ? base_r :
                   !valid_sync2 ? 8'd64 :
                   selected_bit ? 8'd0 : 8'd255;
    assign out_g = !overlay_on ? base_g :
                   !valid_sync2 ? 8'd64 :
                   selected_bit ? 8'd255 : 8'd0;
    assign out_b = !overlay_on ? base_b :
                   !valid_sync2 ? 8'd64 : 8'd0;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            data_sync1  <= 112'd0;
            data_sync2  <= 112'd0;
            valid_sync1 <= 1'b0;
            valid_sync2 <= 1'b0;
        end else begin
            data_sync1  <= snapshot_data;
            data_sync2  <= data_sync1;
            valid_sync1 <= snapshot_valid;
            valid_sync2 <= valid_sync1;
        end
    end

endmodule
