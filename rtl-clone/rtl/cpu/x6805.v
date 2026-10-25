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
//  Central Processing Unit for the MC68705P3 microcomputer.
//
//  The M6805 CPU is implemented independently from I/O and memory,
//  communicating via internal address, data, and control buses. This
//  allows it to function as an independent processor core that can be
//  paired with various memory and peripheral configurations.
//
//  Architecture Overview:
//    - 8-bit data bus, 13-bit address bus (2KB address space for 68705P3)
//    - Von Neumann architecture (unified code/data memory)
//    - 5 programmer-visible registers: A, X, PC, SP, CCR
//    - 88 instructions organized by addressing mode
//    - Hardware interrupt support with priority (Timer > External)
//    - Stack in RAM at $40-$7F (32 bytes maximum)
//
//  Instruction Sections (matching opcode map):
//    Section 1:  Registers and Reset
//    Section 2:  Instruction Fetch Cycle
//    Section 3:  Instruction Decode (Operation Types)
//    Section 4:  Inherent/Register Operations (4x/5x opcodes)
//    Section 5:  Memory Read Operations (LDA, LDX, CMP, CPX, BIT)
//    Section 6:  Memory Write Operations (STA, STX)
//    Section 7:  ALU Operations (ADD, ADC, SUB, SBC, AND, ORA, EOR)
//    Section 8:  Branch Instructions (BRA, BEQ, BNE, BCC, BCS, etc.)
//    Section 9:  Bit Manipulation (BSET, BCLR, BRSET, BRCLR)
//    Section 10: Read-Modify-Write (NEG, COM, LSR, ROR, ASR, LSL, ROL, etc.)
//    Section 11: Jump/Call Instructions (JMP, JSR, RTS, BSR)
//    Section 12: Interrupt Instructions (SWI, RTI)
//    Section 13: Control Instructions (NOP, RSP, TAX, TXA, CLC, SEC, etc.)
//
//  Cycle Timing (M146805 CMOS):
//    All timings are for CMOS version per User's Manual. HMOS timings
//    are typically 1-2 cycles longer for most instructions.
//
//  State Machine Design:
//    The CPU uses a multi-cycle state machine where each state represents
//    one bus cycle. States are organized by function: FETCH, DECODE,
//    OPERAND read, EXECUTE, and specialized states for complex operations
//    like interrupts and subroutine calls.
//
//  Reference: MC68705P3 8-BIT EPROM Micro Computer Unit Data Sheet and
//             M6805/M146805 CMOS Family User's Manual, Second Edition
//============================================================================

module x6805 (
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    // CPU Bus Interface
    output reg  [12:0] addr,
    input  wire  [7:0] din,
    output reg   [7:0] dout,
    output reg         rd,
    output reg         wr,

    // Interrupt Interface
    input  wire       irq,
    input  wire       tirq,
    output reg        irq_ack, // Pulses high when interrupt is acknowledged

    // ALU Interface
    output reg  [7:0] alu_a,
    output reg  [7:0] alu_b,
    output reg  [4:0] alu_op,
    output reg        alu_cin,
    output reg        alu_hin,
    input  wire [7:0] alu_result,
    input  wire       alu_cout,
    input  wire       alu_hout,
    input  wire       alu_zout,
    input  wire       alu_nout,

    // Timer Stop Output
    output reg tstop
);

//=========================================================================
// ALU Operation Codes:
// These codes select the operation performed by the external ALU module.
// The ALU is combinatorial - results are available in the same cycle
// that inputs are presented.
//=========================================================================
localparam [4:0]
    ALU_ADD  = 5'h00, // A + B (binary addition)
    ALU_ADC  = 5'h01, // A + B + C (add with carry)
    ALU_SUB  = 5'h02, // A - B (binary subtraction)
    ALU_SBC  = 5'h03, // A - B - C (subtract with borrow)
    ALU_AND  = 5'h04, // A & B (bitwise AND)
    ALU_ORA  = 5'h05, // A | B (bitwise OR)
    ALU_EOR  = 5'h06, // A ^ B (bitwise exclusive OR)
    ALU_COM  = 5'h07, // ~A (one's complement, $FF - A)
    ALU_NEG  = 5'h08, // 0 - A (two's complement negation)
    ALU_INC  = 5'h09, // A + 1 (increment)
    ALU_DEC  = 5'h0A, // A - 1 (decrement)
    ALU_CLR  = 5'h0B, // 0 (clear, result always zero)
    ALU_LSL  = 5'h0C, // Logical/Arithmetic Shift Left (C <- A <- 0)
    ALU_LSR  = 5'h0D, // Logical Shift Right (0 -> A -> C)
    ALU_ASR  = 5'h0E, // Arithmetic Shift Right (A7 -> A -> C, sign preserved)
    ALU_ROL  = 5'h0F, // Rotate Left through Carry (C <- A <- C)
    ALU_ROR  = 5'h10, // Rotate Right through Carry (C -> A -> C)
    ALU_PASS = 5'h11; // Pass A through unchanged (for LDA, TST, etc.)

//=========================================================================
// CPU Registers (Section 1):
// The M6805 has five programmer-visible registers. All are 8 bits except
// PC (11 bits for 68705P3) and SP (6 bits addressing $40-$7F).
//=========================================================================

//-------------------------------------------------------------------------
// Accumulator (A):
// 8-bit general purpose register for arithmetic, logic, and data transfer.
// Most ALU operations use A as both source and destination.
//-------------------------------------------------------------------------
reg [7:0] reg_a;

//-------------------------------------------------------------------------
// Index Register (X):
// 8-bit register primarily used for indexed addressing modes. Can also
// be used for temporary storage and some RMW operations. Added to offset
// to form effective address in indexed modes.
//-------------------------------------------------------------------------
reg [7:0] reg_x;

//-------------------------------------------------------------------------
// Program Counter (PC):
// Points to the next instruction to be fetched. For MC68705P3, only 11
// bits are needed ($000-$7FF), but we use 13 bits for address bus
// compatibility. Incremented after each byte fetch, loaded during jumps,
// branches, and interrupt/subroutine calls.
//-------------------------------------------------------------------------
reg [12:0] reg_pc;

//-------------------------------------------------------------------------
// Stack Pointer (SP):
// 6-bit register addressing stack area at $40-$7F (32 bytes). The actual
// stack address is $40 + SP, so SP=$3F points to $7F (top of stack).
// Pre-decrement on push (SP decrements, then write).
// Post-increment on pull (read, then SP increments).
// Reset initializes SP to $3F, so first push goes to $7F.
// Maximum stack depth: 5 subroutine calls + 1 interrupt = 15 bytes.
//-------------------------------------------------------------------------
reg [5:0] reg_sp;

//-------------------------------------------------------------------------
// Condition Code Register (CCR) Bits:
// 5 active flags in bits [4:0], upper 3 bits always read as 1.
// Format: [7:5]=111, [4]=H, [3]=I, [2]=N, [1]=Z, [0]=C
//-------------------------------------------------------------------------
reg cc_h; // Half Carry (bit 4): Set when carry occurs from bit 3 to bit 4
          // during ADD/ADC. Used for BCD arithmetic correction.
reg cc_i; // Interrupt Mask (bit 3): When set (1), maskable interrupts are
          // disabled. Set by reset, SWI, and hardware interrupts. Cleared
          // by CLI, RTI, STOP, and WAIT instructions.
reg cc_n; // Negative (bit 2): Set when result MSB is 1 (negative in signed
          // arithmetic). Reflects bit 7 of most recent result.
reg cc_z; // Zero (bit 1): Set when result is $00. Cleared otherwise.
reg cc_c; // Carry/Borrow (bit 0): Set on unsigned overflow from ADD/ADC,
          // borrow from SUB/SBC, and bit shifted out during shifts/rotates.

