/*******************************************************************
* MESSAGE LED bench test wheel: a single broadcast-addressed type-1
* 0x82 message packet (sequence 01020304, message id AABBCCDD).
********************************************************************/

const uint8_t DATA_000001_blk0[] = {
	0xFF, 0xFF, 0xFF, 0xFF, 0x82, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD,
	0xC4, 0x3A,
};

const uint32_t DATA_000001_NSEGS = 1;
const uint8_t* const DATA_000001_SEGS[1] = {
	DATA_000001_blk0,
};
const uint16_t DATA_000001_SEGLENS[1] = {
	26,
};
