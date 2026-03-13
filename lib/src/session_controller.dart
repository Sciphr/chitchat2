import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_bootstrap.dart';
import 'app_preferences.dart';
import 'desktop_capture_bridge.dart';
import 'models.dart';
import 'repositories.dart';
import 'ui_sound_effects.dart';

class ScreenShareService {
  Future<List<DesktopCapturerSource>> getScreenShareSources() async {
    if (!WebRTC.platformIsDesktop) {
      throw UnsupportedError(
        'Desktop screen source enumeration is only available on Windows, macOS, and Linux.',
      );
    }

    return desktopCapturer.getSources(
      types: const [SourceType.Screen, SourceType.Window],
      thumbnailSize: ThumbnailSize(640, 360),
    );
  }

  Future<MediaStream> openConfiguredMicrophone({
    String? deviceId,
    bool noiseCancellation = true,
  }) async {
    if (deviceId != null && deviceId.isNotEmpty) {
      try {
        await Helper.selectAudioInput(deviceId);
      } on Object {
        // Constraint-based device selection below is the fallback path.
      }
    }
    await applyVoiceProcessingPreference(noiseCancellation);

    return navigator.mediaDevices.getUserMedia({
      'audio': {
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
        'echoCancellation': noiseCancellation,
        'noiseSuppression': noiseCancellation,
        'autoGainControl': false,
      },
      'video': false,
    });
  }

  Future<MediaStream> openConfiguredCamera({String? deviceId}) {
    return navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
        'mandatory': {'minWidth': 960, 'minHeight': 540, 'minFrameRate': 15},
      },
    });
  }

  Future<void> applyAudioOutputDevice(String? deviceId) async {
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    try {
      await Helper.selectAudioOutput(deviceId);
    } on Object {
      // Device routing should not break the application when unsupported.
    }
  }

  Future<void> applyVoiceProcessingPreference(bool enabled) async {
    try {
      await NativeAudioManagement.setIsVoiceProcessingBypassed(!enabled);
    } on Object {
      // Voice-processing APIs are not available on every desktop build.
    }
  }

  Future<void> stopStream(MediaStream? stream) async {
    if (stream == null) {
      return;
    }
    for (final track in stream.getTracks()) {
      track.stop();
    }
    try {
      await stream.dispose();
    } on PlatformException catch (error) {
      if (error.code != 'MediaStreamDisposeFailed' ||
          !(error.message?.contains('not found') ?? false)) {
        rethrow;
      }
    }
  }
}

class VoiceRemotePeer {
  VoiceRemotePeer({
    required this.participant,
    required this.cameraRenderer,
    required this.screenRenderer,
  });

  VoiceParticipant participant;
  final RTCVideoRenderer cameraRenderer;
  final RTCVideoRenderer screenRenderer;
  MediaStream? cameraStream;
  MediaStream? screenStream;
  MediaStream? screenRenderStream;

  bool get hasCamera =>
      cameraStream != null && cameraRenderer.srcObject != null;
  bool get hasScreen =>
      screenStream != null && screenRenderer.srcObject != null;
}

class VoiceChannelSessionController extends ChangeNotifier {
  static const String _preferredVideoCodec = 'vp9';
  static const String _fallbackVideoCodec = 'vp8';
  static const Duration _warmedTokenMaxAge = Duration(seconds: 45);

  VoiceChannelSessionController({
    required this.channel,
    required this.client,
    required this.authService,
    required this.preferences,
    required this.screenShareService,
    required this.soundEffects,
  }) : clientId = authService.userId;

  final ChannelSummary channel;
  final SupabaseClient client;
  final AuthService authService;
  final AppPreferences preferences;
  final ScreenShareService screenShareService;
  final UiSoundEffects soundEffects;
  final String clientId;

  final RTCVideoRenderer localCameraRenderer = RTCVideoRenderer();
  final RTCVideoRenderer localScreenRenderer = RTCVideoRenderer();
  final Map<String, VoiceRemotePeer> _peerStates = <String, VoiceRemotePeer>{};
  final Map<String, double> _participantVolumes = <String, double>{};
  final Map<String, double> _screenShareVolumes = <String, double>{};

  RealtimeChannel? _presenceChannel;
  Object? _presenceSubscriptionToken;
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  VoidCallback? _roomChangeHandler;
  Future<String>? _liveKitTokenFuture;
  String? _warmedLiveKitToken;
  DateTime? _warmedLiveKitTokenAt;

  bool _initialized = false;
  bool _joined = false;
  bool _busy = false;
  bool _disposed = false;
  bool _detachingRoom = false;
  bool _muted = false;
  bool _deafened = false;
  ShareKind _shareKind = ShareKind.audio;
  String _status = 'Select Join Voice to connect.';

  List<VoiceParticipant> _participants = const <VoiceParticipant>[];
  List<VoiceParticipant> _presenceParticipants = const <VoiceParticipant>[];
  MediaStream? _localScreenRenderStream;

