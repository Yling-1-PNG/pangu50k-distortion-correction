`timescale 1ns/1ps

// Sequential read-only snapshot of the OV5640 image-quality registers.
// This is a diagnostic wrapper around ov5640_sccb_read and is deliberately
// not connected to the production camera top.

module ov5640_sccb_snapshot #(
    parameter integer REGISTER_COUNT = 14
) (
    input  wire                         clk_i2c,
    input  wire                         rst_n,
    input  wire                         start,
    output reg                          busy,
    output reg                          done,
    output reg                          ack_error,
    output reg [REGISTER_COUNT*8-1:0]  snapshot_data,
    output wire                         i2c_scl,
    inout  wire                         i2c_sda
);

    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_LAUNCH = 2'd1;
    localparam [1:0] ST_WAIT   = 2'd2;

    reg [1:0] state;
    reg [3:0] register_index;
    wire [15:0] selected_register;
    wire reader_done;
    wire reader_ack_error;
    wire [7:0] reader_data;
    wire reader_start = (state == ST_LAUNCH);

    function [15:0] register_address;
        input [3:0] index;
        begin
            case (index)
                4'd0:  register_address = 16'h3500; // exposure[19:16]
                4'd1:  register_address = 16'h3501; // exposure[15:8]
                4'd2:  register_address = 16'h3502; // exposure[7:0]
                4'd3:  register_address = 16'h3503; // AEC/AGC control
                4'd4:  register_address = 16'h350A; // gain[9:8]
                4'd5:  register_address = 16'h350B; // gain[7:0]
                4'd6:  register_address = 16'h3400; // AWB gain R high
                4'd7:  register_address = 16'h3401; // AWB gain R low
                4'd8:  register_address = 16'h3402; // AWB gain G high
                4'd9:  register_address = 16'h3403; // AWB gain G low
                4'd10: register_address = 16'h3404; // AWB gain B high
                4'd11: register_address = 16'h3405; // AWB gain B low
                4'd12: register_address = 16'h5001; // ISP/AWB/CMX/SDE enables
                default: register_address = 16'h4300; // RGB565 format/sequence
            endcase
        end
    endfunction

    assign selected_register = register_address(register_index);

    ov5640_sccb_read reader (
        .clk_i2c(clk_i2c),
        .rst_n(rst_n),
        .start(reader_start),
        .reg_addr(selected_register),
        .done(reader_done),
        .ack_error(reader_ack_error),
        .read_data(reader_data),
        .i2c_scl(i2c_scl),
        .i2c_sda(i2c_sda)
    );

    always @(posedge clk_i2c or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            register_index<= 4'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            ack_error     <= 1'b0;
            snapshot_data <= {REGISTER_COUNT*8{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy           <= 1'b1;
                        ack_error      <= 1'b0;
                        snapshot_data  <= {REGISTER_COUNT*8{1'b0}};
                        register_index <= 4'd0;
                        state          <= ST_LAUNCH;
                    end
                end
                ST_LAUNCH: state <= ST_WAIT;
                ST_WAIT: begin
                    if (reader_done) begin
                        snapshot_data[register_index*8 +: 8] <= reader_data;
                        ack_error <= ack_error | reader_ack_error;
                        if (register_index == REGISTER_COUNT-1) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            register_index <= register_index + 4'd1;
                            state <= ST_LAUNCH;
                        end
                    end
                end
                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule
