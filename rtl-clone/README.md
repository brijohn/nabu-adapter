# rtl-clone — NABU NA-2 network adapter in an FPGA

RTL for an NA-2 network adapter clone on a Tang Nano 9K.
It implements the digital board's receive chain (descrambler, HDLC
destuffer, addressing PAL, 1 KB packet FIFO, interrupt logic), the
serial UART to the NABU PC, and the MC6805 control processor as a soft
core running the original adapter firmware ROM.

## Toolchain

[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build):
untar, `source <suite>/environment`. Uses yosys,
nextpnr-himbaechel with Apicula, gowin_pack and
openFPGALoader.

## Build

```
make            # bitstream -> build/top.fs
make load       # program SRAM (volatile)
make flash      # program internal flash (persistent)
```

## Pins

From `constraints/tangnano9k.cst`:

| Signal | Pin | Notes |
|--------|-----|-------|
| `demod_clk`  | 51 | cable bit clock, 6.312 MHz, must be a global-clock pin |
| `demod_data` | 41 | cable data, sampled on the rising clock edge |
| `uart_rxd` / `uart_txd` | 18 / 17 | wired to the on-board USB UART bridge, pins 27/28 for an external RS-422 transceiver |
| `pll_enb` / `pll_clk` / `pll_data` | 29 / 30 / 25 | MC145155 tuner PLL serial interface |
| `clk27` | 52 | board oscillator |
| `led[5:0]` | 10, 11, 13, 14, 15, 16 | active low |

The whole design runs from `demod_clk`: without a continuous bit clock
the CPU, UART and receive chain are halted. The CPU bus rate,
the firmware's ~1066 Hz timer input and the 111,860 baud UART clock
are all derived from it.

LEDs: `led[0]` heartbeat (from `clk27`), `led[1]` cable activity,
`led[2]` MESSAGE, `led[3]` LINK, `led[5:4]` unused.

## Unit address

The clone's unit address is the `ID` parameter of `rtl/pal.v` (default
`32'h80011887`). It can be any value with the top bit set, and the
headend must address unit grants and messages to the same value. Broadcast
(`FFFFFFFF`) packets are received whatever the ID.

## Layout

```
rtl/
  top.v           top level: clocks, port glue, LEDs
  descrambler.v   x^20 + x^3 + 1 self-synchronizing descrambler
  destuff.v       flag detection, zero-bit destuffing, byte assembly
  pal.v           addressing PAL
  capture_ctrl.v  FIFO capture control
  fifo.v          1 KB packet FIFO
  irq_gen.v       CPU interrupt generation
  uart.v          serial UART to the NABU PC
  cpu/
    x68705*.v, x6805*.v   MC68705P3 soft core (Coin-Op Collection)
    rom.v                 firmware ROM
    nabuna_fw.hex         original NA-2 MC6805 firmware image
constraints/
  tangnano9k.cst  Tang Nano 9K pin and I/O constraints
```

## License

Licensed under
[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/). See `LICENSE`.

The CPU core in `rtl/cpu/x68705*.v` and `rtl/cpu/x6805*.v` is from
[Coin-Op Collection](https://github.com/Coin-OpCollection) by atrac17, also under CC BY-NC 4.0.

`rtl/cpu/nabuna_fw.hex` is the original NABU adapter firmware and is
not covered by this license.
