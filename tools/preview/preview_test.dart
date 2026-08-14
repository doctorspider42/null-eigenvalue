// Renders the app's screen to PNG files without a phone.
//
//   flutter test tools/preview/preview_test.dart
//   (writes tools/preview/out/*.png)
//
// Not part of the test suite - `flutter test` with no arguments only walks
// test/, so this runs when it is asked for. It exists because the picture is
// half the product and the alternative way to look at it is to build an
// unsigned .ipa, sideload it and squint. The widget tester rasterises with a
// real canvas, so what comes out here is what the painter will draw.
//
// The engine is not involved: these are hand-written vis snapshots, which is
// the point - it can be posed in states that would take twenty minutes of
// listening to catch by accident.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:null_eigenvalue/src/hud.dart';
import 'package:null_eigenvalue/src/nebula.dart';
import 'package:null_eigenvalue/src/palette.dart';
import 'package:null_eigenvalue/src/textures.dart';
import 'package:nulleig/nulleig.dart';

const Size kPhone = Size(393, 852); // iPhone 15 in logical pixels

// The window the desktop runners open at. The point of shooting this size is
// that it is the one thing about the desktop build a phone-shaped preview
// cannot tell you: whether a composition designed for a tall narrow frame
// still holds when the frame is wider than it is tall.
const Size kDesktop = Size(1040, 780);

// The panel's callbacks, as top-level no-ops, so the whole UpdatePanel can be
// const in a still that nobody is going to click.
void _ignore() {}
void _ignoreBool(bool _) {}

DroneVis _vis({
  required double level,
  required double centroid,
  required List<double> bands,
  double spark = 0,
  double gate = 1,
  double rootHz = 55,
  int chord = 0,
}) =>
    DroneVis(
      level: level,
      centroid: centroid,
      bands: bands,
      spark: spark,
      rootHz: rootHz,
      motion: 0.3,
      gate: gate,
      chordChange: chord,
    );

