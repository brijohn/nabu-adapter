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
//  Purely combinational 8-bit arithmetic logic unit for the MC68705P3.
//
//  The ALU receives two 8-bit operands (A, B), a 5-bit operation select,
//  and carry/half-carry inputs from the condition code register. It produces
//  an 8-bit result and four flag outputs (C, H, Z, N) that update the CCR.
//
//  Supported operations include arithmetic (ADD, ADC, SUB, SBC, INC, DEC,
//  NEG), logical (AND, ORA, EOR, COM, CLR), and shift/rotate (LSL, LSR,
//  ASR, ROL, ROR). Flag behavior follows M6805 specifications exactly.
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//============================================================================

module x6805_alu (
    // Operand Interface
    input  wire [7:0] a,    // Primary operand (accumulator or memory)
    input  wire [7:0] b,    // Secondary operand (memory)

    // Control Interface
    input  wire [4:0] op,   // ALU operation select
    input  wire       cin,  // Carry input
    input  wire       hin,  // Half-carry input (for DAA if needed)

    // Result Interface
    output reg  [7:0] result,

    // Flags Interface
    output reg        cout, // Carry out
    output reg        hout, // Half-carry out
    output wire       zout, // Zero flag
    output wire       nout  // Negative flag
);

//------------------------------------------------------------------------
// ALU Operation Codes:
// 5-bit encoding allows 18 distinct operations. CPU state machine
// selects operation based on decoded instruction opcode.
//------------------------------------------------------------------------
localparam [4:0]
    ALU_ADD  = 5'h00, // A + B
    ALU_ADC  = 5'h01, // A + B + C
    ALU_SUB  = 5'h02, // A - B
    ALU_SBC  = 5'h03, // A - B - C
    ALU_AND  = 5'h04, // A & B
    ALU_ORA  = 5'h05, // A | B
    ALU_EOR  = 5'h06, // A ^ B
    ALU_COM  = 5'h07, // ~A (ones complement)
    ALU_NEG  = 5'h08, // 0 - A (twos complement)
    ALU_INC  = 5'h09, // A + 1
    ALU_DEC  = 5'h0A, // A - 1
    ALU_CLR  = 5'h0B, // Clear (result = 0)
    ALU_LSL  = 5'h0C, // Logical/Arithmetic Shift Left
    ALU_LSR  = 5'h0D, // Logical Shift Right
    ALU_ASR  = 5'h0E, // Arithmetic Shift Right
    ALU_ROL  = 5'h0F, // Rotate Left through Carry
    ALU_ROR  = 5'h10, // Rotate Right through Carry
    ALU_PASS = 5'h11; // Pass A through (for LDA, TST, etc.)

//------------------------------------------------------------------------
// Arithmetic Intermediate Signals:
// 9-bit results capture carry/borrow out of bit 7. 5-bit lower nibble
// results capture half-carry out of bit 3 for BCD operations.
//------------------------------------------------------------------------
wire [8:0] add_result; // 9-bit result for ADD/ADC
wire [8:0] sub_result; // 9-bit result for SUB/SBC
wire [4:0] add_lo;     // Lower nibble add for half-carry
wire [4:0] sub_lo;     // Lower nibble sub for half-carry

// ADD: A + B + carry_in
wire add_cin = (op == ALU_ADC) ? cin : 1'b0;

