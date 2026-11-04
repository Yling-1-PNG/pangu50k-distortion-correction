`timescale 1ns/1ps
// Bundled-data mailbox from a control clock to the DDR/reader clock.
// The source holds cfg_data until the destination applies the entire word at
// a caller-defined safe frame boundary. This module does not validate fields
// or define physical CDC constraints for the bundled data path.
module frame_config_mailbox #(
    parameter integer CONFIG_WIDTH = 340,
    parameter [CONFIG_WIDTH-1:0] RESET_CONFIG = {CONFIG_WIDTH{1'b0}}
) (
    input  wire                     cfg_clk,
    input  wire                     ddr_clk,
    input  wire                     rst_n,
    input  wire                     cfg_valid,
    output wire                     cfg_ready,
    input  wire [CONFIG_WIDTH-1:0]  cfg_data,
    output reg                      cfg_applied,
    input  wire                     safe_to_apply,
    output reg  [CONFIG_WIDTH-1:0]  active_config,
    output reg                      pending
);
    reg [CONFIG_WIDTH-1:0] mailbox_data;
    reg request_toggle;
    reg acknowledge_toggle;
    (* ASYNC_REG = "TRUE" *) reg request_meta, request_sync;
    (* ASYNC_REG = "TRUE" *) reg acknowledge_meta, acknowledge_sync;
    reg acknowledge_sync_d;
    reg pending_toggle;
    reg [CONFIG_WIDTH-1:0] pending_data;

    assign cfg_ready = acknowledge_sync == request_toggle;

    always @(posedge cfg_clk or negedge rst_n) begin
        if (!rst_n) begin
            mailbox_data <= RESET_CONFIG;
            request_toggle <= 1'b0;
            acknowledge_meta <= 1'b0;
            acknowledge_sync <= 1'b0;
            acknowledge_sync_d <= 1'b0;
            cfg_applied <= 1'b0;
        end else begin
            acknowledge_meta <= acknowledge_toggle;
            acknowledge_sync <= acknowledge_meta;
            acknowledge_sync_d <= acknowledge_sync;
            cfg_applied <= acknowledge_sync != acknowledge_sync_d;
            if (cfg_valid && cfg_ready) begin
                mailbox_data <= cfg_data;
                request_toggle <= ~request_toggle;
            end
        end
    end

    always @(posedge ddr_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_meta <= 1'b0;
            request_sync <= 1'b0;
            acknowledge_toggle <= 1'b0;
            pending_toggle <= 1'b0;
            pending_data <= RESET_CONFIG;
            pending <= 1'b0;
            active_config <= RESET_CONFIG;
        end else begin
            request_meta <= request_toggle;
            request_sync <= request_meta;

            if (pending && safe_to_apply) begin
                active_config <= pending_data;
                acknowledge_toggle <= pending_toggle;
                pending <= 1'b0;
            end else if (!pending && request_sync != acknowledge_toggle) begin
                // Bundled data has remained stable throughout the two-flop
                // request synchronizer latency and stays held until ack.
                pending_data <= mailbox_data;
                pending_toggle <= request_sync;
                pending <= 1'b1;
            end
        end
    end
endmodule
