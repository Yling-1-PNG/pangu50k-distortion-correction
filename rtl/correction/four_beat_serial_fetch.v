// Correctness baseline: fetch one output pixel's 0..4 unique source beats.
// All ports share the DDR controller clock. Accept a new pixel only after the
// previous result is consumed; this serial design is not a 720p30 scheduler.
// Any address/response error halts further pixels until reset.
module four_beat_serial_fetch (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         pixel_valid,
    output wire         pixel_ready,
    input  wire [2:0]   unique_count,
    input  wire [17:0]  uniq_0,
    input  wire [17:0]  uniq_1,
    input  wire [17:0]  uniq_2,
    input  wire [17:0]  uniq_3,
    input  wire [27:0]  frame_base_ctrl_addr,
    output wire         req_valid,
    input  wire         req_ready,
    output wire [27:0]  req_addr,
    input  wire         rsp_valid,
    input  wire [255:0] rsp_data,
    input  wire         rsp_error,
    output wire         result_valid,
    input  wire         result_ready,
    output reg  [2:0]   result_count,
    output reg          result_error,
    output reg  [255:0] result_0,
    output reg  [255:0] result_1,
    output reg  [255:0] result_2,
    output reg  [255:0] result_3
);
    localparam IDLE = 3'd0, ISSUE = 3'd1, WAIT_DATA = 3'd2,
               DONE = 3'd3, HALT = 3'd4;
    reg [2:0] state;
    reg [1:0] index;
    reg [17:0] held_0, held_1, held_2, held_3;
    reg [27:0] held_base;
    reg fault_halt;
    wire [17:0] selected_beat = index == 2'd0 ? held_0 :
                                index == 2'd1 ? held_1 :
                                index == 2'd2 ? held_2 : held_3;
    wire addr_valid;

    hmic_beat_address address (
        .valid_in(state == ISSUE), .frame_base_ctrl_addr(held_base),
        .beat_index(selected_beat), .valid_out(addr_valid),
        .ctrl_addr(req_addr)
    );
    assign pixel_ready = rst_n && state == IDLE;
    assign req_valid = state == ISSUE && addr_valid;
    assign result_valid = state == DONE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 2'd0;
            held_0 <= 18'd0;
            held_1 <= 18'd0;
            held_2 <= 18'd0;
            held_3 <= 18'd0;
            held_base <= 28'd0;
            fault_halt <= 1'b0;
            result_count <= 3'd0;
            result_error <= 1'b0;
            result_0 <= 256'd0;
            result_1 <= 256'd0;
            result_2 <= 256'd0;
            result_3 <= 256'd0;
        end else begin
            case (state)
                IDLE: if (pixel_valid) begin
                    held_0 <= uniq_0;
                    held_1 <= uniq_1;
                    held_2 <= uniq_2;
                    held_3 <= uniq_3;
                    held_base <= frame_base_ctrl_addr;
                    index <= 2'd0;
                    result_count <= unique_count <= 3'd4 ? unique_count : 3'd0;
                    result_error <= unique_count > 3'd4;
                    fault_halt <= unique_count > 3'd4;
                    result_0 <= 256'd0;
                    result_1 <= 256'd0;
                    result_2 <= 256'd0;
                    result_3 <= 256'd0;
                    state <= unique_count == 3'd0 || unique_count > 3'd4 ?
                             DONE : ISSUE;
                end
                ISSUE: if (!addr_valid) begin
                    result_error <= 1'b1;
                    fault_halt <= 1'b1;
                    state <= DONE;
                end else if (req_ready)
                    state <= WAIT_DATA;
                WAIT_DATA: if (rsp_valid) begin
                    if (rsp_error) begin
                        result_error <= 1'b1;
                        fault_halt <= 1'b1;
                        state <= DONE;
                    end else begin
                        case (index)
                            2'd0: result_0 <= rsp_data;
                            2'd1: result_1 <= rsp_data;
                            2'd2: result_2 <= rsp_data;
                            2'd3: result_3 <= rsp_data;
                        endcase
                        if ({1'b0, index} + 3'd1 == result_count)
                            state <= DONE;
                        else begin
                            index <= index + 2'd1;
                            state <= ISSUE;
                        end
                    end
                end
                DONE: if (result_ready)
                    state <= fault_halt ? HALT : IDLE;
                default: state <= HALT;
            endcase
        end
    end
endmodule
