// A desktop harness for the engine. There is no phone in this loop: it renders
// the same synthesizer offline, writes a WAV and measures it, which is how the
// DSP gets checked at all on a machine with no Xcode and no Android SDK.
//
//   nulleig_render out.wav 300              300 s of the default mood
//   nulleig_render out.wav 300 --mood 2     Halo
//   nulleig_render out.wav 600 --tour       walks the field and every mood
//   nulleig_render out.wav 120 --x 0.8 --y 0.3 --seed 7
//   nulleig_render out.wav 120 --pitch -5 --speed 2.5   the second field
//
// It always prints a report. A render that peaks at 0.99, or whose loudest
// second is nine times its quietest, or that contains a NaN, is a bug whether
// or not anyone was listening.
//
// The other question this harness can answer is what the synthesizer costs,
// which on a desk is not a question about the whole app: the audio thread and
// the thread that draws are different threads, and only one of them is in here.
//
//   nulleig_render --bench                  the standard sweep
//   nulleig_render --bench --bench-secs 20  longer, for a steadier number
//   nulleig_render --bench --block 480      a different callback size
//
// No WAV, no analysis, nothing accumulated: just the render loop, timed one
// callback-sized block at a time, because that is the shape the audio thread
// actually calls it in and a mean hides the block that missed its deadline.

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "nulleig.h"

