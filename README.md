# nabu-adapter

Hardware and software for the NABU Network Adapter (NA-2), the cable
box that connected the NABU Personal Computer to the 1980s NABU Network
cable service. The adapter tunes a cable channel, demodulates the
6.312 Mbit/s OQPSK data carrier, descrambles and deframes it, keeps the
packets addressed to it, and passes them to the NABU PC over a serial
link.

This repository recreates the headend side of that service, so a real
adapter can boot and load programs again, and also contains a clone of
the adapter itself.

## Components

| Directory | Contents |
|-----------|----------|
| `libnabuwheel` | C library that generates the headend carousel as scrambled line bytes |
| `headend/gnuradio` | Headend on GNU Radio, transmitting through a HackRF or serving a TCP stream |
| `headend/configs` | Headend configuration files |
| `RP2350-datapump` | Raspberry Pi Pico 2 firmware that feeds a data stream straight into an adapter's demodulator connector |
| `rtl-clone` | FPGA clone of the NA-2 digital board and its MC6805 controller, on a Tang Nano 9K |

Each directory has its own README with requirements and build steps.

## How the pieces fit

The headend builds the carousel with libnabuwheel and modulates it to
the NABU cable signal:

    .pak segments -> libnabuwheel -> headend -+-> HackRF -> cable -> NA-2 -> NABU PC
                                              |
                                              +-> cs8 TCP stream

The TCP output carries cs8 (complex signed 8-bit) samples.

The datapump skips the RF stage. It drives the bit clock and data
signals that the adapter's demodulator would, from a carousel built into
the firmware:

    RP2350-datapump -> bit clock + data -> NA-2 demodulator connector

The FPGA clone takes the same bit clock and data signals as its input,
and runs the original adapter firmware on a soft MC6805 core.

## Configuration

`headend/configs/headend.yaml` is the starting point for the headend.
It lists every carousel setting with its standard value. Set `paks` to a
directory of `.pak` segment files.

`headend/configs/headend-message.yaml` sends only the single message
packet in `headend/configs/message`, which lights the adapter's MESSAGE
LED. It is a quick check that an adapter receives the signal, with no
NABU PC needed.

## License

Each component carries its own license file:

| Directory | License |
|-----------|---------|
| `libnabuwheel` | AGPL-3.0-or-later |
| `headend/gnuradio` | GPL-3.0-or-later |
| `RP2350-datapump` | AGPL-3.0-or-later |
| `rtl-clone` | CC BY-NC 4.0 |

See each directory's README for third-party code and data it includes.

## Acknowledgements

This work builds on earlier reverse engineering of the NA-2:

- Jared Boone's
  [nabu-network-adapter](https://github.com/jboone/nabu-network-adapter),
  covering the adapter's RF section and modulation
- Phil Pemberton's
  [NABU-Adaptor](https://github.com/philpem/NABU-Adaptor), covering the
  adapter's schematic, control processor firmware and addressing PAL

Thanks also to atrac17's
[Coin-Op Collection](https://github.com/Coin-OpCollection), the source of
the MC6805 core.
