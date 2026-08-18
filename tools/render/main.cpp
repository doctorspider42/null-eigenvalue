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
};

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
        else if (positional == 0) { a.out = s; positional++; }
        else if (positional == 1) { a.seconds = atof(s.c_str()); positional++; }
    }

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
