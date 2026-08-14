// These tests deliberately do not build the app.
//
// Everything interesting about Null Eigenvalue is either behind FFI - and the
// engine is a phone binary that does not exist on a test host - or it is a
// picture, and a golden test of a nebula that is animated by a random walk is
// a test that fails on Tuesdays. What is worth pinning down here is the
// boundary: the constants Dart and C++ have to agree on, and the colour maths
// that the whole look rests on.

import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:null_eigenvalue/src/palette.dart';
import 'package:null_eigenvalue/src/updater.dart';
import 'package:nulleig/nulleig.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // The desktop updater's one piece of pure logic, and the one place it could
  // do harm: say yes wrongly and it downloads an installer nobody asked for.
  group('version comparison', () {
    test('a higher patch is newer', () {
      expect(isNewerVersion('0.1.42', '0.1.41'), isTrue);
      expect(isNewerVersion('0.1.41', '0.1.42'), isFalse);
    });

    test('the same version is not newer', () {
      expect(isNewerVersion('0.1.7', '0.1.7'), isFalse);
    });

    test('components are compared as numbers, not as text', () {
      // The bug this exists to prevent: CI's patch number is the run number,
      // so it goes past 9 on the tenth push and string ordering would then
      // stop offering updates for good.
      expect(isNewerVersion('0.1.10', '0.1.9'), isTrue);
      expect(isNewerVersion('0.2.0', '0.10.0'), isFalse);
    });

    test('a missing component counts as zero', () {
      expect(isNewerVersion('0.2', '0.1.9'), isTrue);
      expect(isNewerVersion('0.1', '0.1.0'), isFalse);
    });

    test('anything unparseable is not newer', () {
      // A malformed tag must be able to fail in one direction only.
      expect(isNewerVersion('nightly', '0.1.7'), isFalse);
      expect(isNewerVersion('0.1.7-rc1', '0.1.6'), isFalse);
      expect(isNewerVersion('0.1.8', ''), isFalse);
    });
  });

  // The switch, and only the switch. Everything past the guard is an HTTPS
  // request, and a unit test that reaches GitHub is a unit test that fails
  // whenever the runner has no network - so what is pinned here is the one
  // thing that must hold offline: that "off" means the app does not go to the
  // network on its own, and that it is still off next launch.
  //
  // The updater only does anything on a desktop, which is where this suite
  // runs everywhere except the phone-shaped CI jobs.
  group('the automatic update check', () {
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    test('does nothing while it is switched off', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'updateAuto': false,
      });
      final updater = Updater(currentVersion: '0.1.0');
      await updater.load();
      expect(updater.auto, isFalse);

      // Returns before touching the network, so this is safe with no route to
      // the internet - and if the guard ever regresses, the stage moves off
      // idle and this fails.
      await updater.check();
      expect(updater.stage, UpdateStage.idle);
    }, skip: desktop ? null : 'the updater is desktop-only');

    test('is on unless it has been turned off, and stays off', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final first = Updater(currentVersion: '0.1.0');
      await first.load();
      expect(first.auto, isTrue, reason: 'the default is to look');

      await first.setAuto(false);

      final next = Updater(currentVersion: '0.1.0');
      await next.load();
      expect(next.auto, isFalse, reason: 'the switch outlives the launch');
    }, skip: desktop ? null : 'the updater is desktop-only');
  });
}

double _luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
