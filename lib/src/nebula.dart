import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nulleig/nulleig.dart';

import 'palette.dart';
import 'textures.dart';

/// A point of the finger's wake.
class _TrailPoint {
  _TrailPoint(this.p);
  final Offset p;
  double age = 0;
}

/// An expanding ring, spawned when the harmony moves.
class _Ripple {
  double age = 0;
}

/// A bell.
class _Spark {
  _Spark(this.pos, this.drift, this.size);
  Offset pos;
  final Offset drift;
  final double size;
  double age = 0;
}

/// Everything the picture needs that is not in the engine: orbit phases, the
/// spring that chases the finger, and the three kinds of event the music
/// throws off.
///
/// Kept apart from the painter so that the simulation runs once per frame at a
/// known dt, rather than inside paint() where it would run again for every
/// repaint the framework decides to do.
class NebulaState extends ChangeNotifier {
  NebulaState() {
    // Golden-ratio phases and speeds, the same trick the synthesizer uses on
    // its breath periods and for the same reason: no two orbits share a period
    // so the arrangement never visibly repeats.
    for (var i = 0; i < neBands; i++) {
      final g = (i * 0.6180339887) % 1.0;
      final h = (i * 0.3819660113 + 0.37) % 1.0;
      _wa.add(0.013 + 0.030 * g);
      _wb.add(0.011 + 0.026 * h);
      _wc.add(0.006 + 0.013 * ((i * 0.7548776662) % 1.0));
      _pa.add(g * math.pi * 2);
      _pb.add(h * math.pi * 2);
      _pc.add(((i * 0.5436890127) % 1.0) * math.pi * 2);
    }
  }

  final List<double> _wa = <double>[];
  final List<double> _wb = <double>[];
  final List<double> _wc = <double>[];
  final List<double> _pa = <double>[];
  final List<double> _pb = <double>[];
  final List<double> _pc = <double>[];

  double t = 0;

  /// Where the picture thinks the field is. A critically damped spring, so a
  /// flick has weight and a slow drag tracks exactly.
  Offset centre = const Offset(0.5, 0.55);
  Offset _vel = Offset.zero;
  Offset target = const Offset(0.5, 0.55);

  final List<_TrailPoint> _trail = <_TrailPoint>[];
  final List<_Ripple> _ripples = <_Ripple>[];
  final List<_Spark> _sparks = <_Spark>[];

  int _lastChord = -1;
  double _lastSpark = 0;
  final math.Random _rnd = math.Random(0xE16E);

  DroneVis vis = DroneVis.empty;

  /// Written by the frame clock, read by the painter. They live here rather
  /// than as painter constructor arguments so that the painter can be built
  /// once and repainted from this object - a new painter every frame would
  /// mean a widget rebuild every frame for values no widget reads.
  MoodPalette palette = MoodPalette.all[1];

  /// 0 while playing, 1 while stopped: fades in the invitation to press play
  /// without putting a permanent button on the screen.
  double idleHint = 1;

  void advance(double dt, DroneVis v) {
    t += dt;
    vis = v;

    // Spring. omega picked so that a full-screen move settles in about a third
    // of a second - fast enough to feel connected, slow enough to have mass.
    const omega = 11.0;
    final dx = target - centre;
    _vel += (dx * (omega * omega) - _vel * (2 * omega)) * dt;
    centre += _vel * dt;

    for (final p in _trail) {
      p.age += dt;
    }
    _trail.removeWhere((p) => p.age > 1.1);

    for (final r in _ripples) {
      r.age += dt;
    }
    _ripples.removeWhere((r) => r.age > 7.0);

    for (final s in _sparks) {
      s.age += dt;
      s.pos += s.drift * dt;
    }
    _sparks.removeWhere((s) => s.age > 3.2);

    // The harmony moving is worth seeing: one slow ring per voice entry.
    if (_lastChord < 0) _lastChord = v.chordChange;
    if (v.chordChange != _lastChord) {
      _lastChord = v.chordChange;
      if (_ripples.length < 8) _ripples.add(_Ripple());
    }

    // A bell is a rising edge on `spark`, not a level.
    if (v.spark > _lastSpark + 0.25) {
      if (_sparks.length < 24) {
        final a = _rnd.nextDouble() * math.pi * 2;
        final r = 0.10 + 0.34 * _rnd.nextDouble();
        _sparks.add(_Spark(
          centre + Offset(math.cos(a), math.sin(a)) * r,
          Offset(math.cos(a), math.sin(a)) * 0.012 - const Offset(0, 0.008),
          0.6 + 0.8 * _rnd.nextDouble(),
        ));
      }
    }
    _lastSpark = v.spark;
    notifyListeners();
  }

