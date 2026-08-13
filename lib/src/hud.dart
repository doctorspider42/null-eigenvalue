import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nulleig/nulleig.dart';

import 'palette.dart';

/// The only chrome in the app: a transport and five names. It is hidden by
/// default and fades back out on its own, because a control that is always on
/// screen is a control you are always looking at.
class Hud extends StatelessWidget {
  const Hud({
    super.key,
    required this.palette,
    required this.mood,
    required this.playing,
    required this.rootHz,
    required this.onMood,
    required this.onToggle,
  });

  final MoodPalette palette;
  final int mood;
  final bool playing;
  final double rootHz;
  final ValueChanged<int> onMood;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Transport(playing: playing, colour: palette.accent, onTap: onToggle),
        const SizedBox(height: 30),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < neMoodCount; i++)
              _MoodChip(
                label: MoodPalette.all[i].name,
                selected: i == mood,
                colour: palette.accent,
                onTap: () => onMood(i),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          '${rootHz.toStringAsFixed(1)} Hz',
          style: TextStyle(
            fontSize: 10,
            height: 1.2,
            letterSpacing: 2.4,
            fontWeight: FontWeight.w300,
            color: Colors.white.withValues(alpha: 0.28),
          ),
        ),
      ],
    );
  }
}

class _MoodChip extends StatelessWidget {
  const _MoodChip({
    required this.label,
    required this.selected,
    required this.colour,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        // Generous horizontal padding: these are 10-point words and they still
        // have to be a comfortable target for a thumb.
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              width: selected ? 5 : 3,
              height: selected ? 5 : 3,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? colour
                    : Colors.white.withValues(alpha: 0.30),
              ),
            ),
            const SizedBox(height: 9),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOut,
              style: TextStyle(
                fontSize: 10,
                height: 1.0,
                letterSpacing: 1.7,
                fontWeight: FontWeight.w400,
                color: selected
                    ? colour
                    : Colors.white.withValues(alpha: 0.34),
              ),
              child: Text(label.toUpperCase()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.playing,
    required this.colour,
    required this.onTap,
  });

  final bool playing;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 92,
        height: 92,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: playing ? 1 : 0),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => CustomPaint(
            painter: _TransportPainter(t, colour),
          ),
        ),
      ),
    );
  }
}

/// A ring and a glyph that morphs between a triangle and two bars. Drawn
/// rather than iconed so the line weight matches the rest of the picture -
/// a Material icon next to this artwork looks like it came from another app.
class _TransportPainter extends CustomPainter {
  _TransportPainter(this.t, this.colour);

  /// 0 = showing "play", 1 = showing "pause".
  final double t;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * 0.40;

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = colour.withValues(alpha: 0.42),
    );

    final paint = Paint()..color = colour.withValues(alpha: 0.88);
    final d = r * 0.42;

    if (t < 0.02) {
      final tri = Path()
        ..moveTo(c.dx - d * 0.5, c.dy - d)
        ..lineTo(c.dx - d * 0.5, c.dy + d)
        ..lineTo(c.dx + d, c.dy)
        ..close();
      canvas.drawPath(tri, paint);
      return;
    }

    // Two bars, growing out of the triangle's silhouette as it collapses.
    final gap = d * 0.36 * t;
    final w = d * 0.30;
    final h = d * (1 - 0.12 * (1 - t));
    for (final sign in <double>[-1, 1]) {
      final x = c.dx + sign * (gap + w * 0.5) - w * 0.5 + (1 - t) * d * 0.1;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, c.dy - h, w, h * 2),
          Radius.circular(w * 0.35),
        ),
        paint..color = colour.withValues(alpha: 0.88 * math.min(1, t * 2.2)),
      );
    }
    if (t < 1) {
      final tri = Path()
        ..moveTo(c.dx - d * 0.5, c.dy - d)
        ..lineTo(c.dx - d * 0.5, c.dy + d)
        ..lineTo(c.dx + d, c.dy)
        ..close();
      canvas.drawPath(
        tri,
        Paint()..color = colour.withValues(alpha: 0.88 * (1 - t) * (1 - t)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TransportPainter old) =>
      old.t != t || old.colour != colour;
}
