// Eight ordered output pixels may wait for shared source beats concurrently.
// A hit or fill copies only the needed RGB565 samples into the pixel entry;
// no consumer retains a cache token after its data has been copied.
// All signals are in the HMIC clock domain. Invalid source pixels return black.
module pixel_beat_wait_queue (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    output wire         drain_ready,
    input  wire         in_valid,
    output wire         in_ready,
    output wire [3:0]   occupancy,
    input  wire         in_source_valid,
    input  wire [17:0]  in_beat00, in_beat10, in_beat01, in_beat11,
    input  wire [3:0]   in_lane00, in_lane10, in_lane01, in_lane11,
    input  wire [7:0]   in_fx, in_fy,
    output wire         lookup_valid,
    input  wire         lookup_ready,
    output wire [17:0] lookup_beat,
    input  wire         result_valid,
    input  wire         result_hit,
    input  wire         result_pending,
    input  wire         result_miss,
    input  wire [8:0]   result_token,
    input  wire [255:0] result_data,
    input  wire         filled_valid,
    input  wire [8:0]   filled_token,
    input  wire [255:0] filled_data,
    input  wire [255:0] filled_data_inv,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [15:0] out_p00, out_p10, out_p01, out_p11,
    output wire [7:0]   out_fx, out_fy,
    output reg          fault
);
    reg input_stage_valid_q, input_stage_source_valid_q;
    reg [71:0] input_stage_beats_q;
    reg [63:0] input_stage_lanes_1hot_q;
    reg [7:0] input_stage_fx_q, input_stage_fy_q;
    wire [17:0] input_stage_beat00 = input_stage_beats_q[17:0];
    wire [17:0] input_stage_beat10 = input_stage_beats_q[35:18];
    wire [17:0] input_stage_beat01 = input_stage_beats_q[53:36];
    wire [17:0] input_stage_beat11 = input_stage_beats_q[71:54];
    wire [2:0] unique_count;
    wire [17:0] uniq_0, uniq_1, uniq_2, uniq_3;
    wire [1:0] slot00, slot10, slot01, slot11;
    four_neighbor_beat_dedup dedup (
        .valid_in(input_stage_source_valid_q),
        .beat00(input_stage_beat00), .beat10(input_stage_beat10),
        .beat01(input_stage_beat01), .beat11(input_stage_beat11),
        .unique_count(unique_count), .uniq_0(uniq_0),
        .uniq_1(uniq_1), .uniq_2(uniq_2), .uniq_3(uniq_3),
        .slot00(slot00), .slot10(slot10),
        .slot01(slot01), .slot11(slot11)
    );

    reg [71:0] beat_mem [0:7];
    reg [2:0] unique_mem [0:7];
    reg [7:0] slot_mem [0:7];
    // Store each RGB565 lane selector one-hot so fill-data selection is
    // localized to the sample entry instead of routing four binary lane bits
    // through a 16:1 dynamic part-select at every write site.
    reg [63:0] lane_1hot_mem [0:7];
    reg [7:0] fx_mem [0:7], fy_mem [0:7];
    // Keep the stored coordinate value bijective while adding a local
    // decode stage before the LUT-RAM write data.  The current P&R candidate
    // closed setup, but the remaining DDR hold failures are concentrated on
    // input_stage_fy_q -> fy_mem write-data paths.
    wire [7:0] fy_mem_write_encoded /* synthesis syn_keep=1 */ =
        input_stage_fy_q ^ 8'hA5;
    reg [3:0] ready_mem [0:7], waiting_mem [0:7];
    reg [15:0] sample_mem [0:31];
    reg [8:0] token_mem [0:31];
    reg issued_mem [0:7];
    reg [2:0] wr_ptr, rd_ptr, scan_ptr;
    reg [3:0] count, unscheduled_count;
    // The lane selector LUTRAM write address was a zero-logic-level path
    // from wr_ptr and became a fast-corner hold hotspot after integration.
    // Store this one memory with a reversed slot map: the write address has
    // one real decode/inversion level, while every read applies the inverse
    // constant/dynamic slot map. The queue's logical entry numbering is
    // unchanged.
    wire [2:0] lane_mem_wr_ptr_inv /* synthesis syn_keep=1 */;
    assign lane_mem_wr_ptr_inv = ~wr_ptr;
    reg [1:0] issue_slot;
    // Requests can wait in the bridge; retire metadata with actual results.
    reg [4:0] request_meta [0:3];
    reg [1:0] request_wr_ptr, request_rd_ptr;
    reg [2:0] request_count;
    // Split result-token comparison/control from the sample-memory write.
    // One result may enter and one prior result may retire each cycle.
    reg response_valid_q;
    reg [8:0] response_token_q;
    reg [3:0] response_match_q, response_ready_q;
    reg [63:0] response_pixels_q;
    reg [7:0] response_entry_select_q;
    wire [4:0] reserved_count = {1'b0, count} + {4'd0, input_stage_valid_q};
    wire capture_input = in_valid && in_ready;
    wire enqueue = input_stage_valid_q;
    wire skip = unscheduled_count != 0 && unique_mem[scan_ptr] == 0;
    wire issue = lookup_valid && lookup_ready;
    wire issue_last = issue && {1'b0, issue_slot} + 3'd1 ==
                              unique_mem[scan_ptr];
    wire scan_done = skip || issue_last;
    wire retire = out_valid && out_ready;
    wire [2:0] response_entry = request_meta[request_rd_ptr][4:2];
    wire [1:0] response_slot = request_meta[request_rd_ptr][1:0];
    wire [4:0] output_base = {rd_ptr, 2'b00};
    wire [7:0] response_entry_select;
    wire [15:0] filled_pixel_data [0:31];
    genvar entry_idx;
    genvar fill_entry_idx, fill_sample_idx;

    function [15:0] decode_lane_1hot;
        input [3:0] lane;
        begin
            decode_lane_1hot = 16'h0001 << lane;
        end
    endfunction

    function [15:0] select_lane_1hot;
        input [255:0] data;
        input [15:0] lane_1hot;
        begin
            select_lane_1hot =
                (data[15:0]    & {16{lane_1hot[0]}})  |
                (data[31:16]   & {16{lane_1hot[1]}})  |
                (data[47:32]   & {16{lane_1hot[2]}})  |
                (data[63:48]   & {16{lane_1hot[3]}})  |
                (data[79:64]   & {16{lane_1hot[4]}})  |
                (data[95:80]   & {16{lane_1hot[5]}})  |
                (data[111:96]  & {16{lane_1hot[6]}})  |
                (data[127:112] & {16{lane_1hot[7]}})  |
                (data[143:128] & {16{lane_1hot[8]}})  |
                (data[159:144] & {16{lane_1hot[9]}})  |
                (data[175:160] & {16{lane_1hot[10]}}) |
                (data[191:176] & {16{lane_1hot[11]}}) |
                (data[207:192] & {16{lane_1hot[12]}}) |
                (data[223:208] & {16{lane_1hot[13]}}) |
                (data[239:224] & {16{lane_1hot[14]}}) |
                (data[255:240] & {16{lane_1hot[15]}});
        end
    endfunction

    function [15:0] select_lane_1hot_inverted;
        input [255:0] data_inv;
        input [15:0] lane_1hot;
        begin
            // The lane decoder always emits exactly one asserted bit.
            select_lane_1hot_inverted =
                ~select_lane_1hot(data_inv, lane_1hot);
        end
    endfunction

    generate
        for (fill_entry_idx = 0; fill_entry_idx < 8;
             fill_entry_idx = fill_entry_idx + 1) begin : fill_entry_decode
            localparam [2:0] lane_mem_read_entry = 3'd7 - fill_entry_idx;
            for (fill_sample_idx = 0; fill_sample_idx < 4;
                 fill_sample_idx = fill_sample_idx + 1) begin : sample_decode
                if (fill_entry_idx < 4) begin : positive_data_bank
                    assign filled_pixel_data[fill_entry_idx*4 + fill_sample_idx] =
                        select_lane_1hot(
                            filled_data,
                            ~lane_1hot_mem[lane_mem_read_entry]
                                           [fill_sample_idx*16 +: 16]);
                end else begin : inverted_data_bank
                    assign filled_pixel_data[fill_entry_idx*4 + fill_sample_idx] =
                        select_lane_1hot_inverted(
                            filled_data_inv,
                            ~lane_1hot_mem[lane_mem_read_entry]
                                           [fill_sample_idx*16 +: 16]);
                end
            end
        end
    endgenerate

    generate
        for (entry_idx = 0; entry_idx < 8; entry_idx = entry_idx + 1) begin : response_entry_decode
            assign response_entry_select[entry_idx] = response_entry == entry_idx;
        end
    endgenerate

    assign in_ready = rst_n && !clear && !fault && reserved_count < 5'd8;
    assign occupancy = count;
    assign lookup_valid = rst_n && !fault && unscheduled_count != 0 &&
                          unique_mem[scan_ptr] != 0 && request_count < 3'd4;
    assign lookup_beat = lookup_valid ?
                         beat_mem[scan_ptr][issue_slot*18 +: 18] : 18'd0;
    assign out_valid = rst_n && !fault && count != 0 &&
                       issued_mem[rd_ptr] && ready_mem[rd_ptr] == 4'hf;
    assign out_p00 = out_valid ? sample_mem[output_base] : 16'd0;
    assign out_p10 = out_valid ? sample_mem[output_base + 5'd1] : 16'd0;
    assign out_p01 = out_valid ? sample_mem[output_base + 5'd2] : 16'd0;
    assign out_p11 = out_valid ? sample_mem[output_base + 5'd3] : 16'd0;
    assign out_fx = out_valid ? fx_mem[rd_ptr] : 8'd0;
    assign out_fy = out_valid ? (fy_mem[rd_ptr] ^ 8'hA5) : 8'd0;
    assign drain_ready = count == 0 && unscheduled_count == 0 &&
                         !input_stage_valid_q && request_count == 0 && !response_valid_q;

    integer e, s;
    reg [1:0] sample_slot;
    reg [15:0] sample_lane_oh;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; scan_ptr <= 0;
            count <= 0; unscheduled_count <= 0; issue_slot <= 0;
            input_stage_valid_q <= 1'b0;
            input_stage_lanes_1hot_q <= 64'd0;
            request_wr_ptr <= 0;
            request_rd_ptr <= 0;
            request_count <= 0;
            response_valid_q <= 1'b0;
            response_token_q <= 0;
            response_match_q <= 0; response_ready_q <= 0;
            response_pixels_q <= 0;
            response_entry_select_q <= 8'd0;
            fault <= 0;
            for (e = 0; e < 8; e = e + 1) begin
                ready_mem[e] <= 0;
                waiting_mem[e] <= 0;
                issued_mem[e] <= 0;
            end
        end else begin
            input_stage_valid_q <= capture_input;
            if (capture_input) begin
                input_stage_source_valid_q <= in_source_valid;
                input_stage_beats_q <= {in_beat11, in_beat01,
                                        in_beat10, in_beat00};
                input_stage_lanes_1hot_q <= {
                    decode_lane_1hot(in_lane11),
                    decode_lane_1hot(in_lane01),
                    decode_lane_1hot(in_lane10),
                    decode_lane_1hot(in_lane00)};
                input_stage_fx_q <= in_fx;
                input_stage_fy_q <= in_fy;
            end
            response_valid_q <= 1'b0;
            response_entry_select_q <= 8'd0;
            if (issue) begin
                request_meta[request_wr_ptr] <= {scan_ptr, issue_slot};
                request_wr_ptr <= request_wr_ptr + 1'b1;
            end
            if (result_valid && request_count != 0)
                request_rd_ptr <= request_rd_ptr + 1'b1;
            case ({issue, result_valid && request_count != 0})
                2'b10: request_count <= request_count + 1'b1;
                2'b01: request_count <= request_count - 1'b1;
                default: ;
            endcase
            if (scan_done) begin
                scan_ptr <= scan_ptr + 3'd1;
                issue_slot <= 0;
                issued_mem[scan_ptr] <= 1;
            end else if (issue)
                issue_slot <= issue_slot + 2'd1;
            case ({enqueue, scan_done})
                2'b10: unscheduled_count <= unscheduled_count + 4'd1;
                2'b01: unscheduled_count <= unscheduled_count - 4'd1;
                default: unscheduled_count <= unscheduled_count;
            endcase
            case ({enqueue, retire})
                2'b10: count <= count + 4'd1;
                2'b01: count <= count - 4'd1;
                default: count <= count;
            endcase
            if (retire)
                rd_ptr <= rd_ptr + 3'd1;
            if (enqueue) begin
                wr_ptr <= wr_ptr + 3'd1;
                unique_mem[wr_ptr] <= unique_count;
                beat_mem[wr_ptr] <= {uniq_3, uniq_2, uniq_1, uniq_0};
                slot_mem[wr_ptr] <= {slot11, slot01, slot10, slot00};
                // Complement the stored selector encoding to lengthen the
                // short LUTRAM write-data path; consumers decode it below.
                lane_1hot_mem[lane_mem_wr_ptr_inv] <= ~input_stage_lanes_1hot_q;
                fx_mem[wr_ptr] <= input_stage_fx_q;
                fy_mem[wr_ptr] <= fy_mem_write_encoded;
                ready_mem[wr_ptr] <= input_stage_source_valid_q ? 4'b0000 : 4'b1111;
                waiting_mem[wr_ptr] <= 0;
                issued_mem[wr_ptr] <= 0;
                if (!input_stage_source_valid_q)
                    for (s = 0; s < 4; s = s + 1)
                        sample_mem[{wr_ptr, 2'b00} + s] <= 0;
            end
            // Filled beats may satisfy several pixels and several lanes at once.
            if (filled_valid)
                for (e = 0; e < 8; e = e + 1)
                    for (s = 0; s < 4; s = s + 1)
                        if (waiting_mem[e][s] &&
                            token_mem[e*4+s] == filled_token) begin
                            sample_mem[e*4+s] <= filled_pixel_data[e*4+s];
                            ready_mem[e][s] <= 1;
                            waiting_mem[e][s] <= 0;
                        end

            // Retire the previously decoded result. A same-cycle fill can
            // satisfy a pending result before it is recorded as waiting.
            if (response_valid_q)
                for (e = 0; e < 8; e = e + 1)
                    for (s = 0; s < 4; s = s + 1)
                    if (response_entry_select_q[e] && response_match_q[s]) begin
                        if (response_ready_q[s] ||
                            (filled_valid && filled_token == response_token_q)) begin
                            sample_mem[e*4+s] <= response_ready_q[s] ?
                                response_pixels_q[16*s +: 16] :
                                filled_pixel_data[e*4+s];
                            ready_mem[e][s] <= 1;
                            waiting_mem[e][s] <= 0;
                        end else begin
                            token_mem[e*4+s] <= response_token_q;
                            waiting_mem[e][s] <= 1;
                        end
                    end

            if (result_valid) begin
                if (request_count == 0 ||
                    {1'b0, result_hit} + {1'b0, result_pending} +
                    {1'b0, result_miss} != 2'd1)
                    fault <= 1;
                else begin
                    response_valid_q <= 1'b1;
                    response_entry_select_q <= response_entry_select;
                    response_token_q <= result_token;
                    response_match_q <= 4'b0000;
                    response_ready_q <= 4'b0000;
                    for (s = 0; s < 4; s = s + 1) begin
                        sample_slot = slot_mem[response_entry][2*s +: 2];
                        sample_lane_oh = ~lane_1hot_mem[3'd7 - response_entry]
                                                        [16*s +: 16];
                        if (sample_slot == response_slot) begin
                            response_match_q[s] <= 1'b1;
                            if (result_hit ||
                                (filled_valid && filled_token == result_token)) begin
                                response_ready_q[s] <= 1'b1;
                                response_pixels_q[16*s +: 16] <= result_hit ?
                                    select_lane_1hot(result_data,
                                                     sample_lane_oh) :
                                    select_lane_1hot(filled_data,
                                                     sample_lane_oh);
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
