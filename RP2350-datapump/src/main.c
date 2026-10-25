/******************************************
 * NABU-PC Adaptor datapump — PIO output version
 *
 * Generates scrambled NABU Adaptor data streams at the true line rate of
 * 6.312 Mbit/s.
 *
 * Derived from Phil Pemberton's NABU-RP2040-Datapump.
 * https://github.com/philpem/NABU-Adaptor
 *
 * Changes:
 *
 *  - The SPI peripheral output stage is replaced with a 2-instruction PIO
 *    state machine (src/nabu_tx.pio), because the PL022 SPI clock divider
 *    cannot land near 6.312 MHz (the original ran at a compromise 8 MHz).
 *    The PIO fractional divider gets within ~40 ppm.
 *  - Ported from the arduino-pico core to plain pico-sdk: setup1()/loop1()
 *    become a core-1 entry function, rp2040.fifo becomes the SIO inter-core
 *    FIFO, Serial becomes stdio.
 *  - HDLC zero stuffing uses a 5x256 lookup table indexed by (trailing-ones
 *    count, input byte), giving the stuffed bit pattern, its length and the
 *    new trailing-ones count in one load.
 *  - Output is streamed by a pair of DMA channels that chain to each other,
 *    so the next buffer starts in hardware the cycle the current one
 *    completes, with no CPU in the critical path.
 *  - Optional EXACT_CLOCK retunes the system PLL to 63.12 MHz, an exact 5x
 *    multiple of the 12.624 MHz PIO clock, this eliminates fractional jitter.
 *
 * Output pins (same wiring as the SPI version):
 *   GP18 = bit clock  -> Adaptor J3 pin 7 (demodulator clock)
 *   GP19 = data       -> Adaptor J3 pin 9 (demodulator data)
 *   GND               -> J3 pins 1/6/8
 * Data is presented while the clock is low and stable across the rising
 * edge — the adaptor captures on the rising edge.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "pico/stdlib.h"
#include "pico/multicore.h"
#include "hardware/pio.h"
#include "hardware/dma.h"
#include "hardware/clocks.h"
#include "hardware/gpio.h"

#include "crc16_genibus.h"

// Assembled from src/nabu_tx.pio at build time
#include "nabu_tx.pio.h"

// Oscilloscope trigger output pin and enable
#define DEBUG_PIN 2
#define SCOPE_TRIGGER_OUT

// NABU line rate, bits per second
#define BIT_RATE 6312000

// Output pins: clock is the PIO side-set pin, data is the OUT pin
#define PIN_CLK  18
#define PIN_DATA 19

// Diagnostic printout enable/disable
//#define DIAGPRINT

// Exact zero-jitter line clock: retune the system PLL so
// clk_sys = 63.12 MHz, an exact 5x multiple of the 12.624 MHz
// PIO clock — integer divider, no fractional jitter.
#define EXACT_CLOCK


// Buffering --
// Number of transmit buffers
#define BITBUF_NBUFFERS	2
// Size of a transmit buffer
#define BITBUF_BUFLEN 	32768


// Number of flag bytes at start of packet
#define PACKET_START_FLAG_N 10

// Number of flag bytes between packets
//#define INTERPACKET_FLAG_N 1024

// Number of times a packet should be repeated
#define PACKET_REPEAT_COUNT 1

// Broadcast the MESSAGE LED bench test packet
#define MESSAGE_LED_TEST


/****
 * Packet management
 */
typedef struct {
	const uint16_t len;
	const uint8_t *const data;
} NABU_PACKET;

// Pull in the packets
#ifdef MESSAGE_LED_TEST
#include "packets_message.h"
#else
#include "packets.h"
#endif



/****
 * Scrambler (runs on core 1 only)
 */

// Current scrambler state.
static uint32_t scrambler_state = 0;

// Optimisation: scramble an entire byte
static uint8_t scramble_byte(const uint8_t byte_in)
{
	// Input byte is inverted
	uint8_t out_byte = byte_in ^ 0xFF;

	// xor with LFSR bits [19..11]
	out_byte ^= scrambler_state >> 12;

	// apply tap 2
	// we only have 3 bits of state between here and the end of register
	// so calculate those 3 bits
	out_byte ^= (scrambler_state & 7) << 5;

	// The 3 new bits would be clocked in at the end of the scrambler register
	// so let's pretend we did that
	out_byte ^= (out_byte >> 3) & 0x1C;	// 00011100

	// Now use those 3 new bits to generate the last 2
	out_byte ^= (out_byte >> 3) & 3;

	// Shuffle the new 8 bits into the scrambler state
	scrambler_state = (scrambler_state << 8) | out_byte;

	return out_byte;
}


