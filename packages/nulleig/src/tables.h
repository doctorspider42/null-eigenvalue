// tables.h - the oscillator bank.
//
// Every pitched voice reads from band-limited wavetables rather than computing
// a waveform per sample. Two reasons, both about this particular instrument:
//
//  1. Aliasing. A drone gives you all day to hear it. A naive saw at 55 Hz
//     folds a full spectrum back down and it never stops, so it is not a
//     detail you get to skip. Mip-mapped additive tables are aliasing-free by
//     construction: a table simply does not contain a partial above Nyquist.
//
//  2. Timbre is a control-rate parameter here, not a switch. The engine morphs
//     continuously from sine through organ and saw to a bright glassy spectrum
//     as the field moves, and a two-table crossfade does that for the price of
//     one extra lookup - no table rebuilding, so nothing can click.
#pragma once

#include <cmath>
#include <vector>

#include "dsp.h"

namespace ne {

class WaveBank {
 public:
    static constexpr int kShapes = 4;
    static constexpr int kMips = 11;
    static constexpr int kLen = 2048;
    static constexpr float kMipBase = 16.0f;  // Hz covered by mip 0
    static constexpr int kMaxHarm = 96;

    void build(float sample_rate) {
        sr_ = sample_rate;
        data_.assign((size_t)kShapes * kMips * (kLen + 1), 0.0f);
        const float nyq = sr_ * 0.47f;
        for (int s = 0; s < kShapes; ++s) {
            for (int m = 0; m < kMips; ++m) {
                float top_fundamental = kMipBase * std::pow(2.0f, (float)(m + 1));
                int max_h = (int)(nyq / top_fundamental);
                if (max_h > kMaxHarm) max_h = kMaxHarm;
                if (max_h < 1) max_h = 1;
                float* t = &data_[slot(s, m)];
                float peak = 0.0f;
                for (int i = 0; i < kLen; ++i) {
                    float ph = kTwoPi * (float)i / (float)kLen;
                    float v = 0.0f;
                    for (int h = 1; h <= max_h; ++h) {
                        float a = harmonic(s, h);
                        if (a != 0.0f) v += a * std::sin(ph * (float)h);
                    }
                    t[i] = v;
                    float av = std::fabs(v);
                    if (av > peak) peak = av;
                }
                float g = peak > 1e-6f ? 1.0f / peak : 1.0f;
                for (int i = 0; i < kLen; ++i) t[i] *= g;
                t[kLen] = t[0];  // guard sample, so interpolation never wraps
            }
        }
    }

    // Which mip a fundamental belongs in. Deliberately one step conservative
    // at the boundary: detuned unison copies sit slightly above their nominal
    // pitch and must not tip over into an under-band-limited table.
    inline int mip_for(float hz) const {
        if (hz <= kMipBase) return 0;
        int m = (int)std::floor(std::log2(hz / kMipBase));
        if (m < 0) m = 0;
        if (m >= kMips) m = kMips - 1;
        return m;
    }

    // `phase` 0..1, `morph` 0..kShapes-1 continuous.
    inline float read(float phase, float morph, int mip) const {
        float fp = phase * (float)kLen;
        int i = (int)fp;
        float frac = fp - (float)i;
        if (i >= kLen) i = kLen - 1;

        int s0 = (int)morph;
        if (s0 < 0) s0 = 0;
        if (s0 > kShapes - 2) s0 = kShapes - 2;
        float sf = morph - (float)s0;
        sf = clampf(sf, 0.0f, 1.0f);

        const float* a = &data_[slot(s0, mip)];
        const float* b = &data_[slot(s0 + 1, mip)];
        float va = a[i] + (a[i + 1] - a[i]) * frac;
        float vb = b[i] + (b[i + 1] - b[i]) * frac;
        return va + (vb - va) * sf;
    }

 private:
    static size_t slot(int shape, int mip) {
        return ((size_t)shape * kMips + (size_t)mip) * (size_t)(kLen + 1);
    }

    // The four spectra, in order of brightness. Morphing is a straight
    // crossfade between neighbours, so they are ordered to make that a
    // musically sensible path: sine -> organ -> saw -> glass.
    static float harmonic(int shape, int h) {
        switch (shape) {
            case 0:  // sine
                return h == 1 ? 1.0f : 0.0f;
            case 1: {  // organ drawbars: octaves and fifths, nothing gritty
                switch (h) {
                    case 1: return 1.0f;
                    case 2: return 0.50f;
                    case 3: return 0.28f;
                    case 4: return 0.20f;
                    case 6: return 0.11f;
                    case 8: return 0.07f;
                    case 12: return 0.04f;
                    default: return 0.0f;
                }
            }
            case 2:  // saw, gently rolled off so the top mip is not fizzy
                return (1.0f / (float)h) * std::exp(-(float)h / 42.0f);
            default: {
                // "Glass": odd partials with a formant bump around the 7th-11th.
                // Bell-adjacent without being inharmonic, which matters because
                // these voices are held for minutes and true inharmonicity
                // beats against itself.
                if ((h & 1) == 0) return 0.12f / (float)h;
                float base = std::pow((float)h, -0.72f);
                float d = ((float)h - 9.0f) / 4.5f;
                float bump = 1.0f + 1.6f * std::exp(-d * d);
                return base * bump * std::exp(-(float)h / 30.0f);
            }
        }
    }

    std::vector<float> data_;
    float sr_ = 48000.0f;
};

}  // namespace ne
