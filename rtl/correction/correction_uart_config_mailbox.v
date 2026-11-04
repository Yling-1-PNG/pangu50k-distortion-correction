`timescale 1ns/1ps
// Candidate full control-ingress chain: asynchronous UART pin -> byte/frame
// parser -> bundled-data mailbox -> DDR-domain active configuration.
// safe_to_apply must be generated in ddr_clk domain. No board IO is assigned.
module correction_uart_config_mailbox #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter [339:0] RESET_CONFIG = 340'd0
) (
    input  wire         cfg_clk,
    input  wire         ddr_clk,
    input  wire         rst_n,
    input  wire         uart_rx_pin,
    input  wire         safe_to_apply,
    output wire [339:0] active_config,
    output wire         cfg_applied,
    output wire         pending,
    output wire [15:0]  cfg_sequence,
    output wire         frame_rejected,
    output wire         cfg_overrun,
    output wire         uart_framing_error
);
    wire cfg_valid;
    wire cfg_ready;
    wire [339:0] cfg_data;

    correction_uart_config_rx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) ingress (
        .clk(cfg_clk), .rst_n(rst_n), .uart_rx_pin(uart_rx_pin),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_data(cfg_data),
        .cfg_sequence(cfg_sequence), .frame_rejected(frame_rejected),
        .cfg_overrun(cfg_overrun), .uart_framing_error(uart_framing_error)
    );

    frame_config_mailbox #(.CONFIG_WIDTH(340), .RESET_CONFIG(RESET_CONFIG)) mailbox (
        .cfg_clk(cfg_clk), .ddr_clk(ddr_clk), .rst_n(rst_n),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_data(cfg_data),
        .cfg_applied(cfg_applied), .safe_to_apply(safe_to_apply),
        .active_config(active_config), .pending(pending)
    );
endmodule