/****
 * Transmit bit buffer
 *
 * Filled by core 0 (unscrambled), scrambled and streamed out by core 1.
 * Ownership passes through the SIO inter-core FIFO: core 0 pushes an index
 * when a buffer is committed; core 1 pushes the index back once the DMA
 * that read it has finished.
 */

static uint8_t bb_locked[BITBUF_NBUFFERS] = {0};	// bit buffer lock flags
static uint8_t bb_buffer[BITBUF_NBUFFERS][BITBUF_BUFLEN];	// bit buffers
static uint8_t *bb_wrptr = bb_buffer[0];			// pointer to current byte in current bitbuffer
static size_t bb_length[BITBUF_NBUFFERS];			// number of buffered bytes
static uint32_t bb_cur_bitbuf = 0;	// current bitbuffer
static size_t bb_bytes = 0;			// number of bytes clocked in


// Check if the other core has released any buffers
// Returns true if at least one buffer was unlocked
static bool bb_check_unlocks(void)
{
	bool haveFreeBuffers = false;

	while (multicore_fifo_rvalid()) {
		uint32_t bufnum = multicore_fifo_pop_blocking();
		bb_locked[bufnum] = 0;
		haveFreeBuffers = true;
	}

	return haveFreeBuffers;
}


// Commit/finalise the current bit buffer
static void bb_commit(void)
{
	// lock the buffer and signal the other core to tx it
	bb_locked[bb_cur_bitbuf] = 1;
	bb_length[bb_cur_bitbuf] = bb_bytes;
	multicore_fifo_push_blocking(bb_cur_bitbuf);

	// advance to the next buffer
	bb_cur_bitbuf++;
	if (bb_cur_bitbuf >= BITBUF_NBUFFERS) {
		bb_cur_bitbuf = 0;
	}
	bb_bytes = 0;
	bb_wrptr = bb_buffer[bb_cur_bitbuf];

	// Wait here if the next buffer hasn't been released yet
	if (bb_locked[bb_cur_bitbuf]) {
		while (!bb_check_unlocks()) {
			tight_loop_contents();
		}
	}
}


/**
 * Bit output: accumulator + zero-stuffing lookup table
 *
 * The original bit-banged framing cost ~28 CPU cycles per bit — slower
 * than the 6.312 Mbit/s line rate even at 150 MHz (measured on hardware:
 * 51 ms to fill a buffer that drains in 41.5 ms, so the clock paused
 * ~9.5 ms per buffer). Instead, a 5x256 LUT maps (trailing-ones state,
 * input byte) -> the fully stuffed output pattern, emitted through a bit
 * accumulator one whole byte at a time.
 **/

// Packed LUT entry, one 32-bit load per input byte:
//   [15:0]  stuffed output pattern, right-aligned
//   [23:16] output length in bits (8..10)
//   [31:24] trailing-ones count after this byte (0..4)
static uint32_t stuff_lut[5][256];

// Build the stuffing LUT (one-time, at startup)
static void stuff_lut_init(void)
{
	for (int state = 0; state < 5; state++) {
		for (int b = 0; b < 256; b++) {
			uint16_t bits = 0;
			uint8_t len = 0;
			uint8_t ones = state;
			for (int i = 7; i >= 0; i--) {
				uint8_t v = (b >> i) & 1;
				bits = (bits << 1) | v;
				len++;
				if (v) {
					if (++ones == 5) {
						bits <<= 1;	// insert the stuffed 0
						len++;
						ones = 0;
					}
				} else {
					ones = 0;
				}
			}
			stuff_lut[state][b] = bits | ((uint32_t)len << 16)
			                           | ((uint32_t)ones << 24);
		}
	}
}

// Bit accumulator: whole output bytes go to the buffer; the sub-byte
// remainder lives here and carries across buffer commits.
static uint32_t bb_acc = 0;
static uint32_t bb_accbits = 0;

