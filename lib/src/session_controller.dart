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
  VoiceRemotePeer({required this.participant, required this.renderer});

  VoiceParticipant participant;
  final RTCVideoRenderer renderer;
  MediaStream? remoteStream;

  bool get hasMedia => renderer.srcObject != null;
}

class VoiceChannelSessionController extends ChangeNotifier {
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

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final Map<String, VoiceRemotePeer> _peerStates = <String, VoiceRemotePeer>{};
  final Map<String, double> _participantVolumes = <String, double>{};

  RealtimeChannel? _presenceChannel;
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  VoidCallback? _roomChangeHandler;

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

  bool get joined => _joined;
  bool get busy => _busy;
  bool get muted => _muted;
  bool get deafened => _deafened;
  ShareKind get shareKind => _shareKind;
  String get status => _status;
  bool get hasLocalPreview => localRenderer.srcObject != null;
  List<VoiceParticipant> get participants =>
      List<VoiceParticipant>.unmodifiable(_participants);
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
    await localRenderer.initialize();
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
      await _subscribePresenceChannel();

      final token = await _fetchLiveKitToken();
      final room = lk.Room(
        roomOptions: lk.RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: _audioCaptureOptions(),
          defaultCameraCaptureOptions: _cameraCaptureOptions(),
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
      await _trackPresence();
      await _syncRoomState();
      await soundEffects.play(
        UiSoundEffect.joinCall,
        enabled: preferences.playSounds,
      );
    } catch (error) {
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
    _status = 'Disconnected from voice channel.';

    await _detachRoom();
    await _closePresenceChannel();
    await _disposeRemotePeers();

    localRenderer.srcObject = null;
    _shareKind = ShareKind.audio;
    _muted = false;
    _deafened = false;
    _participantVolumes.clear();

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
      await localParticipant.setScreenShareEnabled(false);
      await localParticipant.setCameraEnabled(
        true,
        cameraCaptureOptions: _cameraCaptureOptions(),
      );
      _shareKind = ShareKind.camera;
      await _syncLocalPreview();
      await _trackPresence();
      await _syncRoomState();
      _status = 'Camera live in voice channel.';
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
      await localParticipant.setCameraEnabled(false);
      await localParticipant.setScreenShareEnabled(
        true,
        captureScreenAudio: captureSystemAudio,
        screenShareCaptureOptions: lk.ScreenShareCaptureOptions(
          sourceId: source.id,
          maxFrameRate: frameRate.toDouble(),
          params: maxHeight >= 1080 && maxWidth >= 1920
              ? lk.VideoParametersPresets.screenShareH1080FPS15
              : lk.VideoParametersPresets.h720_169,
        ),
      );
      _shareKind = ShareKind.screen;
      await _syncLocalPreview();
      await _trackPresence();
      await _syncRoomState();
      _status =
          'Screen share live at ${maxHeight}p/${frameRate}fps${captureSystemAudio ? ' with audio' : ''}.';
    } catch (error) {
      _status = 'Unable to start screen share: $error';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<void> stopVisualShare() async {
    if (!_joined || _busy || _shareKind == ShareKind.audio) {
      return;
    }

    _busy = true;
    _status = 'Stopping visual share...';
    _safeNotifyListeners();

    try {
      final localParticipant = _room?.localParticipant;
      if (localParticipant == null) {
        throw StateError('LiveKit room is not connected.');
      }
      await localParticipant.setCameraEnabled(false);
      await localParticipant.setScreenShareEnabled(false);
      _shareKind = ShareKind.audio;
      await _syncLocalPreview();
      await _trackPresence();
      await _syncRoomState();
      _status = 'Voice-only mode active.';
    } finally {
      _busy = false;
      _safeNotifyListeners();
    }
  }

  Future<List<DesktopCapturerSource>> loadScreenShareSources() {
    return screenShareService.getScreenShareSources();
  }

  double participantVolume(String participantClientId) {
    return _participantVolumes[participantClientId] ?? 1;
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
    _participantVolumes[participantClientId] = normalized;
    final peer = _peerStates[participantClientId];
    if (peer != null) {
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
    await localRenderer.dispose();
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

  Future<void> _subscribePresenceChannel() async {
    await _closePresenceChannel();

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
    _presenceChannel = realtimeChannel;
  }

  Future<void> _closePresenceChannel() async {
    final presenceChannel = _presenceChannel;
    _presenceChannel = null;
    if (presenceChannel != null) {
      try {
        await presenceChannel.untrack();
      } on Object {
        // Best-effort cleanup. The channel may already be closing.
      }
      await client.removeChannel(presenceChannel);
    }
  }

  String _presenceTopic() => 'voice:presence:${channel.id}';

  Future<void> _trackPresence() async {
    await _presenceChannel?.track({
      'user_id': authService.userId,
      'display_name': authService.displayName,
      'muted': _muted,
      'share_kind': _shareKind.name,
      'joined_at': DateTime.now().toIso8601String(),
    });
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
      ..on<lk.TrackSubscribedEvent>((_) {
        unawaited(_syncRoomState());
      })
      ..on<lk.TrackUnsubscribedEvent>((_) {
        unawaited(_syncRoomState());
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
      localRenderer.srcObject = null;
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
        (left, right) => _displayNameForParticipant(left).toLowerCase().compareTo(
          _displayNameForParticipant(right).toLowerCase(),
        ),
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
        .where((participantClientId) => !activeRemoteIds.contains(participantClientId))
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
    final localTrack =
        _preferredVideoTrack(localParticipant) ?? _preferredVisualTrack(localParticipant);
    final stream = localTrack?.mediaStream;
    if (!identical(localRenderer.srcObject, stream)) {
      localRenderer.srcObject = stream;
    }
  }

  Future<VoiceRemotePeer> _getOrCreatePeerState(
    VoiceParticipant participant,
  ) async {
    final existing = _peerStates[participant.clientId];
    if (existing != null) {
      return existing;
    }

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final peer = VoiceRemotePeer(participant: participant, renderer: renderer);
    _peerStates[participant.clientId] = peer;
    return peer;
  }

  Future<void> _syncPeerMedia(
    VoiceRemotePeer peer,
    lk.RemoteParticipant participant,
  ) async {
    final track =
        _preferredVisualTrack(participant) ?? _preferredAudioTrack(participant);
    final stream = track?.mediaStream;
    peer.remoteStream = stream;
    if (!identical(peer.renderer.srcObject, stream)) {
      peer.renderer.srcObject = stream;
    }
    await _applyPeerRendererVolume(peer);
  }

  Future<void> _applyPeerRendererVolume(VoiceRemotePeer peer) async {
    if (peer.renderer.srcObject == null) {
      return;
    }
    await peer.renderer.setVolume(
      _deafened ? 0.0 : participantVolume(peer.participant.clientId),
    );
  }

  Future<void> _disposePeer(VoiceRemotePeer peer) async {
    peer.remoteStream = null;
    peer.renderer.srcObject = null;
    await peer.renderer.dispose();
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
        (participant.identity.isNotEmpty ? participant.identity : participant.sid);

    return VoiceParticipant(
      clientId: participant.sid.isNotEmpty ? participant.sid : participant.identity,
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
        participant.getTrackPublicationBySource(lk.TrackSource.screenShareVideo)
            ?.track !=
        null;
    if (hasScreen) {
      return ShareKind.screen;
    }

    final hasCamera =
        participant.getTrackPublicationBySource(lk.TrackSource.camera)?.track !=
        null;
    if (hasCamera) {
      return ShareKind.camera;
    }

    return ShareKind.audio;
  }

  lk.Track? _preferredVisualTrack(lk.Participant? participant) {
    if (participant == null) {
      return null;
    }
    return participant
            .getTrackPublicationBySource(lk.TrackSource.screenShareVideo)
            ?.track ??
        participant.getTrackPublicationBySource(lk.TrackSource.camera)?.track;
  }

  lk.LocalVideoTrack? _preferredVideoTrack(lk.LocalParticipant? participant) {
    final track = _preferredVisualTrack(participant);
    return track is lk.LocalVideoTrack ? track : null;
  }

  lk.Track? _preferredAudioTrack(lk.Participant? participant) {
    if (participant == null) {
      return null;
    }
    return participant
        .getTrackPublicationBySource(lk.TrackSource.microphone)
        ?.track;
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
