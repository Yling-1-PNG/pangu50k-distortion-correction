// Select four RGB565 neighbours from up to four canonical 256-bit beats.
// Canonical lane N occupies bits [16*N +: 16]. This is a PC/test contract,
// not yet a proven mapping of the PGL50H HMIC axi_rdata physical bit order.
module rgb565_four_sample_select (
    input  wire         valid_in,
    input  wire [2:0]   beat_count,
    input  wire [255:0] beat_0,
    input  wire [255:0] beat_1,
    input  wire [255:0] beat_2,
    input  wire [255:0] beat_3,
    input  wire [1:0]   slot00,
    input  wire [1:0]   slot10,
    input  wire [1:0]   slot01,
    input  wire [1:0]   slot11,
    input  wire [3:0]   lane00,
    input  wire [3:0]   lane10,
    input  wire [3:0]   lane01,
    input  wire [3:0]   lane11,
    output wire         valid_out,
    output wire [15:0]  p00,
    output wire [15:0]  p10,
    output wire [15:0]  p01,
    output wire [15:0]  p11
);
    function [15:0] select_pixel;
        input [255:0] b0, b1, b2, b3;
        input [1:0] slot;
        input [3:0] lane;
        begin
            case (slot)
                2'd0: select_pixel = b0[{lane, 4'b0} +: 16];
                2'd1: select_pixel = b1[{lane, 4'b0} +: 16];
                2'd2: select_pixel = b2[{lane, 4'b0} +: 16];
                2'd3: select_pixel = b3[{lane, 4'b0} +: 16];
            endcase
        end
    endfunction

    assign valid_out = valid_in && beat_count >= 3'd1 && beat_count <= 3'd4
                    && {1'b0, slot00} < beat_count
                    && {1'b0, slot10} < beat_count
                    && {1'b0, slot01} < beat_count
                    && {1'b0, slot11} < beat_count;
    assign p00 = valid_out ? select_pixel(beat_0, beat_1, beat_2, beat_3,
                                          slot00, lane00) : 16'd0;
    assign p10 = valid_out ? select_pixel(beat_0, beat_1, beat_2, beat_3,
                                          slot10, lane10) : 16'd0;
    assign p01 = valid_out ? select_pixel(beat_0, beat_1, beat_2, beat_3,
                                          slot01, lane01) : 16'd0;
    assign p11 = valid_out ? select_pixel(beat_0, beat_1, beat_2, beat_3,
                                          slot11, lane11) : 16'd0;
endmodule
