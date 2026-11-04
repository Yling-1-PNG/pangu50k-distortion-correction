// Single in-flight frame handshake around video_async_fifo. Both clocks use
// the same asynchronous reset. pix_frame_start must occur in blanking before
// the first pix_active of the 1280x720 frame.
module video_frame_gate #(
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
    output reg         wr_fault,
    input  wire        pix_frame_start,
    input  wire        pix_active,
    input  wire        fifo_rd_valid,
    input  wire [15:0] fifo_rd_pixel,
    output wire        fifo_rd_take,
    output wire        display_valid,
    output wire [15:0] display_pixel,
    output wire        frame_pending,
    output reg         pix_frame_done,
    output reg         pix_fault
);
    reg wr_busy, wr_done_seen, request_toggle;
    reg [19:0] wr_count;
    reg ack_w1, ack_w2;
    reg request_r1, request_r2, ack_toggle;
    reg displaying;
    reg [19:0] pix_count;
    wire [19:0] wr_next = wr_count + wr_pixel_fire;

    assign wr_frame_ready = !wr_busy && !wr_fault &&
                            request_toggle == ack_w2;
    assign frame_pending = request_r2 != ack_toggle;
    assign fifo_rd_take = displaying && pix_active && !pix_fault;
    assign display_valid = fifo_rd_take && fifo_rd_valid;
    assign display_pixel = display_valid ? fifo_rd_pixel : 16'd0;

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            ack_w1 <= 1'b0;
            ack_w2 <= 1'b0;
            wr_busy <= 1'b0;
            wr_done_seen <= 1'b0;
            request_toggle <= 1'b0;
            wr_count <= 20'd0;
            wr_fault <= 1'b0;
        end else begin
            ack_w1 <= ack_toggle;
            ack_w2 <= ack_w1;
            if (!wr_busy) begin
                if (wr_pixel_fire || wr_frame_done ||
                    (wr_frame_begin && !wr_frame_ready))
                    wr_fault <= 1'b1;
                else if (wr_frame_begin) begin
                    wr_busy <= 1'b1;
                    wr_done_seen <= 1'b0;
                    wr_count <= 20'd0;
                end
            end else begin
                if (wr_frame_begin ||
                    (wr_pixel_fire && wr_count >= FRAME_PIXELS) ||
                    (wr_frame_done && wr_next != FRAME_PIXELS))
                    wr_fault <= 1'b1;
                if (wr_pixel_fire && wr_count < FRAME_PIXELS) begin
                    wr_count <= wr_next;
                    if (wr_next == PREFILL_PIXELS)
                        request_toggle <= ~request_toggle;
                end
                if (wr_frame_done && wr_next == FRAME_PIXELS)
                    wr_done_seen <= 1'b1;
                if (wr_done_seen && request_toggle == ack_w2)
                    wr_busy <= 1'b0;
            end
        end
    end

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_r1 <= 1'b0;
            request_r2 <= 1'b0;
            ack_toggle <= 1'b0;
            displaying <= 1'b0;
            pix_count <= 20'd0;
            pix_frame_done <= 1'b0;
            pix_fault <= 1'b0;
        end else begin
            request_r1 <= request_toggle;
            request_r2 <= request_r1;
            pix_frame_done <= 1'b0;
            if (pix_frame_start) begin
                if (pix_active || displaying)
                    pix_fault <= 1'b1;
                else if (frame_pending && !pix_fault) begin
                    displaying <= 1'b1;
                    pix_count <= 20'd0;
                end
            end
            if (fifo_rd_take) begin
                if (!fifo_rd_valid)
                    pix_fault <= 1'b1;
                else if (pix_count == FRAME_PIXELS-1) begin
                    displaying <= 1'b0;
                    pix_frame_done <= 1'b1;
                    ack_toggle <= request_r2;
                end else
                    pix_count <= pix_count + 20'd1;
            end
        end
    end
endmodule
