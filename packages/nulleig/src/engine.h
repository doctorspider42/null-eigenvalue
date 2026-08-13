// engine.h - the instrument.
//
// Layout of one sample's journey:
//
//   14 breathing voices ─┐
//   air bed (noise) ─────┼─> drive ─> master filter ─> chorus ─┐
//                        │                                     ├─> delay ─┐
//   bells ───────────────┴─────────────────────────────────────┘          ├─> reverb
//                                                                          │
//   dry + delay + reverb ─> tilt ─> width / mono bass ─> limiter ─> gain ─> out
//
// Bells deliberately bypass the master filter: they are the one bright thing
// in an otherwise dark chain, and a low-passed bell is a thud. The bass below
// ~130 Hz is summed to mono, because a wide low end collapses into mush on a
// phone speaker, which is where a lot of this will actually be heard.
//
// Everything that a finger can change is smoothed with a multi-second time
// constant. There is no such thing as an instant parameter in this engine -
// not for safety, but because the instrument is supposed to feel like it has
// mass.
#pragma once

#include <atomic>

#include "dsp.h"
#include "harmony.h"
#include "nulleig.h"
#include "tables.h"

namespace ne {

constexpr int kVoices = 14;
constexpr int kUnison = 3;
constexpr int kBellPool = 10;
constexpr int kBellPartials = 4;
constexpr int kControlBlock = 64;

// The two lowest voices are the drone itself and never take part in the walk;
// without them the piece would occasionally have no floor, which is the one
// thing a drone may not do.
constexpr int kRootVoices = 2;

struct Voice {
    int offset = 0;       // semitones above the root
    int prev_offset = -1;
    float cur_midi = 40.0f;
    float target_midi = 40.0f;

    float breath_period = 40.0f;  // seconds
    float breath_phase = 0.0f;
    float duty = 0.6f;
    float env = 0.0f;
    float level = 1.0f;

    float centre = 12.0f;  // preferred register, semitones above root
    float spread = 9.0f;

    float phase[kUnison] = {};
    float inc[kUnison] = {};
    float detune[kUnison] = {};  // cents
    float gain[kUnison] = {};
    float pan_l[kUnison] = {};
    float pan_r[kUnison] = {};

    float drift_phase = 0.0f;
    float drift_rate = 0.03f;
    float drift_depth = 5.0f;  // cents
    float drift = 0.0f;

    float morph_bias = 0.0f;
    int mip = 4;

    OnePole tone_l, tone_r;
    float tone_hz = 4000.0f;
    bool active = true;  // density gate; an inactive voice finishes its fade
};

struct Bell {
    bool on = false;
    float phase[kBellPartials] = {};
    float inc[kBellPartials] = {};
    float amp[kBellPartials] = {};
    float dec[kBellPartials] = {};
    float pan_l = 0.7f, pan_r = 0.7f;
    float send_rev = 0.8f, send_dly = 0.5f;
    // A struck bar starts at full amplitude on its first sample, and that
    // instantaneous edge is what makes a sparse event read as a *plink* -
    // something landing on top of the music rather than emerging out of it.
    // A tenth of a second of exponential rise fixes it completely and costs
    // one multiply.
    float env = 0.0f;
    float atk = 0.02f;
};

class Engine {
 public:
    explicit Engine(int sample_rate);

    void render(float* out, int frames);

    // Setters: any thread.
    void set_mood(int m) { p_mood_.store(m, std::memory_order_relaxed); }
    int mood() const { return p_mood_.load(std::memory_order_relaxed); }
    void set_field(float x, float y) {
        p_x_.store(clampf(x, 0.0f, 1.0f), std::memory_order_relaxed);
        p_y_.store(clampf(y, 0.0f, 1.0f), std::memory_order_relaxed);
    }
    void set_touch(bool active, float speed) {
        p_touch_.store(active ? 1 : 0, std::memory_order_relaxed);
        p_speed_.store(clampf(speed, 0.0f, 8.0f), std::memory_order_relaxed);
    }
    void set_playing(bool p) { p_playing_.store(p ? 1 : 0, std::memory_order_relaxed); }
    bool playing() const { return p_playing_.load(std::memory_order_relaxed) != 0; }
    void set_gain(float g) { p_gain_.store(clampf(g, 0.0f, 1.5f), std::memory_order_relaxed); }
    void set_seed(uint32_t s) {
        p_seed_.store(s, std::memory_order_relaxed);
        p_reseed_.fetch_add(1, std::memory_order_relaxed);
    }

    void get_vis(ne_vis* out) const;
    int sample_rate() const { return sr_i_; }
    double elapsed() const { return (double)frames_done_ / (double)sr_; }

 private:
    void control_block();
    void reseed(uint32_t seed);
    void repitch(int vi);
    void apply_mood(const Mood& m);
    void start_phrase();
    void fire_bell(int offset, float level);
    void publish_vis();

