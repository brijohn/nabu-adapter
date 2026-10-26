# NABU headend for GNU Radio

A live NABU cable headend built on GNU Radio. It generates a continuous
broadcast carousel: pak segments interleaved with stride pacing, Set
Tiers grants and live-clock time packets woven in, HDLC framed,
zero-stuffed and scrambled. It then modulates it to the NABU cable signal
(OQPSK with half-sine pulses, Q offset by half a symbol, 3.156 Msym/s at
4 samples per symbol).

It consists of three apps:

| App | Purpose |
|-----|---------|
| `nabu_headend_hackrf.py` | Transmits the headend through a HackRF |
| `nabu_headend_tcp.py` | Serves the signal as a cs8 TCP stream |
| `nabu_cw_cal.py` | Transmits a CW tone for setting the HackRF output level |

The carousel comes from a custom `wheel_source` block that wraps
libnabuwheel.

## Requirements

- GNU Radio 3.10, including GNU Radio Companion and gr-soapy
- yaml-cpp (`libyaml-cpp-dev`)
- pybind11
- For the HackRF apps: SoapySDR, libhackrf and SoapyHackRF

SoapyHackRF must include the `getSampleRateRange` fix (pothosware
SoapyHackRF #26). Older versions only accept whole-MHz sample rates and
reject the 12.624 Msps the headend needs. Build SoapyHackRF from current
master until a release includes the fix.

libnabuwheel is compiled into the module from `../../libnabuwheel` and is
not installed separately.

## Build

    cmake -B build
    cmake --build build
    sudo cmake --install build
    sudo ldconfig

Pass `-DNABUWHEEL_ROOT=/path/to/libnabuwheel` to use a libnabuwheel tree
somewhere else, and `-DENABLE_DOXYGEN=OFF` to skip the API docs.

## Configuration

All wheel policy lives in a YAML config file. Start from
`../configs/headend.yaml` and set `paks` to a directory of `.pak` segment
files. The config sets the pak directory, interleave width, stride, flag
counts, time packets and the grant list. Grants can be broadcast or
addressed to a single adapter's PAL address. Omitted keys take the standard
carousel defaults.

## Running

Both headend apps take the config with `-c`:

    nabu_headend_hackrf.py -c headend.yaml
    nabu_headend_tcp.py -c headend.yaml

`nabu_headend_hackrf.py` opens a window with the carrier frequency
(default 267.0125 MHz, CATV channel 31) and the HackRF TX VGA gain.
Connect the HackRF to the adapter or cable network by cable. The path
needs enough loss to bring the signal to the adapter's input level.
The default TX VGA assumes a 20 dB attenuation and produces about a
0 dBmV signal.

`nabu_headend_tcp.py` listens on port 5816 on all interfaces.

## Level calibration

`nabu_cw_cal.py` transmits a tone with the same power as the headend
signal. Its amplitude matches the modulator's constant 0.7 envelope, and
it uses the same sample rate and HackRF settings. To set the level:

1. Connect the HackRF to a signal level meter through the same cabling,
   attenuators or combiner you will use for the headend.
2. Run `nabu_cw_cal.py`. Set the carrier to the frequency your meter
   measures for the channel, and adjust TX VGA until the meter reads the
   level you want.
3. Run the headend with the same connection and TX VGA setting. Its
   signal arrives at the same level.

The tone is offset from the HackRF's tuned frequency, so the HackRF's
LO leakage does not affect the reading.

On a cable system, NABU's installation guidance puts the data carrier
about 10 dB below the video carriers. For a direct connection to an
adapter, about 0 dBmV at the adapter input is known to work: a real NA-2
boots the menu and loads programs reliably at that level.

## License

Licensed under the GNU General Public License v3.0 or later. See
`COPYING`.
