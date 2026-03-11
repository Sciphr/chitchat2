import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'desktop_capture_bridge.dart';
import 'app_preferences.dart';
import 'models.dart';
import 'repositories.dart';
import 'ui_sound_effects.dart';

class ScreenShareService {
  final DesktopCaptureBridge _desktopCaptureBridge = DesktopCaptureBridge();

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

  Future<MediaStream> openMicrophone() {
    return openConfiguredMicrophone();
  }

  Future<MediaStream> openCameraVideo() {
    return openConfiguredCamera();
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

  Future<MediaStream> openDesktopSource(
    DesktopCapturerSource source, {
    int maxWidth = DesktopCaptureBridge.defaultScreenShareWidth,
    int maxHeight = DesktopCaptureBridge.defaultScreenShareHeight,
    int frameRate = 30,
    bool captureSystemAudio = false,
  }) {
    return _desktopCaptureBridge.getScreenShareStream(
      source,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      frameRate: frameRate.toDouble(),
      captureSystemAudio: captureSystemAudio,
    );
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

enum _VoiceSignalScope { base, camera, screen }

class VoiceRemotePeer {
  VoiceRemotePeer({required this.participant, required this.renderer});

  VoiceParticipant participant;
  final RTCVideoRenderer renderer;
  RTCPeerConnection? connection;
  MediaStream? remoteStream;
  String? sessionId;
  _VoiceSignalScope _signalScope = _VoiceSignalScope.base;

  bool get hasMedia => renderer.srcObject != null;
}

class _AudioEnergySample {
  const _AudioEnergySample({
    required this.totalAudioEnergy,
    required this.totalSamplesDuration,
  });

  final double totalAudioEnergy;
  final double totalSamplesDuration;
}

class VoiceChannelSessionController extends ChangeNotifier {
  VoiceChannelSessionController({
    required this.channel,
    required this.client,
    required this.authService,
    required this.preferences,
    required this.screenShareService,
    required this.soundEffects,
  }) : clientId = const Uuid().v4();

  final ChannelSummary channel;
  final SupabaseClient client;
  final AuthService authService;
  final AppPreferences preferences;
  final ScreenShareService screenShareService;
  final UiSoundEffects soundEffects;
  final String clientId;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final Map<String, VoiceRemotePeer> _peerStates = <String, VoiceRemotePeer>{};
  final Map<String, List<RTCIceCandidate>> _queuedCandidatesByPeer =
      <String, List<RTCIceCandidate>>{};
  final Map<String, RealtimeChannel> _outboundChannels =
      <String, RealtimeChannel>{};

  RealtimeChannel? _presenceChannel;
  RealtimeChannel? _baseInboxChannel;
  RealtimeChannel? _cameraInboxChannel;
  RealtimeChannel? _screenInboxChannel;
  MediaStream? _microphoneStream;
  MediaStream? _videoSourceStream;
  MediaStream? _localCompositeStream;
  bool _initialized = false;
  bool _joined = false;
  bool _busy = false;
  bool _disposed = false;
  bool _muted = false;
  bool _deafened = false;
  ShareKind _shareKind = ShareKind.audio;
  String _status = 'Select Join Voice to connect.';
  Timer? _speakingPollTimer;

  List<VoiceParticipant> _participants = const <VoiceParticipant>[];
  final Map<String, double> _participantVolumes = <String, double>{};
  final Map<String, bool> _speakingStates = <String, bool>{};
  final Map<String, DateTime> _lastSpeakingAt = <String, DateTime>{};
  final Map<String, _AudioEnergySample> _lastAudioSamples =
      <String, _AudioEnergySample>{};

  static const Duration _speakingPollInterval = Duration(milliseconds: 120);
  static const Duration _speakingHoldDuration = Duration(milliseconds: 520);
  double get _speakingThreshold =>
      0.065 / preferences.inputSensitivity.clamp(0.5, 2.0);

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

    _busy = true;
    _status = 'Joining voice channel...';
    notifyListeners();

    try {
      await initialize();
      final microphoneFuture = screenShareService.openConfiguredMicrophone(
        deviceId: preferences.preferredAudioInputId,
        noiseCancellation: preferences.noiseCancellation,
      );
      final presenceChannelFuture = _subscribeRealtimeChannel(
        topic: _presenceTopic(),
        scope: null,
        listenPresence: true,
      );
      final baseInboxChannelFuture = _subscribeRealtimeChannel(
        topic: _signalTopic(_VoiceSignalScope.base, authService.userId),
        scope: _VoiceSignalScope.base,
        listenPresence: false,
      );
      final cameraInboxChannelFuture = _subscribeRealtimeChannel(
        topic: _signalTopic(_VoiceSignalScope.camera, authService.userId),
        scope: _VoiceSignalScope.camera,
        listenPresence: false,
      );
      final screenInboxChannelFuture = _subscribeRealtimeChannel(
        topic: _signalTopic(_VoiceSignalScope.screen, authService.userId),
        scope: _VoiceSignalScope.screen,
        listenPresence: false,
      );

      _microphoneStream = await microphoneFuture;
      await _rebuildLocalCompositeStream();
      final subscribedChannels = await Future.wait<RealtimeChannel>([
        presenceChannelFuture,
        baseInboxChannelFuture,
        cameraInboxChannelFuture,
        screenInboxChannelFuture,
      ]);
      _presenceChannel = subscribedChannels[0];
      _baseInboxChannel = subscribedChannels[1];
      _cameraInboxChannel = subscribedChannels[2];
      _screenInboxChannel = subscribedChannels[3];

      _joined = true;
      await _trackPresence();
      _status = 'Connected to voice channel.';
      await _syncParticipants();
      _startSpeakingMonitor();
      await soundEffects.play(
        UiSoundEffect.joinCall,
        enabled: preferences.playSounds,
      );
    } catch (error) {
      await leave();
      _status = 'Unable to join voice channel: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    final wasJoined = _joined;
    _joined = false;
    _participants = const <VoiceParticipant>[];
    _status = 'Disconnected from voice channel.';
    _stopSpeakingMonitor();
    _speakingStates.clear();
    _lastSpeakingAt.clear();
    _lastAudioSamples.clear();

    for (final peer in _peerStates.values) {
      await _disposePeer(peer);
    }
    _peerStates.clear();
    _queuedCandidatesByPeer.clear();

    for (final outboundChannel in _outboundChannels.values) {
      await client.removeChannel(outboundChannel);
    }
    _outboundChannels.clear();

    final inboundChannels = [
      _presenceChannel,
      _baseInboxChannel,
      _cameraInboxChannel,
      _screenInboxChannel,
    ].whereType<RealtimeChannel>().toList();
    _presenceChannel = null;
    _baseInboxChannel = null;
    _cameraInboxChannel = null;
    _screenInboxChannel = null;
    for (final inboundChannel in inboundChannels) {
      await client.removeChannel(inboundChannel);
    }

    final streamsToDispose = <String, MediaStream>{};
    for (final stream in [
      _videoSourceStream,
      _localCompositeStream,
      _microphoneStream,
    ]) {
      if (stream != null) {
        streamsToDispose[stream.id] = stream;
      }
    }
    _videoSourceStream = null;
    _localCompositeStream = null;
    _microphoneStream = null;
    for (final stream in streamsToDispose.values) {
      await screenShareService.stopStream(stream);
    }
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
    notifyListeners();
  }

  Future<void> startCameraShare() async {
    if (!_joined || _busy) {
      return;
    }

    _busy = true;
    _status = 'Starting camera...';
    notifyListeners();

    try {
      await screenShareService.stopStream(_videoSourceStream);
      _videoSourceStream = await screenShareService.openConfiguredCamera(
        deviceId: preferences.preferredVideoInputId,
      );
      _shareKind = ShareKind.camera;
      localRenderer.srcObject = _videoSourceStream;
      await _rebuildLocalCompositeStream();
      await _trackPresence();
      await _reconnectAllPeers(forceOfferAll: true);
      _status = 'Camera live in voice channel.';
    } catch (error) {
      _status = 'Unable to start camera: $error';
    } finally {
      _busy = false;
      notifyListeners();
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
    notifyListeners();

    try {
      await screenShareService.stopStream(_videoSourceStream);
      _videoSourceStream = await screenShareService.openDesktopSource(
        source,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        frameRate: frameRate,
        captureSystemAudio: captureSystemAudio,
      );
      _shareKind = ShareKind.screen;
      localRenderer.srcObject = _videoSourceStream;
      await _rebuildLocalCompositeStream();
      await _trackPresence();
      await _reconnectAllPeers(forceOfferAll: true);
      _status =
          'Screen share live at ${maxHeight}p/${frameRate}fps${captureSystemAudio ? ' with audio' : ''}.';
    } catch (error) {
      _status = 'Unable to start screen share: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stopVisualShare() async {
    if (!_joined || _busy || _shareKind == ShareKind.audio) {
      return;
    }

    _busy = true;
    _status = 'Stopping visual share...';
    notifyListeners();

    try {
      await screenShareService.stopStream(_videoSourceStream);
      _videoSourceStream = null;
      localRenderer.srcObject = null;
      _shareKind = ShareKind.audio;
      await _rebuildLocalCompositeStream();
      await _trackPresence();
      await _reconnectAllPeers(forceOfferAll: true);
      _status = 'Voice-only mode active.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<DesktopCapturerSource>> loadScreenShareSources() {
    return screenShareService.getScreenShareSources();
  }

  double participantVolume(String participantClientId) {
    return _participantVolumes[participantClientId] ?? 1;
  }

  bool isParticipantSpeaking(String participantClientId) {
    return _speakingStates[participantClientId] ?? false;
  }

  bool isParticipantMutedLocally(String participantClientId) {
    return participantVolume(participantClientId) == 0;
  }

  Future<void> toggleMute() async {
    final nextMuted = !_muted;
    final microphoneStream = _microphoneStream;
    _muted = nextMuted;
    if (microphoneStream != null) {
      for (final track in microphoneStream.getAudioTracks()) {
        track.enabled = !nextMuted;
      }
    }
    notifyListeners();

    if (microphoneStream != null) {
      for (final track in microphoneStream.getAudioTracks()) {
        try {
          await Helper.setMicrophoneMute(nextMuted, track);
        } on MissingPluginException {
          // Some desktop builds do not expose this method; track.enabled is enough.
        } on PlatformException {
          // Fallback to the already-updated track.enabled state.
        }
      }
    }
    if (_joined) {
      unawaited(_trackPresence());
    }
    _speakingStates[clientId] = false;
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
    notifyListeners();
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
    notifyListeners();
  }

  Future<RealtimeChannel> _subscribeRealtimeChannel({
    required String topic,
    required _VoiceSignalScope? scope,
    required bool listenPresence,
  }) async {
    await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    final completer = Completer<void>();
    final realtimeChannel = client.channel(
      topic,
      opts: RealtimeChannelConfig(
        ack: true,
        enabled: true,
        key: clientId,
        private: true,
      ),
    );

    if (scope != null) {
      realtimeChannel.onBroadcast(
        event: 'webrtc-signal',
        callback: (payload) {
          unawaited(_handleBroadcast(payload, scope));
        },
      );
    }

    if (listenPresence) {
      realtimeChannel
        ..onPresenceSync((_) => unawaited(_syncParticipants()))
        ..onPresenceJoin((_) => unawaited(_syncParticipants()))
        ..onPresenceLeave((_) => unawaited(_syncParticipants()));
    }

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
    return realtimeChannel;
  }

  String _presenceTopic() => 'voice:presence:${channel.id}';

  String _signalTopic(_VoiceSignalScope scope, String targetUserId) {
    return 'voice:${scope.name}:${channel.id}:$targetUserId';
  }

  Future<void> _trackPresence() async {
    await _presenceChannel?.track({
      'user_id': authService.userId,
      'display_name': authService.displayName,
      'muted': _muted,
      'share_kind': _shareKind.name,
      'joined_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _syncParticipants() async {
    final realtimeChannel = _presenceChannel;
    if (realtimeChannel == null) {
      return;
    }

    final nextParticipants = <VoiceParticipant>[];
    for (final state in realtimeChannel.presenceState()) {
      for (final presence in state.presences) {
        final payload = presence.payload;
        final userId = payload['user_id'] as String?;
        if (userId == null || userId.isEmpty) {
          continue;
        }
        final shareName =
            payload['share_kind'] as String? ?? ShareKind.audio.name;
        nextParticipants.add(
          VoiceParticipant(
            clientId: state.key,
            userId: userId,
            displayName: payload['display_name'] as String? ?? 'Anonymous',
            isSelf: state.key == clientId,
            isMuted: payload['muted'] as bool? ?? false,
            shareKind: _shareKindFromName(shareName),
            isSpeaking: isParticipantSpeaking(state.key),
          ),
        );
      }
    }

    final hasSelfParticipant = nextParticipants.any(
      (participant) => participant.clientId == clientId || participant.isSelf,
    );
    if (_joined && !hasSelfParticipant) {
      nextParticipants.add(
        VoiceParticipant(
          clientId: clientId,
          userId: authService.userId,
          displayName: authService.displayName,
          isSelf: true,
          isMuted: _muted,
          shareKind: _shareKind,
          isSpeaking: isParticipantSpeaking(clientId),
        ),
      );
    }

    nextParticipants.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );
    _participants = nextParticipants;

    final activeRemoteIds = nextParticipants
        .where((participant) => !participant.isSelf)
        .map((participant) => participant.clientId)
        .toSet();

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

    for (final participant in nextParticipants.where((item) => !item.isSelf)) {
      final peer = await _getOrCreatePeerState(participant);
      peer.participant = participant;
      final shouldOffer =
          _joined &&
          peer.connection == null &&
          clientId.compareTo(participant.clientId) < 0;
      if (shouldOffer) {
        await _connectPeer(peer, offerImmediately: true);
      }
    }

    notifyListeners();
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

  Future<void> _connectPeer(
    VoiceRemotePeer peer, {
    required bool offerImmediately,
  }) async {
    peer.connection ??= await _createPeerConnection(peer);

    if (!offerImmediately) {
      return;
    }

    peer.sessionId = const Uuid().v4();
    peer._signalScope = _signalScopeForShareKind(_shareKind);
    final offer = await peer.connection!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await peer.connection!.setLocalDescription(offer);
    await _sendSignal(
      _VoiceSignalEnvelope.offer(
        channelId: channel.id,
        sessionId: peer.sessionId!,
        fromClientId: clientId,
        fromUserId: authService.userId,
        fromDisplayName: authService.displayName,
        targetUserId: peer.participant.userId,
        targetClientId: peer.participant.clientId,
        shareKind: _shareKind,
        scope: peer._signalScope,
        description: offer,
      ),
    );
  }

  Future<RTCPeerConnection> _createPeerConnection(VoiceRemotePeer peer) async {
    final connection = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        {
          'urls': ['stun:stun.l.google.com:19302'],
        },
      ],
    });

    final stream = _localCompositeStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await connection.addTrack(track, stream);
      }
    }

    connection.onIceCandidate = (candidate) {
      final candidateValue = candidate.candidate;
      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }
      final sessionId = peer.sessionId;
      if (sessionId == null) {
        return;
      }
      unawaited(
        _sendSignalSafely(
          _VoiceSignalEnvelope.iceCandidate(
            channelId: channel.id,
            sessionId: sessionId,
            fromClientId: clientId,
            fromUserId: authService.userId,
            fromDisplayName: authService.displayName,
            targetUserId: peer.participant.userId,
            targetClientId: peer.participant.clientId,
            shareKind: _shareKind,
            scope: peer._signalScope,
            candidate: candidate,
          ),
          context: 'ice candidate',
        ),
      );
    };

    connection.onTrack = (event) {
      unawaited(_attachRemoteTrack(peer, event));
    };

    connection.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _status = 'Voice channel connected.';
          notifyListeners();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          unawaited(_resetPeer(peer, keepRenderer: true));
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          break;
      }
    };

    return connection;
  }

