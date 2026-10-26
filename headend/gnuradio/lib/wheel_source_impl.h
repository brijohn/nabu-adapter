/* -*- c++ -*- */
/*
 * Copyright 2026 Brian Johnson.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef INCLUDED_NABU_HEADEND_WHEEL_SOURCE_IMPL_H
#define INCLUDED_NABU_HEADEND_WHEEL_SOURCE_IMPL_H

#include <cstdint>
#include <vector>

#include <gnuradio/nabu_headend/wheel_source.h>

#include <nabuwheel.h>

namespace gr {
namespace nabu_headend {

class wheel_source_impl : public wheel_source
{
private:
    // backing storage the wheel points into, never resized or reallocated after init
    std::vector<std::vector<uint8_t>> d_pak_data;
    std::vector<std::vector<nw_packet>> d_packets;
    std::vector<nw_segment> d_segments;
    std::vector<nw_grant> d_grants;
    std::vector<uint16_t> d_cursors;
    std::vector<uint16_t> d_pool;

    nw_params d_params;
    nw_wheel d_wheel;
    nw_scrambler d_scrambler;

    void load_config(const std::string& config_file, std::string& pak_dir);
    void load_paks(const std::string& pak_dir);

public:
    wheel_source_impl(const std::string& config_file);
    ~wheel_source_impl() override;

    int work(int noutput_items,
             gr_vector_const_void_star& input_items,
             gr_vector_void_star& output_items) override;
};

} // namespace nabu_headend
} // namespace gr

#endif /* INCLUDED_NABU_HEADEND_WHEEL_SOURCE_IMPL_H */
