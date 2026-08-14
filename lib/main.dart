// Null Eigenvalue - a generative drone that runs with the screen off.
//
// The whole app is one screen. Everything below is wiring: build the engine,
// hand it to the platform's media session so the lock screen can drive it,
// prepare the two textures the picture is drawn from, and get out of the way.

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nulleig/nulleig.dart';

import 'src/audio_handler.dart';
import 'src/drone_controller.dart';
import 'src/field_screen.dart';
import 'src/textures.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Edge to edge with transparent bars: the picture is the app, and a status
  // bar with a background on top of it looks like a mistake.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  DroneEngine engine;
  try {
    engine = DroneEngine.create();
  } catch (error) {
    runApp(_EngineFailure('$error'));
    return;
  }

  final controller = DroneController(engine);
  await controller.restore();
  await controller.prepareArtwork();

  try {
    await AudioService.init(
      builder: () => DroneAudioHandler(controller),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.nulleigenvalue.playback',
        androidNotificationChannelName: 'Null Eigenvalue',
        androidNotificationChannelDescription:
            'Keeps the drone running while the screen is off.',
        // The service stays in the foreground through a pause. Tearing it down
        // and rebuilding it on every play/pause is what makes the controls
        // flicker out of the notification shade and, on iOS, what loses the
        // audio session the app is living on.
        androidStopForegroundOnPause: false,
        androidNotificationOngoing: false,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
      // Bounded, because starting the device now waits on this. A media
      // session that never finishes initialising must cost us the lock
      // screen, not the sound.
    ).timeout(const Duration(seconds: 8));
    controller.mediaSessionOk = true;
  } catch (_) {
    // No media session is a degraded app, not a dead one: it still makes
    // sound, it just cannot be driven from a lock screen. Recorded rather
    // than merely swallowed: "ms0" in the diagnostics line is the difference
    // between chasing an iOS eligibility rule and chasing this timeout.
    controller.mediaSessionOk = false;
  }

  // Last, deliberately. AudioService touches the audio session on the way up,
  // and whichever of the two configures it last decides the category - which
  // decides whether the ringer switch silences us and whether iOS lets the
  // app keep running once the screen locks.
  controller.startAudio();

  final textures = await Textures.load();
  runApp(NullEigenvalueApp(controller: controller, textures: textures));
}

class NullEigenvalueApp extends StatelessWidget {
  const NullEigenvalueApp({
    super.key,
    required this.controller,
    required this.textures,
  });

  final DroneController controller;
  final Textures textures;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Null Eigenvalue',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF03070C),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      // No AnimatedBuilder here: FieldScreen subscribes to the controller
      // itself, and rebuilding it from above as well would just do the same
      // work twice per change.
      home: FieldScreen(controller: controller, textures: textures),
    );
  }
}

class _EngineFailure extends StatelessWidget {
  const _EngineFailure(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF03070C),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: Text(
              'The synthesis engine did not load.\n\n$message',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.7,
                letterSpacing: 1.2,
                color: Color(0x99FFFFFF),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
