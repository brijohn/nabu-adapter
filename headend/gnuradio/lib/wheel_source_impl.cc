/* -*- c++ -*- */
/*
 * Copyright 2026 Brian Johnson.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "wheel_source_impl.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <set>
#include <stdexcept>

#include <gnuradio/io_signature.h>
#include <yaml-cpp/yaml.h>

namespace gr {
namespace nabu_headend {

namespace fs = std::filesystem;

wheel_source::sptr wheel_source::make(const std::string& config_file)
{
    return gnuradio::make_block_sptr<wheel_source_impl>(config_file);
}

// time packets are rendered from the system clock at emission
static void system_clock(void* /*ctx*/, nw_time* out)
{
    time_t now = time(nullptr);
    struct tm tm;
    localtime_r(&now, &tm);
    out->wday = uint8_t(tm.tm_wday);
    out->mon = uint8_t(tm.tm_mon);
    out->mday = uint8_t(tm.tm_mday);
    out->hour = uint8_t(tm.tm_hour);
    out->min = uint8_t(tm.tm_min);
    out->sec = uint8_t(tm.tm_sec);
}

// 0x-prefixed hex word of 1 to 8 digits
static uint32_t parse_hex(const YAML::Node& n, const char* what)
{
    const std::string s = n.as<std::string>();
    const bool prefixed = s.size() > 2 && s.size() <= 10 && s[0] == '0' &&
                          (s[1] == 'x' || s[1] == 'X');
    size_t pos = 0;
    const unsigned long value = prefixed ? std::stoul(s, &pos, 16) : 0;
    if (!prefixed || pos != s.size()) {
        throw std::runtime_error(std::string("headend config: bad value for ") + what +
                                 ": '" + s + "'");
    }
    return uint32_t(value);
}

// "broadcast" or a hex PAL address
static uint32_t parse_palid(const YAML::Node& n)
{
    if (n.as<std::string>() == "broadcast") {
        return NW_BROADCAST;
    }
    return parse_hex(n, "palid");
}

static void check_keys(const YAML::Node& node, const std::set<std::string>& known, const char* where)
{
    for (const auto& kv : node) {
        const std::string key = kv.first.as<std::string>();
        if (!known.count(key)) {
            throw std::runtime_error(std::string("headend config: unknown key '") +
                                     key + "' in " + where);
        }
    }
}

void wheel_source_impl::load_config(const std::string& config_file, std::string& pak_dir)
{
    YAML::Node root = YAML::LoadFile(config_file);
    check_keys(root,
               { "paks", "interleave", "min_stride_ms", "lead_flags",
                 "trail_flags", "idle_flags", "control_gap_flags",
                 "filler_span_bits", "time_frames", "grants" },
               "top level");

    if (!root["paks"]) {
        throw std::runtime_error("headend config: 'paks' (pak directory) is required");
    }
    pak_dir = root["paks"].as<std::string>();

    // defaults are the standard carousel policy
    d_params = nw_params{};
    d_params.interleave = root["interleave"] ? root["interleave"].as<uint16_t>() : 192;
    d_params.min_stride_ms = root["min_stride_ms"] ? root["min_stride_ms"].as<uint32_t>() : 250;
    d_params.lead_flags = root["lead_flags"] ? root["lead_flags"].as<uint16_t>() : 8;
    d_params.trail_flags = root["trail_flags"] ? root["trail_flags"].as<uint16_t>() : 2;
    d_params.idle_flags = root["idle_flags"] ? root["idle_flags"].as<uint32_t>() : 256;
    d_params.control_gap_flags =
        root["control_gap_flags"] ? root["control_gap_flags"].as<uint32_t>() : 16384;
    d_params.filler_span_bits =
        root["filler_span_bits"] ? root["filler_span_bits"].as<uint32_t>() : 140000;
    d_params.time_frames = !root["time_frames"] || root["time_frames"].as<bool>();

    if (root["grants"]) {
        for (const auto& g : root["grants"]) {
            check_keys(g, { "palid", "tiers", "every_ms", "phase_ms" }, "grants entry");
            nw_grant grant{};
            grant.palid = g["palid"] ? parse_palid(g["palid"]) : NW_BROADCAST;
            grant.tiers = g["tiers"] ? parse_hex(g["tiers"], "tiers") : 0x7FFFFFFF;
            grant.every_ms = g["every_ms"] ? g["every_ms"].as<uint32_t>() : 750;
            grant.phase_ms = g["phase_ms"] ? g["phase_ms"].as<uint32_t>() : 750;
            d_grants.push_back(grant);
        }
    } else {
        // standard broadcast all tiers grant
        d_grants.push_back(nw_grant{ NW_BROADCAST, 0x7FFFFFFF, 750, 750 });
    }
    if (d_grants.size() > NW_MAX_ENTRIES) {
        throw std::runtime_error("headend config: too many grants");
    }
    d_params.grants = d_grants.data();
    d_params.n_grants = uint16_t(d_grants.size());
}

void wheel_source_impl::load_paks(const std::string& pak_dir)
{
    std::vector<fs::path> files;
    for (const auto& entry : fs::directory_iterator(pak_dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        std::string ext = entry.path().extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
        if (ext == ".pak") {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());
    if (files.empty()) {
        throw std::runtime_error("headend config: no .pak files in " + pak_dir);
    }

    for (const auto& path : files) {
        std::ifstream f(path, std::ios::binary);
        std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)),
                                  std::istreambuf_iterator<char>());
        if (data.empty()) {
            continue;
        }

        std::vector<nw_packet> pkts(data.size() / 20 + 1);
        const int n = nw_pak_slice(data.data(), data.size(), pkts.data(),
                                   uint16_t(std::min<size_t>(pkts.size(), 65535)));
        if (n <= 0) {
            continue;
        }
        pkts.resize(size_t(n));

        d_pak_data.push_back(std::move(data));
        d_packets.push_back(std::move(pkts));
        d_segments.push_back(nw_segment{ d_packets.back().data(), uint16_t(d_packets.back().size()) });
    }
}

wheel_source_impl::wheel_source_impl(const std::string& config_file)
    : gr::sync_block("wheel_source",
                     gr::io_signature::make(0, 0, 0),
                     gr::io_signature::make(1, 1, sizeof(uint8_t)))
{
    std::string pak_dir;
    load_config(config_file, pak_dir);
    load_paks(pak_dir);

    d_cursors.resize(d_segments.size());
    d_pool.resize(d_params.interleave);
    d_scrambler = nw_scrambler{ 0 };

    if (nw_wheel_init(&d_wheel, &d_params, d_segments.data(),
                      uint16_t(d_segments.size()), system_clock, nullptr,
                      d_cursors.data(), d_pool.data())) {
        throw std::runtime_error("headend config: nw_wheel_init failed "
                                 "(no packets, or bad parameters)");
    }
}

wheel_source_impl::~wheel_source_impl() {}

int wheel_source_impl::work(int noutput_items,
                            gr_vector_const_void_star& input_items,
                            gr_vector_void_star& output_items)
{
    auto out = static_cast<uint8_t*>(output_items[0]);
    nw_wheel_read(&d_wheel, &d_scrambler, out, size_t(noutput_items));
    return noutput_items;
}

} // namespace nabu_headend
} // namespace gr
