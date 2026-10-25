// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module pal #(parameter [31:0] ID = 32'h80_01_18_87) (
    input  wire       bitclk,
    input  wire       byte_strobe,
    input  wire [7:0] d,
    input  wire       n_flag,
    input  wire       rx_gate,
    output reg  [1:0] byte_cnt,
    output reg  [1:0] mcu_status
);
    initial byte_cnt   = 2'd0;
    initial mcu_status = 2'd0;

    reg n_uniq  = 1'b0;
    reg n_bcast = 1'b0;

    wire armed_flag = ~n_flag & rx_gate;
    wire s0         = ~byte_cnt[0] | armed_flag;
    wire s1         = (byte_cnt[0] == byte_cnt[1]) | armed_flag;

    always @(posedge bitclk) begin
        if (byte_strobe) begin
            byte_cnt      <= {s1, s0};
            n_uniq        <= ~(armed_flag
                               | ~n_uniq & byte_cnt == 2'd3 & d == ID[31:24]
                               | ~n_uniq & byte_cnt == 2'd2 & d == ID[23:16]
                               | ~n_uniq & byte_cnt == 2'd1 & d == ID[15:8]
                              );
            n_bcast       <= ~(n_flag & d == 8'hFF & ((byte_cnt == 2'd3 & ~n_uniq) | ~n_bcast));
            mcu_status[1] <= ~((n_flag & byte_cnt == 2'd0 & ((~n_uniq & d == ID[7:0]) | (~n_bcast & d == 8'hFF)))
                               | ((n_flag | ~rx_gate) & ~mcu_status[1])
                              );
            mcu_status[0] <= ~((n_flag & byte_cnt == 2'd3 & ~n_uniq & d[7])
                               | ((n_flag | ~rx_gate) & ~mcu_status[0])
                              );
        end
    end
endmodule
