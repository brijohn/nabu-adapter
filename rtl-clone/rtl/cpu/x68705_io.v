/*
* <-- Coin-Op Collection -->
* https://coinopcollection.org
* https://github.com/Coin-OpCollection/
*
* Author: atrac17 (https://twitter.com/_atrac17)
* Copyright © 2025 Coin-Op Collection
*
* This work is licensed under the Creative Commons Attribution-NonCommercial 4.0 International License.
* To view a copy of this license, visit http://creativecommons.org/licenses/by-nc/4.0/.
*
* You may use, share, and modify this code for non-commercial purposes, provided that proper credit is given.
*/

//============================================================================
//  Parallel I/O ports module for the MC68705P3 microcomputer.
//
//  Implements three bidirectional I/O ports with independent data direction
//  control per pin. Port A and B are 8-bit wide, Port C is 4-bit wide.
//  Each port has a Data Register for read/write and a Data Direction
//  Register (DDR) that configures pins as input (0) or output (1).
//
//  Port characteristics per MC68705P3 datasheet:
//    Port A - Internal pull-ups (~10k), sinks 1.6mA, drives CMOS/1 TTL
//    Port B - True high-Z, sinks 10mA (LED) or 3.2mA, needs pull-ups
//    Port C - True high-Z (4-bit), sinks 1.6mA, needs pull-ups
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//
//  Register Map:
//    $00 - Port A Data Register (read/write)
//    $01 - Port B Data Register (read/write)
//    $02 - Port C Data Register (bits 3:0, upper bits read as 1)
//    $03 - Reserved (reads as $FF)
//    $04 - Port A DDR (write-only, reads as $FF on real hardware)
//    $05 - Port B DDR (write-only, reads as $FF on real hardware)
//    $06 - Port C DDR (bits 3:0, write-only)
//============================================================================

module x68705_io (
    input  wire       clk,
    input  wire       rst,
    input  wire       cen,

    // Register Bus Interface
    input  wire       cs,
    input  wire [2:0] addr, // Register select (0-6)
    input  wire [7:0] din,
    output reg  [7:0] dout,
    input  wire       wr,

    // I/O Port Interface
    input  wire [7:0] pa_i,
    output wire [7:0] pa_o,
    input  wire [7:0] pb_i,
    output wire [7:0] pb_o,
    input  wire [3:0] pc_i,
    output wire [3:0] pc_o
);

//------------------------------------------------------------------------
// Register Addresses:
// I/O registers occupy $00-$06 in the memory map. Address $03 and $07
// are reserved/unused and read as $FF.
//------------------------------------------------------------------------
localparam [2:0]
    ADDR_PA_DATA = 3'd0,
    ADDR_PB_DATA = 3'd1,
    ADDR_PC_DATA = 3'd2,
    ADDR_PA_DDR  = 3'd4,
    ADDR_PB_DDR  = 3'd5,
    ADDR_PC_DDR  = 3'd6;

//------------------------------------------------------------------------
// Internal Registers:
// Output data latches hold values written by CPU. DDRs control pin
// direction. Data is written to latch regardless of DDR state, so
// initial output values should be set before configuring DDR.
//------------------------------------------------------------------------
reg [7:0] pa_latch; // Port A output data latch
reg [7:0] pb_latch; // Port B output data latch
reg [3:0] pc_latch; // Port C output data latch

reg [7:0] pa_ddr;   // Port A data direction register
reg [7:0] pb_ddr;   // Port B data direction register
reg [3:0] pc_ddr;   // Port C data direction register

//------------------------------------------------------------------------
// Output Generation:
// DDR bit = 0: Pin configured as input, output reflects external pin
// DDR bit = 1: Pin configured as output, output reflects latch value
// This muxing provides read-back of actual pin state for inputs and
// written value for outputs, matching hardware behavior.
//------------------------------------------------------------------------
reg [7:0] pa_o_r;
reg [7:0] pb_o_r;
reg [3:0] pc_o_r;

always @(posedge clk) begin
    pa_o_r <= (pa_latch & pa_ddr) | (pa_i & ~pa_ddr);
    pb_o_r <= (pb_latch & pb_ddr) | (pb_i & ~pb_ddr);
    pc_o_r <= (pc_latch & pc_ddr) | (pc_i & ~pc_ddr);
end

assign pa_o = pa_o_r;
assign pb_o = pb_o_r;
assign pc_o = pc_o_r;

//------------------------------------------------------------------------
// Register Write:
// On reset, all DDRs clear to 0 (all pins input), latches clear to 0.
// CPU writes update latch or DDR based on address. Writing to data
// register updates latch even when pin is configured as input.
//------------------------------------------------------------------------
always @(posedge clk) begin
    if(rst) begin
        // Reset: All DDRs to 0 (all inputs), latches to 0
        pa_latch <= 8'h00;
        pb_latch <= 8'h00;
        pc_latch <= 4'h0;
        pa_ddr <= 8'h00;
        pb_ddr <= 8'h00;
        pc_ddr <= 4'h0;
    end else if(cen && cs && wr) begin
        case(addr)
            ADDR_PA_DATA: pa_latch <= din;
            ADDR_PB_DATA: pb_latch <= din;
            ADDR_PC_DATA: pc_latch <= din[3:0];
            ADDR_PA_DDR: pa_ddr <= din;
            ADDR_PB_DDR: pb_ddr <= din;
            ADDR_PC_DDR: pc_ddr <= din[3:0];
            default: ; // No operation for reserved addresses
        endcase
    end
end

//------------------------------------------------------------------------
// Register Read:
// Data registers return combined value: latch for output pins, pin
// state for input pins. Port C upper 4 bits read as 1 (no pins).
// Note: On real MC68705P3, DDRs are write-only and read as $FF.
// This implementation returns actual DDR values for debug visibility.
//------------------------------------------------------------------------
always @(*) begin
    case(addr)
        ADDR_PA_DATA: dout = pa_o;
        ADDR_PB_DATA: dout = pb_o;
        ADDR_PC_DATA: dout = {4'hF, pc_o};  // Upper 4 bits read as 1s
        ADDR_PA_DDR: dout = pa_ddr;
        ADDR_PB_DDR: dout = pb_ddr;
        ADDR_PC_DDR: dout = {4'hF, pc_ddr}; // Upper 4 bits read as 1s
        default: dout = 8'hFF;
    endcase
end

endmodule
