// Dual-clock RGB565 FIFO. Reset assertion is asynchronous; each side waits
// for two local clock edges before accepting traffic after reset release.
module video_async_fifo #(
    parameter ADDR_BITS = 11
) (
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire        rst_n,
    input  wire        wr_valid,
    output wire        wr_ready,
    input  wire [15:0] wr_pixel,
    input  wire        rd_take,
    output wire        rd_valid,
    output wire [15:0] rd_pixel,
    output reg         underflow
);
    localparam PTR_BITS = ADDR_BITS + 1;
    reg [15:0] memory [0:(1 << ADDR_BITS)-1];
    reg [PTR_BITS-1:0] wr_bin, wr_gray, rd_bin, rd_gray;
    reg [PTR_BITS-1:0] rd_gray_w1, rd_gray_w2;
    reg [PTR_BITS-1:0] wr_gray_r1, wr_gray_r2;
    reg [1:0] wr_release, rd_release;
    reg full, empty;

    wire push = wr_valid && wr_ready;
    wire pop = rd_take && rd_valid;
    wire [PTR_BITS-1:0] wr_bin_next = wr_bin + push;
    wire [PTR_BITS-1:0] rd_bin_next = rd_bin + pop;
    wire [PTR_BITS-1:0] wr_gray_next =
        (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_BITS-1:0] rd_gray_next =
        (rd_bin_next >> 1) ^ rd_bin_next;
    // A Gray-permuted RAM address preserves FIFO order (the transform is
    // bijective) while adding local decode delay before the wide RAM address
    // fanout, which helps the physical hold path from the write pointer.
    wire [ADDR_BITS-1:0] wr_addr =
        wr_bin[ADDR_BITS-1:0] ^ (wr_bin[ADDR_BITS-1:0] >> 1);
    wire [ADDR_BITS-1:0] rd_addr =
        rd_bin[ADDR_BITS-1:0] ^ (rd_bin[ADDR_BITS-1:0] >> 1);

    assign wr_ready = wr_release[1] && !full;
    assign rd_valid = rd_release[1] && !empty;
    assign rd_pixel = rd_valid ? memory[rd_addr] : 16'd0;

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n)
            wr_release <= 0;
        else
            wr_release <= {wr_release[0], 1'b1};
    end
    always @(posedge rd_clk or negedge rst_n) begin
        if (!rst_n)
            rd_release <= 0;
        else
            rd_release <= {rd_release[0], 1'b1};
    end

    always @(posedge wr_clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bin <= 0;
            wr_gray <= 0;
            rd_gray_w1 <= 0;
            rd_gray_w2 <= 0;
            full <= 0;
        end else if (!wr_release[1]) begin
            wr_bin <= 0;
            wr_gray <= 0;
            rd_gray_w1 <= 0;
            rd_gray_w2 <= 0;
            full <= 0;
        end else begin
            rd_gray_w1 <= rd_gray;
            rd_gray_w2 <= rd_gray_w1;
            if (push) begin
                memory[wr_addr] <= wr_pixel;
                wr_bin <= wr_bin_next;
                wr_gray <= wr_gray_next;
            end
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
            empty <= 1;
            underflow <= 0;
        end else if (!rd_release[1]) begin
            rd_bin <= 0;
            rd_gray <= 0;
            wr_gray_r1 <= 0;
            wr_gray_r2 <= 0;
            empty <= 1;
            underflow <= 0;
        end else begin
            wr_gray_r1 <= wr_gray;
            wr_gray_r2 <= wr_gray_r1;
            if (pop) begin
                rd_bin <= rd_bin_next;
                rd_gray <= rd_gray_next;
            end
            if (rd_take && !rd_valid)
                underflow <= 1;
            empty <= rd_gray_next == wr_gray_r2;
        end
    end
endmodule