  bool get joined => _joined;
  bool get busy => _busy;
  bool get muted => _muted;
  bool get deafened => _deafened;
  ShareKind get shareKind => _shareKind;
  String get status => _status;
  RTCVideoRenderer get localRenderer => localCameraRenderer;
  bool get hasLocalPreview => localCameraRenderer.srcObject != null;
  bool get hasLocalCameraPreview => localCameraRenderer.srcObject != null;
  bool get hasLocalScreenPreview => localScreenRenderer.srcObject != null;
  bool get isCameraSharing =>
      _activeVisualPublication(
        _room?.localParticipant,
        lk.TrackSource.camera,
      ) !=
      null;
  bool get isScreenSharing =>
      _activeVisualPublication(
        _room?.localParticipant,
        lk.TrackSource.screenShareVideo,
      ) !=
      null;
  List<VoiceParticipant> get participants =>
      List<VoiceParticipant>.unmodifiable(_participants);
  List<VoiceParticipant> get presenceParticipants =>
      List<VoiceParticipant>.unmodifiable(_presenceParticipants);
  List<VoiceRemotePeer> get remotePeers {
    final peers = _peerStates.values.toList()
      ..sort(
        (left, right) => left.participant.displayName.toLowerCase().compareTo(
          right.participant.displayName.toLowerCase(),
        ),
      );
    return peers;
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await localCameraRenderer.initialize();
    await localScreenRenderer.initialize();
  }

  void prewarmJoin() {
    if (_disposed ||
        _joined ||
        AppBootstrap.liveKitUrl.trim().isEmpty ||
        AppBootstrap.liveKitTokenFunctionName.trim().isEmpty) {
      return;
    }
    unawaited(_resolveLiveKitToken());
  }

