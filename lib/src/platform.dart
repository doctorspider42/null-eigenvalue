import 'dart:io';

import 'package:flutter/services.dart';

/// The three desktops, as one question.
///
/// The app is one screen on every platform and this file is deliberately the
/// only place that asks which one it is running on. What actually differs is
/// small: a phone has orientation and system bars, a desktop has a window, a
/// pointer that hovers and a keyboard.
bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// Whether the instrument is running on a television.
///
/// The same APK installs on a handset and on a set, so this cannot be "is it
/// Android" - it is asked of the system, once, in [detectTv], and answered by
/// whether the device carries the leanback feature. A phone that got the
/// television's layout would be locked to landscape with no way to reach the
/// chrome, which is the failure this exists to prevent.
///
/// What actually differs is the whole input story - no pointer, no keyboard, a
/// D-pad four inches from someone's hand and three metres from the screen - so
/// this flag is read rather more than the other two.
bool get isTv => _isTv;

bool _isTv = false;

/// Asks the platform whether this is a television, once, before the first
/// frame.
///
/// Cached in a plain bool rather than awaited at every call site: [isTv] is
/// read from `build` and from key handlers, and neither can wait on a channel.
/// Startup already awaits the engine and the textures, so one more round trip
/// here costs nothing that is not already being paid.
///
/// Anything that does not answer is not a television. A desktop has no channel
/// to ask, and a device that fails the question is far likelier to be a handset
/// than a set that forgot what it was.
Future<void> detectTv() async {
  if (!Platform.isAndroid) return;
  try {
    _isTv = await const MethodChannel('nulleigenvalue/device')
            .invokeMethod<bool>('isTelevision') ??
        false;
  } on PlatformException {
    _isTv = false;
  } on MissingPluginException {
    _isTv = false;
  }
}

/// How much bigger than the phone to draw the chrome on a television, given the
/// screen's shorter side in logical pixels.
///
/// A function with a test rather than an expression in `build`, because the
/// first version of this was reasoned from an assumption about what sets report
/// and was wrong by half. What they actually report - measured on a 4K set - is
/// 960x540 at devicePixelRatio 2, so the logical screen is a *third shorter*
/// than the phone the HUD was drawn for while being much wider. Scaling up on
/// the axis with less room is what walked the transport into the wordmark.
///
/// The ceiling is the useful part: a set that reports something unusual gets a
/// layout that still fits rather than one derived from a number nobody checked.
double tvChromeScale(double shortestSide) =>
    (shortestSide / 430).clamp(1.0, 1.6).toDouble();

/// Whether `audio_service` has an implementation here.
///
/// It ships Android, iOS and macOS. On the Mac that is worth having: it puts
/// the mood in Now Playing and makes the F7/F8/F9 media keys change mood and
/// pause, exactly as the lock screen does on a phone. Windows and Linux have
/// no such plugin, and asking anyway costs eight seconds of startup waiting
/// for a channel nobody is answering.
bool get hasMediaSession =>
    Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// The window, as far as this app cares about it: one switch.
///
/// Implemented in each runner rather than taken from a package. It is about
/// twenty lines of native code per platform against a dependency that would
/// pull three plugins in to do considerably more than the one thing wanted -
/// and a drone you leave running deserves a way to get the title bar off the
/// picture.
class AppWindow {
  const AppWindow._();

  static const MethodChannel _channel =
      MethodChannel('nulleigenvalue/window');

  static bool _fullscreen = false;

  /// Whether the window is currently filling the screen.
  static bool get isFullscreen => _fullscreen;

  /// Flips it, and returns the state afterwards.
  static Future<bool> toggleFullscreen() => setFullscreen(!_fullscreen);

  static Future<bool> setFullscreen(bool value) async {
    if (!isDesktop) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'setFullscreen',
        <String, Object?>{'value': value},
      );
      _fullscreen = result ?? _fullscreen;
    } on PlatformException {
      // A runner that does not answer is a window that does not go fullscreen.
      // Nothing else in the app depends on this.
    } on MissingPluginException {
      _fullscreen = false;
    }
    return _fullscreen;
  }
}
