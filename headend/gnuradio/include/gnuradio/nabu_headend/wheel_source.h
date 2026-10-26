/* -*- c++ -*- */
/*
 * Copyright 2026 Brian Johnson.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef INCLUDED_NABU_HEADEND_WHEEL_SOURCE_H
#define INCLUDED_NABU_HEADEND_WHEEL_SOURCE_H

#include <gnuradio/nabu_headend/api.h>
#include <gnuradio/sync_block.h>

namespace gr {
namespace nabu_headend {

/*!
 * \brief Live NABU cable headend carousel, as packed line bytes.
 * \ingroup nabu_headend
 *
 * Streams a continuously generated broadcast wheel (libnabuwheel):
 * pak segments interleaved round-robin with stride pacing, Set
 * Tiers grants and time packets woven in, HDLC framing with zero
 * stuffing, and the x^20+x^3+1 inverting scrambler. Output is the
 * cable line bit stream - 8 line bits per byte, MSB first, 6.312
 * Mbit/s. Time packets carry the system clock at the moment they
 * are emitted. The block never underruns: idle
 * flags fill whenever no frame is due, so the carrier never pauses.
 *
 * All policy comes from a YAML config file: the pak directory,
 * interleave width, stride, flag counts, time weaving, and the
 * grant list (broadcast or unit-addressed). Unknown keys are an
 * error, and omitted keys take the standard carousel defaults.
 */
class NABU_HEADEND_API wheel_source : virtual public gr::sync_block
{
public:
    typedef std::shared_ptr<wheel_source> sptr;

    /*!
     * \brief Create a wheel source.
     * \param config_file path to the headend YAML config
     */
    static sptr make(const std::string& config_file);
};

} // namespace nabu_headend
} // namespace gr

#endif /* INCLUDED_NABU_HEADEND_WHEEL_SOURCE_H */
