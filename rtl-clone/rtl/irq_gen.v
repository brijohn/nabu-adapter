// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module irq_gen (
    input  wire bitclk,
    input  wire fifo_pop,
    input  wire fifo_empty,
    input  wire fifo_so_set,
    output reg  irq
);
    initial irq = 1'b0;

    reg fifo_empty_q  = 1'b1;
    reg fifo_so_set_q = 1'b0;

    wire not_empty = fifo_empty_q & ~fifo_empty;
    wire drained   = fifo_pop & fifo_empty;
    wire terminate = fifo_so_set & ~fifo_so_set_q;

    always @(posedge bitclk) begin
        fifo_empty_q  <= fifo_empty;
        fifo_so_set_q <= fifo_so_set;
        if (not_empty | drained) begin
            irq <= 1'b1;
        end else if (terminate) begin
            irq <= 1'b0;
        end
    end
endmodule
