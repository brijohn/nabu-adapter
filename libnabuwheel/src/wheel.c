/*
 * wheel.c - scheduler and framer
 *
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Scheduling:
 *   - round-robin segment pool
 *   - one time frame at each round boundary
 *   - stride padding anchored to a fixed grid that never rewinds
 *   - pads longer than filler_span_bits send time frames, not silence
 *   - pads are emitted in NW_PAD_CHUNK_BITS chunks, with a schedule
 *     decision between chunks
 *   - entry table grants, messages and raw frames sent at
 *     the first frame boundary after they are due
 *   - a control gap follows every PAL-addressed and time frame
 *
 * Framing: a 5x256 table maps (trailing-ones count, data byte) to the
 * stuffed output bits, emitted through a bit accumulator a byte at a
 * time. Flags are never stuffed.
 */
#include <string.h>

#include "internal.h"

_Static_assert(sizeof(((nw_wheel *)0)->acc) * 8 >= 18,
               "accumulator must hold a worst-case stuffed byte plus carry");

/* pad idle run between schedule decisions, in line bits */
#define NW_PAD_CHUNK_BITS 512

/*
 * Packed LUT entry, one 32-bit load per input byte:
 *   [15:0]  stuffed output pattern, right-aligned
 *   [23:16] output length in bits (8..10)
 *   [31:24] trailing-ones count after this byte (0..4)
 */
static uint32_t stuff_lut[5][256];
static int lut_ready;

static void lut_init(void)
{
	for (int state = 0; state < 5; state++) {
		for (int b = 0; b < 256; b++) {
			uint16_t bits = 0;
			uint8_t len = 0;
			uint8_t ones = (uint8_t)state;
			for (int i = 7; i >= 0; i--) {
				const uint8_t v = (uint8_t)((b >> i) & 1);
				bits = (uint16_t)((bits << 1) | v);
				len++;
				if (v) {
					if (++ones == 5) {
						bits = (uint16_t)(bits << 1);
						len++;
						ones = 0;
					}
				} else {
					ones = 0;
				}
			}
			stuff_lut[state][b] = bits | ((uint32_t)len << 16) | ((uint32_t)ones << 24);
		}
	}
	lut_ready = 1;
}

/* emission unit types / frame phases */
enum { U_NONE, U_FLAGS, U_DATA };
enum { FP_LEAD, FP_DATA, FP_TAIL, FP_NONE };

/* entry kinds */
enum { K_FREE, K_GRANT, K_MESSAGE, K_FRAME };

static void start_frame(nw_wheel *w, const uint8_t *data, uint16_t len, int gap)
{
	w->fr_data = data;
	w->fr_len = len;
	w->fr_pos = 0;
	w->fr_tail = (uint32_t)w->params.trail_flags + w->params.idle_flags
	           + (gap ? w->params.control_gap_flags : 0);
	w->u_flags = w->params.lead_flags;
	w->fr_phase = FP_LEAD;
	w->unit = U_FLAGS;
}

static void start_pad(nw_wheel *w, uint32_t flags)
{
	w->u_flags = flags;
	w->fr_phase = FP_NONE;
	w->unit = U_FLAGS;
}

static int q_pop(nw_wheel *w)
{
	while (w->next_seg < w->nsegs && w->segs[w->next_seg].count == 0) {
		w->next_seg++;
	}
	return (w->next_seg < w->nsegs) ? (int)w->next_seg++ : -1;
}

static void maintenance(nw_wheel *w)
{
	uint16_t j = 0;
	for (uint16_t i = 0; i < w->pool_fill; i++) {
		uint16_t sgi = w->pool[i];
		if (w->cursors[sgi] >= w->segs[sgi].count) {
			const int r = q_pop(w);
			if (r < 0) {
				continue;
			}
			sgi = (uint16_t)r;
		}
		w->pool[j++] = sgi;
	}
	w->pool_fill = j;
	while (w->pool_fill < w->params.interleave) {
		const int r = q_pop(w);
		if (r < 0) {
			break;
		}
		w->pool[w->pool_fill++] = (uint16_t)r;
	}
}

static void wrap(nw_wheel *w)
{
	if (w->rev_bits == 0) {
		w->rev_bits = w->bits;
	}
	w->revolutions++;
	for (uint16_t s = 0; s < w->nsegs; s++) {
		w->cursors[s] = 0;
	}
	w->next_seg = 0;
}

static void start_entry(nw_wheel *w, const nw_entry *e)
{
	switch (e->kind) {
	case K_GRANT:
		nw_render_grant(w->ctl_buf, e->palid, e->a);
		start_frame(w, w->ctl_buf, NW_GRANT_LEN, 1);
		break;
	case K_MESSAGE:
		nw_render_message(w->ctl_buf, e->palid, e->a, e->b);
		start_frame(w, w->ctl_buf, NW_MSG_LEN, 1);
		break;
	default:
		start_frame(w, e->frame, e->len, (e->frame[0] & 0x80) != 0);
		break;
	}
}

