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
//  Memory and address decode module for the MC68705P3 microcomputer.
//
//  Implements 112 bytes of internal RAM and generates chip selects for all
//  memory-mapped peripherals. The MC68705P3 uses a 2KB address space
//  ($000-$7FF) with Von Neumann architecture where program, data, and I/O
//  share the same address map.
//
//  The stack occupies the upper portion of RAM ($60-$7F, 32 bytes max).
//  Stack pointer resets to $7F and builds downward on push operations.
//  Five levels of subroutine nesting plus one interrupt requires 15 bytes.
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//
//  Memory Map:
//    $000-$007  I/O Registers (Port A/B/C data and DDRs)
//    $008-$009  Timer Registers (TDR, TCR)
//    $00A-$00F  Reserved (reads as $FF)
//    $010-$07F  Internal RAM (112 bytes, stack at $60-$7F)
//    $080-$783  User EPROM (1796 bytes)
//    $784       Mask Option Register (MOR)
//    $785-$7F7  Bootstrap ROM (115 bytes)
//    $7F8-$7FF  Interrupt Vectors (Timer, IRQ, SWI, Reset)
//============================================================================

module x68705_mem (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    // CPU Bus Interface
    input  wire [12:0] addr,
    input  wire  [7:0] din,
    output reg   [7:0] dout,
    input  wire        rd,
    input  wire        wr,

    // ROM Interface
    output wire [10:0] rom_addr,
    input  wire  [7:0] rom_data,
    output wire        rom_cs,

    // Peripheral Interface
    output wire       io_cs,
    output wire       timer_cs,
    input  wire [7:0] io_dout,
    input  wire [7:0] timer_dout
);

//------------------------------------------------------------------------
// Address Decode Constants:
// Page zero ($00-$FF) contains I/O, timer, and RAM. Addresses $80+
// access external EPROM. Reserved locations $0A-$0F read as $FF.
//------------------------------------------------------------------------
localparam [12:0] IO_START    = 13'h0000;
localparam [12:0] IO_END      = 13'h0007; // $00-$07 (io module handles $00-$06)
localparam [12:0] TIMER_START = 13'h0008;
localparam [12:0] TIMER_END   = 13'h0009; // $08-$09
localparam [12:0] RAM_START   = 13'h0010;
localparam [12:0] RAM_END     = 13'h007F; // $10-$7F (112 bytes)
localparam [12:0] ROM_START   = 13'h0080; // $80+

//------------------------------------------------------------------------
// Chip Select Generation:
// Active chip select signals route CPU bus transactions to the
// appropriate peripheral or memory. Only one select active at a time.
//------------------------------------------------------------------------
assign io_cs = (addr >= IO_START) && (addr <= IO_END);
assign timer_cs = (addr >= TIMER_START) && (addr <= TIMER_END);
wire   ram_cs = (addr >= RAM_START) && (addr <= RAM_END);
assign rom_cs = (addr >= ROM_START);

//------------------------------------------------------------------------
// ROM Address:
// Pass lower 11 bits to external ROM. External ROM contains user
// EPROM ($80-$783), MOR ($784), bootstrap ROM ($785-$7F7), and
// interrupt vectors ($7F8-$7FF).
//------------------------------------------------------------------------
assign rom_addr = addr[10:0];

//------------------------------------------------------------------------
// Internal RAM:
// 112 bytes mapped at $10-$7F. RAM serves dual purpose as general
// data storage and program stack. Stack area is $60-$7F (32 bytes).
// Address translation: RAM index = CPU address - $10.
//------------------------------------------------------------------------
wire [6:0] ram_addr = addr[6:0] - 7'h10; // Subtract $10 to get RAM index
wire       ram_we = ram_cs & wr & cen;
wire [7:0] ram_dout;

// Behavioral RAM for simulation compatibility
reg [7:0] ram [0:111]; // 112 bytes

// RAM Write:
// Synchronous write on clock edge when chip select, write, and
// clock enable are all active.
always @(posedge clk) begin
    if(ram_we) begin
        ram[ram_addr] <= din;
    end
end

// RAM Read:
// Synchronous read provides one cycle latency. Address is registered
// to meet timing requirements.
reg [7:0] ram_q;

always @(posedge clk) begin
    ram_q <= ram[ram_addr];
end

assign ram_dout = ram_q;

//------------------------------------------------------------------------
// Data Output Multiplexer:
// Routes read data from selected peripheral or memory to CPU data
// input. Priority: ROM > RAM > Timer > I/O. Unmapped addresses
// return $FF (open bus behavior).
//------------------------------------------------------------------------
always @(*) begin
    if(rom_cs)
        dout = rom_data;
    else if(ram_cs)
        dout = ram_dout;
    else if(timer_cs)
        dout = timer_dout;
    else if(io_cs)
        dout = io_dout;
    else
        dout = 8'hFF; // Default for unmapped addresses
end

//------------------------------------------------------------------------
// RAM Initialization:
// Clear RAM contents for simulation. Real hardware powers up with
// indeterminate RAM contents.
//------------------------------------------------------------------------
integer i;

initial begin
    for(i = 0; i < 112; i = i + 1) begin
        ram[i] = 8'h00;
    end
end

endmodule
