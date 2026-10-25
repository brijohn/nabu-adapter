// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

// NABU NA-2 6805 firmware ROM (2 KB)
module rom (
    input  wire        clk,
    input  wire [10:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:2047];
    initial $readmemh("rtl/cpu/nabuna_fw.hex", mem);

    always @(posedge clk) begin
        data <= mem[addr];
    end
endmodule
