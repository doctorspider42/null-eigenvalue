// dsp.h - the primitives. Header-only, no allocation past construction, every
// process() safe to call from an audio callback.
//
// Nothing here is novel; it is written out rather than pulled in because the
// whole point of this repo is that one C++ core compiles for iOS, Android and
// a desktop test harness with no dependency but the standard library.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace ne {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kTwoPi = 6.28318530717958647692f;

inline float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}
inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }

// Smoothstep, used everywhere a gate would otherwise click.
inline float smoothstepf(float t) {
    t = clampf(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// Denormals cost more than they are worth in a reverb tail that decays for
// thirty seconds; flush anything inaudible to zero.
inline float undenorm(float v) {
    return (v > -1e-25f && v < 1e-25f) ? 0.0f : v;
}

// --------------------------------------------------------------------- random

// PCG32. Small, fast, and - the reason it is here rather than rand() - it is
// seedable per stream, so voice drift, bell placement and the harmonic walk
// can each have their own reproducible sequence.
struct Rng {
    uint64_t state = 0x853c49e6748fea9bULL;
    uint64_t inc = 0xda3e39cb94b95bdbULL;

    void seed(uint64_t s, uint64_t stream = 1) {
        state = 0;
        inc = (stream << 1u) | 1u;
        next();
        state += s;
        next();
    }
    uint32_t next() {
        uint64_t old = state;
        state = old * 6364136223846793005ULL + inc;
        uint32_t xorshifted = (uint32_t)(((old >> 18u) ^ old) >> 27u);
        uint32_t rot = (uint32_t)(old >> 59u);
        return (xorshifted >> rot) | (xorshifted << ((32u - rot) & 31u));
    }
    float uni() { return (float)(next() >> 8) * (1.0f / 16777216.0f); }  // [0,1)
    float bi() { return uni() * 2.0f - 1.0f; }                          // [-1,1)
    int range(int n) { return n <= 1 ? 0 : (int)(next() % (uint32_t)n); }
};

// ------------------------------------------------------------------- one-pole

// The workhorse smoother. `set_time` is a 63% time constant in seconds.
struct OnePole {
    float a = 0.0f, z = 0.0f;
    void set_time(float seconds, float sr) {
        a = (seconds <= 0.0f) ? 1.0f : 1.0f - std::exp(-1.0f / (seconds * sr));
    }
    void set_cutoff(float hz, float sr) {
        float x = std::exp(-kTwoPi * clampf(hz, 1.0f, sr * 0.49f) / sr);
        a = 1.0f - x;
    }
    inline float process(float in) {
        z += a * (in - z);
        return z = undenorm(z);
    }
    void reset(float v = 0.0f) { z = v; }
};

// --------------------------------------------------------------------- filter

// Topology-preserving state variable filter (Zavalishin). Chosen over a biquad
// because it stays stable while its cutoff is being modulated every sample,
// which is exactly what happens here.
struct Svf {
    float g = 0.0f, k = 1.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
    float ic1 = 0.0f, ic2 = 0.0f;

    void set(float cutoff_hz, float res, float sr) {
        float fc = clampf(cutoff_hz, 10.0f, sr * 0.48f);
        g = std::tan(kPi * fc / sr);
        k = 2.0f - 2.0f * clampf(res, 0.0f, 0.97f);
        a1 = 1.0f / (1.0f + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
    // Returns low, and leaves band/high available for the caller.
    inline void process(float v0, float& lo, float& band, float& hi) {
        float v3 = v0 - ic2;
        float v1 = a1 * ic1 + a2 * v3;
        float v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = undenorm(2.0f * v1 - ic1);
        ic2 = undenorm(2.0f * v2 - ic2);
        lo = v2;
        band = v1;
        hi = v0 - k * v1 - v2;
    }
    inline float low(float v0) {
        float lo, bp, hi;
        process(v0, lo, bp, hi);
        return lo;
    }
    inline float high(float v0) {
        float lo, bp, hi;
        process(v0, lo, bp, hi);
        return hi;
    }
    inline float band(float v0) {
        float lo, bp, hi;
        process(v0, lo, bp, hi);
        return bp;
    }
    void reset() { ic1 = ic2 = 0.0f; }
};

// A 6 dB/oct pair used for the master tilt: nudge the balance of the whole mix
// without a shelving filter's phase mess.
struct Tilt {
    OnePole lp;
    void prepare(float sr) { lp.set_cutoff(700.0f, sr); }
    // `amount` -1 dark .. +1 bright
    inline float process(float in, float amount) {
        float low = lp.process(in);
        float high = in - low;
        return low * (1.0f - 0.7f * amount) + high * (1.0f + 0.7f * amount);
    }
};

// ----------------------------------------------------------------- delay line

// Power-of-two ring with linear-interpolated fractional reads. Fractional
// because every delay in this engine is modulated: a chorus tap, an FDN line
// whose length breathes, a pitch shifter's read head.
struct DelayLine {
    std::vector<float> buf;
    uint32_t mask = 0;
    uint32_t w = 0;

    void prepare(int max_samples) {
        uint32_t n = 16;
        while (n < (uint32_t)max_samples + 4) n <<= 1;
        buf.assign(n, 0.0f);
        mask = n - 1;
        w = 0;
    }
    void clear() { std::fill(buf.begin(), buf.end(), 0.0f); }
    inline void write(float v) {
        buf[w] = v;
        w = (w + 1) & mask;
    }
    inline float read(float delay_samples) const {
        float d = delay_samples;
        if (d < 1.0f) d = 1.0f;
        float fpos = (float)w - d;
        int32_t i = (int32_t)std::floor(fpos);
        float frac = fpos - (float)i;
        uint32_t i0 = (uint32_t)(i) & mask;
        uint32_t i1 = (i0 + 1) & mask;
        return buf[i0] + (buf[i1] - buf[i0]) * frac;
    }
    inline float read_int(int delay_samples) const {
        return buf[(w - (uint32_t)delay_samples) & mask];
    }
};

// Schroeder allpass, the input diffuser of the reverb.
struct Allpass {
    DelayLine d;
    int len = 1;
    float gain = 0.5f;
    void prepare(int samples) {
        len = samples < 1 ? 1 : samples;
        d.prepare(len + 8);
    }
    inline float process(float in) {
        float delayed = d.read_int(len);
        float v = in + delayed * gain;
        d.write(v);
        return delayed - v * gain;
    }
};

// ------------------------------------------------------------- FDN reverb

// Eight lines mixed by a Hadamard matrix. A comb bank is the usual cheap
// choice and it is the wrong one here: this engine's whole reason to exist is
// a tail that runs for twenty seconds, and combs ring metallic long before
// that. An orthogonal matrix keeps the mode density high and the decay smooth.
//
// Extras that matter audibly: per-line damping (a room loses treble first),
// a low cut inside the loop (otherwise the sub piles up until it is the only
// thing left), slowly modulated line lengths (kills the static ringing that
// gives a fixed FDN its "flanged" character) and a pitch-shifted feedback path
// - shimmer, the sound everyone actually means when they say ambient reverb.
struct Fdn {
    static constexpr int kLines = 8;

    DelayLine line[kLines];
    OnePole damp[kLines];
    float hp_z[kLines] = {};
    float base_len[kLines] = {};
    float mod_phase[kLines] = {};
    float mod_rate[kLines] = {};

    Allpass diffuser[4];
    DelayLine predelay;

    // Shimmer: two overlapping windows reading the tail faster than it is
    // written, crossfaded so the seams sit under the tail rather than on it.
    DelayLine shim;
    float shim_pos = 0.0f;
    float shim_len = 0.0f;
    OnePole shim_lp;

    float sr = 48000.0f;
    float fb = 0.7f;
    float size = 0.7f;
    float hp_coef = 0.0f;
    float shim_amt = 0.0f;
    float shim_ratio = 2.0f;

    void prepare(float sample_rate) {
        sr = sample_rate;
        // Mutually prime-ish lengths in milliseconds; the spread matters more
        // than the exact values.
        static const float ms[kLines] = {43.7f,  57.3f,  71.1f,  89.9f,
                                         103.3f, 127.7f, 149.1f, 173.9f};
        for (int i = 0; i < kLines; ++i) {
            base_len[i] = ms[i] * 0.001f * sr;
            line[i].prepare((int)(base_len[i] * 2.5f) + 64);
            damp[i].set_cutoff(6000.0f, sr);
            mod_phase[i] = (float)i * 0.618034f;
            mod_rate[i] = 0.07f + 0.031f * (float)i;  // Hz, all different
            hp_z[i] = 0.0f;
        }
        static const float dms[4] = {13.7f, 19.3f, 27.1f, 34.9f};
        for (int i = 0; i < 4; ++i) {
            diffuser[i].prepare((int)(dms[i] * 0.001f * sr));
            diffuser[i].gain = 0.62f;
        }
        predelay.prepare((int)(0.25f * sr) + 64);
        shim.prepare((int)(0.5f * sr) + 64);
        shim_len = 0.09f * sr;
        shim_pos = 0.0f;
        shim_lp.set_cutoff(4200.0f, sr);
        set_low_cut(110.0f);
    }

    void clear() {
        for (int i = 0; i < kLines; ++i) {
            line[i].clear();
            damp[i].reset();
            hp_z[i] = 0.0f;
        }
        for (int i = 0; i < 4; ++i) diffuser[i].d.clear();
        predelay.clear();
        shim.clear();
    }

    void set_low_cut(float hz) {
        hp_coef = std::exp(-kTwoPi * clampf(hz, 20.0f, 800.0f) / sr);
    }
    // RT60 in seconds -> per-line feedback gain. Uses the mean line length,
    // which is close enough given the lines are within a factor of four.
    void set_decay(float rt60_sec, float size01) {
        size = clampf(size01, 0.2f, 1.4f);
        float mean = 0.0f;
        for (int i = 0; i < kLines; ++i) mean += base_len[i] * size;
        mean /= (float)kLines;
        float loops = rt60_sec * sr / mean;
        fb = (loops < 0.5f) ? 0.0f : std::pow(10.0f, -3.0f / loops);
        fb = clampf(fb, 0.0f, 0.9995f);
    }
    void set_damping(float hz) {
        for (int i = 0; i < kLines; ++i) damp[i].set_cutoff(hz, sr);
    }
    void set_diffusion(float d) {
        for (int i = 0; i < 4; ++i) diffuser[i].gain = 0.35f + 0.35f * clampf(d, 0.0f, 1.0f);
    }
    void set_shimmer(float amount, float semitones) {
        shim_amt = clampf(amount, 0.0f, 1.0f);
        shim_ratio = std::pow(2.0f, semitones / 12.0f);
    }

    // in_l/in_r are the send; out_l/out_r are 100% wet.
    inline void process(float in_l, float in_r, float predelay_samples,
                        float& out_l, float& out_r) {
        float mono = (in_l + in_r) * 0.5f;
        predelay.write(mono);
        float x = predelay.read(predelay_samples);
        for (int i = 0; i < 4; ++i) x = diffuser[i].process(x);

        float v[kLines];
        for (int i = 0; i < kLines; ++i) {
            mod_phase[i] += mod_rate[i] / sr;
            if (mod_phase[i] >= 1.0f) mod_phase[i] -= 1.0f;
            float wobble = std::sin(kTwoPi * mod_phase[i]) * (base_len[i] * 0.0025f);
            v[i] = line[i].read(base_len[i] * size + wobble);
        }

        // Fast Walsh-Hadamard, 3 butterfly stages, then 1/sqrt(8) to keep the
        // matrix orthonormal (otherwise the loop gain is off by 8x).
        for (int stride = 1; stride < kLines; stride <<= 1) {
            for (int i = 0; i < kLines; i += stride << 1) {
                for (int j = i; j < i + stride; ++j) {
                    float a = v[j], b = v[j + stride];
                    v[j] = a + b;
                    v[j + stride] = a - b;
                }
            }
        }
        const float norm = 0.35355339f;  // 1/sqrt(8)

        float shim_in = 0.0f;
        if (shim_amt > 0.0001f) {
            // Two windows a half-period apart, cosine-crossfaded.
            shim_pos += shim_ratio - 1.0f;
            if (shim_pos >= shim_len) shim_pos -= shim_len;
            float p1 = shim_pos;
            float p2 = shim_pos + shim_len * 0.5f;
            if (p2 >= shim_len) p2 -= shim_len;
            float w1 = 0.5f - 0.5f * std::cos(kTwoPi * p1 / shim_len);
            float w2 = 0.5f - 0.5f * std::cos(kTwoPi * p2 / shim_len);
            float s = shim.read(p1 + 2.0f) * w1 + shim.read(p2 + 2.0f) * w2;
            shim_in = shim_lp.process(s) * shim_amt * 0.7f;
        }

        for (int i = 0; i < kLines; ++i) {
            float y = v[i] * norm * fb;
            y = damp[i].process(y);
            // one-pole high pass inside the loop
            hp_z[i] = undenorm(hp_coef * hp_z[i] + (1.0f - hp_coef) * y);
            y -= hp_z[i];
            line[i].write(x + y + shim_in);
        }

        // Even lines left, odd lines right - cheap decorrelation that comes out
        // of the Hadamard mix already being uncorrelated.
        float l = 0.0f, r = 0.0f;
        for (int i = 0; i < kLines; i += 2) l += line[i].read_int(1);
        for (int i = 1; i < kLines; i += 2) r += line[i].read_int(1);
        l *= 0.25f;
        r *= 0.25f;
        if (shim_amt > 0.0001f) shim.write((l + r) * 0.5f);
        out_l = l;
        out_r = r;
    }
};

// ---------------------------------------------------------------------- delay

// Ping-pong echo with a damped feedback loop. Long times, high feedback: this
// is a texture generator, not a slapback.
struct PingPong {
    DelayLine l, r;
    OnePole damp_l, damp_r;
    float sr = 48000.0f;
    float time_samples = 24000.0f;
    float feedback = 0.55f;

    void prepare(float sample_rate, float max_seconds) {
        sr = sample_rate;
        l.prepare((int)(max_seconds * sr) + 64);
        r.prepare((int)(max_seconds * sr) + 64);
        damp_l.set_cutoff(3000.0f, sr);
        damp_r.set_cutoff(3000.0f, sr);
    }
    void clear() {
        l.clear();
        r.clear();
        damp_l.reset();
        damp_r.reset();
    }
    void set_damp(float hz) {
        damp_l.set_cutoff(hz, sr);
        damp_r.set_cutoff(hz, sr);
    }
    inline void process(float in_l, float in_r, float& out_l, float& out_r) {
        float dl = l.read(time_samples);
        float dr = r.read(time_samples);
        l.write(in_l + damp_r.process(dr) * feedback);
        r.write(in_r + damp_l.process(dl) * feedback);
        out_l = dl;
        out_r = dr;
    }
};

// --------------------------------------------------------------------- chorus

// Three modulated taps, spread across the field. What turns a stack of static
// oscillators into something that sounds like it has air around it.
struct Chorus {
    DelayLine dl, dr;
    float sr = 48000.0f;
    float phase = 0.0f;
    float rate = 0.19f;
    float depth = 0.5f;

    void prepare(float sample_rate) {
        sr = sample_rate;
        dl.prepare((int)(0.06f * sr) + 64);
        dr.prepare((int)(0.06f * sr) + 64);
    }
    void clear() {
        dl.clear();
        dr.clear();
    }
    inline void process(float in_l, float in_r, float mix, float& out_l, float& out_r) {
        phase += rate / sr;
        if (phase >= 1.0f) phase -= 1.0f;
        float base = 0.012f * sr;
        float span = 0.008f * sr * depth;
        float m0 = std::sin(kTwoPi * phase);
        float m1 = std::sin(kTwoPi * (phase + 0.333f));
        float m2 = std::sin(kTwoPi * (phase + 0.666f));
        dl.write(in_l);
        dr.write(in_r);
        float wl = dl.read(base + span * m0) * 0.6f + dr.read(base * 1.4f + span * m2) * 0.4f;
        float wr = dr.read(base * 1.2f + span * m1) * 0.6f + dl.read(base * 1.7f - span * m0) * 0.4f;
        out_l = lerpf(in_l, wl, mix);
        out_r = lerpf(in_r, wr, mix);
    }
};

// -------------------------------------------------------------------- limiter

// Peak follower with a fast attack and a very slow release. On a drone the
// release time is the only setting that matters: anything under a second and
// the swells breathe audibly.
struct Limiter {
    float env = 0.0f;
    float at = 0.0f, rel = 0.0f;
    float ceiling = 0.94f;

    void prepare(float sr) {
        at = 1.0f - std::exp(-1.0f / (0.003f * sr));
        rel = 1.0f - std::exp(-1.0f / (1.6f * sr));
    }
    inline void process(float& l, float& r) {
        float peak = std::fabs(l) > std::fabs(r) ? std::fabs(l) : std::fabs(r);
        float coef = peak > env ? at : rel;
        env += coef * (peak - env);
        env = undenorm(env);
        float g = env > ceiling ? ceiling / env : 1.0f;
        l *= g;
        r *= g;
        // A gentle final saturator so a transient between control blocks still
        // cannot leave the rails.
        l = std::tanh(l * 1.02f);
        r = std::tanh(r * 1.02f);
    }
};

// ------------------------------------------------------------------ 1/f noise

// Voss-McCartney pink noise, run at control rate. This is the "weather": the
// reason the piece has stretches of calm and then a swell, instead of the
// even, obviously-periodic motion an LFO gives. Pink noise has structure at
// every timescale, which is exactly the property wanted here.
struct PinkWalk {
    static constexpr int kOct = 10;
    float rows[kOct] = {};
    uint32_t counter = 0;
    Rng rng;
    float value = 0.0f;

    void seed(uint32_t s, uint32_t stream) {
        rng.seed(s, stream);
        counter = 0;
        for (int i = 0; i < kOct; ++i) rows[i] = rng.bi();
    }
    // Call at control rate; returns roughly -1..1.
    float step() {
        counter++;
        uint32_t diff = counter ^ (counter - 1);
        float sum = 0.0f;
        for (int i = 0; i < kOct; ++i) {
            if (diff & (1u << i)) rows[i] = rng.bi();
            sum += rows[i];
        }
        value = sum * (1.0f / (float)kOct) * 2.2f;
        return clampf(value, -1.0f, 1.0f);
    }
};

}  // namespace ne
