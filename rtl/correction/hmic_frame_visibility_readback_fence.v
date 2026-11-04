`timescale 1ns/1ps
// Candidate frame-visibility fence for the PGL HMIC-S interface.
//
// The HMIC user interface has no write response. This block therefore waits
// for the writer's complete-frame WLAST count, waits until the previous random
// reader has drained, then issues a single-beat read of the final written
// 256-bit beat and compares it with the final W beat. This is an empirical
// read-after-write check, not a vendor-guaranteed ordering primitive; the
// board-level probe must pass before relying on it for frame ownership.
//
// Aborted writes fail-stop. There is intentionally no timeout-based bank
// release and no inferred abort-safe event.
module hmic_frame_visibility_readback_fence #(
    parameter integer FRAME_ADDR_UNITS = 460800,
    parameter [3:0] FENCE_ID = 4'hf,
    // 1 preserves the historical tail-only probe.  3 validates first,
    // middle and final written beats before publishing the frame.
    parameter integer CHECK_POINTS = 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         capture_grant,
    input  wire [27:0]  capture_base,
    input  wire         frame_transfer_done,
    input  wire         frame_transfer_aborted,
    input  wire         reader_idle,
    input  wire [255:0] axi_wdata,
    input  wire         axi_wready,
    input  wire         axi_wlast,
    input  wire [27:0]  reader_araddr,
    input  wire         reader_aruser_ap,
    input  wire [3:0]   reader_arid,
    input  wire [3:0]   reader_arlen,
    input  wire         reader_arvalid,
    output wire         reader_arready,
    output wire [255:0] reader_rdata,
    output wire [3:0]   reader_rid,
    output wire         reader_rlast,
    output wire         reader_rvalid,
    output wire [27:0]  mem_araddr,
    output wire         mem_aruser_ap,
    output wire [3:0]   mem_arid,
    output wire [3:0]   mem_arlen,
    output wire         mem_arvalid,
    input  wire         mem_arready,
    input  wire [255:0] mem_rdata,
    input  wire [3:0]   mem_rid,
    input  wire         mem_rlast,
    input  wire         mem_rvalid,
    output reg          visibility_confirmed,
    output wire         busy,
    output reg          fault
);
    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_WAIT_READER= 3'd1;
    localparam [2:0] S_ISSUE      = 3'd2;
    localparam [2:0] S_WAIT_R     = 3'd3;
    localparam [2:0] S_FAULT      = 3'd4;
    localparam [2:0] S_CHECK_R    = 3'd5;

    reg [2:0] state;
    reg frame_writing;
    reg last_write_seen;
    reg [27:0] held_frame_base;
    localparam integer FRAME_BEATS = FRAME_ADDR_UNITS / 8;
    localparam integer MID_BEAT = FRAME_BEATS / 2;
    localparam integer CHECK_COUNT = CHECK_POINTS <= 1 ? 1 : 3;
    reg [15:0] write_beat_index;
    reg [2:0] expected_valid;
    reg [255:0] expected_first_data;
    reg [255:0] expected_mid_data;
    reg [255:0] expected_last_data;
    reg [1:0] read_point;
    // Compare the wide HMIC response in registered 16-bit groups. This keeps
    // the existing S_WAIT_R -> S_CHECK_R latency while limiting the amount of
    // per-group state and routing added by the former 32 x 8-bit structure.
    reg [15:0] readback_match_chunks;
    reg readback_response_ok;

    wire fence_active = (state == S_ISSUE) || (state == S_WAIT_R) ||
                        (state == S_CHECK_R);
    wire fence_ar_fire = (state == S_ISSUE) && mem_arready;
    // Keep the current frame reader running while it reaches its own idle
    // boundary. Closing AR in S_WAIT_READER can deadlock a pixel stream that
    // still needs cache misses to finish; no new reader frame can start while
    // the fence is busy, and reader_idle is the gate before we close the path.
    wire reader_path_open = (state == S_IDLE) || (state == S_WAIT_READER);

    assign busy = state != S_IDLE;
    assign reader_arready = reader_path_open && mem_arready;
    assign reader_rdata = mem_rdata;
    assign reader_rid = mem_rid;
    assign reader_rlast = mem_rlast;
    assign reader_rvalid = mem_rvalid && !fence_active;

    wire [27:0] fence_offset = CHECK_COUNT == 1 ?
                               FRAME_ADDR_UNITS - 28'd8 :
                               (read_point == 2'd0 ? 28'd0 :
                                (read_point == 2'd1 ?
                                 (MID_BEAT * 28'd8) :
                                 FRAME_ADDR_UNITS - 28'd8));
    wire [255:0] expected_read_data = CHECK_COUNT == 1 ?
                                      expected_last_data :
                                      (read_point == 2'd0 ? expected_first_data :
                                       (read_point == 2'd1 ? expected_mid_data :
                                        expected_last_data));
    wire [15:0] readback_match_chunks_next;
    genvar compare_chunk;
    generate
        for (compare_chunk = 0; compare_chunk < 16;
             compare_chunk = compare_chunk + 1) begin : g_readback_compare
            assign readback_match_chunks_next[compare_chunk] =
                mem_rdata[compare_chunk * 16 +: 16] ==
                expected_read_data[compare_chunk * 16 +: 16];
        end
    endgenerate
    // HMIC WLAST terminates each 16-beat AXI burst, not the frame. Track the
    // frame beat index explicitly so first/middle/final probes use the same
    // addresses that the writer actually filled.
    wire write_last_fire = frame_writing && axi_wready &&
                           (write_beat_index == FRAME_BEATS - 1);
    assign mem_araddr = fence_ar_fire || state == S_ISSUE ?
                        held_frame_base + fence_offset : reader_araddr;
    assign mem_aruser_ap = state == S_ISSUE ? 1'b0 : reader_aruser_ap;
    assign mem_arid = state == S_ISSUE ? FENCE_ID : reader_arid;
    assign mem_arlen = state == S_ISSUE ? 4'd0 : reader_arlen;
    assign mem_arvalid = state == S_ISSUE ? 1'b1 :
                         (reader_path_open && reader_arvalid);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            frame_writing <= 1'b0;
            last_write_seen <= 1'b0;
            held_frame_base <= 28'd0;
            write_beat_index <= 16'd0;
            expected_valid <= 3'd0;
            expected_first_data <= 256'd0;
            expected_mid_data <= 256'd0;
            expected_last_data <= 256'd0;
            read_point <= 2'd0;
            readback_match_chunks <= 16'd0;
            readback_response_ok <= 1'b0;
            visibility_confirmed <= 1'b0;
            fault <= 1'b0;
        end else begin
            visibility_confirmed <= 1'b0;

            if (capture_grant && !frame_writing && state == S_IDLE) begin
                frame_writing <= 1'b1;
                last_write_seen <= 1'b0;
                write_beat_index <= 16'd0;
                expected_valid <= 3'd0;
            end

            if (frame_writing && axi_wready) begin
                if (write_beat_index == 16'd0) begin
                    expected_first_data <= axi_wdata;
                    expected_valid[0] <= 1'b1;
                end
                if (write_beat_index == MID_BEAT) begin
                    expected_mid_data <= axi_wdata;
                    expected_valid[1] <= 1'b1;
                end
                if (write_beat_index == FRAME_BEATS - 1) begin
                    expected_last_data <= axi_wdata;
                    expected_valid[2] <= 1'b1;
                    last_write_seen <= 1'b1;
                end else
                    write_beat_index <= write_beat_index + 1'b1;
            end

            if (frame_transfer_aborted) begin
                frame_writing <= 1'b0;
                fault <= 1'b1;
                state <= S_FAULT;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (frame_transfer_done) begin
                            frame_writing <= 1'b0;
                            held_frame_base <= capture_base;
                            read_point <= 2'd0;
                            if ((last_write_seen || write_last_fire) &&
                                (CHECK_COUNT == 1 ||
                                 (expected_valid[0] && expected_valid[1] &&
                                  (expected_valid[2] || write_last_fire))))
                                state <= S_WAIT_READER;
                            else begin
                                fault <= 1'b1;
                                state <= S_FAULT;
                            end
                        end
                    end
                    S_WAIT_READER: begin
                        if (reader_idle)
                            state <= S_ISSUE;
                    end
                    S_ISSUE: begin
                        if (mem_arready)
                            state <= S_WAIT_R;
                    end
                    S_WAIT_R: begin
                        if (mem_rvalid) begin
                            readback_match_chunks <= readback_match_chunks_next;
                            readback_response_ok <= mem_rid == FENCE_ID && mem_rlast;
                            state <= S_CHECK_R;
                        end
                    end
                    S_CHECK_R: begin
                        if (readback_response_ok && (&readback_match_chunks)) begin
                            if (CHECK_COUNT == 1 || read_point == 2'd2) begin
                                visibility_confirmed <= 1'b1;
                                last_write_seen <= 1'b0;
                                state <= S_IDLE;
                            end else begin
                                read_point <= read_point + 1'b1;
                                state <= S_ISSUE;
                            end
                        end else begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end
                    end
                    default: begin
                        fault <= 1'b1;
                        state <= S_FAULT;
                    end
                endcase
            end
        end
    end

    // Keep the protocol intent explicit for lint/synthesis review.
    wire unused_reader_inputs = reader_arvalid ^ reader_arready ^
                                reader_rvalid ^ reader_rlast ^
                                (|reader_rid) ^ (|reader_rdata) ^
                                (|reader_arlen) ^ reader_aruser_ap ^
                                fence_ar_fire;
endmodule
