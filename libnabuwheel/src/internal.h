/*
 * internal.h - packet renderers
 *
 * Copyright (c) 2026 Brian Johnson
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef NW_INTERNAL_H
#define NW_INTERNAL_H

#include "nabuwheel.h"

#define NW_GRANT_LEN 19
#define NW_TIME_LEN  27
#define NW_MSG_LEN   26

/* Genibus CRC-16: poly 0x1021 */
uint16_t nw_crc16(const uint8_t *p, size_t n);

void nw_render_grant(uint8_t out[NW_GRANT_LEN], uint32_t palid, uint32_t tiers);
void nw_render_time(uint8_t out[NW_TIME_LEN], const nw_time *t);
void nw_render_message(uint8_t out[NW_MSG_LEN], uint32_t palid, uint32_t seq, uint32_t id);

#endif /* NW_INTERNAL_H */