void main() {
  late Textures textures;

  setUpAll(() async {
    final dir = Directory('tools/preview/out');
    if (!dir.existsSync()) dir.createSync(recursive: true);
  });

  Future<void> shot(
    WidgetTester tester,
    String name, {
    required int mood,
    required DroneVis vis,
    required Offset centre,
    bool hud = false,
    bool playing = true,
    double idleHint = 0,
    double seconds = 41.3,
    List<Offset> trail = const <Offset>[],
    Size size = kPhone,
    String? updateLabel,
    String? volumeLabel,
    bool panel = false,
  }) async {
    // The HUD's own rule, repeated rather than imported: field_screen computes
    // it from MediaQuery, and this harness has no MediaQuery worth the name.
    final scale =
        size == kPhone ? 1.0 : (size.shortestSide / 620).clamp(1.0, 1.5).toDouble();

    tester.view.physicalSize = size * 3.0;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      textures = await Textures.load();
    });

    final state = NebulaState()
      ..palette = MoodPalette.all[mood]
      ..idleHint = idleHint
      ..centre = centre
      ..target = centre;
    for (final p in trail) {
      state.addTrail(p);
    }
    // Advance to a plausible moment: the orbits are functions of time, and at
    // t = 0 every one of them is at the same phase, which is the one
    // arrangement the app will never actually show.
    var t = 0.0;
    while (t < seconds) {
      state.advance(1 / 60, vis);
      t += 1 / 60;
    }

    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            backgroundColor: MoodPalette.all[mood].bg,
            body: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                CustomPaint(painter: NebulaPainter(state: state, textures: textures)),
                if (hud && !panel)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 42 * scale),
                      child: Hud(
                        palette: MoodPalette.all[mood],
                        mood: mood,
                        playing: playing,
                        rootHz: vis.rootHz,
                        scale: scale,
                        updateLabel: updateLabel,
                        onUpdateTap: () {},
                        volumeLabel: volumeLabel,
                        onMood: (_) {},
                        onToggle: () {},
                      ),
                    ),
                  ),
                if (hud && !panel)
                  Positioned(
                    top: 44 * scale,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                          'NULL EIGENVALUE',
                          style: TextStyle(
                            fontSize: 11 * scale,
                            letterSpacing: 6.5 * scale,
                            fontWeight: FontWeight.w300,
                            color: Colors.white.withValues(alpha: 0.34),
                          ),
                        ),
                        if (size != kPhone)
                          Text(
                            '  0.1.9',
                            style: TextStyle(
                              fontSize: 10 * scale,
                              letterSpacing: 2.4 * scale,
                              fontWeight: FontWeight.w300,
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (hud && !panel)
                  Positioned(
                    top: 8 * scale,
                    right: 10,
                    child: GearButton(
                      colour: MoodPalette.all[mood].accent,
                      scale: scale,
                      onTap: () {},
                    ),
                  ),
                if (panel)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Center(
                        child: SettingsPanel(
                          accent: MoodPalette.all[mood].accent,
                          remaining: const Duration(minutes: 27, seconds: 41),
                          choice: const Duration(minutes: 30),
                          scale: scale,
                          showKeys: true,
                          volume: 0.72,
                          onVolume: (_) {},
                          updates: const UpdatePanel(
                            auto: true,
                            busy: false,
                            status: 'UP TO DATE',
                            onAuto: _ignoreBool,
                            onCheck: _ignore,
                          ),
                          onPick: (_) {},
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Two pumps: the transport's TweenAnimationBuilder starts at 0 and the
    // still would otherwise always catch it mid-morph.
    await tester.pump(const Duration(milliseconds: 600));

    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('tools/preview/out/$name.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('manifold, playing, mid field', (tester) async {
    await shot(
      tester,
      '01-manifold',
      mood: 1,
      centre: const Offset(0.5, 0.55),
      vis: _vis(
        level: 0.42,
        centroid: 0.52,
        bands: <double>[0.55, 0.72, 0.40, 0.61, 0.28, 0.44, 0.14, 0.06],
      ),
    );
  });

  testWidgets('manifold with the hud up', (tester) async {
    await shot(
      tester,
      '02-manifold-hud',
      mood: 1,
      hud: true,
      centre: const Offset(0.5, 0.55),
      vis: _vis(
        level: 0.42,
        centroid: 0.52,
        bands: <double>[0.55, 0.72, 0.40, 0.61, 0.28, 0.44, 0.14, 0.06],
      ),
    );
  });

  testWidgets('kernel, dark and low, finger low left', (tester) async {
    await shot(
      tester,
      '03-kernel',
      mood: 0,
      centre: const Offset(0.22, 0.78),
      vis: _vis(
        level: 0.58,
        centroid: 0.18,
        bands: <double>[0.85, 0.78, 0.34, 0.12, 0.05, 0.02, 0, 0],
        rootHz: 43.7,
      ),
    );
  });

  testWidgets('halo, bright and dense, bell just struck', (tester) async {
    await shot(
      tester,
      '04-halo',
      mood: 2,
      centre: const Offset(0.82, 0.24),
      vis: _vis(
        level: 0.47,
        centroid: 0.86,
        bands: <double>[0.18, 0.26, 0.44, 0.62, 0.78, 0.71, 0.55, 0.34],
        spark: 0.9,
        rootHz: 65.4,
      ),
      trail: <Offset>[
        for (var i = 0; i < 22; i++)
          Offset(0.42 + 0.40 * i / 21, 0.62 - 0.38 * i / 21),
      ],
    );
  });

  testWidgets('torsion', (tester) async {
    await shot(
      tester,
      '05-torsion',
      mood: 3,
      centre: const Offset(0.62, 0.46),
      vis: _vis(
        level: 0.51,
        centroid: 0.63,
        bands: <double>[0.40, 0.55, 0.66, 0.30, 0.58, 0.22, 0.30, 0.10],
        rootHz: 49.0,
      ),
    );
  });

  testWidgets('entropy', (tester) async {
    await shot(
      tester,
      '06-entropy',
      mood: 5,
      centre: const Offset(0.38, 0.66),
      vis: _vis(
        level: 0.55,
        centroid: 0.34,
        bands: <double>[0.80, 0.62, 0.20, 0.10, 0.06, 0.03, 0.01, 0],
        rootHz: 36.7,
      ),
    );
  });

  // ------------------------------------------------------------- the desktop
  // Same painter, same HUD, a frame that is wider than it is tall. The thing
  // being judged here is whether the composition survives that: the orbits are
  // stretched by the aspect ratio and the chrome is scaled by one number, and
  // either could have gone wrong without anyone noticing on a phone.

  testWidgets('desktop window, hud up', (tester) async {
    await shot(
      tester,
      '08-desktop-hud',
      mood: 1,
      hud: true,
      size: kDesktop,
      centre: const Offset(0.5, 0.55),
      vis: _vis(
        level: 0.42,
        centroid: 0.52,
        bands: <double>[0.55, 0.72, 0.40, 0.61, 0.28, 0.44, 0.14, 0.06],
      ),
    );
  });

  testWidgets('desktop window, an update on offer', (tester) async {
    await shot(
      tester,
      '09-desktop-update',
      mood: 2,
      hud: true,
      size: kDesktop,
      updateLabel: 'UPDATE 0.1.42',
      volumeLabel: 'VOLUME 72%',
      centre: const Offset(0.72, 0.34),
      vis: _vis(
        level: 0.47,
        centroid: 0.78,
        bands: <double>[0.20, 0.30, 0.48, 0.64, 0.74, 0.66, 0.50, 0.30],
        rootHz: 61.7,
      ),
    );
  });

  testWidgets('desktop window, the panel behind the gear', (tester) async {
    await shot(
      tester,
      '10-desktop-panel',
      mood: 3,
      hud: true,
      panel: true,
      size: kDesktop,
      centre: const Offset(0.44, 0.58),
      vis: _vis(
        level: 0.51,
        centroid: 0.55,
        bands: <double>[0.44, 0.58, 0.62, 0.34, 0.52, 0.24, 0.28, 0.10],
        rootHz: 49.0,
      ),
    );
  });

  testWidgets('stopped: the invitation', (tester) async {
    await shot(
      tester,
      // Mood 1: this is the shot that has to be judged as a first launch, so
      // it uses the mood a first launch actually starts in, not a grey one.
      '07-idle',
      mood: 1,
      centre: const Offset(0.5, 0.52),
      playing: false,
      idleHint: 1,
      vis: _vis(
        level: 0,
        centroid: 0.4,
        bands: <double>[0, 0, 0, 0, 0, 0, 0, 0],
        gate: 0,
        rootHz: 41.2,
      ),
    );
  });
}
