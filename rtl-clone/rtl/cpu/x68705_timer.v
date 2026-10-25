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
//  Timer/counter module for the MC68705P3 microcomputer.
//
//  Implements an 8-bit down counter (TDR) with 7-bit prescaler for extended
//  timing periods. The counter decrements toward zero; when it underflows
//  from $00, the Timer Interrupt Request (TIR) bit is set. The counter
//  continues counting after underflow, allowing software to determine
//  elapsed time since the interrupt without disturbing the count.
//
//  The prescaler divides the input clock by 1, 2, 4, 8, 16, 32, 64, or 128
//  based on TCR[2:0]. Writing 1 to TCR[3] clears the prescaler for
//  truncation-free counting.
//
//  Timer input modes (TCR[5:4]):
//    00 - Internal clock (instruction cycle clock)
//    01 - Internal clock AND TIMER pin (gated, for pulse width measurement)
//    10 - Disabled (no clock input)
//    11 - External TIMER pin (for event counting)
//
//  On EPROM devices, MOR[TOPT] determines whether TCR[5:0] are fixed from
//  MOR (emulating mask-programmed devices) or software programmable.
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//
//  Register Map:
//    $08 - TDR (Timer Data Register) - 8-bit down counter, read/write
//    $09 - TCR (Timer Control Register) - control and status
//
//  TCR Bit Definitions:
//    [7] TIR - Timer Interrupt Request (set on underflow, write 0 to clear)
//    [6] TIM - Timer Interrupt Mask (1=masked, 0=enabled)
//    [5] TIN - Timer Input Select (0=internal, 1=external)
//    [4] TIE - Timer Input Enable (enables TIMER pin)
//    [3] PSC - Prescaler Clear (write 1 to clear, always reads 0)
//    [2:0]   - Prescaler Select (divide ratio 2^n: 1,2,4,8,16,32,64,128)
//============================================================================

module x68705_timer (
    input  wire       clk,
    input  wire       rst,
    input  wire       cen,      // Clock enable

    // Register Bus Interface
    input  wire       cs,
    input  wire       addr,     // 0=TDR ($08), 1=TCR ($09)
    input  wire [7:0] din,
    output reg  [7:0] dout,
    input  wire       wr,

    // Timer Input Pin
    input  wire       timer_in, // External TIMER pin

    // EPROM Interface
    input  wire [7:0] mor,

    // Timer Interrupt Output
    output wire       tirq,     // Timer interrupt request (active high)

    // Timer Stop (for STOP/WAIT instructions)
    input  wire tstop
);

//------------------------------------------------------------------------
// TCR Bit Positions:
// These constants define the bit positions within the Timer Control
// Register for clearer code references.
//------------------------------------------------------------------------
localparam TIR = 7; // Timer Interrupt Request
localparam TIM = 6; // Timer Interrupt Mask
localparam TIN = 5; // Timer Input Select (ext/int)
localparam TIE = 4; // Timer Input Enable
localparam PSC = 3; // Prescaler Clear

// MOR bit for timer option
localparam TOPT = 6; // Timer option bit in MOR

//------------------------------------------------------------------------
// Internal Registers:
// TDR is the 8-bit down counter visible to software.
// TCR contains control bits and interrupt status.
// Prescaler is a 7-bit counter that divides the input clock.
//------------------------------------------------------------------------
reg [7:0] tdr;       // Timer Data Register (8-bit counter)
reg [7:0] tcr;       // Timer Control Register
reg [6:0] prescaler; // 7-bit prescaler

// Edge detection for clock inputs
reg fpin_last; // Last state of filtered pin input
reg prmx_last; // Last state of prescaler mux output

// Internal clock divider (generates slower clock from cen)
reg [1:0] cen_div;

//------------------------------------------------------------------------
// Timer Input Logic:
// Selects clock source based on TIN and TIE bits. When MOR[TOPT]=1,
// these settings come from MOR (mask option emulation); otherwise
// they are software programmable via TCR.
//
// Mode selection:
//   TIN=0, TIE=0: Internal clock only
//   TIN=0, TIE=1: Internal clock gated by TIMER pin (pulse measurement)
//   TIN=1, TIE=0: Timer disabled (no clock)
//   TIN=1, TIE=1: External TIMER pin only (event counting)
//------------------------------------------------------------------------

// When MOR[TOPT]=1, use MOR settings; otherwise use TCR settings
wire use_mor = mor[TOPT];
wire eff_tin = use_mor ? mor[TIN] : tcr[TIN];
wire eff_tie = use_mor ? mor[TIE] : tcr[TIE];

