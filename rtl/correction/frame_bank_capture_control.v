`timescale 1ns/1ps
// DDR-clock-domain frame bank ownership and capture grant control.
// capture_request must already be synchronized into clk. A grant/base pair
// is valid for one cycle after the owner allocates a bank; a writer must only
// sample frame_base when capture_grant is high. Visibility and abort safety
// remain external proof inputs and are never inferred from HMIC WLAST.
module frame_bank_capture_control (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        capture_request,
    output wire        capture_grant,
    output wire        capture_rejected,
    output wire [27:0] capture_base,
    input  wire        writer_transfer_done,
    input  wire        visibility_confirmed,
    input  wire        writer_transfer_aborted,
    input  wire        abort_safe,
    input  wire        reader_request,
    output wire        reader_grant,
    output wire [27:0] reader_base,
    input  wire        reader_done,
    output wire        ready_valid,
    output wire        read_busy,
    output wire        write_busy,
    output wire [15:0] dropped_frames,
    output wire        waiting_visibility,
    output wire        waiting_abort_safe,
    output wire        fault
);
    wire owner_capture_accepted, owner_capture_dropped;
    wire owner_reader_acquired, owner_fault;
    wire [1:0] write_bank, read_bank, ready_bank;
    wire owner_capture_commit, owner_capture_abort, guard_fault;

    frame_bank_owner3 owner (
        .clk(clk), .rst_n(rst_n),
        .capture_start(capture_request),
        .capture_commit(owner_capture_commit),
        .capture_abort(owner_capture_abort),
        .reader_start(reader_request), .reader_done(reader_done),
        .write_busy(write_busy), .write_bank(write_bank),
        .write_base(capture_base), .ready_valid(ready_valid),
        .ready_bank(ready_bank), .read_busy(read_busy),
        .read_bank(read_bank), .read_base(reader_base),
        .capture_accepted(owner_capture_accepted),
        .capture_dropped(owner_capture_dropped),
        .reader_acquired(owner_reader_acquired),
        .dropped_frames(dropped_frames), .fault(owner_fault)
    );

    frame_bank_visibility_guard guard (
        .clk(clk), .rst_n(rst_n),
        .capture_allocated(owner_capture_accepted),
        .writer_transfer_done(writer_transfer_done),
        .visibility_confirmed(visibility_confirmed),
        .writer_transfer_aborted(writer_transfer_aborted),
        .abort_safe(abort_safe),
        .capture_commit(owner_capture_commit),
        .capture_abort(owner_capture_abort), .fault(guard_fault),
        .waiting_visibility(waiting_visibility),
        .waiting_abort_safe(waiting_abort_safe)
    );

    assign capture_grant = owner_capture_accepted;
    assign capture_rejected = owner_capture_dropped;
    assign reader_grant = owner_reader_acquired;
    assign fault = owner_fault | guard_fault;
endmodule
