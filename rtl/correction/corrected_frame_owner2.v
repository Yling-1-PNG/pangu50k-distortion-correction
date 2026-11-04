// DDR-clock-domain owner for two full corrected RGB565 frames.
// Raw camera banks start at 0, 0x400000 and 0x800000 HMIC control-address
// units. Corrected banks start at 0xC00000 and 0x1000000 units. Each 256-bit
// beat advances the control address by 8, so these gaps exceed a 720p frame.
// write_visible is legal only after every write is complete AND a real HMIC
// visibility fence has confirmed that the frame can be read. write_abort_safe
// similarly means no outstanding write can later modify the abandoned bank.
// display_advance and display_read_idle must be synchronized into clk.
// display_advance is the prior pixel frame's completion event, asserted near
// the end of active video; this gives the next frame time to prefill before
// the next VS edge. The first committed frame launches as soon as no front
// bank exists. A launched display reader must latch display_base and finish
// all reads before reporting display_read_idle again.
module corrected_frame_owner2 #(
    parameter [27:0] BANK0_BASE = 28'h0c00000,
    parameter [27:0] BANK1_BASE = 28'h1000000,
    // When a ready bank misses the exact display_advance cycle by a small
    // amount, keep the advance pending and launch it as soon as visibility is
    // proven. The default preserves the original immediate-replay behavior.
    parameter integer DEFER_REPLAY_UNTIL_READY = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        write_start,
    input  wire        write_visible,
    input  wire        write_abort_safe,
    output reg         write_busy,
    output reg         write_bank,
    output wire [27:0] write_base,
    output reg         write_accepted,
    output reg         write_rejected,
    output wire        write_slot_available,
    input  wire        display_advance,
    input  wire        display_read_idle,
    output reg         display_valid,
    output reg         display_bank,
    output wire [27:0] display_base,
    output reg         display_launch,
    output reg         display_empty,
    output reg         display_missed,
    output reg [15:0]  dropped_frames,
    output reg         fault
);
    reg next_write_busy, next_write_bank;
    reg next_display_valid, next_display_bank;
    reg ready_valid, ready_bank;
    reg next_ready_valid, next_ready_bank;
    reg next_write_accepted, next_write_rejected;
    reg next_display_launch, next_display_empty, next_display_missed;
    reg advance_pending, next_advance_pending;
    reg [15:0] next_dropped_frames;
    reg next_fault;
    reg free_found, free_bank;

    assign write_base = write_bank ? BANK1_BASE : BANK0_BASE;
    assign display_base = display_bank ? BANK1_BASE : BANK0_BASE;
    assign write_slot_available = !fault && !write_busy &&
        (!(display_valid && display_bank == 1'b0) &&
         !(ready_valid && ready_bank == 1'b0) ||
         !(display_valid && display_bank == 1'b1) &&
         !(ready_valid && ready_bank == 1'b1));

    always @* begin
        next_write_busy = write_busy;
        next_write_bank = write_bank;
        next_display_valid = display_valid;
        next_display_bank = display_bank;
        next_ready_valid = ready_valid;
        next_ready_bank = ready_bank;
        next_write_accepted = 1'b0;
        next_write_rejected = 1'b0;
        next_display_launch = 1'b0;
        next_display_empty = 1'b0;
        next_display_missed = 1'b0;
        next_advance_pending = advance_pending;
        next_dropped_frames = dropped_frames;
        next_fault = fault;
        free_found = 1'b0;
        free_bank = 1'b0;

        if (write_visible && write_abort_safe) begin
            next_fault = 1'b1;
        end else if (write_visible) begin
            if (next_write_busy) begin
                if (next_ready_valid)
                    next_dropped_frames = next_dropped_frames + 1'b1;
                next_ready_valid = 1'b1;
                next_ready_bank = next_write_bank;
                next_write_busy = 1'b0;
            end else
                next_fault = 1'b1;
        end else if (write_abort_safe) begin
            if (next_write_busy) begin
                next_write_busy = 1'b0;
                next_dropped_frames = next_dropped_frames + 1'b1;
            end else
                next_fault = 1'b1;
        end

        if (display_advance)
            next_advance_pending = 1'b1;

        if (display_advance || advance_pending ||
            (!next_display_valid && next_ready_valid)) begin
            if (!display_read_idle)
                next_display_missed = 1'b1;
            else if (next_ready_valid) begin
                next_advance_pending = 1'b0;
                next_display_valid = 1'b1;
                next_display_bank = next_ready_bank;
                next_ready_valid = 1'b0;
                next_display_launch = 1'b1;
            end else if (!DEFER_REPLAY_UNTIL_READY) begin
                next_advance_pending = 1'b0;
                if (next_display_valid)
                    next_display_launch = 1'b1;
                else
                    next_display_empty = 1'b1;
            end else if (!next_display_valid) begin
                next_display_empty = 1'b1;
            end
        end

        if (write_start) begin
            if (next_write_busy || (write_visible && write_abort_safe)) begin
                next_write_rejected = 1'b1;
                next_dropped_frames = next_dropped_frames + 1'b1;
            end else begin
                if (!(next_display_valid && next_display_bank == 1'b0) &&
                    !(next_ready_valid && next_ready_bank == 1'b0)) begin
                    free_found = 1'b1;
                    free_bank = 1'b0;
                end else if (!(next_display_valid && next_display_bank == 1'b1) &&
                             !(next_ready_valid && next_ready_bank == 1'b1)) begin
                    free_found = 1'b1;
                    free_bank = 1'b1;
                end
                if (free_found) begin
                    next_write_busy = 1'b1;
                    next_write_bank = free_bank;
                    next_write_accepted = 1'b1;
                end else begin
                    next_write_rejected = 1'b1;
                    next_dropped_frames = next_dropped_frames + 1'b1;
                end
            end
        end

        // Invalid producer events freeze ownership so no bank can be reused
        // after its write/visibility contract is broken.
        if (next_fault) begin
            next_write_accepted = 1'b0;
            next_display_launch = 1'b0;
            next_write_busy = write_busy;
            next_write_bank = write_bank;
            next_ready_valid = ready_valid;
            next_ready_bank = ready_bank;
            next_display_valid = display_valid;
            next_display_bank = display_bank;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_busy <= 1'b0;
            write_bank <= 1'b0;
            ready_valid <= 1'b0;
            ready_bank <= 1'b0;
            display_valid <= 1'b0;
            display_bank <= 1'b0;
            write_accepted <= 1'b0;
            write_rejected <= 1'b0;
            display_launch <= 1'b0;
            display_empty <= 1'b0;
            display_missed <= 1'b0;
            advance_pending <= 1'b0;
            dropped_frames <= 16'd0;
            fault <= 1'b0;
        end else begin
            write_busy <= next_write_busy;
            write_bank <= next_write_bank;
            ready_valid <= next_ready_valid;
            ready_bank <= next_ready_bank;
            display_valid <= next_display_valid;
            display_bank <= next_display_bank;
            write_accepted <= next_write_accepted;
            write_rejected <= next_write_rejected;
            display_launch <= next_display_launch;
            display_empty <= next_display_empty;
            display_missed <= next_display_missed;
            advance_pending <= next_advance_pending;
            dropped_frames <= next_dropped_frames;
            fault <= next_fault;
        end
    end
endmodule
