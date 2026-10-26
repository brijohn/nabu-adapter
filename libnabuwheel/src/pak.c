/*
 * pak.c - .pak image slicing
 *
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Format is a series of repeated [u16 LE length][packet including CRC] blocks.
 */
#include "nabuwheel.h"

int nw_pak_slice(const uint8_t *pak, size_t len, nw_packet *out, uint16_t max)
{
	uint16_t n = 0;
	size_t off = 0;
	while (off + 2 <= len) {
		const size_t block = pak[off] | ((size_t)pak[off + 1] << 8);
		if (block < 18 || off + 2 + block > len) {
			break;
		}
		if (n >= max) {
			return -1;
		}
		out[n].data = pak + off + 2;
		out[n].len = (uint16_t)block;
		n++;
		off += 2 + block;
	}
	return n;
}