  Future<void> _handleBroadcast(
    Map<String, dynamic> payload,
    _VoiceSignalScope inboundScope,
  ) async {
    final envelope = _VoiceSignalEnvelope.tryParse(payload);
    if (envelope == null ||
        envelope.channelId != channel.id ||
        envelope.scope != inboundScope ||
        envelope.fromClientId == clientId ||
        envelope.targetUserId != authService.userId ||
        envelope.targetClientId != clientId) {
      return;
    }

    if (inboundScope == _VoiceSignalScope.base &&
        envelope.type == _VoiceSignalType.offer &&
        envelope.shareKind != ShareKind.audio) {
      return;
    }

    final participant = _participants.firstWhere(
      (item) => item.clientId == envelope.fromClientId,
      orElse: () => VoiceParticipant(
        clientId: envelope.fromClientId,
        userId: envelope.fromUserId,
        displayName: envelope.fromDisplayName,
        isSelf: false,
        isMuted: false,
        shareKind: envelope.shareKind,
        isSpeaking: isParticipantSpeaking(envelope.fromClientId),
      ),
    );

    final peer = await _getOrCreatePeerState(participant);

    switch (envelope.type) {
      case _VoiceSignalType.offer:
        await _handleOffer(peer, envelope);
      case _VoiceSignalType.answer:
        await _handleAnswer(peer, envelope);
      case _VoiceSignalType.iceCandidate:
        await _handleIceCandidate(peer, envelope);
      case _VoiceSignalType.hangup:
        await _resetPeer(peer, keepRenderer: true);
    }
  }