//-------------------------------------------------------------------------
// CCR Composition:
// Combines individual flags into full 8-bit CCR for stack operations.
// Upper 3 bits are hardwired to 1 per M6805 specification.
//-------------------------------------------------------------------------
wire [7:0] reg_ccr = {3'b111, cc_h, cc_i, cc_n, cc_z, cc_c};

//=========================================================================
// Stack Pointer Address Calculation:
// The 6-bit SP register ($00-$3F) maps to physical addresses $40-$7F.
// This 32-byte stack area resides at the top of the 112-byte RAM.
// Formula: Physical Address = $40 + SP = {7'b0000001, SP}
//=========================================================================
wire [12:0] sp_addr = {7'b0000001, reg_sp}; // $40 + reg_sp

//=========================================================================
// Interrupt Vector Addresses:
// Located at the top of address space. Each vector is 2 bytes (high:low).
// Priority: Reset (highest) > Timer > External > SWI (lowest among IRQs)
// When both Timer and External are pending, Timer is serviced first.
//=========================================================================
localparam [12:0] VEC_TIMER = 13'h07F8; // Timer interrupt: $7F8/$7F9
localparam [12:0] VEC_IRQ   = 13'h07FA; // External interrupt: $7FA/$7FB
localparam [12:0] VEC_SWI   = 13'h07FC; // Software interrupt: $7FC/$7FD
localparam [12:0] VEC_RESET = 13'h07FE; // Reset vector: $7FE/$7FF

//=========================================================================
// CPU State Machine States:
// Each state represents one bus cycle. The state machine implements
// the multi-cycle execution of M6805 instructions with proper timing.
//=========================================================================
localparam [4:0]
    //---------------------------------------------------------------------
    // Reset and Vector Fetch States:
    //---------------------------------------------------------------------
    ST_RESET     = 5'd0,  // Initial reset state, prepare vector fetch
    ST_VEC_HI    = 5'd1,  // Fetch vector high byte (address bits [12:8])
    ST_VEC_LO    = 5'd2,  // Fetch vector low byte (address bits [7:0])

    //---------------------------------------------------------------------
    // Instruction Execution States:
    //---------------------------------------------------------------------
    ST_FETCH     = 5'd3,  // Fetch opcode from PC, check for interrupts
    ST_DECODE    = 5'd4,  // Decode opcode (unused - decode in FETCH)
    ST_OP1_RD    = 5'd5,  // Read operand byte 1 (immediate/direct/offset)
    ST_OP2_RD    = 5'd6,  // Read operand byte 2 (extended/16-bit offset)
    ST_EXECUTE   = 5'd7,  // Execute instruction, compute results
    ST_MEM_RD    = 5'd8,  // Memory read complete, data on din
    ST_MEM_WR    = 5'd9,  // Memory write active, wr=1

    //---------------------------------------------------------------------
    // Special Operation States:
    //---------------------------------------------------------------------
    ST_ACC_IDLE  = 5'd10, // Accumulator/Index RMW idle (3-cycle timing)
    ST_BIT_RD    = 5'd11, // Bit set/clear: read complete, modify and write
    ST_BIT_TST   = 5'd12, // Bit test: test bit and conditionally branch
    ST_IDX_STORE = 5'd13, // Indexed store delay (M6805 timing compatibility)

    //---------------------------------------------------------------------
    // Read-Modify-Write States:
    //---------------------------------------------------------------------
    ST_RMW_RD    = 5'd14, // RMW: Read from EA in progress
    ST_RMW_ALU   = 5'd15, // RMW: ALU compute, prepare write

    //---------------------------------------------------------------------
    // Subroutine Call/Return States:
    //---------------------------------------------------------------------
    ST_JSR_PUSH1 = 5'd16, // JSR/BSR: Push PC low byte to stack
    ST_JSR_PUSH2 = 5'd17, // JSR/BSR: Push PC high byte to stack
    ST_RTS_IDLE1 = 5'd18, // RTS: First idle (SP increment)
    ST_RTS_IDLE2 = 5'd19, // RTS: Second idle (read in progress)
    ST_RTS_PULL1 = 5'd20, // RTS: Pull PC high byte (data available)
    ST_RTS_PULL2 = 5'd21, // RTS: Pull PC low byte (data available)
    ST_BSR_IDLE  = 5'd22, // BSR: Extra idle cycle for 6-cycle timing

    //---------------------------------------------------------------------
    // Interrupt Handling States:
    // Stack order (pushed first to last): PCL, PCH, X, A, CCR
    // Pull order (RTI): CCR, A, X, PCH, PCL
    //---------------------------------------------------------------------
    ST_SWI_IDLE  = 5'd23, // SWI/IRQ: Idle cycle before stacking
    ST_INT_PUSH1 = 5'd24, // Interrupt: Push PCL
    ST_INT_PUSH2 = 5'd25, // Interrupt: Push PCH
    ST_INT_PUSH3 = 5'd26, // Interrupt: Push X
    ST_INT_PUSH4 = 5'd27, // Interrupt: Push A
    ST_INT_PUSH5 = 5'd28, // Interrupt: Push CCR, set I, fetch vector

    //---------------------------------------------------------------------
    // RTI States:
    //---------------------------------------------------------------------
    ST_RTI_PULL1 = 5'd29, // RTI: Issue read for CCR
    ST_RTI_PULL2 = 5'd30, // RTI: CCR available, pull A
    ST_RTI_PULL3 = 5'd31; // RTI: A available, pull X, start PC pull

reg [4:0] state;

//=========================================================================
// Addressing Modes:
// The M6805 supports 7 addressing modes with indexed having 3 variants.
// Mode determines how the effective address (EA) is calculated.
//=========================================================================
localparam [3:0]
    AM_INH  = 4'd0,  // Inherent: No operand, operation on internal registers
    AM_INHA = 4'd1,  // Inherent Accumulator: RMW operation on A register
    AM_INHX = 4'd2,  // Inherent Index: RMW operation on X register
    AM_IMM  = 4'd3,  // Immediate: Operand follows opcode (EA = PC+1)
    AM_DIR  = 4'd4,  // Direct: 8-bit address in page zero (EA = $00:operand)
    AM_EXT  = 4'd5,  // Extended: 16-bit absolute address (EA = op1:op2)
    AM_IX   = 4'd6,  // Indexed, no offset: EA = X
    AM_IX1  = 4'd7,  // Indexed, 8-bit offset: EA = X + operand
    AM_IX2  = 4'd8,  // Indexed, 16-bit offset: EA = X + op1:op2
    AM_REL  = 4'd9,  // Relative: PC + 2 + signed_offset (for branches)
    AM_BSC  = 4'd10, // Bit Set/Clear: Direct address with bit number in opcode
    AM_BTB  = 4'd11; // Bit Test and Branch: Direct addr + relative offset

//=========================================================================
// Operation Types:
// Decoded from opcode, determines what operation to perform. Grouped by
// function for clarity.
//=========================================================================
localparam [5:0]
    //---------------------------------------------------------------------
    // Register/Memory Operations (opcodes Ax-Fx, low nibble 0-F):
    // These use accumulator or index register with memory operand.
    //---------------------------------------------------------------------
    OP_SUB   = 6'd0,  // A = A - M (subtract)
    OP_CMP   = 6'd1,  // A - M, set flags only (compare)
    OP_SBC   = 6'd2,  // A = A - M - C (subtract with borrow)
    OP_CPX   = 6'd3,  // X - M, set flags only (compare X)
    OP_AND   = 6'd4,  // A = A & M (logical AND)
    OP_BIT   = 6'd5,  // A & M, set flags only (bit test)
    OP_LDA   = 6'd6,  // A = M (load accumulator)
    OP_STA   = 6'd7,  // M = A (store accumulator)
    OP_EOR   = 6'd8,  // A = A ^ M (exclusive OR)
    OP_ADC   = 6'd9,  // A = A + M + C (add with carry)
    OP_ORA   = 6'd10, // A = A | M (logical OR)
    OP_ADD   = 6'd11, // A = A + M (add)
    OP_JMP   = 6'd12, // PC = EA (jump)
    OP_JSR   = 6'd13, // Push PC, PC = EA (jump to subroutine)
    OP_LDX   = 6'd14, // X = M (load index register)
    OP_STX   = 6'd15, // M = X (store index register)

    //---------------------------------------------------------------------
    // Read-Modify-Write Operations (opcodes 3x-7x, low nibble):
    // Operate on memory location or register with single operand.
    //---------------------------------------------------------------------
    OP_NEG   = 6'd16, // M = 0 - M (negate, two's complement)
    OP_COM   = 6'd17, // M = ~M (complement, one's complement)
    OP_LSR   = 6'd18, // Logical shift right: 0 -> M -> C
    OP_ROR   = 6'd19, // Rotate right: C -> M -> C
    OP_ASR   = 6'd20, // Arithmetic shift right: M7 -> M -> C (sign extend)
    OP_LSL   = 6'd21, // Logical shift left: C <- M <- 0
    OP_ROL   = 6'd22, // Rotate left: C <- M <- C
    OP_DEC   = 6'd23, // M = M - 1 (decrement)
    OP_INC   = 6'd24, // M = M + 1 (increment)
    OP_TST   = 6'd25, // Test M, set N and Z flags only
    OP_CLR   = 6'd26, // M = 0 (clear)

    //---------------------------------------------------------------------
    // Branch Operations (opcodes 2x):
    // Conditional and unconditional branches using relative addressing.
    //---------------------------------------------------------------------
    OP_BRA   = 6'd27, // Branch always (unconditional)
    OP_BRN   = 6'd28, // Branch never (2-byte NOP)
    OP_BHI   = 6'd29, // Branch if higher (C=0 AND Z=0, unsigned >)
    OP_BLS   = 6'd30, // Branch if lower or same (C=1 OR Z=1, unsigned <=)
    OP_BCC   = 6'd31, // Branch if carry clear (C=0)
    OP_BCS   = 6'd32, // Branch if carry set (C=1)
    OP_BNE   = 6'd33, // Branch if not equal (Z=0)
    OP_BEQ   = 6'd34, // Branch if equal (Z=1)
    OP_BHCC  = 6'd35, // Branch if half carry clear (H=0)
    OP_BHCS  = 6'd36, // Branch if half carry set (H=1)
    OP_BPL   = 6'd37, // Branch if plus (N=0)
    OP_BMI   = 6'd38, // Branch if minus (N=1)
    OP_BMC   = 6'd39, // Branch if interrupt mask clear (I=0)
    OP_BMS   = 6'd40, // Branch if interrupt mask set (I=1)
    OP_BIL   = 6'd41, // Branch if IRQ line low (active)
    OP_BIH   = 6'd42, // Branch if IRQ line high (inactive)

    //---------------------------------------------------------------------
    // Bit Operations (opcodes 0x, 1x):
    // Test, set, or clear individual bits in direct memory.
    //---------------------------------------------------------------------
    OP_BRSET = 6'd43, // Branch if bit set (test bit, set C, branch if 1)
    OP_BRCLR = 6'd44, // Branch if bit clear (test bit, set C, branch if 0)
    OP_BSET  = 6'd45, // Set bit n in memory
    OP_BCLR  = 6'd46, // Clear bit n in memory

    //---------------------------------------------------------------------
    // Control Operations (opcodes 8x, 9x):
    // Processor control and register transfer instructions.
    //---------------------------------------------------------------------
    OP_RTI   = 6'd47, // Return from interrupt (pull CCR, A, X, PC)
    OP_RTS   = 6'd48, // Return from subroutine (pull PC)
    OP_SWI   = 6'd49, // Software interrupt (push all, vector $7FC)
    OP_STOP  = 6'd50, // Stop oscillator, enter low power mode
    OP_WAIT  = 6'd51, // Wait for interrupt, low power mode
    OP_TAX   = 6'd52, // Transfer A to X
    OP_TXA   = 6'd53, // Transfer X to A
    OP_CLC   = 6'd54, // Clear carry flag (C=0)
    OP_SEC   = 6'd55, // Set carry flag (C=1)
    OP_CLI   = 6'd56, // Clear interrupt mask (I=0, enable interrupts)
    OP_SEI   = 6'd57, // Set interrupt mask (I=1, disable interrupts)
    OP_RSP   = 6'd58, // Reset stack pointer (SP=$3F)
    OP_NOP   = 6'd59, // No operation
    OP_BSR   = 6'd60, // Branch to subroutine (relative addressing)
    OP_ILL   = 6'd63; // Illegal/undefined opcode

