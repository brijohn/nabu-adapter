# RP2350 datapump

Raspberry Pi Pico 2 firmware that generates a scrambled, HDLC-framed NABU
cable data stream at a 6.312 Mbit/s line rate and injects it
directly into a NABU Network Adaptor (NA-2), bypassing the RF can.

Derived from Phil Pemberton's [NABU-RP2040-Datapump](https://github.com/philpem/NABU-Adaptor/tree/master/NABU-RP2040-Datapump).

## Wiring

| Pico 2 | Adaptor J3 |
|--------|------------|
| GP18 (bit clock) | pin 7 (demodulator clock) |
| GP19 (data)      | pin 9 (demodulator data) |
| GND              | pin 8 |

## Build

Requires the [pico-sdk](https://github.com/raspberrypi/pico-sdk) and an
ARM GCC toolchain.

    make SDK=/path/to/pico-sdk   # configure + build
    make flash                   # copy the UF2 to a Pico in BOOTSEL mode
    make monitor                 # USB serial console

## Options

Set in `src/main.c`:

- `MESSAGE_LED_TEST` (default): broadcasts a single message packet that
  lights the adaptor's MESSAGE LED. No NABU PC needed.
  Comment it out to send the boot wheel in `src/packets.h` instead.
- `EXACT_CLOCK` (default): runs the system clock at 63.12 MHz for a
  jitter-free integer PIO divider.
