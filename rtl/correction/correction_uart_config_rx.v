`timescale 1ns/1ps
// Candidate UART-to-runtime-config ingress. This does not assign a board pin.
// UART RX and the PG frame parser share clk; active configuration is still
// transferred by frame_config_mailbox at the caller's safe frame boundary.
module correction_uart_config_rx #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         uart_rx_pin,
    output wire         cfg_valid,
    input  wire         cfg_ready,
    output wire [339:0] cfg_data,
    output wire [15:0]  cfg_sequence,
    output wire         frame_rejected,
    output wire         cfg_overrun,
    output wire         uart_framing_error
);
    wire [7:0] byte_data;
    wire byte_valid;

    uart_rx_8n1 #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) uart_receiver (
        .clk(clk), .rst_n(rst_n), .rx_pin(uart_rx_pin),
        .rx_data(byte_data), .rx_valid(byte_valid),
        .framing_error(uart_framing_error)
    );

    correction_config_frame_rx frame_parser (
        .clk(clk), .rst_n(rst_n), .rx_valid(byte_valid), .rx_data(byte_data),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_data(cfg_data),
        .cfg_sequence(cfg_sequence), .frame_rejected(frame_rejected),
        .cfg_overrun(cfg_overrun)
    );
endmodule