static void arm_next(nw_wheel *w)
{
	for (;;) {
		const uint64_t bits = w->bits;

		for (int i = 0; i < NW_MAX_ENTRIES; i++) {
			nw_entry *const e = &w->entries[i];
			if (e->kind != K_FREE && (int64_t)bits - e->last >= (int64_t)e->every_bits) {
				e->last = (int64_t)bits;
				start_entry(w, e);
				return;
			}
		}

		if (bits < w->pad_until) {
			const uint64_t rem = w->pad_until - bits;
			if (w->params.time_frames && rem > w->params.filler_span_bits) {
				nw_time t;
				w->clock(w->clock_ctx, &t);
				nw_render_time(w->ctl_buf, &t);
				start_frame(w, w->ctl_buf, NW_TIME_LEN, 1);
				return;
			}
			uint64_t chunk = (rem + 7) & ~(uint64_t)7;
			if (chunk > NW_PAD_CHUNK_BITS) {
				chunk = NW_PAD_CHUNK_BITS;
			}
			start_pad(w, (uint32_t)(chunk / 8));
			return;
		}

		if (w->time_pending) {
			w->time_pending = 0;
			if (w->params.time_frames) {
				nw_time t;
				w->clock(w->clock_ctx, &t);
				nw_render_time(w->ctl_buf, &t);
				start_frame(w, w->ctl_buf, NW_TIME_LEN, 1);
				return;
			}
			continue;
		}

		if (w->round_pos >= w->pool_fill) {
			if (!w->marker_done) {
				w->pad_until = w->round_start + w->round_bits;
				if (w->pad_until < bits) {
					w->pad_until = bits;
				}
				w->round_start = w->pad_until;
				w->time_pending = 1;
				w->marker_done = 1;
				continue;
			}
			maintenance(w);
			if (w->pool_fill == 0) {
				wrap(w);
				maintenance(w);
				if (w->pool_fill == 0) {
					start_pad(w, 64);
					return;
				}
			}
			w->round_pos = 0;
			w->marker_done = 0;
			continue;
		}

		const uint16_t sgi = w->pool[w->round_pos++];
		const nw_packet *const pk = &w->segs[sgi].pkts[w->cursors[sgi]++];
		start_frame(w, pk->data, pk->len, pk->len != 0 && (pk->data[0] & 0x80) != 0);
		return;
	}
}

int nw_wheel_init(nw_wheel *w, const nw_params *params,
                  const nw_segment *segs, uint16_t nsegs,
                  nw_clock_fn clock, void *clock_ctx,
                  uint16_t *cursors, uint16_t *pool)
{
	if (!w || !params || !clock || !cursors || !pool) {
		return -1;
	}
	if (params->interleave == 0 || params->n_grants > NW_MAX_ENTRIES) {
		return -1;
	}
	if (params->n_grants != 0 && !params->grants) {
		return -1;
	}
	for (uint16_t i = 0; i < params->n_grants; i++) {
		if (params->grants[i].every_ms == 0) {
			return -1;
		}
	}

	uint32_t npackets = 0;
	for (uint16_t s = 0; s < nsegs; s++) {
		npackets += segs[s].count;
	}
	if (npackets == 0) {
		return -1;
	}

	if (!lut_ready) {
		lut_init();
	}

	memset(w, 0, sizeof(*w));
	w->params = *params;
	w->segs = segs;
	w->nsegs = nsegs;
	w->clock = clock;
	w->clock_ctx = clock_ctx;
	w->cursors = cursors;
	w->pool = pool;
	memset(cursors, 0, sizeof(*cursors) * nsegs);

	w->round_bits = (uint64_t)params->min_stride_ms * NW_BITS_PER_MS;
	for (uint16_t i = 0; i < params->n_grants; i++) {
		nw_entry *const e = &w->entries[i];
		e->kind = K_GRANT;
		e->palid = params->grants[i].palid;
		e->a = params->grants[i].tiers;
		e->every_bits = (uint64_t)params->grants[i].every_ms * NW_BITS_PER_MS;
		e->last = (int64_t)params->grants[i].phase_ms * NW_BITS_PER_MS - (int64_t)e->every_bits;
	}
	w->time_pending = 1;
	w->marker_done = 1;
	w->unit = U_NONE;
	return 0;
}

