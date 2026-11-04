// Corrected-frame replay path from DDR HMIC reads to the HDMI pixel stream.
// The frame owner launches the first committed bank immediately, then selects
// or replays a bank after each pixel-domain frame_done event. Starting the
// next DDR read near the end of active video leaves vertical blanking for the
// FIFO prefill request to reach the next VS edge.
module corrected_frame_display_pipeline #(
    parameter integer FRAME_PIXELS = 1280 * 720,
    parameter integer PREFILL_PIXELS = FRAME_PIXELS < 1024 ? FRAME_PIXELS/2 : 1024,
    parameter integer FIFO_ADDR_BITS = 11,
    parameter [3:0] DISPLAY_READ_ID = 4'he,
    parameter integer DEFER_REPLAY_UNTIL_READY = 0,
    parameter integer PREFETCH_BURSTS = 0,
    parameter integer PREFETCH_TRIGGER_PIXELS = 128,
    parameter integer RESPONSE_VALID_REGISTERED = 0
) (
    input  wire         ddr_clk,
    input  wire         pix_clk,
    input  wire         rst_n,
    input  wire         write_start,
    input  wire         write_visible,
    input  wire         write_abort_safe,
    // Optional display-only replay of the camera frame. The frame owner still
    // tracks the corrected write banks; this override changes only the DDR
    // base supplied to the display reader for the committed display launch.
    input  wire         display_raw_mode,
    input  wire [27:0]  raw_frame_base,
    output wire         write_busy,
    output wire [27:0]  write_base,
    output wire         write_accepted,
    output wire         write_rejected,
    output wire         write_slot_available,
    output wire         owner_fault,
    output wire         display_busy,
    output wire         frame_pending,
    output wire [15:0]  dropped_frames,
    output wire [27:0]  display_base,
    output wire         arvalid,
    input  wire         arready,
    output wire [27:0]  araddr,
    output wire [3:0]   arid,
    output wire [3:0]   arlen,
    output wire         arap,
    input  wire         rvalid,
    input  wire [255:0] rdata,
    input  wire [3:0]   rid,
    input  wire         rlast,
    input  wire         timing_vs,
    input  wire         timing_hs,
    input  wire         timing_de,
    output wire         hdmi_vs,
    output wire         hdmi_hs,
    output wire         hdmi_de,
    output wire [7:0]   hdmi_r,
    output wire [7:0]   hdmi_g,
    output wire [7:0]   hdmi_b,
    output wire         video_fault,
    output wire [4:0]   diagnostic_faults,
    output wire         diagnostic_launch,
    output wire [15:0]  diagnostic_drain_beats,
    output reg  [15:0]  diagnostic_fifo_beats
);
    reg pix_done_toggle;
    reg raw_frame_mode_q;
    // Capture the active camera frame base together with the mode decision.
    // Keeping this 28-bit address registered avoids routing the live camera
    // bank address through the full display-reader mux fanout.
    reg [27:0] raw_frame_base_q;
    reg done_sync1, done_sync2, done_sync_d;
    wire display_advance = done_sync2 ^ done_sync_d;
    wire display_launch, display_empty, display_missed;
    wire display_valid, display_bank;
    wire read_frame_ready, read_frame_done, read_fault;
    wire [15:0] read_pixel;
    wire read_pixel_valid, fifo_wr_ready;
    wire fifo_rd_valid, fifo_rd_take, fifo_underflow;
    wire [15:0] fifo_rd_pixel;
    wire gate_wr_ready, gate_wr_fault, gate_frame_pending;
    wire pix_frame_done, pix_fault;
    wire read_pixel_fire = read_pixel_valid && fifo_wr_ready;
    wire display_read_idle = read_frame_ready && gate_wr_ready;
    reg [7:0] diagnostic_fifo_pixel_index;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            diagnostic_fifo_pixel_index <= 8'd0;
            diagnostic_fifo_beats <= 16'd0;
        end else if (fifo_rd_take) begin
            if (|fifo_rd_pixel)
                diagnostic_fifo_beats[diagnostic_fifo_pixel_index[7:4]] <= 1'b1;
            diagnostic_fifo_pixel_index <= diagnostic_fifo_pixel_index + 1'b1;
        end
    end

    // Toggle crossing preserves the one-cycle frame completion pulse even
    // when the two clocks have unrelated phase/frequency.
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n)
            pix_done_toggle <= 1'b0;
        else if (pix_frame_done)
            pix_done_toggle <= ~pix_done_toggle;
    end
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            done_sync1 <= 1'b0;
            done_sync2 <= 1'b0;
            done_sync_d <= 1'b0;
            raw_frame_mode_q <= 1'b0;
            raw_frame_base_q <= 28'd0;
        end else begin
            done_sync1 <= pix_done_toggle;
            done_sync2 <= done_sync1;
            done_sync_d <= done_sync2;
            if (write_start) begin
                raw_frame_mode_q <= display_raw_mode;
                if (display_raw_mode)
                    raw_frame_base_q <= raw_frame_base;
            end
        end
    end

    corrected_frame_owner2 #(
        .DEFER_REPLAY_UNTIL_READY(DEFER_REPLAY_UNTIL_READY)
    ) frame_owner (
        .clk(ddr_clk), .rst_n(rst_n),
        .write_start(write_start), .write_visible(write_visible),
        .write_abort_safe(write_abort_safe), .write_busy(write_busy),
        .write_bank(), .write_base(write_base),
        .write_accepted(write_accepted), .write_rejected(write_rejected),
        .write_slot_available(write_slot_available),
        .display_advance(display_advance), .display_read_idle(display_read_idle),
        .display_valid(display_valid), .display_bank(display_bank),
        .display_base(display_base), .display_launch(display_launch),
        .display_empty(display_empty), .display_missed(display_missed),
        .dropped_frames(dropped_frames), .fault(owner_fault)
    );

    corrected_frame_hmic_read_path #(
        .FRAME_PIXELS(FRAME_PIXELS), .READ_ID(DISPLAY_READ_ID),
        .PREFETCH_BURSTS(PREFETCH_BURSTS),
        .PREFETCH_TRIGGER_PIXELS(PREFETCH_TRIGGER_PIXELS),
        .RESPONSE_VALID_REGISTERED(RESPONSE_VALID_REGISTERED)
    ) frame_reader (
        .clk(ddr_clk), .rst_n(rst_n), .frame_start(display_launch),
        // Both the mode and the raw-frame base are latched at the camera-frame
        // boundary. The reader therefore sees a stable address for the whole
        // display transaction, while the live camera bank address is kept off
        // the high-fanout HMIC read mux.
        .frame_base(raw_frame_mode_q ? raw_frame_base_q : display_base),
        .frame_ready(read_frame_ready),
        .frame_done(read_frame_done), .pixel_valid(read_pixel_valid),
        .pixel_ready(fifo_wr_ready), .pixel_data(read_pixel),
        .diagnostic_drain_beats(diagnostic_drain_beats),
        .axi_araddr(araddr), .axi_aruser_id(arid), .axi_arlen(arlen),
        .axi_aruser_ap(arap), .axi_arvalid(arvalid),
        .axi_arready(arready), .axi_rdata(rdata), .axi_rid(rid),
        .axi_rlast(rlast), .axi_rvalid(rvalid), .fault(read_fault)
    );

    video_async_fifo #(.ADDR_BITS(FIFO_ADDR_BITS)) pixel_fifo (
        .wr_clk(ddr_clk), .rd_clk(pix_clk), .rst_n(rst_n),
        .wr_valid(read_pixel_valid), .wr_ready(fifo_wr_ready),
        .wr_pixel(read_pixel), .rd_take(fifo_rd_take),
        .rd_valid(fifo_rd_valid), .rd_pixel(fifo_rd_pixel),
        .underflow(fifo_underflow)
    );

    corrected_hdmi_output #(
        .FRAME_PIXELS(FRAME_PIXELS), .PREFILL_PIXELS(PREFILL_PIXELS)
    ) hdmi_output (
        .wr_clk(ddr_clk), .pix_clk(pix_clk), .rst_n(rst_n),
        .wr_frame_begin(display_launch), .wr_pixel_fire(read_pixel_fire),
        .wr_frame_done(read_frame_done), .wr_frame_ready(gate_wr_ready),
        .wr_fault(gate_wr_fault), .timing_vs(timing_vs),
        .timing_hs(timing_hs), .timing_de(timing_de),
        .fifo_rd_valid(fifo_rd_valid), .fifo_rd_pixel(fifo_rd_pixel),
        .fifo_rd_take(fifo_rd_take), .frame_pending(gate_frame_pending),
        .pix_frame_done(pix_frame_done), .pix_fault(pix_fault),
        .hdmi_vs(hdmi_vs), .hdmi_hs(hdmi_hs), .hdmi_de(hdmi_de),
        .hdmi_r(hdmi_r), .hdmi_g(hdmi_g), .hdmi_b(hdmi_b)
    );

    assign display_busy = !read_frame_ready || !gate_wr_ready;
    assign frame_pending = gate_frame_pending;
    assign video_fault = owner_fault | read_fault | gate_wr_fault |
                         pix_fault | fifo_underflow;
    assign diagnostic_faults = {fifo_underflow, pix_fault, gate_wr_fault,
                                read_fault, owner_fault};
    assign diagnostic_launch = display_launch;
    wire unused_status = display_empty ^ display_missed ^ display_valid ^
                         display_bank ^ gate_frame_pending;
endmodule