  Future<void> _handleOffer(
    VoiceRemotePeer peer,
    _VoiceSignalEnvelope envelope,
  ) async {
    await _resetPeer(peer, keepRenderer: true);
    peer.participant = VoiceParticipant(
      clientId: envelope.fromClientId,
      userId: envelope.fromUserId,
      displayName: envelope.fromDisplayName,
      isSelf: false,
      isMuted: false,
      shareKind: envelope.shareKind,
      isSpeaking: isParticipantSpeaking(envelope.fromClientId),
    );
    peer.sessionId = envelope.sessionId;
    peer._signalScope = envelope.scope;
    peer.connection = await _createPeerConnection(peer);

    final description = envelope.description;
    if (description == null) {
      return;
    }

    await peer.connection!.setRemoteDescription(description);
    final answer = await peer.connection!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await peer.connection!.setLocalDescription(answer);

    await _sendSignal(
      _VoiceSignalEnvelope.answer(
        channelId: channel.id,
        sessionId: envelope.sessionId,
        fromClientId: clientId,
        fromUserId: authService.userId,
        fromDisplayName: authService.displayName,
        targetUserId: envelope.fromUserId,
        targetClientId: envelope.fromClientId,
        shareKind: _shareKind,
        scope: _VoiceSignalScope.base,
        description: answer,
      ),
    );

    await _flushQueuedCandidates(peer);
    _status = 'Connected to ${peer.participant.displayName}.';
    notifyListeners();
  }

