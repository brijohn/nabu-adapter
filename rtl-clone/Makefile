# NA-2 digital board clone - Tang Nano 9K build
# Toolchain: OSS CAD Suite

TOP        := top
RTL        := $(wildcard rtl/*.v) $(wildcard rtl/cpu/*.v)
FW         := rtl/cpu/nabuna_fw.hex
CST        := constraints/tangnano9k.cst
DEVICE     := GW1NR-LV9QN88PC6/I5
FAMILY     := GW1N-9C
BOARD      := tangnano9k
FREQ       := 27
BUILD      := build

all: $(BUILD)/$(TOP).fs

# setundef -zero resolves the CPU timer's unread PSC bit (tcr[3]),
# which yosys leaves high-impedance. The resulting undefined net
# produces an unplaceable buffer in nextpnr's clock placer.
$(BUILD)/$(TOP).json: $(RTL) $(FW)
	mkdir -p $(BUILD)
	yosys -p "read_verilog $(RTL); synth_gowin -top $(TOP); setundef -zero; opt_clean -purge; write_json $@"

$(BUILD)/$(TOP)_pnr.json: $(BUILD)/$(TOP).json $(CST)
	nextpnr-himbaechel --json $< --write $@ --freq $(FREQ) \
		--device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST)

$(BUILD)/$(TOP).fs: $(BUILD)/$(TOP)_pnr.json
	gowin_pack -d $(FAMILY) -o $@ $<

# volatile load (SRAM) / persistent (internal flash)
load: $(BUILD)/$(TOP).fs
	openFPGALoader -b $(BOARD) $<

flash: $(BUILD)/$(TOP).fs
	openFPGALoader -b $(BOARD) -f $<

clean:
	rm -rf $(BUILD)

.PHONY: all load flash clean
