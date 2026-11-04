// Emits one IMAGE_WIDTH x IMAGE_HEIGHT output coordinate per accepted handshake.
// input_done marks the final coordinate *issued*, not all DDR reads or video
// pixels drained. Keep the read bank pinned until the downstream chain drains.
module raster_coordinate_source #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire        start_ready,
    output reg         busy,
    output wire        out_valid,
    input  wire        out_ready,
    output reg  [10:0] out_x,
    output reg  [10:0] out_y,
    output reg         input_done
);
    assign start_ready = !busy;
    assign out_valid = busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            out_x <= 11'd0;
            out_y <= 11'd0;
            input_done <= 1'b0;
        end else begin
            input_done <= 1'b0;
            if (!busy) begin
                if (start) begin
                    busy <= 1'b1;
                    out_x <= 11'd0;
                    out_y <= 11'd0;
                end
            end else if (out_ready) begin
                if (out_x == IMAGE_WIDTH-1) begin
                    out_x <= 11'd0;
                    if (out_y == IMAGE_HEIGHT-1) begin
                        busy <= 1'b0;
                        input_done <= 1'b1;
                    end else
                        out_y <= out_y + 11'd1;
                end else
                    out_x <= out_x + 11'd1;
            end
        end
    end
endmodule
