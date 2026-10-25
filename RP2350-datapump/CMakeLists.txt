cmake_minimum_required(VERSION 3.13)

# Target board: Raspberry Pi Pico 2 (RP2350, ARM cores)
set(PICO_BOARD pico2 CACHE STRING "Board type")

# Locate the pico-sdk: -DPICO_SDK_PATH, else $PICO_SDK_PATH
if(NOT DEFINED PICO_SDK_PATH)
    if(DEFINED ENV{PICO_SDK_PATH})
        set(PICO_SDK_PATH $ENV{PICO_SDK_PATH})
    else()
        message(FATAL_ERROR "pico-sdk not found: set PICO_SDK_PATH or pass -DPICO_SDK_PATH=/path/to/pico-sdk")
    endif()
endif()
include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(nabu_datapump C CXX ASM)
set(CMAKE_C_STANDARD 11)

pico_sdk_init()

add_executable(nabu_datapump
    src/main.c
    src/crc16_genibus.c
)

target_include_directories(nabu_datapump PRIVATE src)

# Assembles src/nabu_tx.pio -> nabu_tx.pio.h at build time
pico_generate_pio_header(nabu_datapump ${CMAKE_CURRENT_LIST_DIR}/src/nabu_tx.pio)

target_link_libraries(nabu_datapump
    pico_stdlib
    pico_multicore
    hardware_pio
    hardware_dma
)

# stdio over USB CDC
pico_enable_stdio_usb(nabu_datapump 1)
pico_enable_stdio_uart(nabu_datapump 0)

# Produce .uf2 alongside the .elf
pico_add_extra_outputs(nabu_datapump)
