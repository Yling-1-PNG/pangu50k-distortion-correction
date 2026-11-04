// AR arbitration for the existing random-beat correction reader and the
// sequential corrected-frame display reader. HMIC-S has no RREADY. Responses
// are demultiplexed by disjoint IDs, so random reads and display bursts may
// be outstanding simultaneously. The caller must reserve DISPLAY_ID for m1
// and FENCE_ID for the outer visibility fence; m0 uses only IDs 0..13.
module hmic_two_reader_id_arbiter #(
    parameter [3:0] DISPLAY_ID = 4'he,
    parameter [3:0] FENCE_ID = 4'hf
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [27:0]  m0_araddr,
    input  wire         m0_arap,
    input  wire [3:0]   m0_arid,
    input  wire [3:0]   m0_arlen,
    input  wire         m0_arvalid,
    output wire         m0_arready,
    output wire [255:0] m0_rdata,
    output wire [3:0]   m0_rid,
    output wire         m0_rlast,
    output wire         m0_rvalid,
    input  wire [27:0]  m1_araddr,
    input  wire         m1_arap,
    input  wire [3:0]   m1_arid,
    input  wire [3:0]   m1_arlen,
    input  wire         m1_arvalid,
    output wire         m1_arready,
    output wire [255:0] m1_rdata,
    output wire [3:0]   m1_rid,
    output wire         m1_rlast,
    output wire         m1_rvalid,
    output wire [27:0]  s_araddr,
    output wire         s_arap,
    output wire [3:0]   s_arid,
    output wire [3:0]   s_arlen,
    output wire         s_arvalid,
    input  wire         s_arready,
    input  wire [255:0] s_rdata,
    input  wire [3:0]   s_rid,
    input  wire         s_rlast,
    input  wire         s_rvalid,
    output reg          fault
);
    // The display reader must drain one full frame within one HDMI period.
    // Alternating AR grants with the correction reader halves its effective
    // burst bandwidth and makes the video gate miss the next VS boundary.
    // Let display traffic win when it has a request; correction traffic still
    // uses every cycle in which the display reader is between bursts.
    reg display_inflight;
    // UG022003 p31 requires the offered address/AP/ID/LEN to remain stable
    // until ARVALID && ARREADY. A later display request cannot preempt an
    // already offered, stalled Brown request.
    reg address_locked;
    reg address_owner;
    wire selected = address_locked ? address_owner : m1_arvalid;
    wire ar_fire = s_arvalid && s_arready;
    wire display_fire = ar_fire && selected;
    wire display_response = s_rvalid && s_rid == DISPLAY_ID;
    wire random_response = s_rvalid && s_rid != DISPLAY_ID &&
                           s_rid != FENCE_ID;

    assign s_araddr = selected ? m1_araddr : m0_araddr;
    assign s_arap = selected ? m1_arap : m0_arap;
    assign s_arid = selected ? m1_arid : m0_arid;
    assign s_arlen = selected ? m1_arlen : m0_arlen;
    // Once a display burst is accepted, keep the HMIC request channel free
    // until its tagged response burst reaches RLAST. This preserves the
    // display burst's service window without starving Brown during the
    // display reader's 256-pixel drain interval between bursts.
    assign s_arvalid = !fault && (selected ? m1_arvalid :
                                  (m0_arvalid && !display_inflight));
    assign m0_arready = s_arvalid && !selected &&
                        !display_inflight && s_arready;
    assign m1_arready = s_arvalid && selected && s_arready;
    assign m0_rdata = s_rdata;
    assign m0_rid = s_rid;
    assign m0_rlast = s_rlast;
    assign m0_rvalid = !fault && random_response;
    assign m1_rdata = s_rdata;
    assign m1_rid = s_rid;
    assign m1_rlast = s_rlast;
    assign m1_rvalid = !fault && display_response;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            display_inflight <= 1'b0;
            address_locked <= 1'b0;
            address_owner <= 1'b0;
            fault <= 1'b0;
        end else if (!fault) begin
            if (s_arvalid) begin
                address_locked <= !s_arready;
                if (!s_arready)
                    address_owner <= selected;
            end
            if ((ar_fire && (selected ?
                             (m1_arid != DISPLAY_ID || display_inflight) :
                             (m0_arid == DISPLAY_ID || m0_arid == FENCE_ID))) ||
                (s_rvalid && s_rid == FENCE_ID) ||
                (display_response && !(display_inflight || display_fire))) begin
                fault <= 1'b1;
            end else begin
                if (ar_fire) begin
                    if (selected)
                        display_inflight <= 1'b1;
                end
                if (display_response && s_rlast)
                    display_inflight <= 1'b0;
            end
        end
    end
endmodule
