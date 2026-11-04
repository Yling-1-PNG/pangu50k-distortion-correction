`timescale 1ns/1ps

// Single-owner OV5640 SCCB controller for diagnostic integration.
//
// The vendor camera initializer and the readback diagnostic must not drive
// cmos1_scl/cmos1_sda as separate masters.  This module owns the bus and
// serializes one-byte writes and one-byte reads.  A write request has
// priority when both start pulses arrive together.  start inputs are pulses;
// requests are accepted only while the owner is idle.
//
// Write transaction:
//   START, 0x78, register[15:8], register[7:0], value, STOP
// Read transaction:
//   START, 0x78, register[15:8], register[7:0],
//   repeated START, 0x79, one byte, master NACK, STOP
//
// This is intentionally an isolated, synthesizable protocol block.  It is
// not connected to the production PGL50H top until its init-table wrapper,
// PDS compile, and board-level readback path are reviewed separately.

module ov5640_sccb_owner #(
    parameter [7:0] WRITE_ADDRESS = 8'h78,
    parameter [7:0] READ_ADDRESS  = 8'h79
) (
    input  wire       clk_i2c,
    input  wire       rst_n,

    input  wire       write_start,
    input  wire [15:0] write_reg_addr,
    input  wire [7:0]  write_data,
    output reg        write_busy,
    output reg        write_done,
    output reg        write_ack_error,

    input  wire       read_start,
    input  wire [15:0] read_reg_addr,
    output reg        read_busy,
    output reg        read_done,
    output reg        read_ack_error,
    output reg [7:0]  read_data,

    output reg        busy,
    output wire       i2c_scl,
    inout  wire       i2c_sda
);

    localparam [5:0] ST_IDLE          = 6'd0;
    localparam [5:0] ST_START_H       = 6'd1;
    localparam [5:0] ST_START_L       = 6'd2;
    localparam [5:0] ST_TX_SETUP      = 6'd3;
    localparam [5:0] ST_TX_HIGH       = 6'd4;
    localparam [5:0] ST_TX_LOW        = 6'd5;
    localparam [5:0] ST_ACK_SETUP     = 6'd6;
    localparam [5:0] ST_ACK_HIGH      = 6'd7;
    localparam [5:0] ST_ACK_LOW       = 6'd8;
    localparam [5:0] ST_REP_PREP      = 6'd9;
    localparam [5:0] ST_REP_HIGH      = 6'd10;
    localparam [5:0] ST_REP_ASSERT    = 6'd11;
    localparam [5:0] ST_REP_LOW       = 6'd12;
    localparam [5:0] ST_READ_LOW      = 6'd13;
    localparam [5:0] ST_READ_HIGH     = 6'd14;
    localparam [5:0] ST_NACK_LOW      = 6'd15;
    localparam [5:0] ST_NACK_HIGH     = 6'd16;
    localparam [5:0] ST_STOP_PREP     = 6'd17;
    localparam [5:0] ST_STOP_HIGH     = 6'd18;
    localparam [5:0] ST_STOP_RELEASE  = 6'd19;

    reg [5:0]  state;
    reg        active_read;
    reg [15:0] latched_reg_addr;
    reg [7:0]  latched_write_data;
    reg [7:0]  tx_data;
    reg [2:0]  tx_index;
    reg [2:0]  tx_bit_index;
    reg [2:0]  read_bit_index;
    reg        sda_drive_low;

    assign i2c_scl = (state == ST_IDLE         ||
                      state == ST_START_H      ||
                      state == ST_TX_HIGH      ||
                      state == ST_ACK_HIGH     ||
                      state == ST_REP_HIGH     ||
                      state == ST_REP_ASSERT   ||
                      state == ST_READ_HIGH    ||
                      state == ST_NACK_HIGH    ||
                      state == ST_STOP_HIGH    ||
                      state == ST_STOP_RELEASE) ? 1'b1 : 1'b0;

    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    always @(*) begin
        sda_drive_low = 1'b0;
        case (state)
            ST_START_H,
            ST_START_L,
            ST_REP_ASSERT,
            ST_REP_LOW,
            ST_STOP_PREP,
            ST_STOP_HIGH: sda_drive_low = 1'b1;
            ST_TX_SETUP,
            ST_TX_HIGH,
            ST_TX_LOW: sda_drive_low = ~tx_data[7 - tx_bit_index];
            default: sda_drive_low = 1'b0;
        endcase
    end

    always @(posedge clk_i2c or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            active_read      <= 1'b0;
            latched_reg_addr <= 16'h0000;
            latched_write_data <= 8'h00;
            tx_data          <= 8'h00;
            tx_index         <= 3'd0;
            tx_bit_index     <= 3'd0;
            read_bit_index   <= 3'd0;
            busy             <= 1'b0;
            write_busy       <= 1'b0;
            write_done       <= 1'b0;
            write_ack_error  <= 1'b0;
            read_busy        <= 1'b0;
            read_done        <= 1'b0;
            read_ack_error   <= 1'b0;
            read_data        <= 8'h00;
        end else begin
            write_done <= 1'b0;
            read_done  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy       <= 1'b0;
                    write_busy <= 1'b0;
                    read_busy  <= 1'b0;
                    // Writes have deterministic priority over reads.
                    if (write_start) begin
                        active_read        <= 1'b0;
                        latched_reg_addr   <= write_reg_addr;
                        latched_write_data <= write_data;
                        tx_data            <= WRITE_ADDRESS;
                        tx_index           <= 3'd0;
                        tx_bit_index       <= 3'd0;
                        write_ack_error    <= 1'b0;
                        busy               <= 1'b1;
                        write_busy         <= 1'b1;
                        state              <= ST_START_H;
                    end else if (read_start) begin
                        active_read      <= 1'b1;
                        latched_reg_addr <= read_reg_addr;
                        tx_data          <= WRITE_ADDRESS;
                        tx_index         <= 3'd0;
                        tx_bit_index     <= 3'd0;
                        read_bit_index   <= 3'd0;
                        read_ack_error   <= 1'b0;
                        read_data        <= 8'h00;
                        busy             <= 1'b1;
                        read_busy        <= 1'b1;
                        state            <= ST_START_H;
                    end
                end

                ST_START_H:   state <= ST_START_L;
                ST_START_L:   state <= ST_TX_SETUP;

                ST_TX_SETUP:  state <= ST_TX_HIGH;
                ST_TX_HIGH:   state <= ST_TX_LOW;
                ST_TX_LOW: begin
                    if (tx_bit_index == 3'd7) begin
                        tx_bit_index <= 3'd0;
                        state        <= ST_ACK_SETUP;
                    end else begin
                        tx_bit_index <= tx_bit_index + 3'd1;
                        state        <= ST_TX_SETUP;
                    end
                end

                ST_ACK_SETUP: state <= ST_ACK_HIGH;
                ST_ACK_HIGH: begin
                    if (i2c_sda) begin
                        if (active_read)
                            read_ack_error <= 1'b1;
                        else
                            write_ack_error <= 1'b1;
                    end
                    state <= ST_ACK_LOW;
                end

                ST_ACK_LOW: begin
                    if (!active_read) begin
                        if (tx_index == 3'd3) begin
                            state <= ST_STOP_PREP;
                        end else begin
                            tx_index <= tx_index + 3'd1;
                            case (tx_index)
                                3'd0: tx_data <= latched_reg_addr[15:8];
                                3'd1: tx_data <= latched_reg_addr[7:0];
                                default: tx_data <= latched_write_data;
                            endcase
                            state <= ST_TX_SETUP;
                        end
                    end else if (tx_index < 3'd2) begin
                        tx_index <= tx_index + 3'd1;
                        if (tx_index == 3'd0)
                            tx_data <= latched_reg_addr[15:8];
                        else
                            tx_data <= latched_reg_addr[7:0];
                        state <= ST_TX_SETUP;
                    end else if (tx_index == 3'd2) begin
                        tx_index <= 3'd3;
                        tx_data  <= READ_ADDRESS;
                        state    <= ST_REP_PREP;
                    end else begin
                        read_bit_index <= 3'd0;
                        state          <= ST_READ_LOW;
                    end
                end

                ST_REP_PREP:   state <= ST_REP_HIGH;
                ST_REP_HIGH:   state <= ST_REP_ASSERT;
                ST_REP_ASSERT: state <= ST_REP_LOW;
                ST_REP_LOW:    state <= ST_TX_SETUP;

                ST_READ_LOW:  state <= ST_READ_HIGH;
                ST_READ_HIGH: begin
                    read_data[7 - read_bit_index] <= i2c_sda;
                    if (read_bit_index == 3'd7)
                        state <= ST_NACK_LOW;
                    else begin
                        read_bit_index <= read_bit_index + 3'd1;
                        state <= ST_READ_LOW;
                    end
                end
                ST_NACK_LOW:  state <= ST_NACK_HIGH;
                ST_NACK_HIGH: state <= ST_STOP_PREP;

                // A valid I2C/SCCB STOP is SDA low while SCL is low, then
                // SCL high, then release SDA high.
                ST_STOP_PREP:    state <= ST_STOP_HIGH;
                ST_STOP_HIGH:    state <= ST_STOP_RELEASE;
                ST_STOP_RELEASE: begin
                    busy <= 1'b0;
                    if (active_read) begin
                        read_busy <= 1'b0;
                        read_done <= 1'b1;
                    end else begin
                        write_busy <= 1'b0;
                        write_done <= 1'b1;
                    end
                    state <= ST_IDLE;
                end
                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule
