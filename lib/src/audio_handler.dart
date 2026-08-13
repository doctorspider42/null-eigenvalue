import 'package:audio_service/audio_service.dart';

import 'drone_controller.dart';

/// Bridges the engine to the platform's media session: the iOS lock screen and
/// Control Centre, the Android notification, headphone buttons, the car.
///
/// It carries no audio. The samples are produced natively and this object only
/// publishes what is playing and receives the transport commands - which is
/// why pause here is a fade, not a teardown: the audio session must stay
/// active or iOS takes back the right to run in the background and the
/// controls vanish from the lock screen.
class DroneAudioHandler extends BaseAudioHandler {
  DroneAudioHandler(this.controller) {
    controller.addListener(_publish);
    _publish();
  }

  final DroneController controller;

  @override
  Future<void> play() async => controller.setPlaying(true);

  @override
  Future<void> pause() async => controller.setPlaying(false);

  /// There is nothing to stop. A generative drone has no end, so the honest
  /// response to "stop" from a car stereo or a notification swipe is to fall
  /// silent and stay ready.
  @override
  Future<void> stop() async => controller.setPlaying(false);

  /// Next and previous move through the moods. It is the one thing worth
  /// reaching for without unlocking the phone, and mapping it onto the
  /// skip buttons means it works from a lock screen, a headphone remote and a
  /// steering wheel without any of them knowing what a mood is.
  @override
  Future<void> skipToNext() async => controller.cycleMood(1);

  @override
  Future<void> skipToPrevious() async => controller.cycleMood(-1);

  @override
  Future<void> seek(Duration position) async {}

  void _publish() {
    mediaItem.add(
      MediaItem(
        id: 'null-eigenvalue/${controller.mood}',
        title: controller.moodName,
        album: 'Null Eigenvalue',
        artist: 'generated, continuously',
        // No duration: the piece does not have one, and a media session with
        // no duration is what makes both platforms draw a live indicator
        // instead of a scrubber that lies.
        artUri: controller.artworkUri,
      ),
    );

    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          if (controller.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const <MediaAction>{},
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: controller.playing,
        updatePosition: Duration.zero,
        speed: 1,
      ),
    );
  }
}
