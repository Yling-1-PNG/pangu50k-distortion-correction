`timescale 1ns/1ps
// Structural integration probe: connect the allocated camera writer, compile-
// time Brown/fisheye random reader, frame owner, and lifecycle to DDR3_50H.
// External visibility/abort-safe inputs are unverified proof contracts. This
// is not a board top: HDMI clocks/timing and camera control are external;
// board FDC/IO constraints and real visibility-fence sources are absent.
module correction_ddr_dual_master_top #(
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer FRAME_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT,
    parameter signed [21:0] AFFINE_A00_Q20 = 22'sd1048576,
    parameter signed [21:0] AFFINE_A01_Q20 = 22'sd0,
    parameter signed [21:0] AFFINE_A10_Q20 = 22'sd0,
    parameter signed [21:0] AFFINE_A11_Q20 = 22'sd1048576,
    parameter signed [19:0] AFFINE_TX_Q8 = 20'sd0,
    parameter signed [19:0] AFFINE_TY_Q8 = 20'sd0,
    parameter signed [19:0] CAMERA_FX_Q8 = 20'sd128000,
    parameter signed [19:0] CAMERA_FY_Q8 = 20'sd128000,
    parameter [21:0] INV_CAMERA_FX_Q22 = 22'd8389,
    parameter [21:0] INV_CAMERA_FY_Q22 = 22'd8389,
    parameter signed [21:0] BROWN_K1_Q18 = 22'sd0,
    parameter signed [21:0] BROWN_K2_Q18 = 22'sd0,
    parameter signed [21:0] BROWN_P1_Q18 = 22'sd0,
    parameter signed [21:0] BROWN_P2_Q18 = 22'sd0,
    parameter integer USE_FISHEYE = 0,
    parameter integer PIPELINED_COORDINATES = 0,
    parameter integer IDENTITY_MAP_DIAGNOSTIC = 0,
    parameter integer DIAGNOSTIC_PATTERN_WRITER = 0,
    parameter integer DISPLAY_PREFETCH_BURSTS = 0,
    parameter integer DISPLAY_PREFETCH_TRIGGER_PIXELS = 128,
    parameter integer HMIC_FENCE_CHECK_POINTS = 1,
    parameter integer READ_DEPTH = 1,
    parameter integer USE_HMIC_READBACK_FENCE = 0,
    parameter FISHEYE_INIT_FILE = "../../rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter FISHEYE_INIT_FILE_HI = "../../rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter FISHEYE_INIT_FILE_DELTA = "../../rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem",
    parameter signed [19:0] CAMERA_CX_Q8 = IMAGE_WIDTH * 128,
    parameter signed [19:0] CAMERA_CY_Q8 = IMAGE_HEIGHT * 128,
    parameter integer MEM_ROW_ADDR_WIDTH = 15,
    parameter integer MEM_COL_ADDR_WIDTH = 10,
    parameter integer MEM_BADDR_WIDTH = 3,
    parameter integer MEM_DQ_WIDTH = 32,
    parameter integer MEM_DQS_WIDTH = MEM_DQ_WIDTH/8
) (
    input  wire                         sys_clk,
    input  wire                         rst_n,
    input  wire                         cam_pixel_clk,
    input  wire                         cam_vsync_level,
    input  wire                         cam_pixel_valid,
    input  wire [15:0]                  cam_pixel_data,
    input  wire                         cam_arm,
    // Control inputs are asynchronous at the probe boundary; the correction
    // request is synchronized below. Safety-fence inputs are DDR-domain
    // contracts and must only be driven from a proven DDR-domain source.
    input  wire                         correction_start,
    // Atomic runtime correction configuration mailbox, packed as documented
    // in sim/README.md. cfg_valid/data are accepted in sys_clk; cfg_applied
    // acknowledges only after the complete bundle is activated at a safe
    // DDR-reader frame boundary.
    input  wire                         cfg_update_valid,
    output wire                         cfg_update_ready,
    input  wire [339:0]                 cfg_update_data,
    output wire                         cfg_update_applied,
    input  wire                         visibility_confirmed,
    input  wire                         corrected_visibility_confirmed,
    input  wire                         abort_safe,
    input  wire                         video_pixel_clk,
    // Registered sync_vg timing in the video_pixel_clk domain.
    input  wire                         video_timing_vs,
    input  wire                         video_timing_hs,
    input  wire                         video_timing_de,
    // Runtime frame mode from the HDMI clock domain. A synchronized copy is
    // sampled only when a new correction frame is allocated.
    input  wire                         raw_mode_request,
    output wire                         ddr_init_done,
    output wire                         camera_ready,
    output wire                         camera_fault,
    output wire                         camera_transfer_done,
    output wire                         correction_busy,
    output wire                         correction_fault,
    output wire                         corrected_valid,
    output wire [15:0]                  corrected_pixel,
    output wire                         video_frame_ready,
    output wire                         video_path_fault,
    output reg  [15:0]                  diagnostic_seen,
    output reg  [15:0]                  diagnostic_faults,
    output reg  [15:0]                  diagnostic_write_beats,
    output reg  [15:0]                  diagnostic_read_beats,
    output wire [15:0]                  diagnostic_drain_beats,
    output wire [15:0]                  diagnostic_fifo_beats,
    output wire                         hdmi_vs,
    output wire                         hdmi_hs,
    output wire                         hdmi_de,
    output wire [7:0]                   hdmi_r,
    output wire [7:0]                   hdmi_g,
    output wire [7:0]                   hdmi_b,
    output wire                         mem_rst_n,
    output wire                         mem_ck,
    output wire                         mem_ck_n,
    output wire                         mem_cke,
    output wire                         mem_cs_n,
    output wire                         mem_ras_n,
    output wire                         mem_cas_n,
    output wire                         mem_we_n,
    output wire                         mem_odt,
    output wire [MEM_ROW_ADDR_WIDTH-1:0] mem_a,
    output wire [MEM_BADDR_WIDTH-1:0]   mem_ba,
    inout  wire [MEM_DQ_WIDTH/8-1:0]    mem_dqs,
    inout  wire [MEM_DQ_WIDTH/8-1:0]    mem_dqs_n,
    inout  wire [MEM_DQ_WIDTH-1:0]      mem_dq,
    output wire [MEM_DQ_WIDTH/8-1:0]    mem_dm
);
    localparam integer CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH +
                                         MEM_COL_ADDR_WIDTH + MEM_BADDR_WIDTH;
    localparam signed [19:0] IMAGE_CX_Q8 = IMAGE_WIDTH * 128;
    localparam signed [19:0] IMAGE_CY_Q8 = IMAGE_HEIGHT * 128;
    localparam [339:0] DEFAULT_CORRECTION_CONFIG = {
        AFFINE_A00_Q20, AFFINE_A01_Q20, AFFINE_A10_Q20, AFFINE_A11_Q20,
        AFFINE_TX_Q8, AFFINE_TY_Q8, CAMERA_FX_Q8, CAMERA_FY_Q8,
        CAMERA_CX_Q8, CAMERA_CY_Q8, INV_CAMERA_FX_Q22, INV_CAMERA_FY_Q22,
        BROWN_K1_Q18, BROWN_K2_Q18, BROWN_P1_Q18, BROWN_P2_Q18
    };

    wire [339:0] active_correction_config;
    wire cfg_pending;
    wire signed [21:0] cfg_a00_q20 = active_correction_config[339:318];
    wire signed [21:0] cfg_a01_q20 = active_correction_config[317:296];
    wire signed [21:0] cfg_a10_q20 = active_correction_config[295:274];
    wire signed [21:0] cfg_a11_q20 = active_correction_config[273:252];
    wire signed [19:0] cfg_tx_q8 = active_correction_config[251:232];
    wire signed [19:0] cfg_ty_q8 = active_correction_config[231:212];
    wire signed [19:0] cfg_fx_q8 = active_correction_config[211:192];
    wire signed [19:0] cfg_fy_q8 = active_correction_config[191:172];
    wire signed [19:0] cfg_cx_q8 = active_correction_config[171:152];
    wire signed [19:0] cfg_cy_q8 = active_correction_config[151:132];
    wire [21:0] cfg_inv_fx_q22 = active_correction_config[131:110];
    wire [21:0] cfg_inv_fy_q22 = active_correction_config[109:88];
    wire signed [21:0] cfg_k1_q18 = active_correction_config[87:66];
    wire signed [21:0] cfg_k2_q18 = active_correction_config[65:44];
    wire signed [21:0] cfg_p1_q18 = active_correction_config[43:22];
    wire signed [21:0] cfg_p2_q18 = active_correction_config[21:0];

    wire ddr_clk, pll_lock;
    wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr, axi_araddr;
    wire [3:0] axi_awid, axi_awlen, axi_arid, axi_arlen;
    wire axi_awuser_ap, axi_awvalid, axi_awready;
    wire [255:0] axi_wdata, axi_rdata;
    wire [31:0] axi_wstrb;
    wire axi_wready, axi_wlast;
    wire axi_aruser_ap, axi_arvalid, axi_arready;
    wire axi_rvalid, axi_rlast;
    wire [3:0] axi_rid;

    wire [27:0] camera_awaddr, corrected_awaddr;
    wire [3:0] camera_awid, camera_awlen, corrected_awid, corrected_awlen;
    wire camera_awap, camera_awvalid, camera_awready;
    wire corrected_awap, corrected_awvalid, corrected_awready;
    wire [255:0] camera_wdata, corrected_wdata;
    wire [31:0] camera_wstrb, corrected_wstrb;
    wire camera_wready, camera_wlast, corrected_wready, corrected_wlast;
    wire [27:0] brown_araddr, display_araddr;
    wire [3:0] brown_arid, brown_arlen, display_arid, display_arlen;
    wire brown_arap, brown_arvalid, brown_arready;
    wire display_arap, display_arvalid, display_arready;
    wire [255:0] brown_rdata, display_rdata;
    wire [3:0] brown_rid, display_rid;
    wire brown_rlast, brown_rvalid, display_rlast, display_rvalid;
    reg [255:0] display_rdata_q;
    reg [3:0] display_rid_q;
    reg display_rlast_q, display_rvalid_q;
    reg raw_mode_meta, raw_mode_sync;
    wire [27:0] arb_araddr, corrected_fence_araddr;
    wire [3:0] arb_arid, arb_arlen, corrected_fence_arid,
               corrected_fence_arlen;
    wire arb_arap, arb_arvalid, arb_arready;
    wire corrected_fence_arap, corrected_fence_arvalid,
         corrected_fence_arready;
    wire [255:0] arb_rdata, corrected_fence_rdata;
    wire [3:0] arb_rid, corrected_fence_rid;
    wire arb_rlast, arb_rvalid, corrected_fence_rlast,
         corrected_fence_rvalid;
    wire owner_visibility_confirmed, owner_abort_safe;
    wire camera_visibility_event, corrected_visibility_event;
    wire camera_visibility_busy, corrected_visibility_busy;
    wire camera_visibility_fault, corrected_visibility_fault;
    wire visibility_fence_busy, visibility_fence_fault;
    wire write_arbiter_fault, read_arbiter_fault;

    wire capture_grant, capture_rejected, capture_drop_in_progress;
    wire [27:0] capture_base, read_base;
    wire reader_grant, reader_done, reader_busy;
    wire camera_transfer_aborted, camera_path_fault, frame_owner_fault;
    wire waiting_visibility, waiting_abort_safe;
    wire scan_start_ready, scan_valid, scan_done, scan_ready, scan_busy;
    wire [10:0] scan_x, scan_y;
    wire stream_clear_ready, stream_valid, stream_fault;
    wire [15:0] stream_pixel;
    wire pipeline_clear;
    wire lifecycle_busy, lifecycle_fault;
    wire video_fifo_wr_ready;
    wire video_frame_pending;
    wire video_wr_fault, video_pix_fault, video_fifo_underflow;
    wire corrected_writer_frame_ready, corrected_writer_transfer_done;
    wire corrected_writer_fault, corrected_write_busy, corrected_write_slot;
    wire corrected_write_accepted, corrected_write_rejected;
    wire corrected_frame_owner_fault;
    wire [27:0] corrected_write_base, corrected_display_base;
    wire corrected_display_busy, corrected_display_fault;
    wire corrected_display_launch;
    wire [4:0] display_diagnostic_faults;
    wire [15:0] corrected_dropped_frames;
    wire video_pixel_fire;
    wire corrected_writer_pixel_ready;
    wire corrected_write_pixel_valid;
    wire [15:0] corrected_write_pixel_data;
    wire diagnostic_pattern_valid;
    wire diagnostic_pattern_fault;
    // Keep the frame boundary identical for Brown and pattern A/B builds.
    // DIAGNOSTIC_PATTERN_WRITER changes only the pixel source below.
    wire display_write_start = reader_grant;
    reg [19:0] video_pixel_count;
    reg [3:0] diagnostic_write_beat_index;
    reg [3:0] diagnostic_read_beat_index;
    reg correction_start_meta, correction_start_sync, correction_start_d;
    wire correction_start_pulse = correction_start_sync &&
                                  !correction_start_d;
    // Keep a frame request until the source-bank owner can accept it. The
    // external request is a synchronized one-cycle event, while DDR/visibility
    // arbitration may legitimately keep the reader unavailable for many
    // cycles. Without this pending bit, a request arriving during that window
    // is silently lost and a 30-FPS source becomes an apparent ~15-FPS stream.
    reg correction_request_pending;
    wire correction_request_eligible = ddr_init_done &&
                                       scan_start_ready && !lifecycle_busy &&
                                       !reader_busy &&
                                       corrected_writer_frame_ready &&
                                       corrected_write_slot &&
                                       !visibility_fence_busy;

    hmic_two_writer_burst_arbiter write_arbiter (
        .clk(ddr_clk), .rst_n(rst_n),
        .m0_awaddr(camera_awaddr), .m0_awid(camera_awid),
        .m0_awlen(camera_awlen), .m0_awap(camera_awap),
        .m0_awvalid(camera_awvalid), .m0_awready(camera_awready),
        .m0_wdata(camera_wdata), .m0_wstrb(camera_wstrb),
        .m0_wready(camera_wready), .m0_wlast(camera_wlast),
        .m1_awaddr(corrected_awaddr), .m1_awid(corrected_awid),
        .m1_awlen(corrected_awlen), .m1_awap(corrected_awap),
        .m1_awvalid(corrected_awvalid), .m1_awready(corrected_awready),
        .m1_wdata(corrected_wdata), .m1_wstrb(corrected_wstrb),
        .m1_wready(corrected_wready), .m1_wlast(corrected_wlast),
        .s_awaddr(axi_awaddr), .s_awid(axi_awid), .s_awlen(axi_awlen),
        .s_awap(axi_awuser_ap), .s_awvalid(axi_awvalid),
        .s_awready(axi_awready), .s_wdata(axi_wdata),
        .s_wstrb(axi_wstrb), .s_wready(axi_wready), .s_wlast(axi_wlast),
        .fault(write_arbiter_fault)
    );

    hmic_two_reader_id_arbiter #(.DISPLAY_ID(4'he), .FENCE_ID(4'hf))
    read_arbiter (
        .clk(ddr_clk), .rst_n(rst_n),
        .m0_araddr(brown_araddr), .m0_arap(brown_arap),
        .m0_arid(brown_arid), .m0_arlen(brown_arlen),
        .m0_arvalid(brown_arvalid), .m0_arready(brown_arready),
        .m0_rdata(brown_rdata), .m0_rid(brown_rid),
        .m0_rlast(brown_rlast), .m0_rvalid(brown_rvalid),
        .m1_araddr(display_araddr), .m1_arap(display_arap),
        .m1_arid(display_arid), .m1_arlen(display_arlen),
        .m1_arvalid(display_arvalid), .m1_arready(display_arready),
        .m1_rdata(display_rdata), .m1_rid(display_rid),
        .m1_rlast(display_rlast), .m1_rvalid(display_rvalid),
        .s_araddr(arb_araddr), .s_arap(arb_arap), .s_arid(arb_arid),
        .s_arlen(arb_arlen), .s_arvalid(arb_arvalid),
        .s_arready(arb_arready), .s_rdata(arb_rdata), .s_rid(arb_rid),
        .s_rlast(arb_rlast), .s_rvalid(arb_rvalid),
        .fault(read_arbiter_fault)
    );

    // HMIC has no RREADY: this fixed-latency stage accepts every cycle,
    // carrying data/ID/last together. It cuts the response/fence control
    // cone before the display reader's wide burst-register enables.
    // Even an AR-coincident first beat reaches the reader in its S_R state.
    always @(posedge ddr_clk) begin
        display_rdata_q <= display_rdata;
        display_rid_q <= display_rid;
        display_rlast_q <= display_rlast;
    end
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n)
            display_rvalid_q <= 1'b0;
        else
            display_rvalid_q <= display_rvalid;
    end

    generate
        if (USE_HMIC_READBACK_FENCE != 0) begin : g_hmic_readback_fences
            hmic_frame_visibility_readback_fence #(
                .FRAME_ADDR_UNITS((IMAGE_WIDTH * IMAGE_HEIGHT * 2) / 4),
                .CHECK_POINTS(HMIC_FENCE_CHECK_POINTS)
            ) camera_visibility_fence (
                .clk(ddr_clk), .rst_n(rst_n),
                .capture_grant(capture_grant), .capture_base(capture_base),
                .frame_transfer_done(camera_transfer_done),
                .frame_transfer_aborted(camera_transfer_aborted),
                .reader_idle(!reader_busy && stream_clear_ready &&
                             !corrected_display_busy &&
                             !corrected_visibility_busy),
                .axi_wdata(camera_wdata), .axi_wready(camera_wready),
                .axi_wlast(camera_wlast),
                .reader_araddr(corrected_fence_araddr),
                .reader_aruser_ap(corrected_fence_arap),
                .reader_arid(corrected_fence_arid),
                .reader_arlen(corrected_fence_arlen),
                .reader_arvalid(corrected_fence_arvalid),
                .reader_arready(corrected_fence_arready),
                .reader_rdata(corrected_fence_rdata),
                .reader_rid(corrected_fence_rid),
                .reader_rlast(corrected_fence_rlast),
                .reader_rvalid(corrected_fence_rvalid),
                .mem_araddr(axi_araddr), .mem_aruser_ap(axi_aruser_ap),
                .mem_arid(axi_arid), .mem_arlen(axi_arlen),
                .mem_arvalid(axi_arvalid), .mem_arready(axi_arready),
                .mem_rdata(axi_rdata), .mem_rid(axi_rid),
                .mem_rlast(axi_rlast), .mem_rvalid(axi_rvalid),
                .visibility_confirmed(camera_visibility_event),
                .busy(camera_visibility_busy), .fault(camera_visibility_fault)
            );
            hmic_frame_visibility_readback_fence #(
                .FRAME_ADDR_UNITS((IMAGE_WIDTH * IMAGE_HEIGHT * 2) / 4),
                .CHECK_POINTS(HMIC_FENCE_CHECK_POINTS)
            ) corrected_visibility_fence (
                .clk(ddr_clk), .rst_n(rst_n),
                .capture_grant(corrected_write_accepted),
                .capture_base(corrected_write_base),
                .frame_transfer_done(corrected_writer_transfer_done),
                .frame_transfer_aborted(1'b0),
                .reader_idle(!reader_busy && stream_clear_ready &&
                             !corrected_display_busy),
                .axi_wdata(corrected_wdata), .axi_wready(corrected_wready),
                .axi_wlast(corrected_wlast),
                .reader_araddr(arb_araddr), .reader_aruser_ap(arb_arap),
                .reader_arid(arb_arid), .reader_arlen(arb_arlen),
                .reader_arvalid(arb_arvalid), .reader_arready(arb_arready),
                .reader_rdata(arb_rdata), .reader_rid(arb_rid),
                .reader_rlast(arb_rlast), .reader_rvalid(arb_rvalid),
                .mem_araddr(corrected_fence_araddr),
                .mem_aruser_ap(corrected_fence_arap),
                .mem_arid(corrected_fence_arid),
                .mem_arlen(corrected_fence_arlen),
                .mem_arvalid(corrected_fence_arvalid),
                .mem_arready(corrected_fence_arready),
                .mem_rdata(corrected_fence_rdata),
                .mem_rid(corrected_fence_rid),
                .mem_rlast(corrected_fence_rlast),
                .mem_rvalid(corrected_fence_rvalid),
                .visibility_confirmed(corrected_visibility_event),
                .busy(corrected_visibility_busy),
                .fault(corrected_visibility_fault)
            );
            assign owner_visibility_confirmed = camera_visibility_event;
            // A partial write has no proven safe-release event; fail closed.
            assign owner_abort_safe = 1'b0;
        end else begin : g_external_visibility_contract
            assign axi_araddr = arb_araddr;
            assign axi_aruser_ap = arb_arap;
            assign axi_arid = arb_arid;
            assign axi_arlen = arb_arlen;
            assign axi_arvalid = arb_arvalid;
            assign arb_arready = axi_arready;
            assign arb_rdata = axi_rdata;
            assign arb_rid = axi_rid;
            assign arb_rlast = axi_rlast;
            assign arb_rvalid = axi_rvalid;
            assign corrected_fence_araddr = arb_araddr;
            assign corrected_fence_arap = arb_arap;
            assign corrected_fence_arid = arb_arid;
            assign corrected_fence_arlen = arb_arlen;
            assign corrected_fence_arvalid = arb_arvalid;
            assign corrected_fence_rdata = axi_rdata;
            assign corrected_fence_rid = axi_rid;
            assign corrected_fence_rlast = axi_rlast;
            assign corrected_fence_rvalid = axi_rvalid;
            assign owner_visibility_confirmed = visibility_confirmed;
            assign corrected_visibility_event = corrected_visibility_confirmed;
            assign owner_abort_safe = abort_safe;
            assign camera_visibility_busy = 1'b0;
            assign corrected_visibility_busy = 1'b0;
            assign camera_visibility_fault = 1'b0;
            assign corrected_visibility_fault = 1'b0;
        end
    endgenerate
    assign visibility_fence_busy = camera_visibility_busy |
                                   corrected_visibility_busy;
    assign visibility_fence_fault = camera_visibility_fault |
                                    corrected_visibility_fault;

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            correction_start_meta <= 1'b0;
            correction_start_sync <= 1'b0;
            correction_start_d <= 1'b0;
            correction_request_pending <= 1'b0;
        end else begin
            correction_start_meta <= correction_start;
            correction_start_sync <= correction_start_meta;
            correction_start_d <= correction_start_sync;
            case ({correction_start_pulse, reader_grant})
                2'b10: correction_request_pending <= 1'b1;
                2'b01,
                2'b11: correction_request_pending <= 1'b0;
                default: ;
            endcase
        end
    end

    // raw_mode_request is already frame-boundary latched in the pixel-clock
    // domain. Synchronize the level into DDR. The mode is consumed only at
    // display-frame allocation below; it does not enter the correction
    // coordinate pipeline.
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_mode_meta <= 1'b0;
            raw_mode_sync <= 1'b0;
        end else begin
            raw_mode_meta <= raw_mode_request;
            raw_mode_sync <= raw_mode_meta;
        end
    end

    frame_config_mailbox #(
        .CONFIG_WIDTH(340), .RESET_CONFIG(DEFAULT_CORRECTION_CONFIG)
    ) correction_config (
        .cfg_clk(sys_clk), .ddr_clk(ddr_clk), .rst_n(rst_n),
        .cfg_valid(cfg_update_valid), .cfg_ready(cfg_update_ready),
        .cfg_data(cfg_update_data), .cfg_applied(cfg_update_applied),
        .safe_to_apply(!reader_busy && !lifecycle_busy && !scan_busy &&
                       stream_clear_ready),
        .active_config(active_correction_config), .pending(cfg_pending)
    );

    camera_to_hmic_allocated_path #(
        .H_PIXELS(IMAGE_WIDTH), .V_LINES(IMAGE_HEIGHT), .FIFO_ADDR_BITS(6)
    ) camera_write_master (
        .cam_clk(cam_pixel_clk), .ddr_clk(ddr_clk), .rst_n(rst_n),
        .cam_clear(1'b0), .cam_arm(cam_arm),
        .cam_vsync_level(cam_vsync_level),
        .cam_pixel_valid(cam_pixel_valid), .cam_pixel_data(cam_pixel_data),
        .visibility_confirmed(owner_visibility_confirmed),
        .abort_safe(owner_abort_safe),
        .reader_request((correction_request_pending || correction_start_pulse) &&
                        correction_request_eligible),
        .reader_done(reader_done), .capture_ready(camera_ready),
        .capture_grant(capture_grant), .capture_rejected(capture_rejected),
        .capture_drop_in_progress(capture_drop_in_progress),
        .capture_base(capture_base), .reader_grant(reader_grant),
        .reader_busy(reader_busy),
        .reader_base(read_base), .transfer_done(camera_transfer_done),
        .transfer_aborted(camera_transfer_aborted),
        .waiting_visibility(waiting_visibility),
        .waiting_abort_safe(waiting_abort_safe),
        .path_fault(camera_path_fault), .owner_fault(frame_owner_fault),
        .axi_awaddr(camera_awaddr), .axi_awuser_id(camera_awid),
        .axi_awlen(camera_awlen), .axi_awuser_ap(camera_awap),
        .axi_awvalid(camera_awvalid), .axi_awready(camera_awready),
        .axi_wdata(camera_wdata), .axi_wstrb(camera_wstrb),
        .axi_wready(camera_wready), .axi_wusero_last(camera_wlast)
    );
    assign camera_fault = camera_path_fault | frame_owner_fault |
                          visibility_fence_fault | waiting_abort_safe;

    raster_coordinate_source #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT)
    ) coordinate_scan (
        .clk(ddr_clk), .rst_n(rst_n),
        .start(reader_grant && ddr_init_done && scan_start_ready),
        .start_ready(scan_start_ready), .busy(scan_busy),
        .out_valid(scan_valid), .out_ready(scan_ready),
        .out_x(scan_x), .out_y(scan_y), .input_done(scan_done)
    );

    correction_read_lifecycle #(.FRAME_PIXELS(FRAME_PIXELS)) read_lifecycle (
        .clk(ddr_clk), .rst_n(rst_n), .start(reader_grant),
        .input_done(scan_done), .pixel_valid(corrected_valid),
        .pixel_ready(video_fifo_wr_ready),
        .pipeline_clear_ready(stream_clear_ready),
        .pipeline_clear(pipeline_clear), .reader_done(reader_done),
        .busy(lifecycle_busy), .fault(lifecycle_fault)
    );
    corrected_frame_hmic_write_path #(
        .H_PIXELS(IMAGE_WIDTH), .V_LINES(IMAGE_HEIGHT)
    ) corrected_write_master (
        .clk(ddr_clk), .rst_n(rst_n),
        .frame_begin(corrected_write_accepted),
        .frame_base(corrected_write_base),
        .frame_ready(corrected_writer_frame_ready),
        .pixel_valid(corrected_write_pixel_valid),
        .pixel_ready(corrected_writer_pixel_ready),
        .pixel_data(corrected_write_pixel_data),
        .axi_awaddr(corrected_awaddr), .axi_awuser_id(corrected_awid),
        .axi_awlen(corrected_awlen), .axi_awuser_ap(corrected_awap),
        .axi_awvalid(corrected_awvalid), .axi_awready(corrected_awready),
        .axi_wdata(corrected_wdata), .axi_wstrb(corrected_wstrb),
        .axi_wready(corrected_wready), .axi_wusero_last(corrected_wlast),
        .transfer_done(corrected_writer_transfer_done),
        .fault(corrected_writer_fault)
    );
    assign correction_busy = scan_busy | lifecycle_busy | reader_busy |
                            corrected_write_busy | corrected_display_busy;
    assign video_pixel_fire = corrected_write_pixel_valid &&
                              corrected_writer_pixel_ready;

    generate
        if (DIAGNOSTIC_PATTERN_WRITER != 0) begin : g_pattern_writer
            // Substitute only pixel payload: keep Brown's valid/ready cadence
            // and start the pattern after the corrected-frame owner accepts
            // the same frame that the normal Brown writer would use.
            diagnostic_rgb565_pattern_source #(
                .H_PIXELS(IMAGE_WIDTH), .V_LINES(IMAGE_HEIGHT)
            ) pattern_source (
                .clk(ddr_clk), .rst_n(rst_n),
                .frame_start(corrected_write_accepted),
                .frame_ready(), .pixel_valid(diagnostic_pattern_valid),
                .pixel_ready(corrected_writer_pixel_ready && corrected_valid),
                .pixel_data(corrected_write_pixel_data),
                .frame_done(), .fault(diagnostic_pattern_fault)
            );
            assign video_fifo_wr_ready = corrected_writer_pixel_ready;
            assign corrected_write_pixel_valid = diagnostic_pattern_valid &&
                                                 corrected_valid;
        end else begin : g_normal_writer
            assign diagnostic_pattern_valid = 1'b0;
            assign diagnostic_pattern_fault = 1'b0;
            assign video_fifo_wr_ready = corrected_writer_pixel_ready;
            assign corrected_write_pixel_valid = corrected_valid;
            assign corrected_write_pixel_data = corrected_pixel;
        end
    endgenerate

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n)
            video_pixel_count <= 20'd0;
        else if (display_write_start)
            video_pixel_count <= 20'd0;
        else if (video_pixel_fire && video_pixel_count < FRAME_PIXELS)
            video_pixel_count <= video_pixel_count + 1'b1;
    end

    brown_cached_stream #(
        .READ_DEPTH(READ_DEPTH), .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .USE_FISHEYE(USE_FISHEYE),
        .PIPELINED_COORDINATES(PIPELINED_COORDINATES),
        .IDENTITY_MAP_DIAGNOSTIC(IDENTITY_MAP_DIAGNOSTIC),
        .FISHEYE_INIT_FILE(FISHEYE_INIT_FILE),
        .FISHEYE_INIT_FILE_HI(FISHEYE_INIT_FILE_HI),
        .FISHEYE_INIT_FILE_DELTA(FISHEYE_INIT_FILE_DELTA)
    ) brown_read_master (
        .clk(ddr_clk), .rst_n(rst_n), .clear(pipeline_clear),
        .clear_ready(stream_clear_ready),
        .in_valid(scan_valid), .in_ready(scan_ready),
        .out_x(scan_x), .out_y(scan_y),
        .a00_q20(cfg_a00_q20), .a01_q20(cfg_a01_q20),
        .a10_q20(cfg_a10_q20), .a11_q20(cfg_a11_q20),
        .tx_q8(cfg_tx_q8), .ty_q8(cfg_ty_q8),
        .fx_q8(cfg_fx_q8), .fy_q8(cfg_fy_q8),
        .cx_q8(cfg_cx_q8), .cy_q8(cfg_cy_q8),
        .inv_fx_q22(cfg_inv_fx_q22), .inv_fy_q22(cfg_inv_fy_q22),
        .out_cx_q8(IMAGE_CX_Q8), .out_cy_q8(IMAGE_CY_Q8),
        .inv_out_fx_q22(cfg_inv_fx_q22), .inv_out_fy_q22(cfg_inv_fy_q22),
        .k1_q18(cfg_k1_q18), .k2_q18(cfg_k2_q18),
        .p1_q18(cfg_p1_q18), .p2_q18(cfg_p2_q18),
        .frame_base_ctrl_addr(read_base),
        .out_valid(corrected_valid), .out_ready(video_fifo_wr_ready),
        .out_pixel(corrected_pixel), .fault(stream_fault),
        .axi_araddr(brown_araddr), .axi_aruser_ap(brown_arap),
        .axi_aruser_id(brown_arid), .axi_arlen(brown_arlen),
        .axi_arvalid(brown_arvalid), .axi_arready(brown_arready),
        .axi_rdata(brown_rdata), .axi_rid(brown_rid),
        .axi_rlast(brown_rlast), .axi_rvalid(brown_rvalid)
    );

    corrected_frame_display_pipeline #(
        .FRAME_PIXELS(FRAME_PIXELS),
        .PREFILL_PIXELS(FRAME_PIXELS < 1024 ? FRAME_PIXELS/2 : 1024),
        .FIFO_ADDR_BITS(11), .DISPLAY_READ_ID(4'he),
        .PREFETCH_BURSTS(DISPLAY_PREFETCH_BURSTS),
        .PREFETCH_TRIGGER_PIXELS(DISPLAY_PREFETCH_TRIGGER_PIXELS),
        .RESPONSE_VALID_REGISTERED(1),
        .DEFER_REPLAY_UNTIL_READY(0)
    ) corrected_display_path (
        .ddr_clk(ddr_clk), .pix_clk(video_pixel_clk), .rst_n(rst_n),
        .write_start(display_write_start), .write_visible(corrected_visibility_event),
        .write_abort_safe(1'b0), .write_busy(corrected_write_busy),
        .display_raw_mode(raw_mode_sync), .raw_frame_base(read_base),
        .write_base(corrected_write_base),
        .write_accepted(corrected_write_accepted),
        .write_rejected(corrected_write_rejected),
        .write_slot_available(corrected_write_slot),
        .owner_fault(corrected_frame_owner_fault),
        .display_busy(corrected_display_busy),
        .frame_pending(video_frame_pending),
        .dropped_frames(corrected_dropped_frames),
        .display_base(corrected_display_base),
        .arvalid(display_arvalid), .arready(display_arready),
        .araddr(display_araddr), .arid(display_arid),
        .arlen(display_arlen), .arap(display_arap),
        .rvalid(display_rvalid_q), .rdata(display_rdata_q),
        .rid(display_rid_q), .rlast(display_rlast_q),
        .timing_vs(video_timing_vs), .timing_hs(video_timing_hs),
        .timing_de(video_timing_de), .hdmi_vs(hdmi_vs),
        .hdmi_hs(hdmi_hs), .hdmi_de(hdmi_de), .hdmi_r(hdmi_r),
        .hdmi_g(hdmi_g), .hdmi_b(hdmi_b), .video_fault(corrected_display_fault),
        .diagnostic_faults(display_diagnostic_faults),
        .diagnostic_launch(corrected_display_launch),
        .diagnostic_drain_beats(diagnostic_drain_beats),
        .diagnostic_fifo_beats(diagnostic_fifo_beats)
    );
    assign video_frame_ready = corrected_writer_frame_ready &&
                               corrected_write_slot && !corrected_writer_fault &&
                               !corrected_display_fault;
    assign video_wr_fault = 1'b0;
    assign video_pix_fault = 1'b0;
    assign video_fifo_underflow = 1'b0;
    assign video_path_fault = corrected_display_fault;
    // Sticky stage markers are sampled by the diagnostic HDMI overlay. They
    // are observations only and do not participate in flow control.
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n)
            diagnostic_seen <= 16'd0;
        else
            diagnostic_seen <= diagnostic_seen | {
                corrected_display_fault, correction_fault, camera_fault,
                video_pixel_count == FRAME_PIXELS, video_pixel_fire,
                display_rvalid, display_arvalid && display_arready,
                corrected_display_launch, corrected_visibility_event,
                corrected_writer_transfer_done, corrected_write_accepted,
                reader_grant, owner_visibility_confirmed,
                camera_transfer_done, camera_ready, ddr_init_done
            };
    end
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n)
            diagnostic_faults <= 16'd0;
        else
            diagnostic_faults <= diagnostic_faults | {
                corrected_write_rejected, display_diagnostic_faults,
                corrected_frame_owner_fault, visibility_fence_fault,
                read_arbiter_fault, write_arbiter_fault,
                corrected_display_fault, corrected_writer_fault,
                lifecycle_fault, stream_fault, frame_owner_fault,
                camera_path_fault
            };
    end

    // Sticky per-beat data presence for the corrected-frame HMIC port.
    // Beat 0 is the leftmost box; a single lit bit exposes the 256-pixel
    // striping signature without relying on a full-speed logic analyzer.
    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            diagnostic_write_beat_index <= 4'd0;
            diagnostic_read_beat_index <= 4'd0;
            diagnostic_write_beats <= 16'd0;
            diagnostic_read_beats <= 16'd0;
        end else begin
            if (corrected_wready) begin
                if (|corrected_wdata)
                    diagnostic_write_beats[diagnostic_write_beat_index] <= 1'b1;
                diagnostic_write_beat_index <= corrected_wlast ? 4'd0 :
                                               diagnostic_write_beat_index + 1'b1;
            end
            if (display_rvalid) begin
                if (|display_rdata)
                    diagnostic_read_beats[diagnostic_read_beat_index] <= 1'b1;
                diagnostic_read_beat_index <= display_rlast ? 4'd0 :
                                              diagnostic_read_beat_index + 1'b1;
            end
        end
    end

    assign correction_fault = stream_fault | lifecycle_fault |
                              frame_owner_fault | video_path_fault |
                              camera_path_fault | corrected_writer_fault |
                              write_arbiter_fault | read_arbiter_fault |
                              corrected_write_rejected |
                              corrected_frame_owner_fault | visibility_fence_fault |
                              waiting_abort_safe | diagnostic_pattern_fault;

    DDR3_50H ddr3 (
        .ref_clk(sys_clk), .resetn(rst_n), .ddr_init_done(ddr_init_done),
        .ddrphy_clkin(ddr_clk), .pll_lock(pll_lock),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap),
        .axi_awuser_id(axi_awid), .axi_awlen(axi_awlen),
        .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready), .axi_wusero_id(),
        .axi_wusero_last(axi_wlast),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_arid), .axi_arlen(axi_arlen),
        .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(1'b0), .apb_rst_n(1'b1), .apb_sel(1'b0),
        .apb_enable(1'b0), .apb_addr(8'b0), .apb_write(1'b0),
        .apb_ready(), .apb_wdata(16'b0), .apb_rdata(), .apb_int(),
        .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_cs_n(mem_cs_n),
        .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n),
        .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba),
        .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n), .mem_dq(mem_dq),
        .mem_dm(mem_dm), .debug_data(), .debug_slice_state(),
        .debug_calib_ctrl(), .ck_dly_set_bin(), .force_ck_dly_en(1'b0),
        .force_ck_dly_set_bin(8'h05), .dll_step(), .dll_lock(),
        .init_read_clk_ctrl(2'b0), .init_slip_step(4'b0),
        .force_read_clk_ctrl(1'b0), .ddrphy_gate_update_en(1'b0),
        .update_com_val_err_flag(), .rd_fake_stop(1'b0)
    );
endmodule
