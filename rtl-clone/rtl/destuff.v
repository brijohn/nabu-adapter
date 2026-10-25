// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module destuff (
    input  wire       bitclk,
    input  wire       d,
    input  wire       pb0_edge,
    input  wire       mcu_int,
    output reg        n_flag,
    output reg        pal_rxgate,
    output reg        byte_rxgate,
    output reg        byte_strobe,
    output reg  [7:0] cabledata
);
    initial n_flag      = 1'b1;
    initial pal_rxgate  = 1'b0;
    initial byte_rxgate = 1'b0;
    initial byte_strobe = 1'b0;

    reg [2:0] bitcnt = 3'd0;
    reg [7:0] window = 8'd0;

    wire stuffed = (window[5:0] == 6'b111110) & ~window[6];
    wire flag    = (window[5:0] == 6'b111110) &  window[6] & ~window[7];

    always @(posedge bitclk) begin
        window <= {window[6:0], d};
        if (flag) begin
            bitcnt <= 3'd0;
        end else if (!stuffed) begin
            cabledata <= {cabledata[6:0], window[0]};
            bitcnt    <= bitcnt + 1'b1;
        end
    end

    always @(posedge bitclk) begin
        if (!stuffed) begin
            n_flag <= ~flag;
        end
    end

    always @(posedge bitclk) begin
        byte_strobe <= flag || (!stuffed && bitcnt == 3'd7);
    end

    always @(posedge bitclk) begin
        if (mcu_int)       pal_rxgate <= 1'b0;
        else if (pb0_edge) pal_rxgate <= 1'b1;
    end

    always @(posedge bitclk) begin
        if (flag) begin
            byte_rxgate <= pal_rxgate;
        end
    end
endmodule