  Future<void> _handleAnswer(
    VoiceRemotePeer peer,
    _VoiceSignalEnvelope envelope,
  ) async {
    if (peer.connection == null || peer.sessionId != envelope.sessionId) {
      return;
    }

    final description = envelope.description;
    if (description == null) {
      return;
    }

    await peer.connection!.setRemoteDescription(description);
    await _flushQueuedCandidates(peer);
    _status = 'Connected to ${peer.participant.displayName}.';
    notifyListeners();
  }

  Future<void> _handleIceCandidate(
    VoiceRemotePeer peer,
    _VoiceSignalEnvelope envelope,
  ) async {
    if (peer.connection == null ||
        envelope.candidate == null ||
        peer.sessionId != envelope.sessionId) {
      return;
    }

    final remoteDescription = await peer.connection!.getRemoteDescription();
    if (remoteDescription == null) {
      _queuedCandidatesByPeer
          .putIfAbsent(peer.participant.clientId, () => <RTCIceCandidate>[])
          .add(envelope.candidate!);
      return;
    }

    await peer.connection!.addCandidate(envelope.candidate!);
  }

  Future<void> _flushQueuedCandidates(VoiceRemotePeer peer) async {
    final pending = _queuedCandidatesByPeer.remove(peer.participant.clientId);
    if (peer.connection == null || pending == null || pending.isEmpty) {
      return;
    }

    for (final candidate in pending) {
      await peer.connection!.addCandidate(candidate);
    }
  }

  Future<void> _attachRemoteTrack(
    VoiceRemotePeer peer,
    RTCTrackEvent event,
  ) async {
    MediaStream? stream = event.streams.firstOrNull;
    if (stream == null) {
      final track = event.track;
      stream =
          peer.remoteStream ??
          await createLocalMediaStream(
            'remote-${channel.id}-${peer.participant.clientId}',
          );
      final alreadyAttached = stream.getTracks().any(
        (existingTrack) => existingTrack.id == track.id,
      );
      if (!alreadyAttached) {
        await stream.addTrack(track);
      }
    }

    peer.remoteStream = stream;
    if (!identical(peer.renderer.srcObject, stream)) {
      peer.renderer.srcObject = stream;
    }
    await _applyPeerRendererVolume(peer);
    notifyListeners();
  }

  Future<void> _applyPeerRendererVolume(VoiceRemotePeer peer) async {
    if (peer.renderer.srcObject == null) {
      return;
    }
    await peer.renderer.setVolume(
      _deafened ? 0.0 : participantVolume(peer.participant.clientId),
    );
  }

  Future<void> _rebuildLocalCompositeStream() async {
    final previousComposite = _localCompositeStream;
    final microphoneStream = _microphoneStream;
    if (microphoneStream == null) {
      return;
    }

    if (_videoSourceStream == null) {
      _localCompositeStream = microphoneStream;
      if (previousComposite != null &&
          previousComposite.id != microphoneStream.id) {
        await previousComposite.dispose();
      }
      return;
    }

    final composite = await createLocalMediaStream('voice-${channel.id}');
    for (final track in microphoneStream.getAudioTracks()) {
      await composite.addTrack(track);
    }
    for (final track in _videoSourceStream!.getAudioTracks()) {
      try {
        await composite.addTrack(track);
      } on PlatformException catch (error) {
        final message = error.message ?? '';
        if (error.code != 'MediaSteamAddTrack' &&
            error.code != 'MediaStreamAddTrack' &&
            !message.contains('track is null')) {
          rethrow;
        }
      }
    }
    for (final track in _videoSourceStream!.getVideoTracks()) {
      await composite.addTrack(track);
    }
    _localCompositeStream = composite;

    if (previousComposite != null &&
        previousComposite.id != microphoneStream.id) {
      await previousComposite.dispose();
    }
  }

  Future<void> _reconnectAllPeers({required bool forceOfferAll}) async {
    final currentPeers = _peerStates.values.toList();
    for (final peer in currentPeers) {
      await _resetPeer(peer, keepRenderer: true);
    }

    for (final peer in currentPeers) {
      final shouldOffer =
          forceOfferAll || clientId.compareTo(peer.participant.clientId) < 0;
      await _connectPeer(peer, offerImmediately: shouldOffer);
    }
  }

  Future<void> _resetPeer(
    VoiceRemotePeer peer, {
    required bool keepRenderer,
  }) async {
    if (peer.connection != null) {
      await peer.connection!.close();
      await peer.connection!.dispose();
      peer.connection = null;
    }
    if (peer.remoteStream != null) {
      await peer.remoteStream!.dispose();
      peer.remoteStream = null;
    }
    _queuedCandidatesByPeer.remove(peer.participant.clientId);
    peer.renderer.srcObject = null;
    peer.sessionId = null;
    peer._signalScope = _VoiceSignalScope.base;

    if (!keepRenderer) {
      await peer.renderer.dispose();
    }
  }

  Future<void> _disposePeer(VoiceRemotePeer peer) async {
    await _resetPeer(peer, keepRenderer: false);
  }

