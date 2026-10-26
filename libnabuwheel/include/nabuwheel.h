/*
 * nabuwheel.h - NABU cable headend wheel generator
 *
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Streams a live broadcast carousel as packed line bytes: pak
 * segments interleaved round-robin with stride pacing, Set Tiers
 * grants woven at configured intervals, time packets at round
 * boundaries and in long pads, HDLC framing with zero stuffing, and
 * the x^20+x^3+1 inverting multiplicative scrambler.
 *
 * The library performs no I/O, no allocation, no time lookup, and
 * no config parsing. Hosts provide packet memory, parameter
 * structs, caller-allocated context/state storage, and a clock
 * callback.
 *
 * nw_wheel_read() produces the next len bytes of scrambled line
 * output. It calls nw_wheel_fill() followed by nw_scramble(), which are
 * also exposed for hosts that wish to run the two stages separately.
 *
 * The library is not thread-safe. Proper locking is the responsibility
 * of the host.
 */
#ifndef NABUWHEEL_H
#define NABUWHEEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* line rate: cable bit clock, 2x the 3.156 Msym/s symbol rate */
#define NW_BIT_RATE    6312000
#define NW_BITS_PER_MS 6312

/* unit address matching every adapter's addressing PAL */
#define NW_BROADCAST   0xFFFFFFFF

/* entry table size, config grants included */
#define NW_MAX_ENTRIES 16

/* one cable packet, complete with its Genibus CRC */
typedef struct {
	const uint8_t *data;
	uint16_t       len;
} nw_packet;

/* one segment = the ordered packets of one pak */
typedef struct {
	const nw_packet *pkts;
	uint16_t         count;
} nw_segment;

typedef struct {
	uint8_t wday, mon, mday, hour, min, sec;
} nw_time;

typedef void (*nw_clock_fn)(void *ctx, nw_time *out);

typedef struct {
	uint32_t palid;     /* unit address, or NW_BROADCAST     */
	uint32_t tiers;     /* tiers being granted               */
	uint32_t every_ms;  /* interval at which a grant repeats */
	uint32_t phase_ms;  /* interval offset from stream start */
} nw_grant;

typedef struct {
	uint16_t        interleave;        /* round-robin pool size                           */
	uint16_t        lead_flags;        /* number of flags before each packet              */
	uint16_t        trail_flags;       /* number of flags after each packet               */
	uint32_t        idle_flags;        /* number of flags after every frame               */
	uint32_t        min_stride_ms;     /* same-segment pacing floor                       */
	uint32_t        control_gap_flags; /* extra flags after PAL-addressed and time frames */
	uint32_t        filler_span_bits;  /* longer pads send time packets                   */
	uint8_t         time_frames;       /* 0 disables time packets                         */
	const nw_grant *grants;
	uint16_t        n_grants;
} nw_params;

/* one entry table slot, see nw_wheel_add_grant() */
typedef struct {
	const uint8_t *frame;       /* caller-owned bytes for a raw frame   */
	uint64_t       every_bits;
	int64_t        last;        /* bit time of the last send            */
	uint32_t       palid;
	uint32_t       a;           /* grant tiers, or message seq          */
	uint32_t       b;           /* message id                           */
	uint16_t       len;
	uint8_t        kind;        /* 0 = free slot                        */
	uint8_t        gen;         /* handle generation                    */
} nw_entry;

/*
 * Wheel context. Layout is public only so callers can allocate it
 * statically. Treat every field as private.
 */
typedef struct nw_wheel {
	/* configuration */
	nw_params         params;
	const nw_segment *segs;
	uint16_t          nsegs;
	nw_clock_fn       clock;
	void             *clock_ctx;
	uint16_t         *cursors;
	uint16_t         *pool;

	/* counters */
	uint64_t bits;
	uint64_t rev_bits;
	uint32_t revolutions;

	/* scheduler state */
	uint64_t round_start;
	uint64_t round_bits;
	uint64_t pad_until;
	uint16_t pool_fill;
	uint16_t next_seg;
	uint16_t round_pos;
	uint8_t  time_pending;
	uint8_t  marker_done;
	uint8_t  entry_gen;
	nw_entry entries[NW_MAX_ENTRIES];

	/* emission unit in progress */
	uint8_t        unit;
	uint8_t        fr_phase;
	uint32_t       u_flags;
	uint32_t       fr_tail;
	const uint8_t *fr_data;
	uint16_t       fr_len, fr_pos;
	uint8_t        ctl_buf[32];
	uint8_t        pend;
	uint8_t        pend_valid;

	/* framer state (stuffing + bit accumulator carry) */
	uint32_t acc;
	uint8_t  accbits;
	uint8_t  ones;
} nw_wheel;

typedef struct {
	uint32_t sr;
} nw_scrambler;

/*
 * Initialize a wheel. The cursors array holds nsegs entries, pool holds
 * params->interleave entries. Returns 0, or negative on bad params.
 */
int nw_wheel_init(nw_wheel *w, const nw_params *params,
                  const nw_segment *segs, uint16_t nsegs,
                  nw_clock_fn clock, void *clock_ctx,
                  uint16_t *cursors, uint16_t *pool);

/* Fill buf with exactly len unscrambled line bytes. */
void nw_wheel_fill(nw_wheel *w, uint8_t *buf, size_t len);

/* Scramble buf in place. Buffers must be scrambled in fill order. */
void nw_scramble(nw_scrambler *s, uint8_t *buf, size_t len);

/* Fill and scramble a buffer of the given length. */
void nw_wheel_read(nw_wheel *w, nw_scrambler *s, uint8_t *buf, size_t len);

/*
 * Slice a .pak image into packet spans without copying. Stops at a
 * length under 18 or one past the end. Returns the packet count, or
 * negative if there are more than max.
 */
int nw_pak_slice(const uint8_t *pak, size_t len, nw_packet *out, uint16_t max);

/*
 * Entry table. Each entry is sent at the first frame boundary after
 * it becomes due, then every every_ms, until it is removed. A new or
 * replaced entry is due at once. The functions return a handle >= 0, or
 * negative on bad arguments or a full table.
 *
 * nw_wheel_add_grant() and nw_wheel_add_message() keep one entry
 * per PAL address and kind: a second call for the same address replaces
 * the entry in place and returns its handle. A NULL seq continues from
 * the replaced message's seq + 1, or starts at 1.
 *
 * nw_wheel_add_frame() sends a complete packet, CRC included, from
 * caller memory that must stay valid until the entry is removed.
 */
int nw_wheel_add_grant(nw_wheel *w, uint32_t palid, uint32_t tiers, uint32_t every_ms);
int nw_wheel_add_message(nw_wheel *w, uint32_t palid, const uint32_t *seq, uint32_t id,
                         uint32_t every_ms);
int nw_wheel_add_frame(nw_wheel *w, const uint8_t *frame, uint16_t len, uint32_t every_ms);

/* Remove one entry. Returns 0, or negative for a stale or bad handle. */
int nw_wheel_remove(nw_wheel *w, int handle);

/* Remove every entry, config grants included. */
void nw_wheel_clear(nw_wheel *w);

#ifdef __cplusplus
}
#endif

#endif /* NABUWHEEL_H */
