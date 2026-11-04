// One lookup per clock, 512 x 256-bit RGB565 source-beat store (128 sets x 4).
// Misses reserve a slot; the caller sends one DDR request and later fills that
// token. A lookup of a reserved beat returns pending, not another miss.
// Clear must be held across a frame swap until clear_ready; no lookups then.
// This unit contains no HMIC reader, pixel waiter, or camera write arbitration.
module beat_cache_4way #(
    // Standalone use validates token/tag against stored cache metadata.
    // The production bridge may disable this redundant check because its
    // response-ID table preserves the original {token, beat} pair.
    parameter integer CHECK_FILL_TAG = 1,
    // The production bridge may also trust its live response-ID mapping and
    // clear fence instead of rereading the pending bitmap on the RAM WEA path.
    parameter integer CHECK_FILL_PENDING = 1,
    // Production Brown can update replacement state on allocations only;
    // standalone cache tests retain the original hit-touch behavior.
    parameter integer UPDATE_PLRU_ON_HIT = 1
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,
    output wire         clear_ready,
    input  wire         lookup_valid,
    output wire         lookup_ready,
    input  wire [17:0]  lookup_beat,
    output reg          result_valid,
    output reg          result_hit,
    output reg          result_pending,
    output reg          result_miss,
    output reg  [17:0]  result_beat,
    output reg  [8:0]   result_token,
    output reg  [255:0] result_data,
    input  wire         fill_valid,
    input  wire [8:0]   fill_token,
    input  wire [17:0]  fill_beat,
    input  wire [255:0] fill_data,
    output reg          fault
);
    reg [255:0] data_mem [0:511];
    // Keep metadata physically banked by way. The former flat 512-entry
    // variable-index arrays made set-address bits drive a large decode cone.
    reg [10:0]  tag_way0 [0:127];
    reg [10:0]  tag_way1 [0:127];
    reg [10:0]  tag_way2 [0:127];
    reg [10:0]  tag_way3 [0:127];
    reg [2:0] plru [0:127]; // Four-way tree pseudo-LRU bits, one write/set.
    reg [127:0] valid_way0, valid_way1, valid_way2, valid_way3;
    reg [127:0] pending_way0, pending_way1, pending_way2, pending_way3;
    // Delay the selected pending-bit write by one cycle. The selected set/way is
    // forwarded into lookup/fill checks while the reservation is in flight.
    reg         reserve_valid_q;
    reg [3:0]   reserve_way_onehot_q;
    // Store set bit 4 with inverted polarity so the reservation-to-metadata-RAM
    // address path does not remain a zero-logic FF-to-WADM connection.
    reg [6:0]   reserve_set_q_encoded;
    wire [6:0]  reserve_set_q = {
        reserve_set_q_encoded[6:5], ~reserve_set_q_encoded[4],
        reserve_set_q_encoded[3:0]
    };
    reg [10:0]  reserve_tag_q;
    reg [9:0]   pending_count;
    // Split tag/way selection from the wide cache-data read. The first cycle
    // captures the selected slot; the next cycle reads the 256-bit word.
    reg         lookup_meta_valid;
    reg         lookup_meta_hit, lookup_meta_pending, lookup_meta_miss;
    reg         lookup_meta_data_valid;
    reg [17:0]  lookup_meta_beat;
    reg [8:0]   lookup_meta_token, lookup_meta_slot;
    // Capture fill payloads at the cache boundary. Keeping this register next
    // to the data RAM lets placement split the long HMIC-to-cache route across
    // a pipeline stage instead of routing the bridge register straight into
    // the distributed cache memory.
    reg         fill_valid_q;
    reg [8:0]   fill_token_q;
    reg [17:0]  fill_beat_q;
    reg [255:0] fill_data_q;

    wire [6:0] set_index = lookup_beat[6:0];
    wire [10:0] tag = lookup_beat[17:7];
    wire [2:0] plru_word = plru[set_index];
    wire [3:0] way_valid = {valid_way3[set_index], valid_way2[set_index],
                            valid_way1[set_index], valid_way0[set_index]};
    wire [3:0] way_pending = {pending_way3[set_index], pending_way2[set_index],
                              pending_way1[set_index], pending_way0[set_index]};
    wire [3:0] reserve_way_for_lookup =
        reserve_valid_q && reserve_set_q == set_index ?
        reserve_way_onehot_q : 4'b0000;
    wire [3:0] way_valid_effective = way_valid | reserve_way_for_lookup;
    wire [3:0] way_pending_effective = way_pending | reserve_way_for_lookup;
    wire [3:0] victim_available = ~way_pending_effective;
    wire [3:0] way_hit = {
        reserve_way_for_lookup[3] ? reserve_tag_q == tag :
            way_valid[3] && tag_way3[set_index] == tag,
        reserve_way_for_lookup[2] ? reserve_tag_q == tag :
            way_valid[2] && tag_way2[set_index] == tag,
        reserve_way_for_lookup[1] ? reserve_tag_q == tag :
            way_valid[1] && tag_way1[set_index] == tag,
        reserve_way_for_lookup[0] ? reserve_tag_q == tag :
            way_valid[0] && tag_way0[set_index] == tag
    };
    reg [1:0] selected_way;
    reg [3:0] selected_way_onehot;
    reg [3:0] hit_select_onehot;
    reg [3:0] invalid_select_onehot;
    // Avoid re-encoding the priority hit to a binary way and decoding it back
    // through a variable-index pending mux on the lookup result path.
    wire selected_pending = |(hit_select_onehot & way_pending_effective);
    reg found, can_allocate, has_invalid;
    reg [3:0] victim_select;

    always @* begin
        found = |way_hit;
        has_invalid = !( &way_valid_effective );
        can_allocate = 1'b0;
        selected_way = 2'd0;
        selected_way_onehot = 4'b0001;
        hit_select_onehot = 4'b0000;
        invalid_select_onehot = 4'b0000;
        victim_select = 4'b0000;
        hit_select_onehot[0] = way_hit[0] && !(|way_hit[3:1]);
        hit_select_onehot[1] = way_hit[1] && !(|way_hit[3:2]);
        hit_select_onehot[2] = way_hit[2] && !way_hit[3];
        hit_select_onehot[3] = way_hit[3];
        invalid_select_onehot[0] = !way_valid_effective[0];
        invalid_select_onehot[1] = way_valid_effective[0] && !way_valid_effective[1];
        invalid_select_onehot[2] = way_valid_effective[0] && way_valid_effective[1] &&
                                   !way_valid_effective[2];
        invalid_select_onehot[3] = way_valid_effective[0] && way_valid_effective[1] &&
                                   way_valid_effective[2];
        // Match the prior loop's highest-way-wins behavior if metadata is
        // corrupted and duplicate tags exist.
        if (way_hit[0]) selected_way = 2'd0;
        if (way_hit[1]) selected_way = 2'd1;
        if (way_hit[2]) selected_way = 2'd2;
        if (way_hit[3]) selected_way = 2'd3;
        if (found) begin
            selected_way_onehot = hit_select_onehot;
        end else begin
            if (has_invalid) begin
                can_allocate = 1'b1;
                selected_way_onehot = invalid_select_onehot;
                if (!way_valid[0]) selected_way = 2'd0;
                else if (!way_valid[1]) selected_way = 2'd1;
                else if (!way_valid[2]) selected_way = 2'd2;
                else selected_way = 2'd3;
            end else begin
                can_allocate = |victim_available;
                // Tree-PLRU preferences are root (left/right), left pair,
                // and right pair. If the preferred branch contains only
                // pending ways, fall back to any available branch/way.
                if (victim_available[1:0] != 2'b00 &&
                    victim_available[3:2] != 2'b00) begin
                    if (plru_word[0] == 1'b0) begin
                        if (&victim_available[1:0])
                            victim_select[plru_word[1] ? 1 : 0] = 1'b1;
                        else
                            victim_select[1:0] = victim_available[1:0];
                    end else begin
                        if (&victim_available[3:2])
                            victim_select[plru_word[2] ? 3 : 2] = 1'b1;
                        else
                            victim_select[3:2] = victim_available[3:2];
                    end
                end else if (victim_available[1:0] != 2'b00) begin
                    if (&victim_available[1:0])
                        victim_select[plru_word[1] ? 1 : 0] = 1'b1;
                    else
                        victim_select[1:0] = victim_available[1:0];
                end else if (victim_available[3:2] != 2'b00) begin
                    if (&victim_available[3:2])
                        victim_select[plru_word[2] ? 3 : 2] = 1'b1;
                    else
                        victim_select[3:2] = victim_available[3:2];
                end
                selected_way_onehot = victim_select;
                if (victim_select[0]) selected_way = 2'd0;
                if (victim_select[1]) selected_way = 2'd1;
                if (victim_select[2]) selected_way = 2'd2;
                if (victim_select[3]) selected_way = 2'd3;
            end
        end
    end

    reg [2:0] next_plru_word;
    always @* begin
        next_plru_word = plru_word;
        if (selected_way_onehot[0]) begin
            next_plru_word[0] = 1'b1;
            next_plru_word[1] = 1'b1;
        end else if (selected_way_onehot[1]) begin
            next_plru_word[0] = 1'b1;
            next_plru_word[1] = 1'b0;
        end else if (selected_way_onehot[2]) begin
            next_plru_word[0] = 1'b0;
            next_plru_word[2] = 1'b1;
        end else if (selected_way_onehot[3]) begin
            next_plru_word[0] = 1'b0;
            next_plru_word[2] = 1'b0;
        end
    end

    wire [8:0] selected_slot = {set_index, selected_way};
    wire reserve_matches_fill = reserve_valid_q &&
                                reserve_set_q == fill_token_q[8:2] &&
                                reserve_way_onehot_q[fill_token_q[1:0]];
    reg fill_slot_pending;
    reg [10:0] fill_slot_tag;
    always @* begin
        case (fill_token_q[1:0])
            2'd0: begin
                fill_slot_pending = pending_way0[fill_token_q[8:2]];
                fill_slot_tag = tag_way0[fill_token_q[8:2]];
            end
            2'd1: begin
                fill_slot_pending = pending_way1[fill_token_q[8:2]];
                fill_slot_tag = tag_way1[fill_token_q[8:2]];
            end
            2'd2: begin
                fill_slot_pending = pending_way2[fill_token_q[8:2]];
                fill_slot_tag = tag_way2[fill_token_q[8:2]];
            end
            default: begin
                fill_slot_pending = pending_way3[fill_token_q[8:2]];
                fill_slot_tag = tag_way3[fill_token_q[8:2]];
            end
        endcase
    end
    wire fill_slot_pending_effective = fill_slot_pending || reserve_matches_fill;
    wire [10:0] fill_slot_tag_effective = reserve_matches_fill ?
                                          reserve_tag_q : fill_slot_tag;
    wire lookup_fire = lookup_valid && lookup_ready;
    // For a miss, lookup_ready is equivalent to can_allocate. Keep this
    // reservation event local instead of routing the global ready net into
    // every pending-bit write enable.
    wire miss_fire = lookup_valid && rst_n && !fault && !clear &&
                     !found && can_allocate;
    wire plru_update_fire = lookup_fire &&
                            (miss_fire ||
                             (UPDATE_PLRU_ON_HIT != 0 && found));
    wire fill_tag_matches = (CHECK_FILL_TAG == 0) ||
                            (fill_slot_tag_effective == fill_beat_q[17:7]);
    // Every pending reservation sets valid in the same clock, while fill and
    // clear only remove pending. Thus pending already proves slot validity;
    // rereading the valid bitmap on this path adds a redundant RAM/select cone.
    wire fill_pending_matches = (CHECK_FILL_PENDING == 0) ||
                                fill_slot_pending_effective;
    wire fill_good = fill_valid_q && !fault && fill_pending_matches &&
                     fill_tag_matches &&
                     fill_token_q[8:2] == fill_beat_q[6:0];
    wire fill_hits_selected_way =
        (hit_select_onehot[0] && fill_token_q[1:0] == 2'd0) ||
        (hit_select_onehot[1] && fill_token_q[1:0] == 2'd1) ||
        (hit_select_onehot[2] && fill_token_q[1:0] == 2'd2) ||
        (hit_select_onehot[3] && fill_token_q[1:0] == 2'd3);
    wire bypass_fill = fill_good && (fill_token_q[8:2] == set_index) &&
                       fill_hits_selected_way;
    assign clear_ready = pending_count == 10'd0 && !lookup_meta_valid &&
                         !result_valid;
    assign lookup_ready = rst_n && !fault && !clear && (found || can_allocate);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_way0 <= 128'd0;
            valid_way1 <= 128'd0;
            valid_way2 <= 128'd0;
            valid_way3 <= 128'd0;
            pending_way0 <= 128'd0;
            pending_way1 <= 128'd0;
            pending_way2 <= 128'd0;
            pending_way3 <= 128'd0;
            reserve_valid_q <= 1'b0;
            reserve_way_onehot_q <= 4'd0;
            reserve_set_q_encoded <= 7'b0010000;
            reserve_tag_q <= 11'd0;
            pending_count <= 10'd0;
            lookup_meta_valid <= 1'b0;
            lookup_meta_hit <= 1'b0;
            lookup_meta_pending <= 1'b0;
            lookup_meta_miss <= 1'b0;
            lookup_meta_data_valid <= 1'b0;
            lookup_meta_beat <= 18'd0;
            lookup_meta_token <= 9'd0;
            lookup_meta_slot <= 9'd0;
            result_valid <= 1'b0;
            result_hit <= 1'b0;
            result_pending <= 1'b0;
            result_miss <= 1'b0;
            result_beat <= 18'd0;
            result_token <= 9'd0;
            result_data <= 256'd0;
            fault <= 1'b0;
            fill_valid_q <= 1'b0;
            fill_token_q <= 9'd0;
            fill_beat_q <= 18'd0;
            fill_data_q <= 256'd0;
        end else begin
            fill_valid_q <= fill_valid;
            fill_token_q <= fill_token;
            fill_beat_q <= fill_beat;
            // Invalid cycles are zeroed so this cache-local register bank is
            // not equivalent to the bridge's externally visible fill register.
            fill_data_q <= fill_valid ? fill_data : 256'd0;

            result_valid <= lookup_meta_valid;
            result_hit <= lookup_meta_hit;
            result_pending <= lookup_meta_pending;
            result_miss <= lookup_meta_miss;
            result_beat <= lookup_meta_beat;
            result_token <= lookup_meta_token;
            result_data <= lookup_meta_data_valid ?
                           data_mem[lookup_meta_slot] : 256'd0;

            lookup_meta_valid <= lookup_fire;
            lookup_meta_hit <= lookup_fire && found &&
                               (!selected_pending || bypass_fill);
            lookup_meta_pending <= lookup_fire && found &&
                                   selected_pending && !bypass_fill;
            lookup_meta_miss <= miss_fire;
            lookup_meta_beat <= lookup_beat;
            lookup_meta_token <= selected_slot;
            lookup_meta_slot <= selected_slot;
            lookup_meta_data_valid <= lookup_fire && found &&
                                      (!selected_pending || bypass_fill);
            reserve_valid_q <= miss_fire;
            reserve_way_onehot_q <= miss_fire ? selected_way_onehot : 4'd0;
            reserve_set_q_encoded <= miss_fire ?
                {set_index[6:5], ~set_index[4], set_index[3:0]} : 7'b0010000;
            reserve_tag_q <= miss_fire ? tag : 11'd0;
            if (plru_update_fire) begin
                plru[set_index] <= next_plru_word;
            end
            // Commit tag/valid from the registered reservation. The lookup-
            // side bypass preserves the same-cycle view for following beats.
            if (reserve_valid_q) begin
                if (reserve_way_onehot_q[0]) begin
                    valid_way0[reserve_set_q] <= 1'b1;
                    tag_way0[reserve_set_q] <= reserve_tag_q;
                end
                if (reserve_way_onehot_q[1]) begin
                    valid_way1[reserve_set_q] <= 1'b1;
                    tag_way1[reserve_set_q] <= reserve_tag_q;
                end
                if (reserve_way_onehot_q[2]) begin
                    valid_way2[reserve_set_q] <= 1'b1;
                    tag_way2[reserve_set_q] <= reserve_tag_q;
                end
                if (reserve_way_onehot_q[3]) begin
                    valid_way3[reserve_set_q] <= 1'b1;
                    tag_way3[reserve_set_q] <= reserve_tag_q;
                end
            end
            // Commit the prior cycle's reservation with a short, registered
            // set/way enable. The forwarding above preserves back-to-back
            // same-set and duplicate-beat semantics.
            if (reserve_valid_q) begin
                if (reserve_way_onehot_q[0]) pending_way0[reserve_set_q] <= 1'b1;
                if (reserve_way_onehot_q[1]) pending_way1[reserve_set_q] <= 1'b1;
                if (reserve_way_onehot_q[2]) pending_way2[reserve_set_q] <= 1'b1;
                if (reserve_way_onehot_q[3]) pending_way3[reserve_set_q] <= 1'b1;
            end
            if (fill_valid_q) begin
                if (!fill_good)
                    fault <= 1'b1;
                else begin
                    data_mem[fill_token_q] <= fill_data_q;
                    case (fill_token_q[1:0])
                        2'd0: pending_way0[fill_token_q[8:2]] <= 1'b0;
                        2'd1: pending_way1[fill_token_q[8:2]] <= 1'b0;
                        2'd2: pending_way2[fill_token_q[8:2]] <= 1'b0;
                        default: pending_way3[fill_token_q[8:2]] <= 1'b0;
                    endcase
                end
            end
            case ({miss_fire, fill_good})
                2'b10: pending_count <= pending_count + 10'd1;
                2'b01: pending_count <= pending_count - 10'd1;
                default: pending_count <= pending_count;
            endcase
            if (clear && clear_ready) begin
                valid_way0 <= 128'd0;
                valid_way1 <= 128'd0;
                valid_way2 <= 128'd0;
                valid_way3 <= 128'd0;
                pending_way0 <= 128'd0;
                pending_way1 <= 128'd0;
                pending_way2 <= 128'd0;
                pending_way3 <= 128'd0;
            end
        end
    end
endmodule