    // ------------------------------------------------------------- constants
    float sr_ = 48000.0f;
    int sr_i_ = 48000;

    // -------------------------------------------------------------- incoming
    std::atomic<int> p_mood_{1};
    std::atomic<float> p_x_{0.5f};
    std::atomic<float> p_y_{0.45f};
    std::atomic<int> p_touch_{0};
    std::atomic<float> p_speed_{0.0f};
    std::atomic<int> p_playing_{0};
    std::atomic<float> p_gain_{0.85f};
    std::atomic<uint32_t> p_seed_{0x4e756c6cu};
    std::atomic<uint32_t> p_reseed_{0};
    uint32_t reseed_seen_ = 0;

    // -------------------------------------------------------------- outgoing
    std::atomic<float> v_level_{0.0f};
    std::atomic<float> v_centroid_{0.0f};
    std::atomic<float> v_band_[NE_BANDS];
    std::atomic<float> v_spark_{0.0f};
    std::atomic<float> v_root_{55.0f};
    std::atomic<float> v_motion_{0.0f};
    std::atomic<float> v_gate_{0.0f};
    std::atomic<int> v_chord_{0};

    // ----------------------------------------------------------------- state
    WaveBank bank_;
    PitchSet pitches_;
    int mood_cur_ = 1;

    Voice voice_[kVoices];
    Bell bell_[kBellPool];

    Rng rng_pitch_, rng_bell_, rng_voice_, rng_noise_;
    PinkWalk weather_bright_, weather_dense_, weather_space_;
    OnePole w_bright_, w_dense_, w_space_;
    int weather_div_ = 0;

    // Root: a slow random walk with a restoring pull toward the mood's home.
    float root_cur_ = 33.0f;
    float root_target_ = 33.0f;
    int root_walk_ = 0;
    float root_timer_ = 0.0f;

    // Smoothed derived parameters.
    OnePole s_cutoff_, s_res_, s_morph_, s_bright_, s_dense_, s_air_,
        s_rev_mix_, s_dly_mix_, s_drive_, s_chorus_, s_tilt_, s_gain_,
        s_bell_rate_, s_shimmer_, s_tone_;
    float exc_ = 0.0f;      // touch excitation, decays
    float gate_ = 0.0f;     // master fade
    float motion_ = 0.0f;   // how much harmony moved recently, for the visuals
    float spark_ = 0.0f;

    // Per-sample values held across a control block.
    float cutoff_ = 800.0f, res_ = 0.2f, morph_ = 1.2f;
    float air_level_ = 0.05f, rev_mix_ = 0.4f, dly_mix_ = 0.2f;
    float drive_ = 0.2f, chorus_mix_ = 0.3f, tilt_ = 0.0f, gain_ = 0.85f;
    float bell_prob_ = 0.0f, shimmer_ = 0.0f;
    float rev_predelay_ = 0.0f;

    // Bells arrive as short phrases rather than as isolated events. One note
    // every twenty seconds is a drip; three or four notes walking through the
    // chord is a figure, and a figure is something the ear can file away
    // instead of flinching at.
    static constexpr int kPhraseMax = 6;
    int phrase_notes_[kPhraseMax] = {};
    int phrase_len_ = 0;
    int phrase_pos_ = 0;
    float phrase_timer_ = 0.0f;
    float phrase_gap_ = 0.5f;
    float phrase_level_ = 1.0f;

    // ------------------------------------------------------------------- dsp
    Svf filt_l_, filt_r_;
    Chorus chorus_;
    PingPong delay_;
    Fdn reverb_;
    Limiter limiter_;
    Tilt tilt_l_, tilt_r_;
    OnePole bass_l_, bass_r_;
    // The air bed is two layers, because "noise" on its own is either a
    // whistle or a hiss and a real one is both: a resonant band that wanders
    // a couple of octaves, and a broad shelf under it that is simply the room.
    Svf air_svf_l_, air_svf_r_;
    OnePole air_lp_l_, air_lp_r_;
    float air_phase_ = 0.0f;
    OnePole rev_send_lp_;

    // Reverb / delay parameters that only need touching when the mood does.
    float target_rev_decay_ = 13.0f, target_rev_size_ = 1.0f;
    float rev_decay_cur_ = -1.0f, rev_size_cur_ = -1.0f;

    // The order voices are switched on in as density rises. Interleaved across
    // the register so that a sparse setting is still spread over four octaves
    // rather than being the bottom five voices.
    int order_[kVoices];

    float peak_ = 0.0f;
    float width_ = 1.0f;

    int block_pos_ = kControlBlock;
    uint64_t frames_done_ = 0;
    float sine_[1025];
};

}  // namespace ne
