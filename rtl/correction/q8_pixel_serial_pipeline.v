// One-pixel correctness chain: Q11.8 source position -> four frame beats ->
// serial DDR reads -> canonical RGB565 samples -> bilinear RGB565 output.
// All ports share the DDR controller clock. Real HMIC lane order, frame safety,
// CDC and video-rate throughput are outside this module.
module q8_pixel_serial_pipeline (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire signed [19:0] src_x_q8,
    input  wire signed [19:0] src_y_q8,
    input  wire [27:0]  frame_base_ctrl_addr,
    output wire         req_valid,
    input  wire         req_ready,
    output wire [27:0]  req_addr,
    input  wire         rsp_valid,
    input  wire [255:0] rsp_data,
    input  wire         rsp_error,
    output wire         out_valid,
    input  wire         out_ready,
    output reg  [15:0]  out_pixel,
    output reg          out_error
);
    localparam READY = 2'd0, WAIT_FETCH = 2'd1,
               WAIT_INTERP = 2'd2, OUTPUT = 2'd3;
    reg [1:0] state;
    reg coord_good;
    reg [1:0] held_s00, held_s10, held_s01, held_s11;
    reg [3:0] held_l00, held_l10, held_l01, held_l11;
    reg [7:0] held_fx, held_fy;

    wire coord_valid;
    wire [17:0] beat00, beat10, beat01, beat11;
    wire [3:0] lane00, lane10, lane01, lane11;
    wire [7:0] frac_x, frac_y;
    wire [2:0] unique_count;
    wire [17:0] uniq_0, uniq_1, uniq_2, uniq_3;
    wire [1:0] slot00, slot10, slot01, slot11;
    wire fetch_ready, fetch_valid, fetch_error;
    wire [2:0] fetched_count;
    wire [255:0] data_0, data_1, data_2, data_3;
    wire samples_valid;
    wire [15:0] p00, p10, p01, p11;
    wire interp_valid;
    wire [15:0] interp_pixel;
    wire input_fire = in_valid && in_ready;
    wire consume_fetch = state == WAIT_FETCH && fetch_valid;

    four_neighbor_address_q8 addresses (
        .valid_in(in_valid), .src_x_q8(src_x_q8), .src_y_q8(src_y_q8),
        .valid_out(coord_valid), .addr00(), .addr10(), .addr01(), .addr11(),
        .beat00(beat00), .beat10(beat10), .beat01(beat01), .beat11(beat11),
        .lane00(lane00), .lane10(lane10), .lane01(lane01), .lane11(lane11),
        .frac_x(frac_x), .frac_y(frac_y)
    );
    four_neighbor_beat_dedup grouping (
        .valid_in(coord_valid), .beat00(beat00), .beat10(beat10),
        .beat01(beat01), .beat11(beat11), .unique_count(unique_count),
        .uniq_0(uniq_0), .uniq_1(uniq_1), .uniq_2(uniq_2), .uniq_3(uniq_3),
        .slot00(slot00), .slot10(slot10), .slot01(slot01), .slot11(slot11)
    );
    four_beat_serial_fetch fetch (
        .clk(clk), .rst_n(rst_n), .pixel_valid(input_fire),
        .pixel_ready(fetch_ready), .unique_count(unique_count),
        .uniq_0(uniq_0), .uniq_1(uniq_1), .uniq_2(uniq_2), .uniq_3(uniq_3),
        .frame_base_ctrl_addr(frame_base_ctrl_addr), .req_valid(req_valid),
        .req_ready(req_ready), .req_addr(req_addr), .rsp_valid(rsp_valid),
        .rsp_data(rsp_data), .rsp_error(rsp_error), .result_valid(fetch_valid),
        .result_ready(state == WAIT_FETCH), .result_count(fetched_count),
        .result_error(fetch_error), .result_0(data_0), .result_1(data_1),
        .result_2(data_2), .result_3(data_3)
    );
    rgb565_four_sample_select samples (
        .valid_in(consume_fetch && coord_good && !fetch_error),
        .beat_count(fetched_count), .beat_0(data_0), .beat_1(data_1),
        .beat_2(data_2), .beat_3(data_3),
        .slot00(held_s00), .slot10(held_s10),
        .slot01(held_s01), .slot11(held_s11),
        .lane00(held_l00), .lane10(held_l10),
        .lane01(held_l01), .lane11(held_l11),
        .valid_out(samples_valid), .p00(p00), .p10(p10),
        .p01(p01), .p11(p11)
    );
    bilinear_rgb565 interpolation (
        .clk(clk), .rst(!rst_n), .valid_in(samples_valid && consume_fetch),
        .p00(p00), .p10(p10), .p01(p01), .p11(p11),
        .frac_x(held_fx), .frac_y(held_fy),
        .valid_out(interp_valid), .pixel_out(interp_pixel)
    );

    assign in_ready = rst_n && state == READY && fetch_ready;
    assign out_valid = state == OUTPUT;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= READY;
            coord_good <= 1'b0;
            held_s00 <= 2'd0;
            held_s10 <= 2'd0;
            held_s01 <= 2'd0;
            held_s11 <= 2'd0;
            held_l00 <= 4'd0;
            held_l10 <= 4'd0;
            held_l01 <= 4'd0;
            held_l11 <= 4'd0;
            held_fx <= 8'd0;
            held_fy <= 8'd0;
            out_pixel <= 16'd0;
            out_error <= 1'b0;
        end else begin
            case (state)
                READY: if (input_fire) begin
                    coord_good <= coord_valid;
                    held_s00 <= slot00;
                    held_s10 <= slot10;
                    held_s01 <= slot01;
                    held_s11 <= slot11;
                    held_l00 <= lane00;
                    held_l10 <= lane10;
                    held_l01 <= lane01;
                    held_l11 <= lane11;
                    held_fx <= frac_x;
                    held_fy <= frac_y;
                    state <= WAIT_FETCH;
                end
                WAIT_FETCH: if (consume_fetch) begin
                    if (fetch_error || !coord_good || !samples_valid) begin
                        out_pixel <= 16'd0;
                        out_error <= fetch_error || (coord_good && !samples_valid);
                        state <= OUTPUT;
                    end else
                        state <= WAIT_INTERP;
                end
                WAIT_INTERP: if (interp_valid) begin
                    out_pixel <= interp_pixel;
                    out_error <= 1'b0;
                    state <= OUTPUT;
                end
                OUTPUT: if (out_ready)
                    state <= READY;
            endcase
        end
    end
endmodule
