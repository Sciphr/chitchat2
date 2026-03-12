import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_preferences.dart';
import 'app_toast.dart';
import 'desktop_notifications.dart';
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
  late final Stream<List<DirectConversationSummary>>
  _directConversationSummariesStream;

  bool _loadingServers = true;
  bool _loadingChannels = false;
  bool _loadingServerAccess = false;
  bool _loadingMemberRoster = false;
  String? _serverError;
  String? _channelError;
  String? _memberRosterError;
  List<ServerSummary> _servers = const <ServerSummary>[];
  List<ChannelCategorySummary> _categories = const <ChannelCategorySummary>[];
  List<ChannelSummary> _channels = const <ChannelSummary>[];
  List<ServerRole> _serverRoles = const <ServerRole>[];
  List<ServerMember> _serverMembers = const <ServerMember>[];
  Set<String> _onlineMemberIds = const <String>{};
  Map<String, List<VoiceParticipant>> _voiceParticipantsByChannel =
      const <String, List<VoiceParticipant>>{};
  ServerSummary? _selectedServer;
  ChannelSummary? _selectedChannel;
  ServerAccess? _serverAccess;
  ChannelSummary? _activeVoiceChannel;
  VoiceChannelSessionController? _activeVoiceController;
  VoiceChannelSessionController? _previewVoiceController;
  RealtimeChannel? _serverPresenceChannel;
  RealtimeChannel? _serverRosterChannel;
  RealtimeChannel? _serverStructureChannel;
  RealtimeChannel? _workspaceDirectoryChannel;
  final Map<String, RealtimeChannel> _voicePresenceChannels =
      <String, RealtimeChannel>{};
  final Set<String> _pausedVoicePresenceChannelIds = <String>{};
  bool _displayNamePromptShown = false;
  bool _showDirectMessages = false;
  String? _selectedDirectConversationId;
  bool _serverDetailsPanelCollapsed = false;
  bool _directMessagesDetailsPanelCollapsed = true;
  StreamSubscription<Map<String, List<ChannelMessage>>>?
  _channelMessagesSubscription;
  Map<String, List<ChannelMessage>> _channelMessagesById =
      const <String, List<ChannelMessage>>{};
  Map<String, int> _channelUnreadCounts = const <String, int>{};
  Map<String, int> _lastChannelUnreadCounts = const <String, int>{};
  Map<String, int> _lastDirectUnreadCounts = const <String, int>{};
  String? _currentUserAvatarPath;

  @override
  void initState() {
    super.initState();
    _directConversationSummariesStream = widget.workspaceRepository
        .watchDirectConversationSummaries();
    widget.preferences.addListener(_handlePreferenceChanges);
    unawaited(_applyPreferredAudioSettings());
    unawaited(_initializeWorkspace());
  }

  @override
  void dispose() {
    widget.preferences.removeListener(_handlePreferenceChanges);
    unawaited(_channelMessagesSubscription?.cancel());
    unawaited(_activeVoiceController?.close());
    if (!identical(_previewVoiceController, _activeVoiceController)) {
      unawaited(_previewVoiceController?.close());
    }
    unawaited(_closeServerRosterChannel());
    unawaited(_closeServerStructureChannel());
    unawaited(_closeWorkspaceDirectoryChannel());
    unawaited(_closeServerPresenceChannel(resetUi: false));
    unawaited(_closeVoicePresenceChannels(resetUi: false));
    unawaited(_soundEffects.dispose());
    super.dispose();
  }

  void _handlePreferenceChanges() {
    unawaited(_applyPreferredAudioSettings());
    _recomputeChannelUnreadCounts(notify: false);
  }

  bool get _detailsPanelCollapsed => _showDirectMessages
      ? _directMessagesDetailsPanelCollapsed
      : _serverDetailsPanelCollapsed;

  void _setDetailsPanelCollapsed(bool value) {
    setState(() {
      if (_showDirectMessages) {
        _directMessagesDetailsPanelCollapsed = value;
      } else {
        _serverDetailsPanelCollapsed = value;
      }
    });
  }

  void _toggleDetailsPanel() {
    _setDetailsPanelCollapsed(!_detailsPanelCollapsed);
  }

  Future<void> _resubscribeChannelMessages() async {
    await _channelMessagesSubscription?.cancel();
    _channelMessagesSubscription = null;

    final textChannelIds = _channels
        .where((channel) => channel.kind == ChannelKind.text)
        .map((channel) => channel.id)
        .toList(growable: false);
    if (textChannelIds.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _channelMessagesById = const <String, List<ChannelMessage>>{};
        _channelUnreadCounts = const <String, int>{};
        _lastChannelUnreadCounts = const <String, int>{};
      });
      return;
    }

    _channelMessagesSubscription = widget.workspaceRepository
        .watchChannelsMessages(textChannelIds)
        .listen((messagesById) {
          _channelMessagesById = messagesById;
          _recomputeChannelUnreadCounts(notify: true);
        });
  }

  void _recomputeChannelUnreadCounts({required bool notify}) {
    final previousUnreadCounts = _lastChannelUnreadCounts;
    final nextUnreadCounts = <String, int>{};
    for (final channel in _channels) {
      if (channel.kind != ChannelKind.text) {
        continue;
      }
      final lastReadAt = widget.preferences.channelLastReadAt(channel.id);
      final messages =
          _channelMessagesById[channel.id] ?? const <ChannelMessage>[];
      final unreadCount = messages.where((message) {
        if (message.senderId == widget.authService.userId) {
          return false;
        }
        if (lastReadAt == null) {
          return true;
        }
        return message.createdAt.isAfter(lastReadAt);
      }).length;
      nextUnreadCounts[channel.id] = unreadCount;
    }

    final notifyChannels = notify && previousUnreadCounts.isNotEmpty
        ? _channels
              .where((channel) {
                final previousUnread = previousUnreadCounts[channel.id] ?? 0;
                final nextUnread = nextUnreadCounts[channel.id] ?? 0;
                return channel.kind == ChannelKind.text &&
                    nextUnread > previousUnread &&
                    channel.id != _selectedChannel?.id;
              })
              .toList(growable: false)
        : const <ChannelSummary>[];
    _lastChannelUnreadCounts = nextUnreadCounts;

    if (mounted && !mapEquals(_channelUnreadCounts, nextUnreadCounts)) {
      setState(() {
        _channelUnreadCounts = nextUnreadCounts;
      });
    }

    if (notifyChannels.isEmpty) {
      return;
    }

    final latestChannel = notifyChannels.last;
    final lastReadAt = widget.preferences.channelLastReadAt(latestChannel.id);
    final messages =
        _channelMessagesById[latestChannel.id] ?? const <ChannelMessage>[];
    ChannelMessage? latestUnreadMessage;
    for (final message in messages.reversed) {
      if (message.senderId == widget.authService.userId) {
        continue;
      }
      if (lastReadAt != null && !message.createdAt.isAfter(lastReadAt)) {
        continue;
      }
      latestUnreadMessage = message;
      break;
    }
    if (latestUnreadMessage == null) {
      return;
    }
    final unreadMessage = latestUnreadMessage;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _notifyActivity(
        toastMessage:
            '${unreadMessage.senderDisplayName} in #${latestChannel.name}',
        desktopTitle:
            '${unreadMessage.senderDisplayName} in #${latestChannel.name}',
        desktopBody: _messageActivityPreview(
          body: unreadMessage.body,
          attachments: unreadMessage.attachments,
          deleted: unreadMessage.deleted,
        ),
      );
    });
  }

  void _handleDirectConversationNotifications(
    List<DirectConversationSummary> conversations,
  ) {
    final nextUnreadCounts = <String, int>{
      for (final conversation in conversations)
        conversation.conversationId: conversation.unreadCount,
    };
    if (_lastDirectUnreadCounts.isEmpty) {
      _lastDirectUnreadCounts = nextUnreadCounts;
      return;
    }

    final newUnreadConversations = conversations
        .where((conversation) {
          final previousUnread =
              _lastDirectUnreadCounts[conversation.conversationId] ?? 0;
          return conversation.unreadCount > previousUnread &&
              conversation.conversationId != _selectedDirectConversationId;
        })
        .toList(growable: false);
    _lastDirectUnreadCounts = nextUnreadCounts;

    if (newUnreadConversations.isEmpty) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final latestConversation = newUnreadConversations.last;
      _notifyActivity(
        toastMessage: 'New DM from ${latestConversation.otherDisplayName}.',
        desktopTitle: 'New DM from ${latestConversation.otherDisplayName}',
        desktopBody:
            latestConversation.lastMessagePreview?.trim().isNotEmpty == true
            ? latestConversation.lastMessagePreview
            : 'Open ChitChat to read it.',
      );
    });
  }

  void _notifyActivity({
    required String toastMessage,
    required String desktopTitle,
    String? desktopBody,
  }) {
    if (widget.preferences.desktopNotifications) {
      showAppToast(context, toastMessage, tone: AppToastTone.neutral);
      unawaited(
        showDesktopNotification(title: desktopTitle, body: desktopBody),
      );
    }
    if (widget.preferences.playSounds) {
      unawaited(
        _soundEffects.play(
          UiSoundEffect.message,
          enabled: widget.preferences.playSounds,
        ),
      );
    }
  }

  Future<void> _applyPreferredAudioOutput() async {
    await _screenShareService.applyAudioOutputDevice(
      widget.preferences.preferredAudioOutputId,
    );
  }

  Future<void> _applyPreferredAudioSettings() async {
    await _applyPreferredAudioOutput();
    await _screenShareService.applyVoiceProcessingPreference(
      widget.preferences.noiseCancellation,
    );
  }

  Future<void> _closeServerPresenceChannel({bool resetUi = true}) async {
    final presenceChannel = _serverPresenceChannel;
    _serverPresenceChannel = null;
    if (resetUi && mounted) {
      setState(() {
        _onlineMemberIds = const <String>{};
      });
    }
    if (presenceChannel != null) {
      try {
        await presenceChannel.untrack();
      } on Object {
        // Best-effort cleanup while the channel is shutting down.
      }
      await Supabase.instance.client.removeChannel(presenceChannel);
    }
  }

  Future<void> _closeServerRosterChannel() async {
    final rosterChannel = _serverRosterChannel;
    _serverRosterChannel = null;
    if (rosterChannel != null) {
      await Supabase.instance.client.removeChannel(rosterChannel);
    }
  }

  Future<void> _closeServerStructureChannel() async {
    final structureChannel = _serverStructureChannel;
    _serverStructureChannel = null;
    if (structureChannel != null) {
      await Supabase.instance.client.removeChannel(structureChannel);
    }
  }

  Future<void> _closeWorkspaceDirectoryChannel() async {
    final directoryChannel = _workspaceDirectoryChannel;
    _workspaceDirectoryChannel = null;
    if (directoryChannel != null) {
      await Supabase.instance.client.removeChannel(directoryChannel);
    }
  }

  Future<void> _closeVoicePresenceChannels({bool resetUi = true}) async {
    final channels = _voicePresenceChannels.values.toList();
    _voicePresenceChannels.clear();
    _pausedVoicePresenceChannelIds.clear();
    if (resetUi && mounted) {
      setState(() {
        _voiceParticipantsByChannel = const <String, List<VoiceParticipant>>{};
      });
    }
    for (final channel in channels) {
      await Supabase.instance.client.removeChannel(channel);
    }
  }

  Future<void> _subscribeServerRoster(ServerSummary server) async {
    await _closeServerRosterChannel();
    if (!mounted || _selectedServer?.id != server.id) {
      return;
    }

    final client = Supabase.instance.client;
    final completer = Completer<void>();
    final realtimeChannel = client
        .channel('server-roster:${server.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'server_members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadServerRoster(server));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'server_member_roles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadServerRoster(server));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_profiles',
          callback: (payload) {
            if (_selectedServer?.id != server.id) {
              return;
            }
            if (_shouldRefreshRosterForProfileChange(payload)) {
              unawaited(_loadServerRoster(server));
            }
          },
        );

    realtimeChannel.subscribe((status, [error]) {
      if (completer.isCompleted) {
        return;
      }
      if (status == RealtimeSubscribeStatus.subscribed &&
          identical(_serverPresenceChannel, realtimeChannel)) {
        unawaited(_trackServerPresence());
      }
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          completer.complete();
        case RealtimeSubscribeStatus.channelError:
          completer.completeError(
            StateError(
              'Realtime roster error${error == null ? '' : ': $error'}',
            ),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(
            StateError('Realtime roster channel closed.'),
          );
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(
            StateError('Realtime roster channel timed out.'),
          );
      }
    });

    try {
      await completer.future;
      if (!mounted || _selectedServer?.id != server.id) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _serverRosterChannel = realtimeChannel;
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      if (_selectedServer?.id == server.id) {
        debugPrint(
          'Server roster subscription failed for ${server.id}: $error',
        );
      }
    }
  }

  Future<void> _subscribeWorkspaceDirectory() async {
    await _closeWorkspaceDirectoryChannel();
    if (!mounted) {
      return;
    }

    final client = Supabase.instance.client;
    final completer = Completer<void>();
    final realtimeChannel = client
        .channel('workspace-directory:${widget.authService.userId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'server_members',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: widget.authService.userId,
          ),
          callback: (_) {
            if (mounted) {
              unawaited(
                _loadServers(selectFirstServer: _selectedServer == null),
              );
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'servers',
          callback: (payload) {
            final serverId = _recordIdFromPayload(payload);
            if (serverId == null) {
              return;
            }
            final shouldRefresh =
                _selectedServer?.id == serverId ||
                _servers.any((server) => server.id == serverId);
            if (shouldRefresh && mounted) {
              unawaited(
                _loadServers(selectFirstServer: _selectedServer == null),
              );
            }
          },
        );

    realtimeChannel.subscribe((status, [error]) {
      if (completer.isCompleted) {
        return;
      }
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          completer.complete();
        case RealtimeSubscribeStatus.channelError:
          completer.completeError(
            StateError(
              'Realtime workspace directory error'
              '${error == null ? '' : ': $error'}',
            ),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(
            StateError('Realtime workspace directory channel closed.'),
          );
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(
            StateError('Realtime workspace directory channel timed out.'),
          );
      }
    });

    try {
      await completer.future;
      if (!mounted) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _workspaceDirectoryChannel = realtimeChannel;
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      debugPrint('Workspace directory subscription failed: $error');
    }
  }

  Future<void> _subscribeServerStructure(ServerSummary server) async {
    await _closeServerStructureChannel();
    if (!mounted || _selectedServer?.id != server.id) {
      return;
    }

    final client = Supabase.instance.client;
    final completer = Completer<void>();
    final realtimeChannel = client
        .channel('server-structure:${server.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'channels',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadChannels(server.id));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'channel_categories',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadChannels(server.id));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'server_roles',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadServerRoster(server));
              unawaited(_loadServerAccess(server));
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'servers',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: server.id,
          ),
          callback: (_) {
            if (_selectedServer?.id == server.id) {
              unawaited(_loadServers());
            }
          },
        );

    realtimeChannel.subscribe((status, [error]) {
      if (completer.isCompleted) {
        return;
      }
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          completer.complete();
        case RealtimeSubscribeStatus.channelError:
          completer.completeError(
            StateError(
              'Realtime server structure error'
              '${error == null ? '' : ': $error'}',
            ),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(
            StateError('Realtime server structure channel closed.'),
          );
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(
            StateError('Realtime server structure channel timed out.'),
          );
      }
    });

    try {
      await completer.future;
      if (!mounted || _selectedServer?.id != server.id) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _serverStructureChannel = realtimeChannel;
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      if (_selectedServer?.id == server.id) {
        debugPrint(
          'Server structure subscription failed for ${server.id}: $error',
        );
      }
    }
  }

  Future<void> _subscribeServerPresence(ServerSummary server) async {
    await _closeServerPresenceChannel();
    if (!mounted || _selectedServer?.id != server.id) {
      return;
    }

    final client = Supabase.instance.client;
    await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    final completer = Completer<void>();
    final realtimeChannel = client.channel(
      _serverPresenceTopic(server.id),
      opts: RealtimeChannelConfig(
        ack: true,
        enabled: true,
        key: widget.authService.userId,
        private: true,
      ),
    );

    realtimeChannel
      ..onPresenceSync((_) => _syncServerPresence(realtimeChannel))
      ..onPresenceJoin((_) => _syncServerPresence(realtimeChannel))
      ..onPresenceLeave((_) => _syncServerPresence(realtimeChannel));

    realtimeChannel.subscribe((status, [error]) {
      if (completer.isCompleted) {
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

    try {
      await completer.future;
      if (!mounted || _selectedServer?.id != server.id) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _serverPresenceChannel = realtimeChannel;
      await _trackServerPresence();
      _syncServerPresence(realtimeChannel);
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      if (!mounted || _selectedServer?.id != server.id) {
        return;
      }
      final formattedError = _formatServerPresenceError(error);
      if (formattedError != null) {
        debugPrint(
          'Server presence subscription failed for ${server.id}: $error',
        );
      }
      setState(() {
        _memberRosterError = formattedError;
      });
    }
  }

  Future<void> _trackServerPresence() async {
    await _serverPresenceChannel?.track({
      'user_id': widget.authService.userId,
      'display_name': widget.authService.displayName,
      'tracked_at': DateTime.now().toIso8601String(),
    });
  }

  void _syncServerPresence([RealtimeChannel? channel]) {
    final realtimeChannel = channel ?? _serverPresenceChannel;
    if (realtimeChannel == null || !mounted) {
      return;
    }

    final nextOnlineMemberIds = <String>{};
    for (final state in realtimeChannel.presenceState()) {
      for (final presence in state.presences) {
        final payload = presence.payload;
        final userId = payload['user_id'] as String?;
        if (userId != null && userId.isNotEmpty) {
          nextOnlineMemberIds.add(userId);
        }
      }
    }
    if (_serverMembers.any(
      (member) => member.userId == widget.authService.userId,
    )) {
      nextOnlineMemberIds.add(widget.authService.userId);
    }

    setState(() {
      _onlineMemberIds = nextOnlineMemberIds;
    });
  }

  String _serverPresenceTopic(String serverId) => 'server:presence:$serverId';

  String _voicePresenceTopic(String channelId) => 'voice:presence:$channelId';

  String? _formatServerPresenceError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('unauthorized') ||
        message.contains('permission') ||
        message.contains('read from this channel')) {
      return 'Member presence is blocked by Realtime authorization. Apply the latest Supabase migrations.';
    }
    return 'Member presence unavailable right now.';
  }

  Future<void> _syncVoicePresenceSubscriptions(
    String serverId,
    List<ChannelSummary> channels,
  ) async {
    final voiceChannels = channels
        .where(
          (channel) =>
              channel.kind == ChannelKind.voice &&
              !_pausedVoicePresenceChannelIds.contains(channel.id),
        )
        .toList();
    final desiredChannelIds = voiceChannels
        .map((channel) => channel.id)
        .toSet();

    final staleChannelIds = _voicePresenceChannels.keys
        .where((channelId) => !desiredChannelIds.contains(channelId))
        .toList();
    for (final channelId in staleChannelIds) {
      final realtimeChannel = _voicePresenceChannels.remove(channelId);
      if (realtimeChannel != null) {
        await Supabase.instance.client.removeChannel(realtimeChannel);
      }
    }
    if (staleChannelIds.isNotEmpty && mounted) {
      setState(() {
        _voiceParticipantsByChannel =
            Map<String, List<VoiceParticipant>>.from(
              _voiceParticipantsByChannel,
            )..removeWhere(
              (channelId, _) => !desiredChannelIds.contains(channelId),
            );
      });
    }

    final channelsToSubscribe = voiceChannels
        .where((channel) => !_voicePresenceChannels.containsKey(channel.id))
        .toList();
    if (channelsToSubscribe.isEmpty) {
      return;
    }

    await Future.wait<void>(
      channelsToSubscribe.map(
        (channel) => _subscribeVoicePresenceChannel(serverId, channel),
      ),
    );
  }

  Future<void> _subscribeVoicePresenceChannel(
    String serverId,
    ChannelSummary channel,
  ) async {
    if (!mounted ||
        _selectedServer?.id != serverId ||
        _voicePresenceChannels.containsKey(channel.id)) {
      return;
    }

    final client = Supabase.instance.client;
    await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    final completer = Completer<void>();
    final realtimeChannel = client.channel(
      _voicePresenceTopic(channel.id),
      opts: RealtimeChannelConfig(
        ack: true,
        enabled: true,
        key: widget.authService.userId,
        private: true,
      ),
    );

    realtimeChannel
      ..onPresenceSync((_) => _syncVoicePresence(channel.id, realtimeChannel))
      ..onPresenceJoin((_) => _syncVoicePresence(channel.id, realtimeChannel))
      ..onPresenceLeave((_) => _syncVoicePresence(channel.id, realtimeChannel));

    realtimeChannel.subscribe((status, [error]) {
      if (completer.isCompleted) {
        return;
      }
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          completer.complete();
        case RealtimeSubscribeStatus.channelError:
          completer.completeError(
            StateError(
              'Voice presence error for ${channel.id}'
              '${error == null ? '' : ': $error'}',
            ),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(
            StateError('Voice presence channel closed for ${channel.id}.'),
          );
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(
            StateError('Voice presence channel timed out for ${channel.id}.'),
          );
      }
    });

    try {
      await completer.future;
      if (!mounted ||
          _selectedServer?.id != serverId ||
          !_channels.any((item) => item.id == channel.id)) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _voicePresenceChannels[channel.id] = realtimeChannel;
      _syncVoicePresence(channel.id, realtimeChannel);
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      if (_selectedServer?.id == serverId) {
        debugPrint(
          'Voice presence subscription failed for ${channel.id}: $error',
        );
      }
    }
  }

  Future<void> _pauseVoicePresenceChannel(String channelId) async {
    _pausedVoicePresenceChannelIds.add(channelId);
    final realtimeChannel = _voicePresenceChannels.remove(channelId);
    if (realtimeChannel != null) {
      await Supabase.instance.client.removeChannel(realtimeChannel);
    }
  }

  Future<void> _resumeVoicePresenceChannel(String channelId) async {
    _pausedVoicePresenceChannelIds.remove(channelId);
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }
    final channel = _channels.firstWhere(
      (item) => item.id == channelId,
      orElse: () => ChannelSummary(
        id: '',
        serverId: '',
        categoryId: null,
        name: '',
        kind: ChannelKind.voice,
        position: 0,
        createdBy: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    if (channel.id.isEmpty || channel.kind != ChannelKind.voice) {
      return;
    }
    await _subscribeVoicePresenceChannel(selectedServer.id, channel);
  }

  void _syncVoicePresence(String channelId, RealtimeChannel realtimeChannel) {
    if (!mounted || _selectedServer == null) {
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
        final shareName =
            payload['share_kind'] as String? ?? ShareKind.audio.name;
        participants.add(
          VoiceParticipant(
            clientId: state.key,
            userId: userId,
            displayName: payload['display_name'] as String? ?? 'Anonymous',
            isSelf: false,
            isMuted: payload['muted'] as bool? ?? false,
            shareKind: _shareKindFromName(shareName),
          ),
        );
      }
    }

    participants.sort(
      (left, right) => left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      ),
    );

    setState(() {
      _voiceParticipantsByChannel = Map<String, List<VoiceParticipant>>.from(
        _voiceParticipantsByChannel,
      )..[channelId] = participants;
    });
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
    required String? categoryId,
    required int position,
  }) {
    return ChannelSummary(
      id: channel.id,
      serverId: channel.serverId,
      categoryId: categoryId,
      name: channel.name,
      kind: channel.kind,
      position: position,
      createdBy: channel.createdBy,
      createdAt: channel.createdAt,
    );
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
      preferences: widget.preferences,
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
      final previousChannelId = _activeVoiceChannel?.id;
      _activeVoiceController = null;
      _activeVoiceChannel = null;
      setState(() {});
      await previousActive?.close();
      if (previousChannelId != null) {
        await _resumeVoicePresenceChannel(previousChannelId);
      }
    }

    await _pauseVoicePresenceChannel(selectedChannel.id);
    await targetController.join();
    if (!mounted || !targetController.joined) {
      await _resumeVoicePresenceChannel(selectedChannel.id);
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
    if (activeChannel != null) {
      await _resumeVoicePresenceChannel(activeChannel.id);
    }
  }

  Future<void> _openActiveVoiceChannel() async {
    final activeChannel = _activeVoiceChannel;
    if (activeChannel == null) {
      return;
    }

    final targetServer = _servers.cast<ServerSummary?>().firstWhere(
      (server) => server?.id == activeChannel.serverId,
      orElse: () => _selectedServer,
    );
    if (targetServer != null && _selectedServer?.id != targetServer.id) {
      await _selectServer(targetServer);
    }
    if (!mounted) {
      return;
    }
    await _selectChannel(activeChannel);
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

      ServerSummary? refreshedSelectedServer = _selectedServer;
      if (_selectedServer != null) {
        for (final server in servers) {
          if (server.id == _selectedServer!.id) {
            refreshedSelectedServer = server;
            break;
          }
        }
      }

      setState(() {
        _servers = servers;
        _selectedServer = refreshedSelectedServer;
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
      final currentProfile = await widget.workspaceRepository
          .fetchCurrentUserProfile();
      if (mounted) {
        setState(() {
          _currentUserAvatarPath = currentProfile.avatarPath;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _serverError = error.toString();
        });
      }
    }
    await _subscribeWorkspaceDirectory();
    await _loadServers(selectFirstServer: true);
    if (mounted) {
      unawaited(_maybePromptForDisplayName());
    }
  }

  Future<void> _handleProfileUpdated() async {
    final currentProfile = await widget.workspaceRepository
        .fetchCurrentUserProfile();
    await _activeVoiceController?.refreshLocalParticipantProfile();
    if (!identical(_previewVoiceController, _activeVoiceController)) {
      await _previewVoiceController?.refreshLocalParticipantProfile();
    }
    await _trackServerPresence();
    final selectedServer = _selectedServer;
    if (selectedServer != null) {
      await _loadServerRoster(selectedServer);
    }
    if (mounted) {
      setState(() {
        _currentUserAvatarPath = currentProfile.avatarPath;
      });
    }
  }

  bool _shouldRefreshRosterForProfileChange(Object payload) {
    final dynamicPayload = payload as dynamic;
    final newRecord = dynamicPayload.newRecord;
    final oldRecord = dynamicPayload.oldRecord;
    String? userId;
    if (newRecord is Map && newRecord['id'] is String) {
      userId = newRecord['id'] as String;
    } else if (oldRecord is Map && oldRecord['id'] is String) {
      userId = oldRecord['id'] as String;
    }
    if (userId == null || userId.isEmpty) {
      return false;
    }
    return _serverMembers.any((member) => member.userId == userId);
  }

  String? _recordIdFromPayload(Object payload) {
    final dynamicPayload = payload as dynamic;
    final newRecord = dynamicPayload.newRecord;
    final oldRecord = dynamicPayload.oldRecord;
    if (newRecord is Map && newRecord['id'] is String) {
      return newRecord['id'] as String;
    }
    if (oldRecord is Map && oldRecord['id'] is String) {
      return oldRecord['id'] as String;
    }
    return null;
  }

  Future<void> _loadServerRoster(ServerSummary server) async {
    setState(() {
      _loadingMemberRoster = true;
      _memberRosterError = null;
    });

    try {
      final results = await Future.wait<dynamic>([
        widget.workspaceRepository.fetchServerRoles(server.id),
        widget.workspaceRepository.fetchServerMembers(server.id),
      ]);
      if (!mounted || _selectedServer?.id != server.id) {
        return;
      }
      setState(() {
        _serverRoles = results[0] as List<ServerRole>;
        _serverMembers = results[1] as List<ServerMember>;
        _loadingMemberRoster = false;
      });
      _syncServerPresence();
    } catch (error) {
      if (!mounted || _selectedServer?.id != server.id) {
        return;
      }
      setState(() {
        _memberRosterError = error.toString();
        _loadingMemberRoster = false;
      });
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
              showAppToast(
                dialogContext,
                error.toString(),
                tone: AppToastTone.error,
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
        showAppToast(
          context,
          'Display name updated.',
          tone: AppToastTone.success,
        );
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
      await _resubscribeChannelMessages();
      await _syncVoicePresenceSubscriptions(serverId, channels);

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
      if (_showDirectMessages) {
        setState(() {
          _showDirectMessages = false;
        });
      }
      return;
    }

    await _selectChannel(null);
    await _closeServerRosterChannel();
    await _closeServerStructureChannel();
    await _closeServerPresenceChannel();
    await _closeVoicePresenceChannels();
    _selectedServer = server;
    _showDirectMessages = false;
    _categories = const <ChannelCategorySummary>[];
    _channels = const <ChannelSummary>[];
    _serverRoles = const <ServerRole>[];
    _serverMembers = const <ServerMember>[];
    _voiceParticipantsByChannel = const <String, List<VoiceParticipant>>{};
    _channelMessagesById = const <String, List<ChannelMessage>>{};
    _channelUnreadCounts = const <String, int>{};
    _serverAccess = null;
    _memberRosterError = null;
    _loadingMemberRoster = server != null;
    _loadingServerAccess = server != null;
    setState(() {});

    await _channelMessagesSubscription?.cancel();
    _channelMessagesSubscription = null;

    if (server != null) {
      await Future.wait<void>([
        _loadChannels(server.id, selectFirst: true),
        _loadServerAccess(server),
        _loadServerRoster(server),
        _subscribeServerRoster(server),
        _subscribeServerStructure(server),
        _subscribeServerPresence(server),
      ]);
    }
  }

  Future<void> _openDirectMessagesHome({String? conversationId}) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _showDirectMessages = true;
      _directMessagesDetailsPanelCollapsed = true;
      if (conversationId != null) {
        _selectedDirectConversationId = conversationId;
      }
    });
  }

  Future<void> _promptStartDirectMessage() async {
    final candidates =
        _serverMembers
            .where((member) => member.userId != widget.authService.userId)
            .toList()
          ..sort(
            (left, right) => left.displayName.toLowerCase().compareTo(
              right.displayName.toLowerCase(),
            ),
          );
    if (candidates.isEmpty) {
      showAppToast(
        context,
        'Pick a server with members first to start a new direct message.',
        tone: AppToastTone.neutral,
      );
      return;
    }

    final selectedMember = await showDialog<ServerMember>(
      context: context,
      builder: (context) => _StartDirectMessageDialog(members: candidates),
    );
    if (selectedMember == null) {
      return;
    }

    await _startDirectMessage(
      userId: selectedMember.userId,
      displayName: selectedMember.displayName,
    );
  }

  Future<void> _startDirectMessage({
    required String userId,
    required String displayName,
  }) async {
    if (userId == widget.authService.userId) {
      return;
    }
    try {
      final conversationId = await widget.workspaceRepository
          .createOrGetDirectConversation(otherUserId: userId);
      if (!mounted) {
        return;
      }
      setState(() {
        _showDirectMessages = true;
        _directMessagesDetailsPanelCollapsed = true;
        _selectedDirectConversationId = conversationId;
      });
      showAppToast(
        context,
        'Opened direct messages with $displayName.',
        tone: AppToastTone.success,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    }
  }

  void _selectDirectConversation(String conversationId) {
    if (_selectedDirectConversationId == conversationId &&
        _showDirectMessages) {
      return;
    }
    setState(() {
      _showDirectMessages = true;
      _directMessagesDetailsPanelCollapsed = true;
      _selectedDirectConversationId = conversationId;
    });
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
    final result = await showDialog<_CreateServerDialogResult>(
      context: context,
      builder: (context) => const _CreateServerDialog(),
    );
    if (result == null || result.name.trim().isEmpty) {
      return;
    }

    try {
      final server = await widget.workspaceRepository.createServer(
        result.name,
        description: result.description,
        isPublic: result.isPublic,
      );
      await _loadServers();
      await _selectServer(server);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(context).pop(controller.text),
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    }
  }

  Future<void> _openServerDiscovery() async {
    final serverId = await showDialog<String>(
      context: context,
      builder: (context) => _ServerDiscoveryDialog(
        repository: widget.workspaceRepository,
        avatarUrlForPath: widget.workspaceRepository.publicServerAvatarUrl,
      ),
    );
    if (serverId == null || !mounted) {
      return;
    }
    await _loadServers();
    if (!mounted) {
      return;
    }
    ServerSummary? targetServer;
    for (final server in _servers) {
      if (server.id == serverId) {
        targetServer = server;
        break;
      }
    }
    if (targetServer != null) {
      await _selectServer(targetServer);
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    }
  }

  Future<void> _moveChannel(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  ) async {
    final selectedServer = _selectedServer;
    if (selectedServer == null) {
      return;
    }

    final previousChannels = List<ChannelSummary>.from(_channels);
    final groupedChannels = <String?, List<ChannelSummary>>{
      null: _channels.where((item) => item.categoryId == null).toList(),
      for (final category in _categories)
        category.id: _channels
            .where((item) => item.categoryId == category.id)
            .toList(),
    };

    final sourceCategoryId = channel.categoryId;
    final sourceGroup = List<ChannelSummary>.from(
      groupedChannels[sourceCategoryId] ?? const <ChannelSummary>[],
    );
    final sourceIndex = sourceGroup.indexWhere((item) => item.id == channel.id);
    if (sourceIndex == -1) {
      return;
    }
    sourceGroup.removeAt(sourceIndex);

    final targetGroup = sourceCategoryId == targetCategoryId
        ? sourceGroup
        : List<ChannelSummary>.from(
            groupedChannels[targetCategoryId] ?? const <ChannelSummary>[],
          );
    final originalTargetIndex = targetIndex.clamp(
      0,
      sourceCategoryId == targetCategoryId
          ? sourceGroup.length + 1
          : targetGroup.length,
    );
    var insertIndex = originalTargetIndex;
    if (sourceCategoryId == targetCategoryId &&
        sourceIndex < originalTargetIndex) {
      insertIndex = originalTargetIndex - 1;
    }
    insertIndex = insertIndex.clamp(0, targetGroup.length);
    final unchangedCategory =
        sourceCategoryId == targetCategoryId && sourceIndex == insertIndex;
    if (unchangedCategory) {
      return;
    }

    targetGroup.insert(
      insertIndex,
      _copyChannel(channel: channel, categoryId: targetCategoryId, position: 0),
    );

    final normalizedSource = sourceCategoryId == targetCategoryId
        ? const <ChannelSummary>[]
        : [
            for (var index = 0; index < sourceGroup.length; index++)
              _copyChannel(
                channel: sourceGroup[index],
                categoryId: sourceCategoryId,
                position: index,
              ),
          ];
    final normalizedTarget = [
      for (var index = 0; index < targetGroup.length; index++)
        _copyChannel(
          channel: targetGroup[index],
          categoryId: targetCategoryId,
          position: index,
        ),
    ];

    if (sourceCategoryId == targetCategoryId) {
      groupedChannels[targetCategoryId] = normalizedTarget;
    } else {
      groupedChannels[sourceCategoryId] = normalizedSource;
      groupedChannels[targetCategoryId] = normalizedTarget;
    }

    final updatedChannels = <ChannelSummary>[
      ...(groupedChannels[null] ?? const <ChannelSummary>[]),
      for (final category in _categories)
        ...(groupedChannels[category.id] ?? const <ChannelSummary>[]),
    ];

    setState(() {
      _channels = updatedChannels;
    });

    try {
      await widget.workspaceRepository.reorderChannels([
        for (final entry in [...normalizedSource, ...normalizedTarget])
          ChannelOrderUpdate(
            channelId: entry.id,
            position: entry.position,
            categoryId: entry.categoryId,
          ),
      ]);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _channels = previousChannels;
      });
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
    showAppToast(
      context,
      'Invite code copied to clipboard.',
      tone: AppToastTone.success,
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
    await _loadServers();
    if (!mounted) {
      return;
    }
    ServerSummary? refreshedServer = selectedServer;
    for (final server in _servers) {
      if (server.id == selectedServer.id) {
        refreshedServer = server;
        break;
      }
    }
    if (refreshedServer != null) {
      setState(() {
        _selectedServer = refreshedServer;
      });
    }
    await _loadServerAccess(refreshedServer ?? selectedServer);
    await _loadChannels((refreshedServer ?? selectedServer).id);
    await _loadServerRoster(refreshedServer ?? selectedServer);
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
    return StreamBuilder<List<DirectConversationSummary>>(
      stream: _directConversationSummariesStream,
      builder: (context, directConversationsSnapshot) {
        final directConversations =
            directConversationsSnapshot.data ??
            const <DirectConversationSummary>[];
        _handleDirectConversationNotifications(directConversations);
        final selectedDirectConversation = _selectedDirectConversationId == null
            ? null
            : directConversations.cast<DirectConversationSummary?>().firstWhere(
                (conversation) =>
                    conversation?.conversationId ==
                    _selectedDirectConversationId,
                orElse: () => null,
              );
        if (_showDirectMessages &&
            _selectedDirectConversationId == null &&
            directConversations.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                !_showDirectMessages ||
                _selectedDirectConversationId != null) {
              return;
            }
            _selectDirectConversation(directConversations.first.conversationId);
          });
        }
        final totalDirectUnreadCount = directConversations.fold<int>(
          0,
          (sum, conversation) => sum + conversation.unreadCount,
        );
        final activeVoiceController = _activeVoiceController;
        final voiceParticipantsByChannel =
            Map<String, List<VoiceParticipant>>.from(
              _voiceParticipantsByChannel,
            );
        if (activeVoiceController != null && _activeVoiceChannel != null) {
          final activeChannelId = _activeVoiceChannel!.id;
          final presenceParticipants =
              voiceParticipantsByChannel[activeChannelId] ??
              const <VoiceParticipant>[];
          final activePresenceParticipants =
              activeVoiceController.presenceParticipants.isEmpty
              ? activeVoiceController.participants
              : activeVoiceController.presenceParticipants;
          final liveParticipantsByUserId = {
            for (final participant in activePresenceParticipants)
              participant.userId: participant,
          };
          final mergedParticipants = presenceParticipants
              .map((participant) {
                final liveParticipant =
                    liveParticipantsByUserId[participant.userId];
                if (liveParticipant == null) {
                  return participant;
                }
                return participant.copyWith(
                  clientId: liveParticipant.clientId,
                  displayName: liveParticipant.displayName,
                  isSelf: liveParticipant.isSelf,
                  isMuted: liveParticipant.isMuted,
                  shareKind: liveParticipant.shareKind,
                  isSpeaking: liveParticipant.isSpeaking,
                );
              })
              .toList(growable: true);
          final mergedUserIds = mergedParticipants
              .map((participant) => participant.userId)
              .toSet();
          for (final liveParticipant in activePresenceParticipants) {
            if (!mergedUserIds.contains(liveParticipant.userId)) {
              mergedParticipants.add(liveParticipant);
            }
          }
          mergedParticipants.sort(
            (left, right) => left.displayName.toLowerCase().compareTo(
              right.displayName.toLowerCase(),
            ),
          );
          voiceParticipantsByChannel[activeChannelId] = mergedParticipants;
        }

        final sidebar = _showDirectMessages
            ? _DirectMessagesSidebar(
                conversations: directConversations,
                loading:
                    !directConversationsSnapshot.hasData &&
                    directConversationsSnapshot.connectionState !=
                        ConnectionState.active,
                error: directConversationsSnapshot.hasError
                    ? directConversationsSnapshot.error.toString()
                    : null,
                selectedConversationId: _selectedDirectConversationId,
                currentDisplayName: widget.authService.displayName,
                currentAvatarUrl: widget.workspaceRepository
                    .publicProfileAvatarUrl(_currentUserAvatarPath),
                avatarUrlForPath:
                    widget.workspaceRepository.publicProfileAvatarUrl,
                onSelectConversation: _selectDirectConversation,
                canStartConversation: _serverMembers.any(
                  (member) => member.userId != widget.authService.userId,
                ),
                onStartConversation: _promptStartDirectMessage,
                activeVoiceChannel: _activeVoiceChannel,
                activeVoiceController: activeVoiceController,
                canStreamCamera: true,
                canShareScreen: true,
                onOpenActiveVoiceChannel: _openActiveVoiceChannel,
                onLeaveActiveVoiceChannel: _leaveActiveVoiceChannel,
                onOpenUserSettings: _openUserSettings,
                onSignOut: widget.authService.signOut,
              )
            : activeVoiceController == null
            ? _ChannelSidebar(
                server: selectedServer,
                categories: _categories,
                channels: _channels,
                loading: _loadingChannels,
                loadingAccess: _loadingServerAccess,
                error: _channelError,
                access: _serverAccess,
                selectedChannelId: _selectedChannel?.id,
                channelUnreadCounts: _channelUnreadCounts,
                voiceParticipantsByChannel: voiceParticipantsByChannel,
                activeVoiceChannel: _activeVoiceChannel,
                activeVoiceController: activeVoiceController,
                canStreamCamera: true,
                canShareScreen: true,
                onSelectChannel: _selectChannel,
                onRenameCategory: _promptRenameCategory,
                onReorderCategories: _reorderCategories,
                onMoveChannel: _moveChannel,
                onOpenSettings: _openServerSettings,
                onCopyInviteCode: _copyInviteCode,
                onOpenUserSettings: _openUserSettings,
                onSignOut: widget.authService.signOut,
                currentDisplayName: widget.authService.displayName,
                currentAvatarUrl: widget.workspaceRepository
                    .publicProfileAvatarUrl(_currentUserAvatarPath),
                onOpenActiveVoiceChannel: _openActiveVoiceChannel,
                onLeaveActiveVoiceChannel: _leaveActiveVoiceChannel,
                onStartDirectMessage:
                    ({required userId, required displayName}) =>
                        _startDirectMessage(
                          userId: userId,
                          displayName: displayName,
                        ),
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
                  channelUnreadCounts: _channelUnreadCounts,
                  voiceParticipantsByChannel: voiceParticipantsByChannel,
                  activeVoiceChannel: _activeVoiceChannel,
                  activeVoiceController: activeVoiceController,
                  canStreamCamera: true,
                  canShareScreen: true,
                  onSelectChannel: _selectChannel,
                  onRenameCategory: _promptRenameCategory,
                  onReorderCategories: _reorderCategories,
                  onMoveChannel: _moveChannel,
                  onOpenSettings: _openServerSettings,
                  onCopyInviteCode: _copyInviteCode,
                  onOpenUserSettings: _openUserSettings,
                  onSignOut: widget.authService.signOut,
                  currentDisplayName: widget.authService.displayName,
                  currentAvatarUrl: widget.workspaceRepository
                      .publicProfileAvatarUrl(_currentUserAvatarPath),
                  onOpenActiveVoiceChannel: _openActiveVoiceChannel,
                  onLeaveActiveVoiceChannel: _leaveActiveVoiceChannel,
                  onStartDirectMessage:
                      ({required userId, required displayName}) =>
                          _startDirectMessage(
                            userId: userId,
                            displayName: displayName,
                          ),
                ),
              );

        final membersPanel = _showDirectMessages
            ? _DirectMessagesInfoPanel(
                selectedConversation: selectedDirectConversation,
                avatarUrlForPath:
                    widget.workspaceRepository.publicProfileAvatarUrl,
              )
            : _ServerMembersPanel(
                server: selectedServer,
                roles: _serverRoles,
                members: _serverMembers,
                onlineMemberIds: _onlineMemberIds,
                loading: _loadingMemberRoster,
                error: _memberRosterError,
                currentUserId: widget.authService.userId,
                avatarUrlForPath:
                    widget.workspaceRepository.publicProfileAvatarUrl,
                onStartDirectMessage:
                    ({required userId, required displayName}) =>
                        _startDirectMessage(
                          userId: userId,
                          displayName: displayName,
                        ),
              );

        final content = _showDirectMessages
            ? selectedDirectConversation == null
                  ? const _EmptyState(
                      title: 'Direct messages',
                      message:
                          'Pick a conversation or start one from a member, message, or voice participant.',
                    )
                  : DirectMessageView(
                      key: ValueKey<String>(
                        selectedDirectConversation.conversationId,
                      ),
                      conversation: selectedDirectConversation,
                      repository: widget.workspaceRepository,
                      currentUserId: widget.authService.userId,
                      use24HourTime: widget.preferences.use24HourTime,
                      showTimestamps: widget.preferences.showMessageTimestamps,
                      motionDuration: widget.preferences.motionDuration,
                      animateMessages:
                          widget.preferences.messageAnimations &&
                          !widget.preferences.reduceMotion,
                      onMarkRead: () =>
                          widget.workspaceRepository.markDirectConversationRead(
                            selectedDirectConversation.conversationId,
                          ),
                      onStartDirectMessage:
                          ({required userId, required displayName}) =>
                              _startDirectMessage(
                                userId: userId,
                                displayName: displayName,
                              ),
                    )
            : _selectedChannel == null
            ? const _EmptyState(
                title: 'Select a channel',
                message:
                    'Choose a text channel for chat or a voice channel for live audio, camera, and screen sharing.',
              )
            : _selectedChannel!.kind == ChannelKind.text
            ? TextChannelView(
                channel: _selectedChannel!,
                repository: widget.workspaceRepository,
                currentUserId: widget.authService.userId,
                canSendMessages:
                    _serverAccess?.hasPermission(
                      ServerPermission.sendMessages,
                    ) ??
                    true,
                canManageMessages:
                    _serverAccess?.hasPermission(
                      ServerPermission.manageMessages,
                    ) ??
                    false,
                use24HourTime: widget.preferences.use24HourTime,
                showTimestamps: widget.preferences.showMessageTimestamps,
                motionDuration: widget.preferences.motionDuration,
                animateMessages:
                    widget.preferences.messageAnimations &&
                    !widget.preferences.reduceMotion,
                onMarkRead: (timestamp) => widget.preferences.markChannelRead(
                  _selectedChannel!.id,
                  timestamp,
                ),
                onStartDirectMessage:
                    ({required userId, required displayName}) =>
                        _startDirectMessage(
                          userId: userId,
                          displayName: displayName,
                        ),
              )
            : VoiceChannelView(
                channel: _selectedChannel!,
                repository: widget.workspaceRepository,
                controller: _selectedVoiceController,
                activeChannelId: _activeVoiceChannel?.id,
                canJoinVoice:
                    _serverAccess?.hasPermission(ServerPermission.joinVoice) ??
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
                onStartDirectMessage:
                    ({required userId, required displayName}) =>
                        _startDirectMessage(
                          userId: userId,
                          displayName: displayName,
                        ),
              );

        return Scaffold(
          body: Container(
            decoration: BoxDecoration(gradient: palette.appBackground),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    SizedBox(
                      width: 108,
                      child: _ServerRail(
                        servers: _servers,
                        loading: _loadingServers,
                        error: _serverError,
                        selectedServerId: _showDirectMessages
                            ? null
                            : selectedServer?.id,
                        selectedDirectMessages: _showDirectMessages,
                        directUnreadCount: totalDirectUnreadCount,
                        onSelectServer: _selectServer,
                        onSelectDirectMessages: _openDirectMessagesHome,
                        onCreateServer: _promptCreateServer,
                        onJoinServer: _promptJoinServer,
                        onDiscoverServers: _openServerDiscovery,
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
                        key: ValueKey<String>(
                          _showDirectMessages
                              ? 'dm-sidebar'
                              : 'server-sidebar:${selectedServer?.id}',
                        ),
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
                          key: ValueKey<String>(
                            _showDirectMessages
                                ? 'dm:${_selectedDirectConversationId ?? 'none'}'
                                : '${selectedServer?.id}:${_selectedChannel?.id}',
                          ),
                          child: content,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _DetailsPanelToggle(
                      collapsed: _detailsPanelCollapsed,
                      directMessages: _showDirectMessages,
                      onPressed: _toggleDetailsPanel,
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: 0,
                        end: _detailsPanelCollapsed ? 0 : 1,
                      ),
                      duration: widget.preferences.motionDuration,
                      curve: Curves.easeOutCubic,
                      builder: (context, factor, child) {
                        return SizedBox(
                          width: 288 * factor,
                          child: IgnorePointer(
                            ignoring: factor < 0.99,
                            child: ClipRect(
                              child: OverflowBox(
                                minWidth: 288,
                                maxWidth: 288,
                                alignment: Alignment.centerRight,
                                child: child,
                              ),
                            ),
                          ),
                        );
                      },
                      child: SizedBox(width: 288, child: membersPanel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
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
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    }
  }
}

class _SidebarAccountFooter extends StatelessWidget {
  const _SidebarAccountFooter({
    required this.displayName,
    required this.avatarUrl,
    required this.onOpenUserSettings,
    required this.onSignOut,
  });

  final String displayName;
  final String? avatarUrl;
  final Future<void> Function() onOpenUserSettings;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelStrong,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.borderStrong.withAlpha(170)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: onOpenUserSettings,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        _UserAvatar(
                          displayName: displayName,
                          avatarUrl: avatarUrl,
                          size: 38,
                          backgroundColor: palette.panelAccent.withAlpha(120),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: onSignOut,
              icon: const Icon(Icons.logout, size: 20),
              visualDensity: const VisualDensity(
                horizontal: 0.6,
                vertical: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectMessagesSidebar extends StatelessWidget {
  const _DirectMessagesSidebar({
    required this.conversations,
    required this.loading,
    required this.error,
    required this.selectedConversationId,
    required this.currentDisplayName,
    required this.currentAvatarUrl,
    required this.avatarUrlForPath,
    required this.onSelectConversation,
    required this.canStartConversation,
    required this.onStartConversation,
    required this.activeVoiceChannel,
    required this.activeVoiceController,
    required this.canStreamCamera,
    required this.canShareScreen,
    required this.onOpenActiveVoiceChannel,
    required this.onLeaveActiveVoiceChannel,
    required this.onOpenUserSettings,
    required this.onSignOut,
  });

  final List<DirectConversationSummary> conversations;
  final bool loading;
  final String? error;
  final String? selectedConversationId;
  final String currentDisplayName;
  final String? currentAvatarUrl;
  final String? Function(String? avatarPath) avatarUrlForPath;
  final ValueChanged<String> onSelectConversation;
  final bool canStartConversation;
  final Future<void> Function() onStartConversation;
  final ChannelSummary? activeVoiceChannel;
  final VoiceChannelSessionController? activeVoiceController;
  final bool canStreamCamera;
  final bool canShareScreen;
  final Future<void> Function() onOpenActiveVoiceChannel;
  final Future<void> Function() onLeaveActiveVoiceChannel;
  final Future<void> Function() onOpenUserSettings;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final dockChannel = activeVoiceChannel;
    final dockController = activeVoiceController;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Direct Messages',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Private conversations stay here across all servers.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: canStartConversation ? onStartConversation : null,
                icon: const Icon(Icons.edit_square),
                label: const Text('Start DM'),
              ),
            ),
            const SizedBox(height: 16),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(error!),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : conversations.isEmpty
                  ? const Center(
                      child: Text(
                        'No direct messages yet. Right click someone to start one.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: conversations.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        final selected =
                            conversation.conversationId ==
                            selectedConversationId;
                        return InkWell(
                          onTap: () =>
                              onSelectConversation(conversation.conversationId),
                          borderRadius: BorderRadius.circular(18),
                          child: Ink(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: selected
                                  ? palette.panelAccent
                                  : palette.panelStrong,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: selected
                                    ? Theme.of(context).colorScheme.secondary
                                    : palette.border,
                              ),
                            ),
                            child: Row(
                              children: [
                                _UserAvatar(
                                  displayName: conversation.otherDisplayName,
                                  avatarUrl: avatarUrlForPath(
                                    conversation.otherAvatarPath,
                                  ),
                                  size: 38,
                                  backgroundColor: palette.panelAccent
                                      .withAlpha(140),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        conversation.otherDisplayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        conversation.lastMessagePreview ??
                                            'No messages yet.',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                if (conversation.unreadCount > 0) ...[
                                  const SizedBox(width: 8),
                                  _UnreadBadge(count: conversation.unreadCount),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (dockChannel != null && dockController != null) ...[
              const SizedBox(height: 14),
              _ActiveVoiceDock(
                channel: dockChannel,
                controller: dockController,
                canStreamCamera: canStreamCamera,
                canShareScreen: canShareScreen,
                onOpenChannel: onOpenActiveVoiceChannel,
                onLeaveCall: onLeaveActiveVoiceChannel,
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _SidebarAccountFooter(
              displayName: currentDisplayName,
              avatarUrl: currentAvatarUrl,
              onOpenUserSettings: onOpenUserSettings,
              onSignOut: onSignOut,
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectMessagesInfoPanel extends StatelessWidget {
  const _DirectMessagesInfoPanel({
    required this.selectedConversation,
    required this.avatarUrlForPath,
  });

  final DirectConversationSummary? selectedConversation;
  final String? Function(String? avatarPath) avatarUrlForPath;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: selectedConversation == null
          ? const _EmptyState(
              title: 'Direct messages',
              message:
                  'Select a direct message thread to see conversation details.',
            )
          : Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _UserAvatar(
                    displayName: selectedConversation!.otherDisplayName,
                    avatarUrl: avatarUrlForPath(
                      selectedConversation!.otherAvatarPath,
                    ),
                    size: 56,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    selectedConversation!.otherDisplayName,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'User ID',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(selectedConversation!.otherUserId),
                  const SizedBox(height: 18),
                  Text('Unread', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Text('${selectedConversation!.unreadCount} message(s)'),
                ],
              ),
            ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DetailsPanelToggle extends StatelessWidget {
  const _DetailsPanelToggle({
    required this.collapsed,
    required this.directMessages,
    required this.onPressed,
  });

  final bool collapsed;
  final bool directMessages;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return SizedBox(
      width: 44,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.border),
          ),
          child: IconButton(
            onPressed: onPressed,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            icon: Icon(
              collapsed ? Icons.chevron_left : Icons.chevron_right,
              size: 20,
            ),
            selectedIcon: Icon(
              collapsed ? Icons.chevron_left : Icons.chevron_right,
              size: 20,
            ),
            isSelected: !directMessages && !collapsed,
          ),
        ),
      ),
    );
  }
}

class _ActiveVoiceDock extends StatelessWidget {
  const _ActiveVoiceDock({
    required this.channel,
    required this.controller,
    required this.canStreamCamera,
    required this.canShareScreen,
    required this.onOpenChannel,
    required this.onLeaveCall,
  });

  final ChannelSummary channel;
  final VoiceChannelSessionController controller;
  final bool canStreamCamera;
  final bool canShareScreen;
  final Future<void> Function() onOpenChannel;
  final Future<void> Function() onLeaveCall;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: palette.borderStrong.withAlpha(170)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: onOpenChannel,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.graphic_eq),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'In voice: ${channel.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                controller.status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.open_in_new, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    IconButton.filledTonal(
                      onPressed: controller.busy ? null : controller.toggleMute,
                      icon: Icon(controller.muted ? Icons.mic_off : Icons.mic),
                    ),
                    IconButton.filledTonal(
                      onPressed: controller.busy
                          ? null
                          : controller.toggleDeafen,
                      icon: Icon(
                        controller.deafened
                            ? Icons.hearing_disabled
                            : Icons.hearing,
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: controller.busy || !canStreamCamera
                          ? null
                          : () async {
                              if (controller.shareKind == ShareKind.camera) {
                                await controller.stopVisualShare();
                                return;
                              }
                              await controller.startCameraShare();
                            },
                      icon: Icon(
                        controller.shareKind == ShareKind.camera
                            ? Icons.videocam_off
                            : Icons.videocam,
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed:
                          controller.busy ||
                              !canShareScreen ||
                              !WebRTC.platformIsDesktop
                          ? null
                          : () async {
                              if (controller.shareKind == ShareKind.screen) {
                                await controller.stopVisualShare();
                                return;
                              }
                              final selection =
                                  await showDialog<_ScreenShareSelection>(
                                    context: context,
                                    builder: (context) =>
                                        ScreenSourcePickerDialog(
                                          controller: controller,
                                        ),
                                  );
                              if (selection != null) {
                                await controller.startScreenShare(
                                  selection.source,
                                  maxWidth: selection.preset.width,
                                  maxHeight: selection.preset.height,
                                  frameRate: selection.preset.frameRate,
                                  captureSystemAudio:
                                      selection.captureSystemAudio,
                                );
                              }
                            },
                      icon: Icon(
                        controller.shareKind == ShareKind.screen
                            ? Icons.stop_screen_share
                            : Icons.screen_share,
                      ),
                    ),
                    IconButton.filled(
                      onPressed: controller.busy ? null : onLeaveCall,
                      icon: const Icon(Icons.call_end),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WorkspaceRailTile extends StatelessWidget {
  const _WorkspaceRailTile({
    required this.label,
    required this.selected,
    required this.icon,
    required this.badgeCount,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final IconData icon;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return InkWell(
      onTap: onTap,
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
                    color: Theme.of(context).colorScheme.primary.withAlpha(120),
                    blurRadius: 20,
                    spreadRadius: 3,
                  ),
                ]
              : const [],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Center(
                child: Icon(
                  icon,
                  size: 28,
                  color: selected
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface,
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
                    color: Theme.of(context).colorScheme.secondary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            if (badgeCount > 0)
              Positioned(
                top: -6,
                right: -6,
                child: _UnreadBadge(count: badgeCount),
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
    required this.selectedDirectMessages,
    required this.directUnreadCount,
    required this.onSelectServer,
    required this.onSelectDirectMessages,
    required this.onCreateServer,
    required this.onJoinServer,
    required this.onDiscoverServers,
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
  final bool selectedDirectMessages;
  final int directUnreadCount;
  final Future<void> Function(ServerSummary? server) onSelectServer;
  final Future<void> Function({String? conversationId}) onSelectDirectMessages;
  final Future<void> Function() onCreateServer;
  final Future<void> Function() onJoinServer;
  final Future<void> Function() onDiscoverServers;
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
          ),
          IconButton(
            onPressed: onJoinServer,
            icon: const Icon(Icons.group_add),
          ),
          IconButton(
            onPressed: onDiscoverServers,
            icon: const Icon(Icons.travel_explore_outlined),
          ),
          IconButton(
            onPressed: () => onRefresh(selectFirstServer: false),
            icon: const Icon(Icons.refresh),
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
                    itemCount: servers.length + 1,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _WorkspaceRailTile(
                          label: 'DMs',
                          selected: selectedDirectMessages,
                          icon: Icons.forum_outlined,
                          badgeCount: directUnreadCount,
                          onTap: () => onSelectDirectMessages(),
                        );
                      }
                      final server = servers[index - 1];
                      final selected = server.id == selectedServerId;
                      return GestureDetector(
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

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({
    required this.displayName,
    required this.avatarUrl,
    required this.size,
    this.backgroundColor,
  });

  final String displayName;
  final String? avatarUrl;
  final double size;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color:
            backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        displayName.trim().isEmpty
            ? '?'
            : displayName.characters.first.toUpperCase(),
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: size * 0.38),
      ),
    );

    if (avatarUrl == null) {
      return fallback;
    }

    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          avatarUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      ),
    );
  }
}

class _ChannelSidebar extends StatefulWidget {
  const _ChannelSidebar({
    required this.server,
    required this.categories,
    required this.channels,
    required this.loading,
    required this.loadingAccess,
    required this.error,
    required this.access,
    required this.selectedChannelId,
    required this.channelUnreadCounts,
    required this.voiceParticipantsByChannel,
    required this.activeVoiceChannel,
    required this.activeVoiceController,
    required this.canStreamCamera,
    required this.canShareScreen,
    required this.onSelectChannel,
    required this.onRenameCategory,
    required this.onReorderCategories,
    required this.onMoveChannel,
    required this.onOpenSettings,
    required this.onCopyInviteCode,
    required this.onOpenUserSettings,
    required this.onSignOut,
    required this.currentDisplayName,
    required this.currentAvatarUrl,
    required this.onOpenActiveVoiceChannel,
    required this.onLeaveActiveVoiceChannel,
    required this.onStartDirectMessage,
  });

  final ServerSummary? server;
  final List<ChannelCategorySummary> categories;
  final List<ChannelSummary> channels;
  final bool loading;
  final bool loadingAccess;
  final String? error;
  final ServerAccess? access;
  final String? selectedChannelId;
  final Map<String, int> channelUnreadCounts;
  final Map<String, List<VoiceParticipant>> voiceParticipantsByChannel;
  final ChannelSummary? activeVoiceChannel;
  final VoiceChannelSessionController? activeVoiceController;
  final bool canStreamCamera;
  final bool canShareScreen;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(ChannelCategorySummary category) onRenameCategory;
  final Future<void> Function(int oldIndex, int newIndex) onReorderCategories;
  final Future<void> Function(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  )
  onMoveChannel;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onCopyInviteCode;
  final Future<void> Function() onOpenUserSettings;
  final Future<void> Function() onSignOut;
  final String currentDisplayName;
  final String? currentAvatarUrl;
  final Future<void> Function() onOpenActiveVoiceChannel;
  final Future<void> Function() onLeaveActiveVoiceChannel;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  State<_ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends State<_ChannelSidebar> {
  String? _draggingChannelId;

  void _handleChannelDragStarted(String channelId) {
    if (_draggingChannelId == channelId) {
      return;
    }
    setState(() {
      _draggingChannelId = channelId;
    });
  }

  void _handleChannelDragFinished() {
    if (_draggingChannelId == null) {
      return;
    }
    setState(() {
      _draggingChannelId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedServer = widget.server;
    final serverAccess = widget.access;
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final canManageChannels =
        serverAccess?.hasPermission(ServerPermission.manageChannels) ?? false;
    final showDropSlots = canManageChannels && _draggingChannelId != null;
    final isOwner =
        selectedServer?.ownerId ==
        Supabase.instance.client.auth.currentUser?.id;
    final canOpenSettings =
        (!widget.loadingAccess && isOwner) ||
        (serverAccess?.hasPermission(ServerPermission.inviteMembers) ??
            false) ||
        (serverAccess?.hasPermission(ServerPermission.manageServer) ?? false) ||
        (serverAccess?.hasPermission(ServerPermission.manageRoles) ?? false) ||
        (serverAccess?.hasPermission(ServerPermission.manageChannels) ?? false);
    final uncategorizedChannels = widget.channels
        .where((channel) => channel.categoryId == null)
        .toList();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: selectedServer == null
                  ? const _EmptyState(
                      title: 'No server selected',
                      message:
                          'Create a server or join one with an invite code.',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: widget.onCopyInviteCode,
                          mouseCursor: SystemMouseCursors.click,
                          borderRadius: BorderRadius.circular(14),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    selectedServer.name,
                                    style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.content_copy_outlined,
                                  size: 18,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonalIcon(
                            onPressed: canOpenSettings
                                ? widget.onOpenSettings
                                : null,
                            icon: widget.loadingAccess
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.settings),
                            label: const Text('Server settings'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (widget.error != null) Text(widget.error!),
                        if (widget.loading)
                          const Expanded(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else ...[
                          Expanded(
                            child:
                                widget.channels.isEmpty &&
                                    widget.categories.isEmpty
                                ? const Center(
                                    child: Text(
                                      'This server has no channels yet.',
                                    ),
                                  )
                                : ListView(
                                    children: [
                                      if (uncategorizedChannels.isNotEmpty ||
                                          canManageChannels) ...[
                                        _ChannelGroupDropTarget(
                                          categoryId: null,
                                          canManageChannels: canManageChannels,
                                          onMoveChannel: widget.onMoveChannel,
                                          targetIndex:
                                              uncategorizedChannels.length,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const _CategoryHeader(
                                                title: 'Channels',
                                              ),
                                              const SizedBox(height: 8),
                                              _ChannelList(
                                                categoryId: null,
                                                channels: uncategorizedChannels,
                                                selectedChannelId:
                                                    widget.selectedChannelId,
                                                channelUnreadCounts:
                                                    widget.channelUnreadCounts,
                                                voiceParticipantsByChannel: widget
                                                    .voiceParticipantsByChannel,
                                                onStartDirectMessage:
                                                    widget.onStartDirectMessage,
                                                canManageChannels:
                                                    canManageChannels,
                                                showDropSlots: showDropSlots,
                                                onSelectChannel:
                                                    widget.onSelectChannel,
                                                onMoveChannel:
                                                    widget.onMoveChannel,
                                                onChannelDragStarted:
                                                    _handleChannelDragStarted,
                                                onChannelDragFinished:
                                                    _handleChannelDragFinished,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                      ],
                                      if (widget.categories.isNotEmpty)
                                        ReorderableListView.builder(
                                          shrinkWrap: true,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          buildDefaultDragHandles: false,
                                          itemCount: widget.categories.length,
                                          onReorder: (oldIndex, newIndex) {
                                            unawaited(
                                              widget.onReorderCategories(
                                                oldIndex,
                                                newIndex,
                                              ),
                                            );
                                          },
                                          itemBuilder: (context, index) {
                                            final category =
                                                widget.categories[index];
                                            final categoryChannels = widget
                                                .channels
                                                .where(
                                                  (channel) =>
                                                      channel.categoryId ==
                                                      category.id,
                                                )
                                                .toList();
                                            return Padding(
                                              key: ValueKey<String>(
                                                category.id,
                                              ),
                                              padding: const EdgeInsets.only(
                                                bottom: 14,
                                              ),
                                              child: _CategorySection(
                                                category: category,
                                                channels: categoryChannels,
                                                selectedChannelId:
                                                    widget.selectedChannelId,
                                                channelUnreadCounts:
                                                    widget.channelUnreadCounts,
                                                voiceParticipantsByChannel: widget
                                                    .voiceParticipantsByChannel,
                                                onStartDirectMessage:
                                                    widget.onStartDirectMessage,
                                                canManageChannels:
                                                    canManageChannels,
                                                showDropSlots: showDropSlots,
                                                onRenameCategory: () => widget
                                                    .onRenameCategory(category),
                                                onSelectChannel:
                                                    widget.onSelectChannel,
                                                onMoveChannel:
                                                    widget.onMoveChannel,
                                                onChannelDragStarted:
                                                    _handleChannelDragStarted,
                                                onChannelDragFinished:
                                                    _handleChannelDragFinished,
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
            if (widget.activeVoiceController != null &&
                widget.activeVoiceChannel != null) ...[
              const SizedBox(height: 14),
              _ActiveVoiceDock(
                channel: widget.activeVoiceChannel!,
                controller: widget.activeVoiceController!,
                canStreamCamera: widget.canStreamCamera,
                canShareScreen: widget.canShareScreen,
                onOpenChannel: widget.onOpenActiveVoiceChannel,
                onLeaveCall: widget.onLeaveActiveVoiceChannel,
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _SidebarAccountFooter(
              displayName: widget.currentDisplayName,
              avatarUrl: widget.currentAvatarUrl,
              onOpenUserSettings: widget.onOpenUserSettings,
              onSignOut: widget.onSignOut,
            ),
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
    required this.channelUnreadCounts,
    required this.voiceParticipantsByChannel,
    required this.onStartDirectMessage,
    required this.canManageChannels,
    required this.showDropSlots,
    required this.onRenameCategory,
    required this.onSelectChannel,
    required this.onMoveChannel,
    required this.onChannelDragStarted,
    required this.onChannelDragFinished,
    this.reorderHandle,
  });

  final ChannelCategorySummary category;
  final List<ChannelSummary> channels;
  final String? selectedChannelId;
  final Map<String, int> channelUnreadCounts;
  final Map<String, List<VoiceParticipant>> voiceParticipantsByChannel;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;
  final bool canManageChannels;
  final bool showDropSlots;
  final VoidCallback onRenameCategory;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  )
  onMoveChannel;
  final ValueChanged<String> onChannelDragStarted;
  final VoidCallback onChannelDragFinished;
  final Widget? reorderHandle;

  @override
  Widget build(BuildContext context) {
    final headerActions = <Widget>[];
    if (canManageChannels) {
      headerActions.add(
        IconButton(
          onPressed: onRenameCategory,
          icon: const Icon(Icons.edit_outlined, size: 18),
        ),
      );
    }
    if (reorderHandle != null) {
      headerActions.add(reorderHandle!);
    }

    return _ChannelGroupDropTarget(
      categoryId: category.id,
      canManageChannels: canManageChannels,
      onMoveChannel: onMoveChannel,
      targetIndex: channels.length,
      child: Column(
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
            channelUnreadCounts: channelUnreadCounts,
            voiceParticipantsByChannel: voiceParticipantsByChannel,
            onStartDirectMessage: onStartDirectMessage,
            canManageChannels: canManageChannels,
            showDropSlots: showDropSlots,
            onSelectChannel: onSelectChannel,
            onMoveChannel: onMoveChannel,
            onChannelDragStarted: onChannelDragStarted,
            onChannelDragFinished: onChannelDragFinished,
          ),
        ],
      ),
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

class _ChannelGroupDropTarget extends StatelessWidget {
  const _ChannelGroupDropTarget({
    required this.categoryId,
    required this.canManageChannels,
    required this.onMoveChannel,
    required this.targetIndex,
    required this.child,
  });

  final String? categoryId;
  final bool canManageChannels;
  final Future<void> Function(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  )
  onMoveChannel;
  final int targetIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DragTarget<ChannelSummary>(
      onWillAcceptWithDetails: !canManageChannels
          ? null
          : (details) => details.data.categoryId != categoryId,
      onAcceptWithDetails: !canManageChannels
          ? null
          : (details) {
              unawaited(onMoveChannel(details.data, categoryId, targetIndex));
            },
      builder: (context, candidateData, rejectedData) {
        final hovering = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: hovering
                ? palette.panelAccent.withAlpha(140)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: hovering ? palette.borderStrong : Colors.transparent,
              width: hovering ? 1.4 : 1,
            ),
          ),
          child: child,
        );
      },
    );
  }
}

class _ChannelList extends StatelessWidget {
  const _ChannelList({
    required this.categoryId,
    required this.channels,
    required this.selectedChannelId,
    required this.channelUnreadCounts,
    required this.voiceParticipantsByChannel,
    required this.onStartDirectMessage,
    required this.canManageChannels,
    required this.showDropSlots,
    required this.onSelectChannel,
    required this.onMoveChannel,
    required this.onChannelDragStarted,
    required this.onChannelDragFinished,
  });

  final String? categoryId;
  final List<ChannelSummary> channels;
  final String? selectedChannelId;
  final Map<String, int> channelUnreadCounts;
  final Map<String, List<VoiceParticipant>> voiceParticipantsByChannel;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;
  final bool canManageChannels;
  final bool showDropSlots;
  final Future<void> Function(ChannelSummary? channel) onSelectChannel;
  final Future<void> Function(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  )
  onMoveChannel;
  final ValueChanged<String> onChannelDragStarted;
  final VoidCallback onChannelDragFinished;

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: categoryId == null && canManageChannels ? 104 : 56,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Align(
            alignment: categoryId == null && canManageChannels
                ? Alignment.center
                : Alignment.centerLeft,
            child: Text(
              canManageChannels
                  ? 'No channels here yet. Drop one here to move it.'
                  : 'No channels here yet.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: categoryId == null && canManageChannels
                  ? TextAlign.center
                  : TextAlign.start,
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (var index = 0; index < channels.length; index++) ...[
          _ChannelDropSlot(
            categoryId: categoryId,
            targetIndex: index,
            canManageChannels: canManageChannels,
            visible: showDropSlots,
            onMoveChannel: onMoveChannel,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ChannelTile(
              key: ValueKey<String>(channels[index].id),
              channel: channels[index],
              selected: channels[index].id == selectedChannelId,
              unreadCount: channelUnreadCounts[channels[index].id] ?? 0,
              voiceParticipants:
                  voiceParticipantsByChannel[channels[index].id] ??
                  const <VoiceParticipant>[],
              onStartDirectMessage: onStartDirectMessage,
              onTap: () => onSelectChannel(channels[index]),
              draggable: canManageChannels,
              onDragStarted: () => onChannelDragStarted(channels[index].id),
              onDragFinished: onChannelDragFinished,
            ),
          ),
        ],
        _ChannelDropSlot(
          categoryId: categoryId,
          targetIndex: channels.length,
          canManageChannels: canManageChannels,
          visible: showDropSlots,
          onMoveChannel: onMoveChannel,
        ),
      ],
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    super.key,
    required this.channel,
    required this.selected,
    required this.unreadCount,
    required this.voiceParticipants,
    required this.onStartDirectMessage,
    required this.onTap,
    required this.onDragStarted,
    required this.onDragFinished,
    this.draggable = false,
  });

  final ChannelSummary channel;
  final bool selected;
  final int unreadCount;
  final List<VoiceParticipant> voiceParticipants;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;
  final VoidCallback onTap;
  final VoidCallback onDragStarted;
  final VoidCallback onDragFinished;
  final bool draggable;

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
      if (channel.kind == ChannelKind.text && unreadCount > 0)
        _UnreadBadge(count: unreadCount),
    ];
    final showVoiceParticipants =
        channel.kind == ChannelKind.voice && voiceParticipants.isNotEmpty;

    final tileBody = InkWell(
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
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: voiceParticipants
                      .map(
                        (participant) => Builder(
                          builder: (context) => GestureDetector(
                            onSecondaryTapDown: participant.isSelf
                                ? null
                                : (details) {
                                    unawaited(
                                      _showVoiceParticipantMenu(
                                        context,
                                        details.globalPosition,
                                        participant,
                                      ),
                                    );
                                  },
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    participant.isMuted
                                        ? Icons.mic_off
                                        : participant.shareKind ==
                                              ShareKind.screen
                                        ? Icons.screen_share
                                        : participant.shareKind ==
                                              ShareKind.camera
                                        ? Icons.videocam
                                        : Icons.mic,
                                    size: 13,
                                    color: participant.isSpeaking
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.secondary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      participant.isSelf
                                          ? '${participant.displayName} (you)'
                                          : participant.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: participant.isSpeaking
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.secondary
                                                : null,
                                            fontWeight: participant.isSpeaking
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                          ),
                                    ),
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

    if (!draggable) {
      return tileBody;
    }

    return Draggable<ChannelSummary>(
      data: channel,
      ignoringFeedbackPointer: true,
      onDragStarted: onDragStarted,
      onDragCompleted: onDragFinished,
      onDraggableCanceled: (velocity, offset) => onDragFinished(),
      onDragEnd: (_) => onDragFinished(),
      feedbackOffset: const Offset(28, -26),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: palette.panelStrong.withAlpha(235),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.48, child: tileBody),
      child: tileBody,
    );
  }

  Future<void> _showVoiceParticipantMenu(
    BuildContext context,
    Offset position,
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
      items: const [
        PopupMenuItem<String>(value: 'dm', child: Text('Send direct message')),
      ],
    );
    if (selection == 'dm') {
      await onStartDirectMessage(
        userId: participant.userId,
        displayName: participant.displayName,
      );
    }
  }
}

class _ChannelDropSlot extends StatelessWidget {
  const _ChannelDropSlot({
    required this.categoryId,
    required this.targetIndex,
    required this.canManageChannels,
    required this.visible,
    required this.onMoveChannel,
  });

  final String? categoryId;
  final int targetIndex;
  final bool canManageChannels;
  final bool visible;
  final Future<void> Function(
    ChannelSummary channel,
    String? targetCategoryId,
    int targetIndex,
  )
  onMoveChannel;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return DragTarget<ChannelSummary>(
      onWillAcceptWithDetails: !canManageChannels ? null : (details) => true,
      onAcceptWithDetails: !canManageChannels
          ? null
          : (details) {
              unawaited(onMoveChannel(details.data, categoryId, targetIndex));
            },
      builder: (context, candidateData, rejectedData) {
        final hovering = candidateData.isNotEmpty;
        final showIndicator = visible || hovering;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          margin: showIndicator
              ? const EdgeInsets.symmetric(vertical: 2)
              : EdgeInsets.zero,
          padding: showIndicator
              ? const EdgeInsets.symmetric(horizontal: 8)
              : EdgeInsets.zero,
          height: showIndicator ? (hovering ? 28 : 18) : 0,
          alignment: Alignment.center,
          child: !showIndicator
              ? const SizedBox.shrink()
              : Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      height: hovering ? 16 : 10,
                      decoration: BoxDecoration(
                        color: hovering
                            ? palette.panelAccent.withAlpha(120)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      height: hovering ? 5 : 2,
                      decoration: BoxDecoration(
                        color: hovering
                            ? palette.borderStrong
                            : palette.border.withAlpha(120),
                        borderRadius: BorderRadius.circular(999),
                        boxShadow: hovering
                            ? [
                                BoxShadow(
                                  color: palette.borderStrong.withAlpha(90),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ]
                            : const [],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _ServerMembersPanel extends StatelessWidget {
  const _ServerMembersPanel({
    required this.server,
    required this.roles,
    required this.members,
    required this.onlineMemberIds,
    required this.loading,
    required this.error,
    required this.currentUserId,
    required this.avatarUrlForPath,
    required this.onStartDirectMessage,
  });

  final ServerSummary? server;
  final List<ServerRole> roles;
  final List<ServerMember> members;
  final Set<String> onlineMemberIds;
  final bool loading;
  final String? error;
  final String currentUserId;
  final String? Function(String? avatarPath) avatarUrlForPath;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    if (server == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.panelMuted,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: palette.border),
        ),
        child: const _EmptyState(
          title: 'No members yet',
          message: 'Select a server to view its member roster.',
        ),
      );
    }

    final groupedMembers = _groupMembersByRole();
    final onlineCount = members
        .where((member) => onlineMemberIds.contains(member.userId))
        .length;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.panelMuted,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Members',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '$onlineCount online • ${members.length} total',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(error!),
              ),
            if (loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (members.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('No members found in this server yet.'),
                ),
              )
            else
              Expanded(
                child: ListView(
                  children: groupedMembers
                      .map(
                        (group) => Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: _ServerMemberRoleSection(
                            group: group,
                            onlineMemberIds: onlineMemberIds,
                            currentUserId: currentUserId,
                            avatarUrlForPath: avatarUrlForPath,
                            onStartDirectMessage: onStartDirectMessage,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<_ServerMemberRoleGroup> _groupMembersByRole() {
    final roleOrder = {
      for (var index = 0; index < roles.length; index++) roles[index].id: index,
    };
    final roleById = {for (final role in roles) role.id: role};
    final membersByRoleName = <String, List<ServerMember>>{};
    final roleNameOrder = <String, int>{};

    for (final member in members) {
      final primaryRole = _primaryRoleForMember(member, roleById, roleOrder);
      final roleName = primaryRole?.name ?? 'No role';
      membersByRoleName
          .putIfAbsent(roleName, () => <ServerMember>[])
          .add(member);
      roleNameOrder.putIfAbsent(
        roleName,
        () => primaryRole == null
            ? 1 << 20
            : _roleSortScore(primaryRole, roleOrder),
      );
    }

    final groups = membersByRoleName.entries
        .map(
          (entry) => _ServerMemberRoleGroup(
            roleName: entry.key,
            members: entry.value
              ..sort((left, right) {
                final leftOnline = onlineMemberIds.contains(left.userId);
                final rightOnline = onlineMemberIds.contains(right.userId);
                if (leftOnline != rightOnline) {
                  return leftOnline ? -1 : 1;
                }
                return left.displayName.toLowerCase().compareTo(
                  right.displayName.toLowerCase(),
                );
              }),
            order: roleNameOrder[entry.key] ?? 1 << 20,
          ),
        )
        .toList();

    groups.sort((left, right) {
      final orderComparison = left.order.compareTo(right.order);
      if (orderComparison != 0) {
        return orderComparison;
      }
      return left.roleName.toLowerCase().compareTo(
        right.roleName.toLowerCase(),
      );
    });
    return groups;
  }

  ServerRole? _primaryRoleForMember(
    ServerMember member,
    Map<String, ServerRole> roleById,
    Map<String, int> roleOrder,
  ) {
    final assignedRoles = member.roleIds
        .map((roleId) => roleById[roleId])
        .whereType<ServerRole>()
        .toList();
    if (assignedRoles.isEmpty) {
      return null;
    }
    assignedRoles.sort(
      (left, right) => _roleSortScore(
        left,
        roleOrder,
      ).compareTo(_roleSortScore(right, roleOrder)),
    );
    return assignedRoles.first;
  }

  int _roleSortScore(ServerRole role, Map<String, int> roleOrder) {
    final normalizedName = role.name.toLowerCase();
    if (normalizedName == 'owner') {
      return -3000;
    }
    if (normalizedName == 'admin') {
      return -2000;
    }
    if (normalizedName == 'member') {
      return 9000;
    }
    final index = roleOrder[role.id] ?? 0;
    return role.isSystem ? 1000 + index : index;
  }
}

class _ServerMemberRoleSection extends StatelessWidget {
  const _ServerMemberRoleSection({
    required this.group,
    required this.onlineMemberIds,
    required this.currentUserId,
    required this.avatarUrlForPath,
    required this.onStartDirectMessage,
  });

  final _ServerMemberRoleGroup group;
  final Set<String> onlineMemberIds;
  final String currentUserId;
  final String? Function(String? avatarPath) avatarUrlForPath;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  Widget build(BuildContext context) {
    final onlineMembers = group.members
        .where((member) => onlineMemberIds.contains(member.userId))
        .toList();
    final offlineMembers = group.members
        .where((member) => !onlineMemberIds.contains(member.userId))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${group.roleName.toUpperCase()} • ${group.members.length}',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            letterSpacing: 1.0,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        ...onlineMembers.map(
          (member) => _ServerMemberRow(
            member: member,
            online: true,
            isCurrentUser: member.userId == currentUserId,
            avatarUrl: avatarUrlForPath(member.avatarPath),
            onStartDirectMessage: onStartDirectMessage,
          ),
        ),
        if (onlineMembers.isNotEmpty && offlineMembers.isNotEmpty)
          const SizedBox(height: 8),
        ...offlineMembers.map(
          (member) => _ServerMemberRow(
            member: member,
            online: false,
            isCurrentUser: member.userId == currentUserId,
            avatarUrl: avatarUrlForPath(member.avatarPath),
            onStartDirectMessage: onStartDirectMessage,
          ),
        ),
      ],
    );
  }
}

class _ServerMemberRow extends StatelessWidget {
  const _ServerMemberRow({
    required this.member,
    required this.online,
    required this.isCurrentUser,
    required this.avatarUrl,
    required this.onStartDirectMessage,
  });

  final ServerMember member;
  final bool online;
  final bool isCurrentUser;
  final String? avatarUrl;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  Widget build(BuildContext context) {
    const onlineIndicatorColor = Color(0xFF34C759);
    const offlineIndicatorColor = Color(0xFF8E97A6);
    final indicatorColor = online
        ? onlineIndicatorColor
        : offlineIndicatorColor;
    return Builder(
      builder: (context) => GestureDetector(
        onSecondaryTapDown: isCurrentUser
            ? null
            : (details) {
                unawaited(_showMemberMenu(context, details.globalPosition));
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _UserAvatar(
                    displayName: member.displayName,
                    avatarUrl: avatarUrl,
                    size: 30,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: indicatorColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isCurrentUser
                      ? '${member.displayName} (you)'
                      : member.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: online ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMemberMenu(BuildContext context, Offset position) async {
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem<String>(value: 'dm', child: Text('Send direct message')),
      ],
    );
    if (selection == 'dm') {
      await onStartDirectMessage(
        userId: member.userId,
        displayName: member.displayName,
      );
    }
  }
}

class _ServerMemberRoleGroup {
  const _ServerMemberRoleGroup({
    required this.roleName,
    required this.members,
    required this.order,
  });

  final String roleName;
  final List<ServerMember> members;
  final int order;
}

class TextChannelView extends StatefulWidget {
  const TextChannelView({
    super.key,
    required this.channel,
    required this.repository,
    required this.currentUserId,
    required this.canSendMessages,
    required this.canManageMessages,
    required this.use24HourTime,
    required this.showTimestamps,
    required this.motionDuration,
    required this.animateMessages,
    required this.onMarkRead,
    required this.onStartDirectMessage,
  });

  final ChannelSummary channel;
  final WorkspaceRepository repository;
  final String currentUserId;
  final bool canSendMessages;
  final bool canManageMessages;
  final bool use24HourTime;
  final bool showTimestamps;
  final Duration motionDuration;
  final bool animateMessages;
  final Future<void> Function(DateTime timestamp) onMarkRead;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  State<TextChannelView> createState() => _TextChannelViewState();
}

class _TextChannelViewState extends State<TextChannelView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  ChannelMessage? _replyingTo;
  List<OutgoingMessageAttachment> _draftAttachments =
      <OutgoingMessageAttachment>[];
  String? _lastMarkedReadMessageId;
  List<ChannelMessage> _latestMessages = const <ChannelMessage>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!widget.canSendMessages || _sending) {
      return;
    }
    final text = _messageController.text;
    final attachments = List<OutgoingMessageAttachment>.from(_draftAttachments);
    if (text.trim().isEmpty && attachments.isEmpty) {
      return;
    }

    setState(() {
      _sending = true;
    });
    try {
      await widget.repository.sendChannelMessage(
        channelId: widget.channel.id,
        body: text,
        replyToMessage: _replyingTo,
        attachments: attachments,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _messageController.clear();
        _replyingTo = null;
        _draftAttachments = <OutgoingMessageAttachment>[];
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _toggleReaction(ChannelMessage message, String emoji) async {
    await widget.repository.toggleChannelMessageReaction(
      messageId: message.id,
      emoji: emoji,
    );
  }

  Future<void> _sendGif() async {
    if (!widget.canSendMessages ||
        !widget.repository.hasGiphyApiKey ||
        _sending) {
      return;
    }
    final gif = await showDialog<GiphyGifResult>(
      context: context,
      builder: (context) => _GiphyPickerDialog(repository: widget.repository),
    );
    if (gif == null) {
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      await widget.repository.sendChannelMessage(
        channelId: widget.channel.id,
        body: gif.gifUrl,
        replyToMessage: _replyingTo,
        attachments: List<OutgoingMessageAttachment>.from(_draftAttachments),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _replyingTo = null;
        _draftAttachments = <OutgoingMessageAttachment>[];
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _pickAttachments() async {
    if (!widget.canSendMessages || _sending) {
      return;
    }
    final attachments = await _pickComposerAttachments(
      context,
      existingCount: _draftAttachments.length,
    );
    if (!mounted || attachments.isEmpty) {
      return;
    }
    setState(() {
      _draftAttachments = <OutgoingMessageAttachment>[
        ..._draftAttachments,
        ...attachments,
      ];
    });
  }

  void _removeDraftAttachment(int index) {
    setState(() {
      _draftAttachments = List<OutgoingMessageAttachment>.from(
        _draftAttachments,
      )..removeAt(index);
    });
  }

  Future<void> _deleteMessage(ChannelMessage message) async {
    await widget.repository.deleteChannelMessage(message.id);
  }

  void _appendEmoji(String emoji) {
    final selection = _messageController.selection;
    final baseText = _messageController.text;
    final insertionPoint = selection.isValid
        ? selection.start
        : baseText.length;
    final nextText = baseText.replaceRange(
      insertionPoint,
      selection.isValid ? selection.end : insertionPoint,
      emoji,
    );
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: insertionPoint + emoji.length),
    );
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return true;
    }
    return _scrollController.position.extentAfter < 72;
  }

  void _handleScroll() {
    if (!_isNearBottom() || _latestMessages.isEmpty) {
      return;
    }
    final lastMessage = _latestMessages.last;
    if (_lastMarkedReadMessageId == lastMessage.id) {
      return;
    }
    _lastMarkedReadMessageId = lastMessage.id;
    unawaited(widget.onMarkRead(lastMessage.createdAt));
  }

  void _syncViewport(List<ChannelMessage> messages) {
    _latestMessages = messages;
    final shouldStickToBottom = _isNearBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (shouldStickToBottom && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
      if (!shouldStickToBottom || messages.isEmpty) {
        return;
      }
      final lastMessage = messages.last;
      if (_lastMarkedReadMessageId == lastMessage.id) {
        return;
      }
      _lastMarkedReadMessageId = lastMessage.id;
      unawaited(widget.onMarkRead(lastMessage.createdAt));
    });
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
                  _syncViewport(messages);
                  if (messages.isEmpty) {
                    return const Center(
                      child: Text('No messages yet. Start the conversation.'),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final previousMessage = index == 0
                          ? null
                          : messages[index - 1];
                      final groupedWithPrevious = _shouldGroupMessages(
                        previousSenderId: previousMessage?.senderId,
                        previousCreatedAt: previousMessage?.createdAt,
                        senderId: message.senderId,
                        createdAt: message.createdAt,
                      );
                      final canDelete =
                          message.senderId == widget.currentUserId ||
                          widget.canManageMessages;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == messages.length - 1
                              ? 0
                              : groupedWithPrevious
                              ? 6
                              : 12,
                        ),
                        child: _AnimatedMessageTile(
                          key: ValueKey<String>(message.id),
                          animate: widget.animateMessages,
                          duration: widget.motionDuration,
                          child: _ChatMessageCard(
                            repository: widget.repository,
                            senderId: message.senderId,
                            senderDisplayName: message.senderDisplayName,
                            senderAvatarPath: message.senderAvatarPath,
                            body: message.body,
                            attachments: message.attachments,
                            createdAt: message.createdAt,
                            use24HourTime: widget.use24HourTime,
                            showTimestamp: widget.showTimestamps,
                            showHeader: !groupedWithPrevious,
                            compactGroup: groupedWithPrevious,
                            replyToBody: message.replyToBody,
                            replyToSenderDisplayName:
                                message.replyToSenderDisplayName,
                            deleted: message.deleted,
                            reactions: message.reactions,
                            isOwnMessage:
                                message.senderId == widget.currentUserId,
                            canDelete: canDelete,
                            onReply: () async {
                              setState(() {
                                _replyingTo = message;
                              });
                            },
                            onToggleReaction: (emoji) =>
                                _toggleReaction(message, emoji),
                            onDelete: canDelete
                                ? () => _deleteMessage(message)
                                : null,
                            onOpenDirectMessage:
                                message.senderId == widget.currentUserId
                                ? null
                                : () => widget.onStartDirectMessage(
                                    userId: message.senderId,
                                    displayName: message.senderDisplayName,
                                  ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_draftAttachments.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ComposerAttachmentStrip(
                attachments: _draftAttachments,
                onRemove: _removeDraftAttachment,
              ),
            ],
            if (_replyingTo != null) ...[
              const SizedBox(height: 12),
              _ReplyBanner(
                senderDisplayName: _replyingTo!.senderDisplayName,
                body: _replyingTo!.body,
                onCancel: () {
                  setState(() {
                    _replyingTo = null;
                  });
                },
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: widget.canSendMessages && !_sending
                      ? () async {
                          final emoji = await _showEmojiPickerDialog(context);
                          if (emoji != null && mounted) {
                            _appendEmoji(emoji);
                          }
                        }
                      : null,
                  icon: const Icon(Icons.sentiment_satisfied_alt),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: widget.canSendMessages && !_sending
                      ? _pickAttachments
                      : null,
                  icon: const Icon(Icons.attach_file),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed:
                      widget.canSendMessages &&
                          widget.repository.hasGiphyApiKey &&
                          !_sending
                      ? _sendGif
                      : null,
                  icon: const Icon(Icons.gif_box_outlined),
                ),
                const SizedBox(width: 12),
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
                      enabled: widget.canSendMessages && !_sending,
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
                  onPressed: widget.canSendMessages && !_sending ? _send : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
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

class DirectMessageView extends StatefulWidget {
  const DirectMessageView({
    super.key,
    required this.conversation,
    required this.repository,
    required this.currentUserId,
    required this.use24HourTime,
    required this.showTimestamps,
    required this.motionDuration,
    required this.animateMessages,
    required this.onMarkRead,
    required this.onStartDirectMessage,
  });

  final DirectConversationSummary conversation;
  final WorkspaceRepository repository;
  final String currentUserId;
  final bool use24HourTime;
  final bool showTimestamps;
  final Duration motionDuration;
  final bool animateMessages;
  final Future<void> Function() onMarkRead;
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

  @override
  State<DirectMessageView> createState() => _DirectMessageViewState();
}

class _DirectMessageViewState extends State<DirectMessageView> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  DirectMessage? _replyingTo;
  List<OutgoingMessageAttachment> _draftAttachments =
      <OutgoingMessageAttachment>[];
  String? _lastMarkedReadMessageId;
  List<DirectMessage> _latestMessages = const <DirectMessage>[];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) {
      return;
    }
    final text = _messageController.text;
    final attachments = List<OutgoingMessageAttachment>.from(_draftAttachments);
    if (text.trim().isEmpty && attachments.isEmpty) {
      return;
    }

    setState(() {
      _sending = true;
    });
    try {
      await widget.repository.sendDirectMessage(
        conversationId: widget.conversation.conversationId,
        body: text,
        replyToMessage: _replyingTo,
        attachments: attachments,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _messageController.clear();
        _replyingTo = null;
        _draftAttachments = <OutgoingMessageAttachment>[];
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  void _appendEmoji(String emoji) {
    final selection = _messageController.selection;
    final baseText = _messageController.text;
    final insertionPoint = selection.isValid
        ? selection.start
        : baseText.length;
    final nextText = baseText.replaceRange(
      insertionPoint,
      selection.isValid ? selection.end : insertionPoint,
      emoji,
    );
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: insertionPoint + emoji.length),
    );
  }

  Future<void> _sendGif() async {
    if (!widget.repository.hasGiphyApiKey || _sending) {
      return;
    }
    final gif = await showDialog<GiphyGifResult>(
      context: context,
      builder: (context) => _GiphyPickerDialog(repository: widget.repository),
    );
    if (gif == null) {
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      await widget.repository.sendDirectMessage(
        conversationId: widget.conversation.conversationId,
        body: gif.gifUrl,
        replyToMessage: _replyingTo,
        attachments: List<OutgoingMessageAttachment>.from(_draftAttachments),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _replyingTo = null;
        _draftAttachments = <OutgoingMessageAttachment>[];
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _pickAttachments() async {
    if (_sending) {
      return;
    }
    final attachments = await _pickComposerAttachments(
      context,
      existingCount: _draftAttachments.length,
    );
    if (!mounted || attachments.isEmpty) {
      return;
    }
    setState(() {
      _draftAttachments = <OutgoingMessageAttachment>[
        ..._draftAttachments,
        ...attachments,
      ];
    });
  }

  void _removeDraftAttachment(int index) {
    setState(() {
      _draftAttachments = List<OutgoingMessageAttachment>.from(
        _draftAttachments,
      )..removeAt(index);
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      return true;
    }
    return _scrollController.position.extentAfter < 72;
  }

  void _handleScroll() {
    if (!_isNearBottom() || _latestMessages.isEmpty) {
      return;
    }
    final lastMessage = _latestMessages.last;
    if (lastMessage.senderId == widget.currentUserId ||
        _lastMarkedReadMessageId == lastMessage.id) {
      return;
    }
    _lastMarkedReadMessageId = lastMessage.id;
    unawaited(widget.onMarkRead());
  }

  void _syncViewport(List<DirectMessage> messages) {
    _latestMessages = messages;
    final shouldStickToBottom = _isNearBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (shouldStickToBottom && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
      if (!shouldStickToBottom || messages.isEmpty) {
        return;
      }
      final lastMessage = messages.last;
      if (lastMessage.senderId == widget.currentUserId ||
          _lastMarkedReadMessageId == lastMessage.id) {
        return;
      }
      _lastMarkedReadMessageId = lastMessage.id;
      unawaited(widget.onMarkRead());
    });
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
            Row(
              children: [
                _UserAvatar(
                  displayName: widget.conversation.otherDisplayName,
                  avatarUrl: widget.repository.publicProfileAvatarUrl(
                    widget.conversation.otherAvatarPath,
                  ),
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.conversation.otherDisplayName,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Direct messages',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: StreamBuilder<List<DirectMessage>>(
                stream: widget.repository.watchDirectMessages(
                  widget.conversation.conversationId,
                ),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(snapshot.error.toString()));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final messages = snapshot.data!;
                  _syncViewport(messages);
                  if (messages.isEmpty) {
                    return const Center(
                      child: Text('No direct messages yet. Say hello.'),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final previousMessage = index == 0
                          ? null
                          : messages[index - 1];
                      final groupedWithPrevious = _shouldGroupMessages(
                        previousSenderId: previousMessage?.senderId,
                        previousCreatedAt: previousMessage?.createdAt,
                        senderId: message.senderId,
                        createdAt: message.createdAt,
                      );
                      final canDelete =
                          message.senderId == widget.currentUserId;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == messages.length - 1
                              ? 0
                              : groupedWithPrevious
                              ? 6
                              : 12,
                        ),
                        child: _AnimatedMessageTile(
                          key: ValueKey<String>(message.id),
                          animate: widget.animateMessages,
                          duration: widget.motionDuration,
                          child: _ChatMessageCard(
                            repository: widget.repository,
                            senderId: message.senderId,
                            senderDisplayName: message.senderDisplayName,
                            senderAvatarPath: message.senderAvatarPath,
                            body: message.body,
                            attachments: message.attachments,
                            createdAt: message.createdAt,
                            use24HourTime: widget.use24HourTime,
                            showTimestamp: widget.showTimestamps,
                            showHeader: !groupedWithPrevious,
                            compactGroup: groupedWithPrevious,
                            replyToBody: message.replyToBody,
                            replyToSenderDisplayName:
                                message.replyToSenderDisplayName,
                            deleted: message.deleted,
                            reactions: message.reactions,
                            isOwnMessage:
                                message.senderId == widget.currentUserId,
                            canDelete: canDelete,
                            onReply: () async {
                              setState(() {
                                _replyingTo = message;
                              });
                            },
                            onToggleReaction: (emoji) async {
                              await widget.repository
                                  .toggleDirectMessageReaction(
                                    messageId: message.id,
                                    emoji: emoji,
                                  );
                            },
                            onDelete: canDelete
                                ? () => widget.repository.deleteDirectMessage(
                                    message.id,
                                  )
                                : null,
                            onOpenDirectMessage:
                                message.senderId == widget.currentUserId
                                ? null
                                : () => widget.onStartDirectMessage(
                                    userId: message.senderId,
                                    displayName: message.senderDisplayName,
                                  ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_draftAttachments.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ComposerAttachmentStrip(
                attachments: _draftAttachments,
                onRemove: _removeDraftAttachment,
              ),
            ],
            if (_replyingTo != null) ...[
              const SizedBox(height: 12),
              _ReplyBanner(
                senderDisplayName: _replyingTo!.senderDisplayName,
                body: _replyingTo!.body,
                onCancel: () {
                  setState(() {
                    _replyingTo = null;
                  });
                },
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _sending
                      ? null
                      : () async {
                          final emoji = await _showEmojiPickerDialog(context);
                          if (emoji != null && mounted) {
                            _appendEmoji(emoji);
                          }
                        },
                  icon: const Icon(Icons.sentiment_satisfied_alt),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: _sending ? null : _pickAttachments,
                  icon: const Icon(Icons.attach_file),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: widget.repository.hasGiphyApiKey && !_sending
                      ? _sendGif
                      : null,
                  icon: const Icon(Icons.gif_box_outlined),
                ),
                const SizedBox(width: 12),
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
                      enabled: !_sending,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Type a direct message...',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
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

class _ChatMessageCard extends StatefulWidget {
  const _ChatMessageCard({
    required this.repository,
    required this.senderId,
    required this.senderDisplayName,
    required this.senderAvatarPath,
    required this.body,
    required this.attachments,
    required this.createdAt,
    required this.use24HourTime,
    required this.showTimestamp,
    required this.showHeader,
    required this.compactGroup,
    required this.replyToBody,
    required this.replyToSenderDisplayName,
    required this.deleted,
    required this.reactions,
    required this.isOwnMessage,
    required this.canDelete,
    required this.onReply,
    required this.onToggleReaction,
    this.onDelete,
    this.onOpenDirectMessage,
  });

  final WorkspaceRepository repository;
  final String senderId;
  final String senderDisplayName;
  final String? senderAvatarPath;
  final String body;
  final List<MessageAttachment> attachments;
  final DateTime createdAt;
  final bool use24HourTime;
  final bool showTimestamp;
  final bool showHeader;
  final bool compactGroup;
  final String? replyToBody;
  final String? replyToSenderDisplayName;
  final bool deleted;
  final List<MessageReactionSummary> reactions;
  final bool isOwnMessage;
  final bool canDelete;
  final Future<void> Function() onReply;
  final Future<void> Function(String emoji) onToggleReaction;
  final Future<void> Function()? onDelete;
  final Future<void> Function()? onOpenDirectMessage;

  @override
  State<_ChatMessageCard> createState() => _ChatMessageCardState();
}

class _ChatMessageCardState extends State<_ChatMessageCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final trimmedBody = widget.body.trim();
    final gifUrl = _gifUrl(widget.body);
    final showTextBody =
        !widget.deleted && gifUrl == null && trimmedBody.isNotEmpty;
    final senderAvatarUrl = widget.repository.publicProfileAvatarUrl(
      widget.senderAvatarPath,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapDown: (details) {
          unawaited(_showMessageMenu(context, details.globalPosition));
        },
        child: Container(
          padding: EdgeInsets.fromLTRB(
            14,
            widget.compactGroup ? 10 : 14,
            14,
            14,
          ),
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 42,
                child: widget.showHeader
                    ? _UserAvatar(
                        displayName: widget.senderDisplayName,
                        avatarUrl: senderAvatarUrl,
                        size: 36,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: widget.showHeader
                              ? Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  children: [
                                    Text(
                                      widget.senderDisplayName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (widget.showTimestamp)
                                      Text(
                                        _formatTime(
                                          widget.createdAt,
                                          use24HourTime: widget.use24HourTime,
                                        ),
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                        AnimatedOpacity(
                          opacity: _hovered ? 1 : 0.18,
                          duration: const Duration(milliseconds: 140),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: widget.onReply,
                                icon: const Icon(Icons.reply, size: 18),
                                visualDensity: VisualDensity.compact,
                              ),
                              IconButton(
                                onPressed: () async {
                                  final emoji = await _showEmojiPickerDialog(
                                    context,
                                  );
                                  if (emoji != null) {
                                    await widget.onToggleReaction(emoji);
                                  }
                                },
                                icon: const Icon(
                                  Icons.emoji_emotions_outlined,
                                  size: 18,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              if (widget.canDelete)
                                IconButton(
                                  onPressed: widget.onDelete,
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.showHeader) const SizedBox(height: 8),
                    if (widget.replyToBody != null &&
                        widget.replyToBody!.trim().isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: palette.panel.withAlpha(180),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.replyToSenderDisplayName ?? 'Reply',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.replyToBody!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (gifUrl case final gifUrl?) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 360,
                            maxHeight: 260,
                          ),
                          child: Image.network(
                            gifUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Text(widget.body),
                          ),
                        ),
                      ),
                    ] else if (widget.deleted)
                      Text(
                        'Message deleted.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    else if (showTextBody)
                      Text(widget.body),
                    if (!widget.deleted && widget.attachments.isNotEmpty) ...[
                      if (gifUrl != null || showTextBody)
                        const SizedBox(height: 10),
                      _MessageAttachmentList(
                        repository: widget.repository,
                        attachments: widget.attachments,
                      ),
                    ],
                    if (widget.reactions.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: widget.reactions
                            .map(
                              (reaction) => FilterChip(
                                label: Text(
                                  '${reaction.emoji} ${reaction.count}',
                                ),
                                selected: reaction.includes(
                                  Supabase
                                          .instance
                                          .client
                                          .auth
                                          .currentUser
                                          ?.id ??
                                      '',
                                ),
                                onSelected: (_) {
                                  unawaited(
                                    widget.onToggleReaction(reaction.emoji),
                                  );
                                },
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMessageMenu(BuildContext context, Offset position) async {
    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(value: 'reply', child: Text('Reply')),
      const PopupMenuItem<String>(value: 'react', child: Text('Add reaction')),
    ];
    if (!widget.isOwnMessage && widget.onOpenDirectMessage != null) {
      items.add(
        const PopupMenuItem<String>(
          value: 'dm',
          child: Text('Send direct message'),
        ),
      );
    }
    if (widget.canDelete && widget.onDelete != null) {
      items.add(
        const PopupMenuItem<String>(
          value: 'delete',
          child: Text('Delete message'),
        ),
      );
    }

    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    );
    if (selection == null || !context.mounted) {
      return;
    }
    switch (selection) {
      case 'reply':
        await widget.onReply();
      case 'react':
        final emoji = await _showEmojiPickerDialog(context);
        if (emoji != null) {
          await widget.onToggleReaction(emoji);
        }
      case 'dm':
        await widget.onOpenDirectMessage?.call();
      case 'delete':
        await widget.onDelete?.call();
    }
  }

  String? _gifUrl(String body) {
    if (widget.deleted) {
      return null;
    }
    final trimmed = body.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.hasScheme && uri.hasAuthority)) {
      return null;
    }
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isGif =
        path.endsWith('.gif') ||
        path.contains('/media/') ||
        host.contains('giphy');
    return isGif ? trimmed : null;
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.senderDisplayName,
    required this.body,
    required this.onCancel,
  });

  final String senderDisplayName;
  final String body;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.panelStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to $senderDisplayName',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(body, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _ComposerAttachmentStrip extends StatelessWidget {
  const _ComposerAttachmentStrip({
    required this.attachments,
    required this.onRemove,
  });

  final List<OutgoingMessageAttachment> attachments;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.panelStrong,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var index = 0; index < attachments.length; index++)
            InputChip(
              avatar: Icon(
                _attachmentKindIcon(attachments[index].kind),
                size: 16,
              ),
              label: Text(
                '${attachments[index].fileName} (${_formatBytes(attachments[index].sizeBytes)})',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => onRemove(index),
            ),
        ],
      ),
    );
  }
}

class _MessageAttachmentList extends StatelessWidget {
  const _MessageAttachmentList({
    required this.repository,
    required this.attachments,
  });

  final WorkspaceRepository repository;
  final List<MessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < attachments.length; index++) ...[
          _MessageAttachmentTile(
            repository: repository,
            attachment: attachments[index],
          ),
          if (index != attachments.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _MessageAttachmentTile extends StatelessWidget {
  const _MessageAttachmentTile({
    required this.repository,
    required this.attachment,
  });

  final WorkspaceRepository repository;
  final MessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final attachmentUrl = repository.publicMessageAttachmentUrl(
      attachment.path,
    );
    if (attachmentUrl == null) {
      return const SizedBox.shrink();
    }

    if (attachment.isImage) {
      return InkWell(
        onTap: () => _copyAttachmentLink(
          context,
          fileName: attachment.fileName,
          url: attachmentUrl,
        ),
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 280),
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                Image.network(
                  attachmentUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      _AttachmentFileCard(
                        attachment: attachment,
                        onCopyLink: () => _copyAttachmentLink(
                          context,
                          fileName: attachment.fileName,
                          url: attachmentUrl,
                        ),
                      ),
                ),
                Container(
                  margin: const EdgeInsets.all(10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(170),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Copy link',
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _AttachmentFileCard(
      attachment: attachment,
      onCopyLink: () => _copyAttachmentLink(
        context,
        fileName: attachment.fileName,
        url: attachmentUrl,
      ),
    );
  }
}

class _AttachmentFileCard extends StatelessWidget {
  const _AttachmentFileCard({
    required this.attachment,
    required this.onCopyLink,
  });

  final MessageAttachment attachment;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.panel.withAlpha(180),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.panelAccent,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(_attachmentKindIcon(attachment.kind), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatBytes(attachment.sizeBytes),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onCopyLink,
            icon: const Icon(Icons.link, size: 16),
            label: const Text('Copy link'),
          ),
        ],
      ),
    );
  }
}

Future<List<OutgoingMessageAttachment>> _pickComposerAttachments(
  BuildContext context, {
  required int existingCount,
}) async {
  const maxAttachments = 8;
  const maxBytesPerAttachment = 25 * 1024 * 1024;

  final remainingSlots = maxAttachments - existingCount;
  if (remainingSlots <= 0) {
    showAppToast(context, 'You can attach up to $maxAttachments files.');
    return const <OutgoingMessageAttachment>[];
  }

  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,
    type: FileType.any,
  );
  if (result == null || !context.mounted) {
    return const <OutgoingMessageAttachment>[];
  }

  final attachments = <OutgoingMessageAttachment>[];
  var unreadableCount = 0;
  for (final file in result.files.take(remainingSlots)) {
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      unreadableCount++;
      continue;
    }
    if (bytes.lengthInBytes > maxBytesPerAttachment) {
      showAppToast(
        context,
        '${file.name} is larger than ${_formatBytes(maxBytesPerAttachment)}.',
        tone: AppToastTone.error,
      );
      continue;
    }
    attachments.add(
      OutgoingMessageAttachment(
        fileName: file.name,
        bytes: bytes,
        kind: _attachmentKindForFileName(file.name),
        contentType: _contentTypeForFileName(file.name),
      ),
    );
  }

  if (result.files.length > remainingSlots) {
    showAppToast(
      context,
      'Only the first $remainingSlots additional files were added.',
    );
  } else if (unreadableCount > 0 && attachments.isEmpty) {
    showAppToast(
      context,
      'Unable to read the selected file(s).',
      tone: AppToastTone.error,
    );
  }

  return attachments;
}

Future<void> _copyAttachmentLink(
  BuildContext context, {
  required String fileName,
  required String url,
}) async {
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) {
    return;
  }
  showAppToast(context, 'Copied link for $fileName.');
}

MessageAttachmentKind _attachmentKindForFileName(String fileName) {
  switch (_fileExtension(fileName)) {
    case '.png':
    case '.jpg':
    case '.jpeg':
    case '.gif':
    case '.webp':
    case '.bmp':
    case '.svg':
      return MessageAttachmentKind.image;
    case '.mp4':
    case '.mov':
    case '.webm':
      return MessageAttachmentKind.video;
    case '.mp3':
    case '.wav':
    case '.ogg':
    case '.m4a':
      return MessageAttachmentKind.audio;
    default:
      return MessageAttachmentKind.file;
  }
}

String? _contentTypeForFileName(String fileName) {
  switch (_fileExtension(fileName)) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.bmp':
      return 'image/bmp';
    case '.svg':
      return 'image/svg+xml';
    case '.mp4':
      return 'video/mp4';
    case '.mov':
      return 'video/quicktime';
    case '.webm':
      return 'video/webm';
    case '.mp3':
      return 'audio/mpeg';
    case '.wav':
      return 'audio/wav';
    case '.ogg':
      return 'audio/ogg';
    case '.m4a':
      return 'audio/mp4';
    case '.pdf':
      return 'application/pdf';
    case '.txt':
      return 'text/plain';
    case '.json':
      return 'application/json';
    default:
      return 'application/octet-stream';
  }
}

String _fileExtension(String fileName) {
  final separatorIndex = fileName.lastIndexOf('.');
  if (separatorIndex <= 0 || separatorIndex == fileName.length - 1) {
    return '';
  }
  return fileName.substring(separatorIndex).toLowerCase();
}

IconData _attachmentKindIcon(MessageAttachmentKind kind) {
  switch (kind) {
    case MessageAttachmentKind.image:
      return Icons.image_outlined;
    case MessageAttachmentKind.video:
      return Icons.movie_outlined;
    case MessageAttachmentKind.audio:
      return Icons.audio_file_outlined;
    case MessageAttachmentKind.file:
      return Icons.insert_drive_file_outlined;
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB';
}

String _messageActivityPreview({
  required String body,
  required List<MessageAttachment> attachments,
  required bool deleted,
}) {
  if (deleted) {
    return 'Message deleted.';
  }
  final normalizedBody = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalizedBody.isNotEmpty) {
    return normalizedBody.length <= 120
        ? normalizedBody
        : '${normalizedBody.substring(0, 117)}...';
  }
  if (attachments.isEmpty) {
    return 'New activity in ChitChat.';
  }
  return attachments.length == 1
      ? 'Sent an attachment.'
      : 'Sent ${attachments.length} attachments.';
}

Future<String?> _showEmojiPickerDialog(BuildContext context) async {
  const emojiOptions = <String>[
    '😀',
    '😂',
    '😍',
    '🔥',
    '👍',
    '👀',
    '🎉',
    '💯',
    '❤️',
    '🙏',
    '😅',
    '🤝',
  ];
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Choose emoji'),
      content: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: emojiOptions
            .map(
              (emoji) => InkWell(
                onTap: () => Navigator.of(context).pop(emoji),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(emoji, style: const TextStyle(fontSize: 26)),
                ),
              ),
            )
            .toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

class _GiphyPickerDialog extends StatefulWidget {
  const _GiphyPickerDialog({required this.repository});

  final WorkspaceRepository repository;

  @override
  State<_GiphyPickerDialog> createState() => _GiphyPickerDialogState();
}

class _GiphyPickerDialogState extends State<_GiphyPickerDialog> {
  final TextEditingController _queryController = TextEditingController();
  late Future<List<GiphyGifResult>> _resultsFuture;

  @override
  void initState() {
    super.initState();
    _resultsFuture = widget.repository.searchGifs();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  void _search() {
    setState(() {
      _resultsFuture = widget.repository.searchGifs(
        query: _queryController.text,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose GIF'),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: 'Search Giphy...',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<GiphyGifResult>>(
                future: _resultsFuture,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(snapshot.error.toString()));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final gifs = snapshot.data!;
                  if (gifs.isEmpty) {
                    return const Center(
                      child: Text('No GIFs found for that search.'),
                    );
                  }
                  return GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.05,
                        ),
                    itemCount: gifs.length,
                    itemBuilder: (context, index) {
                      final gif = gifs[index];
                      return InkWell(
                        onTap: () => Navigator.of(context).pop(gif),
                        borderRadius: BorderRadius.circular(16),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Theme.of(
                                context,
                              ).extension<AppThemePalette>()!.border,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.network(
                                  gif.previewUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                        ),
                                      ),
                                ),
                                Positioned(
                                  left: 8,
                                  right: 8,
                                  bottom: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withAlpha(170),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      gif.title.isEmpty ? 'GIF' : gif.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
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
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
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
        const PopupMenuItem<String>(
          value: 'volume_200',
          child: Text('Volume 200%'),
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
      case 'volume_200':
        await voiceController.setParticipantVolume(participant.clientId, 2);
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
                        icon: Icon(
                          voiceController.muted ? Icons.mic_off : Icons.mic,
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: voiceController.toggleDeafen,
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
                        icon: Icon(
                          voiceController.shareKind == ShareKind.screen
                              ? Icons.stop_screen_share
                              : Icons.screen_share,
                        ),
                      ),
                      IconButton.filled(
                        onPressed: voiceController.leave,
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
    required this.onStartDirectMessage,
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
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;
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
          onStartDirectMessage: widget.onStartDirectMessage,
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
        if (!participant.isSelf)
          const PopupMenuItem<String>(
            value: 'dm',
            child: Text('Send direct message'),
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
        const PopupMenuItem<String>(
          value: 'volume_200',
          child: Text('Volume 200%'),
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
      case 'dm':
        await widget.onStartDirectMessage(
          userId: participant.userId,
          displayName: participant.displayName,
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
      case 'volume_200':
        await voiceController.setParticipantVolume(participant.clientId, 2);
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
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(label: Text(voiceController.status)),
                      Text(
                        'Call controls live in the channel dock.',
                        style: Theme.of(context).textTheme.bodySmall,
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
                              max: 2.0,
                              divisions: 8,
                              value: participant.volume!
                                  .clamp(0.0, 2.0)
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
                'Desktop capture sources are loaded natively through flutter_webrtc. The selected resolution and frame rate are now published as chosen, using VP9 with fallback for compatibility.',
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

class _CreateServerDialogResult {
  const _CreateServerDialogResult({
    required this.name,
    required this.description,
    required this.isPublic,
  });

  final String name;
  final String description;
  final bool isPublic;
}

class _StartDirectMessageDialog extends StatefulWidget {
  const _StartDirectMessageDialog({required this.members});

  final List<ServerMember> members;

  @override
  State<_StartDirectMessageDialog> createState() =>
      _StartDirectMessageDialogState();
}

class _StartDirectMessageDialogState extends State<_StartDirectMessageDialog> {
  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final query = _queryController.text.trim().toLowerCase();
    final filteredMembers = widget.members
        .where(
          (member) =>
              query.isEmpty ||
              member.displayName.toLowerCase().contains(query) ||
              member.userId.toLowerCase().contains(query),
        )
        .toList();

    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Start direct message',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search members',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.panelMuted,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: palette.border),
                  ),
                  child: filteredMembers.isEmpty
                      ? const Center(
                          child: Text('No members matched that search.'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: filteredMembers.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final member = filteredMembers[index];
                            return InkWell(
                              onTap: () => Navigator.of(context).pop(member),
                              borderRadius: BorderRadius.circular(18),
                              child: Ink(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: palette.panelStrong,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(color: palette.border),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: palette.panelAccent,
                                        shape: BoxShape.circle,
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        member.displayName.characters.first
                                            .toUpperCase(),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            member.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            member.userId,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateServerDialog extends StatefulWidget {
  const _CreateServerDialog();

  @override
  State<_CreateServerDialog> createState() => _CreateServerDialogState();
}

class _CreateServerDialogState extends State<_CreateServerDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  bool _isPublic = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      _CreateServerDialogResult(
        name: _nameController.text,
        description: _descriptionController.text,
        isPublic: _isPublic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create server'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Server name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              minLines: 2,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'What is this server for?',
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isPublic,
              title: const Text('Public server'),
              subtitle: Text(
                _isPublic
                    ? 'People can join immediately from discovery.'
                    : 'People can discover it, but must request to join.',
              ),
              onChanged: (value) {
                setState(() {
                  _isPublic = value;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _ServerDiscoveryDialog extends StatefulWidget {
  const _ServerDiscoveryDialog({
    required this.repository,
    required this.avatarUrlForPath,
  });

  final WorkspaceRepository repository;
  final String? Function(String? avatarPath) avatarUrlForPath;

  @override
  State<_ServerDiscoveryDialog> createState() => _ServerDiscoveryDialogState();
}

class _ServerDiscoveryDialogState extends State<_ServerDiscoveryDialog> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  bool _loading = true;
  String? _error;
  List<DiscoverableServerSummary> _results =
      const <DiscoverableServerSummary>[];

  @override
  void initState() {
    super.initState();
    unawaited(_loadResults());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadResults() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.repository.searchJoinableServers(
        query: _searchController.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _handleServerAction(DiscoverableServerSummary server) async {
    try {
      if (server.isMember) {
        Navigator.of(context).pop(server.id);
        return;
      }
      if (server.isPublic) {
        await widget.repository.joinPublicServer(server.id);
        if (!mounted) {
          return;
        }
        Navigator.of(context).pop(server.id);
        return;
      }
      await widget.repository.requestServerJoin(server.id);
      if (!mounted) {
        return;
      }
      showAppToast(
        context,
        'Join request sent to ${server.name}.',
        tone: AppToastTone.success,
      );
      await _loadResults();
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                          'Discover servers',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Search servers by name or description. Public servers can be joined immediately; private servers require approval.',
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search servers',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(
                    const Duration(milliseconds: 250),
                    () => unawaited(_loadResults()),
                  );
                },
                onSubmitted: (_) => unawaited(_loadResults()),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.panelMuted,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: palette.border),
                  ),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(_error!, textAlign: TextAlign.center),
                          ),
                        )
                      : _results.isEmpty
                      ? const Center(
                          child: Text('No servers matched your search.'),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _results.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final server = _results[index];
                            final actionLabel = server.isMember
                                ? 'Open'
                                : server.isPublic
                                ? 'Join'
                                : server.hasPendingRequest
                                ? 'Requested'
                                : 'Request';
                            final canAct =
                                server.isMember || !server.hasPendingRequest;
                            return Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: palette.panelStrong,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: palette.border),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: SizedBox(
                                      width: 60,
                                      height: 60,
                                      child: _ServerAvatar(
                                        name: server.name,
                                        avatarUrl: widget.avatarUrlForPath(
                                          server.avatarPath,
                                        ),
                                        selected: false,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              server.name,
                                              style: const TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            Chip(
                                              label: Text(
                                                server.isPublic
                                                    ? 'Public'
                                                    : 'Private',
                                              ),
                                            ),
                                            Chip(
                                              label: Text(
                                                '${server.memberCount} member${server.memberCount == 1 ? '' : 's'}',
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (server.description
                                            .trim()
                                            .isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 8,
                                            ),
                                            child: Text(server.description),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  FilledButton.tonal(
                                    onPressed: canAct
                                        ? () => _handleServerAction(server)
                                        : null,
                                    child: Text(actionLabel),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    required this.onStartDirectMessage,
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
  final Future<void> Function({
    required String userId,
    required String displayName,
  })
  onStartDirectMessage;

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
              onStartDirectMessage: onStartDirectMessage,
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

bool _shouldGroupMessages({
  required String? previousSenderId,
  required DateTime? previousCreatedAt,
  required String senderId,
  required DateTime createdAt,
}) {
  if (previousSenderId == null || previousCreatedAt == null) {
    return false;
  }
  if (previousSenderId != senderId) {
    return false;
  }
  return createdAt.difference(previousCreatedAt) < const Duration(minutes: 5);
}

String _formatTime(DateTime timestamp, {bool use24HourTime = false}) {
  final hours = timestamp.hour;
  final minutes = timestamp.minute.toString().padLeft(2, '0');
  if (use24HourTime) {
    return '${hours.toString().padLeft(2, '0')}:$minutes';
  }
  final suffix = hours >= 12 ? 'PM' : 'AM';
  final normalizedHour = hours % 12 == 0 ? 12 : hours % 12;
  return '$normalizedHour:$minutes $suffix';
}
