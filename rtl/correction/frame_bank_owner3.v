// Single-DDR-clock ownership only. Synchronize camera/HDMI events before use.
// capture_commit requires proven write-to-read visibility; an HMIC WLAST
// transfer_done pulse alone is not enough because this IP has no B response.
// capture_abort also requires all issued writes to be quiescent/visible before
// the discarded bank can be reused. A transfer_aborted pulse alone is not it.
// reader_done means all reads and pixels sourced from read_bank have left the
// correction pipeline; copies already accepted by a separate video FIFO do
// not require this DDR bank. Video frame alignment is a separate contract.
module frame_bank_owner3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        capture_start,
    input  wire        capture_commit,
    input  wire        capture_abort,
    input  wire        reader_start,
    input  wire        reader_done,
    output reg         write_busy,
    output reg  [1:0]  write_bank,
    output wire [27:0] write_base,
    output reg         ready_valid,
    output reg  [1:0]  ready_bank,
    output reg         read_busy,
    output reg  [1:0]  read_bank,
    output wire [27:0] read_base,
    output reg         capture_accepted,
    output reg         capture_dropped,
    output reg         reader_acquired,
    output reg  [15:0] dropped_frames,
    output reg         fault
);
    reg next_write_busy, next_ready_valid, next_read_busy;
    reg [1:0] next_write_bank, next_ready_bank, next_read_bank;
    reg next_capture_accepted, next_capture_dropped, next_reader_acquired;
    reg [15:0] next_dropped_frames;
    reg next_fault;
    reg found_free;
    reg [1:0] free_bank;

    assign write_base = {4'b0, write_bank, 22'b0};
    assign read_base = {4'b0, read_bank, 22'b0};

    always @* begin
        next_write_busy = write_busy;
        next_write_bank = write_bank;
        next_ready_valid = ready_valid;
        next_ready_bank = ready_bank;
        next_read_busy = read_busy;
        next_read_bank = read_bank;
        next_capture_accepted = 1'b0;
        next_capture_dropped = 1'b0;
        next_reader_acquired = 1'b0;
        next_dropped_frames = dropped_frames;
        next_fault = fault;
        found_free = 1'b1;
        free_bank = 2'd0;

        if (reader_done) begin
            if (next_read_busy)
                next_read_busy = 1'b0;
            else
                next_fault = 1'b1;
        end
        if (capture_commit && capture_abort) begin
            next_fault = 1'b1;
        end else if (capture_abort) begin
            if (next_write_busy) begin
                next_write_busy = 1'b0;
                next_dropped_frames = next_dropped_frames + 1'b1;
            end else
                next_fault = 1'b1;
        end else if (capture_commit) begin
            if (next_write_busy) begin
                if (next_ready_valid)
                    next_dropped_frames = next_dropped_frames + 1'b1;
                next_ready_valid = 1'b1;
                next_ready_bank = next_write_bank;
                next_write_busy = 1'b0;
            end else
                next_fault = 1'b1;
        end
        if (reader_start && !next_read_busy && next_ready_valid) begin
            next_read_busy = 1'b1;
            next_read_bank = next_ready_bank;
            next_ready_valid = 1'b0;
            next_reader_acquired = 1'b1;
        end
        if (capture_start && capture_abort) begin
            next_capture_dropped = 1'b1;
            next_dropped_frames = next_dropped_frames + 1'b1;
        end else if (capture_start) begin
            if (next_write_busy) begin
                next_capture_dropped = 1'b1;
                next_dropped_frames = next_dropped_frames + 1'b1;
            end else begin
                if (!(next_read_busy && next_read_bank == 2'd0) &&
                    !(next_ready_valid && next_ready_bank == 2'd0))
                    free_bank = 2'd0;
                else if (!(next_read_busy && next_read_bank == 2'd1) &&
                         !(next_ready_valid && next_ready_bank == 2'd1))
                    free_bank = 2'd1;
                else if (!(next_read_busy && next_read_bank == 2'd2) &&
                         !(next_ready_valid && next_ready_bank == 2'd2))
                    free_bank = 2'd2;
                else
                    found_free = 1'b0;
                if (found_free) begin
                    next_write_busy = 1'b1;
                    next_write_bank = free_bank;
                    next_capture_accepted = 1'b1;
                end else
                    next_fault = 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_busy <= 1'b0;
            write_bank <= 2'd0;
            ready_valid <= 1'b0;
            ready_bank <= 2'd0;
            read_busy <= 1'b0;
            read_bank <= 2'd0;
            capture_accepted <= 1'b0;
            capture_dropped <= 1'b0;
            reader_acquired <= 1'b0;
            dropped_frames <= 16'd0;
            fault <= 1'b0;
        end else begin
            write_busy <= next_write_busy;
            write_bank <= next_write_bank;
            ready_valid <= next_ready_valid;
            ready_bank <= next_ready_bank;
            read_busy <= next_read_busy;
            read_bank <= next_read_bank;
            capture_accepted <= next_capture_accepted;
            capture_dropped <= next_capture_dropped;
            reader_acquired <= next_reader_acquired;
            dropped_frames <= next_dropped_frames;
            fault <= next_fault;
        end
    end
endmodule