//=========================================================================
// Internal Registers:
// Working registers used during instruction execution.
//=========================================================================
reg  [7:0] opcode;    // Current opcode being executed
reg [12:0] vec_addr;  // Vector address for reset/interrupt
reg  [7:0] operand1;  // First operand byte (immediate/address/offset)
reg  [7:0] operand2;  // Second operand byte (address low/offset low)
reg [12:0] ea;        // Effective Address calculated from addressing mode
reg  [3:0] addr_mode; // Current instruction's addressing mode
reg  [5:0] op_type;   // Current operation type (what to do)
reg  [2:0] bit_idx;   // Bit index (0-7) for bit manipulation instructions

//=========================================================================
// Opcode Decode Helpers:
// Split opcode into nibbles for easier decode logic.
//=========================================================================
wire [3:0] op_hi = opcode[7:4]; // High nibble determines addressing mode
wire [3:0] op_lo = opcode[3:0]; // Low nibble determines operation

//=========================================================================
// Instruction Length Reference (bytes):
//   1 byte:  Inherent, Indexed (no offset)
//   2 bytes: Immediate, Direct, Indexed (8-bit), Relative, BSC
//   3 bytes: Extended, Indexed (16-bit), BTB
//=========================================================================

//=========================================================================
// Main State Machine:
// Implements the multi-cycle instruction execution. Each case handles
// one bus cycle's worth of operations.
//=========================================================================
always @(posedge clk) begin
    if(rst) begin
        //=================================================================
        // Synchronous Reset:
        // Initialize all registers to known state per M6805 specification.
        // After reset, CPU fetches vector from $7FE/$7FF to start execution.
        //=================================================================

        // CPU Registers - A and X cleared, SP set to top of stack
        reg_a <= 8'h00;
        reg_x <= 8'h00;
        reg_pc <= 13'h0000;
        reg_sp <= 6'h3F;         // Points to $7F, first push goes there

        // Condition Code Register - I set (interrupts disabled), others cleared
        cc_h <= 1'b0;
        cc_i <= 1'b1;            // Interrupts masked on reset
        cc_n <= 1'b0;
        cc_z <= 1'b0;
        cc_c <= 1'b0;

        // Internal working registers
        opcode <= 8'h00;
        vec_addr <= VEC_RESET;
        operand1 <= 8'h00;
        operand2 <= 8'h00;
        ea <= 13'h0000;
        addr_mode <= AM_INH;
        op_type <= OP_NOP;
        bit_idx <= 3'b000;

        // Bus outputs - addr preset to reset vector for synchronous ROM
        addr <= VEC_RESET;
        dout <= 8'h00;
        rd <= 1'b0;
        wr <= 1'b0;

        // ALU outputs - idle state
        alu_a <= 8'h00;
        alu_b <= 8'h00;
        alu_op <= ALU_PASS;
        alu_cin <= 1'b0;
        alu_hin <= 1'b0;

        // Timer stop - not asserted
        tstop <= 1'b0;

        // Interrupt acknowledge - not asserted
        irq_ack <= 1'b0;

        // Begin reset sequence
        state <= ST_RESET;
    end else if(cen) begin
        //=================================================================
        // Clock Enable Active:
        // Execute one bus cycle of the state machine.
        //=================================================================

        // Default: deassert bus control signals and irq_ack each cycle
        rd <= 1'b0;
        wr <= 1'b0;
        irq_ack <= 1'b0;

        case(state)
            //=============================================================
            // ST_RESET: Begin Reset Vector Fetch
            // Issue read to reset vector address. This is the first cycle
            // after reset releases.
            //=============================================================
            ST_RESET: begin
                addr <= VEC_RESET;
                rd <= 1'b1;
                vec_addr <= VEC_RESET;
                state <= ST_VEC_HI;
            end

            //=============================================================
            // ST_VEC_HI: Read Vector High Byte
            // Vector high byte is on din. Save to PC[12:8], advance to
            // read low byte. M6805 vectors are stored big-endian.
            //=============================================================
            ST_VEC_HI: begin
                reg_pc[12:8] <= {1'b0, din[3:0]}; // Only 4 bits used for 2KB
                addr <= vec_addr + 1;
                rd <= 1'b1;
                state <= ST_VEC_LO;
            end

            //=============================================================
            // ST_VEC_LO: Read Vector Low Byte
            // Vector low byte is on din. Combine with high byte to form
            // complete PC. Set up address for first instruction fetch.
            //=============================================================
            ST_VEC_LO: begin
                reg_pc[7:0] <= din;
                // Set up address for first instruction fetch
                addr <= {reg_pc[12:8], din};
                rd <= 1'b1;
                state <= ST_FETCH;
            end

            //=============================================================
            // ST_FETCH: Instruction Fetch and Decode (Section 2)
            // - Opcode is available on din (from previous cycle's read)
            // - Check for pending interrupts before decode
            // - Decode opcode to determine addressing mode and operation
            // - Set up next read or go to execute based on instruction
            //
            // M6805 Opcode Map (high nibble determines addressing mode):
            //   0x = BRSET/BRCLR (BTB)     8x = Control (INH)
            //   1x = BSET/BCLR (BSC)       9x = Control (INH)
            //   2x = Branches (REL)        Ax = Register/Mem (IMM)
            //   3x = RMW (DIR)             Bx = Register/Mem (DIR)
            //   4x = RMW (A)               Cx = Register/Mem (EXT)
            //   5x = RMW (X)               Dx = Register/Mem (IX2)
            //   6x = RMW (IX1)             Ex = Register/Mem (IX1)
            //   7x = RMW (IX)              Fx = Register/Mem (IX)
            //=============================================================
            ST_FETCH: begin
                //-----------------------------------------------------
                // Hardware Interrupt Check:
                // Check for pending interrupts before instruction decode.
                // Interrupts only serviced when I flag is clear.
                // Timer interrupt (TIRQ) has priority over external (IRQ).
                //-----------------------------------------------------
                if(!cc_i && (tirq || irq)) begin
                    // Hardware interrupt pending and enabled
                    // Select vector (TIRQ has priority over IRQ)
                    vec_addr <= tirq ? VEC_TIMER : VEC_IRQ;
                    // Pulse interrupt acknowledge for one cycle
                    irq_ack <= 1'b1;
                    // Begin interrupt stacking sequence
                    // PC already points to next instruction (return address)
                    state <= ST_SWI_IDLE;
                end else begin
                    //-----------------------------------------------------
                    // Normal Instruction Decode (Section 3):
                    // Latch opcode, increment PC, decode addressing mode
                    // and operation type based on opcode nibbles.
                    //-----------------------------------------------------
                    opcode <= din;
                    reg_pc <= reg_pc + 1;

                    // Decode based on HIGH nibble (primary addressing mode)
                    case(din[7:4])
                        //-----------------------------------------------------
                        // 0x: Bit Test and Branch (BRSET/BRCLR) - 3 bytes, 5 cycles
                        // Opcode encodes: [7:4]=0, [3:1]=bit number, [0]=sense
                        // Bit 0: 0=BRSET (branch if set), 1=BRCLR (branch if clear)
                        //-----------------------------------------------------
                        4'h0: begin
                            addr_mode <= AM_BTB;
                            op_type <= din[0] ? OP_BRCLR : OP_BRSET;
                            bit_idx <= din[3:1];
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // 1x: Bit Set/Clear (BSET/BCLR) - 2 bytes, 5 cycles
                        // Opcode encodes: [7:4]=1, [3:1]=bit number, [0]=sense
                        // Bit 0: 0=BSET (set bit), 1=BCLR (clear bit)
                        //-----------------------------------------------------
                        4'h1: begin
                            addr_mode <= AM_BSC;
                            op_type <= din[0] ? OP_BCLR : OP_BSET;
                            bit_idx <= din[3:1];
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // 2x: Branch Instructions - 2 bytes, 3 cycles
                        // Low nibble determines branch condition.
                        // All branches take same time whether taken or not.
                        //-----------------------------------------------------
                        4'h2: begin
                            addr_mode <= AM_REL;
                            case(din[3:0])
                                4'h0: op_type <= OP_BRA;  // Branch always
                                4'h1: op_type <= OP_BRN;  // Branch never
                                4'h2: op_type <= OP_BHI;  // Branch if higher
                                4'h3: op_type <= OP_BLS;  // Branch if lower/same
                                4'h4: op_type <= OP_BCC;  // Branch if C clear
                                4'h5: op_type <= OP_BCS;  // Branch if C set
                                4'h6: op_type <= OP_BNE;  // Branch if not equal
                                4'h7: op_type <= OP_BEQ;  // Branch if equal
                                4'h8: op_type <= OP_BHCC; // Branch if H clear
                                4'h9: op_type <= OP_BHCS; // Branch if H set
                                4'hA: op_type <= OP_BPL;  // Branch if plus
                                4'hB: op_type <= OP_BMI;  // Branch if minus
                                4'hC: op_type <= OP_BMC;  // Branch if I clear
                                4'hD: op_type <= OP_BMS;  // Branch if I set
                                4'hE: op_type <= OP_BIL;  // Branch if IRQ low
                                4'hF: op_type <= OP_BIH;  // Branch if IRQ high
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // 3x: RMW Direct - 2 bytes, 5 cycles
                        // Read-modify-write on direct (page zero) memory.
                        // Low nibble determines operation.
                        //-----------------------------------------------------
                        4'h3: begin
                            addr_mode <= AM_DIR;
                            case(din[3:0])
                                4'h0: op_type <= OP_NEG;
                                4'h3: op_type <= OP_COM;
                                4'h4: op_type <= OP_LSR;
                                4'h6: op_type <= OP_ROR;
                                4'h7: op_type <= OP_ASR;
                                4'h8: op_type <= OP_LSL;
                                4'h9: op_type <= OP_ROL;
                                4'hA: op_type <= OP_DEC;
                                4'hC: op_type <= OP_INC;
                                4'hD: op_type <= OP_TST;
                                4'hF: op_type <= OP_CLR;
                                default: op_type <= OP_ILL;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // 4x: RMW Accumulator (Section 4) - 1 byte, 3 cycles
                        // Read-modify-write on accumulator A.
                        // Set up ALU now, execute next cycle.
                        //-----------------------------------------------------
                        4'h4: begin
                            addr_mode <= AM_INHA;
                            alu_a <= reg_a;
                            alu_cin <= cc_c;
                            case(din[3:0])
                                4'h0: begin op_type <= OP_NEG; alu_op <= ALU_NEG; end
                                4'h3: begin op_type <= OP_COM; alu_op <= ALU_COM; end
                                4'h4: begin op_type <= OP_LSR; alu_op <= ALU_LSR; end
                                4'h6: begin op_type <= OP_ROR; alu_op <= ALU_ROR; end
                                4'h7: begin op_type <= OP_ASR; alu_op <= ALU_ASR; end
                                4'h8: begin op_type <= OP_LSL; alu_op <= ALU_LSL; end
                                4'h9: begin op_type <= OP_ROL; alu_op <= ALU_ROL; end
                                4'hA: begin op_type <= OP_DEC; alu_op <= ALU_DEC; end
                                4'hC: begin op_type <= OP_INC; alu_op <= ALU_INC; end
                                4'hD: begin op_type <= OP_TST; alu_op <= ALU_PASS; end
                                4'hF: begin op_type <= OP_CLR; alu_op <= ALU_CLR; end
                                default: begin op_type <= OP_ILL; alu_op <= ALU_PASS; end
                            endcase
                            // M6805 CMOS: 3 cycles - add idle cycle for timing
                            state <= ST_ACC_IDLE;
                        end

                        //-----------------------------------------------------
                        // 5x: RMW Index Register (Section 4) - 1 byte, 3 cycles
                        // Read-modify-write on index register X.
                        // Set up ALU now, execute next cycle.
                        //-----------------------------------------------------
                        4'h5: begin
                            addr_mode <= AM_INHX;
                            alu_a <= reg_x;
                            alu_cin <= cc_c;
                            case(din[3:0])
                                4'h0: begin op_type <= OP_NEG; alu_op <= ALU_NEG; end
                                4'h3: begin op_type <= OP_COM; alu_op <= ALU_COM; end
                                4'h4: begin op_type <= OP_LSR; alu_op <= ALU_LSR; end
                                4'h6: begin op_type <= OP_ROR; alu_op <= ALU_ROR; end
                                4'h7: begin op_type <= OP_ASR; alu_op <= ALU_ASR; end
                                4'h8: begin op_type <= OP_LSL; alu_op <= ALU_LSL; end
                                4'h9: begin op_type <= OP_ROL; alu_op <= ALU_ROL; end
                                4'hA: begin op_type <= OP_DEC; alu_op <= ALU_DEC; end
                                4'hC: begin op_type <= OP_INC; alu_op <= ALU_INC; end
                                4'hD: begin op_type <= OP_TST; alu_op <= ALU_PASS; end
                                4'hF: begin op_type <= OP_CLR; alu_op <= ALU_CLR; end
                                default: begin op_type <= OP_ILL; alu_op <= ALU_PASS; end
                            endcase
                            // M6805 CMOS: 3 cycles - add idle cycle
                            state <= ST_ACC_IDLE;
                        end

                        //-----------------------------------------------------
                        // 6x: RMW Indexed 8-bit (Section 10) - 2 bytes, 6 cycles
                        // EA = X + 8-bit offset. Need to fetch offset byte.
                        //-----------------------------------------------------
                        4'h6: begin
                            addr_mode <= AM_IX1;
                            case(din[3:0])
                                4'h0: op_type <= OP_NEG;
                                4'h3: op_type <= OP_COM;
                                4'h4: op_type <= OP_LSR;
                                4'h6: op_type <= OP_ROR;
                                4'h7: op_type <= OP_ASR;
                                4'h8: op_type <= OP_LSL;
                                4'h9: op_type <= OP_ROL;
                                4'hA: op_type <= OP_DEC;
                                4'hC: op_type <= OP_INC;
                                4'hD: op_type <= OP_TST;
                                4'hF: op_type <= OP_CLR;
                                default: op_type <= OP_ILL;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // 7x: RMW Indexed no offset (Section 10) - 1 byte, 5 cycles
                        // EA = X (no offset). Need delay cycle for timing.
                        //-----------------------------------------------------
                        4'h7: begin
                            addr_mode <= AM_IX;
                            ea <= {5'b0, reg_x};
                            case(din[3:0])
                                4'h0: op_type <= OP_NEG;
                                4'h3: op_type <= OP_COM;
                                4'h4: op_type <= OP_LSR;
                                4'h6: op_type <= OP_ROR;
                                4'h7: op_type <= OP_ASR;
                                4'h8: op_type <= OP_LSL;
                                4'h9: op_type <= OP_ROL;
                                4'hA: op_type <= OP_DEC;
                                4'hC: op_type <= OP_INC;
                                4'hD: op_type <= OP_TST;
                                4'hF: op_type <= OP_CLR;
                                default: op_type <= OP_ILL;
                            endcase
                            // Delay cycle for 5-cycle timing
                            state <= ST_IDX_STORE;
                        end

                        //-----------------------------------------------------
                        // 8x: Control Instructions (Section 12, 13) - 1 byte
                        // RTI ($80), RTS ($81), SWI ($83), STOP ($8E), WAIT ($8F)
                        //-----------------------------------------------------
                        4'h8: begin
                            addr_mode <= AM_INH;
                            case(din[3:0])
                                4'h0: op_type <= OP_RTI;
                                4'h1: op_type <= OP_RTS;
                                4'h3: op_type <= OP_SWI;
                                4'hE: op_type <= OP_STOP;
                                4'hF: op_type <= OP_WAIT;
                                default: op_type <= OP_ILL;
                            endcase
                            state <= ST_EXECUTE;
                        end

                        //-----------------------------------------------------
                        // 9x: Control Instructions (Section 13) - 1 byte, 2 cycles
                        // TAX ($97), CLC ($98), SEC ($99), CLI ($9A), SEI ($9B),
                        // RSP ($9C), NOP ($9D), TXA ($9F)
                        //-----------------------------------------------------
                        4'h9: begin
                            addr_mode <= AM_INH;
                            case(din[3:0])
                                4'h7: op_type <= OP_TAX;
                                4'h8: op_type <= OP_CLC;
                                4'h9: op_type <= OP_SEC;
                                4'hA: op_type <= OP_CLI;
                                4'hB: op_type <= OP_SEI;
                                4'hC: op_type <= OP_RSP;
                                4'hD: op_type <= OP_NOP;
                                4'hF: op_type <= OP_TXA;
                                default: op_type <= OP_ILL;
                            endcase
                            state <= ST_EXECUTE;
                        end

                        //-----------------------------------------------------
                        // Ax: Register/Memory Immediate - 2 bytes, 2 cycles
                        // Exception: $AD = BSR (relative addressing, 6 cycles)
                        //-----------------------------------------------------
                        4'hA: begin
                            if(din == 8'hAD) begin
                                // BSR is special - uses relative addressing
                                addr_mode <= AM_REL;
                                op_type <= OP_BSR;
                            end else begin
                                addr_mode <= AM_IMM;
                                case(din[3:0])
                                    4'h0: op_type <= OP_SUB;
                                    4'h1: op_type <= OP_CMP;
                                    4'h2: op_type <= OP_SBC;
                                    4'h3: op_type <= OP_CPX;
                                    4'h4: op_type <= OP_AND;
                                    4'h5: op_type <= OP_BIT;
                                    4'h6: op_type <= OP_LDA;
                                    4'h7: op_type <= OP_ILL; // STA immediate invalid
                                    4'h8: op_type <= OP_EOR;
                                    4'h9: op_type <= OP_ADC;
                                    4'hA: op_type <= OP_ORA;
                                    4'hB: op_type <= OP_ADD;
                                    4'hC: op_type <= OP_ILL; // JMP immediate invalid
                                    4'hD: op_type <= OP_BSR;
                                    4'hE: op_type <= OP_LDX;
                                    4'hF: op_type <= OP_ILL; // STX immediate invalid
                                endcase
                            end
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // Bx: Register/Memory Direct - 2 bytes, 3-5 cycles
                        // EA = $00:operand (page zero addressing)
                        //-----------------------------------------------------
                        4'hB: begin
                            addr_mode <= AM_DIR;
                            case(din[3:0])
                                4'h0: op_type <= OP_SUB;
                                4'h1: op_type <= OP_CMP;
                                4'h2: op_type <= OP_SBC;
                                4'h3: op_type <= OP_CPX;
                                4'h4: op_type <= OP_AND;
                                4'h5: op_type <= OP_BIT;
                                4'h6: op_type <= OP_LDA;
                                4'h7: op_type <= OP_STA;
                                4'h8: op_type <= OP_EOR;
                                4'h9: op_type <= OP_ADC;
                                4'hA: op_type <= OP_ORA;
                                4'hB: op_type <= OP_ADD;
                                4'hC: op_type <= OP_JMP;
                                4'hD: op_type <= OP_JSR;
                                4'hE: op_type <= OP_LDX;
                                4'hF: op_type <= OP_STX;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // Cx: Register/Memory Extended - 3 bytes, 4-6 cycles
                        // EA = operand1:operand2 (full 16-bit address)
                        //-----------------------------------------------------
                        4'hC: begin
                            addr_mode <= AM_EXT;
                            case(din[3:0])
                                4'h0: op_type <= OP_SUB;
                                4'h1: op_type <= OP_CMP;
                                4'h2: op_type <= OP_SBC;
                                4'h3: op_type <= OP_CPX;
                                4'h4: op_type <= OP_AND;
                                4'h5: op_type <= OP_BIT;
                                4'h6: op_type <= OP_LDA;
                                4'h7: op_type <= OP_STA;
                                4'h8: op_type <= OP_EOR;
                                4'h9: op_type <= OP_ADC;
                                4'hA: op_type <= OP_ORA;
                                4'hB: op_type <= OP_ADD;
                                4'hC: op_type <= OP_JMP;
                                4'hD: op_type <= OP_JSR;
                                4'hE: op_type <= OP_LDX;
                                4'hF: op_type <= OP_STX;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // Dx: Register/Memory Indexed 16-bit - 3 bytes, 5-6 cycles
                        // EA = X + operand1:operand2
                        //-----------------------------------------------------
                        4'hD: begin
                            addr_mode <= AM_IX2;
                            case(din[3:0])
                                4'h0: op_type <= OP_SUB;
                                4'h1: op_type <= OP_CMP;
                                4'h2: op_type <= OP_SBC;
                                4'h3: op_type <= OP_CPX;
                                4'h4: op_type <= OP_AND;
                                4'h5: op_type <= OP_BIT;
                                4'h6: op_type <= OP_LDA;
                                4'h7: op_type <= OP_STA;
                                4'h8: op_type <= OP_EOR;
                                4'h9: op_type <= OP_ADC;
                                4'hA: op_type <= OP_ORA;
                                4'hB: op_type <= OP_ADD;
                                4'hC: op_type <= OP_JMP;
                                4'hD: op_type <= OP_JSR;
                                4'hE: op_type <= OP_LDX;
                                4'hF: op_type <= OP_STX;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // Ex: Register/Memory Indexed 8-bit - 2 bytes, 4-5 cycles
                        // EA = X + operand (8-bit offset)
                        //-----------------------------------------------------
                        4'hE: begin
                            addr_mode <= AM_IX1;
                            case(din[3:0])
                                4'h0: op_type <= OP_SUB;
                                4'h1: op_type <= OP_CMP;
                                4'h2: op_type <= OP_SBC;
                                4'h3: op_type <= OP_CPX;
                                4'h4: op_type <= OP_AND;
                                4'h5: op_type <= OP_BIT;
                                4'h6: op_type <= OP_LDA;
                                4'h7: op_type <= OP_STA;
                                4'h8: op_type <= OP_EOR;
                                4'h9: op_type <= OP_ADC;
                                4'hA: op_type <= OP_ORA;
                                4'hB: op_type <= OP_ADD;
                                4'hC: op_type <= OP_JMP;
                                4'hD: op_type <= OP_JSR;
                                4'hE: op_type <= OP_LDX;
                                4'hF: op_type <= OP_STX;
                            endcase
                            addr <= reg_pc + 1;
                            rd <= 1'b1;
                            state <= ST_OP1_RD;
                        end

                        //-----------------------------------------------------
                        // Fx: Register/Memory Indexed no offset - 1 byte, 3-4 cycles
                        // EA = X (no offset byte)
                        //-----------------------------------------------------
                        4'hF: begin
                            addr_mode <= AM_IX;
                            ea <= {5'b0, reg_x};
                            case(din[3:0])
                                4'h0: op_type <= OP_SUB;
                                4'h1: op_type <= OP_CMP;
                                4'h2: op_type <= OP_SBC;
                                4'h3: op_type <= OP_CPX;
                                4'h4: op_type <= OP_AND;
                                4'h5: op_type <= OP_BIT;
                                4'h6: op_type <= OP_LDA;
                                4'h7: op_type <= OP_STA;
                                4'h8: op_type <= OP_EOR;
                                4'h9: op_type <= OP_ADC;
                                4'hA: op_type <= OP_ORA;
                                4'hB: op_type <= OP_ADD;
                                4'hC: op_type <= OP_JMP;
                                4'hD: op_type <= OP_JSR;
                                4'hE: op_type <= OP_LDX;
                                4'hF: op_type <= OP_STX;
                            endcase
                            // Stores and JSR need extra delay cycle for M6805 timing
                            if(din[3:0] == 4'h7 || din[3:0] == 4'hD || din[3:0] == 4'hF)
                                state <= ST_IDX_STORE;
                            else
                                state <= ST_EXECUTE;
                        end

                        default: begin
                            op_type <= OP_ILL;
                            state <= ST_FETCH;
                        end
                    endcase
                end // end else (normal instruction decode)
            end

            //=============================================================
            // ST_ACC_IDLE: Accumulator/Index RMW Idle Cycle (Section 4)
            // M6805 CMOS timing requires 3 cycles for register RMW ops.
            // ALU inputs were set up in ST_FETCH. This idle cycle allows
            // proper timing before results are stored in ST_EXECUTE.
            //=============================================================
            ST_ACC_IDLE: begin
                state <= ST_EXECUTE;
            end

            //=============================================================
            // ST_OP1_RD: Read First Operand Byte
            // - Latch operand from data bus (din)
            // - Increment PC past operand
            // - Calculate EA or fetch second operand depending on mode
            // - For AM_IMM: Execute immediately (2-cycle timing)
            //=============================================================
            ST_OP1_RD: begin
                operand1 <= din;
                reg_pc <= reg_pc + 1;

                case(addr_mode)
                    //-----------------------------------------------------
                    // Immediate Mode (Section 5, 7):
                    // Execute now for 2-cycle timing. Operand is the data.
                    //-----------------------------------------------------
                    AM_IMM: begin
                        // Set up for next instruction fetch
                        addr <= reg_pc + 1;
                        rd <= 1'b1;
                        state <= ST_FETCH;

                        case(op_type)
                            OP_LDA: begin
                                reg_a <= din;
                                cc_n <= din[7];
                                cc_z <= (din == 8'h00);
                            end

                            OP_LDX: begin
                                reg_x <= din;
                                cc_n <= din[7];
                                cc_z <= (din == 8'h00);
                            end

                            OP_CMP: begin
                                cc_n <= ((reg_a - din) >> 7);
                                cc_z <= (reg_a == din);
                                cc_c <= (reg_a < din);
                            end

                            OP_CPX: begin
                                cc_n <= ((reg_x - din) >> 7);
                                cc_z <= (reg_x == din);
                                cc_c <= (reg_x < din);
                            end

                            OP_BIT: begin
                                cc_n <= ((reg_a & din) >> 7);
                                cc_z <= ((reg_a & din) == 8'h00);
                            end

                            // Section 7: ALU Operations (Immediate Mode)
                            OP_ADD: begin
                                reg_a <= reg_a + din;
                                cc_n <= ((reg_a + din) >> 7);
                                cc_z <= ((reg_a + din) == 8'h00);
                                cc_c <= (({1'b0, reg_a} + {1'b0, din}) >> 8);
                                cc_h <= (({1'b0, reg_a[3:0]} + {1'b0, din[3:0]}) >> 4);
                            end

                            OP_ADC: begin
                                reg_a <= reg_a + din + {7'b0, cc_c};
                                cc_n <= ((reg_a + din + {7'b0, cc_c}) >> 7);
                                cc_z <= ((reg_a + din + {7'b0, cc_c}) == 8'h00);
                                cc_c <= (({1'b0, reg_a} + {1'b0, din} + {8'b0, cc_c}) >> 8);
                                cc_h <= (({1'b0, reg_a[3:0]} + {1'b0, din[3:0]} + {4'b0, cc_c}) >> 4);
                            end

                            OP_SUB: begin
                                reg_a <= reg_a - din;
                                cc_n <= ((reg_a - din) >> 7);
                                cc_z <= ((reg_a - din) == 8'h00);
                                cc_c <= (reg_a < din);
                            end

                            OP_SBC: begin
                                reg_a <= reg_a - din - {7'b0, cc_c};
                                cc_n <= ((reg_a - din - {7'b0, cc_c}) >> 7);
                                cc_z <= ((reg_a - din - {7'b0, cc_c}) == 8'h00);
                                cc_c <= ({1'b0, reg_a} < ({1'b0, din} + {8'b0, cc_c}));
                            end

                            OP_AND: begin
                                reg_a <= reg_a & din;
                                cc_n <= ((reg_a & din) >> 7);
                                cc_z <= ((reg_a & din) == 8'h00);
                            end

                            OP_ORA: begin
                                reg_a <= reg_a | din;
                                cc_n <= ((reg_a | din) >> 7);
                                cc_z <= ((reg_a | din) == 8'h00);
                            end

                            OP_EOR: begin
                                reg_a <= reg_a ^ din;
                                cc_n <= ((reg_a ^ din) >> 7);
                                cc_z <= ((reg_a ^ din) == 8'h00);
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // Direct Mode (Section 5, 6, 7, 10):
                    // Operand is 8-bit address in page zero.
                    //-----------------------------------------------------
                    AM_DIR: begin
                        ea <= {5'b0, din};

                        case(op_type)
                            // Memory read operations - issue read now
                            OP_LDA, OP_LDX, OP_CMP, OP_CPX, OP_BIT,
                            OP_ADD, OP_ADC, OP_SUB, OP_SBC, OP_AND, OP_ORA, OP_EOR: begin
                                addr <= {5'b0, din};
                                rd <= 1'b1;
                                state <= ST_MEM_RD;
                            end
                            // Section 10: RMW direct - issue read to EA
                            OP_NEG, OP_COM, OP_LSR, OP_ROR, OP_ASR,
                            OP_LSL, OP_ROL, OP_DEC, OP_INC, OP_TST, OP_CLR: begin
                                addr <= {5'b0, din};
                                rd <= 1'b1;
                                state <= ST_RMW_RD;
                            end
                            // JMP dir: 2 cycles - jump directly
                            OP_JMP: begin
                                reg_pc <= {5'b0, din};
                                addr <= {5'b0, din};
                                rd <= 1'b1;
                                state <= ST_FETCH;
                            end
                            default: begin
                                state <= ST_EXECUTE;
                            end
                        endcase
                    end

                    //-----------------------------------------------------
                    // Extended Mode:
                    // Need second byte for full 16-bit address.
                    //-----------------------------------------------------
                    AM_EXT: begin
                        addr <= reg_pc + 1;
                        rd <= 1'b1;
                        state <= ST_OP2_RD;
                    end

                    //-----------------------------------------------------
                    // Indexed 8-bit Mode:
                    // EA = X + operand (8-bit unsigned offset)
                    //-----------------------------------------------------
                    AM_IX1: begin
                        ea <= {5'b0, reg_x} + {5'b0, din};
                        // Stores, RMW, and JSR need extra delay cycle
                        case(op_type)
                            OP_STA, OP_STX, OP_JSR,
                            OP_NEG, OP_COM, OP_LSR, OP_ROR, OP_ASR,
                            OP_LSL, OP_ROL, OP_DEC, OP_INC, OP_TST, OP_CLR:
                                state <= ST_IDX_STORE;
                            default:
                                state <= ST_EXECUTE;
                        endcase
                    end

                    //-----------------------------------------------------
                    // Indexed 16-bit Mode:
                    // Need second byte for 16-bit offset.
                    //-----------------------------------------------------
                    AM_IX2: begin
                        addr <= reg_pc + 1;
                        rd <= 1'b1;
                        state <= ST_OP2_RD;
                    end

                    //-----------------------------------------------------
                    // Relative Mode (Section 8):
                    // Operand is signed offset from PC after this byte.
                    // EA = (PC+1) + sign_extend(offset)
                    //-----------------------------------------------------
                    AM_REL: begin
                        ea <= (reg_pc + 1) + {{5{din[7]}}, din};
                        state <= ST_EXECUTE;
                    end

                    //-----------------------------------------------------
                    // Bit Set/Clear Mode (Section 9):
                    // Operand is direct address for bit manipulation.
                    //-----------------------------------------------------
                    AM_BSC: begin
                        ea <= {5'b0, din};
                        state <= ST_EXECUTE;
                    end

                    //-----------------------------------------------------
                    // Bit Test and Branch Mode (Section 9):
                    // Need relative offset for conditional branch.
                    //-----------------------------------------------------
                    AM_BTB: begin
                        ea <= {5'b0, din}; // Direct address for bit test
                        addr <= reg_pc + 1;
                        rd <= 1'b1;
                        state <= ST_OP2_RD;
                    end

                    default: begin
                        state <= ST_EXECUTE;
                    end
                endcase
            end

            //=============================================================
            // ST_OP2_RD: Read Second Operand Byte
            // - Latch operand from data bus
            // - Increment PC
            // - Calculate final EA
            //=============================================================
            ST_OP2_RD: begin
                operand2 <= din;
                reg_pc <= reg_pc + 1;

                case(addr_mode)
                    //-----------------------------------------------------
                    // Extended Mode:
                    // EA = operand1:operand2 (high:low, big endian)
                    //-----------------------------------------------------
                    AM_EXT: begin
                        ea <= {operand1[4:0], din};

                        case(op_type)
                            // Memory read ops - issue read for 4-cycle timing
                            OP_LDA, OP_LDX, OP_CMP, OP_CPX, OP_BIT,
                            OP_ADD, OP_ADC, OP_SUB, OP_SBC, OP_AND, OP_ORA, OP_EOR: begin
                                addr <= {operand1[4:0], din};
                                rd <= 1'b1;
                                state <= ST_MEM_RD;
                            end
                            // JMP ext: 3 cycles - jump directly
                            OP_JMP: begin
                                reg_pc <= {operand1[4:0], din};
                                addr <= {operand1[4:0], din};
                                rd <= 1'b1;
                                state <= ST_FETCH;
                            end
                            default: begin
                                state <= ST_EXECUTE;
                            end
                        endcase
                    end

                    //-----------------------------------------------------
                    // Indexed 16-bit Mode:
                    // EA = X + operand1:operand2 (16-bit offset)
                    //-----------------------------------------------------
                    AM_IX2: begin
                        ea <= {5'b0, reg_x} + {operand1, din};
                        // Stores and JSR need extra delay cycle
                        if(op_type == OP_STA || op_type == OP_STX || op_type == OP_JSR)
                            state <= ST_IDX_STORE;
                        else
                            state <= ST_EXECUTE;
                    end

                    //-----------------------------------------------------
                    // Bit Test and Branch Mode (Section 9):
                    // operand2 is signed relative offset for branch.
                    //-----------------------------------------------------
                    AM_BTB: begin
                        operand2 <= din;
                        state <= ST_EXECUTE;
                    end

                    default: begin
                        state <= ST_EXECUTE;
                    end
                endcase
            end

            //=============================================================
            // ST_EXECUTE: Execute Instruction
            // Handle all addressing modes and operation types.
            // ALU results (for register RMW) are now valid.
            //=============================================================
            ST_EXECUTE: begin
                // Default: return to fetch after execution
                addr <= reg_pc;
                rd <= 1'b1;
                state <= ST_FETCH;

                case(addr_mode)
                    //-----------------------------------------------------
                    // AM_INHA: Accumulator Operations (Section 4)
                    // Store ALU results to accumulator A.
                    //-----------------------------------------------------
                    AM_INHA: begin
                        case(op_type)
                            OP_NEG: begin
                                reg_a <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= alu_cout;
                            end

                            OP_COM: begin
                                reg_a <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= 1'b1; // COM always sets C
                            end

                            OP_LSR, OP_ROR, OP_ASR, OP_LSL, OP_ROL: begin
                                reg_a <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= alu_cout;
                            end

                            OP_DEC, OP_INC: begin
                                reg_a <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                // C not affected by INC/DEC
                            end

                            OP_TST: begin
                                // Just set flags, don't modify A
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                            end

                            OP_CLR: begin
                                reg_a <= 8'h00;
                                cc_n <= 1'b0;
                                cc_z <= 1'b1;
                                cc_c <= 1'b0;
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // AM_INHX: Index Register Operations (Section 4)
                    // Store ALU results to index register X.
                    //-----------------------------------------------------
                    AM_INHX: begin
                        case(op_type)
                            OP_NEG: begin
                                reg_x <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= alu_cout;
                            end

                            OP_COM: begin
                                reg_x <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= 1'b1;
                            end

                            OP_LSR, OP_ROR, OP_ASR, OP_LSL, OP_ROL: begin
                                reg_x <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                                cc_c <= alu_cout;
                            end

                            OP_DEC, OP_INC: begin
                                reg_x <= alu_result;
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                            end

                            OP_TST: begin
                                cc_n <= alu_nout;
                                cc_z <= alu_zout;
                            end

                            OP_CLR: begin
                                reg_x <= 8'h00;
                                cc_n <= 1'b0;
                                cc_z <= 1'b1;
                                cc_c <= 1'b0;
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // AM_INH: Inherent Operations (Section 11, 12, 13)
                    //-----------------------------------------------------
                    AM_INH: begin
                        case(op_type)
                            // Section 11: RTS - 6 cycles
                            OP_RTS: begin
                                reg_sp <= reg_sp + 1;
                                state <= ST_RTS_IDLE1;
                            end

                            // Section 12: SWI - 10 cycles
                            OP_SWI: begin
                                vec_addr <= VEC_SWI;
                                state <= ST_SWI_IDLE;
                            end

                            // Section 12: RTI - 9 cycles
                            OP_RTI: begin
                                reg_sp <= reg_sp + 1;
                                state <= ST_RTI_PULL1;
                            end

                            // Section 13: Simple 2-cycle operations
                            OP_NOP: begin
                                // Do nothing
                            end

                            OP_RSP: begin
                                reg_sp <= 6'h3F;
                            end

                            OP_TAX: begin
                                reg_x <= reg_a;
                            end

                            OP_TXA: begin
                                reg_a <= reg_x;
                            end

                            OP_CLC: begin
                                cc_c <= 1'b0;
                            end

                            OP_SEC: begin
                                cc_c <= 1'b1;
                            end

                            OP_CLI: begin
                                cc_i <= 1'b0;
                            end

                            OP_SEI: begin
                                cc_i <= 1'b1;
                            end

                            // Section 13: STOP - halt CPU, stop oscillator
                            OP_STOP: begin
                                cc_i <= 1'b0;
                                tstop <= 1'b1;
                                // CPU halts here
                            end

                            // Section 13: WAIT - halt CPU, wait for interrupt
                            OP_WAIT: begin
                                cc_i <= 1'b0;
                                // CPU halts here
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // Memory Addressing Modes (Section 5, 6, 7, 10, 11)
                    //-----------------------------------------------------
                    AM_DIR, AM_EXT, AM_IX, AM_IX1, AM_IX2: begin
                        case(op_type)
                            // Memory reads
                            OP_LDA, OP_LDX, OP_CMP, OP_CPX, OP_BIT,
                            OP_ADD, OP_ADC, OP_SUB, OP_SBC, OP_AND, OP_ORA, OP_EOR: begin
                                addr <= ea;
                                rd <= 1'b1;
                                state <= ST_MEM_RD;
                            end

                            // Section 6: Memory stores
                            OP_STA: begin
                                addr <= ea;
                                dout <= reg_a;
                                wr <= 1'b1;
                                cc_n <= reg_a[7];
                                cc_z <= (reg_a == 8'h00);
                                state <= ST_MEM_WR;
                            end

                            OP_STX: begin
                                addr <= ea;
                                dout <= reg_x;
                                wr <= 1'b1;
                                cc_n <= reg_x[7];
                                cc_z <= (reg_x == 8'h00);
                                state <= ST_MEM_WR;
                            end

                            // Section 10: Read-Modify-Write
                            OP_NEG, OP_COM, OP_LSR, OP_ROR, OP_ASR,
                            OP_LSL, OP_ROL, OP_DEC, OP_INC, OP_TST, OP_CLR: begin
                                addr <= ea;
                                rd <= 1'b1;
                                state <= ST_RMW_RD;
                            end

                            // Section 11: JMP
                            OP_JMP: begin
                                reg_pc <= ea;
                                addr <= ea;
                                rd <= 1'b1;
                                state <= ST_FETCH;
                            end

                            // Section 11: JSR - push return address, jump
                            OP_JSR: begin
                                addr <= sp_addr;
                                dout <= reg_pc[7:0];
                                wr <= 1'b1;
                                reg_sp <= reg_sp - 1;
                                state <= ST_JSR_PUSH1;
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // Section 8: Branch Instructions (AM_REL)
                    //-----------------------------------------------------
                    AM_REL: begin
                        case(op_type)
                            OP_BRA: begin
                                reg_pc <= ea;
                                addr <= ea;
                            end

                            OP_BRN: begin
                                // Never branch - PC already updated
                            end

                            OP_BHI: begin
                                if(!cc_c && !cc_z) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BLS: begin
                                if(cc_c || cc_z) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BCC: begin
                                if(!cc_c) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BCS: begin
                                if(cc_c) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BNE: begin
                                if(!cc_z) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BEQ: begin
                                if(cc_z) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BHCC: begin
                                if(!cc_h) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BHCS: begin
                                if(cc_h) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BPL: begin
                                if(!cc_n) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BMI: begin
                                if(cc_n) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BMC: begin
                                if(!cc_i) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BMS: begin
                                if(cc_i) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BIL: begin
                                if(irq) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            OP_BIH: begin
                                if(!irq) begin
                                    reg_pc <= ea;
                                    addr <= ea;
                                end
                            end

                            // Section 11: BSR - 6 cycles
                            OP_BSR: begin
                                state <= ST_BSR_IDLE;
                            end

                            default: ;
                        endcase
                    end

                    //-----------------------------------------------------
                    // Section 9: Bit Set/Clear (AM_BSC)
                    //-----------------------------------------------------
                    AM_BSC: begin
                        addr <= ea;
                        rd <= 1'b1;
                        state <= ST_BIT_RD;
                    end

                    //-----------------------------------------------------
                    // Section 9: Bit Test and Branch (AM_BTB)
                    //-----------------------------------------------------
                    AM_BTB: begin
                        addr <= ea;
                        rd <= 1'b1;
                        state <= ST_BIT_TST;
                    end

                    default: ;
                endcase
            end

            //=============================================================
            // ST_MEM_RD: Memory Read Complete (Section 5, 7)
            // Data from memory is available on din.
            //=============================================================
            ST_MEM_RD: begin
                addr <= reg_pc;
                rd <= 1'b1;
                state <= ST_FETCH;

                case(op_type)
                    OP_LDA: begin
                        reg_a <= din;
                        cc_n <= din[7];
                        cc_z <= (din == 8'h00);
                    end

                    OP_LDX: begin
                        reg_x <= din;
                        cc_n <= din[7];
                        cc_z <= (din == 8'h00);
                    end

                    OP_CMP: begin
                        cc_n <= ((reg_a - din) >> 7);
                        cc_z <= (reg_a == din);
                        cc_c <= (reg_a < din);
                    end

                    OP_CPX: begin
                        cc_n <= ((reg_x - din) >> 7);
                        cc_z <= (reg_x == din);
                        cc_c <= (reg_x < din);
                    end

                    OP_BIT: begin
                        cc_n <= ((reg_a & din) >> 7);
                        cc_z <= ((reg_a & din) == 8'h00);
                    end

                    // Section 7: ALU Operations from Memory
                    OP_ADD: begin
                        reg_a <= reg_a + din;
                        cc_n <= ((reg_a + din) >> 7);
                        cc_z <= ((reg_a + din) == 8'h00);
                        cc_c <= (({1'b0, reg_a} + {1'b0, din}) >> 8);
                        cc_h <= (({1'b0, reg_a[3:0]} + {1'b0, din[3:0]}) >> 4);
                    end

                    OP_ADC: begin
                        reg_a <= reg_a + din + {7'b0, cc_c};
                        cc_n <= ((reg_a + din + {7'b0, cc_c}) >> 7);
                        cc_z <= ((reg_a + din + {7'b0, cc_c}) == 8'h00);
                        cc_c <= (({1'b0, reg_a} + {1'b0, din} + {8'b0, cc_c}) >> 8);
                        cc_h <= (({1'b0, reg_a[3:0]} + {1'b0, din[3:0]} + {4'b0, cc_c}) >> 4);
                    end

                    OP_SUB: begin
                        reg_a <= reg_a - din;
                        cc_n <= ((reg_a - din) >> 7);
                        cc_z <= ((reg_a - din) == 8'h00);
                        cc_c <= (reg_a < din);
                    end

                    OP_SBC: begin
                        reg_a <= reg_a - din - {7'b0, cc_c};
                        cc_n <= ((reg_a - din - {7'b0, cc_c}) >> 7);
                        cc_z <= ((reg_a - din - {7'b0, cc_c}) == 8'h00);
                        cc_c <= ({1'b0, reg_a} < ({1'b0, din} + {8'b0, cc_c}));
                    end

                    OP_AND: begin
                        reg_a <= reg_a & din;
                        cc_n <= ((reg_a & din) >> 7);
                        cc_z <= ((reg_a & din) == 8'h00);
                    end

                    OP_ORA: begin
                        reg_a <= reg_a | din;
                        cc_n <= ((reg_a | din) >> 7);
                        cc_z <= ((reg_a | din) == 8'h00);
                    end

                    OP_EOR: begin
                        reg_a <= reg_a ^ din;
                        cc_n <= ((reg_a ^ din) >> 7);
                        cc_z <= ((reg_a ^ din) == 8'h00);
                    end

                    default: ;
                endcase
            end

            //=============================================================
            // ST_MEM_WR: Memory Write Active (Section 6)
            // Write is happening this cycle. Deassert and fetch next.
            //=============================================================
            ST_MEM_WR: begin
                wr <= 1'b0;
                addr <= reg_pc;
                rd <= 1'b1;
                state <= ST_FETCH;
            end

            //=============================================================
            // ST_IDX_STORE: Indexed Store/RMW Delay
            // Extra cycle for M6805 timing compatibility.
            //=============================================================
            ST_IDX_STORE: begin
                case(op_type)
                    // RMW operations - issue read to EA
                    OP_NEG, OP_COM, OP_LSR, OP_ROR, OP_ASR,
                    OP_LSL, OP_ROL, OP_DEC, OP_INC, OP_TST, OP_CLR: begin
                        addr <= ea;
                        rd <= 1'b1;
                        state <= ST_RMW_RD;
                    end
                    default: begin
                        state <= ST_EXECUTE;
                    end
                endcase
            end

            //=============================================================
            // ST_RMW_RD: Read-Modify-Write Read Complete (Section 10)
            // Set up ALU for modify operation.
            //=============================================================
            ST_RMW_RD: begin
                alu_a <= din;
                alu_cin <= cc_c;

                case(op_type)
                    OP_NEG: alu_op <= ALU_NEG;
                    OP_COM: alu_op <= ALU_COM;
                    OP_LSR: alu_op <= ALU_LSR;
                    OP_ROR: alu_op <= ALU_ROR;
                    OP_ASR: alu_op <= ALU_ASR;
                    OP_LSL: alu_op <= ALU_LSL;
                    OP_ROL: alu_op <= ALU_ROL;
                    OP_DEC: alu_op <= ALU_DEC;
                    OP_INC: alu_op <= ALU_INC;
                    OP_TST: alu_op <= ALU_PASS;
                    OP_CLR: alu_op <= ALU_CLR;
                    default: alu_op <= ALU_PASS;
                endcase

                state <= ST_RMW_ALU;
            end

            //=============================================================
            // ST_RMW_ALU: Read-Modify-Write ALU Complete (Section 10)
            // Write modified result back to memory (except TST).
            //=============================================================
            ST_RMW_ALU: begin
                cc_n <= alu_nout;
                cc_z <= alu_zout;
                cc_c <= alu_cout;

                if(op_type == OP_TST) begin
                    // TST only sets flags, no write
                    addr <= reg_pc;
                    rd <= 1'b1;
                    state <= ST_FETCH;
                end else begin
                    dout <= alu_result;
                    wr <= 1'b1;
                    state <= ST_MEM_WR;
                end
            end

            //=============================================================
            // Section 11: Subroutine Call States (JSR, BSR)
            //=============================================================
            ST_JSR_PUSH1: begin
                wr <= 1'b0;
                addr <= sp_addr;
                dout <= {3'b000, reg_pc[12:8]};
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_JSR_PUSH2;
            end

            ST_JSR_PUSH2: begin
                wr <= 1'b0;
                reg_pc <= ea;
                addr <= ea;
                rd <= 1'b1;
                state <= ST_FETCH;
            end

            ST_BSR_IDLE: begin
                addr <= sp_addr;
                dout <= reg_pc[7:0];
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_JSR_PUSH1;
            end

            //=============================================================
            // Section 11: Subroutine Return States (RTS)
            //=============================================================
            ST_RTS_IDLE1: begin
                if(op_type == OP_RTI) begin
                    reg_x <= din;
                    addr <= {7'b0000001, reg_sp + 6'd1};
                end else begin
                    addr <= sp_addr;
                end
                rd <= 1'b1;
                reg_sp <= reg_sp + 1;
                state <= ST_RTS_IDLE2;
            end

            ST_RTS_IDLE2: begin
                state <= ST_RTS_PULL1;
            end

            ST_RTS_PULL1: begin
                ea[12:8] <= din[4:0];
                if(op_type == OP_RTI) begin
                    reg_sp <= reg_sp + 1;
                    addr <= {7'b0000001, reg_sp + 6'd1};
                end else begin
                    addr <= sp_addr;
                end
                rd <= 1'b1;
                state <= ST_RTS_PULL2;
            end

            ST_RTS_PULL2: begin
                reg_pc <= {ea[12:8], din};
                addr <= {ea[12:8], din};
                rd <= 1'b1;
                state <= ST_FETCH;
            end

            //=============================================================
            // Section 12: Interrupt Handling States (SWI, Hardware IRQ)
            // Stack order: PCL, PCH, X, A, CCR (5 bytes)
            //=============================================================
            ST_SWI_IDLE: begin
                addr <= sp_addr;
                dout <= reg_pc[7:0];
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_INT_PUSH1;
            end

            ST_INT_PUSH1: begin
                wr <= 1'b0;
                addr <= sp_addr;
                dout <= {3'b000, reg_pc[12:8]};
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_INT_PUSH2;
            end

            ST_INT_PUSH2: begin
                wr <= 1'b0;
                addr <= sp_addr;
                dout <= reg_x;
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_INT_PUSH3;
            end

            ST_INT_PUSH3: begin
                wr <= 1'b0;
                addr <= sp_addr;
                dout <= reg_a;
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_INT_PUSH4;
            end

            ST_INT_PUSH4: begin
                wr <= 1'b0;
                addr <= sp_addr;
                dout <= reg_ccr;
                wr <= 1'b1;
                reg_sp <= reg_sp - 1;
                state <= ST_INT_PUSH5;
            end

            ST_INT_PUSH5: begin
                wr <= 1'b0;
                cc_i <= 1'b1; // Mask further interrupts
                addr <= vec_addr;
                rd <= 1'b1;
                state <= ST_VEC_HI;
            end

            //=============================================================
            // Section 12: RTI States
            // Pull order: CCR, A, X, PCH, PCL
            //=============================================================
            ST_RTI_PULL1: begin
                addr <= sp_addr;
                rd <= 1'b1;
                state <= ST_RTI_PULL2;
            end

            ST_RTI_PULL2: begin
                cc_h <= din[4];
                cc_i <= din[3];
                cc_n <= din[2];
                cc_z <= din[1];
                cc_c <= din[0];
                reg_sp <= reg_sp + 1;
                addr <= {7'b0000001, reg_sp + 6'd1};
                rd <= 1'b1;
                state <= ST_RTI_PULL3;
            end

            ST_RTI_PULL3: begin
                reg_a <= din;
                reg_sp <= reg_sp + 1;
                addr <= {7'b0000001, reg_sp + 6'd1};
                rd <= 1'b1;
                state <= ST_RTS_IDLE1;
            end

            //=============================================================
            // Section 9: Bit Set/Clear Complete
            //=============================================================
            ST_BIT_RD: begin
                case(op_type)
                    OP_BSET: begin
                        case(bit_idx)
                            3'd0: dout <= din | 8'h01;
                            3'd1: dout <= din | 8'h02;
                            3'd2: dout <= din | 8'h04;
                            3'd3: dout <= din | 8'h08;
                            3'd4: dout <= din | 8'h10;
                            3'd5: dout <= din | 8'h20;
                            3'd6: dout <= din | 8'h40;
                            3'd7: dout <= din | 8'h80;
                        endcase
                    end

                    OP_BCLR: begin
                        case(bit_idx)
                            3'd0: dout <= din & 8'hFE;
                            3'd1: dout <= din & 8'hFD;
                            3'd2: dout <= din & 8'hFB;
                            3'd3: dout <= din & 8'hF7;
                            3'd4: dout <= din & 8'hEF;
                            3'd5: dout <= din & 8'hDF;
                            3'd6: dout <= din & 8'hBF;
                            3'd7: dout <= din & 8'h7F;
                        endcase
                    end

                    default: dout <= din;
                endcase

                wr <= 1'b1;
                rd <= 1'b0;
                state <= ST_MEM_WR;
            end

            //=============================================================
            // Section 9: Bit Test and Branch Complete
            //=============================================================
            ST_BIT_TST: begin
                // Set C to state of tested bit
                cc_c <= din[bit_idx];

                // Check branch condition
                if((op_type == OP_BRSET && din[bit_idx]) ||
                   (op_type == OP_BRCLR && !din[bit_idx])) begin
                    // Branch taken
                    reg_pc <= reg_pc + {{5{operand2[7]}}, operand2};
                    addr <= reg_pc + {{5{operand2[7]}}, operand2};
                end else begin
                    // Branch not taken
                    addr <= reg_pc;
                end

                rd <= 1'b1;
                state <= ST_FETCH;
            end

            //=============================================================
            // Default: Safety return to fetch
            //=============================================================
            default: begin
                addr <= reg_pc;
                rd <= 1'b1;
                state <= ST_FETCH;
            end
        endcase
    end
end

endmodule
