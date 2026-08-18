import 'dart:ui';

/// The colours of one mood.
///
/// Four stops rather than a two-colour gradient because the picture is built
/// out of additive blobs: [deep] is what the low register is drawn in and it
/// has to stay almost invisible against [bg] when a voice is quiet, while
/// [accent] is what a bell flashes in and has to survive being added on top of
/// everything else. A single gradient between two colours cannot do both.
class MoodPalette {
  const MoodPalette({
    required this.name,
    required this.bg,
    required this.deep,
    required this.mid,
    required this.accent,
  });

  final String name;

  /// The page behind everything. Never pure black - a real black rectangle on
  /// an OLED reads as a hole rather than as depth.
  final Color bg;

  /// The low register.
  final Color deep;

  /// The middle, where most of the energy lives.
  final Color mid;

  /// Highs, bells and the touch trail.
  final Color accent;

  static const List<MoodPalette> all = <MoodPalette>[
    MoodPalette(
      name: 'Kernel',
      bg: Color(0xFF05040B),
      deep: Color(0xFF1B1140),
      mid: Color(0xFF3E2C86),
      accent: Color(0xFF8A67F0),
    ),
    MoodPalette(
      name: 'Manifold',
      bg: Color(0xFF03070C),
      deep: Color(0xFF0E2A4A),
      mid: Color(0xFF1B7C97),
      accent: Color(0xFF5CE0CC),
    ),
    MoodPalette(
      name: 'Halo',
      bg: Color(0xFF05070B),
      deep: Color(0xFF14405C),
      mid: Color(0xFF52B6E4),
      accent: Color(0xFFFFE3AE),
    ),
    MoodPalette(
      name: 'Torsion',
      bg: Color(0xFF0A0406),
      deep: Color(0xFF4A0E32),
      mid: Color(0xFFB8235E),
      accent: Color(0xFFFF9152),
    ),
    MoodPalette(
      name: 'Limit',
      bg: Color(0xFF06070A),
      deep: Color(0xFF1C2733),
      mid: Color(0xFF4C6178),
      accent: Color(0xFFB6C9DA),
    ),
    // Entropy is the noise mood, so it is the one palette with almost no hue
    // in it: warm grey over near-black, the colour of tape and room tone.
    MoodPalette(
      name: 'Entropy',
      bg: Color(0xFF070707),
      deep: Color(0xFF262322),
      mid: Color(0xFF6B6560),
      accent: Color(0xFFE3DDD4),
    ),
  ];

  static MoodPalette lerp(MoodPalette a, MoodPalette b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return MoodPalette(
      name: t < 0.5 ? a.name : b.name,
      bg: Color.lerp(a.bg, b.bg, t)!,
      deep: Color.lerp(a.deep, b.deep, t)!,
      mid: Color.lerp(a.mid, b.mid, t)!,
      accent: Color.lerp(a.accent, b.accent, t)!,
    );
  }

  /// The palette as the second field's pitch leaves it. [amount] is octaves,
  /// -1 .. 1, and 0 is exactly this palette back again.
  ///
  /// Transposing the music moves every voice by the same interval and leaves
  /// every one of the chord's intervals where it was; this does the same thing
  /// to the colours. Each stop slides one place along the ladder the palette
  /// already is - [mid] takes [accent]'s place going up, [deep]'s going down -
  /// rather than the whole picture being washed with a tint, which would say
  /// "a filter has been put over this" and not "the instrument is lower".
  ///
  /// The page moves least and never becomes a hole. It has to keep being the
  /// thing the additive blobs are added to, and an octave down that darkened
  /// the background to black would take the depth out of the picture at the
  /// same time as it took the light.
  MoodPalette transposed(double amount) {
    final a = amount.clamp(-1.0, 1.0).toDouble();
    if (a == 0) return this;
    if (a > 0) {
      return MoodPalette(
        name: name,
        bg: Color.lerp(bg, deep, 0.20 * a)!,
        deep: Color.lerp(deep, mid, 0.34 * a)!,
        mid: Color.lerp(mid, accent, 0.34 * a)!,
        // Nothing above accent to borrow from, so the top of the palette goes
        // where a register that has run out of room actually goes: white. A
        // little of it - the accent is what bells and the mark are drawn in,
        // and at an octave up over a loud field a quarter of the way to white
        // put a hole in the middle of the picture.
        accent: Color.lerp(accent, const Color(0xFFFFFFFF), 0.16 * a)!,
      );
    }
    final k = -a;
    return MoodPalette(
      name: name,
      bg: Color.lerp(bg, const Color(0xFF000000), 0.30 * k)!,
      deep: Color.lerp(deep, bg, 0.34 * k)!,
      mid: Color.lerp(mid, deep, 0.38 * k)!,
      accent: Color.lerp(accent, mid, 0.38 * k)!,
    );
  }

  /// The colour for register slice `i` of `n`, brightened by how bright the
  /// engine says it currently sounds. Low slices sit near [deep] and the top
  /// ones near [accent], so the picture's vertical spread is the music's.
  Color forBand(int i, int n, double centroid) {
    final t = n <= 1 ? 0.0 : i / (n - 1);
    final base = t < 0.5
        ? Color.lerp(deep, mid, t * 2)!
        : Color.lerp(mid, accent, (t - 0.5) * 2)!;
    // Brightness does not change hue, it lifts the whole thing toward accent -
    // which is what opening the filter actually sounds like.
    return Color.lerp(base, accent, 0.28 * centroid)!;
  }
}