  Future<void> join() async {
    if (_joined || _busy) {
      return;
    }
    if (AppBootstrap.liveKitUrl.trim().isEmpty) {
      _status = 'LiveKit URL is missing. Set LIVEKIT_URL in dart defines.';
      _safeNotifyListeners();
      return;
    }

    _busy = true;
    _status = 'Joining voice channel...';
    _safeNotifyListeners();

    try {
      await initialize();
      final tokenFuture = _resolveLiveKitToken();
      final presenceFuture = _subscribePresenceChannel();

      final token = await tokenFuture;
      _clearWarmedLiveKitToken();
      final room = lk.Room(
        roomOptions: lk.RoomOptions(
          adaptiveStream: false,
          dynacast: false,
          defaultAudioCaptureOptions: _audioCaptureOptions(),
          defaultCameraCaptureOptions: _cameraCaptureOptions(),
          defaultVideoPublishOptions: _defaultVideoPublishOptions(),
        ),
      );
      await _attachRoom(room);
      await room.connect(AppBootstrap.liveKitUrl, token);
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _audioCaptureOptions(),
      );
      _room = room;
      _joined = true;
      _muted = false;
      _shareKind = ShareKind.audio;
      _status = 'Connected to voice channel.';
      await presenceFuture;
      await _trackPresence();
      await _syncRoomState();
      await soundEffects.play(
        UiSoundEffect.joinCall,
        enabled: preferences.playSounds,
      );
    } catch (error) {
      _clearWarmedLiveKitToken();
      await leave();
      _status = 'Unable to join voice channel: $error';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> leave() async {
    final wasJoined = _joined;
    _joined = false;
    _participants = const <VoiceParticipant>[];
    _presenceParticipants = const <VoiceParticipant>[];
    _status = 'Disconnected from voice channel.';

    await _closePresenceChannel();
    await _detachRoom();
    await _disposeRemotePeers();

    if (_localScreenRenderStream != null) {
      await _localScreenRenderStream!.dispose();
      _localScreenRenderStream = null;
    }
    localCameraRenderer.srcObject = null;
    localScreenRenderer.srcObject = null;
    _shareKind = ShareKind.audio;
    _muted = false;
    _deafened = false;

    if (wasJoined) {
      await soundEffects.play(
        UiSoundEffect.leaveCall,
        enabled: preferences.playSounds,
      );
    }
    _safeNotifyListeners();
  }

  Future<void> startCameraShare() async {
    if (!_joined || _busy) {
      return;
    }

    _busy = true;
    _status = 'Starting camera...';
    _safeNotifyListeners();

    try {
      final room = _room;
      final localParticipant = room?.localParticipant;
      if (localParticipant == null) {
        throw StateError('LiveKit room is not connected.');
      }
      await localParticipant.setCameraEnabled(
        true,
        cameraCaptureOptions: _cameraCaptureOptions(),
      );
      await _syncLocalPreview();
      await _syncRoomState();
      await _trackPresence();
      _status = isScreenSharing
          ? 'Camera and screen share live.'
          : 'Camera live in voice channel.';
    } catch (error) {
      _status = 'Unable to start camera: $error';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> startScreenShare(
    DesktopCapturerSource source, {
    int maxWidth = DesktopCaptureBridge.defaultScreenShareWidth,
    int maxHeight = DesktopCaptureBridge.defaultScreenShareHeight,
    int frameRate = 30,
    bool captureSystemAudio = false,
  }) async {
    if (!_joined || _busy) {
      return;
    }

    _busy = true;
    _status = 'Starting screen share...';
    _safeNotifyListeners();

    try {
      final room = _room;
      final localParticipant = room?.localParticipant;
      if (localParticipant == null) {
        throw StateError('LiveKit room is not connected.');
      }
      _applyScreenSharePublishOptions(
        width: maxWidth,
        height: maxHeight,
        frameRate: frameRate,
      );
      await localParticipant.setScreenShareEnabled(
        true,
        captureScreenAudio: true,
        screenShareCaptureOptions: lk.ScreenShareCaptureOptions(
          sourceId: source.id,
          maxFrameRate: frameRate.toDouble(),
          params: _screenShareVideoParameters(
            width: maxWidth,
            height: maxHeight,
            frameRate: frameRate,
          ),
        ),
      );
      await _syncLocalPreview();
      await _syncRoomState();
      await _trackPresence();
      _status = isCameraSharing
          ? 'Camera and screen share live with audio.'
          : 'Screen share live at ${maxHeight}p/${frameRate}fps with audio.';
    } catch (error) {
      _status = 'Unable to start screen share: $error';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> stopCameraShare() async {
    if (!_joined || _busy || !isCameraSharing) {
      return;
    }

    _busy = true;
    _status = 'Stopping camera...';
    _safeNotifyListeners();

    try {
      final localParticipant = _room?.localParticipant;
      if (localParticipant == null) {
        throw StateError('LiveKit room is not connected.');
      }
      await localParticipant.setCameraEnabled(false);
      await _syncLocalPreview();
      await _syncRoomState();
      await _trackPresence();
      _status = isScreenSharing
          ? 'Screen share still live.'
          : 'Voice-only mode active.';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> stopScreenShare() async {
    if (!_joined || _busy || !isScreenSharing) {
      return;
    }

    _busy = true;
    _status = 'Stopping screen share...';
    _safeNotifyListeners();

    try {
      final localParticipant = _room?.localParticipant;
      if (localParticipant == null) {
        throw StateError('LiveKit room is not connected.');
      }
      await localParticipant.setScreenShareEnabled(false);
      await _syncLocalPreview();
      await _syncRoomState();
      await _trackPresence();
      _status = isCameraSharing
          ? 'Camera still live.'
          : 'Voice-only mode active.';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> stopVisualShare() async {
    if (isScreenSharing) {
      await stopScreenShare();
    }
    if (isCameraSharing) {
      await stopCameraShare();
    }
  }

  Future<List<DesktopCapturerSource>> loadScreenShareSources() {
    return screenShareService.getScreenShareSources();
  }

  double participantVolume(String participantClientId) {
    final participantUserId = _participantUserId(participantClientId);
    if (participantUserId == null || participantUserId.isEmpty) {
      return _participantVolumes[participantClientId] ?? 1;
    }
    return _participantVolumes[participantUserId] ??
        preferences.speakerVolumeForUser(participantUserId);
  }

  double screenShareVolume(String participantClientId) {
    final participantUserId = _participantUserId(participantClientId);
    if (participantUserId == null || participantUserId.isEmpty) {
      return _screenShareVolumes[participantClientId] ?? 1;
    }
    return _screenShareVolumes[participantUserId] ??
        preferences.screenShareVolumeForUser(participantUserId);
  }

  bool isParticipantSpeaking(String participantClientId) {
    final participant = _participants.firstWhere(
      (item) => item.clientId == participantClientId,
      orElse: () => const VoiceParticipant(
        clientId: '',
        userId: '',
        displayName: '',
        isSelf: false,
        isMuted: true,
        shareKind: ShareKind.audio,
      ),
    );
    return participant.clientId.isNotEmpty && participant.isSpeaking;
  }

  bool isParticipantMutedLocally(String participantClientId) {
    return participantVolume(participantClientId) == 0;
  }

  String? _participantUserId(String participantClientId) {
    if (participantClientId == clientId) {
      return authService.userId;
    }
    final participant = _participants.firstWhere(
      (item) => item.clientId == participantClientId,
      orElse: () => const VoiceParticipant(
        clientId: '',
        userId: '',
        displayName: '',
        isSelf: false,
        isMuted: true,
        shareKind: ShareKind.audio,
      ),
    );
    if (participant.userId.isNotEmpty) {
      return participant.userId;
    }
    final peer = _peerStates[participantClientId];
    final peerUserId = peer?.participant.userId;
    if (peerUserId != null && peerUserId.isNotEmpty) {
      return peerUserId;
    }
    return null;
  }

  Future<void> toggleMute() async {
    final room = _room;
    final localParticipant = room?.localParticipant;
    if (localParticipant == null) {
      return;
    }

    final nextMuted = !_muted;
    _muted = nextMuted;
    _safeNotifyListeners();

    try {
      await localParticipant.setMicrophoneEnabled(
        !nextMuted,
        audioCaptureOptions: _audioCaptureOptions(),
      );
    } on Object {
      _muted = !nextMuted;
      rethrow;
    } finally {
      await _trackPresence();
      await _syncRoomState();
    }

    unawaited(
      soundEffects.play(
        nextMuted ? UiSoundEffect.mute : UiSoundEffect.unmute,
        enabled: preferences.playSounds,
      ),
    );
  }

  Future<void> toggleDeafen() async {
    _deafened = !_deafened;
    for (final peer in _peerStates.values) {
      await _applyPeerRendererVolume(peer);
    }
    await soundEffects.play(
      _deafened ? UiSoundEffect.deafen : UiSoundEffect.undeafen,
      enabled: preferences.playSounds,
    );
    _safeNotifyListeners();
  }

  Future<void> setParticipantVolume(
    String participantClientId,
    double volume,
  ) async {
    final normalized = volume.clamp(0.0, 2.0).toDouble();
    final participantUserId = _participantUserId(participantClientId);
    if (participantUserId == null || participantUserId.isEmpty) {
      _participantVolumes[participantClientId] = normalized;
    } else {
      _participantVolumes[participantUserId] = normalized;
      await preferences.setSpeakerVolumeForUser(participantUserId, normalized);
    }
    final peer = _peerStates[participantClientId];
    if (peer != null) {
      await _applyPeerRendererVolume(peer);
    }
    _safeNotifyListeners();
  }

  Future<void> setScreenShareVolume(
    String participantClientId,
    double volume,
  ) async {
    final normalized = volume.clamp(0.0, 2.0).toDouble();
    final participantUserId = _participantUserId(participantClientId);
    if (participantUserId == null || participantUserId.isEmpty) {
      _screenShareVolumes[participantClientId] = normalized;
    } else {
      _screenShareVolumes[participantUserId] = normalized;
      await preferences.setScreenShareVolumeForUser(
        participantUserId,
        normalized,
      );
    }
    final peer = _peerStates[participantClientId];
    if (peer != null && peer.screenRenderer.srcObject != null) {
      await _applyPeerRendererVolume(peer);
    }
    _safeNotifyListeners();
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    await leave();
    _disposed = true;
    await localCameraRenderer.dispose();
    await localScreenRenderer.dispose();
    super.dispose();
  }

  Future<void> refreshLocalParticipantProfile() async {
    _room?.localParticipant?.setName(authService.displayName);
    final metadata = _encodeParticipantMetadata();
    _room?.localParticipant?.setMetadata(metadata);
    if (_joined) {
      await _trackPresence();
      await _syncRoomState();
    } else {
      _safeNotifyListeners();
    }
  }

  lk.AudioCaptureOptions _audioCaptureOptions() => lk.AudioCaptureOptions(
    deviceId: preferences.preferredAudioInputId,
    noiseSuppression: preferences.noiseCancellation,
    echoCancellation: preferences.noiseCancellation,
    autoGainControl: false,
    stopAudioCaptureOnMute: false,
  );

  lk.CameraCaptureOptions _cameraCaptureOptions() => lk.CameraCaptureOptions(
    deviceId: preferences.preferredVideoInputId,
    maxFrameRate: 15,
    params: lk.VideoParametersPresets.h720_169,
  );

  lk.VideoPublishOptions _defaultVideoPublishOptions() =>
      _videoPublishOptionsForScreenShare(
        width: DesktopCaptureBridge.defaultScreenShareWidth,
        height: DesktopCaptureBridge.defaultScreenShareHeight,
        frameRate: DesktopCaptureBridge.defaultScreenShareFrameRate.toInt(),
      );

  void _applyScreenSharePublishOptions({
    required int width,
    required int height,
    required int frameRate,
  }) {
    final room = _room;
    if (room == null) {
      return;
    }
    room.engine.roomOptions = room.roomOptions.copyWith(
      defaultVideoPublishOptions: _videoPublishOptionsForScreenShare(
        width: width,
        height: height,
        frameRate: frameRate,
      ),
    );
  }

  lk.VideoPublishOptions _videoPublishOptionsForScreenShare({
    required int width,
    required int height,
    required int frameRate,
  }) {
    final parameters = _screenShareVideoParameters(
      width: width,
      height: height,
      frameRate: frameRate,
    );
    return lk.VideoPublishOptions(
      videoCodec: _preferredVideoCodec,
      screenShareEncoding: parameters.encoding,
      degradationPreference: lk.DegradationPreference.maintainResolution,
      backupVideoCodec: const lk.BackupVideoCodec(
        enabled: true,
        codec: _fallbackVideoCodec,
      ),
    );
  }

  lk.VideoParameters _screenShareVideoParameters({
    required int width,
    required int height,
    required int frameRate,
  }) {
    return lk.VideoParameters(
      dimensions: lk.VideoDimensions(width, height),
      encoding: lk.VideoEncoding(
        maxBitrate: _screenShareBitrate(
          width: width,
          height: height,
          frameRate: frameRate,
        ),
        maxFramerate: frameRate,
      ),
    );
  }

  int _screenShareBitrate({
    required int width,
    required int height,
    required int frameRate,
  }) {
    final pixels = width * height;
    final baseBitrate = switch (pixels) {
      <= 1280 * 720 => 2500 * 1000,
      <= 1920 * 1080 => 4000 * 1000,
      <= 2560 * 1440 => 6000 * 1000,
      _ => 8000 * 1000,
    };
    if (frameRate <= 30) {
      return baseBitrate;
    }
    return baseBitrate * 2;
  }

  Future<void> _subscribePresenceChannel() async {
    await _closePresenceChannel();
    final subscriptionToken = Object();
    _presenceSubscriptionToken = subscriptionToken;

    await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    final completer = Completer<void>();
    final realtimeChannel = client.channel(
      _presenceTopic(),
      opts: RealtimeChannelConfig(
        ack: true,
        enabled: true,
        key: clientId,
        private: true,
      ),
    );

    realtimeChannel
      ..onPresenceSync((_) => _syncPresenceState(realtimeChannel))
      ..onPresenceJoin((_) => _syncPresenceState(realtimeChannel))
      ..onPresenceLeave((_) => _syncPresenceState(realtimeChannel));

    realtimeChannel.subscribe((status, [error]) {
      if (_disposed || completer.isCompleted) {
        return;
      }
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          completer.complete();
        case RealtimeSubscribeStatus.channelError:
          completer.completeError(
            StateError('Realtime error${error == null ? '' : ': $error'}'),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(StateError('Realtime channel closed.'));
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(StateError('Realtime channel timed out.'));
      }
    });

    await completer.future;
    if (_disposed ||
        !identical(_presenceSubscriptionToken, subscriptionToken)) {
      await _disposePresenceChannel(realtimeChannel);
      return;
    }
    _presenceChannel = realtimeChannel;
    _syncPresenceState(realtimeChannel);
  }

  Future<void> _closePresenceChannel() async {
    _presenceSubscriptionToken = null;
    final presenceChannel = _presenceChannel;
    _presenceChannel = null;
    if (presenceChannel != null) {
      await _disposePresenceChannel(presenceChannel);
    }
  }

  Future<void> _disposePresenceChannel(RealtimeChannel presenceChannel) async {
    try {
      await presenceChannel.untrack();
    } on Object {
      // Best-effort cleanup. The channel may already be closing.
    }
    try {
      await client.removeChannel(presenceChannel);
    } on Object {
      // Channel teardown should not leave the controller in a broken state.
    }
  }

  String _presenceTopic() => 'voice:presence:${channel.id}';

  Future<void> _trackPresence() async {
    final presenceChannel = _presenceChannel;
    if (presenceChannel == null) {
      return;
    }
    try {
      await presenceChannel.untrack();
    } on Object {
      // Replacing presence should not fail if nothing is currently tracked.
    }
    await presenceChannel.track({
      'user_id': authService.userId,
      'display_name': authService.displayName,
      'muted': _muted,
      'share_kind': _shareKind.name,
      'joined_at': DateTime.now().toIso8601String(),
    });
  }

  void _syncPresenceState(RealtimeChannel realtimeChannel) {
    if (_disposed) {
      return;
    }

    final participants = <VoiceParticipant>[];
    for (final state in realtimeChannel.presenceState()) {
      for (final presence in state.presences) {
        final payload = presence.payload;
        final userId = payload['user_id'] as String?;
        if (userId == null || userId.isEmpty) {
          continue;
        }
        final displayName = payload['display_name'] as String? ?? 'Anonymous';
        final shareKind = _shareKindFromName(
          payload['share_kind'] as String? ?? ShareKind.audio.name,
        );
        participants.add(
          VoiceParticipant(
            clientId: state.key,
            userId: userId,
            displayName: displayName,
            isSelf: userId == authService.userId,
            isMuted: payload['muted'] as bool? ?? false,
            shareKind: shareKind,
          ),
        );
      }
    }

    participants.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
    _presenceParticipants = participants;
    _safeNotifyListeners();
  }

  Future<String> _fetchLiveKitToken() async {
    final response = await client.functions.invoke(
      AppBootstrap.liveKitTokenFunctionName,
      body: <String, dynamic>{'channelId': channel.id},
    );
    if (response.status >= 400) {
      throw StateError(
        'Unable to fetch LiveKit token (${response.status}): ${response.data}',
      );
    }

    final data = response.data;
    final payload = data is Map<String, dynamic>
        ? data
        : data is Map
        ? Map<String, dynamic>.from(data)
        : null;
    final token = payload?['token'] as String?;
    if (token == null || token.isEmpty) {
      throw StateError('LiveKit token response was missing a token.');
    }
    return token;
  }

  Future<String> _resolveLiveKitToken() {
    final cachedToken = _warmedLiveKitToken;
    final cachedAt = _warmedLiveKitTokenAt;
    if (cachedToken != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) <= _warmedTokenMaxAge) {
      return Future<String>.value(cachedToken);
    }

    final inFlightToken = _liveKitTokenFuture;
    if (inFlightToken != null) {
      return inFlightToken;
    }

    late final Future<String> tokenFuture;
    tokenFuture = _fetchLiveKitToken()
        .then((token) {
          if (!_disposed) {
            _warmedLiveKitToken = token;
            _warmedLiveKitTokenAt = DateTime.now();
          }
          return token;
        })
        .whenComplete(() {
          if (identical(_liveKitTokenFuture, tokenFuture)) {
            _liveKitTokenFuture = null;
          }
        });
    _liveKitTokenFuture = tokenFuture;
    return tokenFuture;
  }

  void _clearWarmedLiveKitToken() {
    _warmedLiveKitToken = null;
    _warmedLiveKitTokenAt = null;
  }

  Future<void> _attachRoom(lk.Room room) async {
    _roomChangeHandler = () {
      if (_disposed || _detachingRoom) {
        return;
      }
      unawaited(_syncRoomState());
    };
    room.addListener(_roomChangeHandler!);
    _roomListener = room.createListener()
      ..on<lk.RoomConnectedEvent>((_) {
        if (_disposed || _detachingRoom) {
          return;
        }
        _status = 'Connected to voice channel.';
        unawaited(_syncRoomState());
      })
      ..on<lk.RoomReconnectingEvent>((_) {
        if (_disposed || _detachingRoom) {
          return;
        }
        _status = 'Reconnecting voice channel...';
        _safeNotifyListeners();
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        if (_disposed || _detachingRoom) {
          return;
        }
        _status = 'Voice channel reconnected.';
        unawaited(_syncRoomState());
      })
      ..on<lk.RoomDisconnectedEvent>((event) {
        if (_disposed || _detachingRoom) {
          return;
        }
        _status = event.reason == null
            ? 'Disconnected from voice channel.'
            : 'Voice channel disconnected: ${event.reason}.';
        unawaited(_syncRoomState());
      })
      ..on<lk.ParticipantEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.ParticipantDisconnectedEvent>((event) {
        unawaited(_handleParticipantDisconnected(event.participant));
      })
      ..on<lk.TrackSubscribedEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.TrackUnsubscribedEvent>((event) {
        unawaited(_handleTrackRemoved(event.participant, event.publication));
      })
      ..on<lk.TrackUnpublishedEvent>((event) {
        unawaited(_handleTrackRemoved(event.participant, event.publication));
      })
      ..on<lk.TrackMutedEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.TrackUnmutedEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.LocalTrackPublishedEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.LocalTrackUnpublishedEvent>((_) {
        unawaited(_syncRoomState());
      });
  }

  Future<void> _detachRoom() async {
    final room = _room;
    final roomListener = _roomListener;
    final roomChangeHandler = _roomChangeHandler;
    _room = null;
    _roomListener = null;
    _roomChangeHandler = null;
    _detachingRoom = true;

    if (room != null && roomChangeHandler != null) {
      room.removeListener(roomChangeHandler);
    }
    if (room != null) {
      await room.disconnect();
    }
    await roomListener?.dispose();
    if (room != null) {
      await room.dispose();
    }
    _detachingRoom = false;
  }

  Future<void> _syncRoomState() async {
    if (_disposed || _detachingRoom) {
      return;
    }
    final room = _room;
    if (room == null) {
      _participants = const <VoiceParticipant>[];
      await _disposeRemotePeers();
      localCameraRenderer.srcObject = null;
      localScreenRenderer.srcObject = null;
      _safeNotifyListeners();
      return;
    }

    await _syncLocalPreview();

    final nextParticipants = <VoiceParticipant>[];
    final localParticipant = room.localParticipant;
    if (localParticipant != null) {
      final localVoiceParticipant = _voiceParticipantFromLkParticipant(
        localParticipant,
        isSelf: true,
      );
      _shareKind = localVoiceParticipant.shareKind;
      nextParticipants.add(localVoiceParticipant);
    } else {
      _shareKind = ShareKind.audio;
    }

    final remoteParticipants = room.remoteParticipants.values.toList()
      ..sort(
        (left, right) => _displayNameForParticipant(left)
            .toLowerCase()
            .compareTo(_displayNameForParticipant(right).toLowerCase()),
      );
    final activeRemoteIds = <String>{};
    for (final remoteParticipant in remoteParticipants) {
      final voiceParticipant = _voiceParticipantFromLkParticipant(
        remoteParticipant,
        isSelf: false,
      );
      nextParticipants.add(voiceParticipant);
      final peer = await _getOrCreatePeerState(voiceParticipant);
      peer.participant = voiceParticipant;
      activeRemoteIds.add(voiceParticipant.clientId);
      await _syncPeerMedia(peer, remoteParticipant);
    }

    final stalePeerIds = _peerStates.keys
        .where(
          (participantClientId) =>
              !activeRemoteIds.contains(participantClientId),
        )
        .toList();
    for (final peerId in stalePeerIds) {
      final peer = _peerStates.remove(peerId);
      if (peer != null) {
        await _disposePeer(peer);
      }
    }

    nextParticipants.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
    _participants = nextParticipants;
    _safeNotifyListeners();
  }

  Future<void> _syncLocalPreview() async {
    final localParticipant = _room?.localParticipant;
    final cameraTrack = _activeVisualPublication(
      localParticipant,
      lk.TrackSource.camera,
    )?.track;
    final screenTrack = _activeVisualPublication(
      localParticipant,
      lk.TrackSource.screenShareVideo,
    )?.track;
    final screenAudioTrack = _activeVisualPublication(
      localParticipant,
      lk.TrackSource.screenShareAudio,
    )?.track;
    final cameraStream = cameraTrack?.mediaStream;
    final screenStream = screenTrack?.mediaStream;
    final screenRenderStream = await _screenRenderStream(
      videoTrack: screenTrack,
      audioTrack: screenAudioTrack,
      previousCompositeStream: _localScreenRenderStream,
      label: 'local-screen-preview',
    );
    if (!identical(screenRenderStream, screenStream)) {
      if (_localScreenRenderStream != null &&
          !identical(_localScreenRenderStream, screenRenderStream)) {
        await _localScreenRenderStream!.dispose();
      }
      _localScreenRenderStream = identical(screenRenderStream, screenStream)
          ? null
          : screenRenderStream;
    }
    if (!identical(localCameraRenderer.srcObject, cameraStream)) {
      localCameraRenderer.srcObject = cameraStream;
    }
    if (!identical(localScreenRenderer.srcObject, screenRenderStream)) {
      localScreenRenderer.srcObject = screenRenderStream;
    }
  }

  Future<VoiceRemotePeer> _getOrCreatePeerState(
    VoiceParticipant participant,
  ) async {
    final existing = _peerStates[participant.clientId];
    if (existing != null) {
      return existing;
    }

    final cameraRenderer = RTCVideoRenderer();
    final screenRenderer = RTCVideoRenderer();
    await cameraRenderer.initialize();
    await screenRenderer.initialize();
    final peer = VoiceRemotePeer(
      participant: participant,
      cameraRenderer: cameraRenderer,
      screenRenderer: screenRenderer,
    );
    _peerStates[participant.clientId] = peer;
    return peer;
  }

  Future<void> _syncPeerMedia(
    VoiceRemotePeer peer,
    lk.RemoteParticipant participant,
  ) async {
    final cameraTrack = _activeVisualPublication(
      participant,
      lk.TrackSource.camera,
    )?.track;
    final screenTrack = _activeVisualPublication(
      participant,
      lk.TrackSource.screenShareVideo,
    )?.track;
    final screenAudioTrack = _activeVisualPublication(
      participant,
      lk.TrackSource.screenShareAudio,
    )?.track;
    final cameraStream = cameraTrack?.mediaStream;
    final screenStream = screenTrack?.mediaStream;
    final screenRenderStream = await _screenRenderStream(
      videoTrack: screenTrack,
      audioTrack: screenAudioTrack,
      previousCompositeStream: peer.screenRenderStream,
      label:
          'remote-screen-${participant.sid.isNotEmpty ? participant.sid : participant.identity}',
    );
    peer.cameraStream = cameraStream;
    peer.screenStream = screenRenderStream;
    if (!identical(peer.screenRenderStream, screenRenderStream)) {
      if (peer.screenRenderStream != null &&
          !identical(peer.screenRenderStream, screenRenderStream) &&
          !identical(peer.screenRenderStream, screenStream)) {
        await peer.screenRenderStream!.dispose();
      }
      peer.screenRenderStream = identical(screenRenderStream, screenStream)
          ? null
          : screenRenderStream;
    }
    if (!identical(peer.cameraRenderer.srcObject, cameraStream)) {
      peer.cameraRenderer.srcObject = cameraStream;
    }
    if (!identical(peer.screenRenderer.srcObject, screenRenderStream)) {
      peer.screenRenderer.srcObject = screenRenderStream;
    }
    await _applyPeerRendererVolume(peer);
  }

  Future<void> _applyPeerRendererVolume(VoiceRemotePeer peer) async {
    final targetVolume = _deafened
        ? 0.0
        : participantVolume(peer.participant.clientId);
    final screenTargetVolume = _deafened
        ? 0.0
        : screenShareVolume(peer.participant.clientId);
    if (peer.cameraRenderer.srcObject != null) {
      await peer.cameraRenderer.setVolume(targetVolume);
    }
    if (peer.screenRenderer.srcObject != null) {
      await peer.screenRenderer.setVolume(screenTargetVolume);
    }
  }

  Future<void> _disposePeer(VoiceRemotePeer peer) async {
    peer.cameraStream = null;
    peer.screenStream = null;
    if (peer.screenRenderStream != null) {
      await peer.screenRenderStream!.dispose();
      peer.screenRenderStream = null;
    }
    peer.cameraRenderer.srcObject = null;
    peer.screenRenderer.srcObject = null;
    await peer.cameraRenderer.dispose();
    await peer.screenRenderer.dispose();
  }

  Future<void> _disposeRemotePeers() async {
    final peers = _peerStates.values.toList();
    _peerStates.clear();
    for (final peer in peers) {
      await _disposePeer(peer);
    }
  }

  VoiceParticipant _voiceParticipantFromLkParticipant(
    lk.Participant participant, {
    required bool isSelf,
  }) {
    final metadata = _decodeParticipantMetadata(participant.metadata);
    final displayName = _displayNameForParticipant(participant);
    final userId =
        metadata?['user_id'] as String? ??
        (participant.identity.isNotEmpty
            ? participant.identity
            : participant.sid);

    return VoiceParticipant(
      clientId: participant.sid.isNotEmpty
          ? participant.sid
          : participant.identity,
      userId: userId,
      displayName: displayName,
      isSelf: isSelf,
      isMuted: isSelf ? _muted : participant.isMuted,
      shareKind: _shareKindForParticipant(participant),
      isSpeaking: !participant.isMuted && participant.isSpeaking,
    );
  }

  ShareKind _shareKindForParticipant(lk.Participant participant) {
    final hasScreen =
        _activeVisualPublication(
          participant,
          lk.TrackSource.screenShareVideo,
        ) !=
        null;
    if (hasScreen) {
      return ShareKind.screen;
    }

    final hasCamera =
        _activeVisualPublication(participant, lk.TrackSource.camera) != null;
    if (hasCamera) {
      return ShareKind.camera;
    }

    return ShareKind.audio;
  }

  ShareKind _shareKindFromName(String value) {
    switch (value) {
      case 'camera':
        return ShareKind.camera;
      case 'screen':
        return ShareKind.screen;
      default:
        return ShareKind.audio;
    }
  }

  Future<MediaStream?> _screenRenderStream({
    required lk.Track? videoTrack,
    required lk.Track? audioTrack,
    required MediaStream? previousCompositeStream,
    required String label,
  }) async {
    final baseStream = videoTrack?.mediaStream;
    if (videoTrack == null || baseStream == null) {
      return null;
    }

    final baseAudioTracks = baseStream.getAudioTracks();
    if (audioTrack == null ||
        identical(audioTrack.mediaStream, baseStream) ||
        baseAudioTracks.any(
          (track) => track.id == audioTrack.mediaStreamTrack.id,
        )) {
      return baseStream;
    }

    if (previousCompositeStream != null) {
      final sameVideo = previousCompositeStream.getVideoTracks().any(
        (track) => track.id == videoTrack.mediaStreamTrack.id,
      );
      final sameAudio = previousCompositeStream.getAudioTracks().any(
        (track) => track.id == audioTrack.mediaStreamTrack.id,
      );
      if (sameVideo && sameAudio) {
        return previousCompositeStream;
      }
    }

    final compositeStream = await createLocalMediaStream(label);
    await compositeStream.addTrack(videoTrack.mediaStreamTrack);
    await compositeStream.addTrack(audioTrack.mediaStreamTrack);
    return compositeStream;
  }

  lk.TrackPublication<lk.Track>? _activeVisualPublication(
    lk.Participant? participant,
    lk.TrackSource source,
  ) {
    if (participant == null) {
      return null;
    }
    final publication = participant.getTrackPublicationBySource(source);
    if (publication == null || publication.track == null || publication.muted) {
      return null;
    }
    return publication;
  }

  Future<void> _handleParticipantDisconnected(
    lk.RemoteParticipant participant,
  ) async {
    final peer = _peerStates.remove(
      participant.sid.isNotEmpty ? participant.sid : participant.identity,
    );
    if (peer != null) {
      await _disposePeer(peer);
    }
    await _syncRoomState();
  }

  Future<void> _handleTrackRemoved(
    lk.RemoteParticipant participant,
    lk.TrackPublication<lk.Track> publication,
  ) async {
    if (publication.source == lk.TrackSource.camera ||
        publication.source == lk.TrackSource.screenShareVideo ||
        publication.source == lk.TrackSource.screenShareAudio) {
      final peer =
          _peerStates[participant.sid.isNotEmpty
              ? participant.sid
              : participant.identity];
      if (peer != null) {
        if (publication.source == lk.TrackSource.camera) {
          peer.cameraStream = null;
          peer.cameraRenderer.srcObject = null;
        } else {
          peer.screenStream = null;
          if (peer.screenRenderStream != null) {
            await peer.screenRenderStream!.dispose();
            peer.screenRenderStream = null;
          }
          peer.screenRenderer.srcObject = null;
        }
      }
    }
    await _syncRoomState();
  }

  Map<String, dynamic>? _decodeParticipantMetadata(String? metadata) {
    if (metadata == null || metadata.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(metadata);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String _displayNameForParticipant(lk.Participant participant) {
    final name = participant.name.trim();
    if (name.isNotEmpty) {
      return name;
    }
    final metadata = _decodeParticipantMetadata(participant.metadata);
    final metadataName = metadata?['display_name'] as String?;
    if (metadataName != null && metadataName.trim().isNotEmpty) {
      return metadataName.trim();
    }
    if (participant.identity.isNotEmpty) {
      return participant.identity;
    }
    return 'Anonymous';
  }

  String _encodeParticipantMetadata() {
    return jsonEncode({
      'user_id': authService.userId,
      'display_name': authService.displayName,
      'channel_id': channel.id,
    });
  }
}
