// Two HMIC-S write masters share one AW/W port. Ownership is held from one
// accepted 16-beat AW until its final WREADY/WLAST beat. The HMIC interface
// has no WVALID or B response, so neither master may be interleaved mid-burst.
// Round-robin preference changes only after a complete burst.
module hmic_two_writer_burst_arbiter (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [27:0]  m0_awaddr,
    input  wire [3:0]   m0_awid,
    input  wire [3:0]   m0_awlen,
    input  wire         m0_awap,
    input  wire         m0_awvalid,
    output wire         m0_awready,
    input  wire [255:0] m0_wdata,
    input  wire [31:0]  m0_wstrb,
    output wire         m0_wready,
    output wire         m0_wlast,
    input  wire [27:0]  m1_awaddr,
    input  wire [3:0]   m1_awid,
    input  wire [3:0]   m1_awlen,
    input  wire         m1_awap,
    input  wire         m1_awvalid,
    output wire         m1_awready,
    input  wire [255:0] m1_wdata,
    input  wire [31:0]  m1_wstrb,
    output wire         m1_wready,
    output wire         m1_wlast,
    output wire [27:0]  s_awaddr,
    output wire [3:0]   s_awid,
    output wire [3:0]   s_awlen,
    output wire         s_awap,
    output wire         s_awvalid,
    input  wire         s_awready,
    output wire [255:0] s_wdata,
    output wire [31:0]  s_wstrb,
    input  wire         s_wready,
    input  wire         s_wlast,
    output reg          fault
);
    localparam [1:0] S_AW = 0, S_W = 1, S_FAULT = 2;
    reg [1:0] state;
    reg owner, prefer1;
    // Keep the offered AW owner through downstream backpressure, before
    // burst ownership starts. UG022003 p31 forbids changing AW fields while
    // AWVALID is waiting for AWREADY.
    reg address_locked, address_owner;
    reg [3:0] beat_index;
    wire preferred = m0_awvalid && m1_awvalid ? prefer1 : m1_awvalid;
    wire selected = address_locked ? address_owner : preferred;
    wire selected_valid = selected ? m1_awvalid : m0_awvalid;
    wire aw_fire = s_awvalid && s_awready;
    wire w_fire = state == S_W && s_wready;
    wire [31:0] owned_wstrb = owner ? m1_wstrb : m0_wstrb;

    assign s_awaddr = selected ? m1_awaddr : m0_awaddr;
    assign s_awid = selected ? m1_awid : m0_awid;
    assign s_awlen = selected ? m1_awlen : m0_awlen;
    assign s_awap = selected ? m1_awap : m0_awap;
    assign s_awvalid = state == S_AW && !fault && selected_valid;
    assign m0_awready = s_awvalid && !selected && s_awready;
    assign m1_awready = s_awvalid && selected && s_awready;
    assign s_wdata = state == S_W ? (owner ? m1_wdata : m0_wdata) : 256'd0;
    assign s_wstrb = state == S_W ? owned_wstrb : 32'd0;
    assign m0_wready = state == S_W && !owner && !fault && s_wready;
    assign m1_wready = state == S_W && owner && !fault && s_wready;
    assign m0_wlast = state == S_W && !owner && !fault && s_wlast;
    assign m1_wlast = state == S_W && owner && !fault && s_wlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_AW;
            owner <= 1'b0;
            prefer1 <= 1'b0;
            address_locked <= 1'b0;
            address_owner <= 1'b0;
            beat_index <= 4'd0;
            fault <= 1'b0;
        end else if (fault || state == S_FAULT) begin
            state <= S_FAULT;
        end else if (state == S_AW) begin
            if (s_awvalid) begin
                address_locked <= !s_awready;
                if (!s_awready)
                    address_owner <= selected;
            end
            if (s_wready || s_wlast ||
                (aw_fire && s_awlen != 4'd15)) begin
                fault <= 1'b1;
                state <= S_FAULT;
            end else if (aw_fire) begin
                owner <= selected;
                beat_index <= 4'd0;
                state <= S_W;
            end
        end else if (state == S_W) begin
            if ((s_wlast && !s_wready) ||
                (w_fire && (s_wlast != (beat_index == 4'd15) ||
                            owned_wstrb != 32'hffff_ffff))) begin
                fault <= 1'b1;
                state <= S_FAULT;
            end else if (w_fire) begin
                if (beat_index == 4'd15) begin
                    prefer1 <= !owner;
                    state <= S_AW;
                end else
                    beat_index <= beat_index + 1'b1;
            end
        end
    end
endmodule
