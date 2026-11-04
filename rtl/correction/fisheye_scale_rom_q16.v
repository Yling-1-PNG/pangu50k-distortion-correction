// Candidate OpenCV-fisheye radial scale table, Q2.16, 513 entries.
// Both words are captured from the addresses present at the clock edge.
// ROM contents are tied to one lens distortion calibration, not to Brown K/D.
module fisheye_scale_rom_q16 #(
    parameter INIT_FILE = "../../rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem",
    parameter INIT_FILE_HI = "../../rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem"
) (
    input  wire clk,
    input  wire [9:0] addr0, addr1,
    output reg [17:0] scale0_q16, scale1_q16
);
    // PDS Lite warns on 18-bit words stored as five hex digits. Split the
    // table into exact-width 16-bit and 4-bit files; only high[1:0] is used.
    reg [15:0] rom_low [0:512];
    reg [3:0] rom_high [0:512];
    initial begin
        $readmemh(INIT_FILE, rom_low);
        $readmemh(INIT_FILE_HI, rom_high);
    end
    always @(posedge clk) begin
        scale0_q16 <= {rom_high[addr0][1:0], rom_low[addr0]};
        scale1_q16 <= {rom_high[addr1][1:0], rom_low[addr1]};
    end
endmodule