// Timer clock input selection
// fpin is the input to the prescaler
// Internal clock is derived from cen_div[1] (divide by 4)
wire int_clk = cen_div[1];

// Timer input mode multiplexer
wire fpin = (eff_tin == 1'b0 && eff_tie == 1'b0) ? int_clk : (eff_tin == 1'b0 && eff_tie == 1'b1) ? (int_clk & timer_in) : (eff_tin == 1'b1 && eff_tie == 1'b0) ? 1'b0 : timer_in;

//------------------------------------------------------------------------
// Prescaler Output Multiplexer:
// The 7-bit prescaler provides taps at each bit position. TCR[2:0]
// (or MOR[2:0] when TOPT=1) selects which tap feeds the counter.
// This provides divide ratios of 1, 2, 4, 8, 16, 32, 64, or 128.
//------------------------------------------------------------------------
wire [7:0] prescaler_taps = {prescaler, fpin}; // Bits 7:1 = prescaler, bit 0 = fpin

// Effective prescaler select (MOR or TCR)
wire [2:0] pres_sel = use_mor ? mor[2:0] : tcr[2:0];

// Selected prescaler output (feeds counter decrement)
wire prmx = prescaler_taps[pres_sel];

//------------------------------------------------------------------------
// Timer Interrupt Output:
// TIRQ is active when TIR=1 (interrupt pending) AND TIM=0 (not masked).
// This is a level-sensitive interrupt that remains active until TIR
// is cleared by software writing 0 to TCR[7].
//------------------------------------------------------------------------
assign tirq = tcr[TIR] & ~tcr[TIM];

//------------------------------------------------------------------------
// Counter Decrement Value:
// Pre-computed next TDR value for underflow detection.
//------------------------------------------------------------------------
wire [7:0] next_tdr = tdr - 8'd1;

//------------------------------------------------------------------------
// Timer Operation:
// On reset: TDR=$FF, prescaler=$7F, TIM=1 (masked), TIR=0.
// Prescaler increments on rising edge of input clock (fpin).
// Counter decrements on rising edge of selected prescaler tap.
// TIR is set when counter transitions through $00 (underflow).
//------------------------------------------------------------------------
always @(posedge clk) begin
    if(rst) begin
        // Reset state per datasheet
        tdr <= 8'hFF;       // Counter = $FF
        tcr <= 8'h40;       // TIM=1 (masked), TIR=0, others=0
        prescaler <= 7'h7F; // Prescaler = $7F
        cen_div <= 2'b00;
        fpin_last <= 1'b0;
        prmx_last <= 1'b0;
    end else begin
        // Internal clock divider (runs unless STOP instruction)
        if(cen && !tstop) begin
            cen_div <= cen_div + 2'd1;
        end

        // Edge detection for prescaler input
        fpin_last <= fpin;
        prmx_last <= prmx;

        // Prescaler increments on rising edge of fpin
        if(fpin && !fpin_last) begin
            prescaler <= prescaler + 7'd1;
        end

        // Counter decrements on rising edge of selected prescaler tap
        if(prmx && !prmx_last) begin
            tdr <= next_tdr;
            // Set TIR when counter underflows (transitions to $00)
            if(next_tdr == 8'h00) begin
                tcr[TIR] <= 1'b1;
            end
        end

        // Register writes
        if(cen && cs && wr) begin
            if(addr == 1'b0) begin
                // TDR write ($08): load counter with new value
                tdr <= din;
            end else begin
                // TCR write ($09)
                // TIR and TIM are always writable
                // TCR[5:0] may come from MOR if TOPT is set
                if(use_mor) begin
                    tcr <= {din[7:6], mor[5:0]};
                end else begin
                    tcr <= din;
                end

                // Prescaler clear: writing 1 to bit 3 clears prescaler
                // This allows truncation-free counting when changing settings
                if(din[PSC]) begin
                    prescaler <= 7'h00;
                end
            end
        end
    end
end

//------------------------------------------------------------------------
// Register Read:
// TDR returns current counter value (can be read without disturbing count).
// TCR returns control/status bits; PSC (bit 3) always reads as 0.
//------------------------------------------------------------------------
always @(*) begin
    if(addr == 1'b0) begin
        // TDR read ($08)
        dout = tdr;
    end else begin
        // TCR read ($09)
        // Bit 3 (PSC) always reads as 0
        dout = {tcr[7:4], 1'b0, tcr[2:0]};
    end
end

endmodule
