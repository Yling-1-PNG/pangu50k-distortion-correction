`timescale 1ns/1ps
// PGL50H board top for the fixed-pose OV5640 -> DDR3 -> correction -> HDMI
// path. Vendor camera/HDMI support modules and the DDR3_50H IP are supplied by
// the matching Pango reference project; this file is the maintained project
// top and does not copy those vendor sources into the repository.
module hdmi_ddr_ov5640_top #(
    parameter integer MEM_ROW_ADDR_WIDTH = 15,
    parameter integer MEM_COL_ADDR_WIDTH = 10,
    parameter integer MEM_BADDR_WIDTH = 3,
    parameter integer MEM_DQ_WIDTH = 32,
    parameter integer MEM_DQS_WIDTH = MEM_DQ_WIDTH / 8,
    parameter integer IMAGE_WIDTH = 1280,
    parameter integer IMAGE_HEIGHT = 720,
    parameter integer READ_DEPTH = 2,
    parameter integer USE_FISHEYE = 1,
    parameter integer PIPELINED_COORDINATES = 1,
    parameter integer IDENTITY_MAP_DIAGNOSTIC = 0,
    parameter integer DIAGNOSTIC_OVERLAY = 0,
    parameter integer DIAGNOSTIC_PATTERN_WRITER = 0,
    parameter integer DISPLAY_PREFETCH_BURSTS = 0,
    parameter integer DISPLAY_PREFETCH_TRIGGER_PIXELS = 128,
    parameter integer HMIC_FENCE_CHECK_POINTS = 3,
    parameter FISHEYE_INIT_FILE = "rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter FISHEYE_INIT_FILE_HI = "rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter FISHEYE_INIT_FILE_DELTA = "rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem",
    // Diagnostic 2026-10-16 fisheye calibration candidate, scaled to 1280x720.
    // These values are not frozen; replace them after the next qualified capture.
    parameter signed [19:0] CAMERA_FX_Q8 = 20'sd107730,
    parameter signed [19:0] CAMERA_FY_Q8 = 20'sd107626,
    parameter signed [19:0] CAMERA_CX_Q8 = 20'sd156137,
    parameter signed [19:0] CAMERA_CY_Q8 = 20'sd88804,
    parameter [21:0] INV_CAMERA_FX_Q22 = 22'd11984,
    parameter [21:0] INV_CAMERA_FY_Q22 = 22'd11984,
    parameter signed [21:0] BROWN_K1_Q18 = -22'sd63182,
    parameter signed [21:0] BROWN_K2_Q18 = 22'sd9937,
    parameter signed [21:0] BROWN_P1_Q18 = 22'sd1597,
    parameter signed [21:0] BROWN_P2_Q18 = -22'sd443
) (
    input  wire                         sys_clk,
    // MES50HP KEY1 (K18), active low.
    input  wire                         key1,
    output wire [1:0]                   cmos_init_done,
    inout  wire                         cmos1_scl,
    inout  wire                         cmos1_sda,
    input  wire                         cmos1_vsync,
    input  wire                         cmos1_href,
    input  wire                         cmos1_pclk,
    input  wire [7:0]                   cmos1_data,
    output wire                         cmos1_reset,
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
    output wire [MEM_DQ_WIDTH/8-1:0]    mem_dm,
    output reg                          heart_beat_led,
    output wire                         ddr_init_done,
    output wire                         rstn_out,
    output wire                         iic_tx_scl,
    inout  wire                         iic_tx_sda,
    output wire                         hdmi_int_led,
    output wire                         pix_clk,
    output wire                         vs_out,
    output wire                         hs_out,
    output wire                         de_out,
    output wire [7:0]                   r_out,
    output wire [7:0]                   g_out,
    output wire [7:0]                   b_out
);
    wire cfg_clk, clk_25M, pll_locked;
    wire init_over_tx, init_over_rx;
    wire iic_scl, iic_sda;
    wire initial_en;
    wire [15:0] cmos1_data_16;
    wire cmos1_href_16, cmos1_pclk_16;
    reg [7:0] cmos1_data_d;
    reg cmos1_href_d, cmos1_vsync_d;
    reg [15:0] reset_delay;
    wire timing_vs, timing_hs, timing_de, timing_de_re;
    wire [11:0] timing_x, timing_y;
    reg timing_vs_d;
    wire correction_start = timing_vs && !timing_vs_d;
    wire camera_fault, correction_fault;
    wire [15:0] diagnostic_seen, diagnostic_faults;
    wire [15:0] diagnostic_write_beats, diagnostic_read_beats;
    wire [15:0] diagnostic_drain_beats, diagnostic_fifo_beats;
    wire [7:0] core_r, core_g, core_b;
    reg [24:0] heartbeat_count;
    localparam [24:0] HEARTBEAT_LIMIT = 25'd25_000_000;
    wire key1_press;
    reg raw_mode_request_sys;
    reg raw_mode_meta_pix, raw_mode_sync_pix, raw_mode_active;

    pgl50h_key_debounce #(
        .DEBOUNCE_CYCLES(1_000_000),
        .ACTIVE_LOW(1)
    ) key1_filter (
        .clk(sys_clk), .rst_n(rstn_out), .key_in(key1),
        .press_pulse(key1_press), .pressed()
    );

    pll u_pll (
        .clkin1(sys_clk), .clkout0(pix_clk), .clkout1(cfg_clk),
        .clkout2(clk_25M), .pll_lock(pll_locked)
    );

    ms72xx_ctl ms72xx_ctl_inst (
        .clk(cfg_clk), .rst_n(rstn_out),
        .init_over_tx(init_over_tx), .init_over_rx(init_over_rx),
        .iic_tx_scl(iic_tx_scl), .iic_tx_sda(iic_tx_sda),
        .iic_scl(iic_scl), .iic_sda(iic_sda)
    );
    // LED1 (B2) is raw mode; LED2 (A2) is corrected mode. Both are active
    // high on MES50HP according to the board manual.
    assign hdmi_int_led = raw_mode_active;
    assign cmos_init_done[1] = ~raw_mode_active;
    assign rstn_out = (reset_delay == 16'h2710);

    always @(posedge cfg_clk) begin
        if (!pll_locked)
            reset_delay <= 16'd0;
        else if (reset_delay != 16'h2710)
            reset_delay <= reset_delay + 1'b1;
    end

    // Toggle in sys_clk, synchronize into pix_clk, and latch only at the
    // start of a video frame. This prevents a mid-frame mode change.
    always @(posedge sys_clk or negedge rstn_out) begin
        if (!rstn_out)
            raw_mode_request_sys <= 1'b0; // corrected mode after reset
        else if (key1_press)
            raw_mode_request_sys <= ~raw_mode_request_sys;
    end

    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            raw_mode_meta_pix <= 1'b0;
            raw_mode_sync_pix <= 1'b0;
            raw_mode_active <= 1'b0;
        end else begin
            raw_mode_meta_pix <= raw_mode_request_sys;
            raw_mode_sync_pix <= raw_mode_meta_pix;
            if (correction_start)
                raw_mode_active <= raw_mode_sync_pix;
        end
    end

    power_on_delay camera_power_on (
        .clk_50M(sys_clk), .reset_n(1'b1),
        .camera1_rstn(cmos1_reset), .camera2_rstn(),
        .camera_pwnd(), .initial_en(initial_en)
    );

    reg_config camera1_config (
        .clk_25M(clk_25M), .camera_rstn(cmos1_reset),
        .initial_en(initial_en), .i2c_sclk(cmos1_scl),
        .i2c_sdat(cmos1_sda), .reg_conf_done(cmos_init_done[0]),
        .reg_index(), .clock_20k()
    );
    always @(posedge cmos1_pclk) begin
        cmos1_data_d <= cmos1_data;
        cmos1_href_d <= cmos1_href;
        cmos1_vsync_d <= cmos1_vsync;
    end
    cmos_8_16bit cmos1_8_16bit (
        .pclk(cmos1_pclk), .rst_n(cmos_init_done[0]),
        .pdata_i(cmos1_data_d), .de_i(cmos1_href_d), .vs_i(cmos1_vsync_d),
        .pixel_clk(cmos1_pclk_16), .pdata_o(cmos1_data_16),
        .de_o(cmos1_href_16)
    );

    sync_vg video_timing (
        .clk(pix_clk), .rstn(rstn_out),
        .vs_out(timing_vs), .hs_out(timing_hs),
        .de_out(timing_de), .de_re(timing_de_re),
        .x_act(timing_x), .y_act(timing_y)
    );

    always @(posedge pix_clk or negedge rstn_out) begin
        if (!rstn_out)
            timing_vs_d <= 1'b0;
        else
            timing_vs_d <= timing_vs;
    end

    correction_ddr_dual_master_top #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .READ_DEPTH(READ_DEPTH), .USE_FISHEYE(USE_FISHEYE),
        .PIPELINED_COORDINATES(PIPELINED_COORDINATES),
        .IDENTITY_MAP_DIAGNOSTIC(IDENTITY_MAP_DIAGNOSTIC),
        .DIAGNOSTIC_PATTERN_WRITER(DIAGNOSTIC_PATTERN_WRITER),
        .DISPLAY_PREFETCH_BURSTS(DISPLAY_PREFETCH_BURSTS),
        .DISPLAY_PREFETCH_TRIGGER_PIXELS(DISPLAY_PREFETCH_TRIGGER_PIXELS),
        .HMIC_FENCE_CHECK_POINTS(HMIC_FENCE_CHECK_POINTS),
        .USE_HMIC_READBACK_FENCE(1),
        .FISHEYE_INIT_FILE(FISHEYE_INIT_FILE),
        .FISHEYE_INIT_FILE_HI(FISHEYE_INIT_FILE_HI),
        .FISHEYE_INIT_FILE_DELTA(FISHEYE_INIT_FILE_DELTA),
        .CAMERA_FX_Q8(CAMERA_FX_Q8), .CAMERA_FY_Q8(CAMERA_FY_Q8),
        .CAMERA_CX_Q8(CAMERA_CX_Q8), .CAMERA_CY_Q8(CAMERA_CY_Q8),
        .INV_CAMERA_FX_Q22(INV_CAMERA_FX_Q22),
        .INV_CAMERA_FY_Q22(INV_CAMERA_FY_Q22),
        .BROWN_K1_Q18(BROWN_K1_Q18), .BROWN_K2_Q18(BROWN_K2_Q18),
        .BROWN_P1_Q18(BROWN_P1_Q18), .BROWN_P2_Q18(BROWN_P2_Q18)
    ) u_correction_core (
        .sys_clk(sys_clk), .rst_n(rstn_out),
        .cam_pixel_clk(cmos1_pclk_16), .cam_vsync_level(cmos1_vsync_d),
        .cam_pixel_valid(cmos1_href_16),
        .cam_pixel_data({cmos1_data_16[4:0], cmos1_data_16[10:5],
                         cmos1_data_16[15:11]}),
        .cam_arm(ddr_init_done && cmos_init_done[0]),
        .correction_start(correction_start),
        .cfg_update_valid(1'b0), .cfg_update_ready(),
        .cfg_update_data(340'd0), .cfg_update_applied(),
        .visibility_confirmed(1'b0),
        .corrected_visibility_confirmed(1'b0), .abort_safe(1'b0),
        .video_pixel_clk(pix_clk), .video_timing_vs(timing_vs),
        .video_timing_hs(timing_hs), .video_timing_de(timing_de),
        .raw_mode_request(raw_mode_active),
        .ddr_init_done(ddr_init_done), .camera_ready(),
        .camera_fault(camera_fault), .camera_transfer_done(),
        .correction_busy(), .correction_fault(correction_fault),
        .corrected_valid(), .corrected_pixel(), .video_frame_ready(),
        .video_path_fault(), .diagnostic_seen(diagnostic_seen),
        .diagnostic_faults(diagnostic_faults),
        .diagnostic_write_beats(diagnostic_write_beats),
        .diagnostic_read_beats(diagnostic_read_beats),
        .diagnostic_drain_beats(diagnostic_drain_beats),
        .diagnostic_fifo_beats(diagnostic_fifo_beats),
        .hdmi_vs(vs_out), .hdmi_hs(hs_out),
        .hdmi_de(de_out), .hdmi_r(core_r), .hdmi_g(core_g), .hdmi_b(core_b),
        .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_cs_n(mem_cs_n), .mem_ras_n(mem_ras_n),
        .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n), .mem_odt(mem_odt),
        .mem_a(mem_a), .mem_ba(mem_ba), .mem_dqs(mem_dqs),
        .mem_dqs_n(mem_dqs_n), .mem_dq(mem_dq), .mem_dm(mem_dm)
    );

    generate
        if (DIAGNOSTIC_OVERLAY != 0) begin : g_diagnostic_overlay
            reg [15:0] seen_sync1, seen_sync2;
            reg [15:0] fault_sync1, fault_sync2;
            reg [15:0] write_sync1, write_sync2;
            reg [15:0] read_sync1, read_sync2;
            reg [15:0] drain_sync1, drain_sync2;
            reg [15:0] fifo_sync1, fifo_sync2;
            reg [7:0] overlay_r, overlay_g, overlay_b;
            always @(posedge pix_clk or negedge rstn_out) begin
                if (!rstn_out) begin
                    seen_sync1 <= 16'd0;
                    seen_sync2 <= 16'd0;
                    fault_sync1 <= 16'd0;
                    fault_sync2 <= 16'd0;
                    write_sync1 <= 16'd0;
                    write_sync2 <= 16'd0;
                    read_sync1 <= 16'd0;
                    read_sync2 <= 16'd0;
                    drain_sync1 <= 16'd0;
                    drain_sync2 <= 16'd0;
                    fifo_sync1 <= 16'd0;
                    fifo_sync2 <= 16'd0;
                end else begin
                    seen_sync1 <= diagnostic_seen;
                    seen_sync2 <= seen_sync1;
                    fault_sync1 <= diagnostic_faults;
                    fault_sync2 <= fault_sync1;
                    write_sync1 <= diagnostic_write_beats;
                    write_sync2 <= write_sync1;
                    read_sync1 <= diagnostic_read_beats;
                    read_sync2 <= read_sync1;
                    drain_sync1 <= diagnostic_drain_beats;
                    drain_sync2 <= drain_sync1;
                    fifo_sync1 <= diagnostic_fifo_beats;
                    fifo_sync2 <= fifo_sync1;
                end
            end
            // Minimal six-row status marker: 16 cells per row, 4 pixels per
            // cell, and 4 pixels per row.  The previous 256x48 strip still
            // made the timing_x/timing_y and RGB mux cross a relatively large
            // video region and was difficult to route.  Keep the same sticky
            // event vectors but bound the observation area to 64x24 so this
            // diagnostic build stays physically lightweight.
            wire overlay_on = timing_de && timing_x < 12'd64 &&
                              timing_y < 12'd24;
            wire [3:0] overlay_bit = timing_x[5:2];
            wire [2:0] overlay_row = timing_y[4:2];
            wire overlay_value =
                overlay_row == 3'd0 ? seen_sync2[overlay_bit] :
                overlay_row == 3'd1 ? fault_sync2[overlay_bit] :
                overlay_row == 3'd2 ? write_sync2[overlay_bit] :
                overlay_row == 3'd3 ? read_sync2[overlay_bit] :
                overlay_row == 3'd4 ? drain_sync2[overlay_bit] :
                fifo_sync2[overlay_bit];
            always @* begin
                if (overlay_row == 3'd0) begin
                    overlay_r = overlay_value ? 8'd0 : 8'd96;
                    overlay_g = overlay_value ? 8'd255 : 8'd0;
                    overlay_b = 8'd0;
                end else if (overlay_row == 3'd1) begin
                    overlay_r = overlay_value ? 8'd255 : 8'd0;
                    overlay_g = 8'd0;
                    overlay_b = overlay_value ? 8'd0 : 8'd64;
                end else if (overlay_row == 3'd3) begin
                    overlay_r = 8'd0;
                    overlay_g = overlay_value ? 8'd255 : 8'd0;
                    overlay_b = overlay_value ? 8'd255 : 8'd48;
                end else begin
                    overlay_r = overlay_value ? 8'd255 : 8'd48;
                    overlay_g = overlay_value ? 8'd255 : 8'd0;
                    overlay_b = 8'd0;
                end
            end
            assign r_out = overlay_on ? overlay_r : core_r;
            assign g_out = overlay_on ? overlay_g : core_g;
            assign b_out = overlay_on ? overlay_b : core_b;
        end else begin : g_normal_video
            assign r_out = core_r;
            assign g_out = core_g;
            assign b_out = core_b;
        end
    endgenerate

    always @(posedge sys_clk or negedge rstn_out) begin
        if (!rstn_out) begin
            heartbeat_count <= 25'd0;
            heart_beat_led <= 1'b0;
        end else if (!ddr_init_done) begin
            heartbeat_count <= 25'd0;
            heart_beat_led <= 1'b0;
        end else if (heartbeat_count == HEARTBEAT_LIMIT - 1'b1) begin
            heartbeat_count <= 25'd0;
            heart_beat_led <= ~heart_beat_led;
        end else begin
            heartbeat_count <= heartbeat_count + 1'b1;
        end
    end

    wire unused_board_signals = init_over_rx ^ timing_de_re ^
                                (|timing_x) ^ (|timing_y) ^
                                camera_fault ^ correction_fault;
endmodule
