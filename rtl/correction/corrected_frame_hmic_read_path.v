// Sequential corrected-frame reader in the DDR clock domain. HMIC-S has no
// RREADY, so every accepted 16-beat burst is captured before pixels are
// released to the downstream FIFO. When PREFETCH_BURSTS is enabled, the next
// burst is requested while the current 256-pixel burst is being drained. The
// default remains the historical one-burst behavior for a clean A/B.
module corrected_frame_hmic_read_path #(
    parameter integer FRAME_PIXELS = 1280 * 720,
    parameter [3:0] READ_ID = 4'he,
    parameter integer PREFETCH_BURSTS = 0,
    parameter integer PREFETCH_TRIGGER_PIXELS = 128,
    // Set only when an upstream register stage delays RVALID/RDATA together.
    parameter integer RESPONSE_VALID_REGISTERED = 0
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_start,
    input  wire [27:0]  frame_base,
    output wire         frame_ready,
    output reg          frame_done,
    output wire         pixel_valid,
    input  wire         pixel_ready,
    output wire [15:0]  pixel_data,
    output reg  [15:0]  diagnostic_drain_beats,
    output wire [27:0]  axi_araddr,
    output wire [3:0]   axi_aruser_id,
    output wire [3:0]   axi_arlen,
    output wire         axi_aruser_ap,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rlast,
    input  wire         axi_rvalid,
    output reg          fault
);
    localparam integer FRAME_BURSTS = FRAME_PIXELS / 256;
    localparam integer SHAPE_OK = FRAME_PIXELS >= 256 &&
                                  FRAME_PIXELS % 256 == 0 &&
                                  FRAME_BURSTS <= 4095;
    localparam [2:0] S_IDLE = 0, S_AR = 1, S_R = 2,
                     S_DRAIN = 3, S_WAIT_PREFETCH = 4, S_FAULT = 5;
    localparam [1:0] PF_IDLE = 0, PF_AR = 1, PF_R = 2, PF_READY = 3;

    reg [2:0] state;
    reg [1:0] prefetch_state;
    reg [27:0] base_q;
    reg [12:0] burst_index;
    reg [3:0] receive_index;
    reg [3:0] prefetch_receive_index;
    reg [7:0] pixel_index;
    reg current_bank;

    wire pixel_fire = pixel_valid && pixel_ready;
    wire [28:0] frame_limit = {1'b0, frame_base} +
                              FRAME_BURSTS * 29'd128;
    wire current_response_accept = axi_rvalid && !fault &&
        (RESPONSE_VALID_REGISTERED != 0 ? state == S_R :
         ((state == S_AR && axi_arready) || state == S_R));
    wire prefetch_response_accept = axi_rvalid && !fault &&
        (RESPONSE_VALID_REGISTERED != 0 ? prefetch_state == PF_R :
         ((prefetch_state == PF_AR && axi_arready) ||
          prefetch_state == PF_R));
    wire unexpected_response = axi_rvalid && !fault &&
                               !current_response_accept &&
                               !prefetch_response_accept;
    wire [3:0] current_response_index =
        state == S_AR ? 4'd0 : receive_index;
    wire [3:0] prefetch_response_index =
        prefetch_state == PF_AR ? 4'd0 : prefetch_receive_index;
    wire prefetch_start = (PREFETCH_BURSTS != 0) &&
        state == S_DRAIN && pixel_fire &&
        pixel_index == (PREFETCH_TRIGGER_PIXELS - 1) &&
        burst_index < FRAME_BURSTS - 1 && prefetch_state == PF_IDLE;
    wire [12:0] request_burst = state == S_AR ? burst_index :
                                 burst_index + 13'd1;

    // Two explicit banks avoid a read/write collision while a prefetched
    // burst is received. Each 256-bit beat remains a separately enabled
    // register, preserving the board-proven fix for the old LUTRAM mapping.
    wire [255:0] burst_data_bank0 [0:15];
    wire [255:0] burst_data_bank1 [0:15];
    wire [255:0] selected_burst = current_bank ?
                                   burst_data_bank1[pixel_index[7:4]] :
                                   burst_data_bank0[pixel_index[7:4]];
    genvar bank, beat;
    generate
        for (bank = 0; bank < 2; bank = bank + 1) begin : g_burst_bank
            for (beat = 0; beat < 16; beat = beat + 1) begin : g_burst_register
                reg [255:0] data_q;
                always @(posedge clk) begin
                    if (current_response_accept &&
                        current_bank == bank &&
                        current_response_index == beat)
                        data_q <= axi_rdata;
                    if (prefetch_response_accept &&
                        current_bank != bank &&
                        prefetch_response_index == beat)
                        data_q <= axi_rdata;
                end
                if (bank == 0)
                    assign burst_data_bank0[beat] = data_q;
                else
                    assign burst_data_bank1[beat] = data_q;
            end
        end
    endgenerate

    assign frame_ready = state == S_IDLE && !fault && SHAPE_OK;
    assign pixel_valid = state == S_DRAIN && !fault;
    assign pixel_data = selected_burst[pixel_index[3:0] * 16 +: 16];
    assign axi_araddr = base_q + {8'd0, request_burst, 7'd0};
    assign axi_aruser_id = READ_ID;
    assign axi_arlen = 4'd15;
    assign axi_aruser_ap = 1'b0;
    assign axi_arvalid = !fault && (state == S_AR ||
                                    prefetch_state == PF_AR);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            prefetch_state <= PF_IDLE;
            base_q <= 28'd0;
            burst_index <= 13'd0;
            receive_index <= 4'd0;
            prefetch_receive_index <= 4'd0;
            pixel_index <= 8'd0;
            current_bank <= 1'b0;
            diagnostic_drain_beats <= 16'd0;
            frame_done <= 1'b0;
            fault <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (pixel_fire && |pixel_data)
                diagnostic_drain_beats[pixel_index[7:4]] <= 1'b1;

            if (fault || state == S_FAULT) begin
                state <= S_FAULT;
                prefetch_state <= PF_IDLE;
            end else if ((frame_start && !frame_ready) || unexpected_response) begin
                fault <= 1'b1;
                state <= S_FAULT;
                prefetch_state <= PF_IDLE;
            end else begin
                // The prefetch FSM is independent of the current burst
                // drain, but the single HMIC port never has two AR requests
                // active at once.
                if (prefetch_start)
                    prefetch_state <= PF_AR;
                else if (prefetch_state == PF_AR && axi_arready) begin
                    if (RESPONSE_VALID_REGISTERED == 0 && axi_rvalid) begin
                        if (axi_rid != READ_ID || axi_rlast) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                            prefetch_state <= PF_IDLE;
                        end else begin
                            prefetch_receive_index <= 4'd1;
                            prefetch_state <= PF_R;
                        end
                    end else begin
                        prefetch_receive_index <= 4'd0;
                        prefetch_state <= PF_R;
                    end
                end else if (prefetch_state == PF_R && axi_rvalid) begin
                    if (axi_rid != READ_ID ||
                        axi_rlast != (prefetch_receive_index == 4'd15)) begin
                        fault <= 1'b1;
                        state <= S_FAULT;
                        prefetch_state <= PF_IDLE;
                    end else if (prefetch_receive_index == 4'd15) begin
                        prefetch_state <= PF_READY;
                    end else
                        prefetch_receive_index <= prefetch_receive_index + 1'b1;
                end

                case (state)
                    S_IDLE: if (frame_start) begin
                        if (frame_base[6:0] != 0 ||
                            frame_limit > 29'h10000000) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else begin
                            base_q <= frame_base;
                            burst_index <= 13'd0;
                            receive_index <= 4'd0;
                            pixel_index <= 8'd0;
                            current_bank <= 1'b0;
                            state <= S_AR;
                        end
                    end
                    S_AR: if (axi_arready) begin
                        if (RESPONSE_VALID_REGISTERED == 0 && axi_rvalid) begin
                            if (axi_rid != READ_ID || axi_rlast) begin
                                fault <= 1'b1;
                                state <= S_FAULT;
                            end else begin
                                receive_index <= 4'd1;
                                state <= S_R;
                            end
                        end else begin
                            receive_index <= 4'd0;
                            state <= S_R;
                        end
                    end
                    S_R: if (axi_rvalid) begin
                        if (axi_rid != READ_ID ||
                            axi_rlast != (receive_index == 4'd15)) begin
                            fault <= 1'b1;
                            state <= S_FAULT;
                        end else if (receive_index == 4'd15) begin
                            pixel_index <= 8'd0;
                            state <= S_DRAIN;
                        end else
                            receive_index <= receive_index + 1'b1;
                    end
                    S_DRAIN: if (pixel_fire) begin
                        if (pixel_index == 8'd255) begin
                            if (burst_index == FRAME_BURSTS - 1) begin
                                frame_done <= 1'b1;
                                prefetch_state <= PF_IDLE;
                                state <= S_IDLE;
                            end else if (PREFETCH_BURSTS != 0) begin
                                if (prefetch_state == PF_READY) begin
                                    current_bank <= ~current_bank;
                                    burst_index <= burst_index + 1'b1;
                                    pixel_index <= 8'd0;
                                    prefetch_state <= PF_IDLE;
                                    state <= S_DRAIN;
                                end else
                                    state <= S_WAIT_PREFETCH;
                            end else begin
                                burst_index <= burst_index + 1'b1;
                                state <= S_AR;
                            end
                        end else
                            pixel_index <= pixel_index + 1'b1;
                    end
                    S_WAIT_PREFETCH: if (prefetch_state == PF_READY) begin
                        current_bank <= ~current_bank;
                        burst_index <= burst_index + 1'b1;
                        pixel_index <= 8'd0;
                        prefetch_state <= PF_IDLE;
                        state <= S_DRAIN;
                    end
                    default: begin
                        fault <= 1'b1;
                        state <= S_FAULT;
                        prefetch_state <= PF_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
