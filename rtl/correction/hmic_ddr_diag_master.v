`timescale 1ns/1ps

// Volatile-memory diagnostic master for the Pango DDR3_50H simplified AXI port.
// This is a board diagnostic, not a write-visibility fence for the correction
// pipeline. It deliberately waits between writes and reads and requires four
// distinct-ID reads to be outstanding before the first response.
module hmic_ddr_diag_master #(
    parameter [27:0] BASE_ADDR = 28'h0001000,
    parameter integer SETTLE_CYCLES = 8192,
    parameter [31:0] WATCHDOG_CYCLES = 32'd50000000
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         ddr_init_done,

    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awuser_id,
    output wire [3:0]   axi_awlen,
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire [3:0]   axi_wusero_id,
    input  wire         axi_wusero_last,

    output wire [27:0]  axi_araddr,
    output wire [3:0]   axi_aruser_id,
    output wire [3:0]   axi_arlen,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rlast,
    input  wire         axi_rvalid,

    output reg          passed,
    output reg          failed,
    output reg  [2:0]   max_outstanding
);
    localparam [2:0] S_WAIT_INIT = 3'd0;
    localparam [2:0] S_WRITE_AW = 3'd1;
    localparam [2:0] S_WRITE_W = 3'd2;
    localparam [2:0] S_SETTLE = 3'd3;
    localparam [2:0] S_READ_AR = 3'd4;
    localparam [2:0] S_READ_R = 3'd5;
    localparam [2:0] S_PASS = 3'd6;
    localparam [2:0] S_FAIL = 3'd7;

    reg [2:0] state;
    reg [1:0] write_index;
    reg [2:0] ar_sent;
    reg [2:0] r_received;
    reg [3:0] seen_ids;
    reg [2:0] in_flight;
    reg saw_response_before_all_ar;
    reg [31:0] settle_count;
    reg [31:0] watchdog_count;
    reg r_valid_stage1, r_last_stage1;
    reg [255:0] r_data_stage1;
    reg [3:0] r_id_stage1;
    reg r_valid_stage2, r_last_stage2;
    reg [3:0] r_id_stage2, r_match_stage2;
    wire [255:0] expected_stage1 = expected_word(r_id_stage1[1:0]);

    wire aw_fire = axi_awvalid && axi_awready;
    wire w_fire = axi_wready;
    wire ar_fire = axi_arvalid && axi_arready;
    wire r_fire = r_valid_stage2;
    wire [2:0] ar_sent_next = ar_sent + (ar_fire ? 3'd1 : 3'd0);
    wire [2:0] r_received_next = r_received + (r_fire ? 3'd1 : 3'd0);
    wire [2:0] in_flight_next = in_flight +
                                (ar_fire ? 3'd1 : 3'd0) -
                                (r_fire ? 3'd1 : 3'd0);

    function [255:0] expected_word;
        input [1:0] index;
        begin
            case (index)
                2'd0: expected_word = 256'h01234567_89abcdef_13579bdf_2468ace0_55aa33cc_cc33aa55_f00dcafe_deadbeef;
                2'd1: expected_word = 256'hfedcba98_76543210_0f1e2d3c_4b5a6978_a55ac33c_3cc35aa5_0badf00d_c001d00d;
                2'd2: expected_word = 256'h11223344_55667788_99aabbcc_ddeeff00_10203040_50607080_90a0b0c0_d0e0f000;
                default: expected_word = 256'h89abcdef_01234567_fedcba98_76543210_aa55aa55_55aa55aa_5a5aa5a5_a5a55a5a;
            endcase
        end
    endfunction

    assign axi_awaddr = BASE_ADDR + {23'd0, write_index, 3'b000};
    assign axi_awuser_id = 4'd0;
    assign axi_awlen = 4'd0;
    assign axi_awvalid = (state == S_WRITE_AW);
    assign axi_wdata = expected_word(write_index);
    assign axi_wstrb = 32'hffffffff;

    assign axi_araddr = BASE_ADDR + {22'd0, ar_sent[1:0], 3'b000};
    assign axi_aruser_id = {2'b00, ar_sent[1:0]};
    assign axi_arlen = 4'd0;
    assign axi_arvalid = (state == S_READ_AR) && (ar_sent < 3'd4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_WAIT_INIT;
            write_index <= 2'd0;
            ar_sent <= 3'd0;
            r_received <= 3'd0;
            seen_ids <= 4'b0;
            in_flight <= 3'd0;
            max_outstanding <= 3'd0;
            saw_response_before_all_ar <= 1'b0;
            settle_count <= 32'd0;
            watchdog_count <= 32'd0;
            r_valid_stage1 <= 1'b0;
            r_last_stage1 <= 1'b0;
            r_data_stage1 <= 256'd0;
            r_id_stage1 <= 4'd0;
            r_valid_stage2 <= 1'b0;
            r_last_stage2 <= 1'b0;
            r_id_stage2 <= 4'd0;
            r_match_stage2 <= 4'd0;
            passed <= 1'b0;
            failed <= 1'b0;
        end else if (!passed && !failed) begin
            if (watchdog_count == WATCHDOG_CYCLES - 1'b1) begin
                state <= S_FAIL;
                failed <= 1'b1;
            end else begin
                watchdog_count <= watchdog_count + 1'b1;

                r_valid_stage1 <= axi_rvalid;
                r_last_stage1 <= axi_rlast;
                r_data_stage1 <= axi_rdata;
                r_id_stage1 <= axi_rid;
                r_valid_stage2 <= r_valid_stage1;
                r_last_stage2 <= r_last_stage1;
                r_id_stage2 <= r_id_stage1;
                r_match_stage2 <= {
                    r_data_stage1[255:192] == expected_stage1[255:192],
                    r_data_stage1[191:128] == expected_stage1[191:128],
                    r_data_stage1[127:64] == expected_stage1[127:64],
                    r_data_stage1[63:0] == expected_stage1[63:0]
                };

                if (ar_fire)
                    ar_sent <= ar_sent_next;
                if (r_fire)
                    r_received <= r_received_next;
                if (ar_fire || r_fire)
                    in_flight <= in_flight_next;
                if (in_flight_next > max_outstanding)
                    max_outstanding <= in_flight_next;

                if (axi_rvalid && (ar_sent < 3'd4))
                    saw_response_before_all_ar <= 1'b1;

                if (r_fire) begin
                    if ((r_id_stage2 > 4'd3) || seen_ids[r_id_stage2[1:0]] ||
                        !r_last_stage2 || (r_match_stage2 != 4'hf)) begin
                        state <= S_FAIL;
                        failed <= 1'b1;
                    end else begin
                        seen_ids[r_id_stage2[1:0]] <= 1'b1;
                    end
                end

                case (state)
                    S_WAIT_INIT: begin
                        if (ddr_init_done)
                            state <= S_WRITE_AW;
                    end
                    S_WRITE_AW: begin
                        if (aw_fire)
                            state <= S_WRITE_W;
                    end
                    S_WRITE_W: begin
                        if (w_fire) begin
                            if (!axi_wusero_last || (axi_wusero_id != 4'd0)) begin
                                state <= S_FAIL;
                                failed <= 1'b1;
                            end else if (write_index == 2'd3) begin
                                state <= S_SETTLE;
                                settle_count <= 32'd0;
                            end else begin
                                write_index <= write_index + 1'b1;
                                state <= S_WRITE_AW;
                            end
                        end
                    end
                    S_SETTLE: begin
                        if (settle_count == SETTLE_CYCLES - 1)
                            state <= S_READ_AR;
                        else
                            settle_count <= settle_count + 1'b1;
                    end
                    S_READ_AR: begin
                        if ((ar_sent_next == 3'd4) && (r_received_next == 3'd4)) begin
                            if ((max_outstanding == 3'd4) &&
                                !saw_response_before_all_ar &&
                                (in_flight_next == 3'd0)) begin
                                state <= S_PASS;
                                passed <= 1'b1;
                            end else begin
                                state <= S_FAIL;
                                failed <= 1'b1;
                            end
                        end else if (ar_sent_next == 3'd4) begin
                            state <= S_READ_R;
                        end
                    end
                    S_READ_R: begin
                        if (r_received_next == 3'd4) begin
                            if ((ar_sent == 3'd4) && (max_outstanding == 3'd4) &&
                                !saw_response_before_all_ar &&
                                (in_flight_next == 3'd0)) begin
                                state <= S_PASS;
                                passed <= 1'b1;
                            end else begin
                                state <= S_FAIL;
                                failed <= 1'b1;
                            end
                        end
                    end
                    default: begin
                        state <= state;
                    end
                endcase
            end
        end
    end
endmodule
