# libnabuwheel

A C11 library that generates a live NABU cable headend carousel as
packed line bytes: pak segments interleaved round-robin with stride
pacing, Set Tiers grants woven at configured intervals, time packets at
round boundaries and in long pads, HDLC framing with zero stuffing, and
the x^20+x^3+1 inverting scrambler.

The core does no I/O, no allocation, no time lookup, and no config
parsing — hosts provide packet memory, parameters, caller-allocated
state, and a clock callback.

## Layout

    include/nabuwheel.h   public API
    src/wheel.c           scheduler + framer
    src/scramble.c        byte-wise scrambler
    src/pak.c             .pak image slicing
    src/packets.c         grant/time/message rendering, CRC-16

## Build

    make                  # static lib

## License

Licensed under the GNU Affero General Public License v3.0 or later. See
`COPYING`.
