// Backpressure-aware DDR-clock-domain packer for a corrected RGB565 frame.
// The earliest of 16 pixels occupies the least-significant 16-bit lane.
// frame_done pulses only after the final 256-bit beat is accepted. The caller
// must hold pixel_valid/data while pixel_ready is low, as in ready/valid.
module corrected_rgb565_beat_packer #(
    parameter integer FRAME_PIXELS = 1280*720
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_begin,
    output wire         frame_ready,
    input  wire         pixel_valid,
    output wire         pixel_ready,
    input  wire [15:0]  pixel_data,
    output reg          beat_valid,
    input  wire         beat_ready,
    output reg  [255:0] beat_data,
    output reg          frame_done,
    output reg          fault
);
    localparam integer COUNT_BITS = $clog2(FRAME_PIXELS + 1);
    reg active;
    reg [COUNT_BITS-1:0] pixel_count;
    reg [3:0] pack_index;
    // Payload is observed only when beat_valid is high. pack_data is fully
    // overwritten by 15 accepted pixels before the next beat is emitted, so
    // do not clear this wide bank on reset or frame_begin.
    reg [239:0] pack_data;
    wire pixel_fire = pixel_valid && pixel_ready;
    wire beat_fire = beat_valid && beat_ready;

    assign frame_ready = !active && !beat_valid && !fault;
    assign pixel_ready = active && !beat_valid && !fault &&
                         pixel_count < FRAME_PIXELS;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            pixel_count <= 0;
            pack_index <= 0;
            beat_valid <= 1'b0;
            frame_done <= 1'b0;
            fault <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (frame_begin) begin
                if (!frame_ready || FRAME_PIXELS < 16 ||
                    FRAME_PIXELS % 16 != 0)
                    fault <= 1'b1;
                else begin
                    active <= 1'b1;
                    pixel_count <= 0;
                    pack_index <= 0;
                end
            end else if (!fault) begin
                if (beat_fire) begin
                    beat_valid <= 1'b0;
                    if (pixel_count == FRAME_PIXELS) begin
                        active <= 1'b0;
                        frame_done <= 1'b1;
                    end
                end
                if (pixel_fire) begin
                    pixel_count <= pixel_count + 1'b1;
                    if (pack_index == 4'd15) begin
                        beat_valid <= 1'b1;
                        pack_index <= 0;
                    end else begin
                        pack_index <= pack_index + 1'b1;
                    end
                end
            end
        end
    end

    // Keep the wide payload bank out of the frame_begin/reset control cone.
    // A valid frame_begin occurs while active is low, hence pixel_fire is low;
    // an invalid concurrent frame_begin faults the packer and cannot expose
    // this payload. A beat is published only after all its pixels are written.
    always @(posedge clk) begin
        if (rst_n && !fault && pixel_fire) begin
            if (pack_index == 4'd15)
                beat_data <= {pixel_data, pack_data};
            else
                pack_data <= {pixel_data, pack_data[239:16]};
        end
    end
endmodule
