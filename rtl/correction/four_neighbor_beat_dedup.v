// Merge repeated 256-bit beat indices within one output pixel's four samples.
// Slots preserve first-appearance order: 00, 10, 01, 11. Only slots below
// unique_count are valid. No cache lookup, request scheduling or DDR access.
module four_neighbor_beat_dedup (
    input  wire        valid_in,
    input  wire [17:0] beat00,
    input  wire [17:0] beat10,
    input  wire [17:0] beat01,
    input  wire [17:0] beat11,
    output wire [2:0]  unique_count,
    output wire [17:0] uniq_0,
    output wire [17:0] uniq_1,
    output wire [17:0] uniq_2,
    output wire [17:0] uniq_3,
    output wire [1:0]  slot00,
    output wire [1:0]  slot10,
    output wire [1:0]  slot01,
    output wire [1:0]  slot11
);
    wire add10 = beat10 != beat00;
    wire [2:0] count10 = add10 ? 3'd2 : 3'd1;
    wire hit01_0 = beat01 == beat00;
    wire hit01_1 = add10 && beat01 == beat10;
    wire add01 = !hit01_0 && !hit01_1;
    wire [2:0] count01 = count10 + {2'd0, add01};
    wire [17:0] uniq1_01 = add10 ? beat10 : (add01 ? beat01 : 18'd0);
    wire [17:0] uniq2_01 = add10 && add01 ? beat01 : 18'd0;
    wire hit11_0 = beat11 == beat00;
    wire hit11_1 = count01 > 3'd1 && beat11 == uniq1_01;
    wire hit11_2 = count01 > 3'd2 && beat11 == uniq2_01;
    wire add11 = !hit11_0 && !hit11_1 && !hit11_2;

    assign unique_count = valid_in ? count01 + {2'd0, add11} : 3'd0;
    assign uniq_0 = valid_in ? beat00 : 18'd0;
    assign uniq_1 = valid_in ? (count01 > 3'd1 ? uniq1_01 :
                         (add11 ? beat11 : 18'd0)) : 18'd0;
    assign uniq_2 = valid_in ? (count01 > 3'd2 ? uniq2_01 :
                         (count01 == 3'd2 && add11 ? beat11 : 18'd0)) : 18'd0;
    assign uniq_3 = valid_in && count01 == 3'd3 && add11 ? beat11 : 18'd0;
    assign slot00 = 2'd0;
    assign slot10 = valid_in && add10 ? 2'd1 : 2'd0;
    assign slot01 = valid_in ? (hit01_0 ? 2'd0 :
                         (hit01_1 ? 2'd1 : count10[1:0])) : 2'd0;
    assign slot11 = valid_in ? (hit11_0 ? 2'd0 :
                         (hit11_1 ? 2'd1 :
                         (hit11_2 ? 2'd2 : count01[1:0]))) : 2'd0;
endmodule