  void _startSpeakingMonitor() {
    _speakingPollTimer?.cancel();
    unawaited(_pollSpeakingStates());
    _speakingPollTimer = Timer.periodic(_speakingPollInterval, (_) {
      unawaited(_pollSpeakingStates());
    });
  }

  void _stopSpeakingMonitor() {
    _speakingPollTimer?.cancel();
    _speakingPollTimer = null;
  }

  Future<void> _pollSpeakingStates() async {
    if (_disposed || (!_joined && _peerStates.isEmpty)) {
      return;
    }

    final now = DateTime.now();
    final levelsByParticipant = <String, double?>{clientId: null};
    for (final peer in _peerStates.values) {
      levelsByParticipant[peer.participant.clientId] =
          await _readRemoteAudioLevel(peer);
    }

    for (final entry in levelsByParticipant.entries) {
      final participantClientId = entry.key;
      final level = entry.value;
      final isMuted = participantClientId == clientId
          ? _muted
          : (_peerStates[participantClientId]?.participant.isMuted ?? false);
      if (!isMuted && level != null && level >= _speakingThreshold) {
        _lastSpeakingAt[participantClientId] = now;
      }
    }

    final nextSpeakingStates = <String, bool>{};
    final relevantParticipantIds = <String>{
      clientId,
      ..._participants.map((participant) => participant.clientId),
      ..._peerStates.keys,
    };
    for (final participantClientId in relevantParticipantIds) {
      final isMuted = participantClientId == clientId
          ? _muted
          : (_peerStates[participantClientId]?.participant.isMuted ?? false);
      final lastSpeakingAt = _lastSpeakingAt[participantClientId];
      final isSpeaking =
          !isMuted &&
          lastSpeakingAt != null &&
          now.difference(lastSpeakingAt) <= _speakingHoldDuration;
      nextSpeakingStates[participantClientId] = isSpeaking;
      if (!isSpeaking) {
        _lastSpeakingAt.remove(participantClientId);
      }
    }

    if (mapEquals(_speakingStates, nextSpeakingStates)) {
      return;
    }

    _speakingStates
      ..clear()
      ..addAll(nextSpeakingStates);
    _participants = [
      for (final participant in _participants)
        participant.copyWith(
          isSpeaking: isParticipantSpeaking(participant.clientId),
        ),
    ];
    for (final peer in _peerStates.values) {
      peer.participant = peer.participant.copyWith(
        isSpeaking: isParticipantSpeaking(peer.participant.clientId),
      );
    }
    notifyListeners();
  }

  Future<double?> _readRemoteAudioLevel(VoiceRemotePeer peer) async {
    final connection = peer.connection;
    if (connection == null || peer.participant.isMuted) {
      return 0;
    }

    try {
      final receivers = await connection.getReceivers();
      final audioReceiver = receivers
          .where((receiver) => receiver.track?.kind == 'audio')
          .firstOrNull;
      if (audioReceiver == null) {
        return null;
      }
      return _extractAudioLevel(
        await audioReceiver.getStats(),
        participantClientId: peer.participant.clientId,
      );
    } catch (_) {
      return null;
    }
  }

  double? _extractAudioLevel(
    List<StatsReport> stats, {
    required String participantClientId,
  }) {
    _AudioEnergySample? currentSample;
    for (final report in stats) {
      final values = report.values;
      final mediaKind =
          (values['kind'] ?? values['mediaType'] ?? values['media_type'])
              ?.toString()
              .toLowerCase();
      if (mediaKind != null && mediaKind != 'audio') {
        continue;
      }

      final audioLevel = _parseStatDouble(
        values['audioLevel'] ?? values['audio_level'],
      );
      if (audioLevel != null) {
        return audioLevel.clamp(0.0, 1.0);
      }

      final voiceActivity =
          values['voiceActivityFlag'] ?? values['voice_activity_flag'];
      if (voiceActivity == true) {
        return 1;
      }

      final totalAudioEnergy = _parseStatDouble(
        values['totalAudioEnergy'] ?? values['total_audio_energy'],
      );
      final totalSamplesDuration = _parseStatDouble(
        values['totalSamplesDuration'] ??
            values['total_samples_duration'] ??
            values['totalAudioDuration'] ??
            values['total_audio_duration'],
      );
      if (totalAudioEnergy != null && totalSamplesDuration != null) {
        currentSample = _AudioEnergySample(
          totalAudioEnergy: totalAudioEnergy,
          totalSamplesDuration: totalSamplesDuration,
        );
      }
    }

    if (currentSample == null) {
      return null;
    }

    final previousSample = _lastAudioSamples[participantClientId];
    _lastAudioSamples[participantClientId] = currentSample;
    if (previousSample == null) {
      return null;
    }

    final deltaEnergy = math.max(
      0.0,
      currentSample.totalAudioEnergy - previousSample.totalAudioEnergy,
    );
    final deltaDuration = math.max(
      0.0,
      currentSample.totalSamplesDuration - previousSample.totalSamplesDuration,
    );
    if (deltaDuration <= 0) {
      return null;
    }

    final derivedLevel = math.sqrt(deltaEnergy / deltaDuration);
    return derivedLevel.clamp(0.0, 1.0);
  }

