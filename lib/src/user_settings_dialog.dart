import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_preferences.dart';
import 'app_toast.dart';
import 'models.dart';
import 'repositories.dart';
import 'session_controller.dart';

class UserSettingsDialog extends StatefulWidget {
  const UserSettingsDialog({
    super.key,
    required this.authService,
    required this.repository,
    required this.preferences,
    required this.screenShareService,
    this.onProfileUpdated,
  });

  final AuthService authService;
  final WorkspaceRepository repository;
  final AppPreferences preferences;
  final ScreenShareService screenShareService;
  final Future<void> Function()? onProfileUpdated;

  @override
  State<UserSettingsDialog> createState() => _UserSettingsDialogState();
}

class _UserSettingsDialogState extends State<UserSettingsDialog> {
  late final TextEditingController _displayNameController =
      TextEditingController(text: widget.authService.displayName);
  final RTCVideoRenderer _cameraRenderer = RTCVideoRenderer();
  final AudioPlayer _speakerTestPlayer = AudioPlayer();
  final Uint8List _speakerTestToneBytes = _buildSpeakerTestTone();

  bool _savingProfile = false;
  bool _loadingProfile = true;
  bool _uploadingAvatar = false;
  bool _loadingDevices = true;
  bool _testingMic = false;
  bool _testingSpeaker = false;
  bool _testingCamera = false;
  String? _mediaStatus;
  double _micLevel = 0;
  double _micPeakLevel = 0;
  String? _selectedAudioInputId;
  String? _selectedAudioOutputId;
  String? _selectedVideoInputId;
  List<MediaDeviceInfo> _audioInputs = const <MediaDeviceInfo>[];
  List<MediaDeviceInfo> _audioOutputs = const <MediaDeviceInfo>[];
  List<MediaDeviceInfo> _videoInputs = const <MediaDeviceInfo>[];
  MediaStream? _micStream;
  MediaStream? _cameraStream;
  RTCPeerConnection? _micMeterPrimaryConnection;
  RTCPeerConnection? _micMeterSecondaryConnection;
  RTCRtpSender? _micMeterSender;
  Timer? _micMeterTimer;
  String? _avatarPath;
  UserStatus _status = UserStatus.online;
  late final TextEditingController _activityController =
      TextEditingController();
  bool _savingStatus = false;

  @override
  void initState() {
    super.initState();
    _selectedAudioInputId = widget.preferences.preferredAudioInputId;
    _selectedAudioOutputId = widget.preferences.preferredAudioOutputId;
    _selectedVideoInputId = widget.preferences.preferredVideoInputId;
    unawaited(_loadProfile());
    unawaited(_initializeMediaTools());
  }

  @override
  void dispose() {
    navigator.mediaDevices.ondevicechange = null;
    _displayNameController.dispose();
    _activityController.dispose();
    _micMeterTimer?.cancel();
    unawaited(_disposeMicMeter());
    unawaited(widget.screenShareService.stopStream(_micStream));
    unawaited(widget.screenShareService.stopStream(_cameraStream));
    unawaited(_speakerTestPlayer.dispose());
    unawaited(_cameraRenderer.dispose());
    super.dispose();
  }

  Future<void> _initializeMediaTools() async {
    await _cameraRenderer.initialize();
    await _speakerTestPlayer.setReleaseMode(ReleaseMode.stop);
    await _speakerTestPlayer.setPlayerMode(PlayerMode.mediaPlayer);
    await _speakerTestPlayer.setVolume(0.9);
    navigator.mediaDevices.ondevicechange = (_) {
      unawaited(_loadMediaDevices());
    };
    await widget.screenShareService.applyVoiceProcessingPreference(
      widget.preferences.noiseCancellation,
    );
    await _loadMediaDevices();
    await widget.screenShareService.applyAudioOutputDevice(
      _selectedAudioOutputId,
    );
  }

