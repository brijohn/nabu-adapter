# Copyright 2026 Brian Johnson
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
include(GrPython)

find_program(GRCC_EXECUTABLE grcc REQUIRED)

set(nabu_headend_apps
    nabu_headend_hackrf
    nabu_headend_tcp
    nabu_cw_cal)

foreach(app ${nabu_headend_apps})
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/${app}.py
        COMMAND ${CMAKE_COMMAND} -E env GRC_BLOCKS_PATH=${PROJECT_SOURCE_DIR}/grc
                ${GRCC_EXECUTABLE} -o ${CMAKE_CURRENT_BINARY_DIR}
                ${CMAKE_CURRENT_SOURCE_DIR}/${app}.grc
        DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/${app}.grc
                ${PROJECT_SOURCE_DIR}/grc/nabu_headend_wheel_source.block.yml)
    list(APPEND nabu_headend_app_scripts ${CMAKE_CURRENT_BINARY_DIR}/${app}.py)
endforeach()

add_custom_target(nabu_headend_apps ALL DEPENDS ${nabu_headend_app_scripts})

gr_python_install(PROGRAMS ${nabu_headend_app_scripts} DESTINATION bin)
