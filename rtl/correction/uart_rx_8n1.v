`timescale 1ns/1ps
// Parameterized asynchronous 8N1 receiver. rx_valid is a one-cycle pulse;
// rx_data remains stable until the next complete byte. Input pin timing is
// synchronized here, but electrical IO constraints and pin mapping are external.
module uart_rx_8n1 #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx_pin,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        framing_error
);
    localparam integer CLKS_PER_BIT = (CLOCK_HZ + (BAUD / 2)) / BAUD;
    localparam integer HALF_BIT_CLKS = CLKS_PER_BIT / 2;
    localparam integer COUNT_WIDTH = (CLKS_PER_BIT < 2) ? 1 : $clog2(CLKS_PER_BIT + 1);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    (* ASYNC_REG = "TRUE" *) reg rx_meta;
    (* ASYNC_REG = "TRUE" *) reg rx_sync;
    reg [1:0] state;
    reg [COUNT_WIDTH-1:0] clk_count;
    reg [2:0] bit_index;
    reg [7:0] shift_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx_pin;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            clk_count <= {COUNT_WIDTH{1'b0}};
            bit_index <= 3'd0;
            shift_data <= 8'd0;
            rx_data <= 8'd0;
            rx_valid <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                ST_IDLE: begin
                    clk_count <= {COUNT_WIDTH{1'b0}};
                    if (!rx_sync) begin
                        state <= ST_START;
                        bit_index <= 3'd0;
                    end
                end

                ST_START: begin
                    if (clk_count == HALF_BIT_CLKS - 1) begin
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        if (!rx_sync)
                            state <= ST_DATA;
                        else
                            state <= ST_IDLE;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        shift_data[bit_index] <= rx_sync;
                        if (bit_index == 3'd7)
                            state <= ST_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                ST_STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= {COUNT_WIDTH{1'b0}};
                        state <= ST_IDLE;
                        if (rx_sync) begin
                            rx_data <= shift_data;
                            rx_valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    clk_count <= {COUNT_WIDTH{1'b0}};
                end
            endcase
        end
    end
endmodule
