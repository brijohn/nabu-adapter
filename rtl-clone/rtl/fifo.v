// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module fifo (
    input  wire       bitclk,
    input  wire       clear,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    input  wire       rd_en,
    output reg  [7:0] rd_data,
    output wire       empty,
    output wire       full
);
    reg [7:0]  mem [0:1023];
    reg [10:0] wr_ptr = 11'd0;
    reg [10:0] rd_ptr = 11'd0;
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr == {~rd_ptr[10], rd_ptr[9:0]});

    always @(posedge bitclk) begin
        if (clear) begin
            wr_ptr <= 11'd0;
            rd_ptr <= 11'd0;
        end else begin
            if (wr_en & ~full) begin
                mem[wr_ptr[9:0]] <= wr_data;
                wr_ptr           <= wr_ptr + 1'b1;
            end
            if (rd_en & ~empty) begin
                rd_data <= mem[rd_ptr[9:0]];
                rd_ptr  <= rd_ptr + 1'b1;
            end
        end
    end
endmodule