  double? _parseStatDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  Future<RealtimeChannel> _ensureOutboundChannel(
    _VoiceSignalScope scope,
    String targetUserId,
  ) async {
    final topic = _signalTopic(scope, targetUserId);
    final existing = _outboundChannels[topic];
    if (existing != null) {
      return existing;
    }

    final realtimeChannel = await _subscribeRealtimeChannel(
      topic: topic,
      scope: null,
      listenPresence: false,
    );
    _outboundChannels[topic] = realtimeChannel;
    return realtimeChannel;
  }

  Future<void> _sendSignalSafely(
    _VoiceSignalEnvelope envelope, {
    required String context,
  }) async {
    try {
      await _sendSignal(envelope);
    } catch (error) {
      if (_disposed || !_joined) {
        return;
      }
      debugPrint('Ignoring voice signal failure during $context: $error');
    }
  }

  Future<void> _sendSignal(_VoiceSignalEnvelope envelope) async {
    final sendScope = envelope.type == _VoiceSignalType.offer
        ? envelope.scope
        : _VoiceSignalScope.base;
    final topic = _signalTopic(sendScope, envelope.targetUserId);

    Future<void> sendOnce() async {
      final realtimeChannel = await _ensureOutboundChannel(
        sendScope,
        envelope.targetUserId,
      );
      final response = await realtimeChannel.sendBroadcastMessage(
        event: 'webrtc-signal',
        payload: envelope.toJson(),
      );
      if (response != ChannelResponse.ok) {
        throw StateError('Broadcast send failed with response: $response');
      }
    }

    try {
      await sendOnce();
    } on StateError catch (error) {
      final message = error.toString().toLowerCase();
      final recoverable =
          message.contains('realtime channel closed') ||
          message.contains('timed out') ||
          message.contains('channel error');
      if (!recoverable || _disposed || !_joined) {
        rethrow;
      }
      final staleChannel = _outboundChannels.remove(topic);
      if (staleChannel != null) {
        await client.removeChannel(staleChannel);
      }
      await sendOnce();
    }
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stopSpeakingMonitor();
    await leave();
    await localRenderer.dispose();
  }

  Future<void> refreshLocalParticipantProfile() async {
    _participants = [
      for (final participant in _participants)
        participant.isSelf
            ? participant.copyWith(displayName: authService.displayName)
            : participant,
    ];
    if (_joined) {
      await _trackPresence();
    }
    notifyListeners();
  }

  _VoiceSignalScope _signalScopeForShareKind(ShareKind shareKind) {
    switch (shareKind) {
      case ShareKind.camera:
        return _VoiceSignalScope.camera;
      case ShareKind.screen:
        return _VoiceSignalScope.screen;
      case ShareKind.audio:
        return _VoiceSignalScope.base;
    }
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
}

enum _VoiceSignalType { offer, answer, iceCandidate, hangup }

class _VoiceSignalEnvelope {
  const _VoiceSignalEnvelope({
    required this.type,
    required this.channelId,
    required this.sessionId,
    required this.fromClientId,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.targetUserId,
    required this.targetClientId,
    required this.shareKind,
    required this.scope,
    this.description,
    this.candidate,
  });

  final _VoiceSignalType type;
  final String channelId;
  final String sessionId;
  final String fromClientId;
  final String fromUserId;
  final String fromDisplayName;
  final String targetUserId;
  final String targetClientId;
  final ShareKind shareKind;
  final _VoiceSignalScope scope;
  final RTCSessionDescription? description;
  final RTCIceCandidate? candidate;

  factory _VoiceSignalEnvelope.offer({
    required String channelId,
    required String sessionId,
    required String fromClientId,
    required String fromUserId,
    required String fromDisplayName,
    required String targetUserId,
    required String targetClientId,
    required ShareKind shareKind,
    required _VoiceSignalScope scope,
    required RTCSessionDescription description,
  }) {
    return _VoiceSignalEnvelope(
      type: _VoiceSignalType.offer,
      channelId: channelId,
      sessionId: sessionId,
      fromClientId: fromClientId,
      fromUserId: fromUserId,
      fromDisplayName: fromDisplayName,
      targetUserId: targetUserId,
      targetClientId: targetClientId,
      shareKind: shareKind,
      scope: scope,
      description: description,
    );
  }

