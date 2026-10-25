# Convenience wrapper:
#   make          - configure (once) + build
#   make flash    - copy the UF2 to the mounted bootloader drive
#   make monitor  - open the USB CDC serial port with minicom
#   make clean    - remove the build directory

SDK   ?= $(PICO_SDK_PATH)
BUILD ?= build
UF2    = $(BUILD)/nabu_datapump.uf2

all: $(BUILD)/CMakeCache.txt
	cmake --build $(BUILD) -j

$(BUILD)/CMakeCache.txt: CMakeLists.txt
	@if [ -z "$(SDK)" ]; then \
		echo "pico-sdk not found: set PICO_SDK_PATH or pass SDK=/path/to/pico-sdk"; \
		exit 1; \
	fi
	cmake -B $(BUILD) -DPICO_SDK_PATH=$(SDK)

flash: all
	@MNT=$$(ls -d /media/$$USER/RP2350 /media/$$USER/RPI-RP2 2>/dev/null | head -1); \
	if [ -z "$$MNT" ]; then \
		echo "No bootloader drive found. Hold BOOTSEL while plugging in, then retry."; \
		exit 1; \
	fi; \
	cp $(UF2) "$$MNT"/ && sync && echo "Flashed $(UF2) -> $$MNT"

monitor:
	minicom -b 115200 -o -D $$(ls /dev/ttyACM* | head -1)

clean:
	rm -rf $(BUILD)

.PHONY: all flash monitor clean
