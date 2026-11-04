`timescale 1ns/1ps

// Auditable ROM wrapper for the OV5640 initialization table.
// Each word is {register_address[15:0], value[7:0]}.

module ov5640_init_rom #(
    parameter integer REGISTER_COUNT = 357,
    parameter INIT_FILE = "rtl/data/ov5640_720p30_init_2023.mem"
) (
    input  wire [8:0]  addr,
    output wire [23:0] data
);
    reg [23:0] rom [0:REGISTER_COUNT-1];

    initial $readmemh(INIT_FILE, rom);

    assign data = rom[addr];
endmodule
