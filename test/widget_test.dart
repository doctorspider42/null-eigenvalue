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
import 'package:null_eigenvalue/src/drone_controller.dart';
import 'package:null_eigenvalue/src/hud.dart';
import 'package:null_eigenvalue/src/palette.dart';
import 'package:null_eigenvalue/src/platform.dart';
import 'package:null_eigenvalue/src/tv_focus.dart';
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

  group('the remote', () {
    test('the ring and the playing mood are different things', () {
      // Walking the row must not change the mood - six presses to reach the
      // last one would otherwise cost six crossfades.
      const focus = TvFocus(control: TvControl.mood, mood: 3);
      expect(focus.ringsMood(3), isTrue);
      expect(focus.ringsMood(0), isFalse);
      // And the cursor keeps its dot while it is somewhere else entirely, so
      // coming back to the row lands where it left.
      final gear = focus.withControl(TvControl.gear);
      expect(gear.mood, 3);
      expect(gear.ringsMood(3), isFalse);
    });

    test('the D-pad can reach every dot', () {
      // The chrome handler clamps the cursor to this, so a mood the engine
      // grew without a dot to match would be unreachable from a remote.
      expect(MoodPalette.all.length, neMoodCount);
    });

    test('every panel row a remote can reach has something on it', () {
      // The sleep column is OFF plus one row per duration. Adding a duration
      // without the count following leaves the last one unreachable, and the
      // handler turns row n into minutes[n - 1], so an off-by-one picks the
      // wrong duration rather than failing outright.
      expect(
        SettingsPanel.tvRowsIn(SettingsPanel.tvSleepColumn, withUpdates: true),
        SettingsPanel.minutes.length + 1,
      );
      // Whether there is an updater is the settings column's business; the
      // durations do not move either way.
      expect(
        SettingsPanel.tvRowsIn(SettingsPanel.tvSleepColumn, withUpdates: false),
        SettingsPanel.tvRowsIn(SettingsPanel.tvSleepColumn, withUpdates: true),
      );
    });

    test('the update rows are only walkable where there is an updater', () {
      // Both rows are drawn behind `updates != null` and counted behind the
      // same condition. If the two ever disagree the D-pad either stops one row
      // short of INSTALL or walks onto a row that is not there - and the second
      // is silent, because the ring simply vanishes.
      expect(SettingsPanel.tvUpdateRow, SettingsPanel.tvDiagnosticsRow + 1);
      expect(SettingsPanel.tvAutoRow, SettingsPanel.tvUpdateRow + 1);
      expect(
        SettingsPanel.tvRowsIn(SettingsPanel.tvSettingsColumn,
            withUpdates: true),
        SettingsPanel.tvRowsIn(SettingsPanel.tvSettingsColumn,
                withUpdates: false) +
            2,
      );
    });

    test('a build CI did not cut never offers itself an update', () {
      // The guard that keeps a working tree from being replaced by a release,
      // and the reason the Android rows are conditional at all.
      expect(Updater(currentVersion: '').enabled, isFalse);
    });

    test('the level is the first thing sideways of the durations', () {
      // The point of the second column. Reaching the level used to mean walking
      // all six durations, because the cursor was one running number over a
      // layout the eye reads as two columns side by side.
      expect(SettingsPanel.tvVolumeRow, 0);
      expect(SettingsPanel.tvSettingsColumn,
          greaterThan(SettingsPanel.tvSleepColumn));
    });

    test('the chrome fits the screen a television actually reports', () {
      // 960x540 at dpr 2 is what a 4K set reports; the first version of this
      // assumed the same size but scaled it by 1.8, which stood the chrome 420
      // pixels tall in a 540-pixel screen and pushed the transport into the
      // wordmark once the diagnostics appeared.
      final scale = tvChromeScale(540);
      expect(scale, closeTo(1.26, 0.05));

      // The HUD's own fixed heights: transport, the gaps, the dots, the mood
      // name and the readout. Whatever the scale, that column plus the bottom
      // padding has to leave the wordmark's band alone.
      const columnAtUnitScale = 92 + 26 + 34 + 14 + 12 + 12 + 22;
      expect(columnAtUnitScale * scale + 34 * scale, lessThan(540 * 0.75));
    });

  });

  group('the second field', () {
    // The two-finger gesture is relative and has no scale printed on it, so
    // the only home it has is one you can feel. These pin the feel.
    const span = DroneController.pitchSpan;
    const width = DroneController.pitchDetent;

    test('has a home you can always get back to', () {
      // Anything inside the band is exactly nothing. Without this, an
      // instrument you can detune is an instrument you cannot re-tune - the
      // odds of landing on 0.00 semitones by dragging a thumb are none.
      expect(DroneController.detent(0, width, span), 0);
      expect(DroneController.detent(width, width, span), 0);
      expect(DroneController.detent(-width, width, span), 0);
    });

    test('leaving it is a slide and not a jump', () {
      // The band is subtracted rather than snapped, so the first hair outside
      // it is worth a hair. A snap would make the detent audible as a lurch,
      // which on a pitch control is the one thing it must not be.
      expect(DroneController.detent(width + 0.001, width, span),
          closeTo(0.001, 1e-9));
      expect(DroneController.detent(-width - 0.001, width, span),
          closeTo(-0.001, 1e-9));
    });

    test('a full traverse reaches the ends and stops there', () {
      // The accumulator is clamped a whole band past the span, which is what
      // pays for the dead zone: without the extra width the axis would top out
      // a detent short of its own range and never reach twelve semitones.
      expect(DroneController.detent(span + width, width, span), span);
      expect(DroneController.detent(span * 9, width, span), span);
      expect(DroneController.detent(-span * 9, width, span), -span);
    });
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

  group('the second field in the picture', () {
    // Pitch is colour as well as sound. What has to hold is the direction and
    // the fact that home is untouched - the exact amounts are taste, and a
    // test that pins taste is a test that has to be edited to change a look.
    final p = MoodPalette.all[1];

    test('home is the mood and nothing else', () {
      // The default state of the app. If transposing at zero returned a
      // slightly different palette, every mood in the app would be a shade
      // off its own colours for no reason anyone could see.
      final home = p.transposed(0);
      expect(home.bg, p.bg);
      expect(home.deep, p.deep);
      expect(home.mid, p.mid);
      expect(home.accent, p.accent);
    });

    test('up is brighter and down is darker, all the way through', () {
      final up = p.transposed(1);
      final down = p.transposed(-1);
      for (final pair in <List<Color>>[
        <Color>[down.deep, p.deep, up.deep],
        <Color>[down.mid, p.mid, up.mid],
        <Color>[down.accent, p.accent, up.accent],
      ]) {
        expect(_luma(pair[0]), lessThan(_luma(pair[1])));
        expect(_luma(pair[2]), greaterThan(_luma(pair[1])));
      }
    });

    test('the page never becomes a hole', () {
      // The one rule the background has: a real black rectangle on an OLED
      // reads as a hole rather than as depth, and an octave down darkens it.
      for (final mood in MoodPalette.all) {
        expect(_luma(mood.transposed(-1).bg), greaterThan(0.005));
      }
    });

    test('past an octave is an octave', () {
      // The controller clamps its own accumulator, but the amount handed here
      // is a division by the span and a spare band is allowed past it.
      expect(p.transposed(-4).mid, p.transposed(-1).mid);
      expect(p.transposed(9).accent, p.transposed(1).accent);
    });
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
