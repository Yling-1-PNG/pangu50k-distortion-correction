`timescale 1ns/1ps

// Candidate 720p30 OV5640 initializer using the audited vendor table and the
// single SCCB owner. This is intentionally a drop-in diagnostic wrapper; it
// is not connected to the formal camera top until its clock/reset crossings,
// PDS FDC, and board behavior are reviewed.

module ov5640_sccb_720p30_init #(
    parameter INIT_FILE = "rtl/data/ov5640_720p30_init_2023.mem",
    parameter integer I2C_HALF_PERIOD = 1249
) (
    input  wire        clk_25M,
    input  wire        camera_rstn,
    input  wire        initial_en,
    output wire        reg_conf_done,
    output wire        config_ack_error,
    input  wire        read_start,
    input  wire [15:0] read_reg_addr,
    output wire        read_busy,
    output wire        read_done,
    output wire        read_ack_error,
    output wire [7:0]  read_data,
    output wire        clock_20k,
    output wire [8:0]  reg_index,
    output wire        i2c_sclk,
    inout  wire        i2c_sdat
);
    wire [23:0] table_data;

    ov5640_init_rom #(
        .INIT_FILE(INIT_FILE)
    ) table_rom (
        .addr(reg_index),
        .data(table_data)
    );

    ov5640_sccb_init_owner #(
        .REGISTER_COUNT(357),
        .I2C_HALF_PERIOD(I2C_HALF_PERIOD)
    ) init_owner (
        .clk_25M(clk_25M),
        .camera_rstn(camera_rstn),
        .initial_en(initial_en),
        .table_data(table_data),
        .table_index(reg_index),
        .reg_conf_done(reg_conf_done),
        .config_ack_error(config_ack_error),
        .read_start(read_start),
        .read_reg_addr(read_reg_addr),
        .read_busy(read_busy),
        .read_done(read_done),
        .read_ack_error(read_ack_error),
        .read_data(read_data),
        .clock_20k(clock_20k),
        .i2c_sclk(i2c_sclk),
        .i2c_sdat(i2c_sdat)
    );
endmodule
