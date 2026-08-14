import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Claims the audio session before anything else runs.
  ///
  /// This is deliberately not left to the engine or to a plugin. The session's
  /// category decides three things this app cannot do without: whether the
  /// ringer switch silences it (`.ambient` does, `.playback` does not),
  /// whether iOS keeps the process alive once the screen locks, and whether
  /// the app is eligible to appear on the lock screen at all. Several things
  /// in a Flutter app want to touch that session - miniaudio when it opens the
  /// device, audio_service when it starts - and whichever ran last used to
  /// win. Setting it here, at launch, means the answer does not depend on the
  /// order they happen to initialise in.
  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // No options: with .playback, Bluetooth A2DP and AirPlay routes are
      // already allowed by default, and Apple documents the explicit flags as
      // valid only with .playAndRecord - passing them here risks the whole
      // setCategory call being refused, which would leave the session in the
      // default soloAmbient and this app silent behind the ringer switch.
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true, options: [])
    } catch {
      // A session that will not configure means no sound, but the UI still
      // runs and the in-app diagnostics will say the callback count is zero.
      NSLog("Null Eigenvalue: audio session setup failed: \(error)")
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