static inline void bb_put_bits(uint32_t bits, uint32_t len)
{
	bb_acc = (bb_acc << len) | bits;
	bb_accbits += len;
	while (bb_accbits >= 8) {
		bb_accbits -= 8;
		*bb_wrptr++ = (uint8_t)(bb_acc >> bb_accbits);
		if (++bb_bytes >= BITBUF_BUFLEN) {
			bb_commit();
		}
	}
}

/****
 * SDLC transmission
 */

// Trailing-ones state for zero stuffing (0..4)
static uint8_t sdlc_nOnes = 0;

// Send a flag, 7E hex (raw)
static void sdlc_send_flag(void)
{
	bb_put_bits(0x7E, 8);

	// flag starts and ends with a zero, so reset the ones counter.
	sdlc_nOnes = 0;
}

// Send an arbitrary byte, zero-stuffed via the LUT
static void sdlc_send_byte(const uint8_t bval)
{
	const uint32_t e = stuff_lut[sdlc_nOnes][bval];
	bb_put_bits(e & 0xFFFF, (e >> 16) & 0xFF);
	sdlc_nOnes = e >> 24;
}


/**
 * Packet transmission
 *
 * This is the fill loop that must outrun the 41.5 ms buffer drain, so the
 * accumulator/stuffing state lives in locals (registers) for the whole
 * packet and the globals are synced once at the end.
 **/
static void send_segment(const uint8_t *buf, const size_t len)
{
	// Worst-case output bytes this packet can produce
	const size_t worst = PACKET_START_FLAG_N + ((len * 10) + 7) / 8 + 1;
	if (bb_bytes + worst > BITBUF_BUFLEN) {
		bb_commit();
	}

	uint32_t acc = bb_acc;
	uint32_t accbits = bb_accbits;	// 0..7 between whole-byte drains
	uint8_t *wr = bb_wrptr;

	// SDLC FLAG bytes to start the packet. 8 bits in, 8 bits out:
	// accbits is invariant, so each flag emits exactly one byte.
	for (int n=0; n<PACKET_START_FLAG_N; n++) {
		acc = (acc << 8) | 0x7E;
		*wr++ = (uint8_t)(acc >> accbits);
	}

	// A flag starts and ends with a zero, so the stuffing state resets
	uint32_t ones = 0;

	// Packet data. Each input byte adds 8..10 stuffed bits, so with
	// accbits in 0..7 there is always exactly one whole output byte,
	// sometimes two.
	for (size_t n=0; n<len; n++) {
		const uint32_t e = stuff_lut[ones][buf[n]];
		const uint32_t elen = (e >> 16) & 0xFF;
		ones = e >> 24;
		acc = (acc << elen) | (e & 0xFFFF);
		accbits += elen - 8;
		*wr++ = (uint8_t)(acc >> accbits);
		if (accbits >= 8) {
			accbits -= 8;
			*wr++ = (uint8_t)(acc >> accbits);
		}
	}

	bb_acc = acc;
	bb_accbits = accbits;
	sdlc_nOnes = (uint8_t)ones;
	bb_bytes += (size_t)(wr - bb_wrptr);
	bb_wrptr = wr;
}

#define UADDR_BROADCAST (0xFFFFFFFF)
#define TIERS_AND(x) ((x) & 0x7FFFFFFF)
#define TIERS_XOR(x) ((x) | 0x80000000)

// Tier Authorization
static void __attribute__((unused)) send_auth_tiers(const uint32_t uaddr, const uint32_t tiers)
{
	uint8_t buf[19];
	size_t i=0;

	// Make sure the top bit of the unit address is set - if not, this will look like a segment!
	uint32_t ua = uaddr | 0x80000000;

	// Build the buffer
	buf[i++] = (ua >> 24) & 0xff;		// Unit address
	buf[i++] = (ua >> 16) & 0xff;
	buf[i++] = (ua >> 8)  & 0xff;
	buf[i++] = (ua)       & 0xff;
	buf[i++] = 0x81;					// Command code, 0x81 = Set Tiers
	buf[i++] = (tiers >> 24) & 0xff;	// Tier bits
	buf[i++] = (tiers >> 16) & 0xff;
	buf[i++] = (tiers >> 8)  & 0xff;
	buf[i++] = (tiers)       & 0xff;
	// Free space to byte 17
	while (i<17) {
		buf[i++] = 0;
	}
	// Frame check sequence - Genibus CRC16
	uint16_t fcs = crc16_genibus_fini(crc16_genibus_update(buf, i, crc16_genibus_init()));
	buf[i++] = (fcs >> 8) & 0xff;
	buf[i++] = (fcs)      & 0xff;

	// SDLC FLAG bytes to start the packet
	for (int n=0; n<PACKET_START_FLAG_N; n++) {
		sdlc_send_flag();
	}

	// Packet data
	for (size_t n=0; n<i; n++) {
		sdlc_send_byte(buf[n]);
	}
}

