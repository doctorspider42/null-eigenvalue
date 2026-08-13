// harmony.h - what makes this a piece rather than a chord.
//
// The problem with a generated drone is that the two obvious designs are both
// wrong. A fixed chord is a texture: put it on and in ninety seconds you have
// heard everything it will ever do. A chord *progression* is worse, because a
// loop that comes round every eight bars announces itself as a loop the second
// time you hear it.
//
// So there is no progression here. There is a fixed drone root, and above it a
// set of voices that each breathe in and out on their own period, and each one
// picks a new pitch every time it comes back in. Three things make that work:
//
//   - The breath periods are spaced by the golden ratio (24 s .. 86 s, no two
//     alike and no two commensurable), so the *combination* of which voices
//     are sounding has a recurrence time measured in days. Nothing about the
//     texture ever repeats, without a single random number being involved in
//     the timing.
//
//   - A voice only ever changes pitch while it is silent. Nothing has to
//     crossfade or glide, so the harmony can move as much as it likes and you
//     never hear a change happen - you notice, half a minute later, that the
//     chord is somewhere else.
//
//   - The new pitch is drawn from the mood's scale, weighted by how it sounds
//     against the voices that are currently audible (see `weigh`). That is the
//     part that keeps twelve independently-wandering voices reading as one
//     harmony instead of a cluster.
//
// Over a longer timescale the root itself walks, by a fifth or a third, every
// few minutes. Voices hold their offset, so the whole field transposes at once
// - the one event in the piece big enough to notice while it happens.
#pragma once

#include <cmath>

#include "dsp.h"

namespace ne {

constexpr int kMoodCount = 5;

struct Mood {
    const char* name;
    uint16_t scale;       // pitch class bitmask, bit 0 = root
    int root_midi;        // where the drone sits
    float low_semi;       // register the walking voices may occupy,
    float high_semi;      // in semitones above the root
    float breath_scale;   // multiplies every voice's breath period
    float root_walk_sec;  // mean seconds between root shifts
    float morph;          // timbre baseline, 0 sine .. 3 glass
    float morph_span;     // how far the brightness axis moves it
    float rev_decay;      // RT60, seconds
    float rev_size;
    float rev_mix;
    float shimmer;
    float bell_per_min;   // at mid density
    float bell_decay;     // seconds
    float drive;
    float chorus;
    float air;            // noise bed level
    float delay_sec;
    float delay_fb;
    float delay_mix;
    float tilt;           // -1 dark .. +1 bright
    float cutoff_lo;      // master filter sweep, Hz, at field x = 0
    float cutoff_hi;      // ... and at x = 1
};

// The five. They are not presets in the "starting point" sense - each is a
// different instrument, and switching is the only large gesture the UI has.
inline const Mood& mood_at(int i) {
    static const Mood kMoods[kMoodCount] = {
        // Kernel - the null space. As low and as still as the thing goes.
        {"Kernel",
         0b0000010010001101,  // 0 2 3 7 10 : minor, no third-stacking, no 6th
         29, 0.0f, 38.0f, 1.7f, 330.0f,
         0.75f, 0.9f,
         19.0f, 1.15f, 0.42f, 0.04f,
         2.6f, 5.0f,
         0.22f, 0.20f, 0.07f,
         6.4f, 0.62f, 0.16f,
         -0.30f, 420.0f, 3400.0f},

        // Manifold - warm, wide, the default. Dorian, so it is minor without
        // being sad about it.
        {"Manifold",
         0b0000011010101101,  // 0 2 3 5 7 9 10
         33, 0.0f, 45.0f, 1.15f, 260.0f,
         1.50f, 1.1f,
         13.0f, 0.95f, 0.44f, 0.14f,
         6.0f, 3.4f,
         0.17f, 0.42f, 0.10f,
         4.2f, 0.55f, 0.22f,
         -0.05f, 750.0f, 8000.0f},

        // Halo - lydian, high, and the only mood with real shimmer. The #4 is
        // the whole character: it never resolves, so it can hang forever.
        {"Halo",
         0b0000101011010101,  // 0 2 4 6 7 9 11
         36, 0.0f, 50.0f, 0.95f, 220.0f,
         2.20f, 0.9f,
         24.0f, 1.25f, 0.52f, 0.62f,
         13.0f, 4.5f,
         0.10f, 0.55f, 0.09f,
         3.0f, 0.66f, 0.30f,
         0.30f, 1400.0f, 14000.0f},

        // Torsion - phrygian with a major third above a minor scale. Tense,
        // metallic, the shortest tail so the dissonance stays legible.
        {"Torsion",
         0b0000010110110011,  // 0 1 4 5 7 8 10
         31, 0.0f, 43.0f, 0.85f, 190.0f,
         2.50f, 0.8f,
         8.5f, 0.75f, 0.38f, 0.22f,
         9.0f, 2.2f,
         0.40f, 0.30f, 0.17f,
         2.25f, 0.70f, 0.32f,
         0.08f, 950.0f, 10000.0f},

        // Limit - the piece as it stops. Pentatonic, the fewest voices, the
        // longest breaths and a thirty-second room.
        {"Limit",
         0b0000010010101001,  // 0 3 5 7 10
         28, 0.0f, 41.0f, 2.4f, 420.0f,
         1.15f, 0.85f,
         30.0f, 1.35f, 0.58f, 0.34f,
         1.6f, 7.0f,
         0.09f, 0.36f, 0.12f,
         8.5f, 0.68f, 0.24f,
         -0.15f, 550.0f, 5200.0f},
    };
    if (i < 0) i = 0;
    if (i >= kMoodCount) i = kMoodCount - 1;
    return kMoods[i];
}

inline float midi_hz(float midi) {
    return 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f);
}

