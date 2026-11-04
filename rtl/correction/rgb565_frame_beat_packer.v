`timescale 1ns/1ps
// Camera pixel-clock domain only. Inputs must already be aligned 16-bit RGB565
// pixels, frame_start and DE in this same clock domain. One output beat holds
// 16 pixels: earliest pixel is lane 0 (bits [15:0]). beat_last travels with
// the beat across a future CDC FIFO; frame_done is only producer-side enqueue.
// On any malformed frame/backpressure overflow, fault blocks capture until
// clear. The system must abort the DDR writer and flush frame-tagged FIFO data
// before clear; a one-cycle frame_abort pulse needs a proper CDC handshake.
module rgb565_frame_beat_packer #(
    parameter integer H_PIXELS = 1280,
    parameter integer V_LINES = 720
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    input  wire         frame_start,
    input  wire         arm,
    input  wire         pixel_valid,
    input  wire [15:0]  pixel_data,
    output reg          beat_valid,
    input  wire         beat_ready,
    output reg  [255:0] beat_data,
    output reg          beat_last,
    output reg          frame_open,
    output reg          frame_done,
    output reg          frame_abort,
    output reg          fault
);
    localparam integer XW = $clog2(H_PIXELS + 1);
    localparam integer YW = $clog2(V_LINES + 1);
    reg active, ending, in_line, final_pending, closed_frame;
    reg [XW-1:0] x_count;
    reg [YW-1:0] y_count;
    reg [3:0] pack_index;
    reg [239:0] pack_data;
    reg [255:0] final_data;
    wire beat_fire = beat_valid && beat_ready;
    wire slot_free = !beat_valid || beat_ready;
    wire [255:0] completed_data = {pixel_data, pack_data};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            ending <= 1'b0;
            in_line <= 1'b0;
            final_pending <= 1'b0;
            closed_frame <= 1'b0;
            x_count <= 0;
            y_count <= 0;
            pack_index <= 0;
            pack_data <= 0;
            final_data <= 0;
            beat_valid <= 1'b0;
            beat_data <= 0;
            beat_last <= 1'b0;
            frame_open <= 1'b0;
            frame_done <= 1'b0;
            frame_abort <= 1'b0;
            fault <= 1'b0;
        end else begin
            frame_open <= 1'b0;
            frame_done <= 1'b0;
            frame_abort <= 1'b0;
            if (clear) begin
                active <= 1'b0;
                ending <= 1'b0;
                in_line <= 1'b0;
                final_pending <= 1'b0;
                closed_frame <= 1'b0;
                x_count <= 0;
                y_count <= 0;
                pack_index <= 0;
                beat_valid <= 1'b0;
                beat_last <= 1'b0;
                fault <= 1'b0;
            end else if (!fault) begin
                if (beat_fire)
                    beat_valid <= 1'b0;
                if (frame_start) begin
                    if (active || beat_valid || pixel_valid) begin
                        fault <= 1'b1;
                        frame_abort <= active;
                        beat_valid <= 1'b0;
                        active <= 1'b0;
                        ending <= 1'b0;
                    end else begin
                        closed_frame <= 1'b0;
                        if (arm) begin
                            active <= 1'b1;
                            ending <= 1'b0;
                            in_line <= 1'b0;
                            final_pending <= 1'b0;
                            x_count <= 0;
                            y_count <= 0;
                            pack_index <= 0;
                            frame_open <= 1'b1;
                        end
                    end
                end else if (active) begin
                    if (ending) begin
                        if (pixel_valid) begin
                            fault <= 1'b1;
                            frame_abort <= 1'b1;
                            beat_valid <= 1'b0;
                            active <= 1'b0;
                            ending <= 1'b0;
                        end else if (beat_fire) begin
                            active <= 1'b0;
                            ending <= 1'b0;
                            closed_frame <= 1'b1;
                            frame_done <= 1'b1;
                        end
                    end else if (pixel_valid) begin
                        if (x_count == H_PIXELS || y_count == V_LINES) begin
                            fault <= 1'b1;
                            frame_abort <= 1'b1;
                            beat_valid <= 1'b0;
                            active <= 1'b0;
                        end else begin
                            in_line <= 1'b1;
                            x_count <= x_count + 1'b1;
                            if (pack_index == 4'd15) begin
                                pack_index <= 0;
                                if (!slot_free) begin
                                    fault <= 1'b1;
                                    frame_abort <= 1'b1;
                                    beat_valid <= 1'b0;
                                    active <= 1'b0;
                                end else if (y_count == V_LINES-1 &&
                                             x_count == H_PIXELS-1) begin
                                    final_data <= completed_data;
                                    final_pending <= 1'b1;
                                end else begin
                                    beat_data <= completed_data;
                                    beat_valid <= 1'b1;
                                    beat_last <= 1'b0;
                                end
                            end else begin
                                pack_data[pack_index*16 +: 16] <= pixel_data;
                                pack_index <= pack_index + 1'b1;
                            end
                        end
                    end else if (in_line) begin
                        if (x_count != H_PIXELS || pack_index != 0) begin
                            fault <= 1'b1;
                            frame_abort <= 1'b1;
                            beat_valid <= 1'b0;
                            active <= 1'b0;
                        end else begin
                            in_line <= 1'b0;
                            x_count <= 0;
                            y_count <= y_count + 1'b1;
                            if (y_count == V_LINES-1) begin
                                if (!final_pending || !slot_free) begin
                                    fault <= 1'b1;
                                    frame_abort <= 1'b1;
                                    beat_valid <= 1'b0;
                                    active <= 1'b0;
                                end else begin
                                    beat_data <= final_data;
                                    beat_valid <= 1'b1;
                                    beat_last <= 1'b1;
                                    final_pending <= 1'b0;
                                    ending <= 1'b1;
                                end
                            end
                        end
                    end
                end else if (closed_frame && pixel_valid) begin
                    fault <= 1'b1;
                end
            end
        end
    end
endmodule