namespace {

bool write_wav16(const char* path, const std::vector<float>& interleaved, int rate) {
    FILE* f = fopen(path, "wb");
    if (!f) return false;
    const uint32_t frames = (uint32_t)(interleaved.size() / 2);
    const uint32_t data_bytes = frames * 2 * 2;
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
    fwrite("RIFF", 1, 4, f);
    u32(36 + data_bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    u32(16);
    u16(1);
    u16(2);
    u32((uint32_t)rate);
    u32((uint32_t)rate * 4);
    u16(4);
    u16(16);
    fwrite("data", 1, 4, f);
    u32(data_bytes);
    for (float s : interleaved) {
        float v = s > 1.0f ? 1.0f : (s < -1.0f ? -1.0f : s);
        int16_t q = (int16_t)lrintf(v * 32767.0f);
        fwrite(&q, 2, 1, f);
    }
    fclose(f);
    return true;
}

struct Args {
    std::string out = "out.wav";
    double seconds = 120.0;
    int mood = 1;
    float x = 0.5f, y = 0.45f;
    float pitch = 0.0f, speed = 1.0f;
    uint32_t seed = 0x4e756c6c;
    bool tour = false;
    int rate = 48000;
    bool bench = false;
    double bench_secs = 10.0;
    int block = 480;
};

// ------------------------------------------------------------------- bench

/* One line of the sweep: a place on the control surface and a name to print. */
struct Case {
    const char* name;
    int mood;
    float x, y;
    float speed;
    bool playing;
};

struct Timing {
    double mean_us;
    double p50_us;
    double p99_us;
    double max_us;
    double audio_s;
};

/* Renders `secs` of audio in `block`-frame chunks and times each chunk.
 *
 * The engine is warmed first and the warm-up is not timed: the gate fades up
 * over about a second, the first control block does work every later one does
 * not, and a cold instruction cache is not what the audio thread meets.
 */
Timing bench_case(ne_engine* e, const Case& c, double secs, int block) {
    ne_set_mood(e, c.mood);
    ne_set_field(e, c.x, c.y);
    ne_set_rate(e, c.speed);
    ne_set_playing(e, c.playing ? 1 : 0);

    const int rate = ne_sample_rate(e);
    std::vector<float> buf((size_t)block * 2);

    // Two seconds of warm-up: long enough for the gate to reach the top (or
    // the bottom, for the paused case) and for the field's own smoothing to
    // have arrived where it was sent.
    const int64_t warm = (int64_t)(2.0 * rate);
    for (int64_t n = 0; n < warm; n += block) ne_render(e, buf.data(), block);

    const int64_t total = (int64_t)(secs * rate);
    const int64_t blocks = total / block;
    std::vector<double> us;
    us.reserve((size_t)blocks);

    for (int64_t b = 0; b < blocks; ++b) {
        const auto t0 = std::chrono::steady_clock::now();
        ne_render(e, buf.data(), block);
        const auto t1 = std::chrono::steady_clock::now();
        us.push_back(std::chrono::duration<double, std::micro>(t1 - t0).count());
    }

    std::sort(us.begin(), us.end());
    double sum = 0.0;
    for (double v : us) sum += v;
    Timing t;
    t.mean_us = us.empty() ? 0.0 : sum / (double)us.size();
    t.p50_us = us.empty() ? 0.0 : us[us.size() / 2];
    t.p99_us = us.empty() ? 0.0 : us[(size_t)((double)us.size() * 0.99)];
    t.max_us = us.empty() ? 0.0 : us.back();
    t.audio_s = (double)(blocks * block) / rate;
    return t;
}

int run_bench(const Args& a) {
    ne_engine* e = ne_create(a.rate);
    if (!e) { fprintf(stderr, "ne_create failed\n"); return 1; }
    ne_set_seed(e, a.seed);
    ne_set_gain(e, 0.9f);
    ne_set_pitch(e, 0.0f);

    const int rate = ne_sample_rate(e);
    // How long the audio thread has to produce one block. Everything below is
    // really one number - time spent over time available - and this is the
    // denominator.
    const double budget_us = 1e6 * (double)a.block / rate;

    const Case cases[] = {
        // The floor: paused and faded, where render() memsets and returns.
        {"paused", 1, 0.5f, 0.45f, 1.0f, false},
        // The two ends of the density axis, which is the axis that decides how
        // many of the fourteen voices are above the cutoff at all.
        {"bare (y=0)", 1, 0.5f, 0.00f, 1.0f, true},
        {"default field", 1, 0.5f, 0.45f, 1.0f, true},
        {"dense (y=1)", 1, 0.5f, 1.00f, 1.0f, true},
        {"dense + bright", 1, 1.0f, 1.00f, 1.0f, true},
        // Same voices, every clock four times faster: more harmonic moves and
        // more bells per second, and nothing else different.
        {"dense, 4x speed", 1, 1.0f, 1.00f, 4.0f, true},
        // Every mood at the top of the field, because they do not all run the
        // same number of things.
        {"Kernel, dense", 0, 1.0f, 1.00f, 1.0f, true},
        {"Manifold, dense", 1, 1.0f, 1.00f, 1.0f, true},
        {"Halo, dense", 2, 1.0f, 1.00f, 1.0f, true},
        {"Torsion, dense", 3, 1.0f, 1.00f, 1.0f, true},
        {"Limit, dense", 4, 1.0f, 1.00f, 1.0f, true},
        {"Entropy, dense", 5, 1.0f, 1.00f, 1.0f, true},
    };

    printf("engine bench  %d Hz  block %d frames (%.2f ms of audio per call)\n",
           rate, a.block, budget_us / 1000.0);
    printf("%.0f s of audio per case, %d voices x %d unison, %d bells x %d partials\n\n",
           a.bench_secs, 14, 3, 10, 4);
    printf("  %-17s %9s %9s %9s %9s %9s\n", "case", "mean us", "p50", "p99", "max",
           "%core");
    for (const Case& c : cases) {
        const Timing t = bench_case(e, c, a.bench_secs, a.block);
        // Per cent of one core is the honest headline: it is what the audio
        // thread costs whatever else the machine is doing, and it is directly
        // comparable to the figure the task manager shows for the whole app.
        const double core = 100.0 * t.mean_us / budget_us;
        printf("  %-17s %9.1f %9.1f %9.1f %9.1f %8.2f%%\n", c.name, t.mean_us, t.p50_us,
               t.p99_us, t.max_us, core);
    }
    printf("\nworst case is what matters for a dropout: a block over %.0f us\n",
           budget_us);
    printf("  is one the audio thread did not finish in time.\n");
    ne_destroy(e);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Args a;
    int positional = 0;
    for (int i = 1; i < argc; ++i) {
        std::string s = argv[i];
        auto val = [&]() -> const char* { return (i + 1 < argc) ? argv[++i] : "0"; };
        if (s == "--mood") a.mood = atoi(val());
        else if (s == "--x") a.x = (float)atof(val());
        else if (s == "--y") a.y = (float)atof(val());
        else if (s == "--pitch") a.pitch = (float)atof(val());
        else if (s == "--speed") a.speed = (float)atof(val());
        else if (s == "--seed") a.seed = (uint32_t)strtoul(val(), nullptr, 10);
        else if (s == "--rate") a.rate = atoi(val());
        else if (s == "--tour") a.tour = true;
        else if (s == "--bench") a.bench = true;
        else if (s == "--bench-secs") a.bench_secs = atof(val());
        else if (s == "--block") a.block = atoi(val());
        else if (positional == 0) { a.out = s; positional++; }
        else if (positional == 1) { a.seconds = atof(s.c_str()); positional++; }
    }

    // The bench renders nothing to disk and analyses nothing, so it leaves
    // before any of the WAV machinery below is set up.
    if (a.bench) return run_bench(a);

    ne_engine* e = ne_create(a.rate);
    if (!e) { fprintf(stderr, "ne_create failed\n"); return 1; }
    ne_set_seed(e, a.seed);
    ne_set_mood(e, a.mood);
    ne_set_field(e, a.x, a.y);
    ne_set_pitch(e, a.pitch);
    ne_set_rate(e, a.speed);
    ne_set_gain(e, 0.9f);
    ne_set_playing(e, 1);

    const int rate = ne_sample_rate(e);
    const int64_t total = (int64_t)(a.seconds * rate);
    const int block = 1024;

    std::vector<float> all;
    all.reserve((size_t)total * 2);
    std::vector<float> buf((size_t)block * 2);

    // Per-second RMS and peak, which is what the report is built from.
    std::vector<float> sec_rms, sec_peak;
    double acc = 0.0;
    float speak = 0.0f;
    int64_t sec_n = 0;

    double worst = 0.0;
    int64_t nonfinite = 0;
    double dc_l = 0.0, dc_r = 0.0;
    int last_chord = -1, chord_moves = 0;

    ne_vis vis;
    for (int64_t n = 0; n < total; n += block) {
        int frames = (int)((total - n < block) ? (total - n) : block);

        if (a.tour) {
            // Walk the whole control surface so one render exercises every
            // mood and both axes, including the transitions between them -
            // which is where a synthesizer usually breaks.
            double t = (double)n / rate;
            double u = t / a.seconds;
            ne_set_mood(e, (int)(u * NE_MOOD_COUNT) % NE_MOOD_COUNT);
            ne_set_field(e, (float)(0.5 + 0.5 * sin(t * 0.031)),
                         (float)(0.5 + 0.5 * sin(t * 0.017 + 1.1)));
            ne_set_touch(e, (fmod(t, 40.0) < 6.0) ? 1 : 0, 1.4f);
            // Both ends of the second field too, on periods sharing no
            // factor with the field's, so the tour reaches the corners.
            ne_set_pitch(e, (float)(12.0 * sin(t * 0.0071)));
            ne_set_rate(e, (float)pow(2.0, 2.0 * sin(t * 0.0043 + 0.7)));
        }

        ne_render(e, buf.data(), frames);
        for (int i = 0; i < frames; ++i) {
            float l = buf[(size_t)i * 2], r = buf[(size_t)i * 2 + 1];
            if (!std::isfinite(l) || !std::isfinite(r)) nonfinite++;
            dc_l += l;
            dc_r += r;
            float p = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
            if (p > speak) speak = p;
            if (p > worst) worst = p;
            acc += (double)l * l + (double)r * r;
            if (++sec_n >= rate) {
                sec_rms.push_back((float)sqrt(acc / (2.0 * sec_n)));
                sec_peak.push_back(speak);
                acc = 0.0;
                speak = 0.0f;
                sec_n = 0;
            }
        }
        all.insert(all.end(), buf.begin(), buf.begin() + (size_t)frames * 2);

        ne_get_vis(e, &vis);
        if (last_chord < 0) last_chord = vis.chord_change;
        chord_moves = vis.chord_change - last_chord;
    }

    if (!write_wav16(a.out.c_str(), all, rate)) {
        fprintf(stderr, "could not write %s\n", a.out.c_str());
        return 1;
    }

    // ---- report -----------------------------------------------------------
    double rms_min = 1e9, rms_max = 0.0, rms_sum = 0.0;
    int silent_secs = 0;
    for (float v : sec_rms) {
        if (v < rms_min) rms_min = v;
        if (v > rms_max) rms_max = v;
        rms_sum += v;
        if (v < 0.002f) silent_secs++;
    }
    double rms_mean = sec_rms.empty() ? 0.0 : rms_sum / sec_rms.size();
    size_t n_total = all.size() / 2;

    printf("wrote %s  %.1f s @ %d Hz stereo\n", a.out.c_str(), (double)n_total / rate, rate);
    printf("  mood        %s%s\n", ne_mood_name(a.mood), a.tour ? " (tour: all)" : "");
    if (!a.tour && (a.pitch != 0.0f || a.speed != 1.0f))
        printf("  second      pitch %+.1f st   speed %.2fx\n", a.pitch, a.speed);
    printf("  peak        %.4f  %s\n", worst, worst > 0.995 ? "!! CLIPPING" : "ok");
    printf("  rms         mean %.4f   min/s %.4f   max/s %.4f   ratio %.2f\n", rms_mean,
           rms_min, rms_max, rms_min > 1e-6 ? rms_max / rms_min : 0.0);
    printf("  dc offset   L %+.5f  R %+.5f  %s\n", dc_l / n_total, dc_r / n_total,
           (fabs(dc_l / n_total) < 0.01 && fabs(dc_r / n_total) < 0.01) ? "ok" : "!! DC");
    printf("  non-finite  %lld  %s\n", (long long)nonfinite, nonfinite ? "!! NaN/Inf" : "ok");
    printf("  silent secs %d of %d %s\n", silent_secs, (int)sec_rms.size(),
           silent_secs > 3 ? "!! DROPOUT" : "ok");
    printf("  harmony     %d voice entries in %.0f s (%.1f/min)\n", chord_moves, a.seconds,
           chord_moves * 60.0 / a.seconds);
    printf("  final vis   level %.3f centroid %.3f root %.1f Hz motion %.3f\n", vis.level,
           vis.centroid, vis.root_hz, vis.motion);

    int bad = (worst > 0.995) + (nonfinite > 0) + (silent_secs > 3) +
              (fabs(dc_l / n_total) > 0.01);
    ne_destroy(e);
    if (bad) { printf("FAIL (%d checks)\n", bad); return 1; }
    printf("OK\n");
    return 0;
}
