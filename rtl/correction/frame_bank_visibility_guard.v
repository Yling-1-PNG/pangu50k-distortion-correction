`timescale 1ns/1ps
// Do not publish or release a capture bank on HMIC transfer status alone.
// visibility_confirmed and abort_safe are external DDR-domain proof events;
// this guard orders them but does not generate or validate that proof.
module frame_bank_visibility_guard (
    input  wire clk,
    input  wire rst_n,
    input  wire capture_allocated,
    input  wire writer_transfer_done,
    input  wire visibility_confirmed,
    input  wire writer_transfer_aborted,
    input  wire abort_safe,
    output reg  capture_commit,
    output reg  capture_abort,
    output reg  fault,
    output wire waiting_visibility,
    output wire waiting_abort_safe
);
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_CAPTURE = 3'd1;
    localparam [2:0] S_VISIBILITY = 3'd2;
    localparam [2:0] S_ABORT_SAFE = 3'd3;
    localparam [2:0] S_FAULT = 3'd4;

    reg [2:0] state;
    wire terminal_conflict = writer_transfer_done && writer_transfer_aborted;

    assign waiting_visibility = state == S_VISIBILITY;
    assign waiting_abort_safe = state == S_ABORT_SAFE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            capture_commit <= 1'b0;
            capture_abort <= 1'b0;
            fault <= 1'b0;
        end else begin
            capture_commit <= 1'b0;
            capture_abort <= 1'b0;

            if (fault || state == S_FAULT) begin
                state <= S_FAULT;
            end else if (terminal_conflict) begin
                fault <= 1'b1;
                state <= S_FAULT;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (capture_allocated && !visibility_confirmed && !abort_safe)
                            state <= S_CAPTURE;
                        else if (capture_allocated || visibility_confirmed || abort_safe) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end
                    end
                    S_CAPTURE: begin
                        if (capture_allocated || visibility_confirmed || abort_safe) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (writer_transfer_done) begin
                            state <= S_VISIBILITY;
                        end else if (writer_transfer_aborted) begin
                            state <= S_ABORT_SAFE;
                        end
                    end
                    S_VISIBILITY: begin
                        if (capture_allocated || writer_transfer_done || abort_safe) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (writer_transfer_aborted) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (visibility_confirmed) begin
                            capture_commit <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                    S_ABORT_SAFE: begin
                        if (capture_allocated || writer_transfer_done || visibility_confirmed) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (writer_transfer_aborted) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (abort_safe) begin
                            capture_abort <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                    default: begin
                        fault <= 1'b1;
                        state <= S_FAULT;
                    end
                endcase
            end
        end
    end
endmodule