// Message
static void __attribute__((unused)) send_message(const uint32_t uaddr, const uint32_t seqn, const uint32_t msgcode)
{
	uint8_t buf[25];
	size_t i=0;

	// Make sure the top bit of the unit address is set - if not, this will look like a segment!
	uint32_t ua = uaddr | 0x80000000;

	// Build the buffer
	buf[i++] = (ua >> 24) & 0xff;		// Unit address
	buf[i++] = (ua >> 16) & 0xff;
	buf[i++] = (ua >> 8)  & 0xff;
	buf[i++] = (ua)       & 0xff;
	buf[i++] = 0x82;					// Command code, 0x82 = Message

	// Free space to byte 15
	while (i<15) {
		buf[i++] = 0;
	}

	buf[i++] = (seqn >> 24) & 0xff;		// Sequence number
	buf[i++] = (seqn >> 16) & 0xff;
	buf[i++] = (seqn >> 8)  & 0xff;
	buf[i++] = (seqn)       & 0xff;

	buf[i++] = (msgcode >> 24) & 0xff;	// Message code
	buf[i++] = (msgcode >> 16) & 0xff;
	buf[i++] = (msgcode >> 8)  & 0xff;
	buf[i++] = (msgcode)       & 0xff;

	// Frame check sequence - Genibus CRC16
	uint16_t fcs = crc16_genibus_fini(crc16_genibus_update(buf, i, crc16_genibus_init()));
	buf[i++] = (fcs >> 8) & 0xff;
	buf[i++] = (fcs)      & 0xff;

	// SDLC FLAG bytes to start the packet
	for (int n=0; n<PACKET_START_FLAG_N; n++) {
		sdlc_send_flag();
	}

	// Packet data
	for (size_t n=0; n<i; n++) {
		sdlc_send_byte(buf[n]);
	}
}


/****************************
 * SECOND PROCESSOR CORE
 *
 * Scrambles committed buffers and streams them to the PIO transmitter
 * via DMA.
 ****************************/

static PIO  tx_pio = pio0;
static int  tx_sm;
static uint tx_offset;

/**
 * DMA Chaining
 * Each channel CHAIN_TOs the other, so the hardware starts buffer N+1
 * in the same cycle buffer N's transfer completes — no code in the
 * critical path.
 **/
static unsigned int dma_ch[2];
static dma_channel_config dma_cfg[2];

static void core1_main(void)
{
	printf("Transmitter core starting up...\n");

	// Set up the PIO transmitter
	tx_offset = pio_add_program(tx_pio, &nabu_tx_program);
	tx_sm = pio_claim_unused_sm(tx_pio, true);
	nabu_tx_program_init(tx_pio, tx_sm, tx_offset, PIN_CLK, PIN_DATA, BIT_RATE);

	// Report the quantized divider and the bit rate it actually produces
	{
		float div = (float)clock_get_hz(clk_sys) / (2.0f * (float)BIT_RATE);
		uint32_t div_q = (uint32_t)(div * 256.0f + 0.5f);
		float actual = (float)clock_get_hz(clk_sys) * 256.0f / (float)div_q / 2.0f;
		printf("(TX) PIO clkdiv = %f, actual bit rate = %.1f bit/s\n", div, actual);
	}

	// Set up the chained TX DMA pair
	dma_ch[0] = dma_claim_unused_channel(true);
	dma_ch[1] = dma_claim_unused_channel(true);
	for (int i = 0; i < 2; i++) {
		dma_cfg[i] = dma_channel_get_default_config(dma_ch[i]);
		channel_config_set_transfer_data_size(&dma_cfg[i], DMA_SIZE_8);
		channel_config_set_dreq(&dma_cfg[i], pio_get_dreq(tx_pio, tx_sm, true));
		// completing a transfer triggers the partner channel
		channel_config_set_chain_to(&dma_cfg[i], dma_ch[i ^ 1]);
		dma_channel_configure(dma_ch[i], &dma_cfg[i],
							  &tx_pio->txf[tx_sm], NULL, 0, false);
	}

	int slot = 0;				// channel to arm with the next buffer
	int inflight[2] = {-1, -1};	// bit buffer index loaded in each channel
	bool started = false;

	while (1) {
		// Get the index of the data block to push
		uint32_t zIndex = multicore_fifo_pop_blocking();

		// Apply scrambling
		uint8_t *p = bb_buffer[zIndex];
		for (size_t i=0; i<bb_length[zIndex]; i++) {
			*p = scramble_byte(*p);
			p++;
		}

		// Arm this slot's channel.
		dma_channel_set_read_addr(dma_ch[slot], bb_buffer[zIndex], false);
		dma_channel_set_trans_count(dma_ch[slot], bb_length[zIndex], false);

		if (!started) {
			// very first buffer: nothing to chain from
			dma_channel_start(dma_ch[slot]);
			started = true;
		}
		inflight[slot] = (int)zIndex;
		slot ^= 1;

		// The other channel holds the oldest in-flight buffer. Wait for
		// its transfer to complete and only then hand the buffer back to
		// the filler core.
		if (inflight[slot] >= 0) {
			dma_channel_wait_for_finish_blocking(dma_ch[slot]);
			multicore_fifo_push_blocking((uint32_t)inflight[slot]);
			inflight[slot] = -1;

#ifdef SCOPE_TRIGGER_OUT
			gpio_put(DEBUG_PIN, 1);
			busy_wait_us(1);
			gpio_put(DEBUG_PIN, 0);
#endif
		}
	}
}


