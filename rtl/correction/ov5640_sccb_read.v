`timescale 1ns/1ps

// Isolated OV5640 SCCB/I2C-style one-register readback diagnostic.
//
// This module is intentionally not connected to the production camera top.
// OV5640 uses an 8-bit bus address: 0x78 for write and 0x79 for read.
// The master releases SDA for ACK and read data; the board-level pull-up
// supplies the high level.

module ov5640_sccb_read #(
    parameter [7:0] WRITE_ADDRESS = 8'h78,
    parameter [7:0] READ_ADDRESS  = 8'h79
) (
    input  wire       clk_i2c,
    input  wire       rst_n,
    input  wire       start,
    input  wire [15:0] reg_addr,
    output reg        busy,
    output reg        done,
    output reg        ack_error,
    output reg [7:0]  read_data,
    output wire       i2c_scl,
    inout  wire       i2c_sda
);

    localparam [4:0] ST_IDLE        = 5'd0;
    localparam [4:0] ST_START_H     = 5'd1;
    localparam [4:0] ST_START_L     = 5'd2;
    localparam [4:0] ST_TX_SETUP    = 5'd3;
    localparam [4:0] ST_TX_HIGH     = 5'd4;
    localparam [4:0] ST_TX_LOW      = 5'd5;
    localparam [4:0] ST_ACK_SETUP   = 5'd6;
    localparam [4:0] ST_ACK_HIGH    = 5'd7;
    localparam [4:0] ST_ACK_LOW     = 5'd8;
    localparam [4:0] ST_REP_PREP    = 5'd9;
    localparam [4:0] ST_REP_HIGH    = 5'd10;
    localparam [4:0] ST_REP_ASSERT  = 5'd11;
    localparam [4:0] ST_REP_LOW     = 5'd12;
    localparam [4:0] ST_READ_LOW    = 5'd13;
    localparam [4:0] ST_READ_HIGH   = 5'd14;
    localparam [4:0] ST_READ_END_L  = 5'd15;
    localparam [4:0] ST_NACK_HIGH   = 5'd16;
    localparam [4:0] ST_STOP_ASSERT = 5'd17;
    localparam [4:0] ST_STOP_RELEASE= 5'd18;

    reg [4:0]  state;
    reg [7:0]  tx_data;
    reg [1:0]  tx_index;
    reg [2:0]  tx_bit_index;
    reg [2:0]  read_bit_index;
    reg        sda_drive_low;

    assign i2c_scl = (state == ST_IDLE        ||
                      state == ST_START_H     ||
                      state == ST_TX_HIGH     ||
                      state == ST_ACK_HIGH    ||
                      state == ST_REP_HIGH    ||
                      state == ST_REP_ASSERT  ||
                      state == ST_READ_HIGH   ||
                      state == ST_NACK_HIGH   ||
                      state == ST_STOP_ASSERT ||
                      state == ST_STOP_RELEASE) ? 1'b1 : 1'b0;

    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    always @(*) begin
        sda_drive_low = 1'b0;
        case (state)
            ST_START_H,
            ST_START_L,
            ST_REP_ASSERT,
            ST_REP_LOW,
            ST_STOP_ASSERT: sda_drive_low = 1'b1;
            ST_TX_SETUP,
            ST_TX_HIGH,
            ST_TX_LOW: sda_drive_low = ~tx_data[7 - tx_bit_index];
            default: sda_drive_low = 1'b0;
        endcase
    end

    always @(posedge clk_i2c or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            tx_data       <= 8'h00;
            tx_index      <= 2'd0;
            tx_bit_index  <= 3'd0;
            read_bit_index<= 3'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            ack_error     <= 1'b0;
            read_data     <= 8'h00;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        ack_error    <= 1'b0;
                        read_data    <= 8'h00;
                        tx_data      <= WRITE_ADDRESS;
                        tx_index     <= 2'd0;
                        tx_bit_index <= 3'd0;
                        state        <= ST_START_H;
                    end
                end

                ST_START_H:      state <= ST_START_L;
                ST_START_L:      state <= ST_TX_SETUP;
                ST_TX_SETUP:     state <= ST_TX_HIGH;
                ST_TX_HIGH:      state <= ST_TX_LOW;
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
                    if (i2c_sda)
                        ack_error <= 1'b1;
                    state <= ST_ACK_LOW;
                end
                ST_ACK_LOW: begin
                    if (tx_index < 2'd2) begin
                        tx_index <= tx_index + 2'd1;
                        tx_data  <= (tx_index == 2'd0) ? reg_addr[15:8] : reg_addr[7:0];
                        state    <= ST_TX_SETUP;
                    end else if (tx_index == 2'd2) begin
                        tx_index <= 2'd3;
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
                        state <= ST_READ_END_L;
                    else begin
                        read_bit_index <= read_bit_index + 3'd1;
                        state <= ST_READ_LOW;
                    end
                end
                ST_READ_END_L:   state <= ST_NACK_HIGH;
                ST_NACK_HIGH:    state <= ST_STOP_ASSERT;
                ST_STOP_ASSERT:  state <= ST_STOP_RELEASE;
                ST_STOP_RELEASE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
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
