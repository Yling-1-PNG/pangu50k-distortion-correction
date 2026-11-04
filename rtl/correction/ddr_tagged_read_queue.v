// Tagged single-beat HMIC read front end. One held AR, up to DEPTH in-flight
// IDs. The consumer must capture each rsp_valid pulse (the IP has no RREADY).
// This is not a beat cache, write arbiter, frame synchronizer, or proof that
// a particular HMIC configuration accepts DEPTH outstanding transactions.
module ddr_tagged_read_queue #(
    parameter ADDR_WIDTH = 28,
    parameter DEPTH = 8  // 1..16, because HMIC ARID/RID are four bits.
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  req_valid,
    output wire                  req_ready,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    output wire [3:0]            req_tag,
    output reg                   rsp_valid,
    output reg  [3:0]            rsp_tag,
    output reg  [255:0]          rsp_data,
    output reg                   rsp_error,
    output reg                   fault,
    output wire [ADDR_WIDTH-1:0] axi_araddr,
    output wire                  axi_aruser_ap,
    output wire [3:0]            axi_aruser_id,
    output wire [3:0]            axi_arlen,
    output wire                  axi_arvalid,
    input  wire                  axi_arready,
    input  wire [255:0]          axi_rdata,
    input  wire [3:0]            axi_rid,
    input  wire                  axi_rlast,
    input  wire                  axi_rvalid
);
    reg [DEPTH-1:0] busy;
    reg [DEPTH-1:0] issued;
    reg             ar_pending;
    reg [ADDR_WIDTH-1:0] held_addr;
    reg [3:0]            held_tag;
    reg [3:0]            free_tag;
    reg                  free_found;
    integer i;

    always @* begin
        free_found = 1'b0;
        free_tag = 4'd0;
        for (i = 0; i < DEPTH; i = i + 1)
            if (!busy[i] && !free_found) begin
                free_found = 1'b1;
                free_tag = i[3:0];
            end
    end

    assign req_ready = rst_n && !fault && !ar_pending && free_found;
    assign req_tag = free_tag;
    assign axi_araddr = held_addr;
    assign axi_aruser_ap = 1'b0;
    assign axi_aruser_id = held_tag;
    assign axi_arlen = 4'd0;
    assign axi_arvalid = rst_n && !fault && ar_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= {DEPTH{1'b0}};
            issued <= {DEPTH{1'b0}};
            ar_pending <= 1'b0;
            held_addr <= {ADDR_WIDTH{1'b0}};
            held_tag <= 4'd0;
            rsp_valid <= 1'b0;
            rsp_tag <= 4'd0;
            rsp_data <= 256'd0;
            rsp_error <= 1'b0;
            fault <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;
            if (req_valid && req_ready) begin
                busy[free_tag] <= 1'b1;
                held_addr <= req_addr;
                held_tag <= free_tag;
                ar_pending <= 1'b1;
            end
            if (axi_arvalid && axi_arready) begin
                ar_pending <= 1'b0;
                issued[held_tag] <= 1'b1;
            end
            if (axi_rvalid && !fault) begin
                if (axi_rid >= DEPTH || !busy[axi_rid] ||
                    !(issued[axi_rid] ||
                      (axi_arvalid && axi_arready && axi_rid == held_tag))) begin
                    fault <= 1'b1; // Unknown or not-yet-issued response.
                end else begin
                    rsp_valid <= 1'b1;
                    rsp_tag <= axi_rid;
                    rsp_data <= axi_rdata;
                    rsp_error <= !axi_rlast;
                    busy[axi_rid] <= 1'b0;
                    issued[axi_rid] <= 1'b0;
                    if (!axi_rlast)
                        fault <= 1'b1;
                end
            end
        end
    end
endmodule
