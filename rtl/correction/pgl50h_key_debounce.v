// Synchronized, active-low push-button debounce with one-cycle press pulse.
// The default count is for the PGL50H 50 MHz system clock and a 20 ms
// debounce interval. Small values can be used by the focused simulation.
module pgl50h_key_debounce #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    parameter integer ACTIVE_LOW = 1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  press_pulse,
    output reg  pressed
);
    localparam integer COUNT_WIDTH =
        (DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(DEBOUNCE_CYCLES);
    reg key_meta, key_sync;
    reg stable_pressed_d;
    reg [COUNT_WIDTH-1:0] stable_count;
    wire sampled_pressed = ACTIVE_LOW ? ~key_sync : key_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= ACTIVE_LOW ? 1'b1 : 1'b0;
            key_sync <= ACTIVE_LOW ? 1'b1 : 1'b0;
            stable_pressed_d <= 1'b0;
            stable_count <= {COUNT_WIDTH{1'b0}};
            pressed <= 1'b0;
            press_pulse <= 1'b0;
        end else begin
            key_meta <= key_in;
            key_sync <= key_meta;
            press_pulse <= 1'b0;

            if (sampled_pressed == pressed) begin
                stable_count <= {COUNT_WIDTH{1'b0}};
            end else if (DEBOUNCE_CYCLES <= 1 ||
                         stable_count == DEBOUNCE_CYCLES - 1) begin
                pressed <= sampled_pressed;
                stable_count <= {COUNT_WIDTH{1'b0}};
            end else begin
                stable_count <= stable_count + 1'b1;
            end

            stable_pressed_d <= pressed;
            if (pressed && !stable_pressed_d)
                press_pulse <= 1'b1;
        end
    end
endmodule
