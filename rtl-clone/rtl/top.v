// Copyright (c) 2026 Brian Johnson
// SPDX-License-Identifier: CC-BY-NC-4.0

// NA-2 digital board clone - top level (Tang Nano 9K)
module top (
    input  wire       clk27,
    input  wire       demod_clk,
    input  wire       demod_data,
    input  wire       uart_rxd,
    output wire       uart_txd,
    output wire       pll_enb,
    output wire       pll_clk,
    output wire       pll_data,
    output wire [5:0] led
);
    localparam CEN_DIV = 7;

    reg [23:0] beat = 24'd0;
    always @(posedge clk27) begin
        beat <= beat + 1'b1;
    end

    reg [3:0] por = 4'd0;
    always @(posedge demod_clk) begin
        if (~&por) por <= por + 1'b1;
    end

    reg [2:0] cen_cnt = 3'd0;
    always @(posedge demod_clk) begin
        cen_cnt <= (cen_cnt == (CEN_DIV - 1)) ? 3'd0 : cen_cnt + 1'b1;
    end
    wire cpu_cen = (cen_cnt == (CEN_DIV - 1));

    // ~1066 Hz TIMER input, in place of the real board's RC oscillator
    reg [12:0] tmr_cnt  = 13'd0;
    reg        timer_in = 1'b0;
    always @(posedge demod_clk) begin
        if (tmr_cnt == 13'd2959) begin
            tmr_cnt  <= 13'd0;
            timer_in <= ~timer_in;
        end else begin
            tmr_cnt <= tmr_cnt + 1'b1;
        end
    end

    // 16 x 111860 baud from the 6.312 MHz demod clock
    localparam [15:0] BAUD_INC = 16'd18583;
    reg        baud16_en = 1'b0;
    reg [15:0] baud_acc  = 16'd0;
    always @(posedge demod_clk) begin
        {baud16_en, baud_acc} <= baud_acc + BAUD_INC;
    end

    wire [7:0]  pa_o, pb_o;
    wire [10:0] rom_addr;
    wire [7:0]  rom_data;

    reg pb0_q = 1'b0;
    always @(posedge demod_clk) begin
        pb0_q <= pb_o[0];
    end
    wire pb0_edge = pb_o[0] & ~pb0_q;

    wire d;
    descrambler u_descrambler (.bitclk(demod_clk), .s(demod_data), .d(d));

    wire       irq, n_flag, pal_rxgate, byte_rxgate, byte_strobe;
    wire [7:0] cabledata;
    destuff u_destuff (
        .bitclk      (demod_clk),
        .d           (d),
        .pb0_edge    (pb0_edge),
        .mcu_int     (irq),
        .n_flag      (n_flag),
        .pal_rxgate  (pal_rxgate),
        .byte_rxgate (byte_rxgate),
        .byte_strobe (byte_strobe),
        .cabledata   (cabledata)
    );

    wire       fifo_so_set, n_fifo_so_clr;
    wire [1:0] mcu_status;
    pal u_pal (
        .bitclk      (demod_clk),
        .byte_strobe (byte_strobe),
        .d           (cabledata),
        .n_flag      (n_flag),
        .rx_gate     (pal_rxgate),
        .byte_cnt    ({fifo_so_set, n_fifo_so_clr}),
        .mcu_status  (mcu_status)
    );

    wire       fifo_empty, fifo_pop;
    wire [7:0] fifo_dout;
    capture_ctrl u_capture_ctrl (
        .bitclk      (demod_clk),
        .byte_strobe (byte_strobe),
        .n_flag      (n_flag),
        .cabledata   (cabledata),
        .byte_rxgate (byte_rxgate),
        .pal_rxgate  (pal_rxgate),
        .n_mcu_rd    (pb_o[1]),
        .fifo_empty  (fifo_empty),
        .fifo_pop    (fifo_pop),
        .fifo_dout   (fifo_dout)
    );

    irq_gen u_irq_gen (
        .bitclk      (demod_clk),
        .fifo_pop    (fifo_pop),
        .fifo_empty  (fifo_empty),
        .fifo_so_set (fifo_so_set),
        .irq         (irq)
    );

    reg n_thrl_q    = 1'b1;
    reg thrl_fifo_q = 1'b0;

    wire thrl_fifo = fifo_pop & ~pb_o[2];
    wire n_thrl    = ~(thrl_fifo | pb_o[6]);
    always @(posedge demod_clk) begin
        n_thrl_q    <= n_thrl;
        thrl_fifo_q <= thrl_fifo;
    end
    wire       tx_load    = n_thrl & ~n_thrl_q;
    wire [7:0] uart_txbus = thrl_fifo_q ? fifo_dout : pa_o;

    reg pb3_q = 1'b1;
    always @(posedge demod_clk) begin
        pb3_q <= pb_o[3];
    end
    wire rx_read = ~pb_o[3] & pb3_q;

    wire [7:0] uart_rx;
    wire       thre, dav;
    uart u_uart (
        .clk       (demod_clk),
        .rst       (~&por),
        .baud16_en (baud16_en),
        .tx_data   (uart_txbus),
        .tx_load   (tx_load),
        .rx_read   (rx_read),
        .rxd       (uart_rxd),
        .rx_data   (uart_rx),
        .thre      (thre),
        .dav       (dav),
        .txd       (uart_txd)
    );

    wire [7:0] pa_i = ~pb_o[1] ? fifo_dout :
                      ~pb_o[3] ? uart_rx   :
                      8'hFF;

    wire [3:0] pc_i = {mcu_status, thre, dav};

    rom u_rom (.clk(demod_clk), .addr(rom_addr), .data(rom_data));
    x68705 u_cpu (
        .clk      (demod_clk),
        .rst      (~&por),
        .cen      (cpu_cen),
        .rom_addr (rom_addr),
        .rom_data (rom_data),
        .rom_cs   (),
        .pa_i     (pa_i),
        .pa_o     (pa_o),
        .pb_i     (8'hFF),
        .pb_o     (pb_o),
        .pc_i     (pc_i),
        .pc_o     (),
        .irq      (irq),
        .irq_ack  (),
        .timer_in (timer_in),
        .mor      (8'h00)
    );

    assign pll_enb  = pb_o[7];
    assign pll_clk  = pa_o[6];
    assign pll_data = pa_o[7];

    reg [21:0] stretch = 22'd0;
    always @(posedge demod_clk) begin
        if (!n_flag)               stretch <= {22{1'b1}};
        else if (stretch != 22'd0) stretch <= stretch - 1'b1;
    end

    assign led = {2'b11, pb_o[5], pb_o[4], ~(stretch != 22'd0), ~beat[23]};
endmodule