  void addTrail(Offset normalised) {
    _trail.add(_TrailPoint(normalised));
    if (_trail.length > 90) _trail.removeAt(0);
  }

  Offset orbit(int i, double radius) {
    final rr = radius * (1 + 0.20 * math.sin(t * _wc[i] * math.pi * 2 + _pc[i]));
    return Offset(
      math.cos(t * _wa[i] * math.pi * 2 + _pa[i]),
      math.sin(t * _wb[i] * math.pi * 2 + _pb[i]),
    ) * rr;
  }
}

/// Draws the field.
///
/// Every glowing thing on screen is the same white blob texture, tinted and
/// added. The composition is one core (the drone), eight orbs (the register
/// slices the engine publishes), rings for harmonic movement, points for
/// bells, and the finger's own wake - so what is on screen is not a decoration
/// that happens to move, it is a reading of the synthesizer.
class NebulaPainter extends CustomPainter {
  NebulaPainter({required this.state, required this.textures})
      : super(repaint: state);

  final NebulaState state;
  final Textures textures;

  static final Float64List _identity = Matrix4.identity().storage;

  void _blob(Canvas c, Offset p, double radius, Color color) {
    if (radius <= 0.2 || color.a <= 0.002) return;
    final src = Rect.fromLTWH(
        0, 0, textures.blob.width.toDouble(), textures.blob.height.toDouble());
    c.drawImageRect(
      textures.blob,
      src,
      Rect.fromCircle(center: p, radius: radius),
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.low
        ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final s = math.min(size.width, size.height);
    final palette = state.palette;
    final idleHint = state.idleHint;
    final v = state.vis;
    final gate = v.gate;
    final centre = Offset(
      state.centre.dx * size.width,
      state.centre.dy * size.height,
    );

    canvas.drawRect(rect, Paint()..color = palette.bg);

    // A pool of light under the field, so the composition has a place to sit
    // even when every voice is quiet.
    _blob(canvas, centre, s * 0.85,
        palette.deep.withValues(alpha: 0.16 + 0.12 * gate));

    // ---- the register slices ---------------------------------------------
    for (var i = 0; i < neBands; i++) {
      final t = i / (neBands - 1);
      var energy = v.bands[i];
      // While paused the engine reports silence, but a black screen is not a
      // pause, it is a crash. Breathe gently instead, and hand the picture
      // back to the music as soon as it starts.
      final idle = (0.11 + 0.055 * math.sin(state.t * 0.21 + i * 1.7)) *
          (1 - gate);
      energy = math.max(energy, idle);

      final orbitR = s * (0.05 + 0.40 * math.pow(t, 0.85).toDouble());
      final pos = centre + state.orbit(i, orbitR);
      // Low slices are big and soft, high ones small and sharp - which is what
      // the register actually sounds like.
      final radius = s * (0.30 - 0.20 * t) * (0.45 + 1.05 * energy);
      final colour = palette.forBand(i, neBands, v.centroid);
      _blob(canvas, pos, radius,
          colour.withValues(alpha: (0.06 + 0.62 * energy).clamp(0.0, 0.85)));
    }

    // ---- the drone itself -------------------------------------------------
    final coreLevel = math.max(v.level, 0.06 * (1 - gate));
    _blob(
      canvas,
      centre,
      s * (0.13 + 0.16 * coreLevel),
      Color.lerp(palette.deep, palette.mid, 0.35 + 0.55 * v.centroid)!
          .withValues(alpha: (0.18 + 0.55 * coreLevel).clamp(0.0, 0.9)),
    );

    // ---- harmonic movement ------------------------------------------------
    for (final r in state._ripples) {
      final u = (r.age / 7.0).clamp(0.0, 1.0);
      final radius = s * (0.06 + 1.05 * Curves.easeOutCubic.transform(u));
      final fade = (1 - u) * (1 - u);
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6 + 1.4 * fade
          ..blendMode = BlendMode.plus
          ..color = palette.accent.withValues(alpha: 0.085 * fade),
      );
    }

    // ---- bells ------------------------------------------------------------
    for (final sp in state._sparks) {
      final u = (sp.age / 3.2).clamp(0.0, 1.0);
      final fade = math.pow(1 - u, 1.8).toDouble();
      final p = Offset(sp.pos.dx * size.width, sp.pos.dy * size.height);
      _blob(canvas, p, s * 0.055 * sp.size * (0.4 + 1.6 * fade),
          palette.accent.withValues(alpha: 0.55 * fade));
      _blob(canvas, p, s * 0.010 * sp.size,
          const Color(0xFFFFFFFF).withValues(alpha: 0.85 * fade));
    }

    // ---- the finger's wake -------------------------------------------------
    if (state._trail.length > 1) {
      for (var i = 1; i < state._trail.length; i++) {
        final a = state._trail[i - 1];
        final b = state._trail[i];
        final fade = (1 - b.age / 1.1).clamp(0.0, 1.0);
        if (fade <= 0.01) continue;
        canvas.drawLine(
          Offset(a.p.dx * size.width, a.p.dy * size.height),
          Offset(b.p.dx * size.width, b.p.dy * size.height),
          Paint()
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 1.0 + 5.0 * fade * fade
            ..blendMode = BlendMode.plus
            ..color = palette.accent.withValues(alpha: 0.16 * fade),
        );
      }
      final head = state._trail.last;
      final fade = (1 - head.age / 1.1).clamp(0.0, 1.0);
      _blob(
        canvas,
        Offset(head.p.dx * size.width, head.p.dy * size.height),
        s * 0.06 * fade,
        palette.accent.withValues(alpha: 0.28 * fade),
      );
    }

    // ---- the invitation ---------------------------------------------------
    if (idleHint > 0.01) {
      final breathe = 0.5 + 0.5 * math.sin(state.t * 0.9);
      final r = s * (0.115 + 0.012 * breathe);
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..blendMode = BlendMode.plus
          ..color = palette.accent
              .withValues(alpha: idleHint * (0.24 + 0.16 * breathe)),
      );
      final tri = Path();
      final d = s * 0.030;
      tri.moveTo(centre.dx - d * 0.45, centre.dy - d);
      tri.lineTo(centre.dx - d * 0.45, centre.dy + d);
      tri.lineTo(centre.dx + d * 0.95, centre.dy);
      tri.close();
      canvas.drawPath(
        tri,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = palette.accent.withValues(alpha: idleHint * 0.55),
      );
    }

    // ---- grain -------------------------------------------------------------
    // Last, over everything: it is dither for the wide dark gradients
    // underneath, and it only works if it is applied to the finished frame.
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.overlay
        ..shader = ImageShader(
          textures.grain,
          TileMode.repeated,
          TileMode.repeated,
          _identity,
        ),
    );
  }

  @override
  bool shouldRepaint(covariant NebulaPainter old) =>
      old.state != state || old.textures != textures;
}

