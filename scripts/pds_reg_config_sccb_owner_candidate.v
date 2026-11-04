`timescale 1ns/1ps

// Isolated PDS top-integration adapter. It keeps the vendor reg_config port
// contract while the SCCB implementation is qualified independently.
// build_formal_pds_top.ps1 copies this over the vendor source only when
// -UseSccbOwnerCameraConfig is supplied.

module reg_config (
    input  wire       clk_25M,
    input  wire       camera_rstn,
    input  wire       initial_en,
    output wire       reg_conf_done,
    output wire       i2c_sclk,
    inout  wire       i2c_sdat,
    output wire       clock_20k,
    output wire [8:0] reg_index
);
    wire config_ack_error;
    wire read_busy;
    wire read_done;
    wire read_ack_error;
    wire [7:0] read_data;

    ov5640_sccb_720p30_init #(
        .INIT_FILE("source/rtl/data/ov5640_720p30_init_2023.mem"),
        .I2C_HALF_PERIOD(1249)
    ) camera_init (
        .clk_25M(clk_25M),
        .camera_rstn(camera_rstn),
        .initial_en(initial_en),
        .reg_conf_done(reg_conf_done),
        .config_ack_error(config_ack_error),
        .read_start(1'b0),
        .read_reg_addr(16'd0),
        .read_busy(read_busy),
        .read_done(read_done),
        .read_ack_error(read_ack_error),
        .read_data(read_data),
        .clock_20k(clock_20k),
        .reg_index(reg_index),
        .i2c_sclk(i2c_sclk),
        .i2c_sdat(i2c_sdat)
    );
endmodule
