`timescale 1ns/1ps

// OV5640 initialization sequencer that uses the single SCCB owner.
//
// table_data is {register_address[15:0], value[7:0]} and is selected by
// table_index.  The table itself is deliberately external so a generated
// ROM can be audited against the vendor initialization source without
// embedding a second SCCB master in the design.
//
// This module is an integration candidate, not the production top yet.  It
// preserves the vendor's derived half-period divider and exposes the owner
// readback interface for a later diagnostic wrapper.

module ov5640_sccb_init_owner #(
    parameter integer REGISTER_COUNT = 357,
    parameter integer I2C_HALF_PERIOD = 1249
) (
    input  wire        clk_25M,
    input  wire        camera_rstn,
    input  wire        initial_en,
    input  wire [23:0] table_data,
    output reg  [8:0]  table_index,
    output reg         reg_conf_done,
    output reg         config_ack_error,
    output wire        clock_20k,

    input  wire        read_start,
    input  wire [15:0] read_reg_addr,
    output wire        read_busy,
    output wire        read_done,
    output wire        read_ack_error,
    output wire [7:0]  read_data,

    output wire        i2c_sclk,
    inout  wire        i2c_sdat
);

    localparam [1:0] ST_CONFIG_IDLE = 2'd0;
    localparam [1:0] ST_CONFIG_WAIT = 2'd1;
    localparam [1:0] ST_CONFIG_DONE = 2'd2;

    reg [1:0] config_state;
    reg [15:0] i2c_div_count;
    reg clock_20k_reg;
    reg write_start;
    wire write_busy;
    wire write_done;
    wire write_ack_error;

    // This divider intentionally follows the official source structure:
    // with 25 MHz input and HALF_PERIOD=1249, clock_20k has about 10 kHz
    // rising edges despite the vendor signal/comment calling it 20 kHz.
    always @(posedge clk_25M or negedge camera_rstn) begin
        if (!camera_rstn) begin
            i2c_div_count <= 16'd0;
            clock_20k_reg <= 1'b0;
        end else if (i2c_div_count == I2C_HALF_PERIOD - 1) begin
            i2c_div_count <= 16'd0;
            clock_20k_reg <= ~clock_20k_reg;
        end else begin
            i2c_div_count <= i2c_div_count + 1'b1;
        end
    end

    assign clock_20k = clock_20k_reg;

    ov5640_sccb_owner sccb_owner (
        .clk_i2c(clock_20k_reg),
        .rst_n(camera_rstn),
        .write_start(write_start),
        .write_reg_addr(table_data[23:8]),
        .write_data(table_data[7:0]),
        .write_busy(write_busy),
        .write_done(write_done),
        .write_ack_error(write_ack_error),
        .read_start(read_start),
        .read_reg_addr(read_reg_addr),
        .read_busy(read_busy),
        .read_done(read_done),
        .read_ack_error(read_ack_error),
        .read_data(read_data),
        .busy(),
        .i2c_scl(i2c_sclk),
        .i2c_sda(i2c_sdat)
    );

    always @(posedge clock_20k_reg or negedge camera_rstn) begin
        if (!camera_rstn) begin
            config_state    <= ST_CONFIG_IDLE;
            table_index     <= 9'd0;
            reg_conf_done   <= 1'b0;
            config_ack_error<= 1'b0;
            write_start     <= 1'b0;
        end else begin
            write_start <= 1'b0;

            if (!initial_en) begin
                config_state     <= ST_CONFIG_IDLE;
                table_index      <= 9'd0;
                reg_conf_done    <= 1'b0;
                config_ack_error <= 1'b0;
            end else begin
                case (config_state)
                    ST_CONFIG_IDLE: begin
                        if (!reg_conf_done && !write_busy) begin
                            write_start  <= 1'b1;
                            config_state <= ST_CONFIG_WAIT;
                        end
                    end
                    ST_CONFIG_WAIT: begin
                        if (write_done) begin
                            config_ack_error <= config_ack_error | write_ack_error;
                            if (table_index == REGISTER_COUNT - 1) begin
                                reg_conf_done <= 1'b1;
                                config_state  <= ST_CONFIG_DONE;
                            end else begin
                                table_index   <= table_index + 1'b1;
                                config_state  <= ST_CONFIG_IDLE;
                            end
                        end
                    end
                    ST_CONFIG_DONE: begin
                        reg_conf_done <= 1'b1;
                    end
                    default: config_state <= ST_CONFIG_IDLE;
                endcase
            end
        end
    end

endmodule
