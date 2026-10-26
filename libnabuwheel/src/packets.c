/*
 * packets.c - control packet rendering
 *
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Packet Types:
 *   - Set Tiers (0x81)
 *   - Message (0x82)
 *   - 7FFFFF time segment packet
 */
#include <string.h>

#include "internal.h"

uint16_t nw_crc16(const uint8_t *p, size_t n)
{
	uint16_t crc = 0xFFFF;
	for (size_t i = 0; i < n; i++) {
		crc ^= (uint16_t)p[i] << 8;
		for (int b = 0; b < 8; b++) {
			crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
		}
	}
	return crc ^ 0xFFFF;
}

static void put32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}

static void put_fcs(uint8_t *pkt, size_t body_len)
{
	const uint16_t fcs = nw_crc16(pkt, body_len);
	pkt[body_len] = fcs >> 8;
	pkt[body_len + 1] = fcs & 0xFF;
}

void nw_render_grant(uint8_t out[NW_GRANT_LEN], uint32_t palid, uint32_t tiers)
{
	memset(out, 0, NW_GRANT_LEN);
	put32(out, palid);
	out[4] = 0x81;
	put32(out + 5, tiers);
	put_fcs(out, NW_GRANT_LEN - 2);
}

void nw_render_time(uint8_t out[NW_TIME_LEN], const nw_time *t)
{
	static const uint8_t head[18] = {
		0x7F, 0xFF, 0xFF,            /* segment address        */
		0x00,                        /* packet number          */
		0x01,                        /* owner                  */
		0x7F, 0xFF, 0xFF, 0xFF,      /* tier                   */
		0x7F, 0x80,                  /* mystery bytes          */
		0xB1,                        /* type flags: first+last */
		0x00, 0x00,                  /* pak number             */
		0x00, 0x00,                  /* offset                 */
		0x02, 0x02,
	};
	memcpy(out, head, sizeof(head));
	out[18] = t->wday + 1;
	out[19] = 0x54;                  /* 1984 forever */
	out[20] = t->mon + 1;
	out[21] = t->mday;
	out[22] = t->hour;
	out[23] = t->min;
	out[24] = t->sec;
	put_fcs(out, NW_TIME_LEN - 2);
}

void nw_render_message(uint8_t out[NW_MSG_LEN], uint32_t palid, uint32_t seq, uint32_t id)
{
	memset(out, 0, NW_MSG_LEN);
	put32(out, palid);
	out[4] = 0x82;
	/* bytes 5..15 are always zero */
	put32(out + 16, seq);
	put32(out + 20, id);
	put_fcs(out, NW_MSG_LEN - 2);
}
