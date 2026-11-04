// Synthesizable Brown correction data path, all in one HMIC clock domain.
// Input coefficients and frame_base_ctrl_addr must remain stable until clear
// has drained the pipeline. This is not a camera/HDMI top or DDR write arbiter.
module brown_cached_stream #(
    parameter READ_DEPTH = 8,
    parameter IMAGE_WIDTH = 1280,
    parameter IMAGE_HEIGHT = 720,
    parameter USE_FISHEYE = 0,
    parameter PIPELINED_COORDINATES = 0,
    parameter integer IDENTITY_MAP_DIAGNOSTIC = 0,
    parameter FISHEYE_INIT_FILE = "../../rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter FISHEYE_INIT_FILE_HI = "../../rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter FISHEYE_INIT_FILE_DELTA = "../../rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem"
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    output wire         clear_ready,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [10:0]  out_x, out_y,
    input  wire signed [21:0] a00_q20, a01_q20, a10_q20, a11_q20,
    input  wire signed [19:0] tx_q8, ty_q8,
    input  wire signed [19:0] fx_q8, fy_q8, cx_q8, cy_q8,
    input  wire [21:0]  inv_fx_q22, inv_fy_q22,
    input  wire signed [19:0] out_cx_q8, out_cy_q8,
    input  wire [21:0]  inv_out_fx_q22, inv_out_fy_q22,
    input  wire signed [21:0] k1_q18, k2_q18, p1_q18, p2_q18,
    input  wire [27:0]  frame_base_ctrl_addr,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [15:0]  out_pixel,
    output wire         fault,
    output wire [27:0]  axi_araddr,
    output wire         axi_aruser_ap,
    output wire [3:0]   axi_aruser_id,
    output wire [3:0]   axi_arlen,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rlast,
    input  wire         axi_rvalid
);
    wire queue_in_ready, queue_drain_ready, queue_drain_ready_raw;
    wire queue_fault, bridge_fault;
    wire coord_valid = in_valid && in_ready;
    wire [3:0] queue_occupancy;
    wire [1:0] fisheye_pending;
    wire mapper_empty;
    wire queue_clear = clear && mapper_empty;
    wire queue_accept;
    wire affine_valid, source_valid, address_valid;
    wire signed [19:0] ideal_x_q8, ideal_y_q8;
    wire signed [19:0] source_x_q8, source_y_q8;
    wire [21:0] addr00, addr10, addr01, addr11;
    wire [17:0] beat00, beat10, beat01, beat11;
    wire [3:0] lane00, lane10, lane01, lane11;
    wire [7:0] frac_x, frac_y;
    wire lookup_valid, lookup_ready, result_valid, result_hit;
    wire result_pending, result_miss, bridge_filled_valid;
    wire [17:0] lookup_beat, result_beat;
    wire [8:0] result_token, bridge_filled_token;
    wire [255:0] result_data, bridge_filled_data;
    reg filled_valid_q;
    reg [8:0] filled_token_q;
    reg [255:0] filled_data_q;
    reg [255:0] filled_data_inv_q;
    wire queue_out_valid, queue_out_ready, queue_out_fire, interpolate_valid;
    wire [15:0] p00, p10, p01, p11, interpolated_pixel;
    wire [7:0] queue_fx, queue_fy;
    reg interpolate_input_valid;
    reg [15:0] interpolate_p00, interpolate_p10;
    reg [15:0] interpolate_p01, interpolate_p11;
    reg [7:0] interpolate_fx, interpolate_fy;
    wire bridge_clear_ready;
    reg [15:0] output_fifo [0:3];
    reg [1:0] output_wr_ptr, output_rd_ptr;
    reg [2:0] output_count;
    reg [2:0] interpolate_pending;
    wire output_pop = out_valid && out_ready;
    wire output_push = interpolate_valid;
    wire output_drained = output_count == 0 && interpolate_pending == 0;
    wire bridge_clear = queue_clear && queue_drain_ready && output_drained;

    assign fault = queue_fault || bridge_fault;
    assign queue_drain_ready = queue_drain_ready_raw && !filled_valid_q;
    generate if (PIPELINED_COORDINATES != 0) begin: pipelined_mapping
        wire pipe_in_ready, pipe_out_valid, pipe_map_valid, pipe_empty;
        assign fisheye_pending = 2'b00;
        assign mapper_empty = pipe_empty;
        assign queue_accept = pipe_out_valid;
        assign source_valid = pipe_map_valid;
        assign in_ready = pipe_in_ready && !fault && !clear;

        if (USE_FISHEYE != 0) begin: fish_eye
            fisheye_affine_source_pipeline #(
                .INIT_FILE(FISHEYE_INIT_FILE),
                .INIT_FILE_HI(FISHEYE_INIT_FILE_HI),
                .INIT_FILE_DELTA(FISHEYE_INIT_FILE_DELTA),
                .IDENTITY_MAP_DIAGNOSTIC(IDENTITY_MAP_DIAGNOSTIC)
            ) coordinate_map (
                .clk(clk), .rst_n(rst_n),
                .in_valid(in_valid && !fault && !clear),
                .in_ready(pipe_in_ready), .out_x(out_x), .out_y(out_y),
                .a00_q20(a00_q20), .a01_q20(a01_q20),
                .a10_q20(a10_q20), .a11_q20(a11_q20),
                .tx_q8(tx_q8), .ty_q8(ty_q8),
                .src_fx_q8(fx_q8), .src_fy_q8(fy_q8),
                .src_cx_q8(cx_q8), .src_cy_q8(cy_q8),
                .out_cx_q8(out_cx_q8), .out_cy_q8(out_cy_q8),
                .inv_out_fx_q22(inv_out_fx_q22),
                .inv_out_fy_q22(inv_out_fy_q22),
                .out_valid(pipe_out_valid), .map_valid(pipe_map_valid),
                .pipe_empty(pipe_empty),
                .out_ready(queue_in_ready && !fault),
                .src_x_q8(source_x_q8), .src_y_q8(source_y_q8)
            );
        end else begin: brown
            brown_affine_source_pipeline #(
                .IDENTITY_MAP_DIAGNOSTIC(IDENTITY_MAP_DIAGNOSTIC)
            ) coordinate_map (
                .clk(clk), .rst_n(rst_n),
                .in_valid(in_valid && !fault && !clear),
                .in_ready(pipe_in_ready), .out_x(out_x), .out_y(out_y),
                .a00_q20(a00_q20), .a01_q20(a01_q20),
                .a10_q20(a10_q20), .a11_q20(a11_q20),
                .tx_q8(tx_q8), .ty_q8(ty_q8),
                .fx_q8(fx_q8), .fy_q8(fy_q8),
                .cx_q8(cx_q8), .cy_q8(cy_q8),
                .inv_fx_q22(inv_fx_q22), .inv_fy_q22(inv_fy_q22),
                .k1_q18(k1_q18), .k2_q18(k2_q18),
                .p1_q18(p1_q18), .p2_q18(p2_q18),
                .out_valid(pipe_out_valid), .map_valid(pipe_map_valid),
                .pipe_empty(pipe_empty),
                .out_ready(queue_in_ready && !fault),
                .src_x_q8(source_x_q8), .src_y_q8(source_y_q8)
            );
        end
    end else begin: combinational_mapping
        reg [1:0] pending;
        reg queue_stage_reserved;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                pending <= 0;
            else
                pending <= {pending[0], coord_valid};
        end
        assign fisheye_pending = USE_FISHEYE != 0 ? pending : 2'b00;
        assign mapper_empty = USE_FISHEYE == 0 || fisheye_pending == 0;
        assign queue_accept = USE_FISHEYE != 0 ? fisheye_pending[1] : coord_valid;
        assign in_ready = queue_in_ready && !fault && !clear &&
                          (USE_FISHEYE == 0 ||
                           {1'b0, queue_occupancy} + queue_stage_reserved +
                           fisheye_pending[0] + fisheye_pending[1] < 5'd8);

        // The queue's occupancy output excludes its one-entry input stage.
        // Reserve that slot alongside mapper tokens so a non-elastic fish
        // mapper never emits a coordinate when the queue cannot capture it.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                queue_stage_reserved <= 1'b0;
            else
                queue_stage_reserved <= queue_accept && queue_in_ready;
        end

        inverse_affine_q8 affine (
            .valid_in(coord_valid), .out_x(out_x), .out_y(out_y),
            .a00_q20(a00_q20), .a01_q20(a01_q20),
            .a10_q20(a10_q20), .a11_q20(a11_q20),
            .tx_q8(tx_q8), .ty_q8(ty_q8),
            .valid_out(affine_valid), .ideal_x_q8(ideal_x_q8),
            .ideal_y_q8(ideal_y_q8)
        );
        if (USE_FISHEYE != 0) begin: fish_eye
            fisheye_source_with_rom_q8 #(
                .INIT_FILE(FISHEYE_INIT_FILE), .INIT_FILE_HI(FISHEYE_INIT_FILE_HI)
            ) source (
                .clk(clk), .rst_n(rst_n), .valid_in(affine_valid),
                .ideal_x_q8(ideal_x_q8), .ideal_y_q8(ideal_y_q8),
                .src_fx_q8(fx_q8), .src_fy_q8(fy_q8),
                .src_cx_q8(cx_q8), .src_cy_q8(cy_q8),
                .out_cx_q8(out_cx_q8), .out_cy_q8(out_cy_q8),
                .inv_out_fx_q22(inv_out_fx_q22),
                .inv_out_fy_q22(inv_out_fy_q22),
                .valid_out(source_valid), .src_x_q8(source_x_q8),
                .src_y_q8(source_y_q8)
            );
        end else begin: brown_model
            brown_source_q8 source (
                .valid_in(affine_valid), .ideal_x_q8(ideal_x_q8),
                .ideal_y_q8(ideal_y_q8),
                .fx_q8(fx_q8), .fy_q8(fy_q8),
                .cx_q8(cx_q8), .cy_q8(cy_q8),
                .inv_fx_q22(inv_fx_q22), .inv_fy_q22(inv_fy_q22),
                .k1_q18(k1_q18), .k2_q18(k2_q18),
                .p1_q18(p1_q18), .p2_q18(p2_q18),
                .valid_out(source_valid), .src_x_q8(source_x_q8),
                .src_y_q8(source_y_q8)
            );
        end
    end endgenerate

    // Register the queue's four-neighbour mux output before the bilinear
    // multiplier chain; reserve output FIFO space for every accepted pixel
    // that has not yet been pushed into it.
    assign queue_out_ready = !fault &&
                             {1'b0, output_count} + {1'b0, interpolate_pending} < 4'd4;
    assign queue_out_fire = queue_out_valid && queue_out_ready;
    assign out_valid = output_count != 0 && !fault;
    assign out_pixel = out_valid ? output_fifo[output_rd_ptr] : 16'd0;
    assign clear_ready = queue_drain_ready && mapper_empty &&
                         output_drained &&
                         bridge_clear_ready && !fault;
    four_neighbor_address_q8 #(
        .IMG_WIDTH(IMAGE_WIDTH), .IMG_HEIGHT(IMAGE_HEIGHT)
    ) address (
        .valid_in(source_valid), .src_x_q8(source_x_q8),
        .src_y_q8(source_y_q8), .valid_out(address_valid),
        .addr00(addr00), .addr10(addr10),
        .addr01(addr01), .addr11(addr11),
        .beat00(beat00), .beat10(beat10),
        .beat01(beat01), .beat11(beat11),
        .lane00(lane00), .lane10(lane10),
        .lane01(lane01), .lane11(lane11),
        .frac_x(frac_x), .frac_y(frac_y)
    );
    pixel_beat_wait_queue queue (
        .clk(clk), .rst_n(rst_n), .clear(queue_clear),
        .drain_ready(queue_drain_ready_raw),
        .in_valid(queue_accept), .in_ready(queue_in_ready),
        .occupancy(queue_occupancy),
        .in_source_valid(address_valid),
        .in_beat00(beat00), .in_beat10(beat10),
        .in_beat01(beat01), .in_beat11(beat11),
        .in_lane00(lane00), .in_lane10(lane10),
        .in_lane01(lane01), .in_lane11(lane11),
        .in_fx(frac_x), .in_fy(frac_y),
        .lookup_valid(lookup_valid), .lookup_ready(lookup_ready),
        .lookup_beat(lookup_beat), .result_valid(result_valid),
        .result_hit(result_hit), .result_pending(result_pending),
        .result_miss(result_miss), .result_token(result_token),
        .result_data(result_data), .filled_valid(filled_valid_q),
        .filled_token(filled_token_q), .filled_data(filled_data_q),
        .filled_data_inv(filled_data_inv_q),
        .out_valid(queue_out_valid), .out_ready(queue_out_ready),
        .out_p00(p00), .out_p10(p10),
        .out_p01(p01), .out_p11(p11),
        .out_fx(queue_fx), .out_fy(queue_fy), .fault(queue_fault)
    );
    beat_cache_read_bridge #(.READ_DEPTH(READ_DEPTH)) bridge (
        .clk(clk), .rst_n(rst_n), .clear(bridge_clear),
        .clear_ready(bridge_clear_ready),
        .frame_base_ctrl_addr(frame_base_ctrl_addr),
        .lookup_valid(lookup_valid), .lookup_ready(lookup_ready),
        .lookup_beat(lookup_beat), .result_valid(result_valid),
        .result_hit(result_hit), .result_pending(result_pending),
        .result_miss(result_miss), .result_beat(result_beat),
        .result_token(result_token), .result_data(result_data),
        .filled_valid(bridge_filled_valid),
        .filled_token(bridge_filled_token),
        .filled_data(bridge_filled_data), .fault(bridge_fault),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id), .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid)
    );
    bilinear_rgb565 interpolate (
        .clk(clk), .rst(!rst_n),
        .valid_in(interpolate_input_valid),
        .p00(interpolate_p00), .p10(interpolate_p10),
        .p01(interpolate_p01), .p11(interpolate_p11),
        .frac_x(interpolate_fx), .frac_y(interpolate_fy),
        .valid_out(interpolate_valid), .pixel_out(interpolated_pixel)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            interpolate_input_valid <= 1'b0;
            interpolate_p00 <= 16'd0;
            interpolate_p10 <= 16'd0;
            interpolate_p01 <= 16'd0;
            interpolate_p11 <= 16'd0;
            interpolate_fx <= 8'd0;
            interpolate_fy <= 8'd0;
            interpolate_pending <= 3'd0;
            filled_valid_q <= 1'b0;
            filled_token_q <= 9'd0;
            filled_data_q <= 256'd0;
            filled_data_inv_q <= 256'd0;
            output_wr_ptr <= 0;
            output_rd_ptr <= 0;
            output_count <= 0;
        end else begin
            filled_valid_q <= bridge_filled_valid;
            if (bridge_filled_valid) begin
                filled_token_q <= bridge_filled_token;
                filled_data_q <= bridge_filled_data;
                filled_data_inv_q <= ~bridge_filled_data;
            end
            interpolate_input_valid <= queue_out_fire;
            if (queue_out_fire) begin
                interpolate_p00 <= p00;
                interpolate_p10 <= p10;
                interpolate_p01 <= p01;
                interpolate_p11 <= p11;
                interpolate_fx <= queue_fx;
                interpolate_fy <= queue_fy;
            end
            case ({queue_out_fire, output_push})
                2'b10: interpolate_pending <= interpolate_pending + 3'd1;
                2'b01: interpolate_pending <= interpolate_pending - 3'd1;
                default: interpolate_pending <= interpolate_pending;
            endcase
            if (output_push) begin
                output_fifo[output_wr_ptr] <= interpolated_pixel;
                output_wr_ptr <= output_wr_ptr + 2'd1;
            end
            if (output_pop)
                output_rd_ptr <= output_rd_ptr + 2'd1;
            case ({output_push, output_pop})
                2'b10: output_count <= output_count + 3'd1;
                2'b01: output_count <= output_count - 3'd1;
                default: output_count <= output_count;
            endcase
        end
    end
endmodule