void nw_wheel_fill(nw_wheel *w, uint8_t *buf, size_t len)
{
	uint8_t *wr = buf;
	uint8_t *const end = buf + len;

	if (w->pend_valid && wr < end) {
		*wr++ = w->pend;
		w->pend_valid = 0;
	}

	while (wr < end) {
		if (w->unit == U_NONE) {
			arm_next(w);
		} else if (w->unit == U_FLAGS) {
			if (w->u_flags == 0) {
				if (w->fr_phase == FP_LEAD) {
					w->fr_phase = FP_DATA;
					w->unit = U_DATA;
				} else {
					w->unit = U_NONE;
				}
				continue;
			}
			w->ones = 0;
			if (w->accbits == 0) {
				size_t n = (size_t)(end - wr);
				if (n > w->u_flags) {
					n = w->u_flags;
				}
				memset(wr, 0x7E, n);
				wr += n;
				w->u_flags -= (uint32_t)n;
				w->bits += 8 * (uint64_t)n;
			} else {
				w->acc = (w->acc << 8) | 0x7E;
				*wr++ = (uint8_t)(w->acc >> w->accbits);
				w->u_flags--;
				w->bits += 8;
			}
		} else {
			if (w->fr_pos >= w->fr_len) {
				w->u_flags = w->fr_tail;
				w->fr_phase = FP_TAIL;
				w->unit = U_FLAGS;
				continue;
			}
			const uint32_t e = stuff_lut[w->ones][w->fr_data[w->fr_pos++]];
			const uint32_t elen = (e >> 16) & 0xFF;
			const uint32_t acc = (w->acc << elen) | (e & 0xFFFF);
			uint32_t accbits = w->accbits + elen - 8;
			w->ones = (uint8_t)(e >> 24);
			w->bits += elen;
			*wr++ = (uint8_t)(acc >> accbits);
			if (accbits >= 8) {
				accbits -= 8;
				const uint8_t b1 = (uint8_t)(acc >> accbits);
				if (wr < end) {
					*wr++ = b1;
				} else {
					w->pend = b1;
					w->pend_valid = 1;
				}
			}
			w->acc = acc;
			w->accbits = (uint8_t)accbits;
		}
	}
}

void nw_wheel_read(nw_wheel *w, nw_scrambler *s, uint8_t *buf, size_t len)
{
	nw_wheel_fill(w, buf, len);
	nw_scramble(s, buf, len);
}

static int handle_of(const nw_wheel *w, int i)
{
	return (w->entries[i].gen << 8) | i;
}

static int find_entry(const nw_wheel *w, uint8_t kind, uint32_t palid)
{
	for (int i = 0; i < NW_MAX_ENTRIES; i++) {
		if (w->entries[i].kind == kind && w->entries[i].palid == palid) {
			return i;
		}
	}
	return -1;
}

static int alloc_entry(nw_wheel *w, uint8_t kind, uint32_t palid)
{
	for (int i = 0; i < NW_MAX_ENTRIES; i++) {
		if (w->entries[i].kind == K_FREE) {
			memset(&w->entries[i], 0, sizeof(w->entries[i]));
			w->entries[i].kind = kind;
			w->entries[i].palid = palid;
			w->entries[i].gen = ++w->entry_gen;
			return i;
		}
	}
	return -1;
}

static void set_due(nw_wheel *w, nw_entry *e, uint32_t every_ms)
{
	e->every_bits = (uint64_t)every_ms * NW_BITS_PER_MS;
	e->last = (int64_t)w->bits - (int64_t)e->every_bits;
}

int nw_wheel_add_grant(nw_wheel *w, uint32_t palid, uint32_t tiers, uint32_t every_ms)
{
	if (!w || every_ms == 0) {
		return -1;
	}
	int i = find_entry(w, K_GRANT, palid);
	if (i < 0) {
		i = alloc_entry(w, K_GRANT, palid);
		if (i < 0) {
			return -1;
		}
	}
	w->entries[i].a = tiers;
	set_due(w, &w->entries[i], every_ms);
	return handle_of(w, i);
}

int nw_wheel_add_message(nw_wheel *w, uint32_t palid, const uint32_t *seq, uint32_t id,
                         uint32_t every_ms)
{
	if (!w || every_ms == 0) {
		return -1;
	}
	uint32_t next = 1;
	int i = find_entry(w, K_MESSAGE, palid);
	if (i >= 0) {
		next = w->entries[i].a + 1;
	} else {
		i = alloc_entry(w, K_MESSAGE, palid);
		if (i < 0) {
			return -1;
		}
	}
	w->entries[i].a = seq ? *seq : next;
	w->entries[i].b = id;
	set_due(w, &w->entries[i], every_ms);
	return handle_of(w, i);
}

int nw_wheel_add_frame(nw_wheel *w, const uint8_t *frame, uint16_t len, uint32_t every_ms)
{
	if (!w || !frame || len == 0 || every_ms == 0) {
		return -1;
	}
	const int i = alloc_entry(w, K_FRAME, 0);
	if (i < 0) {
		return -1;
	}
	w->entries[i].frame = frame;
	w->entries[i].len = len;
	set_due(w, &w->entries[i], every_ms);
	return handle_of(w, i);
}

int nw_wheel_remove(nw_wheel *w, int handle)
{
	if (!w || handle < 0) {
		return -1;
	}
	const int i = handle & 0xFF;
	if (i >= NW_MAX_ENTRIES || w->entries[i].kind == K_FREE || w->entries[i].gen != (uint8_t)(handle >> 8)) {
		return -1;
	}
	w->entries[i].kind = K_FREE;
	return 0;
}

void nw_wheel_clear(nw_wheel *w)
{
	if (!w) {
		return;
	}
	for (int i = 0; i < NW_MAX_ENTRIES; i++) {
		w->entries[i].kind = K_FREE;
	}
}
