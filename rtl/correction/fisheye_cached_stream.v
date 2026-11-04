// Candidate fisheye coordinate ROM on the existing ordered cache/DDR read path.
// This is a data-path top only: no camera writer, HMIC IP or HDMI output.
module fisheye_cached_stream #(
    parameter READ_DEPTH = 8,
    parameter PIPELINED_COORDINATES = 0,
    parameter INIT_FILE = "../../rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter INIT_FILE_HI = "../../rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem",
    parameter INIT_FILE_DELTA = "../../rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem"
) (
    input  wire         clk, rst_n, clear,
    output wire         clear_ready,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [10:0]  out_x, out_y,
    input  wire signed [21:0] a00_q20, a01_q20, a10_q20, a11_q20,
    input  wire signed [19:0] tx_q8, ty_q8,
    input  wire signed [19:0] src_fx_q8, src_fy_q8, src_cx_q8, src_cy_q8,
    input  wire signed [19:0] out_cx_q8, out_cy_q8,
    input  wire [21:0]  inv_out_fx_q22, inv_out_fy_q22,
    input  wire [27:0]  frame_base_ctrl_addr,
    output wire         out_valid,
    input  wire         out_ready,
    output wire [15:0]  out_pixel,
    output wire         fault,
    output wire [27:0]  axi_araddr,
    output wire         axi_aruser_ap,
    output wire [3:0]   axi_aruser_id, axi_arlen,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rlast, axi_rvalid
);
    brown_cached_stream #(
        .READ_DEPTH(READ_DEPTH), .USE_FISHEYE(1),
        .PIPELINED_COORDINATES(PIPELINED_COORDINATES),
        .FISHEYE_INIT_FILE(INIT_FILE), .FISHEYE_INIT_FILE_HI(INIT_FILE_HI),
        .FISHEYE_INIT_FILE_DELTA(INIT_FILE_DELTA)
    ) path (
        .clk(clk), .rst_n(rst_n), .clear(clear), .clear_ready(clear_ready),
        .in_valid(in_valid), .in_ready(in_ready), .out_x(out_x), .out_y(out_y),
        .a00_q20(a00_q20), .a01_q20(a01_q20),
        .a10_q20(a10_q20), .a11_q20(a11_q20),
        .tx_q8(tx_q8), .ty_q8(ty_q8),
        .fx_q8(src_fx_q8), .fy_q8(src_fy_q8),
        .cx_q8(src_cx_q8), .cy_q8(src_cy_q8),
        .inv_fx_q22(22'd0), .inv_fy_q22(22'd0),
        .out_cx_q8(out_cx_q8), .out_cy_q8(out_cy_q8),
        .inv_out_fx_q22(inv_out_fx_q22),
        .inv_out_fy_q22(inv_out_fy_q22),
        .k1_q18(22'sd0), .k2_q18(22'sd0),
        .p1_q18(22'sd0), .p2_q18(22'sd0),
        .frame_base_ctrl_addr(frame_base_ctrl_addr),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_pixel(out_pixel), .fault(fault),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id), .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid)
    );
endmodule
