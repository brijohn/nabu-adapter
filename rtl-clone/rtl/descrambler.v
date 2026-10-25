// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module descrambler (
    input  wire bitclk,
    input  wire s,
    output wire d
);
    reg [19:0] sr = 20'd0;

    assign d = ~(s ^ sr[2] ^ sr[19]);

    always @(posedge bitclk) begin
        sr <= {sr[18:0], s};
    end
endmodule