#ifdef EXACT_CLOCK
#include "hardware/pll.h"

// clk_sys = 63.12 MHz = 5 x 12.624 MHz
static void set_exact_clock(void)
{
	// park clk_sys on the crystal reference while the sys PLL is retuned
	clock_configure(clk_sys, CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLK_REF,
	                0, 12 * MHZ, 12 * MHZ);

	pll_init(pll_sys, 2, 1578 * MHZ, 5, 5);

	clock_configure(clk_sys, CLOCKS_CLK_SYS_CTRL_SRC_VALUE_CLKSRC_CLK_SYS_AUX,
	                CLOCKS_CLK_SYS_CTRL_AUXSRC_VALUE_CLKSRC_PLL_SYS,
	                63120 * KHZ, 63120 * KHZ);

	// keep peripheral clock bookkeeping consistent with the new clk_sys
	clock_configure(clk_peri, 0, CLOCKS_CLK_PERI_CTRL_AUXSRC_VALUE_CLK_SYS,
	                63120 * KHZ, 63120 * KHZ);
}
#endif


/****
 * Main (core 0): build the carousel into the bit buffers
 */

int main(void)
{
#ifdef EXACT_CLOCK
	set_exact_clock();
#endif

	stdio_init_all();
	sleep_ms(2000);		// give USB CDC a moment to enumerate

	printf("NABU datapump starting, line rate %d bit/s\n", BIT_RATE);

	// init debug pin
	gpio_init(DEBUG_PIN);
	gpio_set_dir(DEBUG_PIN, GPIO_OUT);
	gpio_put(DEBUG_PIN, 0);

	// build the zero-stuffing lookup table
	stuff_lut_init();

	// Start the transmitter core.
	multicore_launch_core1(core1_main);

	size_t curSeg = 0;
	size_t curRepeat = 0;

	while (1) {
		// Release any buffers the transmitter core has finished with
		bb_check_unlocks();

#ifdef DIAGPRINT
		printf("Seg %zu, len %u", curSeg, DATA_000001_SEGLENS[curSeg]);
#endif

		send_segment(DATA_000001_SEGS[curSeg], DATA_000001_SEGLENS[curSeg]);

#ifdef DIAGPRINT
		printf(". bblen %zu bytes + %u bits (%zu total bits)\n",
			   bb_bytes, (unsigned)bb_accbits, (bb_bytes * 8) + bb_accbits);
#endif

#if defined(INTERPACKET_FLAG_N) && (INTERPACKET_FLAG_N > 0)
		for (int x=0; x<INTERPACKET_FLAG_N; x++) {
			sdlc_send_flag();
		}
#endif
		if (curRepeat++ > PACKET_REPEAT_COUNT) {
			curRepeat = 0;

			// next segment
			curSeg++;
			if (curSeg >= DATA_000001_NSEGS) {
				curSeg = 0;
			}
		}
	}

	return 0;
}
