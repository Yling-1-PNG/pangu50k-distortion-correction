// Convert a frame-relative 256-bit beat index to the HMIC_S address port.
// UG022003 V1.4 section 2.8.1 gives an address step of 8 per 256-bit beat.
// The frame base must be aligned to that step and already be an HMIC address.
// This does not define DDR bank mapping or RGB565 lane order.
module hmic_beat_address (
    input  wire        valid_in,
    input  wire [27:0] frame_base_ctrl_addr,
    input  wire [17:0] beat_index,
    output wire        valid_out,
    output wire [27:0] ctrl_addr
);
    wire [28:0] extended_addr =
        {1'b0, frame_base_ctrl_addr} + {8'd0, beat_index, 3'd0};
    assign valid_out = valid_in && frame_base_ctrl_addr[2:0] == 3'd0
                     && !extended_addr[28];
    assign ctrl_addr = valid_out ? extended_addr[27:0] : 28'd0;
endmodule
