/*
 * scramble.c - x^20+x^3+1 inverting multiplicative scrambler
 *
 * Copyright (c) 2024 Phil Pemberton
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Byte-wise algorithm taken from Phil Pemberton's NABU-RP2040-Datapump.
 */
#include "nabuwheel.h"

void nw_scramble(nw_scrambler *s, uint8_t *buf, size_t len)
{
	uint32_t st = s->sr;
	for (size_t i = 0; i < len; i++) {
		uint8_t out = buf[i] ^ 0xFF;
		out ^= (uint8_t)(st >> 12);
		out ^= (uint8_t)((st & 7) << 5);
		out ^= (out >> 3) & 0x1C;
		out ^= (out >> 3) & 0x03;
		st = ((st << 8) | out) & 0xFFFFF;
		buf[i] = out;
	}
	s->sr = st;
}