  Future<void> _saveStatus() async {
    setState(() => _savingStatus = true);
    try {
      await widget.repository.setUserStatus(
        status: _status,
        activityText: _activityController.text.trim().isEmpty
            ? null
            : _activityController.text.trim(),
      );
      if (mounted) showAppToast(context, 'Status updated.', tone: AppToastTone.success);
    } catch (error) {
      if (mounted) showAppToast(context, 'Failed: $error', tone: AppToastTone.error);
    } finally {
      if (mounted) setState(() => _savingStatus = false);
    }
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await widget.repository.fetchCurrentUserProfile();
      if (!mounted) {
        return;
      }
      setState(() {
        _avatarPath = profile.avatarPath;
        _status = profile.status;
        _activityController.text = profile.activityText ?? '';
        _loadingProfile = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingProfile = false;
      });
    }
  }

  Future<void> _saveProfile() async {
    final nextName = _displayNameController.text.trim();
    if (nextName.isEmpty) {
      return;
    }

    setState(() {
      _savingProfile = true;
    });
    try {
      await widget.authService.updateDisplayName(nextName);
      await widget.repository.ensureCurrentProfile();
      await widget.onProfileUpdated?.call();
      if (!mounted) {
        return;
      }
      final profile = await widget.repository.fetchCurrentUserProfile();
      if (!mounted) {
        return;
      }
      setState(() {
        _avatarPath = profile.avatarPath;
      });
      showAppToast(context, 'Profile updated.', tone: AppToastTone.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _savingProfile = false;
        });
      }
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_uploadingAvatar) {
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) {
      return;
    }

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      showAppToast(
        context,
        'Unable to read that image file.',
        tone: AppToastTone.error,
      );
      return;
    }

    final extension = _fileExtension(file.name);
    setState(() {
      _uploadingAvatar = true;
    });
    try {
      final profile = await widget.repository.uploadCurrentUserAvatar(
        bytes: bytes,
        fileExtension: extension,
      );
      await widget.onProfileUpdated?.call();
      if (!mounted) {
        return;
      }
      setState(() {
        _avatarPath = profile.avatarPath;
      });
      showAppToast(
        context,
        'Profile picture updated.',
        tone: AppToastTone.success,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _uploadingAvatar = false;
        });
      }
    }
  }

  Future<void> _loadMediaDevices() async {
    if (mounted) {
      setState(() {
        _loadingDevices = true;
      });
    }

    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final audioInputs = devices
          .where((device) => device.kind == 'audioinput')
          .toList();
      final audioOutputs = devices
          .where((device) => device.kind == 'audiooutput')
          .toList();
      final videoInputs = devices
          .where((device) => device.kind == 'videoinput')
          .toList();

      final nextAudioInputId = _resolveDeviceSelection(
        _selectedAudioInputId,
        audioInputs,
      );
      final nextAudioOutputId = _resolveDeviceSelection(
        _selectedAudioOutputId,
        audioOutputs,
      );
      final nextVideoInputId = _resolveDeviceSelection(
        _selectedVideoInputId,
        videoInputs,
      );

      if (_selectedAudioInputId != nextAudioInputId) {
        _selectedAudioInputId = nextAudioInputId;
        await widget.preferences.setPreferredAudioInputId(nextAudioInputId);
      }
      if (_selectedAudioOutputId != nextAudioOutputId) {
        _selectedAudioOutputId = nextAudioOutputId;
        await widget.preferences.setPreferredAudioOutputId(nextAudioOutputId);
      }
      if (_selectedVideoInputId != nextVideoInputId) {
        _selectedVideoInputId = nextVideoInputId;
        await widget.preferences.setPreferredVideoInputId(nextVideoInputId);
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _audioInputs = audioInputs;
        _audioOutputs = audioOutputs;
        _videoInputs = videoInputs;
        _loadingDevices = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingDevices = false;
        _mediaStatus = 'Unable to load media devices: $error';
      });
    }
  }

  String? _resolveDeviceSelection(
    String? selectedId,
    List<MediaDeviceInfo> devices,
  ) {
    if (selectedId == null || selectedId.isEmpty) {
      return null;
    }
    final exists = devices.any((device) => device.deviceId == selectedId);
    return exists ? selectedId : null;
  }

  Future<void> _setSelectedAudioInput(String? deviceId) async {
    await widget.preferences.setPreferredAudioInputId(deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedAudioInputId = deviceId;
      _mediaStatus = deviceId == null
          ? 'Microphone set to the system default device.'
          : 'Microphone updated.';
    });
    if (_testingMic) {
      await _restartMicTest();
    }
  }

  Future<void> _setSelectedAudioOutput(String? deviceId) async {
    await widget.preferences.setPreferredAudioOutputId(deviceId);
    await widget.screenShareService.applyAudioOutputDevice(deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedAudioOutputId = deviceId;
      _mediaStatus = deviceId == null
          ? 'Speaker set to the system default output.'
          : 'Speaker output updated.';
    });
  }

  Future<void> _setSelectedVideoInput(String? deviceId) async {
    await widget.preferences.setPreferredVideoInputId(deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedVideoInputId = deviceId;
      _mediaStatus = deviceId == null
          ? 'Camera set to the system default device.'
          : 'Camera updated.';
    });
    if (_testingCamera) {
      await _restartCameraTest();
    }
  }

  Future<void> _setNoiseCancellation(bool enabled) async {
    await widget.preferences.setNoiseCancellation(enabled);
    await widget.screenShareService.applyVoiceProcessingPreference(enabled);
    if (!mounted) {
      return;
    }
    setState(() {
      _mediaStatus = enabled
          ? 'Noise cancellation enabled.'
          : 'Noise cancellation disabled.';
    });
    if (_testingMic) {
      await _restartMicTest();
    }
  }

  Future<void> _setInputSensitivity(double value) async {
    await widget.preferences.setInputSensitivity(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _mediaStatus = 'Input sensitivity updated.';
    });
  }

  Future<void> _toggleMicTest() async {
    if (_testingMic) {
      await _stopMicTest(status: 'Microphone test stopped.');
      return;
    }

    try {
      final stream = await widget.screenShareService.openConfiguredMicrophone(
        deviceId: _selectedAudioInputId,
        noiseCancellation: widget.preferences.noiseCancellation,
      );
      _micStream = stream;
      await _startMicMeter(stream);
      await _loadMediaDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _testingMic = true;
        _mediaStatus = stream.getAudioTracks().isNotEmpty
            ? 'Microphone input detected. Speak to watch the live level.'
            : 'No microphone input detected.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mediaStatus = 'Microphone test failed: $error';
      });
    }
  }

  Future<void> _restartMicTest() async {
    await _stopMicTest();
    await _toggleMicTest();
  }

  Future<void> _stopMicTest({String? status}) async {
    _micMeterTimer?.cancel();
    _micMeterTimer = null;
    _micLevel = 0;
    _micPeakLevel = 0;
    await _disposeMicMeter();
    await widget.screenShareService.stopStream(_micStream);
    _micStream = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _testingMic = false;
      if (status != null) {
        _mediaStatus = status;
      }
    });
  }

  Future<void> _startMicMeter(MediaStream stream) async {
    await _disposeMicMeter();
    final tracks = stream.getAudioTracks();
    if (tracks.isEmpty) {
      return;
    }

    final primary = await createPeerConnection(<String, dynamic>{});
    final secondary = await createPeerConnection(<String, dynamic>{});
    await secondary.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    primary.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        return;
      }
      unawaited(secondary.addCandidate(candidate));
    };
    secondary.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        return;
      }
      unawaited(primary.addCandidate(candidate));
    };

    final sender = await primary.addTrack(tracks.first, stream);
    final offer = await primary.createOffer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await primary.setLocalDescription(offer);
    await secondary.setRemoteDescription(offer);
    final answer = await secondary.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await secondary.setLocalDescription(answer);
    await primary.setRemoteDescription(answer);

    _micMeterPrimaryConnection = primary;
    _micMeterSecondaryConnection = secondary;
    _micMeterSender = sender;
    _micMeterTimer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(_pollMicLevel()),
    );
  }

  Future<void> _disposeMicMeter() async {
    _micMeterSender = null;
    final primary = _micMeterPrimaryConnection;
    final secondary = _micMeterSecondaryConnection;
    _micMeterPrimaryConnection = null;
    _micMeterSecondaryConnection = null;

    if (primary != null) {
      await primary.close();
      await primary.dispose();
    }
    if (secondary != null) {
      await secondary.close();
      await secondary.dispose();
    }
  }

  Future<void> _pollMicLevel() async {
    final sender = _micMeterSender;
    if (sender == null) {
      return;
    }

    try {
      final level = (_extractAudioLevel(await sender.getStats()) ?? 0)
          .clamp(0.0, 1.0)
          .toDouble();
      if (!mounted) {
        return;
      }
      setState(() {
        _micLevel = level;
        _micPeakLevel = math.max(level, _micPeakLevel * 0.85);
      });
    } catch (_) {
      // Ignore transient stats failures while the preview graph spins up.
    }
  }

  Future<void> _runSpeakerTest() async {
    if (_testingSpeaker) {
      return;
    }

    if (mounted) {
      setState(() {
        _testingSpeaker = true;
        _mediaStatus = 'Playing speaker test tone...';
      });
    }

    try {
      await widget.screenShareService.applyAudioOutputDevice(
        _selectedAudioOutputId,
      );
      await _speakerTestPlayer.stop();
      await _speakerTestPlayer.play(
        BytesSource(_speakerTestToneBytes, mimeType: 'audio/wav'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 950));
      if (!mounted) {
        return;
      }
      setState(() {
        _mediaStatus = _selectedAudioOutputId == null
            ? 'Speaker test played through the system default output.'
            : 'Speaker test played through the selected output.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mediaStatus = 'Speaker test failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _testingSpeaker = false;
        });
      }
    }
  }

  Future<void> _toggleCameraTest() async {
    if (_testingCamera) {
      await _stopCameraTest(status: 'Camera preview stopped.');
      return;
    }

    try {
      final stream = await widget.screenShareService.openConfiguredCamera(
        deviceId: _selectedVideoInputId,
      );
      _cameraStream = stream;
      _cameraRenderer.srcObject = stream;
      await _loadMediaDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _testingCamera = true;
        _mediaStatus = 'Camera preview active.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _mediaStatus = 'Camera test failed: $error';
      });
    }
  }

  Future<void> _restartCameraTest() async {
    await _stopCameraTest();
    await _toggleCameraTest();
  }

  Future<void> _stopCameraTest({String? status}) async {
    await widget.screenShareService.stopStream(_cameraStream);
    _cameraStream = null;
    _cameraRenderer.srcObject = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _testingCamera = false;
      if (status != null) {
        _mediaStatus = status;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 820),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: DefaultTabController(
            length: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'User settings',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 6),
                          Text(widget.authService.currentUser.email ?? ''),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const TabBar(
                  tabs: [
                    Tab(text: 'Profile'),
                    Tab(text: 'Appearance'),
                    Tab(text: 'Notifications'),
                    Tab(text: 'Media'),
                  ],
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: TabBarView(
                    children: [
                      _ProfileSettingsTab(
                        controller: _displayNameController,
                        saving: _savingProfile,
                        loadingProfile: _loadingProfile,
                        avatarUrl: widget.repository.publicProfileAvatarUrl(
                          _avatarPath,
                        ),
                        uploadingAvatar: _uploadingAvatar,
                        onUploadAvatar: _pickAndUploadAvatar,
                        onSave: _saveProfile,
                        status: _status,
                        activityController: _activityController,
                        savingStatus: _savingStatus,
                        onStatusChanged: (s) => setState(() => _status = s),
                        onSaveStatus: _saveStatus,
                      ),
                      _AppearanceSettingsTab(preferences: widget.preferences),
                      _NotificationSettingsTab(preferences: widget.preferences),
                      _MediaSettingsTab(
                        preferences: widget.preferences,
                        renderer: _cameraRenderer,
                        loadingDevices: _loadingDevices,
                        mediaStatus: _mediaStatus,
                        testingMic: _testingMic,
                        testingSpeaker: _testingSpeaker,
                        testingCamera: _testingCamera,
                        micLevel: _micLevel,
                        micPeakLevel: _micPeakLevel,
                        audioInputs: _audioInputs,
                        audioOutputs: _audioOutputs,
                        videoInputs: _videoInputs,
                        selectedAudioInputId: _selectedAudioInputId,
                        selectedAudioOutputId: _selectedAudioOutputId,
                        selectedVideoInputId: _selectedVideoInputId,
                        onRefreshDevices: _loadMediaDevices,
                        onToggleMicTest: _toggleMicTest,
                        onRunSpeakerTest: _runSpeakerTest,
                        onToggleCameraTest: _toggleCameraTest,
                        onAudioInputChanged: _setSelectedAudioInput,
                        onAudioOutputChanged: _setSelectedAudioOutput,
                        onVideoInputChanged: _setSelectedVideoInput,
                        onNoiseCancellationChanged: _setNoiseCancellation,
                        onInputSensitivityChanged: _setInputSensitivity,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileSettingsTab extends StatelessWidget {
  const _ProfileSettingsTab({
    required this.controller,
    required this.saving,
    required this.loadingProfile,
    required this.avatarUrl,
    required this.uploadingAvatar,
    required this.onUploadAvatar,
    required this.onSave,
    required this.status,
    required this.activityController,
    required this.savingStatus,
    required this.onStatusChanged,
    required this.onSaveStatus,
  });

  final TextEditingController controller;
  final bool saving;
  final bool loadingProfile;
  final String? avatarUrl;
  final bool uploadingAvatar;
  final Future<void> Function() onUploadAvatar;
  final Future<void> Function() onSave;
  final UserStatus status;
  final TextEditingController activityController;
  final bool savingStatus;
  final void Function(UserStatus) onStatusChanged;
  final Future<void> Function() onSaveStatus;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return ListView(
      children: [
        const Text(
          'Change the display name shown across servers, chat messages, and voice presence.',
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: palette.panelAccent.withAlpha(140),
              backgroundImage: avatarUrl == null
                  ? null
                  : NetworkImage(avatarUrl!),
              child: avatarUrl == null && !loadingProfile
                  ? Text(
                      controller.text.trim().isEmpty
                          ? '?'
                          : controller.text
                                .trim()
                                .characters
                                .first
                                .toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    )
                  : loadingProfile
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            const SizedBox(width: 16),
            FilledButton.tonalIcon(
              onPressed: uploadingAvatar ? null : onUploadAvatar,
              icon: uploadingAvatar
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.image_outlined),
              label: Text(uploadingAvatar ? 'Uploading...' : 'Upload picture'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: saving ? null : onSave,
            icon: const Icon(Icons.save),
            label: Text(saving ? 'Saving...' : 'Save profile'),
          ),
        ),
        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 16),
        Text('Status', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        DropdownButtonFormField<UserStatus>(
          initialValue: status,
          decoration: const InputDecoration(labelText: 'Status'),
          items: UserStatus.values
              .map(
                (s) => DropdownMenuItem<UserStatus>(
                  value: s,
                  child: Row(
                    children: [
                      _StatusDot(status: s, size: 10),
                      const SizedBox(width: 8),
                      Text(s.label),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (s) {
            if (s != null) onStatusChanged(s);
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: activityController,
          decoration: const InputDecoration(
            labelText: 'Activity text (optional)',
            hintText: 'e.g. Playing a game, listening to music...',
          ),
          maxLength: 128,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: savingStatus ? null : onSaveStatus,
            icon: const Icon(Icons.check),
            label: Text(savingStatus ? 'Saving...' : 'Save status'),
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status, this.size = 12});

  final UserStatus status;
  final double size;

  Color get _color {
    switch (status) {
      case UserStatus.online:
        return const Color(0xFF43B581);
      case UserStatus.away:
        return const Color(0xFFFAA61A);
      case UserStatus.dnd:
        return const Color(0xFFF04747);
      case UserStatus.invisible:
        return const Color(0xFF747F8D);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: _color, shape: BoxShape.circle),
    );
  }
}

String _fileExtension(String fileName) {
  final separatorIndex = fileName.lastIndexOf('.');
  if (separatorIndex <= 0 || separatorIndex == fileName.length - 1) {
    return '';
  }
  return fileName.substring(separatorIndex).toLowerCase();
}

class _AppearanceSettingsTab extends StatelessWidget {
  const _AppearanceSettingsTab({required this.preferences});

  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: preferences,
      builder: (context, _) {
        return ListView(
          children: [
            const Text(
              'Adjust the overall look and how much motion the interface uses.',
            ),
            const SizedBox(height: 18),
            SegmentedButton<AppThemeScheme>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment<AppThemeScheme>(
                  value: AppThemeScheme.ocean,
                  label: Text('Ocean'),
                ),
                ButtonSegment<AppThemeScheme>(
                  value: AppThemeScheme.ember,
                  label: Text('Ember'),
                ),
                ButtonSegment<AppThemeScheme>(
                  value: AppThemeScheme.forest,
                  label: Text('Forest'),
                ),
              ],
              selected: {preferences.themeScheme},
              onSelectionChanged: (selection) {
                unawaited(preferences.setThemeScheme(selection.first));
              },
            ),
            const SizedBox(height: 18),
            SwitchListTile(
              value: preferences.messageAnimations,
              title: const Text('Animate messages'),
              subtitle: const Text('Use flow-in motion for new messages.'),
              onChanged: (value) {
                unawaited(preferences.setMessageAnimations(value));
              },
            ),
            SwitchListTile(
              value: preferences.reduceMotion,
              title: const Text('Reduce motion'),
              subtitle: const Text(
                'Minimize transitions when changing servers and channels.',
              ),
              onChanged: (value) {
                unawaited(preferences.setReduceMotion(value));
              },
            ),
            SwitchListTile(
              value: preferences.use24HourTime,
              title: const Text('24-hour timestamps'),
              subtitle: const Text(
                'Show message times in 24-hour format instead of AM/PM.',
              ),
              onChanged: (value) {
                unawaited(preferences.setUse24HourTime(value));
              },
            ),
            SwitchListTile(
              value: preferences.showMessageTimestamps,
              title: const Text('Show message timestamps'),
              subtitle: const Text(
                'Show message times in chat headers instead of hiding them.',
              ),
              onChanged: (value) {
                unawaited(preferences.setShowMessageTimestamps(value));
              },
            ),
          ],
        );
      },
    );
  }
}

class _NotificationSettingsTab extends StatelessWidget {
  const _NotificationSettingsTab({required this.preferences});

  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: preferences,
      builder: (context, _) {
        return ListView(
          children: [
            const Text(
              'Notification settings are stored locally on this device.',
            ),
            const SizedBox(height: 18),
            SwitchListTile(
              value: preferences.desktopNotifications,
              title: const Text('Activity notifications'),
              subtitle: const Text(
                'Show desktop notifications and in-app alerts for new messages and activity.',
              ),
              onChanged: (value) {
                unawaited(preferences.setDesktopNotifications(value));
              },
            ),
            SwitchListTile(
              value: preferences.playSounds,
              title: const Text('Message sounds'),
              subtitle: const Text('Play interface sounds for chat activity.'),
              onChanged: (value) {
                unawaited(preferences.setPlaySounds(value));
              },
            ),
          ],
        );
      },
    );
  }
}

class _MediaSettingsTab extends StatelessWidget {
  const _MediaSettingsTab({
    required this.preferences,
    required this.renderer,
    required this.loadingDevices,
    required this.mediaStatus,
    required this.testingMic,
    required this.testingSpeaker,
    required this.testingCamera,
    required this.micLevel,
    required this.micPeakLevel,
    required this.audioInputs,
    required this.audioOutputs,
    required this.videoInputs,
    required this.selectedAudioInputId,
    required this.selectedAudioOutputId,
    required this.selectedVideoInputId,
    required this.onRefreshDevices,
    required this.onToggleMicTest,
    required this.onRunSpeakerTest,
    required this.onToggleCameraTest,
    required this.onAudioInputChanged,
    required this.onAudioOutputChanged,
    required this.onVideoInputChanged,
    required this.onNoiseCancellationChanged,
    required this.onInputSensitivityChanged,
  });

  final AppPreferences preferences;
  final RTCVideoRenderer renderer;
  final bool loadingDevices;
  final String? mediaStatus;
  final bool testingMic;
  final bool testingSpeaker;
  final bool testingCamera;
  final double micLevel;
  final double micPeakLevel;
  final List<MediaDeviceInfo> audioInputs;
  final List<MediaDeviceInfo> audioOutputs;
  final List<MediaDeviceInfo> videoInputs;
  final String? selectedAudioInputId;
  final String? selectedAudioOutputId;
  final String? selectedVideoInputId;
  final Future<void> Function() onRefreshDevices;
  final Future<void> Function() onToggleMicTest;
  final Future<void> Function() onRunSpeakerTest;
  final Future<void> Function() onToggleCameraTest;
  final Future<void> Function(String? deviceId) onAudioInputChanged;
  final Future<void> Function(String? deviceId) onAudioOutputChanged;
  final Future<void> Function(String? deviceId) onVideoInputChanged;
  final Future<void> Function(bool enabled) onNoiseCancellationChanged;
  final Future<void> Function(double value) onInputSensitivityChanged;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Choose your devices, test them, and decide whether voice cleanup should stay on.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            OutlinedButton.icon(
              onPressed: loadingDevices
                  ? null
                  : () => unawaited(onRefreshDevices()),
              icon: loadingDevices
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('Refresh devices'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 760;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: stacked ? constraints.maxWidth : 320,
                  child: _MediaPanelCard(
                    title: 'Audio devices',
                    child: Column(
                      children: [
                        _DeviceSelectorField(
                          label: 'Microphone',
                          value: selectedAudioInputId,
                          devices: audioInputs,
                          emptyLabel: 'System default',
                          onChanged: (value) =>
                              unawaited(onAudioInputChanged(value)),
                        ),
                        const SizedBox(height: 14),
                        _DeviceSelectorField(
                          label: 'Speaker',
                          value: selectedAudioOutputId,
                          devices: audioOutputs,
                          emptyLabel: 'System default',
                          onChanged: (value) =>
                              unawaited(onAudioOutputChanged(value)),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: preferences.noiseCancellation,
                          title: const Text('Noise cancellation'),
                          subtitle: const Text(
                            'Uses WebRTC echo cancellation, noise suppression, and native voice processing when available.',
                          ),
                          onChanged: (value) =>
                              unawaited(onNoiseCancellationChanged(value)),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Input sensitivity',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        Slider(
                          value: preferences.inputSensitivity,
                          min: 0.5,
                          max: 2.0,
                          divisions: 30,
                          label: _sensitivityLabel(
                            preferences.inputSensitivity,
                          ),
                          onChanged: (value) =>
                              unawaited(onInputSensitivityChanged(value)),
                        ),
                        Text(
                          '${_sensitivityLabel(preferences.inputSensitivity)}. '
                          'Raise this if quiet words are getting missed. Lower it if background noise triggers the mic too easily.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: stacked ? constraints.maxWidth : 320,
                  child: _MediaPanelCard(
                    title: 'Microphone test',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          testingMic
                              ? 'Speak normally. The meter shows how much audio is getting through after your current processing settings.'
                              : 'Start the microphone test to see a live input meter.',
                        ),
                        const SizedBox(height: 14),
                        _SignalMeter(level: micLevel, peakLevel: micPeakLevel),
                        const SizedBox(height: 10),
                        Text(
                          _describeMicLevel(micLevel),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonalIcon(
                          onPressed: () => unawaited(onToggleMicTest()),
                          icon: Icon(testingMic ? Icons.stop : Icons.mic),
                          label: Text(
                            testingMic
                                ? 'Stop microphone test'
                                : 'Test microphone',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: stacked ? constraints.maxWidth : 320,
                  child: _MediaPanelCard(
                    title: 'Speaker test',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Play a short tone through the selected output so you can confirm the routing before joining voice.',
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonalIcon(
                          onPressed: testingSpeaker
                              ? null
                              : () => unawaited(onRunSpeakerTest()),
                          icon: testingSpeaker
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.volume_up),
                          label: Text(
                            testingSpeaker
                                ? 'Playing test tone...'
                                : 'Play speaker test',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        _MediaPanelCard(
          title: 'Camera preview',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DeviceSelectorField(
                label: 'Camera',
                value: selectedVideoInputId,
                devices: videoInputs,
                emptyLabel: 'System default',
                onChanged: (value) => unawaited(onVideoInputChanged(value)),
              ),
              const SizedBox(height: 16),
              Container(
                height: 420,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: palette.border),
                ),
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<RTCVideoValue>(
                  valueListenable: renderer,
                  builder: (context, value, _) {
                    final aspectRatio = value.aspectRatio > 0
                        ? value.aspectRatio
                        : 16 / 9;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 320,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: aspectRatio,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: DecoratedBox(
                                  decoration: const BoxDecoration(
                                    color: Colors.black,
                                  ),
                                  child: testingCamera
                                      ? RTCVideoView(
                                          renderer,
                                          mirror: true,
                                          objectFit: RTCVideoViewObjectFit
                                              .RTCVideoViewObjectFitContain,
                                          placeholderBuilder: (context) {
                                            return const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            );
                                          },
                                        )
                                      : const Center(
                                          child: Text(
                                            'Camera preview is not active.',
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => unawaited(onToggleCameraTest()),
                              icon: Icon(
                                testingCamera ? Icons.stop : Icons.videocam,
                              ),
                              label: Text(
                                testingCamera
                                    ? 'Stop camera preview'
                                    : 'Test camera',
                              ),
                            ),
                            const Spacer(),
                            if (testingCamera &&
                                value.width > 0 &&
                                value.height > 0)
                              Text(
                                '${value.width.round()} x ${value.height.round()}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        if (mediaStatus != null) ...[
          const SizedBox(height: 16),
          Text(mediaStatus!),
        ],
      ],
    );
  }

  String _describeMicLevel(double level) {
    if (level >= 0.2) {
      return 'Strong input detected.';
    }
    if (level >= 0.06) {
      return 'Low but usable input detected.';
    }
    return 'Mostly quiet right now.';
  }

  String _sensitivityLabel(double value) {
    return 'Sensitivity ${(value * 100).round()}%';
  }
}

class _MediaPanelCard extends StatelessWidget {
  const _MediaPanelCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.panelStrong,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _DeviceSelectorField extends StatelessWidget {
  const _DeviceSelectorField({
    required this.label,
    required this.value,
    required this.devices,
    required this.emptyLabel,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<MediaDeviceInfo> devices;
  final String emptyLabel;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text(emptyLabel)),
        for (var index = 0; index < devices.length; index++)
          DropdownMenuItem<String?>(
            value: devices[index].deviceId,
            child: Text(_deviceLabel(devices[index], index)),
          ),
      ],
      onChanged: onChanged,
    );
  }

  String _deviceLabel(MediaDeviceInfo device, int index) {
    final cleanLabel = device.label.trim();
    if (cleanLabel.isNotEmpty) {
      return cleanLabel;
    }
    switch (device.kind) {
      case 'audioinput':
        return 'Microphone ${index + 1}';
      case 'audiooutput':
        return 'Speaker ${index + 1}';
      case 'videoinput':
        return 'Camera ${index + 1}';
      default:
        return 'Device ${index + 1}';
    }
  }
}

class _SignalMeter extends StatelessWidget {
  const _SignalMeter({required this.level, required this.peakLevel});

  final double level;
  final double peakLevel;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final levelClamped = level.clamp(0.0, 1.0);
    final peakClamped = peakLevel.clamp(0.0, 1.0);
    return Container(
      height: 18,
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            children: [
              Container(color: palette.panel),
              Container(
                width: width * levelClamped,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                    ],
                  ),
                ),
              ),
              Positioned(
                left: math.max(0, width * peakClamped - 2),
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: Colors.white.withAlpha(190)),
              ),
            ],
          );
        },
      ),
    );
  }
}

double? _extractAudioLevel(List<StatsReport> stats) {
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
      return audioLevel;
    }

    final voiceActivity =
        values['voiceActivityFlag'] ?? values['voice_activity_flag'];
    if (voiceActivity == true) {
      return 1;
    }
  }
  return null;
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

Uint8List _buildSpeakerTestTone() {
  const sampleRate = 44100;
  const frequency = 880.0;
  const volume = 0.32;
  const durationMs = 820;
  final totalSamples = (sampleRate * durationMs / 1000).round();
  final dataSize = totalSamples * 2;
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

  for (var index = 0; index < totalSamples; index++) {
    final progress = index / totalSamples;
    final envelope = progress < 0.08
        ? progress / 0.08
        : progress > 0.9
        ? (1 - progress) / 0.1
        : 1.0;
    final sample =
        math.sin(2 * math.pi * frequency * index / sampleRate) *
        volume *
        envelope;
    bytes.setInt16(44 + (index * 2), (sample * 32767).round(), Endian.little);
  }

  return bytes.buffer.asUint8List();
}
