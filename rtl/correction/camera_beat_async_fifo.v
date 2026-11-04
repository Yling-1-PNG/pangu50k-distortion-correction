`timescale 1ns/1ps
// Asynchronous FIFO for one complete RGB565 camera beat plus its frame-last
// marker. Reset assertion is asynchronous; each clock domain waits for two
// local edges before accepting traffic. Frame abort/flush is intentionally not
// implemented here: the system must stop the producer and drain/discard queued
// beats through an acknowledged frame-lifecycle protocol before rearming.
module camera_beat_async_fifo #(
    parameter integer ADDR_BITS = 5
) (
    input  wire         wr_clk,
    input  wire         rd_clk,
    input  wire         rst_n,
    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire [255:0] wr_data,
    input  wire         wr_last,
    input  wire         rd_take,
    output wire         rd_valid,
    output wire [255:0] rd_data,
    output wire         rd_last,
    output reg          overflow,
    output reg          underflow
);
    localparam integer PTR_BITS = ADDR_BITS + 1;
    localparam integer ENTRY_BITS = 257;
    localparam [PTR_BITS-1:0] WR_BIN_INVERT_MASK =
        (ADDR_BITS >= 5) ? ({{(PTR_BITS-1){1'b0}}, 1'b1} << 4) :
                           {PTR_BITS{1'b0}};
    localparam [ADDR_BITS-1:0] RAM_ADDR_XOR = (1 << (ADDR_BITS - 1));
    reg [ENTRY_BITS-1:0] memory [0:(1 << ADDR_BITS)-1];
    reg [PTR_BITS-1:0] wr_bin_encoded, wr_gray, rd_bin, rd_gray;
    // Decode locally so the measured WADM4 path sees a logic boundary while
    // the externally visible FIFO pointer remains in the original encoding.
    wire [PTR_BITS-1:0] wr_bin = wr_bin_encoded ^ WR_BIN_INVERT_MASK;
    reg [PTR_BITS-1:0] rd_gray_w1, rd_gray_w2;
    reg [PTR_BITS-1:0] wr_gray_r1, wr_gray_r2;
    reg [1:0] wr_release, rd_release;
    reg full, empty;

    wire push = wr_valid && wr_ready;
    wire pop = rd_take && rd_valid;
    wire [PTR_BITS-1:0] wr_bin_next = wr_bin + push;
    wire [PTR_BITS-1:0] rd_bin_next = rd_bin + pop;
    wire [PTR_BITS-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_BITS-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;
    // Apply the same address permutation on both ports. This inserts an
    // inverter on the highest write-address bit without changing FIFO order.
    wire [ADDR_BITS-1:0] wr_ram_addr = wr_bin[ADDR_BITS-1:0] ^ RAM_ADDR_XOR;
    wire [ADDR_BITS-1:0] rd_ram_addr = rd_bin[ADDR_BITS-1:0] ^ RAM_ADDR_XOR;
    // Store a reversible address-keyed representation. The XOR adds a small
    // data-path delay before the LUT-RAM write port, which is otherwise a
    // direct packer-register-to-RAM path with a measured hold violation.
    wire [ENTRY_BITS-1:0] write_word_encoded =
        {wr_last, wr_data} ^ {ENTRY_BITS{wr_bin[0]}};
    wire [ENTRY_BITS-1:0] read_word_decoded =
        memory[rd_ram_addr] ^ {ENTRY_BITS{rd_bin[0]}};

    assign wr_ready = wr_release[1] && !full;
    assign rd_valid = rd_release[1] && !empty;
    assign {rd_last, rd_data} = rd_valid ? read_word_decoded : 257'd0;

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n)
            wr_release <= 2'b00;
        else
            wr_release <= {wr_release[0], 1'b1};
    end

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n)
            rd_release <= 2'b00;
        else
            rd_release <= {rd_release[0], 1'b1};
    end

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bin_encoded <= WR_BIN_INVERT_MASK;
            wr_gray <= 0;
            rd_gray_w1 <= 0;
            rd_gray_w2 <= 0;
            full <= 1'b0;
            overflow <= 1'b0;
        end else if (!wr_release[1]) begin
            wr_bin_encoded <= WR_BIN_INVERT_MASK;
            wr_gray <= 0;
            rd_gray_w1 <= 0;
            rd_gray_w2 <= 0;
            full <= 1'b0;
            overflow <= 1'b0;
        end else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
            if (push) begin
                memory[wr_ram_addr] <= write_word_encoded;
                wr_bin_encoded <= wr_bin_next ^ WR_BIN_INVERT_MASK;
                wr_gray <= wr_gray_next;
            end
            if (wr_valid && !wr_ready)
                overflow <= 1'b1;
            full <= wr_gray_next ==
                {~rd_gray_w2[PTR_BITS-1:PTR_BITS-2],
                  rd_gray_w2[PTR_BITS-3:0]};
        end
    end

    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_bin <= 0;
            rd_gray <= 0;
            wr_gray_r1 <= 0;
            wr_gray_r2 <= 0;
            empty <= 1'b1;
            underflow <= 1'b0;
        end else if (!rd_release[1]) begin
            rd_bin <= 0;
            rd_gray <= 0;
            wr_gray_r1 <= 0;
            wr_gray_r2 <= 0;
            empty <= 1'b1;
            underflow <= 1'b0;
        end else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
            if (pop) begin
                rd_bin <= rd_bin_next;
                rd_gray <= rd_gray_next;
            end
            if (rd_take && !rd_valid)
                underflow <= 1'b1;
            empty <= rd_gray_next == wr_gray_r2;
        end
    end
endmodule
