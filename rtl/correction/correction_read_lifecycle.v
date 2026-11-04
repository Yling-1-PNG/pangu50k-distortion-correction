// DDR-clock-domain release of a correction read bank. The video FIFO owns
// copies of pixels after pixel_valid/pixel_ready; its later display timing
// is a separate frame-boundary contract.
module correction_read_lifecycle #(
    parameter integer FRAME_PIXELS = 1280*720
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire input_done,
    input  wire pixel_valid,
    input  wire pixel_ready,
    input  wire pipeline_clear_ready,
    output wire pipeline_clear,
    output reg  reader_done,
    output wire busy,
    output reg  fault
);
    localparam IDLE = 2'd0, ACTIVE = 2'd1, CLEAR = 2'd2;
    reg [1:0] state;
    reg input_seen;
    reg [19:0] pixel_count;
    wire pixel_fire = pixel_valid && pixel_ready;
    wire [19:0] pixel_next = pixel_count + pixel_fire;
    wire extra_pixel = pixel_fire && pixel_count >= FRAME_PIXELS;

    assign busy = state != IDLE;
    assign pipeline_clear = state == CLEAR && pipeline_clear_ready && !fault &&
                            !start && !input_done && !pixel_fire;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            input_seen <= 1'b0;
            pixel_count <= 20'd0;
            reader_done <= 1'b0;
            fault <= 1'b0;
        end else begin
            reader_done <= 1'b0;
            case (state)
                IDLE: begin
                    if (input_done || pixel_fire)
                        fault <= 1'b1;
                    if (start && !fault && !input_done && !pixel_fire) begin
                        state <= ACTIVE;
                        input_seen <= 1'b0;
                        pixel_count <= 20'd0;
                    end
                end
                ACTIVE: begin
                    if (input_done)
                        input_seen <= 1'b1;
                    if (pixel_fire && !extra_pixel)
                        pixel_count <= pixel_next;
                    if (start || extra_pixel)
                        fault <= 1'b1;
                    else if (!fault && (input_seen || input_done) &&
                             pixel_next == FRAME_PIXELS)
                        state <= CLEAR;
                end
                CLEAR: begin
                    if (start || input_done || pixel_fire)
                        fault <= 1'b1;
                    else if (pipeline_clear) begin
                        state <= IDLE;
                        reader_done <= 1'b1;
                    end
                end
                default: fault <= 1'b1;
            endcase
        end
    end
endmodule
