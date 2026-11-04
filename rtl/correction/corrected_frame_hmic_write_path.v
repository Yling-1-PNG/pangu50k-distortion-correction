// DDR-clock-domain corrected RGB565 producer to one HMIC write master.
// frame_base comes from a reserved corrected-frame bank and must remain stable
// at frame_begin. transfer_done is only a write-transfer milestone: the owner
// must wait for a separate HMIC readback visibility proof before publishing.
module corrected_frame_hmic_write_path #(
    parameter integer H_PIXELS = 1280,
    parameter integer V_LINES = 720
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         frame_begin,
    input  wire [27:0]  frame_base,
    output wire         frame_ready,
    input  wire         pixel_valid,
    output wire         pixel_ready,
    input  wire [15:0]  pixel_data,
    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awuser_id,
    output wire [3:0]   axi_awlen,
    output wire         axi_awuser_ap,
    output wire         axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    input  wire         axi_wready,
    input  wire         axi_wusero_last,
    output wire         transfer_done,
    output wire         fault
);
    localparam integer FRAME_PIXELS = H_PIXELS * V_LINES;
    localparam integer FRAME_BURSTS = FRAME_PIXELS / 256;
    localparam integer FRAME_SHAPE_OK = FRAME_PIXELS >= 256 &&
                                        FRAME_PIXELS % 256 == 0;
    wire packer_ready, writer_ready, packer_pixel_ready;
    wire beat_valid, beat_ready, packed_done;
    wire [255:0] beat_data;
    wire packer_fault, writer_fault;
    reg start_fault;
    wire begin_accepted = frame_begin && frame_ready;

    assign frame_ready = FRAME_SHAPE_OK && packer_ready && writer_ready && !fault;
    assign pixel_ready = packer_pixel_ready && !fault;
    assign fault = packer_fault | writer_fault | start_fault;

    corrected_rgb565_beat_packer #(.FRAME_PIXELS(FRAME_PIXELS)) packer (
        .clk(clk), .rst_n(rst_n), .frame_begin(begin_accepted),
        .frame_ready(packer_ready), .pixel_valid(pixel_valid),
        .pixel_ready(packer_pixel_ready), .pixel_data(pixel_data),
        .beat_valid(beat_valid), .beat_ready(beat_ready),
        .beat_data(beat_data), .frame_done(packed_done),
        .fault(packer_fault)
    );

    controlled_frame_write_port #(.FRAME_BURSTS(FRAME_BURSTS)) writer (
        .clk(clk), .rst_n(rst_n), .frame_begin(begin_accepted),
        .frame_base(frame_base), .frame_done(packed_done), .abort(1'b0),
        .frame_ready(writer_ready), .beat_valid(beat_valid),
        .beat_ready(beat_ready), .beat_data(beat_data),
        .axi_awaddr(axi_awaddr), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awuser_ap(axi_awuser_ap),
        .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb),
        .axi_wready(axi_wready), .axi_wusero_last(axi_wusero_last),
        .transfer_done(transfer_done), .transfer_aborted(),
        .fault(writer_fault)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            start_fault <= 1'b0;
        else if (frame_begin && !frame_ready)
            start_fault <= 1'b1;
    end
endmodule
