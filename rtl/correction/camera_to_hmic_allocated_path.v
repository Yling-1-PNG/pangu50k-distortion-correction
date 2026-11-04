`timescale 1ns/1ps
// Camera frame writer with three-bank ownership. Camera frame events cross
// through the path's mailbox; bank allocation and grant/base are DDR-domain.
// Safety proof inputs remain explicit external contracts, not HMIC inferences.
module camera_to_hmic_allocated_path #(
    parameter integer H_PIXELS = 1280,
    parameter integer V_LINES = 720,
    parameter integer FIFO_ADDR_BITS = 6
) (
    input  wire         cam_clk,
    input  wire         ddr_clk,
    input  wire         rst_n,
    input  wire         cam_clear,
    input  wire         cam_arm,
    input  wire         cam_vsync_level,
    input  wire         cam_pixel_valid,
    input  wire [15:0]  cam_pixel_data,
    input  wire         visibility_confirmed,
    input  wire         abort_safe,
    input  wire         reader_request,
    input  wire         reader_done,
    output wire         capture_ready,
    output wire         capture_grant,
    output wire         capture_rejected,
    output wire         capture_drop_in_progress,
    output wire [27:0]  capture_base,
    output wire         reader_grant,
    output wire         reader_busy,
    output wire [27:0]  reader_base,
    output wire         transfer_done,
    output wire         transfer_aborted,
    output wire         waiting_visibility,
    output wire         waiting_abort_safe,
    output wire         path_fault,
    output wire         owner_fault,
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
    wire bank_capture_request;
    wire abort_waiting_visibility, abort_recovered;
    wire camera_frame_open, camera_frame_done, camera_frame_abort;
    wire [27:0] allocated_base;
    wire [15:0] dropped_frames;
    wire ready_valid, read_busy, write_busy;

    assign capture_base = allocated_base;
    assign reader_busy = read_busy;

    camera_to_hmic_write_path #(
        .H_PIXELS(H_PIXELS), .V_LINES(V_LINES),
        .FIFO_ADDR_BITS(FIFO_ADDR_BITS), .USE_FRAME_BANK_CONTROL(1)
    ) writer_path (
        .cam_clk(cam_clk), .ddr_clk(ddr_clk), .rst_n(rst_n),
        .cam_clear(cam_clear), .cam_arm(cam_arm),
        .cam_vsync_level(cam_vsync_level),
        .cam_pixel_valid(cam_pixel_valid), .cam_pixel_data(cam_pixel_data),
        .frame_base(28'd0), .abort_release_authorized(abort_safe),
        .bank_capture_request(bank_capture_request),
        .bank_capture_grant(capture_grant),
        .bank_capture_rejected(capture_rejected),
        .bank_capture_base(allocated_base),
        .capture_ready(capture_ready),
        .unallocated_drop_active(capture_drop_in_progress),
        .abort_waiting_visibility(abort_waiting_visibility),
        .abort_recovered(abort_recovered),
        .camera_frame_open(camera_frame_open),
        .camera_frame_done(camera_frame_done),
        .camera_frame_abort(camera_frame_abort),
        .transfer_done(transfer_done),
        .transfer_aborted(transfer_aborted), .fault(path_fault),
        .axi_awaddr(axi_awaddr), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awuser_ap(axi_awuser_ap),
        .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last)
    );

    frame_bank_capture_control bank_control (
        .clk(ddr_clk), .rst_n(rst_n),
        .capture_request(bank_capture_request),
        .capture_grant(capture_grant),
        .capture_rejected(capture_rejected),
        .capture_base(allocated_base),
        .writer_transfer_done(transfer_done),
        .visibility_confirmed(visibility_confirmed),
        .writer_transfer_aborted(transfer_aborted), .abort_safe(abort_safe),
        .reader_request(reader_request), .reader_grant(reader_grant),
        .reader_base(reader_base), .reader_done(reader_done),
        .ready_valid(ready_valid), .read_busy(read_busy),
        .write_busy(write_busy), .dropped_frames(dropped_frames),
        .waiting_visibility(waiting_visibility),
        .waiting_abort_safe(waiting_abort_safe), .fault(owner_fault)
    );
endmodule
