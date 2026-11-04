`timescale 1ns/1ps
// Candidate byte-frame parser for host/correction_protocol.py.
// Input bytes are already sampled in clk domain; this module is not a UART RX.
// A complete, CRC-checked config is held until cfg_ready. If the one-entry
// output is occupied by another valid config, the new config is dropped and
// cfg_overrun is set (sticky until reset).
module correction_config_frame_rx (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         rx_valid,
    input  wire [7:0]   rx_data,
    output reg          cfg_valid,
    input  wire         cfg_ready,
    output reg  [339:0] cfg_data,
    output reg  [15:0]  cfg_sequence,
    output reg          frame_rejected,
    output reg          cfg_overrun
);
    localparam [2:0] ST_WAIT_P  = 3'd0;
    localparam [2:0] ST_WAIT_G  = 3'd1;
    localparam [2:0] ST_HEADER = 3'd2;
    localparam [2:0] ST_PAYLOAD = 3'd3;
    localparam [2:0] ST_CRC_LO = 3'd4;
    localparam [2:0] ST_CRC_HI = 3'd5;

    reg [2:0] state;
    reg [2:0] header_index;
    reg [7:0] version;
    reg [7:0] message_type;
    reg [15:0] frame_sequence;
    reg [7:0] payload_length;
    reg [7:0] payload_count;
    reg [6:0] payload_field_index;
    reg [1:0] payload_subindex;
    reg [7:0] slot_byte0, slot_byte1;
    reg [15:0] crc;
    reg [7:0] received_crc_lo;
    reg padding_bad;
    reg [339:0] assembly_config;

    function [15:0] crc16_ccitt_false_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [15:0] value;
        begin
            value = crc_in ^ {data_in, 8'h00};
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[15] ? ((value << 1) ^ 16'h1021) : (value << 1);
            crc16_ccitt_false_byte = value;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_WAIT_P;
            header_index <= 3'd0;
            version <= 8'd0;
            message_type <= 8'd0;
            frame_sequence <= 16'd0;
            payload_length <= 8'd0;
            payload_count <= 8'd0;
            payload_field_index <= 7'd0;
            payload_subindex <= 2'd0;
            slot_byte0 <= 8'd0;
            slot_byte1 <= 8'd0;
            crc <= 16'hffff;
            received_crc_lo <= 8'd0;
            padding_bad <= 1'b0;
            assembly_config <= 340'd0;
            cfg_valid <= 1'b0;
            cfg_data <= 340'd0;
            cfg_sequence <= 16'd0;
            frame_rejected <= 1'b0;
            cfg_overrun <= 1'b0;
        end else begin
            frame_rejected <= 1'b0;

            if (cfg_valid && cfg_ready)
                cfg_valid <= 1'b0;

            if (rx_valid) begin
                case (state)
                    ST_WAIT_P: begin
                        if (rx_data == 8'h50)
                            state <= ST_WAIT_G;
                    end

                    ST_WAIT_G: begin
                        if (rx_data == 8'h47) begin
                            state <= ST_HEADER;
                            header_index <= 3'd0;
                            crc <= 16'hffff;
                        end else if (rx_data != 8'h50) begin
                            state <= ST_WAIT_P;
                        end
                    end

                    ST_HEADER: begin
                        crc <= crc16_ccitt_false_byte(crc, rx_data);
                        case (header_index)
                            3'd0: version <= rx_data;
                            3'd1: message_type <= rx_data;
                            3'd2: frame_sequence[7:0] <= rx_data;
                            3'd3: frame_sequence[15:8] <= rx_data;
                            3'd4: begin
                                payload_length <= rx_data;
                                payload_count <= 8'd0;
                                payload_field_index <= 7'd0;
                                payload_subindex <= 2'd0;
                                padding_bad <= 1'b0;
                                if (rx_data == 8'd0)
                                    state <= ST_CRC_LO;
                                else
                                    state <= ST_PAYLOAD;
                            end
                            default: state <= ST_WAIT_P;
                        endcase
                        if (header_index != 3'd4)
                            header_index <= header_index + 1'b1;
                    end

                    ST_PAYLOAD: begin
                        crc <= crc16_ccitt_false_byte(crc, rx_data);
                        if (payload_field_index < 7'd16) begin
                            case (payload_subindex)
                                2'd0: slot_byte0 <= rx_data;
                                2'd1: slot_byte1 <= rx_data;
                                2'd2: begin
                                    // 24-bit little-endian slots contain either
                                    // a signed 22-bit / 20-bit value or unsigned
                                    // 22-bit inverse focal length.
                                    if (payload_field_index <= 7'd3 ||
                                        (payload_field_index >= 7'd12 &&
                                         payload_field_index <= 7'd15)) begin
                                        if (rx_data[7:6] != {2{rx_data[5]}})
                                            padding_bad <= 1'b1;
                                        case (payload_field_index)
                                            7'd0:  assembly_config[339:318] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd1:  assembly_config[317:296] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd2:  assembly_config[295:274] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd3:  assembly_config[273:252] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd12: assembly_config[87:66]   <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd13: assembly_config[65:44]   <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd14: assembly_config[43:22]   <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            7'd15: assembly_config[21:0]    <= {rx_data[5:0], slot_byte1, slot_byte0};
                                            default: begin end
                                        endcase
                                    end else if (payload_field_index >= 7'd4 &&
                                                 payload_field_index <= 7'd9) begin
                                        if (rx_data[7:4] != {4{rx_data[3]}})
                                            padding_bad <= 1'b1;
                                        case (payload_field_index)
                                            7'd4: assembly_config[251:232] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            7'd5: assembly_config[231:212] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            7'd6: assembly_config[211:192] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            7'd7: assembly_config[191:172] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            7'd8: assembly_config[171:152] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            7'd9: assembly_config[151:132] <= {rx_data[3:0], slot_byte1, slot_byte0};
                                            default: begin end
                                        endcase
                                    end else begin
                                        if (rx_data[7:6] != 2'b00)
                                            padding_bad <= 1'b1;
                                        if (payload_field_index == 7'd10)
                                            assembly_config[131:110] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                        else
                                            assembly_config[109:88] <= {rx_data[5:0], slot_byte1, slot_byte0};
                                    end
                                    payload_field_index <= payload_field_index + 1'b1;
                                end
                                default: begin end
                            endcase
                            if (payload_subindex == 2'd2)
                                payload_subindex <= 2'd0;
                            else
                                payload_subindex <= payload_subindex + 1'b1;
                        end

                        if (payload_count == payload_length - 1'b1)
                            state <= ST_CRC_LO;
                        payload_count <= payload_count + 1'b1;
                    end

                    ST_CRC_LO: begin
                        received_crc_lo <= rx_data;
                        state <= ST_CRC_HI;
                    end

                    ST_CRC_HI: begin
                        state <= ST_WAIT_P;
                        if (crc[7:0] == received_crc_lo && crc[15:8] == rx_data &&
                            version == 8'd1 && message_type == 8'h01 &&
                            payload_length == 8'd48 && !padding_bad) begin
                            if (!cfg_valid || cfg_ready) begin
                                cfg_data <= assembly_config;
                                cfg_sequence <= frame_sequence;
                                cfg_valid <= 1'b1;
                            end else begin
                                cfg_overrun <= 1'b1;
                            end
                        end else begin
                            frame_rejected <= 1'b1;
                        end
                    end

                    default: state <= ST_WAIT_P;
                endcase
            end
        end
    end
endmodule
