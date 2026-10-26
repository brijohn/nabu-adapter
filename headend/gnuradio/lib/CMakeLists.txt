# Copyright 2011,2012,2016,2018,2019 Free Software Foundation, Inc.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

########################################################################
# Setup library
########################################################################
include(GrPlatform) #define LIB_SUFFIX

# the wheel generator core is compiled in from its own source tree
set(NABUWHEEL_ROOT "${PROJECT_SOURCE_DIR}/../../libnabuwheel"
    CACHE PATH "Path to the libnabuwheel source tree")
if(NOT EXISTS "${NABUWHEEL_ROOT}/include/nabuwheel.h")
    message(FATAL_ERROR "libnabuwheel not found at ${NABUWHEEL_ROOT}, set -DNABUWHEEL_ROOT")
endif()

find_package(yaml-cpp REQUIRED)

list(APPEND nabu_headend_sources
    wheel_source_impl.cc
    ${NABUWHEEL_ROOT}/src/wheel.c
    ${NABUWHEEL_ROOT}/src/scramble.c
    ${NABUWHEEL_ROOT}/src/pak.c
    ${NABUWHEEL_ROOT}/src/packets.c)

set(nabu_headend_sources
    "${nabu_headend_sources}"
    PARENT_SCOPE)
if(NOT nabu_headend_sources)
    message(STATUS "No C++ sources... skipping lib/")
    return()
endif(NOT nabu_headend_sources)

add_library(gnuradio-nabu_headend SHARED ${nabu_headend_sources})
if(TARGET yaml-cpp::yaml-cpp)
    target_link_libraries(gnuradio-nabu_headend gnuradio::gnuradio-runtime yaml-cpp::yaml-cpp)
else()
    target_link_libraries(gnuradio-nabu_headend gnuradio::gnuradio-runtime yaml-cpp)
endif()
target_include_directories(
    gnuradio-nabu_headend
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/../include>
    PUBLIC $<INSTALL_INTERFACE:include>
    PRIVATE ${NABUWHEEL_ROOT}/include ${NABUWHEEL_ROOT}/src)
set_target_properties(gnuradio-nabu_headend PROPERTIES DEFINE_SYMBOL "gnuradio_nabu_headend_EXPORTS")

if(APPLE)
    set_target_properties(gnuradio-nabu_headend PROPERTIES INSTALL_NAME_DIR
                                                    "${CMAKE_INSTALL_PREFIX}/lib")
endif(APPLE)

########################################################################
# Install built library files
########################################################################
include(GrMiscUtils)
gr_library_foo(gnuradio-nabu_headend)

########################################################################
# Print summary
########################################################################
message(STATUS "Using install prefix: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "Building for version: ${VERSION} / ${LIBVER}")

########################################################################
# Build and register unit test
########################################################################
include(GrTest)

# If your unit tests require special include paths, add them here
#include_directories()
# List all files that contain Boost.UTF unit tests here
list(APPEND test_nabu_headend_sources)
# Anything we need to link to for the unit tests go here
list(APPEND GR_TEST_TARGET_DEPS gnuradio-nabu_headend)

if(NOT test_nabu_headend_sources)
    message(STATUS "No C++ unit tests... skipping")
    return()
endif(NOT test_nabu_headend_sources)

foreach(qa_file ${test_nabu_headend_sources})
    gr_add_cpp_test("nabu_headend_${qa_file}" ${CMAKE_CURRENT_SOURCE_DIR}/${qa_file})
endforeach(qa_file)