  factory _VoiceSignalEnvelope.answer({
    required String channelId,
    required String sessionId,
    required String fromClientId,
    required String fromUserId,
    required String fromDisplayName,
    required String targetUserId,
    required String targetClientId,
    required ShareKind shareKind,
    required _VoiceSignalScope scope,
    required RTCSessionDescription description,
  }) {
    return _VoiceSignalEnvelope(
      type: _VoiceSignalType.answer,
      channelId: channelId,
      sessionId: sessionId,
      fromClientId: fromClientId,
      fromUserId: fromUserId,
      fromDisplayName: fromDisplayName,
      targetUserId: targetUserId,
      targetClientId: targetClientId,
      shareKind: shareKind,
      scope: scope,
      description: description,
    );
  }

  factory _VoiceSignalEnvelope.iceCandidate({
    required String channelId,
    required String sessionId,
    required String fromClientId,
    required String fromUserId,
    required String fromDisplayName,
    required String targetUserId,
    required String targetClientId,
    required ShareKind shareKind,
    required _VoiceSignalScope scope,
    required RTCIceCandidate candidate,
  }) {
    return _VoiceSignalEnvelope(
      type: _VoiceSignalType.iceCandidate,
      channelId: channelId,
      sessionId: sessionId,
      fromClientId: fromClientId,
      fromUserId: fromUserId,
      fromDisplayName: fromDisplayName,
      targetUserId: targetUserId,
      targetClientId: targetClientId,
      shareKind: shareKind,
      scope: scope,
      candidate: candidate,
    );
  }

  static _VoiceSignalEnvelope? tryParse(Map<String, dynamic> payload) {
    try {
      final nested = payload['payload'];
      final body = nested is Map<String, dynamic>
          ? nested
          : nested is Map
          ? Map<String, dynamic>.from(nested)
          : payload;

      final typeName = body['type'] as String?;
      final shareName = body['share_kind'] as String?;
      final scopeName = body['scope'] as String?;
      if (typeName == null ||
          shareName == null ||
          scopeName == null ||
          body['channel_id'] == null ||
          body['session_id'] == null ||
          body['from_client_id'] == null ||
          body['from_user_id'] == null ||
          body['from_display_name'] == null ||
          body['target_user_id'] == null ||
          body['target_client_id'] == null) {
        return null;
      }

      RTCSessionDescription? description;
      final descriptionMap = body['description'];
      if (descriptionMap is Map) {
        final normalized = Map<String, dynamic>.from(descriptionMap);
        final sdp = normalized['sdp'] as String?;
        final type = normalized['type'] as String?;
        if (sdp != null && type != null) {
          description = RTCSessionDescription(sdp, type);
        }
      }

      RTCIceCandidate? candidate;
      final candidateMap = body['candidate'];
      if (candidateMap is Map) {
        final normalized = Map<String, dynamic>.from(candidateMap);
        final candidateValue = normalized['candidate'] as String?;
        final sdpMid = normalized['sdpMid'] as String?;
        final sdpMLineIndex = normalized['sdpMLineIndex'] as int?;
        if (candidateValue != null && sdpMid != null && sdpMLineIndex != null) {
          candidate = RTCIceCandidate(candidateValue, sdpMid, sdpMLineIndex);
        }
      }

      return _VoiceSignalEnvelope(
        type: _signalTypeFromName(typeName),
        channelId: body['channel_id'] as String,
        sessionId: body['session_id'] as String,
        fromClientId: body['from_client_id'] as String,
        fromUserId: body['from_user_id'] as String,
        fromDisplayName: body['from_display_name'] as String,
        targetUserId: body['target_user_id'] as String,
        targetClientId: body['target_client_id'] as String,
        shareKind: _shareKindFromName(shareName),
        scope: _signalScopeFromName(scopeName),
        description: description,
        candidate: candidate,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'channel_id': channelId,
      'session_id': sessionId,
      'from_client_id': fromClientId,
      'from_user_id': fromUserId,
      'from_display_name': fromDisplayName,
      'target_user_id': targetUserId,
      'target_client_id': targetClientId,
      'share_kind': shareKind.name,
      'scope': scope.name,
      if (description != null)
        'description': {'sdp': description!.sdp, 'type': description!.type},
      if (candidate != null)
        'candidate': {
          'candidate': candidate!.candidate,
          'sdpMid': candidate!.sdpMid,
          'sdpMLineIndex': candidate!.sdpMLineIndex,
        },
    };
  }

  static _VoiceSignalType _signalTypeFromName(String value) {
    return _VoiceSignalType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => _VoiceSignalType.hangup,
    );
  }

  static ShareKind _shareKindFromName(String value) {
    switch (value) {
      case 'camera':
        return ShareKind.camera;
      case 'screen':
        return ShareKind.screen;
      default:
        return ShareKind.audio;
    }
  }

  static _VoiceSignalScope _signalScopeFromName(String value) {
    switch (value) {
      case 'camera':
        return _VoiceSignalScope.camera;
      case 'screen':
        return _VoiceSignalScope.screen;
      default:
        return _VoiceSignalScope.base;
    }
  }
}