assign add_result = {1'b0, a} + {1'b0, b} + {8'b0, add_cin};
assign add_lo = {1'b0, a[3:0]} + {1'b0, b[3:0]} + {4'b0, add_cin};

// SUB: A - B - carry_in (borrow)
wire sub_cin = (op == ALU_SBC) ? cin : 1'b0;

assign sub_result = {1'b0, a} - {1'b0, b} - {8'b0, sub_cin};
assign sub_lo = {1'b0, a[3:0]} - {1'b0, b[3:0]} - {4'b0, sub_cin};

//------------------------------------------------------------------------
// ALU Operation:
// Combinational logic selects result and flag outputs based on op code.
// Default preserves carry and half-carry for operations that don't
// affect them (INC, DEC, logical operations, shifts).
//------------------------------------------------------------------------
always @(*) begin
    // Default values
    result = 8'h00;
    cout   = cin; // Preserve carry by default
    hout   = hin; // Preserve half-carry by default

    case(op)
        //----------------------------------------------------------------
        // Arithmetic Operations:
        // ADD/ADC set C on carry out of bit 7, H on carry out of bit 3.
        // SUB/SBC set C on borrow (when |B| > |A|), H unaffected.
        // INC/DEC do not affect C or H flags per M6805 specification.
        //----------------------------------------------------------------
        ALU_ADD: begin
            result = add_result[7:0];
            cout = add_result[8];
            hout = add_lo[4];
        end

        ALU_ADC: begin
            result = add_result[7:0];
            cout = add_result[8];
            hout = add_lo[4];
        end

        ALU_SUB: begin
            result = sub_result[7:0];
            cout = sub_result[8]; // Borrow flag
            hout = hin;           // H not affected by SUB
        end

        ALU_SBC: begin
            result = sub_result[7:0];
            cout = sub_result[8]; // Borrow flag
            hout = hin;           // H not affected by SBC
        end

        ALU_INC: begin
            result = a + 8'h01;
            cout = cin;           // C not affected by INC
            hout = hin;           // H not affected by INC
        end

        ALU_DEC: begin
            result = a - 8'h01;
            cout = cin;           // C not affected by DEC
            hout = hin;           // H not affected by DEC
        end

        ALU_NEG: begin
            // NEG: 0 - A (twos complement)
            // C is set if result != 0 (i.e., there was a borrow)
            result = 8'h00 - a;
            cout = |a;            // C=1 unless A was 0
            hout = hin;           // H not affected
        end

        //----------------------------------------------------------------
        // Logical Operations:
        // AND, ORA, EOR do not affect C or H flags.
        // COM always sets C flag per M6805 specification.
        // CLR does not affect C flag.
        //----------------------------------------------------------------
        ALU_AND: begin
            result = a & b;
            cout = cin;           // C not affected
            hout = hin;           // H not affected
        end

        ALU_ORA: begin
            result = a | b;
            cout = cin;           // C not affected
            hout = hin;           // H not affected
        end

        ALU_EOR: begin
            result = a ^ b;
            cout = cin;           // C not affected
            hout = hin;           // H not affected
        end

        ALU_COM: begin
            // COM: Ones complement, C is always set
            result = ~a;
            cout = 1'b1;          // C always set
            hout = hin;           // H not affected
        end

        ALU_CLR: begin
            // CLR: Result is 0, N=0, Z=1, C not affected
            result = 8'h00;
            cout = cin;           // C not affected
            hout = hin;           // H not affected
        end

        //----------------------------------------------------------------
        // Shift and Rotate Operations:
        // All shifts/rotates load C from the bit shifted out.
        // LSL/ASL: bit 7 -> C, 0 -> bit 0
        // LSR: 0 -> bit 7, bit 0 -> C
        // ASR: bit 7 held (sign extend), bit 0 -> C
        // ROL: bit 7 -> C, C -> bit 0
        // ROR: C -> bit 7, bit 0 -> C
        //----------------------------------------------------------------
        ALU_LSL: begin
            // LSL/ASL: Shift left, 0 into bit 0, bit 7 into C
            result = {a[6:0], 1'b0};
            cout = a[7];
            hout = hin;           // H not affected
        end

        ALU_LSR: begin
            // LSR: Shift right, 0 into bit 7, bit 0 into C
            result = {1'b0, a[7:1]};
            cout = a[0];
            hout = hin;           // H not affected
        end

        ALU_ASR: begin
            // ASR: Shift right, bit 7 held (sign extend), bit 0 into C
            result = {a[7], a[7:1]};
            cout = a[0];
            hout = hin;           // H not affected
        end

        ALU_ROL: begin
            // ROL: Rotate left through carry
            result = {a[6:0], cin};
            cout = a[7];
            hout = hin;           // H not affected
        end

        ALU_ROR: begin
            // ROR: Rotate right through carry
            result = {cin, a[7:1]};
            cout = a[0];
            hout = hin;           // H not affected
        end

        //----------------------------------------------------------------
        // Pass-through:
        // Used for LDA, LDX, TST, TAX, TXA. Result equals input A,
        // flags C and H are not affected. N and Z reflect result.
        //----------------------------------------------------------------
        ALU_PASS: begin
            result = a;
            cout = cin;           // C not affected
            hout = hin;           // H not affected
        end

        default: begin
            result = a;
            cout = cin;
            hout = hin;
        end
    endcase
end

//------------------------------------------------------------------------
// N and Z Flag Generation:
// N (Negative) is set when result bit 7 is set, indicating a negative
// value in two's complement representation.
// Z (Zero) is set when all eight result bits are zero.
// Both flags are updated by all data manipulation instructions.
//------------------------------------------------------------------------
assign nout = result[7];
assign zout = (result == 8'h00);

endmodule
