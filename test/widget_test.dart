// These tests deliberately do not build the app.
//
// Everything interesting about Null Eigenvalue is either behind FFI - and the
// engine is a phone binary that does not exist on a test host - or it is a
// picture, and a golden test of a nebula that is animated by a random walk is
// a test that fails on Tuesdays. What is worth pinning down here is the
// boundary: the constants Dart and C++ have to agree on, and the colour maths
// that the whole look rests on.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:null_eigenvalue/src/palette.dart';
import 'package:nulleig/nulleig.dart';

void main() {
  test('every mood the engine knows has a palette', () {
    // If these ever disagree, the app indexes past the end of the palette list
    // the first time someone taps the last mood.
    expect(MoodPalette.all.length, neMoodCount);
  });

  test('palette names match the engine order', () {
    const expected = <String>[
      'Kernel',
      'Manifold',
      'Halo',
      'Torsion',
      'Limit',
      'Entropy',
    ];
    expect(MoodPalette.all.map((p) => p.name).toList(), expected);
  });

  test('band colours run from deep to accent', () {
    final p = MoodPalette.all[1];
    final low = p.forBand(0, neBands, 0);
    final high = p.forBand(neBands - 1, neBands, 0);
    expect(low, isNot(equals(high)));
    // Luminance has to increase with register or the picture reads upside
    // down: the low voices would be the bright ones.
    expect(_luma(high), greaterThan(_luma(low)));
  });

  test('brightness lifts the colour without leaving the palette', () {
    final p = MoodPalette.all[2];
    final dull = p.forBand(3, neBands, 0);
    final bright = p.forBand(3, neBands, 1);
    expect(_luma(bright), greaterThan(_luma(dull)));
  });

  test('palette lerp is stable at the ends', () {
    final a = MoodPalette.all[0];
    final b = MoodPalette.all[3];
    expect(MoodPalette.lerp(a, b, 0).bg, a.bg);
    expect(MoodPalette.lerp(a, b, 1).bg, b.bg);
    expect(MoodPalette.lerp(a, b, -5).bg, a.bg);
    expect(MoodPalette.lerp(a, b, 5).bg, b.bg);
  });

  test('an empty vis snapshot is the right shape', () {
    expect(DroneVis.empty.bands.length, neBands);
    expect(DroneVis.empty.gate, 0);
  });
}

double _luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
