`timescale 1ns/1ps
// DDR-clock-domain 256-bit HMIC write sequencer for a pre-authorized frame.
// The caller must choose a free bank before frame_begin and provide all beats
// through beat_valid/beat_ready. Neither transfer_done nor transfer_aborted
// proves DDR read visibility or internal write quiescence.
// HMIC_S has no write B response or WVALID input: preload each full 16-beat
// burst before AW, then advance WDATA only when the IP asserts WREADY.
module controlled_frame_write_port #(
    parameter integer FRAME_BURSTS = 3600
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_begin,
    input  wire [27:0]  frame_base,
    input  wire         frame_done,
    input  wire         abort,
    output wire         frame_ready,
    input  wire         beat_valid,
    output wire         beat_ready,
    input  wire [255:0] beat_data,
    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awuser_id,
    output wire [3:0]   axi_awlen,
    output wire         axi_awuser_ap,
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire         axi_wusero_last,
    output reg          transfer_done,
    output reg          transfer_aborted,
    output reg          fault
);
    localparam [2:0] S_IDLE = 0, S_FILL = 1, S_AW = 2,
                     S_W = 3, S_WAIT_DONE = 4, S_FAULT = 5;
    localparam integer TOTAL_BEATS = FRAME_BURSTS * 16;
    reg [2:0] state;
    reg [27:0] held_base;
    reg [255:0] burst_data [0:15];
    reg [3:0] fill_index, send_index;
    // Keep a registered one-hot write select beside the binary counter. The
    // binary index remains the protocol counter; this local decode avoids a
    // four-bit global address decode on every 256-bit burst-buffer bank.
    reg [15:0] fill_select_onehot;
    reg [12:0] burst_index;
    reg [15:0] accepted_beats;
    reg done_seen;
    reg abort_pending;
    wire beat_fire = beat_valid && beat_ready;
    // S_FILL guarantees accepted_beats < TOTAL_BEATS: accepting the final
    // beat leaves S_FILL on that same rising edge. Latched protocol faults
    // also leave S_FILL immediately, so the half-cycle RAM enable needs no
    // wide count compare or global fault net.
    // Abort is consumed on the next rising edge and leaves S_FILL before any
    // burst can be issued. Do not put it on the 256-bit bank-write enable path:
    // a coincident unaccepted beat may be staged, then discarded with the
    // aborted frame and overwritten before a later burst is issued.
    wire burst_preload = rst_n && beat_valid && state == S_FILL;
    wire [16:0] accepted_next = {1'b0, accepted_beats} + beat_fire;
    wire [28:0] frame_limit = {1'b0, frame_base} +
                              (FRAME_BURSTS * 29'd128);
    wire bad_begin = frame_begin && !frame_ready;
    wire bad_done = frame_done && !(abort || abort_pending) &&
                    (state == S_IDLE || done_seen ||
                     accepted_next != TOTAL_BEATS);
    wire bad_abort = abort && state == S_IDLE;
    wire bad_ip = (axi_wready && state != S_W) ||
                  (axi_wusero_last && !axi_wready) ||
                  (state == S_W && axi_wready &&
                   axi_wusero_last != (send_index == 4'd15));

    assign frame_ready = state == S_IDLE && !fault;
    assign beat_ready = state == S_FILL && !fault &&
                        accepted_beats < TOTAL_BEATS;
    assign axi_awaddr = held_base + {8'd0, burst_index, 7'd0};
    assign axi_awuser_id = 4'd0;
    assign axi_awlen = 4'd15;
    assign axi_awuser_ap = 1'b0;
    assign axi_awvalid = state == S_AW && !fault && !abort;
    // HMIC has no WVALID: WDATA is consumed only on WREADY. The top-level
    // writer arbiter masks the shared memory bus outside its S_W state, so
    // keep phase gating off this critical burst-data mux.
    assign axi_wdata = burst_data[send_index];
    assign axi_wstrb = state == S_W ? 32'hffff_ffff : 32'd0;

    // Capture the accepted beat on the rising edge. The FIFO presents the
    // current beat before the handshake edge; capturing on that same edge
    // gives the FIFO-output-to-burst-RAM path a full clock period in the
    // implementation rather than a half-cycle falling-edge path.
    genvar burst_slot;
    generate
        for (burst_slot = 0; burst_slot < 16; burst_slot = burst_slot + 1) begin : g_burst_slot_write
            always @(posedge clk) begin
                if (burst_preload && fill_select_onehot[burst_slot])
                    burst_data[burst_slot] <= beat_data;
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            held_base <= 28'd0;
            fill_index <= 4'd0;
            fill_select_onehot <= 16'h0001;
            send_index <= 4'd0;
            burst_index <= 13'd0;
            accepted_beats <= 16'd0;
            done_seen <= 1'b0;
            abort_pending <= 1'b0;
            transfer_done <= 1'b0;
            transfer_aborted <= 1'b0;
            fault <= 1'b0;
        end else begin
            transfer_done <= 1'b0;
            transfer_aborted <= 1'b0;
            if (fault || state == S_FAULT) begin
                state <= S_FAULT;
            end else if (bad_begin || bad_done || bad_abort || bad_ip) begin
                fault <= 1'b1;
                state <= S_FAULT;
            end else begin
                if (frame_done)
                    done_seen <= 1'b1;
                if (abort && state == S_W)
                    abort_pending <= 1'b1;
                case (state)
                    S_IDLE: if (frame_begin) begin
                        if (frame_base[6:0] != 0 ||
                            frame_limit > 29'h10000000 ||
                            FRAME_BURSTS < 1 || FRAME_BURSTS > 4095) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else begin
                            held_base <= frame_base;
                            fill_index <= 4'd0;
                            fill_select_onehot <= 16'h0001;
                            send_index <= 4'd0;
                            burst_index <= 13'd0;
                            accepted_beats <= 16'd0;
                            done_seen <= 1'b0;
                            abort_pending <= 1'b0;
                            state <= S_FILL;
                        end
                    end
                    S_FILL: if (abort) begin
                        transfer_aborted <= 1'b1;
                        state <= S_IDLE;
                    end else if (beat_fire) begin
                        accepted_beats <= accepted_next[15:0];
                        if (fill_index == 4'd15) begin
                            fill_index <= 4'd0;
                            fill_select_onehot <= 16'h0001;
                            state <= S_AW;
                        end else begin
                            fill_index <= fill_index + 4'd1;
                            fill_select_onehot <= {fill_select_onehot[14:0], fill_select_onehot[15]};
                        end
                    end
                    S_AW: if (abort) begin
                        transfer_aborted <= 1'b1;
                        state <= S_IDLE;
                    end else if (axi_awready)
                        state <= S_W;
                    S_W: if (axi_wready) begin
                        if (send_index == 4'd15) begin
                            send_index <= 4'd0;
                            if (abort || abort_pending) begin
                                abort_pending <= 1'b0;
                                transfer_aborted <= 1'b1;
                                state <= S_IDLE;
                            end else if (burst_index == FRAME_BURSTS-1) begin
                                if (done_seen || frame_done) begin
                                    transfer_done <= 1'b1;
                                    state <= S_IDLE;
                                end else
                                    state <= S_WAIT_DONE;
                            end else begin
                                burst_index <= burst_index + 13'd1;
                                state <= S_FILL;
                            end
                        end else
                            send_index <= send_index + 4'd1;
                    end
                    S_WAIT_DONE: if (abort) begin
                        transfer_aborted <= 1'b1;
                        state <= S_IDLE;
                    end else if (done_seen || frame_done) begin
                        transfer_done <= 1'b1;
                        state <= S_IDLE;
                    end
                    default: begin
                        fault <= 1'b1;
                        state <= S_FAULT;
                    end
                endcase
            end
        end
    end
endmodule
