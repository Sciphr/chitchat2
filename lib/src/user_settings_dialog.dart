import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_preferences.dart';
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

  bool _savingProfile = false;
  bool _testingMic = false;
  bool _testingCamera = false;
  String? _mediaStatus;
  MediaStream? _micStream;
  MediaStream? _cameraStream;

  @override
  void initState() {
    super.initState();
    unawaited(_cameraRenderer.initialize());
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    unawaited(widget.screenShareService.stopStream(_micStream));
    unawaited(widget.screenShareService.stopStream(_cameraStream));
    unawaited(_cameraRenderer.dispose());
    super.dispose();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() {
          _savingProfile = false;
        });
      }
    }
  }

  Future<void> _toggleMicTest() async {
    if (_testingMic) {
      await widget.screenShareService.stopStream(_micStream);
      _micStream = null;
      if (mounted) {
        setState(() {
          _testingMic = false;
          _mediaStatus = 'Microphone test stopped.';
        });
      }
      return;
    }

    try {
      final stream = await widget.screenShareService.openMicrophone();
      _micStream = stream;
      if (!mounted) {
        return;
      }
      setState(() {
        _testingMic = true;
        _mediaStatus = stream.getAudioTracks().isNotEmpty
            ? 'Microphone input detected.'
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

  Future<void> _toggleCameraTest() async {
    if (_testingCamera) {
      await widget.screenShareService.stopStream(_cameraStream);
      _cameraStream = null;
      _cameraRenderer.srcObject = null;
      if (mounted) {
        setState(() {
          _testingCamera = false;
          _mediaStatus = 'Camera preview stopped.';
        });
      }
      return;
    }

    try {
      final stream = await widget.screenShareService.openCameraVideo();
      _cameraStream = stream;
      _cameraRenderer.srcObject = stream;
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
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
                        onSave: _saveProfile,
                      ),
                      _AppearanceSettingsTab(preferences: widget.preferences),
                      _NotificationSettingsTab(preferences: widget.preferences),
                      _MediaSettingsTab(
                        renderer: _cameraRenderer,
                        mediaStatus: _mediaStatus,
                        testingMic: _testingMic,
                        testingCamera: _testingCamera,
                        onToggleMicTest: _toggleMicTest,
                        onToggleCameraTest: _toggleCameraTest,
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
    required this.onSave,
  });

  final TextEditingController controller;
  final bool saving;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Text(
          'Change the display name shown across servers, chat messages, and voice presence.',
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
      ],
    );
  }
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
              title: const Text('Desktop notifications'),
              subtitle: const Text('Show local desktop alerts for activity.'),
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
    required this.renderer,
    required this.mediaStatus,
    required this.testingMic,
    required this.testingCamera,
    required this.onToggleMicTest,
    required this.onToggleCameraTest,
  });

  final RTCVideoRenderer renderer;
  final String? mediaStatus;
  final bool testingMic;
  final bool testingCamera;
  final Future<void> Function() onToggleMicTest;
  final Future<void> Function() onToggleCameraTest;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return ListView(
      children: [
        const Text(
          'Test your microphone and camera before joining a voice channel.',
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.tonalIcon(
              onPressed: onToggleMicTest,
              icon: const Icon(Icons.mic),
              label: Text(testingMic ? 'Stop mic test' : 'Test microphone'),
            ),
            FilledButton.tonalIcon(
              onPressed: onToggleCameraTest,
              icon: const Icon(Icons.videocam),
              label: Text(testingCamera ? 'Stop camera' : 'Test camera'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          height: 260,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border),
          ),
          child: testingCamera
              ? RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : const Center(child: Text('Camera preview is not active.')),
        ),
        if (mediaStatus != null) ...[
          const SizedBox(height: 16),
          Text(mediaStatus!),
        ],
      ],
    );
  }
}
