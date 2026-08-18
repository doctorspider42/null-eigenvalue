#include "engine.h"

#include <algorithm>

namespace ne {
namespace {

// Pade approximation of tanh. Used for the drive stage and nothing else;
// accuracy is irrelevant, monotonicity and cheapness are not.
inline float soft(float x) {
    float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

// Equal-power pan, -1 hard left .. +1 hard right.
inline void pan_gains(float p, float& l, float& r) {
    float a = (clampf(p, -1.0f, 1.0f) + 1.0f) * 0.25f * kTwoPi * 0.5f;
    l = std::cos(a);
    r = std::sin(a);
}

inline float fract(float x) { return x - std::floor(x); }

// The window a voice fades in and out through. Long attack, longer release -
// on this timescale a symmetric envelope reads as a swell rather than a note.
inline float breath_window(float u) {
    if (u <= 0.0f || u >= 1.0f) return 0.0f;
    const float atk = 0.32f, rel_start = 0.58f;
    if (u < atk) return 0.5f - 0.5f * std::cos(kPi * u / atk);
    if (u > rel_start) return 0.5f + 0.5f * std::cos(kPi * (u - rel_start) / (1.0f - rel_start));
    return 1.0f;
}

// Nearly harmonic, and that is a correction rather than a preference.
//
// The textbook struck-bar set is {1, 2, 2.76, 5.4} and it sounds like a bell
// precisely because those partials are inharmonic. That works when a bell is
// heard against silence or against something moving. Here it is heard against
// a chord that has been held for a minute, and 2.76 lands about a minor tenth
// and a bit above the fundamental - close enough to a real interval to be
// heard as one, far enough to be out of tune with it. Every strike read as a
// wrong note.
//
// So: octave, twelfth and a double octave plus a third, all consonant with
// whatever the drone is doing, with a fraction of a percent of stretch so the
// partials still beat against each other rather than fusing into one sine.
const float kBellRatio[kBellPartials] = {1.0f, 2.0f, 3.006f, 5.02f};
const float kBellAmp[kBellPartials] = {1.0f, 0.40f, 0.22f, 0.11f};

}  // namespace

Engine::Engine(int sample_rate) {
    sr_i_ = sample_rate > 8000 ? sample_rate : 48000;
    sr_ = (float)sr_i_;
    const float csr = sr_ / (float)kControlBlock;  // control rate

    for (int i = 0; i <= 1024; ++i) sine_[i] = std::sin(kTwoPi * (float)i / 1024.0f);

    bank_.build(sr_);

    chorus_.prepare(sr_);
    delay_.prepare(sr_, 10.0f);
    reverb_.prepare(sr_);
    limiter_.prepare(sr_);
    tilt_l_.prepare(sr_);
    tilt_r_.prepare(sr_);
    bass_l_.set_cutoff(130.0f, sr_);
    bass_r_.set_cutoff(130.0f, sr_);
    rev_send_lp_.set_cutoff(7000.0f, sr_);

    // Smoothing times. These are the numbers that decide whether the
    // instrument feels like it has mass; the filter is the fastest because it
    // is what a finger is most obviously "playing", and the reverb mix the
    // slowest because hearing a room change size is uncanny.
    s_cutoff_.set_time(0.35f, csr);
    s_res_.set_time(1.0f, csr);
    s_morph_.set_time(2.5f, csr);
    s_bright_.set_time(1.2f, csr);
    s_dense_.set_time(2.5f, csr);
    s_air_.set_time(3.0f, csr);
    s_rev_mix_.set_time(6.0f, csr);
    s_dly_mix_.set_time(4.0f, csr);
    s_drive_.set_time(3.0f, csr);
    s_chorus_.set_time(4.0f, csr);
    s_tilt_.set_time(5.0f, csr);
    s_gain_.set_time(0.08f, csr);
    s_bell_rate_.set_time(6.0f, csr);
    s_shimmer_.set_time(8.0f, csr);
    s_tone_.set_time(1.5f, csr);
    // Fast by this engine's standards and slow by a pitch wheel's. Anything
    // shorter and two fingers sliding up the screen sound like a tape edit;
    // anything longer and the gesture stops feeling connected to the sound.
    s_pitch_.set_time(0.30f, csr);

    w_bright_.set_time(16.0f, csr);
    w_dense_.set_time(22.0f, csr);
    w_space_.set_time(40.0f, csr);

    for (int i = 0; i < NE_BANDS; ++i) v_band_[i].store(0.0f, std::memory_order_relaxed);

    // Interleave the switch-on order across the register.
    {
        int n = kVoices - kRootVoices;
        int half = (n + 1) / 2;
        int k = 0;
        for (int i = 0; i < half; ++i) {
            order_[k++] = kRootVoices + i;
            int j = kRootVoices + half + i;
            if (j < kVoices) order_[k++] = j;
        }
        for (int i = 0; i < kRootVoices; ++i) order_[k++] = i;  // never gated
    }

    mood_cur_ = 1;
    reseed(p_seed_.load(std::memory_order_relaxed));
}

void Engine::reseed(uint32_t seed) {
    rng_pitch_.seed(seed, 11);
    rng_bell_.seed(seed, 23);
    rng_voice_.seed(seed, 37);
    rng_noise_.seed(seed, 53);
    weather_bright_.seed(seed, 71);
    weather_dense_.seed(seed, 89);
    weather_space_.seed(seed, 97);

    const Mood& m = mood_at(mood_cur_);
    root_walk_ = 0;
    root_target_ = (float)m.root_midi;
    root_cur_ = root_target_;
    root_timer_ = m.root_walk_sec * (0.5f + rng_voice_.uni());

    for (int i = 0; i < kVoices; ++i) {
        Voice& v = voice_[i];
        // Golden-ratio spacing: the periods are maximally spread and no two
        // are in any simple ratio, so the ensemble pattern does not recur.
        float g = fract((float)i * 0.6180339887f);
        v.breath_period = (24.0f + 62.0f * g);
        v.duty = 0.45f + 0.40f * fract((float)i * 0.7548776662f);
        v.breath_phase = fract((float)i * 0.3819660113f + 0.11f);
        v.env = 0.0f;
        v.level = 1.0f;
        v.prev_offset = -1;

        float d = 3.5f + 6.0f * rng_voice_.uni();
        float base_pan = rng_voice_.bi() * 0.62f;
        for (int u = 0; u < kUnison; ++u) {
            v.phase[u] = rng_voice_.uni();
            float k = (kUnison == 1) ? 0.0f : ((float)u / (float)(kUnison - 1)) * 2.0f - 1.0f;
            v.detune[u] = k * d;
            v.gain[u] = (u == kUnison / 2) ? 1.0f : 0.62f;
            pan_gains(clampf(base_pan + k * 0.5f, -1.0f, 1.0f), v.pan_l[u], v.pan_r[u]);
        }
        float gsum = 0.0f;
        for (int u = 0; u < kUnison; ++u) gsum += v.gain[u];
        for (int u = 0; u < kUnison; ++u) v.gain[u] /= gsum;

        v.drift_phase = rng_voice_.uni();
        v.drift_rate = 0.012f + 0.045f * rng_voice_.uni();
        v.drift_depth = 3.0f + 6.0f * rng_voice_.uni();
        v.morph_bias = rng_voice_.bi() * 0.22f;
        v.tone_l.reset();
        v.tone_r.reset();
        v.active = true;
    }

    for (int i = 0; i < kBellPool; ++i) bell_[i].on = false;
    phrase_len_ = 0;
    phrase_pos_ = 0;
    phrase_timer_ = 0.0f;

    apply_mood(m);

    // Root voices anchor the piece; the rest start already spread out so the
    // opening is a chord rather than a unison that grows.
    voice_[0].offset = 0;
    voice_[1].offset = 12;
    for (int i = 0; i < kVoices; ++i) {
        if (i >= kRootVoices) repitch(i);
        voice_[i].cur_midi = voice_[i].target_midi = root_cur_ + (float)voice_[i].offset;
    }

    filt_l_.reset();
    filt_r_.reset();
    chorus_.clear();
    delay_.clear();
    reverb_.clear();
    // Not reset to zero: the transposition is where the hand left it, not part
    // of the piece being re-seeded. Snapped rather than glided, because there
    // is nothing to glide from - the whole instrument has just been rebuilt.
    s_pitch_.reset(p_pitch_.load(std::memory_order_relaxed));
    pitch_ = s_pitch_.z;
    gate_ = 0.0f;
    exc_ = 0.0f;
    motion_ = 0.0f;
    spark_ = 0.0f;
    peak_ = 0.0f;
    rev_decay_cur_ = rev_size_cur_ = -1.0f;
}

void Engine::apply_mood(const Mood& m) {
    pitches_.build(m);
    root_target_ = (float)m.root_midi + (float)root_walk_;

    int walkers = kVoices - kRootVoices;
    for (int i = 0; i < kVoices; ++i) {
        Voice& v = voice_[i];
        v.breath_period = (24.0f + 62.0f * fract((float)i * 0.6180339887f)) * m.breath_scale;
        if (i < kRootVoices) continue;
        float t = ((float)(i - kRootVoices) + 0.5f) / (float)walkers;
        v.centre = m.low_semi + (m.high_semi - m.low_semi) * t;
        v.spread = 6.0f + 5.0f * fract((float)i * 0.4142135f);
    }
    voice_[0].centre = 0.0f;
    voice_[1].centre = 12.0f;
}

void Engine::repitch(int vi) {
    Voice& v = voice_[vi];

    int sounding[kVoices];
    float amps[kVoices];
    int n = 0;
    for (int j = 0; j < kVoices; ++j) {
        if (j == vi) continue;
        float a = voice_[j].env * voice_[j].level;
        if (a < 0.02f) continue;
        sounding[n] = voice_[j].offset;
        amps[n] = a;
        ++n;
    }

    int prev = v.offset;
    v.offset = choose_offset(pitches_, sounding, amps, n, v.centre, v.spread,
                             v.prev_offset, rng_pitch_);
    v.prev_offset = prev;
    v.target_midi = root_cur_ + (float)v.offset;
    v.cur_midi = v.target_midi;  // silent, so nothing to glide

    motion_ = clampf(motion_ + 0.16f, 0.0f, 1.0f);
    v_chord_.fetch_add(1, std::memory_order_relaxed);
}

// Builds the next figure: two to four notes walking through the chord that is
// currently sounding, in one register, a beat or so apart.
//
// Single isolated strikes were the first version and they were wrong in a way
// that took someone else's ears to name: one note every twenty seconds does
// not read as music, it reads as a notification. A short ascending or
// descending figure through the notes already being held reads as a phrase,
// and a phrase belongs to the piece.
void Engine::start_phrase() {
    // The sounding chord, low to high, without duplicates. Insertion sort
    // because there are at most fourteen of them.
    int set[kVoices];
    int n = 0;
    for (int j = 0; j < kVoices; ++j) {
        if (voice_[j].env * voice_[j].level <= 0.10f) continue;
        int o = voice_[j].offset;
        bool dup = false;
        for (int k = 0; k < n; ++k) {
            if (set[k] == o) { dup = true; break; }
        }
        if (dup) continue;
        int p = n++;
        while (p > 0 && set[p - 1] > o) { set[p] = set[p - 1]; --p; }
        set[p] = o;
    }
    if (n == 0) {
        // Nothing audible to draw from: fall back to the top of the scale
        // rather than invent a note outside it.
        if (pitches_.count == 0) return;
        n = 1;
        set[0] = pitches_.offset[pitches_.count - 1];
    }

    int len = 2 + rng_bell_.range(3);  // 2..4
    if (len > kPhraseMax) len = kPhraseMax;
    int dir = rng_bell_.uni() < 0.5f ? -1 : 1;
    int idx = rng_bell_.range(n);
    int oct = (rng_bell_.uni() < 0.35f) ? 24 : 12;

    for (int i = 0; i < len; ++i) {
        phrase_notes_[i] = set[idx] + oct;
        int next = idx + dir;
        // Reflect at the ends rather than wrap: a wrap is an octave leap in
        // the middle of a four-note figure, which is exactly the jump the
        // phrase exists to avoid.
        if (next < 0 || next >= n) {
            dir = -dir;
            next = idx + dir;
        }
        idx = (next < 0) ? 0 : (next >= n ? n - 1 : next);
    }

    phrase_len_ = len;
    phrase_pos_ = 0;
    phrase_timer_ = 0.0f;
    phrase_gap_ = 0.30f + 0.55f * rng_bell_.uni();
    phrase_level_ = 0.80f + 0.35f * rng_bell_.uni();
}

void Engine::fire_bell(int off, float level) {
    int slot = -1;
    float weakest = 1e9f;
    for (int i = 0; i < kBellPool; ++i) {
        if (!bell_[i].on) { slot = i; break; }
        float a = bell_[i].amp[0];
        if (a < weakest) { weakest = a; slot = i; }
    }
    if (slot < 0) return;

    const Mood& m = mood_at(mood_cur_);
    float bright = s_bright_.z;
    float f0 = midi_hz(root_cur_ + pitch_ + (float)off);
    while (f0 > sr_ * 0.16f) f0 *= 0.5f;

    Bell& b = bell_[slot];
    b.on = true;
    float decay = m.bell_decay * (0.55f + 0.9f * rng_bell_.uni());
    for (int p = 0; p < kBellPartials; ++p) {
        float jitter = 1.0f + rng_bell_.bi() * 0.006f;
        b.phase[p] = rng_bell_.uni();
        b.inc[p] = f0 * kBellRatio[p] * jitter / sr_;
        if (b.inc[p] > 0.45f) b.inc[p] = 0.0f;  // above Nyquist: just drop it
        float tilt = std::pow(0.35f + 0.9f * bright, (float)p);
        b.amp[p] = kBellAmp[p] * tilt * level * (0.6f + 0.5f * rng_bell_.uni());
        float d = decay / (1.0f + 0.75f * (float)p);
        b.dec[p] = std::exp(-6.9078f / (d * sr_));
    }
    b.env = 0.0f;
    b.atk = 1.0f - std::exp(-1.0f / ((0.06f + 0.14f * rng_bell_.uni()) * sr_));
    pan_gains(rng_bell_.bi() * 0.85f, b.pan_l, b.pan_r);
    // Sent much harder than it is heard directly. A bell that arrives mostly
    // through the room is an event in the same space as the drone; a dry one
    // is an event on top of it.
    b.send_rev = 0.95f + 0.55f * rng_bell_.uni();
    b.send_dly = 0.35f + 0.55f * rng_bell_.uni();

    spark_ = 1.0f;
}

void Engine::control_block() {
    const float dt = (float)kControlBlock / sr_;

    // ---- incoming ---------------------------------------------------------
    uint32_t reseed_ticket = p_reseed_.load(std::memory_order_relaxed);
    if (reseed_ticket != reseed_seen_) {
        reseed_seen_ = reseed_ticket;
        reseed(p_seed_.load(std::memory_order_relaxed));
    }
    int want_mood = p_mood_.load(std::memory_order_relaxed);
    if (want_mood < 0) want_mood = 0;
    if (want_mood >= kMoodCount) want_mood = kMoodCount - 1;
    if (want_mood != mood_cur_) {
        mood_cur_ = want_mood;
        root_walk_ = 0;
        apply_mood(mood_at(mood_cur_));
        root_timer_ = mood_at(mood_cur_).root_walk_sec;
    }
    const Mood& m = mood_at(mood_cur_);

    float fx = p_x_.load(std::memory_order_relaxed);
    float fy = p_y_.load(std::memory_order_relaxed);
    bool touching = p_touch_.load(std::memory_order_relaxed) != 0;
    float speed = p_speed_.load(std::memory_order_relaxed);
    bool play = p_playing_.load(std::memory_order_relaxed) != 0;

    // The second gesture. `rate` scales every dt below this line; `pitch_` is
    // added wherever a midi number becomes a frequency, and nowhere else - the
    // harmony, the registers and the scale all stay in their own coordinates.
    rate_ = p_rate_.load(std::memory_order_relaxed);
    s_pitch_.process(p_pitch_.load(std::memory_order_relaxed));
    pitch_ = s_pitch_.z;
    const float rdt = dt * rate_;

    // ---- weather ----------------------------------------------------------
    // Pink rather than an LFO: 1/f has structure at every timescale, so the
    // piece gets stretches of calm and then a swell instead of a visible
    // period. Stepped four times a second and then smoothed over tens of
    // seconds, which puts its energy between about 25 s and 4 minutes - all of
    // it divided by the speed axis, which is the one place in the engine where
    // that means recomputing a coefficient rather than scaling a dt.
    if (std::fabs(rate_ - weather_rate_) > 0.02f) {
        weather_rate_ = rate_;
        const float csr = sr_ / (float)kControlBlock;
        w_bright_.set_time(16.0f / rate_, csr);
        w_dense_.set_time(22.0f / rate_, csr);
        w_space_.set_time(40.0f / rate_, csr);
    }
    if (--weather_div_ <= 0) {
        weather_div_ = (int)(0.25f / rdt);
        if (weather_div_ < 1) weather_div_ = 1;
        w_bright_.process(weather_bright_.step());
        w_dense_.process(weather_dense_.step());
        w_space_.process(weather_space_.step());
    }

    // ---- excitation -------------------------------------------------------
    // A fast drag is audible as energy, not only as a new parameter value.
    float target_exc = touching ? clampf(speed * 0.42f, 0.0f, 1.0f) : 0.0f;
    exc_ += (target_exc > exc_ ? 0.25f : 0.020f) * (target_exc - exc_);

    // ---- derived parameters ----------------------------------------------
    float bright = clampf(fx + 0.22f * w_bright_.z + 0.18f * exc_, 0.0f, 1.0f);
    float dense = clampf(fy + 0.18f * w_dense_.z, 0.0f, 1.0f);
    float space = clampf(0.5f + 0.5f * w_space_.z, 0.0f, 1.0f);

    s_bright_.process(bright);
    s_dense_.process(dense);

    float b = s_bright_.z, d = s_dense_.z;

    float cutoff = m.cutoff_lo * std::pow(m.cutoff_hi / m.cutoff_lo, std::pow(b, 1.25f));
    cutoff *= 1.0f + 0.35f * exc_;
    s_cutoff_.process(clampf(cutoff, 60.0f, sr_ * 0.45f));
    s_res_.process(0.12f + 0.30f * b);
    s_morph_.process(clampf(m.morph + m.morph_span * (b - 0.42f) * 2.0f, 0.0f, 3.0f));
    s_air_.process(m.air * (0.35f + 1.1f * b));
    s_drive_.process(m.drive * (0.7f + 0.6f * b));
    s_chorus_.process(m.chorus * (0.75f + 0.5f * d));
    s_tilt_.process(clampf(m.tilt + 0.5f * (b - 0.5f), -1.0f, 1.0f));
    s_rev_mix_.process(clampf(m.rev_mix * (0.78f + 0.42f * (1.0f - d)) * (0.85f + 0.3f * space),
                              0.0f, 0.85f));
    s_dly_mix_.process(m.delay_mix * (0.55f + 0.75f * d));
    s_shimmer_.process(m.shimmer * (0.5f + 0.8f * b));
    s_bell_rate_.process(m.bell_per_min * (0.22f + 1.9f * d) * (0.35f + 1.0f * b) *
                         (1.0f + 3.0f * exc_));
    s_gain_.process(p_gain_.load(std::memory_order_relaxed));
    s_tone_.process(7.0f + 20.0f * b);

    cutoff_ = s_cutoff_.z;
    res_ = s_res_.z;
    morph_ = s_morph_.z;
    air_level_ = s_air_.z;
    drive_ = s_drive_.z;
    chorus_mix_ = s_chorus_.z;
    tilt_ = s_tilt_.z;
    rev_mix_ = s_rev_mix_.z;
    dly_mix_ = s_dly_mix_.z;
    shimmer_ = s_shimmer_.z;
    gain_ = s_gain_.z;
    width_ = 1.0f + 0.4f * b;

    // ---- sleep ------------------------------------------------------------
    // The last twenty seconds are a fade, not a countdown to a cut: scaling
    // the gate's target by the remaining time turns the deadline into a long
    // exhale, which on this instrument is the only way to stop that does not
    // sound like a fault. When the deadline lands the engine clears its own
    // playing flag - the UI finds out later, whenever it next looks, and a UI
    // that is asleep behind a locked screen never needs to find out at all.
    float sleep_scale = 1.0f;
    uint64_t sleep_dl = sleep_deadline_.load(std::memory_order_relaxed);
    if (sleep_dl != 0) {
        uint64_t done = frames_done_.load(std::memory_order_relaxed);
        if (done >= sleep_dl) {
            sleep_deadline_.store(0, std::memory_order_relaxed);
            p_playing_.store(0, std::memory_order_relaxed);
            play = false;
        } else {
            float rem = (float)((double)(sleep_dl - done) / (double)sr_);
            sleep_scale = clampf(rem / 20.0f, 0.0f, 1.0f);
        }
    }

    // ---- master gate ------------------------------------------------------
    float gate_target = (play ? 1.0f : 0.0f) * sleep_scale;
    float gate_coef = 1.0f - std::exp(-dt / (play ? 1.6f : 1.1f));
    gate_ += gate_coef * (gate_target - gate_);
    if (!play && gate_ < 1e-4f) gate_ = 0.0f;

    // ---- filters ----------------------------------------------------------
    filt_l_.set(cutoff_, res_, sr_);
    filt_r_.set(cutoff_, res_, sr_);

    chorus_.rate = (0.13f + 0.14f * space) * rate_;
    chorus_.depth = 0.35f + 0.5f * b;

    delay_.time_samples = clampf(m.delay_sec * (0.85f + 0.3f * space), 0.05f, 9.5f) * sr_;
    delay_.feedback = clampf(m.delay_fb * (0.85f + 0.25f * d), 0.0f, 0.86f);
    delay_.set_damp(clampf(1200.0f + 5000.0f * b, 400.0f, sr_ * 0.4f));

    float want_decay = m.rev_decay * (0.75f + 0.5f * space);
    float want_size = m.rev_size * (0.9f + 0.2f * space);
    if (std::fabs(want_decay - rev_decay_cur_) > 0.15f ||
        std::fabs(want_size - rev_size_cur_) > 0.01f) {
        rev_decay_cur_ = want_decay;
        rev_size_cur_ = want_size;
        reverb_.set_decay(want_decay, want_size);
    }
    reverb_.set_damping(clampf(2500.0f + 9000.0f * b, 700.0f, sr_ * 0.4f));
    reverb_.set_diffusion(0.55f + 0.35f * d);
    reverb_.set_shimmer(shimmer_, 12.0f);
    rev_predelay_ = (0.02f + 0.05f * space) * sr_;

    // Air bed: a resonant band whose centre wanders a couple of octaves.
    air_phase_ += 0.021f * rdt;
    if (air_phase_ >= 1.0f) air_phase_ -= 1.0f;
    float air_c = 420.0f * std::pow(2.0f, 2.9f * b + 0.85f * std::sin(kTwoPi * air_phase_));
    air_svf_l_.set(clampf(air_c, 80.0f, sr_ * 0.42f), 0.55f, sr_);
    air_svf_r_.set(clampf(air_c * 1.13f, 80.0f, sr_ * 0.42f), 0.55f, sr_);
    float air_broad = clampf(700.0f + 8500.0f * b, 300.0f, sr_ * 0.42f);
    air_lp_l_.set_cutoff(air_broad, sr_);
    air_lp_r_.set_cutoff(air_broad * 0.86f, sr_);

    // ---- root walk --------------------------------------------------------
    root_timer_ -= rdt;
    if (root_timer_ <= 0.0f) {
        root_timer_ = m.root_walk_sec * (0.6f + 0.9f * rng_pitch_.uni());
        // Fifths and thirds, with a restoring pull so the piece cannot wander
        // out of the register it was designed for.
        static const int kMoves[8] = {7, -5, 5, -7, 3, -3, 2, -2};
        int pick = kMoves[rng_pitch_.range(8)];
        int next = root_walk_ + pick;
        if (next > 7 || next < -7) next = root_walk_ - pick;
        root_walk_ = next;
        root_target_ = (float)m.root_midi + (float)root_walk_;
    }
    if (std::fabs(root_target_ - root_cur_) > 1e-4f) {
        // ~12 s to travel a fifth: slow enough to read as the whole field
        // moving rather than as a pitch bend.
        float step = rdt * 7.0f / 12.0f;
        float diff = root_target_ - root_cur_;
        root_cur_ += clampf(diff, -step, step);
        motion_ = clampf(motion_ + rdt * 0.5f, 0.0f, 1.0f);
    }

    // ---- density gate -----------------------------------------------------
    int want_active = kRootVoices + (int)std::lround(2.0f + (float)(kVoices - kRootVoices - 2) * d);
    if (want_active > kVoices) want_active = kVoices;
    for (int k = 0; k < kVoices; ++k) {
        int vi = order_[k];
        voice_[vi].active = (vi < kRootVoices) || (k < want_active - kRootVoices);
    }

    // ---- voices -----------------------------------------------------------
    float lvl_coef = 1.0f - std::exp(-dt / 5.0f);
    for (int i = 0; i < kVoices; ++i) {
        Voice& v = voice_[i];

        float prev_phase = v.breath_phase;
        v.breath_phase += rdt / v.breath_period;
        if (v.breath_phase >= 1.0f) {
            v.breath_phase -= 1.0f;
            if (i >= kRootVoices) repitch(i);
        }
        (void)prev_phase;

        if (i < kRootVoices) {
            v.env = 0.66f + 0.34f * (0.5f - 0.5f * std::cos(kTwoPi * v.breath_phase));
        } else {
            float u = v.breath_phase / v.duty;
            v.env = breath_window(u);
        }
        v.level += lvl_coef * ((v.active ? 1.0f : 0.0f) - v.level);

        v.target_midi = root_cur_ + (float)v.offset;
        // Only the root shift makes this glide; a repitch snaps while silent.
        float gstep = rdt * 7.0f / 12.0f + 1e-6f;
        float gd = v.target_midi - v.cur_midi;
        v.cur_midi += clampf(gd, -gstep, gstep);

        v.drift_phase += v.drift_rate * rdt;
        if (v.drift_phase >= 1.0f) v.drift_phase -= 1.0f;
        v.drift = std::sin(kTwoPi * v.drift_phase) * v.drift_depth;

        float f0 = midi_hz(v.cur_midi + pitch_ + v.drift * (1.0f / 100.0f));
        v.mip = bank_.mip_for(f0 * 1.02f);
        for (int u = 0; u < kUnison; ++u) {
            float f = f0 * std::pow(2.0f, v.detune[u] / 1200.0f);
            v.inc[u] = clampf(f / sr_, 0.0f, 0.48f);
        }
        // The per-voice roll-off keeps the low stack from buzzing, but it must
        // not be allowed to darken the whole instrument: without the floor,
        // every voice is filtered relative to its own pitch and the result is
        // a mix with nothing above a kilohertz - which on a phone speaker,
        // where anything under 500 Hz barely exists, is silence.
        v.tone_hz = clampf(f0 * s_tone_.z, 900.0f, sr_ * 0.45f);
        v.tone_l.set_cutoff(v.tone_hz, sr_);
        v.tone_r.a = v.tone_l.a;
    }

    // ---- bells ------------------------------------------------------------
    // The rate is now phrases per minute, not notes per minute.
    bell_prob_ = clampf(s_bell_rate_.z / 60.0f * rdt, 0.0f, 0.35f);
    if (phrase_len_ > 0) {
        phrase_timer_ -= rdt;
        if (phrase_timer_ <= 0.0f) {
            fire_bell(phrase_notes_[phrase_pos_], phrase_level_);
            phrase_level_ *= 0.87f;  // a figure that leans away as it goes
            phrase_timer_ = phrase_gap_ * (0.85f + 0.30f * rng_bell_.uni());
            if (++phrase_pos_ >= phrase_len_) phrase_len_ = 0;
        }
    } else if (gate_ > 0.25f && m.bell_per_min > 0.01f &&
               rng_bell_.uni() < bell_prob_) {
        start_phrase();
    }

    // ---- visuals ----------------------------------------------------------
    motion_ -= motion_ * (1.0f - std::exp(-rdt / 12.0f));
    spark_ -= spark_ * (1.0f - std::exp(-dt / 0.55f));
    publish_vis();
}

void Engine::publish_vis() {
    v_level_.store(clampf(peak_, 0.0f, 1.0f), std::memory_order_relaxed);
    v_spark_.store(clampf(spark_, 0.0f, 1.0f), std::memory_order_relaxed);
    v_root_.store(midi_hz(root_cur_ + pitch_), std::memory_order_relaxed);
    v_motion_.store(clampf(motion_, 0.0f, 1.0f), std::memory_order_relaxed);
    v_gate_.store(clampf(gate_, 0.0f, 1.0f), std::memory_order_relaxed);
    v_chord_.load(std::memory_order_relaxed);

    // Brightness as the UI should draw it: where the energy actually is, not
    // where the filter knob is. Combining the filter, the timbre morph and the
    // field position tracks the perceived centre closely enough for a picture
    // and costs nothing, where an FFT would cost a thread.
    float cnorm = std::log(cutoff_ / 60.0f) / std::log(12000.0f / 60.0f);
    float centroid = clampf(0.45f * cnorm + 0.35f * (morph_ / 3.0f) + 0.20f * s_bright_.z,
                            0.0f, 1.0f);
    v_centroid_.store(centroid, std::memory_order_relaxed);

    // Register slices, so the visuals can put the low voices at the bottom.
    float band[NE_BANDS] = {};
    for (int i = 0; i < kVoices; ++i) {
        float a = voice_[i].env * voice_[i].level;
        if (a < 0.001f) continue;
        float t = (voice_[i].cur_midi + pitch_ - 24.0f) / 48.0f;  // ~C1..C5
        int idx = (int)(clampf(t, 0.0f, 0.9999f) * (float)NE_BANDS);
        band[idx] += a;
    }
    for (int i = 0; i < NE_BANDS; ++i) {
        float cur = v_band_[i].load(std::memory_order_relaxed);
        float want = clampf(band[i] * 0.75f, 0.0f, 1.0f) * gate_;
        cur += 0.06f * (want - cur);
        v_band_[i].store(cur, std::memory_order_relaxed);
    }
}

void Engine::get_vis(ne_vis* out) const {
    if (!out) return;
    out->level = v_level_.load(std::memory_order_relaxed);
    out->centroid = v_centroid_.load(std::memory_order_relaxed);
    for (int i = 0; i < NE_BANDS; ++i) out->band[i] = v_band_[i].load(std::memory_order_relaxed);
    out->spark = v_spark_.load(std::memory_order_relaxed);
    out->root_hz = v_root_.load(std::memory_order_relaxed);
    out->motion = v_motion_.load(std::memory_order_relaxed);
    out->gate = v_gate_.load(std::memory_order_relaxed);
    out->chord_change = v_chord_.load(std::memory_order_relaxed);
}

void Engine::render(float* out, int frames) {
    int n = 0;
    while (n < frames) {
        if (block_pos_ >= kControlBlock) {
            control_block();
            block_pos_ = 0;
        }
        int todo = kControlBlock - block_pos_;
        if (todo > frames - n) todo = frames - n;

        // Paused and fully faded: emit silence without running the graph. The
        // device stays open (losing the audio session would cost us the lock
        // screen and, on iOS, the right to run at all), but a paused app has
        // no business spending battery on a reverb tail that is already zero.
        if (gate_ <= 0.0f && !playing()) {
            std::memset(out + (size_t)n * 2, 0, sizeof(float) * (size_t)todo * 2);
            peak_ -= peak_ * 0.2f;
            n += todo;
            block_pos_ += todo;
            frames_done_.fetch_add((uint64_t)todo, std::memory_order_relaxed);
            continue;
        }

        for (int k = 0; k < todo; ++k) {
            float l = 0.0f, r = 0.0f;

            // -------- voices
            for (int i = 0; i < kVoices; ++i) {
                Voice& v = voice_[i];
                float env = v.env * v.level;
                if (env < 1e-4f) continue;
                float vl = 0.0f, vr = 0.0f;
                for (int u = 0; u < kUnison; ++u) {
                    v.phase[u] += v.inc[u];
                    if (v.phase[u] >= 1.0f) v.phase[u] -= 1.0f;
                    float s = bank_.read(v.phase[u], morph_ + v.morph_bias, v.mip) * v.gain[u];
                    vl += s * v.pan_l[u];
                    vr += s * v.pan_r[u];
                }
                l += v.tone_l.process(vl) * env;
                r += v.tone_r.process(vr) * env;
            }
            l *= 0.42f;
            r *= 0.42f;

            // -------- air bed
            if (air_level_ > 1e-4f) {
                float nl = rng_noise_.bi();
                float nr = rng_noise_.bi();
                l += (air_svf_l_.band(nl) * 0.80f + air_lp_l_.process(nl) * 1.15f) *
                     air_level_;
                r += (air_svf_r_.band(nr) * 0.80f + air_lp_r_.process(nr) * 1.15f) *
                     air_level_;
            }

            // -------- drive and master filter
            if (drive_ > 1e-4f) {
                l += drive_ * (soft(l * 2.6f) - l);
                r += drive_ * (soft(r * 2.6f) - r);
            }
            l = filt_l_.low(l);
            r = filt_r_.low(r);

            // -------- chorus
            chorus_.process(l, r, chorus_mix_, l, r);

            // -------- bells (post-filter on purpose)
            float bl = 0.0f, br = 0.0f, brl = 0.0f, brr = 0.0f, bdl = 0.0f, bdr = 0.0f;
            for (int i = 0; i < kBellPool; ++i) {
                Bell& bell = bell_[i];
                if (!bell.on) continue;
                float s = 0.0f, total = 0.0f;
                for (int p = 0; p < kBellPartials; ++p) {
                    if (bell.inc[p] <= 0.0f) continue;
                    bell.phase[p] += bell.inc[p];
                    if (bell.phase[p] >= 1.0f) bell.phase[p] -= 1.0f;
                    float fi = bell.phase[p] * 1024.0f;
                    int i0 = (int)fi;
                    float fr = fi - (float)i0;
                    s += (sine_[i0] + (sine_[i0 + 1] - sine_[i0]) * fr) * bell.amp[p];
                    bell.amp[p] *= bell.dec[p];
                    total += bell.amp[p];
                }
                if (total < 2e-5f) {
                    bell.on = false;
                    continue;
                }
                bell.env += bell.atk * (1.0f - bell.env);
                s *= bell.env;
                float sl = s * bell.pan_l * 0.42f, sr2 = s * bell.pan_r * 0.42f;
                bl += sl * 0.38f;
                br += sr2 * 0.38f;
                brl += sl * bell.send_rev;
                brr += sr2 * bell.send_rev;
                bdl += sl * bell.send_dly;
                bdr += sr2 * bell.send_dly;
            }

            // -------- delay
            float dl_out, dr_out;
            delay_.process(l * 0.85f + bdl, r * 0.85f + bdr, dl_out, dr_out);

            // -------- reverb
            float rl, rr;
            reverb_.process(l + brl + dl_out * 0.30f, r + brr + dr_out * 0.30f,
                            rev_predelay_, rl, rr);

            // -------- sum
            float ol = l + bl + dl_out * dly_mix_ + rl * rev_mix_ * 1.6f;
            float orr = r + br + dr_out * dly_mix_ + rr * rev_mix_ * 1.6f;

            ol = tilt_l_.process(ol, tilt_);
            orr = tilt_r_.process(orr, tilt_);

            // -------- mono bass: a wide low end collapses on a phone speaker
            float lo_l = bass_l_.process(ol);
            float lo_r = bass_r_.process(orr);
            float mono_lo = (lo_l + lo_r) * 0.5f;
            ol = (ol - lo_l) + mono_lo;
            orr = (orr - lo_r) + mono_lo;

            float mid = (ol + orr) * 0.5f;
            float side = (ol - orr) * 0.5f * width_;
            ol = mid + side;
            orr = mid - side;

            ol *= gate_;
            orr *= gate_;
            limiter_.process(ol, orr);

            float pk = std::fabs(ol) > std::fabs(orr) ? std::fabs(ol) : std::fabs(orr);
            peak_ += (pk > peak_ ? 0.35f : 0.0009f) * (pk - peak_);

            ol *= gain_;
            orr *= gain_;
            out[(size_t)(n + k) * 2 + 0] = ol;
            out[(size_t)(n + k) * 2 + 1] = orr;
        }

        n += todo;
        block_pos_ += todo;
        frames_done_.fetch_add((uint64_t)todo, std::memory_order_relaxed);
    }
}

}  // namespace ne

