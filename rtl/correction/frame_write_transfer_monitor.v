// Checks the HMIC write data beat pattern, not DDR read visibility.
// frame_begin must precede the first AW handshake; frame_end may arrive early.
module frame_write_transfer_monitor #(
    parameter integer FRAME_BURSTS = 3600,
    parameter integer FRAME_ADDR_UNITS = 460800
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_begin,
    input  wire        frame_end,
    input  wire [27:0] frame_base,
    input  wire        axi_awvalid,
    input  wire        axi_awready,
    input  wire [27:0] axi_awaddr,
    input  wire [3:0]  axi_awlen,
    input  wire        axi_wready,
    input  wire        axi_wusero_last,
    output reg         active,
    output reg         transfer_done,
    output reg         fault,
    output reg [12:0]  aw_count,
    output reg [12:0]  last_count
);
    reg [27:0] held_base;
    reg end_seen;
    reg [3:0] beat_index;
    wire aw_fire = axi_awvalid && axi_awready;
    wire last_fire = axi_wready && axi_wusero_last;
    wire [13:0] aw_next = {1'b0, aw_count} + aw_fire;
    wire [13:0] last_next = {1'b0, last_count} + last_fire;
    wire [28:0] expected_awaddr =
        {1'b0, held_base} + {9'd0, aw_count, 7'd0};
    wire [28:0] aw_end = {1'b0, axi_awaddr} + 29'd128;
    wire [28:0] frame_limit = {1'b0, held_base} + FRAME_ADDR_UNITS;
    wire bad_aw = aw_fire && (axi_awlen != 4'd15 || axi_awaddr[2:0] != 0 ||
                              {1'b0, axi_awaddr} != expected_awaddr ||
                              aw_end > frame_limit ||
                              aw_count >= FRAME_BURSTS);
    wire bad_last = last_fire && (last_count >= FRAME_BURSTS ||
                                  last_next > aw_next);
    wire bad_beat = axi_wready &&
                    (axi_wusero_last != (beat_index == 4'd15));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            held_base <= 28'd0;
            end_seen <= 1'b0;
            beat_index <= 4'd0;
            transfer_done <= 1'b0;
            fault <= 1'b0;
            aw_count <= 13'd0;
            last_count <= 13'd0;
        end else begin
            transfer_done <= 1'b0;
            if (frame_begin) begin
                if (active)
                    fault <= 1'b1;
                else begin
                    active <= 1'b1;
                    held_base <= frame_base;
                    end_seen <= 1'b0;
                    beat_index <= 4'd0;
                    aw_count <= 13'd0;
                    last_count <= 13'd0;
                end
            end else if (active) begin
                if (frame_end)
                    end_seen <= 1'b1;
                if (aw_fire)
                    aw_count <= aw_next[12:0];
                if (last_fire)
                    last_count <= last_next[12:0];
                if (axi_wready)
                    beat_index <= beat_index + 4'd1;
                if (bad_aw || bad_last || bad_beat)
                    fault <= 1'b1;
                if (!fault && !bad_aw && !bad_last && !bad_beat &&
                    (end_seen || frame_end) &&
                    aw_next == FRAME_BURSTS && last_next == FRAME_BURSTS) begin
                    active <= 1'b0;
                    transfer_done <= 1'b1;
                end
            end else if (frame_end || aw_fire || last_fire)
                fault <= 1'b1;
        end
    end
endmodule
