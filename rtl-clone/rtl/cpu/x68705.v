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
//  Fully synchronous, cycle-accurate implementation of the MC68705P3
//  microcomputer unit with single address map and memory-mapped I/O.
//
//  The design integrates all functional blocks found in the original device:
//  CPU, ALU, RAM, I/O ports, and timer, connected via internal data and
//  address buses. External EPROM is provided through a dedicated interface.
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//
//  Submodules:
//    x6805        - Central processor containing instruction decoder, state
//                   machine, program counter (11-bit), stack pointer (6-bit),
//                   index register, accumulator, and condition code register.
//                   Executes 88 instructions across 8 addressing modes.
//
//    x6805_alu    - 8-bit arithmetic logic unit performing ADD, SUB, AND, OR,
//                   EOR, shifts, rotates, and BCD decimal adjust. Generates
//                   carry, half-carry, zero, and negative flags.
//
//    x68705_io    - Three parallel I/O ports: Port A (8-bit), Port B (8-bit),
//                   Port C (4-bit). Each pin individually programmable as
//                   input or output via Data Direction Registers (DDRs).
//
//    x68705_timer - 8-bit timer/counter with 7-bit programmable prescaler.
//                   Can be clocked internally or externally. Generates
//                   interrupt on overflow. Configured via Mask Option Register.
//
//    x68705_mem   - Address decoder and 112-byte internal RAM ($10-$7F).
//                   Generates chip selects for I/O ($00-$07), timer ($08-$09),
//                   RAM, and external EPROM ($80-$7FF).
//============================================================================

module x68705 (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    // ROM Interface
    output wire [10:0] rom_addr,
    input  wire  [7:0] rom_data,
    output wire        rom_cs,

    // I/O Port Interface
    input  wire  [7:0] pa_i,     // Port A input
    output wire  [7:0] pa_o,     // Port A output
    input  wire  [7:0] pb_i,     // Port B input
    output wire  [7:0] pb_o,     // Port B output
    input  wire  [3:0] pc_i,     // Port C input (4-bit)
    output wire  [3:0] pc_o,     // Port C output (4-bit)

    // Interrupt Interface
    input  wire        irq,      // External interrupt request
    output wire        irq_ack,  // Interrupt acknowledge pulse

    // Timer External Input
    input  wire        timer_in, // External timer clock input

    // EPROM Interface
    input  wire  [7:0] mor       // MOR for timer configuration
);

//------------------------------------------------------------------------
// Internal Bus Signals:
// 13-bit address bus and 8-bit data bus connect CPU to all memory and
// peripherals. Memory-mapped I/O uses same bus for register access.
//------------------------------------------------------------------------
wire [12:0] cpu_addr;
wire  [7:0] cpu_dout;
wire  [7:0] cpu_din;
wire        cpu_rd;
wire        cpu_wr;

//------------------------------------------------------------------------
// ALU Interface:
// CPU provides operands (A, B), operation code, and carry/half-carry
// inputs. ALU returns 8-bit result and updated condition flags (C,H,Z,N).
//------------------------------------------------------------------------
wire [7:0] alu_a;
wire [7:0] alu_b;
wire [4:0] alu_op;
wire       alu_cin;
wire       alu_hin;
wire [7:0] alu_result;
wire       alu_cout;
wire       alu_hout;
wire       alu_zout;
wire       alu_nout;

//------------------------------------------------------------------------
// Peripheral Chip Selects and Data:
// Address decoder generates active chip selects for I/O registers
// ($00-$07) and timer registers ($08-$09). Each peripheral drives
// its data output onto the read data mux.
//------------------------------------------------------------------------
wire       io_cs;
wire       timer_cs;
wire [7:0] io_dout;
wire [7:0] timer_dout;

//------------------------------------------------------------------------
// Timer Interrupt:
// TIRQ asserts when timer overflows and interrupt is not masked (TIM=0).
// TSTOP halts timer during STOP instruction execution.
//------------------------------------------------------------------------
wire tirq;
wire tstop;

