// Connect one lookup/cycle cache to a tagged HMIC read port. Cache misses
// enter a 16-entry FIFO; accepted AR IDs map back to cache fill tokens.
// All ports use the same HMIC clock. This is not a pixel reorder buffer,
// camera write arbiter, or guarantee of the IP's outstanding-read capacity.
module beat_cache_read_bridge #(
    parameter READ_DEPTH = 8 // 1..16; must be validated with the real HMIC IP.
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    output wire         clear_ready,
    input  wire [27:0]  frame_base_ctrl_addr,
    input  wire         lookup_valid,
    output wire         lookup_ready,
    input  wire [17:0]  lookup_beat,
    output wire         result_valid,
    output wire         result_hit,
    output wire         result_pending,
    output wire         result_miss,
    output wire [17:0]  result_beat,
    output wire [8:0]   result_token,
    output wire [255:0] result_data,
    output wire         filled_valid,
    output wire [8:0]   filled_token,
    output wire [255:0] filled_data,
    output wire         fault,
    output wire [27:0]  axi_araddr,
    output wire         axi_aruser_ap,
    output wire [3:0]   axi_aruser_id,
    output wire [3:0]   axi_arlen,
    output wire         axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire [3:0]   axi_rid,
    input  wire         axi_rlast,
    input  wire         axi_rvalid
);
    reg [26:0] miss_fifo [0:15]; // {beat[17:0], cache_token[8:0]}.
    reg [3:0] wr_ptr, rd_ptr;
    reg [4:0] fifo_count;
    reg [1:0] lookup_in_pipe; // Reserve room across the cache's two-cycle result.
    // Two-entry request elastic buffer. Its ready signal depends only on
    // local occupancy, not the cache's same-cycle ready response.
    reg       req_valid;
    reg [17:0] req_beat;
    reg       req_tail_valid;
    reg [17:0] req_tail_beat;
    reg [8:0]  tag_token [0:15];
    reg [17:0] tag_beat [0:15];
    reg [15:0] tag_live;
    reg        fill_valid_q;
    reg [8:0]  fill_token_q;
    reg [17:0] fill_beat_q;
    reg [255:0] fill_data_q;
    reg bridge_fault;

    wire cache_ready, cache_clear_ready, cache_fault;
    wire reader_req_ready, reader_rsp_valid, reader_rsp_error, reader_fault;
    wire [3:0] reader_req_tag, reader_rsp_tag;
    wire [255:0] reader_rsp_data;
    wire [17:0] fifo_beat = miss_fifo[rd_ptr][26:9];
    wire [8:0] fifo_token = miss_fifo[rd_ptr][8:0];
    wire [27:0] reader_req_addr;
    wire reader_addr_valid;
    wire fifo_nonempty = fifo_count != 5'd0;
    wire [2:0] pending_results = {2'b00, req_valid} +
                                 {2'b00, req_tail_valid} +
                                 {2'b00, lookup_in_pipe[0]} +
                                 {2'b00, lookup_in_pipe[1]};
    wire room_for_result = {1'b0, fifo_count} + pending_results < 6'd16;
    // A request already accepted from the queue must drain even after clear
    // is asserted; cache clear waits until this request has been consumed.
    wire cache_lookup_valid = req_valid && !fault;
    wire cache_lookup_fire = cache_lookup_valid && cache_ready;
    wire upstream_fire = lookup_valid && lookup_ready;
    wire enqueue = result_valid && result_miss;
    // A completed response frees its reader ID before the bridge retires its
    // mapping. The one-cycle bubble prevents clearing a newly reused ID.
    wire reader_req_valid = fifo_nonempty && reader_addr_valid &&
                            !fault && !reader_rsp_valid;
    wire dequeue = reader_req_valid && reader_req_ready;
    wire fill_fire = reader_rsp_valid && !reader_rsp_error &&
                     tag_live[reader_rsp_tag] && !fault;
    wire clear_cache = clear && clear_ready;

    assign fault = bridge_fault || cache_fault || reader_fault;
    // Deliberately avoid the cache_ready -> upstream-ready combinational
    // feedback. A full two-entry buffer applies backpressure for one cycle
    // after a dequeue rather than routing cache_ready through the queue scan.
    assign lookup_ready = !clear && !fault && room_for_result &&
                          !req_tail_valid;
    assign clear_ready = cache_clear_ready && !fifo_nonempty &&
                         !req_valid && !req_tail_valid &&
                         lookup_in_pipe == 2'b00 &&
                         tag_live == 16'd0 && !fill_valid_q && !fault;
    assign filled_valid = fill_valid_q;
    assign filled_token = fill_token_q;
    assign filled_data = fill_data_q;

    // A live reader ID maps only to a previously accepted cache miss, and
    // clear waits for every live ID/fill to drain. Trust that ownership here
    // instead of rereading pending/tag metadata on the data-RAM write path.
    beat_cache_4way #(
        .CHECK_FILL_TAG(0), .CHECK_FILL_PENDING(0),
        .UPDATE_PLRU_ON_HIT(0)
    ) cache (
        .clk(clk), .rst_n(rst_n), .clear(clear_cache),
        .clear_ready(cache_clear_ready),
        .lookup_valid(cache_lookup_valid), .lookup_ready(cache_ready),
        .lookup_beat(req_beat),
        .result_valid(result_valid),
        .result_hit(result_hit), .result_pending(result_pending),
        .result_miss(result_miss), .result_beat(result_beat),
        .result_token(result_token), .result_data(result_data),
        .fill_valid(fill_fire),
        .fill_token(tag_token[reader_rsp_tag]),
        .fill_beat(tag_beat[reader_rsp_tag]), .fill_data(reader_rsp_data),
        .fault(cache_fault)
    );
    hmic_beat_address address (
        .valid_in(fifo_nonempty), .frame_base_ctrl_addr(frame_base_ctrl_addr),
        .beat_index(fifo_beat), .valid_out(reader_addr_valid),
        .ctrl_addr(reader_req_addr)
    );
    ddr_tagged_read_queue #(.DEPTH(READ_DEPTH)) reader (
        .clk(clk), .rst_n(rst_n), .req_valid(reader_req_valid),
        .req_ready(reader_req_ready), .req_addr(reader_req_addr),
        .req_tag(reader_req_tag), .rsp_valid(reader_rsp_valid),
        .rsp_tag(reader_rsp_tag), .rsp_data(reader_rsp_data),
        .rsp_error(reader_rsp_error), .fault(reader_fault),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap),
        .axi_aruser_id(axi_aruser_id), .axi_arlen(axi_arlen),
        .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 4'd0;
            rd_ptr <= 4'd0;
            fifo_count <= 5'd0;
            lookup_in_pipe <= 2'b00;
            req_valid <= 1'b0;
            req_beat <= 18'd0;
            req_tail_valid <= 1'b0;
            req_tail_beat <= 18'd0;
            tag_live <= 16'd0;
            fill_valid_q <= 1'b0;
            fill_token_q <= 9'd0;
            fill_beat_q <= 18'd0;
            fill_data_q <= 256'd0;
            bridge_fault <= 1'b0;
        end else begin
            // Break the response-tag mux and cache fill-validation path at
            // the bridge boundary. The response ID is released immediately;
            // its cache side effect commits on the following clock.
            fill_valid_q <= fill_fire;
            if (fill_fire) begin
                fill_token_q <= tag_token[reader_rsp_tag];
                fill_beat_q <= tag_beat[reader_rsp_tag];
                fill_data_q <= reader_rsp_data;
            end
            lookup_in_pipe <= {lookup_in_pipe[0], cache_lookup_fire};
            if (cache_lookup_fire) begin
                if (req_tail_valid) begin
                    req_valid <= 1'b1;
                    req_beat <= req_tail_beat;
                    if (upstream_fire) begin
                        req_tail_valid <= 1'b1;
                        req_tail_beat <= lookup_beat;
                    end else begin
                        req_tail_valid <= 1'b0;
                    end
                end else if (upstream_fire) begin
                    req_valid <= 1'b1;
                    req_beat <= lookup_beat;
                end else begin
                    req_valid <= 1'b0;
                end
            end else if (upstream_fire) begin
                if (!req_valid) begin
                    req_valid <= 1'b1;
                    req_beat <= lookup_beat;
                end else begin
                    req_tail_valid <= 1'b1;
                    req_tail_beat <= lookup_beat;
                end
            end
            if (enqueue) begin
                miss_fifo[wr_ptr] <= {result_beat, result_token};
                wr_ptr <= wr_ptr + 4'd1;
            end
            if (dequeue) begin
                tag_live[reader_req_tag] <= 1'b1;
                tag_token[reader_req_tag] <= fifo_token;
                tag_beat[reader_req_tag] <= fifo_beat;
                rd_ptr <= rd_ptr + 4'd1;
            end
            case ({enqueue, dequeue})
                2'b10: fifo_count <= fifo_count + 5'd1;
                2'b01: fifo_count <= fifo_count - 5'd1;
                default: fifo_count <= fifo_count;
            endcase
            if (reader_rsp_valid) begin
                if (reader_rsp_error || !tag_live[reader_rsp_tag])
                    bridge_fault <= 1'b1;
                tag_live[reader_rsp_tag] <= 1'b0;
            end
            if (fifo_nonempty && !reader_addr_valid)
                bridge_fault <= 1'b1;
        end
    end
endmodule
