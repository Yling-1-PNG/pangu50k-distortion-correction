// One outstanding, one-beat read on the HMIC_S simplified AXI interface.
// req_addr is already in the controller's address units; no pixel-to-DDR
// conversion, cache, frame synchronization, or clock crossing is done here.
// Start requests only after DDR init; reset/clock sequencing is external.
// The IP has no RREADY: the consumer must capture the one-cycle rsp_valid pulse.
module ddr_single_beat_reader #(
    parameter ADDR_WIDTH = 28
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    req_valid,
    output wire                    req_ready,
    input  wire [ADDR_WIDTH-1:0]   req_addr,
    output reg                     rsp_valid,
    output reg  [255:0]            rsp_data,
    output reg                     rsp_error,
    output wire [ADDR_WIDTH-1:0]   axi_araddr,
    output wire                    axi_aruser_ap,
    output wire [3:0]              axi_aruser_id,
    output wire [3:0]              axi_arlen,
    output wire                    axi_arvalid,
    input  wire                    axi_arready,
    input  wire [255:0]            axi_rdata,
    input  wire [3:0]              axi_rid,
    input  wire                    axi_rlast,
    input  wire                    axi_rvalid
);
    localparam IDLE = 2'd0, ISSUE = 2'd1, WAIT_DATA = 2'd2, FAULT = 2'd3;
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] held_addr;

    assign req_ready = rst_n && (state == IDLE);
    assign axi_araddr = held_addr;
    assign axi_aruser_ap = 1'b0;
    assign axi_aruser_id = 4'd0;
    assign axi_arlen = 4'd0; // One 256-bit beat: ARLEN + 1.
    assign axi_arvalid = (state == ISSUE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            held_addr <= {ADDR_WIDTH{1'b0}};
            rsp_valid <= 1'b0;
            rsp_data <= 256'd0;
            rsp_error <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;
            case (state)
                IDLE: if (req_valid) begin
                    held_addr <= req_addr;
                    state <= ISSUE;
                end
                ISSUE: if (axi_arready) begin
                    if (axi_rvalid) begin
                        rsp_valid <= 1'b1;
                        rsp_data <= axi_rdata;
                        rsp_error <= (axi_rid != 4'd0) || !axi_rlast;
                        state <= ((axi_rid != 4'd0) || !axi_rlast) ? FAULT : IDLE;
                    end else begin
                        state <= WAIT_DATA;
                    end
                end
                WAIT_DATA: if (axi_rvalid) begin
                    rsp_valid <= 1'b1;
                    rsp_data <= axi_rdata;
                    rsp_error <= (axi_rid != 4'd0) || !axi_rlast;
                    state <= ((axi_rid != 4'd0) || !axi_rlast) ? FAULT : IDLE;
                end
                default: state <= FAULT; // Protocol fault requires reset.
            endcase
        end
    end
endmodule