//------------------------------------------------------------------------
// 6805 CPU Instance:
// Central processor with instruction decoder, state machine, program
// counter, stack pointer, index register, accumulator, and condition
// code register. Handles instruction fetch, decode, execute cycles
// and interrupt processing for IRQ, TIRQ, and SWI.
//------------------------------------------------------------------------
x6805 u_cpu (
    .clk        ( clk        ),
    .rst        ( rst        ),
    .cen        ( cen        ),
    .addr       ( cpu_addr   ),
    .din        ( cpu_din    ),
    .dout       ( cpu_dout   ),
    .rd         ( cpu_rd     ),
    .wr         ( cpu_wr     ),
    .irq        ( irq        ),
    .tirq       ( tirq       ),
    .irq_ack    ( irq_ack    ),
    .alu_a      ( alu_a      ),
    .alu_b      ( alu_b      ),
    .alu_op     ( alu_op     ),
    .alu_cin    ( alu_cin    ),
    .alu_hin    ( alu_hin    ),
    .alu_result ( alu_result ),
    .alu_cout   ( alu_cout   ),
    .alu_hout   ( alu_hout   ),
    .alu_zout   ( alu_zout   ),
    .alu_nout   ( alu_nout   ),
    .tstop      ( tstop      )
);

//------------------------------------------------------------------------
// ALU Instance:
// Combinational arithmetic logic unit. Performs ADD, ADC, SUB, SBC,
// AND, ORA, EOR, shifts, rotates, increment, decrement, complement,
// negate, and BCD decimal adjust operations.
//------------------------------------------------------------------------
x6805_alu u_alu (
    .a      ( alu_a      ),
    .b      ( alu_b      ),
    .op     ( alu_op     ),
    .cin    ( alu_cin    ),
    .hin    ( alu_hin    ),
    .result ( alu_result ),
    .cout   ( alu_cout   ),
    .hout   ( alu_hout   ),
    .zout   ( alu_zout   ),
    .nout   ( alu_nout   )
);

//------------------------------------------------------------------------
// Memory and Address Decode Instance:
// Contains 112 bytes of internal RAM ($10-$7F) and generates chip
// selects for I/O, timer, RAM, and external EPROM. Multiplexes read
// data from all sources onto CPU data input bus.
//------------------------------------------------------------------------
x68705_mem u_mem (
    .clk        ( clk        ),
    .rst        ( rst        ),
    .cen        ( cen        ),
    .addr       ( cpu_addr   ),
    .din        ( cpu_dout   ),
    .dout       ( cpu_din    ),
    .rd         ( cpu_rd     ),
    .wr         ( cpu_wr     ),
    .rom_addr   ( rom_addr   ),
    .rom_data   ( rom_data   ),
    .rom_cs     ( rom_cs     ),
    .io_cs      ( io_cs      ),
    .timer_cs   ( timer_cs   ),
    .io_dout    ( io_dout    ),
    .timer_dout ( timer_dout )
);

//------------------------------------------------------------------------
// I/O Ports Instance:
// Three parallel I/O ports with independent data direction control.
// Port A and B are 8-bit, Port C is 4-bit. DDRs configure each pin
// as input (0) or output (1). DDRs are write-only, read as $FF.
//------------------------------------------------------------------------
x68705_io u_io (
    .clk  ( clk           ),
    .rst  ( rst           ),
    .cen  ( cen           ),
    .cs   ( io_cs         ),
    .addr ( cpu_addr[2:0] ),
    .din  ( cpu_dout      ),
    .dout ( io_dout       ),
    .wr   ( cpu_wr        ),
    .pa_i ( pa_i          ),
    .pa_o ( pa_o          ),
    .pb_i ( pb_i          ),
    .pb_o ( pb_o          ),
    .pc_i ( pc_i          ),
    .pc_o ( pc_o          )
);

//------------------------------------------------------------------------
// Timer Instance:
// 8-bit down counter with 7-bit programmable prescaler (divide 1-128).
// Clock source selected by MOR: internal bus clock or external TIMER
// pin. Generates TIRQ on underflow from $00 to $FF.
//------------------------------------------------------------------------
x68705_timer u_timer (
    .clk      ( clk           ),
    .rst      ( rst           ),
    .cen      ( cen           ),
    .cs       ( timer_cs      ),
    .addr     ( cpu_addr[0]   ),
    .din      ( cpu_dout      ),
    .dout     ( timer_dout    ),
    .wr       ( cpu_wr        ),
    .timer_in ( timer_in      ),
    .mor      ( mor           ),
    .tirq     ( tirq          ),
    .tstop    ( tstop         )
);

endmodule
