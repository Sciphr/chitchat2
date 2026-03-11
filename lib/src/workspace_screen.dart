import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_preferences.dart';
import 'models.dart';
import 'repositories.dart';
import 'session_controller.dart';
import 'server_settings_dialog.dart';
import 'ui_sound_effects.dart';
import 'user_settings_dialog.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.authService,
    required this.workspaceRepository,
    required this.preferences,
  });

  final AuthService authService;
  final WorkspaceRepository workspaceRepository;
  final AppPreferences preferences;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final ScreenShareService _screenShareService = ScreenShareService();
  final UiSoundEffects _soundEffects = UiSoundEffects();

  bool _loadingServers = true;
  bool _loadingChannels = false;
  bool _loadingServerAccess = false;
  String? _serverError;
  String? _channelError;
  List<ServerSummary> _servers = const <ServerSummary>[];
  List<ChannelCategorySummary> _categories = const <ChannelCategorySummary>[];
  List<ChannelSummary> _channels = const <ChannelSummary>[];
  ServerSummary? _selectedServer;
  ChannelSummary? _selectedChannel;
  ServerAccess? _serverAccess;
  ChannelSummary? _activeVoiceChannel;
  VoiceChannelSessionController? _activeVoiceController;
  VoiceChannelSessionController? _previewVoiceController;
  bool _displayNamePromptShown = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeWorkspace());
  }

  @override
  void dispose() {
    unawaited(_activeVoiceController?.close());
    if (!identical(_previewVoiceController, _activeVoiceController)) {
      unawaited(_previewVoiceController?.close());
    }
    unawaited(_soundEffects.dispose());
    super.dispose();
  }

  ChannelCategorySummary _copyCategoryWithPosition(
    ChannelCategorySummary category,
    int position,
  ) {
    return ChannelCategorySummary(
      id: category.id,
      serverId: category.serverId,
      name: category.name,
      position: position,
      createdBy: category.createdBy,
      createdAt: category.createdAt,
    );
  }

  ChannelSummary _copyChannel({
    required ChannelSummary channel,
    String? categoryId,
    required int position,
  }) {
    return ChannelSummary(
      id: channel.id,
      serverId: channel.serverId,
      categoryId: categoryId ?? channel.categoryId,
      name: channel.name,
      kind: channel.kind,
      position: position,
      createdBy: channel.createdBy,
      createdAt: channel.createdAt,
    );
  }

  List<ChannelSummary> _optimisticallyReorderedChannels(
    String? categoryId,
    List<ChannelSummary> reorderedGroup,
  ) {
    final updatedGroup = [
      for (var index = 0; index < reorderedGroup.length; index++)
        _copyChannel(
          channel: reorderedGroup[index],
          categoryId: categoryId,
          position: index,
        ),
    ];

    var replacementIndex = 0;
    return [
      for (final channel in _channels)
        if (channel.categoryId == categoryId)
          updatedGroup[replacementIndex++]
        else
          channel,
    ];
  }

  VoiceChannelSessionController? get _selectedVoiceController {
    final selectedChannel = _selectedChannel;
    if (selectedChannel == null || selectedChannel.kind != ChannelKind.voice) {
      return null;
    }
    if (_activeVoiceChannel?.id == selectedChannel.id) {
      return _activeVoiceController;
    }
    return _previewVoiceController;
  }

  Future<void> _disposePreviewVoiceController() async {
    final previewController = _previewVoiceController;
    _previewVoiceController = null;
    if (mounted) {
      setState(() {});
    }
    if (previewController != null &&
        !identical(previewController, _activeVoiceController)) {
      await previewController.close();
    }
  }

  Future<void> _prepareVoicePreview(ChannelSummary channel) async {
    if (_activeVoiceChannel?.id == channel.id) {
      await _disposePreviewVoiceController();
      return;
    }
    if (_previewVoiceController?.channel.id == channel.id) {
      return;
    }

    final previousPreview = _previewVoiceController;
    _previewVoiceController = null;
    setState(() {});
    if (previousPreview != null &&
        !identical(previousPreview, _activeVoiceController)) {
      await previousPreview.close();
    }

    final controller = VoiceChannelSessionController(
      channel: channel,
      client: Supabase.instance.client,
      authService: widget.authService,
      screenShareService: _screenShareService,
      soundEffects: _soundEffects,
    );
    await controller.initialize();
    if (!mounted ||
        _selectedChannel?.id != channel.id ||
        _selectedChannel?.kind != ChannelKind.voice ||
        _activeVoiceChannel?.id == channel.id) {
      await controller.close();
      return;
    }
    setState(() {
      _previewVoiceController = controller;
    });
  }

  Future<void> _joinSelectedVoiceChannel() async {
    final selectedChannel = _selectedChannel;
    if (selectedChannel == null || selectedChannel.kind != ChannelKind.voice) {
      return;
    }

    var targetController = _selectedVoiceController;
    if (targetController == null) {
      await _prepareVoicePreview(selectedChannel);
      targetController = _selectedVoiceController;
    }
    if (targetController == null) {
      return;
    }

    if (_activeVoiceChannel?.id != selectedChannel.id) {
      final previousActive = _activeVoiceController;
      _activeVoiceController = null;
      _activeVoiceChannel = null;
      setState(() {});
      await previousActive?.close();
    }

    await targetController.join();
    if (!mounted || !targetController.joined) {
      return;
    }

    setState(() {
      _activeVoiceController = targetController;
      _activeVoiceChannel = selectedChannel;
      if (identical(_previewVoiceController, targetController)) {
        _previewVoiceController = null;
      }
    });
  }

  Future<void> _leaveActiveVoiceChannel() async {
    final activeController = _activeVoiceController;
    final activeChannel = _activeVoiceChannel;
    if (activeController == null) {
      return;
    }

    final keepAsPreview = _selectedChannel?.id == activeChannel?.id;
    await activeController.leave();
    if (!mounted) {
      return;
    }

    setState(() {
      _activeVoiceController = null;
      _activeVoiceChannel = null;
      if (keepAsPreview) {
        _previewVoiceController = activeController;
      }
    });

    if (!keepAsPreview) {
      await activeController.close();
    }
  }

  Future<void> _loadServers({bool selectFirstServer = false}) async {
    setState(() {
      _loadingServers = true;
      _serverError = null;
    });

    try {
      final servers = await widget.workspaceRepository.fetchServers();
      if (!mounted) {
        return;
      }

      setState(() {
        _servers = servers;
        _loadingServers = false;
      });

      if (selectFirstServer && _selectedServer == null && servers.isNotEmpty) {
        await _selectServer(servers.first);
      } else if (_selectedServer != null &&
          !servers.any((server) => server.id == _selectedServer!.id)) {
        await _selectServer(null);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _serverError = error.toString();
        _loadingServers = false;
      });
    }
  }

  Future<void> _initializeWorkspace() async {
    try {
      await widget.workspaceRepository.ensureCurrentProfile();
    } catch (error) {
      if (mounted) {
        setState(() {
          _serverError = error.toString();
        });
      }
    }
    await _loadServers(selectFirstServer: true);
    if (mounted) {
      unawaited(_maybePromptForDisplayName());
    }
  }

  Future<void> _handleProfileUpdated() async {
    await _activeVoiceController?.refreshLocalParticipantProfile();
    if (!identical(_previewVoiceController, _activeVoiceController)) {
      await _previewVoiceController?.refreshLocalParticipantProfile();
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _maybePromptForDisplayName() async {
    if (_displayNamePromptShown ||
        !widget.authService.shouldPromptForDisplayName) {
      return;
    }
    _displayNamePromptShown = true;

    final controller = TextEditingController(
      text: widget.authService.suggestedDisplayName,
    );
    try {
      final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          Future<void> savePromptDisplayName() async {
            final nextName = controller.text.trim();
            if (nextName.isEmpty) {
              return;
            }

            try {
              await widget.authService.updateDisplayName(nextName);
              await widget.workspaceRepository.ensureCurrentProfile();
              await _handleProfileUpdated();
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop(true);
              }
            } catch (error) {
              if (!dialogContext.mounted) {
                return;
              }
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text(error.toString())),
              );
            }
          }

          return AlertDialog(
            title: const Text('Choose your display name'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This name is shown across servers, messages, and voice chat.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  onSubmitted: (_) => unawaited(savePromptDisplayName()),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: savePromptDisplayName,
                child: const Text('Save'),
              ),
            ],
          );
        },
      );

      if (saved == true && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Display name updated.')));
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _loadChannels(
    String serverId, {
    bool selectFirst = false,
  }) async {
    setState(() {
      _loadingChannels = true;
      _channelError = null;
    });

    try {
      final results = await Future.wait<dynamic>([
        widget.workspaceRepository.fetchChannelCategories(serverId),
        widget.workspaceRepository.fetchChannels(serverId),
      ]);
      final categories = results[0] as List<ChannelCategorySummary>;
      final channels = results[1] as List<ChannelSummary>;
      if (!mounted) {
        return;
      }

      setState(() {
        _categories = categories;
        _channels = channels;
        _loadingChannels = false;
      });

      if (selectFirst && channels.isNotEmpty) {
        await _selectChannel(channels.first);
      } else if (_selectedChannel != null &&
          !channels.any((channel) => channel.id == _selectedChannel!.id)) {
        await _selectChannel(null);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _channelError = error.toString();
        _loadingChannels = false;
      });
    }
  }

  Future<void> _selectServer(ServerSummary? server) async {
    if (_selectedServer?.id == server?.id) {
      return;
    }

    await _selectChannel(null);
    _selectedServer = server;
    _categories = const <ChannelCategorySummary>[];
    _channels = const <ChannelSummary>[];
    _serverAccess = null;
    _loadingServerAccess = server != null;
    setState(() {});

    if (server != null) {
      await Future.wait<void>([
        _loadChannels(server.id, selectFirst: true),
        _loadServerAccess(server),
      ]);
    }
  }

  Future<void> _loadServerAccess(ServerSummary server) async {
    setState(() {
      _loadingServerAccess = true;
    });

    try {
      final access = await widget.workspaceRepository.fetchServerAccess(server);
      if (!mounted || _selectedServer?.id != server.id) {
        return;
      }
      setState(() {
        _serverAccess = access;
        _loadingServerAccess = false;
      });
    } catch (error) {
      if (!mounted || _selectedServer?.id != server.id) {
        return;
      }
      setState(() {
        _serverError = error.toString();
        _loadingServerAccess = false;
      });
    }
  }

  Future<void> _selectChannel(ChannelSummary? channel) async {
    if (_selectedChannel?.id == channel?.id) {
      return;
    }

    _selectedChannel = channel;
    setState(() {});

    if (channel != null && channel.kind == ChannelKind.voice) {
      await _prepareVoicePreview(channel);
    } else {
      await _disposePreviewVoiceController();
    }
  }

  Future<void> _promptCreateServer() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create server'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Server name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty) {
      return;
    }

    try {
      final server = await widget.workspaceRepository.createServer(result);
      await _loadServers();
      await _selectServer(server);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _promptJoinServer() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join server'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Invite code'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty) {
      return;
    }

    try {
      final server = await widget.workspaceRepository.joinServerByInvite(
        result,
      );
      await _loadServers();
      await _selectServer(server);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _promptCreateChannel() async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }

    final nameController = TextEditingController();
    ChannelKind kind = ChannelKind.text;
    String? selectedCategoryId =
        _selectedChannel?.categoryId ??
        (_categories.isEmpty ? null : _categories.first.id);

    final result = await showDialog<(String, ChannelKind, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create channel'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Channel name'),
              ),
              const SizedBox(height: 16),
              SegmentedButton<ChannelKind>(
                segments: const [
                  ButtonSegment<ChannelKind>(
                    value: ChannelKind.text,
                    label: Text('Text'),
                    icon: Icon(Icons.chat_bubble_outline),
                  ),
                  ButtonSegment<ChannelKind>(
                    value: ChannelKind.voice,
                    label: Text('Voice'),
                    icon: Icon(Icons.volume_up),
                  ),
                ],
                selected: {kind},
                onSelectionChanged: (selection) {
                  setState(() {
                    kind = selection.first;
                  });
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                initialValue: selectedCategoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No category'),
                  ),
                  ..._categories.map(
                    (category) => DropdownMenuItem<String?>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    selectedCategoryId = value;
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pop((nameController.text, kind, selectedCategoryId)),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();

    if (result == null || result.$1.trim().isEmpty) {
      return;
    }

    try {
      final channel = await widget.workspaceRepository.createChannel(
        serverId: selectedServer.id,
        categoryId: result.$3,
        name: result.$1,
        kind: result.$2,
      );
      await _loadChannels(selectedServer.id);
      await _selectChannel(channel);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _promptCreateCategory() async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }

    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty) {
      return;
    }

    try {
      await widget.workspaceRepository.createChannelCategory(
        serverId: selectedServer.id,
        name: result,
      );
      await _loadChannels(selectedServer.id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _promptRenameCategory(ChannelCategorySummary category) async {
    final controller = TextEditingController(text: category.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (result == null || result.trim().isEmpty) {
      return;
    }

    try {
      await widget.workspaceRepository.renameChannelCategory(
        categoryId: category.id,
        name: result,
      );
      final selectedServer = _selectedServer;
      if (selectedServer != null) {
        await _loadChannels(selectedServer.id);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _reorderCategories(int oldIndex, int newIndex) async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }
    final previousCategories = List<ChannelCategorySummary>.from(_categories);
    final nextCategories = List<ChannelCategorySummary>.from(_categories);
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final moved = nextCategories.removeAt(oldIndex);
    nextCategories.insert(newIndex, moved);
    final updatedCategories = [
      for (var index = 0; index < nextCategories.length; index++)
        _copyCategoryWithPosition(nextCategories[index], index),
    ];

    setState(() {
      _categories = updatedCategories;
    });

    try {
      await widget.workspaceRepository.reorderChannelCategories([
        for (var index = 0; index < updatedCategories.length; index++)
          ChannelCategoryOrderUpdate(
            categoryId: updatedCategories[index].id,
            position: index,
          ),
      ]);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _categories = previousCategories;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _reorderChannels(
    String? categoryId,
    int oldIndex,
    int newIndex,
  ) async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }
    final previousChannels = List<ChannelSummary>.from(_channels);
    final nextChannels = _channels
        .where((channel) => channel.categoryId == categoryId)
        .toList();
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final moved = nextChannels.removeAt(oldIndex);
    nextChannels.insert(newIndex, moved);
    final updatedChannels = _optimisticallyReorderedChannels(
      categoryId,
      nextChannels,
    );

    setState(() {
      _channels = updatedChannels;
    });

    try {
      await widget.workspaceRepository.reorderChannels([
        for (var index = 0; index < nextChannels.length; index++)
          ChannelOrderUpdate(
            channelId: nextChannels[index].id,
            position: index,
            categoryId: categoryId,
          ),
      ]);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _channels = previousChannels;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _copyInviteCode() async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: selectedServer.inviteCode));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite code copied to clipboard.')),
    );
  }

  Future<void> _pickServerAvatar() async {
    final selectedServer = _selectedServer;
    if (selectedServer == null ||
        selectedServer.ownerId != widget.authService.userId) {
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) {
      return;
    }

    try {
      final updatedServer = await widget.workspaceRepository.uploadServerAvatar(
        serverId: selectedServer.id,
        bytes: file.bytes!,
        fileExtension: file.extension ?? 'png',
      );
      await _loadServers();
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedServer = updatedServer;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _openServerSettings() async {
    final selectedServer = _selectedServer;
    final serverAccess = _serverAccess;
    if (selectedServer == null || serverAccess == null) {
      return;
    }

    final shouldRefresh = await showDialog<bool>(
      context: context,
      builder: (context) => ServerSettingsDialog(
        server: selectedServer,
        repository: widget.workspaceRepository,
        access: serverAccess,
        onCopyInvite: _copyInviteCode,
        onCreateChannel: _promptCreateChannel,
        onCreateCategory: _promptCreateCategory,
        onPickServerAvatar: _pickServerAvatar,
      ),
    );

    if (!mounted ||
        _selectedServer?.id != selectedServer.id ||
        shouldRefresh != true) {
      return;
    }
    await _loadServerAccess(selectedServer);
    await _loadChannels(selectedServer.id);
  }

  Future<void> _openUserSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => UserSettingsDialog(
        authService: widget.authService,
        repository: widget.workspaceRepository,
        preferences: widget.preferences,
        screenShareService: _screenShareService,
        onProfileUpdated: _handleProfileUpdated,
      ),
    );

    if (!mounted) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selectedServer = _selectedServer;
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final activeVoiceController = _activeVoiceController;
    final sidebar = activeVoiceController == null
        ? _ChannelSidebar(
            server: selectedServer,
            categories: _categories,
            channels: _channels,
            loading: _loadingChannels,
            loadingAccess: _loadingServerAccess,
            error: _channelError,
            access: _serverAccess,
            selectedChannelId: _selectedChannel?.id,
            activeVoiceChannelId: _activeVoiceChannel?.id,
            activeVoiceParticipants: const <VoiceParticipant>[],
            onSelectChannel: _selectChannel,
            onRenameCategory: _promptRenameCategory,
            onReorderCategories: _reorderCategories,
            onReorderChannels: _reorderChannels,
            onOpenSettings: _openServerSettings,
          )
        : AnimatedBuilder(
            animation: activeVoiceController,
            builder: (context, _) => _ChannelSidebar(
              server: selectedServer,
              categories: _categories,
              channels: _channels,
              loading: _loadingChannels,
              loadingAccess: _loadingServerAccess,
              error: _channelError,
              access: _serverAccess,
              selectedChannelId: _selectedChannel?.id,
              activeVoiceChannelId: _activeVoiceChannel?.id,
              activeVoiceParticipants: activeVoiceController.participants,
              onSelectChannel: _selectChannel,
              onRenameCategory: _promptRenameCategory,
              onReorderCategories: _reorderCategories,
              onReorderChannels: _reorderChannels,
              onOpenSettings: _openServerSettings,
            ),
          );

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: palette.appBackground),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                _WorkspaceHeader(
                  displayName: widget.authService.displayName,
                  onSignOut: widget.authService.signOut,
                  onOpenSettings: _openUserSettings,
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 108,
                        child: _ServerRail(
                          servers: _servers,
                          loading: _loadingServers,
                          error: _serverError,
                          selectedServerId: selectedServer?.id,
                          onSelectServer: _selectServer,
                          onCreateServer: _promptCreateServer,
                          onJoinServer: _promptJoinServer,
                          onRefresh: _loadServers,
                          currentUserId: widget.authService.userId,
                          onLeaveServer: _leaveServer,
                          onDeleteServer: _deleteServer,
                          avatarUrlForPath:
                              widget.workspaceRepository.publicServerAvatarUrl,
                        ),
                      ),
                      const SizedBox(width: 18),
                      AnimatedSwitcher(
                        duration: widget.preferences.motionDuration,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.04, 0),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          key: ValueKey<String?>(selectedServer?.id),
                          width: 320,
                          child: sidebar,
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: widget.preferences.motionDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.02, 0.03),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: KeyedSubtree(
                            key: ValueKey<String?>(
                              '${selectedServer?.id}:${_selectedChannel?.id}',
                            ),
                            child: _selectedChannel == null
                                ? const _EmptyState(
                                    title: 'Select a channel',
                                    message:
                                        'Choose a text channel for chat or a voice channel for live audio, camera, and screen sharing.',
                                  )
                                : _selectedChannel!.kind == ChannelKind.text
                                ? TextChannelView(
                                    channel: _selectedChannel!,
                                    repository: widget.workspaceRepository,
                                    canSendMessages:
                                        _serverAccess?.hasPermission(
                                          ServerPermission.sendMessages,
                                        ) ??
                                        true,
                                    motionDuration:
                                        widget.preferences.motionDuration,
                                    animateMessages:
                                        widget.preferences.messageAnimations &&
                                        !widget.preferences.reduceMotion,
                                  )
                                : VoiceChannelView(
                                    channel: _selectedChannel!,
                                    repository: widget.workspaceRepository,
                                    controller: _selectedVoiceController,
                                    activeChannelId: _activeVoiceChannel?.id,
                                    canJoinVoice:
                                        _serverAccess?.hasPermission(
                                          ServerPermission.joinVoice,
                                        ) ??
                                        true,
                                    canManageServer:
                                        _serverAccess?.hasPermission(
                                          ServerPermission.manageServer,
                                        ) ??
                                        false,
                                    canStreamCamera:
                                        _serverAccess?.hasPermission(
                                          ServerPermission.streamCamera,
                                        ) ??
                                        true,
                                    canShareScreen:
                                        _serverAccess?.hasPermission(
                                          ServerPermission.shareScreen,
                                        ) ??
                                        true,
                                    onJoinCall: _joinSelectedVoiceChannel,
                                    onLeaveCall: _leaveActiveVoiceChannel,
                                  ),
                          ),
                        ),
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

  Future<void> _leaveServer(ServerSummary server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave server'),
        content: Text(
          'Leave "${server.name}"? You will need a new invite to rejoin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      if (_activeVoiceChannel?.serverId == server.id) {
        await _leaveActiveVoiceChannel();
      }
      if (_selectedServer?.id == server.id) {
        await _selectChannel(null);
      }
      await widget.workspaceRepository.removeMemberFromServer(
        serverId: server.id,
        userId: widget.authService.userId,
      );
      await _loadServers(selectFirstServer: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _deleteServer(ServerSummary server) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete server'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Deleting "${server.name}" will permanently remove its channels, messages, roles, and invites for everyone.',
              ),
              const SizedBox(height: 12),
              const Text('Type the server name to confirm.'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(labelText: 'Server name'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: controller.text.trim() == server.name
                  ? () => Navigator.of(context).pop(true)
                  : null,
              child: const Text('Delete server'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();

    if (confirmed != true) {
      return;
    }

    try {
      if (_activeVoiceChannel?.serverId == server.id) {
        await _leaveActiveVoiceChannel();
      }
      if (_selectedServer?.id == server.id) {
        await _selectChannel(null);
      }
      await widget.workspaceRepository.deleteServer(server.id);
      await _loadServers(selectFirstServer: true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.displayName,
    required this.onSignOut,
    required this.onOpenSettings,
  });

  final String displayName;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'ChitChat',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: onOpenSettings,
              icon: const Icon(Icons.account_circle),
              label: Text(displayName),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerRail extends StatelessWidget {
  const _ServerRail({
    required this.servers,
    required this.loading,
    required this.error,
    required this.selectedServerId,
    required this.onSelectServer,
    required this.onCreateServer,
    required this.onJoinServer,
    required this.onRefresh,
    required this.currentUserId,
    required this.onLeaveServer,
    required this.onDeleteServer,
    required this.avatarUrlForPath,
  });

  final List<ServerSummary> servers;
  final bool loading;
  final String? error;
  final String? selectedServerId;
  final Future<void> Function(ServerSummary? server) onSelectServer;
  final Future<void> Function() onCreateServer;
  final Future<void> Function() onJoinServer;
  final Future<void> Function({bool selectFirstServer}) onRefresh;
  final String currentUserId;
  final Future<void> Function(ServerSummary server) onLeaveServer;
  final Future<void> Function(ServerSummary server) onDeleteServer;
  final String? Function(String? avatarPath) avatarUrlForPath;

  Future<void> _showServerMenu(
    BuildContext context,
    Offset position,
    ServerSummary server,
  ) async {
    final isOwner = server.ownerId == currentUserId;
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: isOwner ? 'delete' : 'leave',
          child: Text(isOwner ? 'Delete server' : 'Leave server'),
        ),
      ],
    );

    if (selection == 'leave') {
      await onLeaveServer(server);
    } else if (selection == 'delete') {
      await onDeleteServer(server);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          IconButton(
            onPressed: onCreateServer,
            icon: const Icon(Icons.add_business),
            tooltip: 'Create server',
          ),
          IconButton(
            onPressed: onJoinServer,
            icon: const Icon(Icons.group_add),
            tooltip: 'Join by invite',
          ),
          IconButton(
            onPressed: () => onRefresh(selectFirstServer: false),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh servers',
          ),
          const Divider(height: 1),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(error!, textAlign: TextAlign.center),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: servers.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      final selected = server.id == selectedServerId;
                      return Tooltip(
                        message: server.name,
                        child: GestureDetector(
                          onSecondaryTapDown: (details) {
                            unawaited(
                              _showServerMenu(
                                context,
                                details.globalPosition,
                                server,
                              ),
                            );
                          },
                          child: InkWell(
                            onTap: () => onSelectServer(server),
                            mouseCursor: SystemMouseCursors.click,
                            borderRadius: BorderRadius.circular(18),
                            child: Ink(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : palette.panelStrong,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: selected
                                      ? Theme.of(context).colorScheme.secondary
                                      : palette.border,
                                  width: selected ? 4 : 1.5,
                                ),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary.withAlpha(120),
                                          blurRadius: 20,
                                          spreadRadius: 3,
                                        ),
                                      ]
                                    : const [],
                              ),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(15),
                                      child: _ServerAvatar(
                                        name: server.name,
                                        avatarUrl: avatarUrlForPath(
                                          server.avatarPath,
                                        ),
                                        selected: selected,
                                      ),
                                    ),
                                  ),
                                  if (selected)
                                    Positioned(
                                      left: -1,
                                      top: 14,
                                      bottom: 14,
                                      child: Container(
                                        width: 6,
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.secondary,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ServerAvatar extends StatelessWidget {
  const _ServerAvatar({
    required this.name,
    required this.avatarUrl,
    required this.selected,
  });

  final String name;
  final String? avatarUrl;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: selected
          ? Theme.of(context).colorScheme.primary
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          name.characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: selected
                ? Theme.of(context).colorScheme.onPrimary
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );

    if (avatarUrl == null) {
      return fallback;
    }

    return Image.network(
      avatarUrl!,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}

class _ChannelSidebar extends StatelessWidget {
  const _ChannelSidebar({
    required this.server,
    required this.categories,
    required this.channels,
    required this.loading,
    required this.loadingAccess,
    required this.error,
    required this.access,
    required this.selectedChannelId,
    required this.activeVoiceChannelId,
    required this.activeVoiceParticipants,
    required this.onSelectChannel,
    required this.onRenameCategory,
    required this.onReorderCategories,
    required this.onReorderChannels,
    required this.onOpenSettings,
  });

  final ServerSummary? server;
  final List<ChannelCategorySummary> categories;
  final List<ChannelSummary> channels;
  final bool loading;
  final bool loadingAccess;
  final String? error;
  final ServerAccess? access;
  final String? selectedChannelId;
  final String? activeVoiceChannelId;
  final List<VoiceParticipant> activeVoiceParticipants;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(ChannelCategorySummary category) onRenameCategory;
  final Future<void> Function(int oldIndex, int newIndex) onReorderCategories;
  final Future<void> Function(String? categoryId, int oldIndex, int newIndex)
  onReorderChannels;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final selectedServer = server;
    final serverAccess = access;
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final canManageChannels =
        serverAccess?.hasPermission(ServerPermission.manageChannels) ?? false;
    final isOwner =
        selectedServer?.ownerId ==
        Supabase.instance.client.auth.currentUser?.id;
    final canOpenSettings =
        (!loadingAccess && isOwner) ||
        (serverAccess?.hasPermission(ServerPermission.inviteMembers) ??
            false) ||
        (serverAccess?.hasPermission(ServerPermission.manageServer) ?? false) ||
        (serverAccess?.hasPermission(ServerPermission.manageRoles) ?? false) ||
        (serverAccess?.hasPermission(ServerPermission.manageChannels) ?? false);
    final uncategorizedChannels = channels
        .where((channel) => channel.categoryId == null)
        .toList();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: selectedServer == null
          ? const _EmptyState(
              title: 'No server selected',
              message: 'Create a server or join one with an invite code.',
            )
          : Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selectedServer.name,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: canOpenSettings ? onOpenSettings : null,
                      icon: loadingAccess
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.settings),
                      label: const Text('Server settings'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (error != null) Text(error!),
                  if (loading)
                    const Expanded(
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...[
                    Expanded(
                      child: channels.isEmpty && categories.isEmpty
                          ? const Center(
                              child: Text('This server has no channels yet.'),
                            )
                          : ListView(
                              children: [
                                if (uncategorizedChannels.isNotEmpty) ...[
                                  const _CategoryHeader(title: 'Channels'),
                                  const SizedBox(height: 8),
                                  _ChannelList(
                                    categoryId: null,
                                    channels: uncategorizedChannels,
                                    selectedChannelId: selectedChannelId,
                                    activeVoiceChannelId: activeVoiceChannelId,
                                    activeVoiceParticipants:
                                        activeVoiceParticipants,
                                    canManageChannels: canManageChannels,
                                    onSelectChannel: onSelectChannel,
                                    onReorderChannels: onReorderChannels,
                                  ),
                                  const SizedBox(height: 14),
                                ],
                                if (categories.isNotEmpty)
                                  ReorderableListView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    buildDefaultDragHandles: false,
                                    itemCount: categories.length,
                                    onReorder: (oldIndex, newIndex) {
                                      unawaited(
                                        onReorderCategories(oldIndex, newIndex),
                                      );
                                    },
                                    itemBuilder: (context, index) {
                                      final category = categories[index];
                                      final categoryChannels = channels
                                          .where(
                                            (channel) =>
                                                channel.categoryId ==
                                                category.id,
                                          )
                                          .toList();
                                      return Padding(
                                        key: ValueKey<String>(category.id),
                                        padding: const EdgeInsets.only(
                                          bottom: 14,
                                        ),
                                        child: _CategorySection(
                                          category: category,
                                          channels: categoryChannels,
                                          selectedChannelId: selectedChannelId,
                                          activeVoiceChannelId:
                                              activeVoiceChannelId,
                                          activeVoiceParticipants:
                                              activeVoiceParticipants,
                                          canManageChannels: canManageChannels,
                                          onRenameCategory: () =>
                                              onRenameCategory(category),
                                          onSelectChannel: onSelectChannel,
                                          onReorderChannels: onReorderChannels,
                                          reorderHandle: canManageChannels
                                              ? ReorderableDragStartListener(
                                                  index: index,
                                                  child: const Icon(
                                                    Icons.drag_indicator,
                                                    size: 18,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.channels,
    required this.selectedChannelId,
    required this.activeVoiceChannelId,
    required this.activeVoiceParticipants,
    required this.canManageChannels,
    required this.onRenameCategory,
    required this.onSelectChannel,
    required this.onReorderChannels,
    this.reorderHandle,
  });

  final ChannelCategorySummary category;
  final List<ChannelSummary> channels;
  final String? selectedChannelId;
  final String? activeVoiceChannelId;
  final List<VoiceParticipant> activeVoiceParticipants;
  final bool canManageChannels;
  final VoidCallback onRenameCategory;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(String? categoryId, int oldIndex, int newIndex)
  onReorderChannels;
  final Widget? reorderHandle;

  @override
  Widget build(BuildContext context) {
    final headerActions = <Widget>[];
    if (canManageChannels) {
      headerActions.add(
        IconButton(
          onPressed: onRenameCategory,
          icon: const Icon(Icons.edit_outlined, size: 18),
          tooltip: 'Rename category',
        ),
      );
    }
    if (reorderHandle != null) {
      headerActions.add(reorderHandle!);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CategoryHeader(
          title: category.name,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: headerActions,
          ),
        ),
        const SizedBox(height: 8),
        _ChannelList(
          categoryId: category.id,
          channels: channels,
          selectedChannelId: selectedChannelId,
          activeVoiceChannelId: activeVoiceChannelId,
          activeVoiceParticipants: activeVoiceParticipants,
          canManageChannels: canManageChannels,
          onSelectChannel: onSelectChannel,
          onReorderChannels: onReorderChannels,
        ),
      ],
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final rowChildren = <Widget>[
      Expanded(
        child: Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ];
    if (trailing != null) {
      rowChildren.add(trailing!);
    }
    return Row(children: rowChildren);
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.categoryId,
    required this.channels,
    required this.selectedChannelId,
    required this.activeVoiceChannelId,
    required this.activeVoiceParticipants,
    required this.canManageChannels,
    required this.onSelectChannel,
    required this.onReorderChannels,
  });

  final String? categoryId;
  final List<ChannelSummary> channels;
  final String? selectedChannelId;
  final String? activeVoiceChannelId;
  final List<VoiceParticipant> activeVoiceParticipants;
  final bool canManageChannels;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(String? categoryId, int oldIndex, int newIndex)
  onReorderChannels;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return Text(
        'No channels here yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: channels.length,
      onReorder: canManageChannels
          ? (oldIndex, newIndex) {
              unawaited(onReorderChannels(categoryId, oldIndex, newIndex));
            }
          : (oldIndex, newIndex) {},
      itemBuilder: (context, index) {
        final channel = channels[index];
        return Padding(
          key: ValueKey<String>(channel.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: _ChannelTile(
            channel: channel,
            selected: channel.id == selectedChannelId,
            activeVoiceChannelId: activeVoiceChannelId,
            activeVoiceParticipants: activeVoiceParticipants,
            onTap: () => onSelectChannel(channel),
            trailing: canManageChannels
                ? ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_indicator, size: 18),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.activeVoiceChannelId,
    required this.activeVoiceParticipants,
    required this.onTap,
    this.trailing,
  });

  final ChannelSummary channel;
  final bool selected;
  final String? activeVoiceChannelId;
  final List<VoiceParticipant> activeVoiceParticipants;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final icon = channel.kind == ChannelKind.text
        ? Icons.chat_bubble_outline
        : Icons.volume_up;
    final rowChildren = <Widget>[
      Icon(icon, size: 18),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          channel.name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    ];
    if (trailing != null) {
      rowChildren.add(trailing!);
    }
    final showVoiceParticipants =
        channel.kind == ChannelKind.voice &&
        activeVoiceChannelId == channel.id &&
        activeVoiceParticipants.isNotEmpty;

    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? palette.panelAccent : palette.panelStrong,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.secondary
                : palette.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: rowChildren),
            if (showVoiceParticipants) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: activeVoiceParticipants
                      .map(
                        (participant) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: palette.panel,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: palette.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                participant.isMuted
                                    ? Icons.mic_off
                                    : participant.shareKind == ShareKind.screen
                                    ? Icons.screen_share
                                    : participant.shareKind == ShareKind.camera
                                    ? Icons.videocam
                                    : Icons.mic,
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                participant.isSelf
                                    ? '${participant.displayName} (you)'
                                    : participant.displayName,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (participant.isSpeaking) ...[
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.mic,
                                  size: 14,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class TextChannelView extends StatefulWidget {
  const TextChannelView({
    super.key,
    required this.channel,
    required this.repository,
    required this.canSendMessages,
    required this.motionDuration,
    required this.animateMessages,
  });

  final ChannelSummary channel;
  final WorkspaceRepository repository;
  final bool canSendMessages;
  final Duration motionDuration;
  final bool animateMessages;

  @override
  State<TextChannelView> createState() => _TextChannelViewState();
}

class _TextChannelViewState extends State<TextChannelView> {
  final TextEditingController _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!widget.canSendMessages) {
      return;
    }
    final text = _messageController.text;
    _messageController.clear();
    await widget.repository.sendChannelMessage(
      channelId: widget.channel.id,
      body: text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '# ${widget.channel.name}',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<List<ChannelMessage>>(
                stream: widget.repository.watchChannelMessages(
                  widget.channel.id,
                ),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(snapshot.error.toString()));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final messages = snapshot.data!;
                  if (messages.isEmpty) {
                    return const Center(
                      child: Text('No messages yet. Start the conversation.'),
                    );
                  }
                  return ListView.separated(
                    itemCount: messages.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _AnimatedMessageTile(
                        key: ValueKey<String>(message.id),
                        animate: widget.animateMessages,
                        duration: widget.motionDuration,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: palette.panelStrong,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    message.senderDisplayName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _formatTime(message.createdAt),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(message.body),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        unawaited(_send());
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _messageController,
                      enabled: widget.canSendMessages,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: widget.canSendMessages
                            ? 'Type a channel message...'
                            : 'Your role cannot send messages in this server.',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: widget.canSendMessages ? _send : null,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedMessageTile extends StatefulWidget {
  const _AnimatedMessageTile({
    super.key,
    required this.child,
    required this.animate,
    required this.duration,
  });

  final Widget child;
  final bool animate;
  final Duration duration;

  @override
  State<_AnimatedMessageTile> createState() => _AnimatedMessageTileState();
}

class _AnimatedMessageTileState extends State<_AnimatedMessageTile> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    if (widget.animate && widget.duration > Duration.zero) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _visible = true;
          });
        }
      });
    } else {
      _visible = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate || widget.duration == Duration.zero) {
      return widget.child;
    }

    return AnimatedSlide(
      duration: widget.duration,
      offset: _visible ? Offset.zero : const Offset(0, 0.08),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        duration: widget.duration,
        opacity: _visible ? 1 : 0,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

// ignore: unused_element
class _LegacyVoiceChannelView extends StatelessWidget {
  const _LegacyVoiceChannelView({
    required this.channel,
    required this.repository,
    required this.controller,
    required this.canJoinVoice,
    required this.canManageServer,
    required this.canStreamCamera,
    required this.canShareScreen,
  });

  final ChannelSummary channel;
  final WorkspaceRepository repository;
  final VoiceChannelSessionController? controller;
  final bool canJoinVoice;
  final bool canManageServer;
  final bool canStreamCamera;
  final bool canShareScreen;

  Future<void> _showParticipantMenu(
    BuildContext context,
    Offset position,
    VoiceChannelSessionController voiceController,
    VoiceParticipant participant,
  ) async {
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'profile',
          child: Text('View profile'),
        ),
        PopupMenuItem<String>(
          value: voiceController.isParticipantMutedLocally(participant.clientId)
              ? 'unmute_local'
              : 'mute_local',
          child: Text(
            voiceController.isParticipantMutedLocally(participant.clientId)
                ? 'Unmute locally'
                : 'Mute locally',
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'volume_25',
          child: Text('Volume 25%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_50',
          child: Text('Volume 50%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_100',
          child: Text('Volume 100%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_150',
          child: Text('Volume 150%'),
        ),
        if (canManageServer && !participant.isSelf) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'kick',
            child: Text('Kick from server'),
          ),
        ],
      ],
    );

    if (selection == null || !context.mounted) {
      return;
    }

    switch (selection) {
      case 'profile':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(participant.displayName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('User ID: ${participant.userId}'),
                const SizedBox(height: 8),
                Text('Current media: ${participant.shareKind.name}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      case 'mute_local':
        await voiceController.setParticipantVolume(participant.clientId, 0);
      case 'unmute_local':
        await voiceController.setParticipantVolume(participant.clientId, 1);
      case 'volume_25':
        await voiceController.setParticipantVolume(participant.clientId, 0.25);
      case 'volume_50':
        await voiceController.setParticipantVolume(participant.clientId, 0.5);
      case 'volume_100':
        await voiceController.setParticipantVolume(participant.clientId, 1);
      case 'volume_150':
        await voiceController.setParticipantVolume(participant.clientId, 1.5);
      case 'kick':
        await repository.removeMemberFromServer(
          serverId: channel.serverId,
          userId: participant.userId,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final voiceController = controller;
    if (voiceController == null) {
      return const _EmptyState(
        title: 'Loading voice channel',
        message: 'Preparing the voice session.',
      );
    }

    return AnimatedBuilder(
      animation: voiceController,
      builder: (context, _) {
        final palette = Theme.of(context).extension<AppThemePalette>()!;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: palette.panelMuted,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: palette.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Voice: ${channel.name}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Chip(label: Text(voiceController.status)),
                  ],
                ),
                const SizedBox(height: 16),
                if (!voiceController.joined)
                  FilledButton.tonalIcon(
                    onPressed: canJoinVoice ? voiceController.join : null,
                    icon: const Icon(Icons.call),
                    label: const Text('Join call'),
                  )
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      IconButton.filledTonal(
                        onPressed: voiceController.toggleMute,
                        tooltip: voiceController.muted
                            ? 'Unmute microphone'
                            : 'Mute microphone',
                        icon: Icon(
                          voiceController.muted ? Icons.mic_off : Icons.mic,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: voiceController.toggleDeafen,
                        tooltip: voiceController.deafened
                            ? 'Undeafen'
                            : 'Deafen',
                        icon: Icon(
                          voiceController.deafened
                              ? Icons.hearing_disabled
                              : Icons.hearing,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: canStreamCamera
                            ? (voiceController.shareKind == ShareKind.camera
                                  ? voiceController.stopVisualShare
                                  : voiceController.startCameraShare)
                            : null,
                        tooltip: voiceController.shareKind == ShareKind.camera
                            ? 'Stop camera'
                            : 'Toggle camera',
                        icon: Icon(
                          voiceController.shareKind == ShareKind.camera
                              ? Icons.videocam_off
                              : Icons.videocam,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: canShareScreen && WebRTC.platformIsDesktop
                            ? () async {
                                if (voiceController.shareKind ==
                                    ShareKind.screen) {
                                  await voiceController.stopVisualShare();
                                  return;
                                }
                                final selection =
                                    await showDialog<_ScreenShareSelection>(
                                      context: context,
                                      builder: (context) =>
                                          ScreenSourcePickerDialog(
                                            controller: voiceController,
                                          ),
                                    );
                                if (selection != null) {
                                  await voiceController.startScreenShare(
                                    selection.source,
                                    maxWidth: selection.preset.width,
                                    maxHeight: selection.preset.height,
                                    frameRate: selection.preset.frameRate,
                                    captureSystemAudio:
                                        selection.captureSystemAudio,
                                  );
                                }
                              }
                            : null,
                        tooltip: voiceController.shareKind == ShareKind.screen
                            ? 'Stop screen share'
                            : 'Share screen',
                        icon: Icon(
                          voiceController.shareKind == ShareKind.screen
                              ? Icons.stop_screen_share
                              : Icons.screen_share,
                        ),
                      ),
                      IconButton.filled(
                        onPressed: voiceController.leave,
                        tooltip: 'Leave call',
                        icon: const Icon(Icons.call_end),
                      ),
                    ],
                  ),
                const SizedBox(height: 18),
                if (!canJoinVoice)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Your current role does not have permission to join voice channels in this server.',
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: voiceController.participants
                      .map(
                        (participant) => Builder(
                          builder: (context) => GestureDetector(
                            onSecondaryTapDown: (details) {
                              unawaited(
                                _showParticipantMenu(
                                  context,
                                  details.globalPosition,
                                  voiceController,
                                  participant,
                                ),
                              );
                            },
                            child: Chip(
                              label: Text(
                                participant.isSelf
                                    ? '${participant.displayName} (you)'
                                    : participant.displayName,
                              ),
                              avatar: Icon(
                                participant.isMuted
                                    ? Icons.mic_off
                                    : participant.shareKind == ShareKind.screen
                                    ? Icons.screen_share
                                    : participant.shareKind == ShareKind.camera
                                    ? Icons.videocam
                                    : Icons.mic,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.3,
                    children: [
                      _MediaTile(
                        title: voiceController.shareKind == ShareKind.audio
                            ? 'Your voice session'
                            : 'Your live preview',
                        child: voiceController.hasLocalPreview
                            ? RTCVideoView(
                                voiceController.localRenderer,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                              )
                            : const Center(
                                child: Text(
                                  'Audio only. Start camera or screen.',
                                ),
                              ),
                      ),
                      ...voiceController.remotePeers.map(
                        (peer) => GestureDetector(
                          onSecondaryTapDown: (details) {
                            unawaited(
                              _showParticipantMenu(
                                context,
                                details.globalPosition,
                                voiceController,
                                peer.participant,
                              ),
                            );
                          },
                          child: _MediaTile(
                            title:
                                '${peer.participant.displayName} • ${(voiceController.participantVolume(peer.participant.clientId) * 100).round()}%',
                            child: peer.hasMedia
                                ? RTCVideoView(
                                    peer.renderer,
                                    objectFit: RTCVideoViewObjectFit
                                        .RTCVideoViewObjectFitCover,
                                  )
                                : const Center(
                                    child: Text('Waiting for media...'),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.panelStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: palette.panel,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(title),
            ),
          ),
        ],
      ),
    );
  }
}

class VoiceChannelView extends StatefulWidget {
  const VoiceChannelView({
    super.key,
    required this.channel,
    required this.repository,
    required this.controller,
    required this.activeChannelId,
    required this.canJoinVoice,
    required this.canManageServer,
    required this.canStreamCamera,
    required this.canShareScreen,
    required this.onJoinCall,
    required this.onLeaveCall,
    this.fullscreenMode = false,
  });

  final ChannelSummary channel;
  final WorkspaceRepository repository;
  final VoiceChannelSessionController? controller;
  final String? activeChannelId;
  final bool canJoinVoice;
  final bool canManageServer;
  final bool canStreamCamera;
  final bool canShareScreen;
  final Future<void> Function() onJoinCall;
  final Future<void> Function() onLeaveCall;
  final bool fullscreenMode;

  @override
  State<VoiceChannelView> createState() => _VoiceChannelViewState();
}

class _VoiceChannelViewState extends State<VoiceChannelView> {
  String? _focusedParticipantClientId;

  Future<void> _openFullscreen(BuildContext context) async {
    final voiceController = widget.controller;
    if (voiceController == null) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _FullscreenVoiceCallPage(
          channel: widget.channel,
          repository: widget.repository,
          controller: voiceController,
          activeChannelId: widget.activeChannelId,
          canJoinVoice: widget.canJoinVoice,
          canManageServer: widget.canManageServer,
          canStreamCamera: widget.canStreamCamera,
          canShareScreen: widget.canShareScreen,
          onJoinCall: widget.onJoinCall,
          onLeaveCall: widget.onLeaveCall,
        ),
      ),
    );
  }

  Future<void> _showParticipantMenu(
    BuildContext context,
    Offset position,
    VoiceChannelSessionController voiceController,
    VoiceParticipant participant,
  ) async {
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'profile',
          child: Text('View profile'),
        ),
        PopupMenuItem<String>(
          value: voiceController.isParticipantMutedLocally(participant.clientId)
              ? 'unmute_local'
              : 'mute_local',
          child: Text(
            voiceController.isParticipantMutedLocally(participant.clientId)
                ? 'Unmute locally'
                : 'Mute locally',
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'volume_25',
          child: Text('Volume 25%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_50',
          child: Text('Volume 50%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_100',
          child: Text('Volume 100%'),
        ),
        const PopupMenuItem<String>(
          value: 'volume_150',
          child: Text('Volume 150%'),
        ),
        if (widget.canManageServer && !participant.isSelf) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'kick',
            child: Text('Kick from server'),
          ),
        ],
      ],
    );

    if (selection == null || !context.mounted) {
      return;
    }

    switch (selection) {
      case 'profile':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(participant.displayName),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('User ID: ${participant.userId}'),
                const SizedBox(height: 8),
                Text('Current media: ${participant.shareKind.name}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      case 'mute_local':
        await voiceController.setParticipantVolume(participant.clientId, 0);
      case 'unmute_local':
        await voiceController.setParticipantVolume(participant.clientId, 1);
      case 'volume_25':
        await voiceController.setParticipantVolume(participant.clientId, 0.25);
      case 'volume_50':
        await voiceController.setParticipantVolume(participant.clientId, 0.5);
      case 'volume_100':
        await voiceController.setParticipantVolume(participant.clientId, 1);
      case 'volume_150':
        await voiceController.setParticipantVolume(participant.clientId, 1.5);
      case 'kick':
        await widget.repository.removeMemberFromServer(
          serverId: widget.channel.serverId,
          userId: participant.userId,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final voiceController = widget.controller;
    if (voiceController == null) {
      return const _EmptyState(
        title: 'Loading voice channel',
        message: 'Preparing the voice session.',
      );
    }

    return AnimatedBuilder(
      animation: voiceController,
      builder: (context, _) {
        final palette = Theme.of(context).extension<AppThemePalette>()!;
        final selfParticipant = voiceController.participants
            .where((participant) => participant.isSelf)
            .firstOrNull;
        final participantTiles = <_ParticipantStageModel>[
          _ParticipantStageModel(
            clientId: voiceController.clientId,
            title: selfParticipant == null
                ? 'You'
                : '${selfParticipant.displayName} (you)',
            subtitle: voiceController.shareKind == ShareKind.audio
                ? 'Audio only'
                : voiceController.shareKind == ShareKind.camera
                ? 'Camera live'
                : 'Screen sharing',
            renderer: voiceController.hasLocalPreview
                ? voiceController.localRenderer
                : null,
            hasVideo: voiceController.hasLocalPreview,
            shareKind: voiceController.shareKind,
            isMuted: voiceController.muted,
            participant: selfParticipant,
            isSelf: true,
            volume: null,
            isSpeaking: selfParticipant?.isSpeaking ?? false,
          ),
          ...voiceController.remotePeers.map(
            (peer) => _ParticipantStageModel(
              clientId: peer.participant.clientId,
              title: peer.participant.displayName,
              subtitle: peer.participant.shareKind == ShareKind.audio
                  ? 'Audio only'
                  : peer.participant.shareKind == ShareKind.camera
                  ? 'Camera live'
                  : 'Screen sharing',
              renderer: peer.hasMedia ? peer.renderer : null,
              hasVideo: peer.hasMedia,
              shareKind: peer.participant.shareKind,
              isMuted: peer.participant.isMuted,
              participant: peer.participant,
              isSelf: false,
              volume: voiceController.participantVolume(
                peer.participant.clientId,
              ),
              isSpeaking: peer.participant.isSpeaking,
            ),
          ),
        ];
        final focusedTile = participantTiles
            .where((tile) => tile.clientId == _focusedParticipantClientId)
            .firstOrNull;
        final joinedInThisChannel =
            widget.activeChannelId == widget.channel.id &&
            voiceController.joined;

        return DecoratedBox(
          decoration: BoxDecoration(
            color: palette.panelMuted,
            borderRadius: BorderRadius.circular(widget.fullscreenMode ? 0 : 28),
            border: Border.all(color: palette.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Voice: ${widget.channel.name}',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 16),
                if (!joinedInThisChannel)
                  FilledButton.tonalIcon(
                    onPressed: widget.canJoinVoice && !voiceController.busy
                        ? widget.onJoinCall
                        : null,
                    icon: voiceController.busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.call),
                    label: Text(
                      voiceController.busy ? 'Connecting...' : 'Join call',
                    ),
                  )
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      IconButton.filledTonal(
                        onPressed: voiceController.toggleMute,
                        tooltip: voiceController.muted
                            ? 'Unmute microphone'
                            : 'Mute microphone',
                        icon: Icon(
                          voiceController.muted ? Icons.mic_off : Icons.mic,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: voiceController.toggleDeafen,
                        tooltip: voiceController.deafened
                            ? 'Undeafen'
                            : 'Deafen',
                        icon: Icon(
                          voiceController.deafened
                              ? Icons.hearing_disabled
                              : Icons.hearing,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: widget.canStreamCamera
                            ? (voiceController.shareKind == ShareKind.camera
                                  ? voiceController.stopVisualShare
                                  : voiceController.startCameraShare)
                            : null,
                        tooltip: voiceController.shareKind == ShareKind.camera
                            ? 'Stop camera'
                            : 'Toggle camera',
                        icon: Icon(
                          voiceController.shareKind == ShareKind.camera
                              ? Icons.videocam_off
                              : Icons.videocam,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed:
                            widget.canShareScreen && WebRTC.platformIsDesktop
                            ? () async {
                                if (voiceController.shareKind ==
                                    ShareKind.screen) {
                                  await voiceController.stopVisualShare();
                                  return;
                                }
                                final selection =
                                    await showDialog<_ScreenShareSelection>(
                                      context: context,
                                      builder: (context) =>
                                          ScreenSourcePickerDialog(
                                            controller: voiceController,
                                          ),
                                    );
                                if (selection != null) {
                                  await voiceController.startScreenShare(
                                    selection.source,
                                    maxWidth: selection.preset.width,
                                    maxHeight: selection.preset.height,
                                    frameRate: selection.preset.frameRate,
                                    captureSystemAudio:
                                        selection.captureSystemAudio,
                                  );
                                }
                              }
                            : null,
                        tooltip: voiceController.shareKind == ShareKind.screen
                            ? 'Stop screen share'
                            : 'Share screen',
                        icon: Icon(
                          voiceController.shareKind == ShareKind.screen
                              ? Icons.stop_screen_share
                              : Icons.screen_share,
                        ),
                      ),
                      IconButton.filled(
                        onPressed: widget.onLeaveCall,
                        tooltip: 'Leave call',
                        icon: const Icon(Icons.call_end),
                      ),
                    ],
                  ),
                const SizedBox(height: 18),
                if (!widget.canJoinVoice)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Your current role does not have permission to join voice channels in this server.',
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: !joinedInThisChannel
                            ? const _EmptyState(
                                title: 'Voice ready',
                                message:
                                    'Join the call to show the live participant stage.',
                              )
                            : focusedTile == null
                            ? _ParticipantGrid(
                                participants: participantTiles,
                                onVolumeChangedParticipant:
                                    (participant, value) {
                                      final remoteParticipant =
                                          participant.participant;
                                      if (participant.isSelf ||
                                          remoteParticipant == null) {
                                        return;
                                      }
                                      unawaited(
                                        voiceController.setParticipantVolume(
                                          remoteParticipant.clientId,
                                          value,
                                        ),
                                      );
                                    },
                                onTapParticipant: (participant) {
                                  setState(() {
                                    _focusedParticipantClientId =
                                        participant.clientId;
                                  });
                                },
                                onSecondaryTapParticipant:
                                    (participant, details) {
                                      if (participant.participant == null) {
                                        return;
                                      }
                                      unawaited(
                                        _showParticipantMenu(
                                          context,
                                          details.globalPosition,
                                          voiceController,
                                          participant.participant!,
                                        ),
                                      );
                                    },
                              )
                            : _FocusedParticipantLayout(
                                focused: focusedTile,
                                others: participantTiles
                                    .where(
                                      (participant) =>
                                          participant.clientId !=
                                          focusedTile.clientId,
                                    )
                                    .toList(),
                                onClearFocus: () {
                                  setState(() {
                                    _focusedParticipantClientId = null;
                                  });
                                },
                                onVolumeChangedParticipant:
                                    (participant, value) {
                                      final remoteParticipant =
                                          participant.participant;
                                      if (participant.isSelf ||
                                          remoteParticipant == null) {
                                        return;
                                      }
                                      unawaited(
                                        voiceController.setParticipantVolume(
                                          remoteParticipant.clientId,
                                          value,
                                        ),
                                      );
                                    },
                                onTapParticipant: (participant) {
                                  setState(() {
                                    _focusedParticipantClientId =
                                        participant.clientId;
                                  });
                                },
                                onSecondaryTapParticipant:
                                    (participant, details) {
                                      if (participant.participant == null) {
                                        return;
                                      }
                                      unawaited(
                                        _showParticipantMenu(
                                          context,
                                          details.globalPosition,
                                          voiceController,
                                          participant.participant!,
                                        ),
                                      );
                                    },
                              ),
                      ),
                      if (joinedInThisChannel)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: IconButton.filledTonal(
                            onPressed: widget.fullscreenMode
                                ? () => Navigator.of(context).pop()
                                : () => _openFullscreen(context),
                            tooltip: widget.fullscreenMode
                                ? 'Exit full screen'
                                : 'Full screen',
                            icon: Icon(
                              widget.fullscreenMode
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ParticipantStageModel {
  const _ParticipantStageModel({
    required this.clientId,
    required this.title,
    required this.subtitle,
    required this.renderer,
    required this.hasVideo,
    required this.shareKind,
    required this.isMuted,
    required this.participant,
    required this.isSelf,
    required this.volume,
    required this.isSpeaking,
  });

  final String clientId;
  final String title;
  final String subtitle;
  final RTCVideoRenderer? renderer;
  final bool hasVideo;
  final ShareKind shareKind;
  final bool isMuted;
  final VoiceParticipant? participant;
  final bool isSelf;
  final double? volume;
  final bool isSpeaking;
}

class _ParticipantGrid extends StatelessWidget {
  const _ParticipantGrid({
    required this.participants,
    required this.onVolumeChangedParticipant,
    required this.onTapParticipant,
    required this.onSecondaryTapParticipant,
  });

  final List<_ParticipantStageModel> participants;
  final void Function(_ParticipantStageModel participant, double value)
  onVolumeChangedParticipant;
  final ValueChanged<_ParticipantStageModel> onTapParticipant;
  final void Function(
    _ParticipantStageModel participant,
    TapDownDetails details,
  )
  onSecondaryTapParticipant;

  @override
  Widget build(BuildContext context) {
    final count = participants.length;
    final crossAxisCount = count <= 1
        ? 1
        : count == 2
        ? 2
        : count <= 4
        ? 2
        : 3;

    return GridView.builder(
      itemCount: participants.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: count == 1 ? 1.9 : 1.32,
      ),
      itemBuilder: (context, index) {
        final participant = participants[index];
        return _ParticipantStageTile(
          participant: participant,
          onVolumeChanged: (value) =>
              onVolumeChangedParticipant(participant, value),
          onTap: () => onTapParticipant(participant),
          onSecondaryTapDown: (details) =>
              onSecondaryTapParticipant(participant, details),
        );
      },
    );
  }
}

class _FocusedParticipantLayout extends StatelessWidget {
  const _FocusedParticipantLayout({
    required this.focused,
    required this.others,
    required this.onClearFocus,
    required this.onVolumeChangedParticipant,
    required this.onTapParticipant,
    required this.onSecondaryTapParticipant,
  });

  final _ParticipantStageModel focused;
  final List<_ParticipantStageModel> others;
  final VoidCallback onClearFocus;
  final void Function(_ParticipantStageModel participant, double value)
  onVolumeChangedParticipant;
  final ValueChanged<_ParticipantStageModel> onTapParticipant;
  final void Function(
    _ParticipantStageModel participant,
    TapDownDetails details,
  )
  onSecondaryTapParticipant;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _ParticipantStageTile(
            participant: focused,
            onVolumeChanged: (value) =>
                onVolumeChangedParticipant(focused, value),
            onTap: onClearFocus,
            onSecondaryTapDown: (details) =>
                onSecondaryTapParticipant(focused, details),
          ),
        ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 136,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: others.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final participant = others[index];
                return SizedBox(
                  width: 220,
                  child: _ParticipantStageTile(
                    participant: participant,
                    compact: true,
                    onVolumeChanged: (value) =>
                        onVolumeChangedParticipant(participant, value),
                    onTap: () => onTapParticipant(participant),
                    onSecondaryTapDown: (details) =>
                        onSecondaryTapParticipant(participant, details),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _ParticipantStageTile extends StatelessWidget {
  const _ParticipantStageTile({
    required this.participant,
    required this.onVolumeChanged,
    required this.onTap,
    required this.onSecondaryTapDown,
    this.compact = false,
  });

  final _ParticipantStageModel participant;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final statusIcon = participant.isMuted
        ? Icons.mic_off
        : participant.shareKind == ShareKind.screen
        ? Icons.screen_share
        : participant.shareKind == ShareKind.camera
        ? Icons.videocam
        : Icons.mic;

    return GestureDetector(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Container(
        decoration: BoxDecoration(
          color: palette.panelStrong,
          borderRadius: BorderRadius.circular(compact ? 18 : 24),
          border: Border.all(
            color: participant.isSpeaking
                ? Theme.of(context).colorScheme.secondary
                : palette.border,
            width: participant.isSpeaking ? 2.4 : 1,
          ),
          boxShadow: participant.isSpeaking
              ? [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withAlpha(70),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ]
              : const [],
        ),
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                color: Colors.black,
                child: participant.hasVideo && participant.renderer != null
                    ? Center(
                        child: RTCVideoView(
                          participant.renderer!,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        ),
                      )
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: palette.heroGradient,
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(statusIcon, size: compact ? 28 : 48),
                              const SizedBox(height: 12),
                              Text(
                                participant.shareKind == ShareKind.audio
                                    ? 'Audio only'
                                    : participant.shareKind == ShareKind.camera
                                    ? 'Camera unavailable'
                                    : 'Screen share loading',
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(14, compact ? 10 : 12, 14, 12),
              decoration: BoxDecoration(
                color: palette.panel,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(compact ? 18 : 24),
                  bottomRight: Radius.circular(compact ? 18 : 24),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(statusIcon, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              participant.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              participant.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (participant.isSpeaking) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.mic,
                          size: 16,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ],
                    ],
                  ),
                  if (!participant.isSelf && participant.volume != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          participant.volume == 0
                              ? Icons.volume_off
                              : Icons.volume_up,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: compact ? 2.5 : 3.5,
                              thumbShape: RoundSliderThumbShape(
                                enabledThumbRadius: compact ? 6 : 7,
                              ),
                              overlayShape: SliderComponentShape.noOverlay,
                            ),
                            child: Slider(
                              min: 0,
                              max: 1.5,
                              divisions: 6,
                              value: participant.volume!
                                  .clamp(0.0, 1.5)
                                  .toDouble(),
                              onChanged: onVolumeChanged,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 46,
                          child: Text(
                            '${(participant.volume! * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScreenSourcePickerDialog extends StatefulWidget {
  const ScreenSourcePickerDialog({super.key, required this.controller});

  final VoiceChannelSessionController controller;

  @override
  State<ScreenSourcePickerDialog> createState() =>
      _ScreenSourcePickerDialogState();
}

class _ScreenSourcePickerDialogState extends State<ScreenSourcePickerDialog> {
  static const List<_ScreenShareQualityPreset> _resolutionPresets =
      <_ScreenShareQualityPreset>[
        _ScreenShareQualityPreset(label: '720p', width: 1280, height: 720),
        _ScreenShareQualityPreset(label: '1080p', width: 1920, height: 1080),
        _ScreenShareQualityPreset(label: '1440p', width: 2560, height: 1440),
        _ScreenShareQualityPreset(label: '4K', width: 3840, height: 2160),
      ];
  static const List<int> _frameRateOptions = <int>[30, 60];

  bool _loading = true;
  String? _error;
  List<DesktopCapturerSource> _sources = const <DesktopCapturerSource>[];
  String? _selectedSourceId;
  _ScreenShareQualityPreset _selectedResolution = _resolutionPresets[1];
  int _selectedFrameRate = _frameRateOptions.first;
  StreamSubscription<DesktopCapturerSource>? _thumbnailSubscription;
  StreamSubscription<DesktopCapturerSource>? _nameSubscription;

  @override
  void initState() {
    super.initState();
    _thumbnailSubscription = desktopCapturer.onThumbnailChanged.stream.listen((
      _,
    ) {
      if (mounted) {
        setState(() {});
      }
    });
    _nameSubscription = desktopCapturer.onNameChanged.stream.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    unawaited(_thumbnailSubscription?.cancel());
    unawaited(_nameSubscription?.cancel());
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await widget.controller.loadScreenShareSources();
      if (!mounted) {
        return;
      }
      setState(() {
        _sources = sources;
        _loading = false;
        _selectedSourceId = sources.isEmpty ? null : sources.first.id;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Choose a screen or window',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Desktop capture sources are loaded natively through flutter_webrtc and rendered in this custom grid.',
              ),
              const SizedBox(height: 18),
              Text('Resolution', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _resolutionPresets
                    .map(
                      (preset) => ChoiceChip(
                        label: Text(preset.label),
                        selected: preset == _selectedResolution,
                        mouseCursor: SystemMouseCursors.click,
                        onSelected: (_) {
                          setState(() {
                            _selectedResolution = preset;
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
              Text('Frame rate', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _frameRateOptions
                    .map(
                      (fps) => ChoiceChip(
                        label: Text('${fps}fps'),
                        selected: fps == _selectedFrameRate,
                        mouseCursor: SystemMouseCursors.click,
                        onSelected: (_) {
                          setState(() {
                            _selectedFrameRate = fps;
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(child: Text(_error!))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final crossAxisCount = constraints.maxWidth >= 780
                              ? 3
                              : 2;
                          return GridView.builder(
                            padding: const EdgeInsets.only(bottom: 12),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: 1.08,
                                ),
                            itemCount: _sources.length,
                            itemBuilder: (context, index) {
                              final source = _sources[index];
                              final selected = source.id == _selectedSourceId;
                              return InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedSourceId = source.id;
                                  });
                                },
                                mouseCursor: SystemMouseCursors.click,
                                borderRadius: BorderRadius.circular(18),
                                child: Ink(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: selected
                                          ? palette.borderStrong
                                          : palette.border,
                                      width: selected ? 2 : 1,
                                    ),
                                    color: palette.panelStrong,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Container(
                                            width: double.infinity,
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              color: palette.panel,
                                            ),
                                            clipBehavior: Clip.antiAlias,
                                            child: source.thumbnail == null
                                                ? const Center(
                                                    child: Icon(
                                                      Icons
                                                          .desktop_windows_outlined,
                                                      size: 36,
                                                    ),
                                                  )
                                                : Image.memory(
                                                    Uint8List.fromList(
                                                      source.thumbnail!,
                                                    ),
                                                    fit: BoxFit.cover,
                                                    gaplessPlayback: true,
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          source.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          source.type.name,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _loading ? null : _loadSources,
                    child: const Text('Refresh'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _selectedSourceId == null
                        ? null
                        : () {
                            final source = _sources.firstWhere(
                              (item) => item.id == _selectedSourceId,
                            );
                            Navigator.of(context).pop(
                              _ScreenShareSelection(
                                source: source,
                                preset: _selectedResolution.copyWith(
                                  frameRate: _selectedFrameRate,
                                ),
                                captureSystemAudio: true,
                              ),
                            );
                          },
                    child: const Text('Share selected source'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScreenShareSelection {
  const _ScreenShareSelection({
    required this.source,
    required this.preset,
    required this.captureSystemAudio,
  });

  final DesktopCapturerSource source;
  final _ScreenShareQualityPreset preset;
  final bool captureSystemAudio;
}

class _FullscreenVoiceCallPage extends StatelessWidget {
  const _FullscreenVoiceCallPage({
    required this.channel,
    required this.repository,
    required this.controller,
    required this.activeChannelId,
    required this.canJoinVoice,
    required this.canManageServer,
    required this.canStreamCamera,
    required this.canShareScreen,
    required this.onJoinCall,
    required this.onLeaveCall,
  });

  final ChannelSummary channel;
  final WorkspaceRepository repository;
  final VoiceChannelSessionController controller;
  final String? activeChannelId;
  final bool canJoinVoice;
  final bool canManageServer;
  final bool canStreamCamera;
  final bool canShareScreen;
  final Future<void> Function() onJoinCall;
  final Future<void> Function() onLeaveCall;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: palette.appBackground),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: VoiceChannelView(
              channel: channel,
              repository: repository,
              controller: controller,
              activeChannelId: activeChannelId,
              canJoinVoice: canJoinVoice,
              canManageServer: canManageServer,
              canStreamCamera: canStreamCamera,
              canShareScreen: canShareScreen,
              onJoinCall: onJoinCall,
              onLeaveCall: onLeaveCall,
              fullscreenMode: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScreenShareQualityPreset {
  const _ScreenShareQualityPreset({
    required this.label,
    required this.width,
    required this.height,
    this.frameRate = 30,
  });

  final String label;
  final int width;
  final int height;
  final int frameRate;

  _ScreenShareQualityPreset copyWith({
    String? label,
    int? width,
    int? height,
    int? frameRate,
  }) {
    return _ScreenShareQualityPreset(
      label: label ?? this.label,
      width: width ?? this.width,
      height: height ?? this.height,
      frameRate: frameRate ?? this.frameRate,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.border),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime timestamp) {
  final hours = timestamp.hour.toString().padLeft(2, '0');
  final minutes = timestamp.minute.toString().padLeft(2, '0');
  return '$hours:$minutes';
}
