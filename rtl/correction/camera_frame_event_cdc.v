`timescale 1ns/1ps
// One-entry acknowledged event mailbox from camera-pixel to DDR clock domain.
// event_code is held stable until the synchronized acknowledgement returns.
// The source events are pulses and cannot be backpressured; a pulse while busy
// therefore latches source_fault and the receiver must fail the frame closed.
module camera_frame_event_cdc (
    input  wire       src_clk,
    input  wire       dst_clk,
    input  wire       rst_n,
    input  wire       src_event_valid,
    input  wire [1:0] src_event_code,
    output wire       src_ready,
    output reg        src_fault,
    output reg        dst_fault,
    output reg        dst_event_valid,
    output reg  [1:0] dst_event_code
);
    reg request_toggle;
    reg acknowledge_toggle;
    reg acknowledge_src1, acknowledge_src2;
    reg request_dst1, request_dst2;
    reg request_seen;
    reg fault_dst1, fault_dst2;
    reg [1:0] held_event_code;

    assign src_ready = (request_toggle == acknowledge_src2) && !src_fault;

    always @(posedge src_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_toggle <= 1'b0;
            acknowledge_src1 <= 1'b0;
            acknowledge_src2 <= 1'b0;
            held_event_code <= 2'b00;
            src_fault <= 1'b0;
        end else begin
            acknowledge_src1 <= acknowledge_toggle;
            acknowledge_src2 <= acknowledge_src1;
            if (src_event_valid) begin
                if (src_ready) begin
                    held_event_code <= src_event_code;
                    request_toggle <= ~request_toggle;
                end else begin
                    src_fault <= 1'b1;
                end
            end
        end
    end

    always @(posedge dst_clk or negedge rst_n) begin
        if (!rst_n) begin
            request_dst1 <= 1'b0;
            request_dst2 <= 1'b0;
            request_seen <= 1'b0;
            acknowledge_toggle <= 1'b0;
            fault_dst1 <= 1'b0;
            fault_dst2 <= 1'b0;
            dst_fault <= 1'b0;
            dst_event_valid <= 1'b0;
            dst_event_code <= 2'b00;
        end else begin
            request_dst1 <= request_toggle;
            request_dst2 <= request_dst1;
            fault_dst1 <= src_fault;
            fault_dst2 <= fault_dst1;
            dst_fault <= fault_dst2;
            dst_event_valid <= 1'b0;
            if (request_dst2 != request_seen) begin
                dst_event_code <= held_event_code;
                dst_event_valid <= 1'b1;
                request_seen <= request_dst2;
                acknowledge_toggle <= request_dst2;
            end
        end
    end
endmodule
