import 'package:audioplayers/audioplayers.dart';

enum UiSoundEffect {
  joinCall('join.wav'),
  leaveCall('leave.wav'),
  mute('mute.wav'),
  unmute('unmute.wav'),
  deafen('deafen.wav'),
  undeafen('undeafen.wav');

  const UiSoundEffect(this.assetName);

  final String assetName;
}

class UiSoundEffects {
  UiSoundEffects() {
    _player.setReleaseMode(ReleaseMode.stop);
    _player.setPlayerMode(PlayerMode.lowLatency);
    _player.setVolume(0.7);
  }

  final AudioPlayer _player = AudioPlayer();

  Future<void> play(UiSoundEffect effect) async {
    try {
      await _player.stop();
      await _player.play(AssetSource('audio/${effect.assetName}'));
    } catch (_) {
      // Sound effects should never interrupt core call controls.
    }
  }

  Future<void> dispose() => _player.dispose();
}
