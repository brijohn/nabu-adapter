// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module capture_ctrl (
    input  wire       bitclk,
    input  wire       byte_strobe,
    input  wire       n_flag,
    input  wire [7:0] cabledata,
    input  wire       byte_rxgate,
    input  wire       pal_rxgate,
    input  wire       n_mcu_rd,
    output wire       fifo_empty,
    output wire       fifo_pop,
    output wire [7:0] fifo_dout
);
    reg [2:0] rd_sync    = 3'b111;
    reg       fifo_pop_q = 1'b0;

    wire wr_en = byte_strobe & byte_rxgate & n_flag;
    wire clear = ~n_flag & pal_rxgate;
    wire pop   = rd_sync[2] & ~rd_sync[1];

    assign fifo_pop = fifo_pop_q;

    always @(posedge bitclk) begin
        rd_sync    <= {rd_sync[1:0], n_mcu_rd};
        fifo_pop_q <= pop;
    end

    fifo u_fifo (
        .bitclk  (bitclk),
        .clear   (clear),
        .wr_en   (wr_en),
        .wr_data (cabledata),
        .rd_en   (pop),
        .rd_data (fifo_dout),
        .empty   (fifo_empty),
        .full    ()
    );
endmodule
