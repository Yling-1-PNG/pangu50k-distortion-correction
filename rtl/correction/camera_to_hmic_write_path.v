`timescale 1ns/1ps
// Camera-side frame packer, 257-bit CDC FIFO, frame-event mailbox and the
// controlled HMIC writer. frame_base must be granted and held stable before
// cam_frame_start. HMIC write visibility/quiescence is external: after an
// aborted transfer this block drains stale FIFO entries and waits for
// abort_release_authorized before allowing a new frame.
module camera_to_hmic_write_path #(
    parameter integer H_PIXELS = 1280,
    parameter integer V_LINES = 720,
    parameter integer FIFO_ADDR_BITS = 5,
    parameter integer USE_FRAME_BANK_CONTROL = 0
) (
    input  wire         cam_clk,
    input  wire         ddr_clk,
    input  wire         rst_n,
    input  wire         cam_clear,
    input  wire         cam_arm,
    input  wire         cam_vsync_level,
    input  wire         cam_pixel_valid,
    input  wire [15:0]  cam_pixel_data,
    input  wire [27:0]  frame_base,
    input  wire         abort_release_authorized,
    output wire         bank_capture_request,
    input  wire         bank_capture_grant,
    input  wire         bank_capture_rejected,
    input  wire [27:0]  bank_capture_base,
    output wire         capture_ready,
    output wire         unallocated_drop_active,
    output reg          abort_waiting_visibility,
    output reg          abort_recovered,
    output wire         camera_frame_open,
    output wire         camera_frame_done,
    output wire         camera_frame_abort,
    output reg          transfer_done,
    output reg          transfer_aborted,
    output reg          fault,
    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awuser_id,
    output wire [3:0]   axi_awlen,
    output wire         axi_awuser_ap,
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire         axi_wusero_last
);
    localparam integer FRAME_BEATS = H_PIXELS * V_LINES / 16;
    localparam integer FRAME_BURSTS = H_PIXELS * V_LINES / 256;
    localparam [1:0] EVENT_OPEN = 2'b01;
    localparam [1:0] EVENT_DONE = 2'b10;
    localparam [1:0] EVENT_ABORT = 2'b11;

    wire packed_valid, packed_ready, packed_last;
    wire cam_frame_start;
    wire [255:0] packed_data;
    wire packer_fault;
    wire event_valid, event_fault;
    wire [1:0] event_code;
    wire fifo_valid, fifo_last, fifo_overflow, fifo_underflow;
    wire [255:0] fifo_data;
    wire writer_frame_ready, writer_beat_ready;
    wire writer_done, writer_aborted, writer_fault;
    reg [15:0] accepted_count;
    reg frame_done_seen, frame_done_sent;
    reg discard_mode, writer_abort_seen;
    reg [1:0] fifo_empty_stable;
    reg allocation_waiting, unallocated_drop, drop_terminal_seen;
    reg drop_last_seen, writer_started;
    reg [1:0] drop_fifo_empty_stable;

    wire source_event_valid = camera_frame_open || camera_frame_done ||
                              camera_frame_abort;
    wire [1:0] source_event_code = camera_frame_open ? EVENT_OPEN :
                                   camera_frame_done ? EVENT_DONE : EVENT_ABORT;
    wire event_open = event_valid && event_code == EVENT_OPEN;
    wire event_done = event_valid && event_code == EVENT_DONE;
    wire event_abort = event_valid && event_code == EVENT_ABORT;
    wire bank_capture_rejected_active = USE_FRAME_BANK_CONTROL ?
                                        bank_capture_rejected : 1'b0;
    wire writer_frame_begin = USE_FRAME_BANK_CONTROL ?
                              (allocation_waiting && bank_capture_grant) :
                              event_open;
    wire [27:0] writer_frame_base = USE_FRAME_BANK_CONTROL ?
                                   bank_capture_base : frame_base;
    wire fifo_to_writer = fifo_valid && writer_beat_ready && !discard_mode &&
                          !unallocated_drop;
    wire fifo_read_take = unallocated_drop ? fifo_valid :
                          discard_mode ? fifo_valid : fifo_to_writer;
    wire writer_frame_done = frame_done_seen &&
                             accepted_count == FRAME_BEATS &&
                             !frame_done_sent;
    wire writer_frame_abort = event_abort && writer_started &&
                               !unallocated_drop;

    assign capture_ready = writer_frame_ready && !discard_mode &&
                          !unallocated_drop && !fault;
    assign unallocated_drop_active = unallocated_drop;
    assign bank_capture_request = USE_FRAME_BANK_CONTROL && event_open;
    camera_vsync_frame_start vsync_to_pixel_domain (
        .pixel_clk(cam_clk), .rst_n(rst_n),
        .vsync_level(cam_vsync_level), .frame_start(cam_frame_start)
    );

    rgb565_frame_beat_packer #(
        .H_PIXELS(H_PIXELS), .V_LINES(V_LINES)
    ) packer (
        .clk(cam_clk), .rst_n(rst_n), .clear(cam_clear),
        .frame_start(cam_frame_start), .arm(cam_arm),
        .pixel_valid(cam_pixel_valid), .pixel_data(cam_pixel_data),
        .beat_valid(packed_valid), .beat_ready(packed_ready),
        .beat_data(packed_data), .beat_last(packed_last),
        .frame_open(camera_frame_open), .frame_done(camera_frame_done),
        .frame_abort(camera_frame_abort), .fault(packer_fault)
    );

    camera_beat_async_fifo #(.ADDR_BITS(FIFO_ADDR_BITS)) beat_fifo (
        .wr_clk(cam_clk), .rd_clk(ddr_clk), .rst_n(rst_n),
        .wr_valid(packed_valid), .wr_ready(packed_ready),
        .wr_data(packed_data), .wr_last(packed_last),
        .rd_take(fifo_read_take), .rd_valid(fifo_valid),
        .rd_data(fifo_data), .rd_last(fifo_last),
        .overflow(fifo_overflow), .underflow(fifo_underflow)
    );

    camera_frame_event_cdc event_mailbox (
        .src_clk(cam_clk), .dst_clk(ddr_clk), .rst_n(rst_n),
        .src_event_valid(source_event_valid),
        .src_event_code(source_event_code),
        .src_ready(), .src_fault(),
        .dst_fault(event_fault), .dst_event_valid(event_valid),
        .dst_event_code(event_code)
    );

    controlled_frame_write_port #(.FRAME_BURSTS(FRAME_BURSTS)) writer (
        .clk(ddr_clk), .rst_n(rst_n), .frame_begin(writer_frame_begin),
        .frame_base(writer_frame_base), .frame_done(writer_frame_done),
        .abort(writer_frame_abort), .frame_ready(writer_frame_ready),
        .beat_valid(fifo_valid && !discard_mode),
        .beat_ready(writer_beat_ready), .beat_data(fifo_data),
        .axi_awaddr(axi_awaddr), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awuser_ap(axi_awuser_ap),
        .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last),
        .transfer_done(writer_done), .transfer_aborted(writer_aborted),
        .fault(writer_fault)
    );

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            accepted_count <= 0;
            frame_done_seen <= 1'b0;
            frame_done_sent <= 1'b0;
            discard_mode <= 1'b0;
            writer_abort_seen <= 1'b0;
            fifo_empty_stable <= 0;
            allocation_waiting <= 1'b0;
            unallocated_drop <= 1'b0;
            drop_terminal_seen <= 1'b0;
            drop_last_seen <= 1'b0;
            writer_started <= 1'b0;
            drop_fifo_empty_stable <= 0;
            abort_waiting_visibility <= 1'b0;
            abort_recovered <= 1'b0;
            transfer_done <= 1'b0;
            transfer_aborted <= 1'b0;
            fault <= 1'b0;
        end else begin
            abort_recovered <= 1'b0;
            transfer_done <= writer_done;
            transfer_aborted <= writer_aborted;

            if (writer_frame_begin)
                writer_started <= 1'b1;
            if (writer_done || writer_aborted)
                writer_started <= 1'b0;

            if (event_open) begin
                accepted_count <= 0;
                frame_done_seen <= 1'b0;
                frame_done_sent <= 1'b0;
                if (USE_FRAME_BANK_CONTROL)
                    allocation_waiting <= 1'b1;
            end
            if (USE_FRAME_BANK_CONTROL && allocation_waiting &&
                bank_capture_grant) begin
                allocation_waiting <= 1'b0;
            end
            if (bank_capture_rejected_active) begin
                allocation_waiting <= 1'b0;
                unallocated_drop <= 1'b1;
                drop_terminal_seen <= 1'b0;
                drop_last_seen <= 1'b0;
                drop_fifo_empty_stable <= 0;
            end
            if (event_done && !unallocated_drop &&
                !bank_capture_rejected_active)
                frame_done_seen <= 1'b1;
            if (fifo_to_writer)
                accepted_count <= accepted_count + 1'b1;
            if (writer_frame_done)
                frame_done_sent <= 1'b1;

            if (event_abort && !unallocated_drop &&
                !bank_capture_rejected_active) begin
                discard_mode <= 1'b1;
                writer_abort_seen <= 1'b0;
                fifo_empty_stable <= 0;
                abort_waiting_visibility <= 1'b0;
            end

            if (unallocated_drop || bank_capture_rejected_active) begin
                if (event_done || event_abort)
                    drop_terminal_seen <= 1'b1;
                if (fifo_read_take && fifo_last)
                    drop_last_seen <= 1'b1;
                if (fifo_valid)
                    drop_fifo_empty_stable <= 0;
                else if (drop_fifo_empty_stable != 2'b11)
                    drop_fifo_empty_stable <= drop_fifo_empty_stable + 1'b1;

                if (drop_terminal_seen &&
                    (drop_last_seen ||
                     ((event_abort || drop_terminal_seen) &&
                      drop_fifo_empty_stable >= 2))) begin
                    unallocated_drop <= 1'b0;
                    drop_terminal_seen <= 1'b0;
                    drop_last_seen <= 1'b0;
                    drop_fifo_empty_stable <= 0;
                    accepted_count <= 0;
                    frame_done_seen <= 1'b0;
                    frame_done_sent <= 1'b0;
                end
            end
            if (discard_mode) begin
                if (writer_aborted)
                    writer_abort_seen <= 1'b1;
                if (fifo_valid)
                    fifo_empty_stable <= 0;
                else if (fifo_empty_stable != 2'b11)
                    fifo_empty_stable <= fifo_empty_stable + 1'b1;

                if (writer_abort_seen && fifo_empty_stable >= 2)
                    abort_waiting_visibility <= 1'b1;

                if (abort_waiting_visibility && abort_release_authorized) begin
                    discard_mode <= 1'b0;
                    abort_waiting_visibility <= 1'b0;
                    abort_recovered <= 1'b1;
                    writer_abort_seen <= 1'b0;
                    fifo_empty_stable <= 0;
                    accepted_count <= 0;
                    frame_done_seen <= 1'b0;
                    frame_done_sent <= 1'b0;
                end
            end

            if (event_fault || fifo_overflow ||
                fifo_underflow || writer_fault)
                fault <= 1'b1;
        end
    end
endmodule