// How well two pitches sit together, by interval class. Derived from the usual
// consonance ordering and then flattened a little: this is a weight in a
// random draw, not a rule, and a table with zeros in it produces a harmony
// that only ever states the same four notes.
inline float interval_weight(int semitones) {
    static const float kW[12] = {
        1.00f,  // unison / octave
        0.10f,  // minor 2nd
        0.42f,  // major 2nd
        0.90f,  // minor 3rd
        0.88f,  // major 3rd
        0.92f,  // perfect 4th
        0.30f,  // tritone
        1.00f,  // perfect 5th
        0.78f,  // minor 6th
        0.80f,  // major 6th
        0.62f,  // minor 7th
        0.24f,  // major 7th
    };
    int ic = semitones % 12;
    if (ic < 0) ic += 12;
    return kW[ic];
}

inline bool in_scale(uint16_t mask, int semitone_offset) {
    int pc = semitone_offset % 12;
    if (pc < 0) pc += 12;
    return (mask >> pc) & 1u;
}

// Every scale offset available to a walking voice, low to high.
struct PitchSet {
    static constexpr int kMax = 64;
    int offset[kMax];
    int count = 0;

    void build(const Mood& m) {
        count = 0;
        int lo = (int)m.low_semi, hi = (int)m.high_semi;
        for (int o = lo; o <= hi && count < kMax; ++o) {
            if (in_scale(m.scale, o)) offset[count++] = o;
        }
    }
};

// Picks the offset a voice should fade in on.
//
// `sounding` holds the absolute offsets of the voices currently audible and
// `amp` how audible each is; a voice at 5% volume should barely constrain the
// choice, which is what keeps the harmony from locking up as everything fades
// together. `centre`/`spread` are the voice's own register preference, so the
// ensemble stays spread across four octaves instead of collecting in the
// middle where the weights are happiest.
inline int choose_offset(const PitchSet& set, const int* sounding,
                         const float* amp, int n_sounding, float centre,
                         float spread, int previous, Rng& rng) {
    if (set.count == 0) return 0;

    float w[PitchSet::kMax];
    float total = 0.0f;
    for (int i = 0; i < set.count; ++i) {
        int cand = set.offset[i];

        // Consonance against what is audible, as a weighted geometric mean so
        // that adding a quiet voice cannot swamp the loud ones.
        float logsum = 0.0f, wsum = 0.0f;
        bool doubled = false;
        for (int j = 0; j < n_sounding; ++j) {
            float a = amp[j];
            if (a < 0.02f) continue;
            int d = cand - sounding[j];
            if (d < 0) d = -d;
            if (d == 0) doubled = true;
            logsum += a * std::log(interval_weight(d) + 1e-4f);
            wsum += a;
        }
        float consonance = wsum > 1e-4f ? std::exp(logsum / wsum) : 1.0f;

        // Register fit: a soft window, not a hard band, so a voice can stray
        // an octave when the weights strongly want it to.
        float d = ((float)cand - centre) / spread;
        float fit = std::exp(-0.5f * d * d);

        // Some doubling is the sound of an organ; a lot of it is a thin chord
        // played four times.
        float dup = doubled ? 0.30f : 1.0f;

        // Prefer not to land exactly where this voice was last time - the same
        // voice returning to the same note is the one way this design can read
        // as a loop.
        float novelty = (cand == previous) ? 0.15f : 1.0f;

        float weight = consonance * consonance * fit * dup * novelty;
        w[i] = weight;
        total += weight;
    }
    if (total <= 1e-9f) return set.offset[rng.range(set.count)];

    float r = rng.uni() * total;
    for (int i = 0; i < set.count; ++i) {
        r -= w[i];
        if (r <= 0.0f) return set.offset[i];
    }
    return set.offset[set.count - 1];
}

}  // namespace ne
