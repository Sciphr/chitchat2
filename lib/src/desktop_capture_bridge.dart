// ignore_for_file: implementation_imports

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc/src/native/media_stream_impl.dart';

class DesktopCaptureBridge {
  static const double defaultScreenShareFrameRate = 30;
  static const int defaultScreenShareWidth = 1920;
  static const int defaultScreenShareHeight = 1080;

  Future<MediaStream> getScreenShareStream(
    DesktopCapturerSource source, {
    double frameRate = defaultScreenShareFrameRate,
    int maxWidth = defaultScreenShareWidth,
    int maxHeight = defaultScreenShareHeight,
    bool captureSystemAudio = false,
  }) async {
    if (!WebRTC.platformIsDesktop) {
      throw UnsupportedError(
        'Native desktop capture is only available on Windows, macOS, and Linux.',
      );
    }

    try {
      final response =
          await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
            'getDisplayMedia',
            <String, dynamic>{
              'constraints': {
                'audio': captureSystemAudio,
                'video': {
                  'deviceId': {'exact': source.id},
                  'mandatory': {
                    'frameRate': frameRate,
                    'minFrameRate': frameRate >= 24 ? 24 : frameRate,
                    'maxFrameRate': frameRate,
                    'minWidth': 640,
                    'minHeight': 360,
                    'maxWidth': maxWidth,
                    'maxHeight': maxHeight,
                  },
                },
              },
            },
          );

      if (response == null) {
        throw StateError('Native desktop capture returned no stream.');
      }

      final stream = MediaStreamNative(response['streamId'] as String, 'local');
      stream.setMediaTracks(
        List<dynamic>.from(response['audioTracks'] as List? ?? const []),
        List<dynamic>.from(response['videoTracks'] as List? ?? const []),
      );
      return stream;
    } on PlatformException catch (error) {
      throw StateError(
        'Unable to create native desktop capture stream: ${error.message}',
      );
    }
  }
}
