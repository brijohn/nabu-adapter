// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

module uart (
    input  wire       clk,
    input  wire       rst,
    input  wire       baud16_en,
    input  wire [7:0] tx_data,
    input  wire       tx_load,
    input  wire       rx_read,
    input  wire       rxd,
    output reg  [7:0] rx_data,
    output reg        thre,
    output reg        dav,
    output reg        txd
);
    initial thre = 1'b1;
    initial txd  = 1'b1;

    reg [7:0] thr       = 8'd0;
    reg       thr_full  = 1'b0;
    reg [8:0] tx_sr     = 9'd0;
    reg [3:0] tx_phase  = 4'd0;
    reg [3:0] tx_bits   = 4'd0;
    reg       tx_active = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            thr_full  <= 1'b0;
            thre      <= 1'b1;
            tx_active <= 1'b0;
            txd       <= 1'b1;
        end else begin
            if (tx_load) begin
                thr      <= tx_data;
                thr_full <= 1'b1;
                thre     <= 1'b0;
            end
            if (baud16_en) begin
                if (tx_active) begin
                    if (tx_phase == 4'd15) begin
                        tx_phase <= 4'd0;
                        if (tx_bits == 4'd0) begin
                            tx_active <= 1'b0;
                            txd       <= 1'b1;
                        end else begin
                            txd     <= tx_sr[0];
                            tx_sr   <= {1'b1, tx_sr[8:1]};
                            tx_bits <= tx_bits - 1'b1;
                        end
                    end else begin
                        tx_phase <= tx_phase + 1'b1;
                    end
                end else if (thr_full) begin
                    tx_sr     <= {1'b1, thr};
                    txd       <= 1'b0;
                    tx_bits   <= 4'd9;
                    tx_phase  <= 4'd0;
                    tx_active <= 1'b1;
                    thr_full  <= 1'b0;
                    thre      <= 1'b1;
                end
            end
        end
    end

    localparam RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [1:0] rxd_sync = 2'b11;
    reg [1:0] rx_state = RX_IDLE;
    reg [3:0] rx_phase = 4'd0;
    reg [2:0] rx_bits  = 3'd0;
    reg [7:0] rx_sr    = 8'd0;

    wire rxd_s    = rxd_sync[1];
    wire sample   = baud16_en & (rx_phase == 4'd7);
    wire bit_tick = baud16_en & (rx_phase == 4'd15);

    always @(posedge clk) begin
        if (rx_state == RX_IDLE || rst) rx_phase <= 4'd0;
        else if (baud16_en)             rx_phase <= rx_phase + 1'b1;
    end

    always @(posedge clk) begin
        if (rst) begin
            rxd_sync <= 2'b11;
            rx_state <= RX_IDLE;
            dav      <= 1'b0;
            rx_data  <= 8'd0;
        end else begin
            rxd_sync <= {rxd_sync[0], rxd};
            if (rx_read) dav <= 1'b0;
            case (rx_state)
                RX_IDLE: begin
                    if (~rxd_s) rx_state <= RX_START;
                end
                RX_START: begin
                    if (sample & rxd_s) begin
                        rx_state <= RX_IDLE;
                        rx_bits  <= 3'd0;
                    end else if (bit_tick) begin
                        rx_state <= RX_DATA;
                        rx_bits  <= 3'd0;
                    end
                end
                RX_DATA: begin
                    if (sample) rx_sr <= {rxd_s, rx_sr[7:1]};
                    if (bit_tick) begin
                        if (rx_bits == 3'd7) rx_state <= RX_STOP;
                        else                 rx_bits  <= rx_bits + 1'b1;
                    end
                end
                RX_STOP: begin
                    if (sample) begin
                        rx_data <= rx_sr;
                        dav     <= 1'b1;
                    end
                    if (bit_tick) rx_state <= RX_IDLE;
                end
            endcase
        end
    end
endmodule
