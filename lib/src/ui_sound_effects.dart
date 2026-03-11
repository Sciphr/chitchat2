import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

enum UiSoundEffect {
  joinCall(segments: [660, 880], segmentMs: 90),
  leaveCall(segments: [880, 660], segmentMs: 100),
  mute(segments: [480], segmentMs: 90),
  unmute(segments: [720], segmentMs: 90),
  deafen(segments: [420, 300], segmentMs: 110),
  undeafen(segments: [300, 460], segmentMs: 110);

  const UiSoundEffect({required this.segments, required this.segmentMs});

  final List<int> segments;
  final int segmentMs;
}

class UiSoundEffects {
  UiSoundEffects() {
    if (_useAudioPlayer) {
      _player = AudioPlayer()
        ..setReleaseMode(ReleaseMode.stop)
        ..setPlayerMode(PlayerMode.lowLatency)
        ..setVolume(0.75);
    }
  }

  static const int _gapMs = 28;
  AudioPlayer? _player;

  bool get _useNativeWindowsBeep =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _useAudioPlayer => !_useNativeWindowsBeep;

  Future<void> play(UiSoundEffect effect, {bool enabled = true}) async {
    if (!enabled) {
      return;
    }
    try {
      if (_useNativeWindowsBeep) {
        await _playNativeWindowsBeep(effect);
        return;
      }

      final player = _player;
      if (player == null) {
        return;
      }
      await player.stop();
      await player.play(BytesSource(_buildTone(effect), mimeType: 'audio/wav'));
    } catch (_) {
      // UI sound effects should never interrupt core call controls.
    }
  }

  Future<void> _playNativeWindowsBeep(UiSoundEffect effect) async {
    await Future<void>(() {
      for (var index = 0; index < effect.segments.length; index++) {
        Beep(effect.segments[index], effect.segmentMs);
        if (index == effect.segments.length - 1) {
          continue;
        }
        Sleep(_gapMs);
      }
    });
  }

  Future<void> dispose() async {
    await _player?.dispose();
  }
}

Uint8List _buildTone(UiSoundEffect effect) {
  const sampleRate = 44100;
  const amplitude = 0.28;
  const gapMs = 28;
  final samples = <int>[];

  for (
    var segmentIndex = 0;
    segmentIndex < effect.segments.length;
    segmentIndex++
  ) {
    final frequency = effect.segments[segmentIndex];
    final segmentSamples = (sampleRate * effect.segmentMs / 1000).round();
    for (var sampleIndex = 0; sampleIndex < segmentSamples; sampleIndex++) {
      final progress = sampleIndex / segmentSamples;
      final envelope = progress < 0.14
          ? progress / 0.14
          : progress > 0.86
          ? (1 - progress) / 0.14
          : 1.0;
      final sample =
          math.sin(2 * math.pi * frequency * sampleIndex / sampleRate) *
          amplitude *
          envelope;
      samples.add((sample * 32767).round());
    }
    if (segmentIndex == effect.segments.length - 1) {
      continue;
    }
    final gapSamples = (sampleRate * gapMs / 1000).round();
    samples.addAll(List<int>.filled(gapSamples, 0));
  }

  final dataSize = samples.length * 2;
  final bytes = ByteData(44 + dataSize);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);

  for (var index = 0; index < samples.length; index++) {
    bytes.setInt16(44 + (index * 2), samples[index], Endian.little);
  }

  return bytes.buffer.asUint8List();
}
