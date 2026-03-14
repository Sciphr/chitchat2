import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_preferences.dart';
import 'app_toast.dart';
import 'models.dart';
import 'repositories.dart';

class ServerSettingsDialog extends StatefulWidget {
  const ServerSettingsDialog({
    super.key,
    required this.server,
    required this.repository,
    required this.access,
    required this.onCopyInvite,
    required this.onCreateChannel,
    required this.onCreateCategory,
    required this.onPickServerAvatar,
    this.onStateChanged,
    this.onPendingJoinRequestsChanged,
  });

  final ServerSummary server;
  final WorkspaceRepository repository;
  final ServerAccess access;
  final Future<void> Function() onCopyInvite;
  final Future<void> Function() onCreateChannel;
  final Future<void> Function() onCreateCategory;
  final Future<void> Function() onPickServerAvatar;
  final void Function({
    required ServerSummary server,
    required List<ServerRole> roles,
    required List<ServerMember> members,
  })?
  onStateChanged;
  final ValueChanged<int>? onPendingJoinRequestsChanged;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late ServerSummary _server = widget.server;
  bool _loading = true;
  bool _loadingOverrides = false;
  bool _loadingJoinRequests = false;
  bool _saving = false;
  String? _error;
  List<ChannelSummary> _channels = const <ChannelSummary>[];
  List<ServerRole> _roles = const <ServerRole>[];
  List<ServerMember> _members = const <ServerMember>[];
  List<ServerJoinRequestSummary> _joinRequests =
      const <ServerJoinRequestSummary>[];
  List<ChannelPermissionOverride> _channelOverrides =
      const <ChannelPermissionOverride>[];
  String? _selectedOverrideChannelId;
  RealtimeChannel? _joinRequestsChannel;
  List<ServerBan> _bans = const <ServerBan>[];
  bool _loadingBans = false;
  List<AuditLogEntry> _auditLog = const <AuditLogEntry>[];
  bool _loadingAuditLog = false;
  String? _auditLogActionFilter;

  bool get _canManageRoles =>
      widget.access.hasPermission(ServerPermission.manageRoles);
  bool get _canManageChannels =>
      widget.access.hasPermission(ServerPermission.manageChannels);
  bool get _canInviteMembers =>
      widget.access.hasPermission(ServerPermission.inviteMembers);
  bool get _canManageServer =>
      widget.access.hasPermission(ServerPermission.manageServer);
  bool get _canBanMembers =>
      widget.access.hasPermission(ServerPermission.banMembers);
  bool get _canReviewJoinRequests =>
      widget.access.isOwner || _canInviteMembers || _canManageServer;
  bool get _canEditServerPicture => widget.access.isOwner;

  ChannelSummary? get _selectedOverrideChannel {
    final selectedId = _selectedOverrideChannelId;
    if (selectedId == null) {
      return null;
    }
    for (final channel in _channels) {
      if (channel.id == selectedId) {
        return channel;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_closeJoinRequestsChannel());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait<dynamic>([
        widget.repository.fetchChannels(_server.id),
        widget.repository.fetchServerRoles(_server.id),
        widget.repository.fetchServerMembers(_server.id),
      ]);
      if (!mounted) {
        return;
      }
      final channels = results[0] as List<ChannelSummary>;
      setState(() {
        _channels = channels;
        _roles = results[1] as List<ServerRole>;
        _members = results[2] as List<ServerMember>;
        _selectedOverrideChannelId = channels.isEmpty
            ? null
            : channels.first.id;
        _loading = false;
      });
      _publishStateChange();
      await _loadChannelOverrides();
      if (_canReviewJoinRequests) {
        await _loadJoinRequests();
        await _subscribeJoinRequestUpdates();
      }
      if (_canBanMembers) {
        await _loadBans();
      }
      if (_canManageServer) {
        await _loadAuditLog();
      }
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

  Future<void> _loadJoinRequests({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loadingJoinRequests = true;
      });
    }
    try {
      final requests = await widget.repository.fetchServerJoinRequests(
        _server.id,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _joinRequests = requests;
        _loadingJoinRequests = false;
      });
      _publishJoinRequestCount();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loadingJoinRequests = false;
      });
    }
  }

  void _publishJoinRequestCount() {
    widget.onPendingJoinRequestsChanged?.call(_joinRequests.length);
  }

  Future<void> _closeJoinRequestsChannel() async {
    final joinRequestsChannel = _joinRequestsChannel;
    _joinRequestsChannel = null;
    if (joinRequestsChannel != null) {
      await widget.repository.client.removeChannel(joinRequestsChannel);
    }
  }

  Future<void> _subscribeJoinRequestUpdates() async {
    await _closeJoinRequestsChannel();
    if (!_canReviewJoinRequests || !mounted) {
      return;
    }

    final client = widget.repository.client;
    final completer = Completer<void>();
    final realtimeChannel = client
        .channel('server-settings-join-requests:${_server.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'server_join_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'server_id',
            value: _server.id,
          ),
          callback: (_) {
            if (mounted) {
              unawaited(_loadJoinRequests(showLoading: false));
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
              'Realtime join request error'
              '${error == null ? '' : ': $error'}',
            ),
          );
        case RealtimeSubscribeStatus.closed:
          completer.completeError(
            StateError('Realtime join request channel closed.'),
          );
        case RealtimeSubscribeStatus.timedOut:
          completer.completeError(
            StateError('Realtime join request channel timed out.'),
          );
      }
    });

    try {
      await completer.future;
      if (!mounted) {
        await client.removeChannel(realtimeChannel);
        return;
      }
      _joinRequestsChannel = realtimeChannel;
    } catch (error) {
      await client.removeChannel(realtimeChannel);
      debugPrint(
        'Join request dialog subscription failed for ${_server.id}: $error',
      );
    }
  }

  Future<void> _loadBans() async {
    setState(() => _loadingBans = true);
    try {
      final bans = await widget.repository.fetchServerBans(_server.id);
      if (!mounted) return;
      setState(() {
        _bans = bans;
        _loadingBans = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingBans = false);
    }
  }

  Future<void> _loadAuditLog({String? actionFilter}) async {
    setState(() {
      _loadingAuditLog = true;
      _auditLogActionFilter = actionFilter;
    });
    try {
      final entries = await widget.repository.fetchAuditLog(
        serverId: _server.id,
        actionFilter: actionFilter,
      );
      if (!mounted) return;
      setState(() {
        _auditLog = entries;
        _loadingAuditLog = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingAuditLog = false);
    }
  }

  Future<void> _banMember(ServerMember member) async {
    String? reason;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final reasonController = TextEditingController();
        return AlertDialog(
          title: Text('Ban ${member.displayName}?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('This will remove them from the server and prevent rejoining.'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                decoration: const InputDecoration(labelText: 'Reason (optional)'),
                onChanged: (v) => reason = v.trim().isEmpty ? null : v.trim(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Ban'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.banMember(
        serverId: _server.id,
        userId: member.userId,
        reason: reason,
      );
      if (!mounted) return;
      await _loadBans();
      await _load();
    } catch (error) {
      if (mounted) {
        showAppToast(context, 'Failed to ban: $error', tone: AppToastTone.error);
      }
    }
  }

  Future<void> _unbanMember(ServerBan ban) async {
    try {
      await widget.repository.unbanMember(
        serverId: _server.id,
        userId: ban.userId,
      );
      if (!mounted) return;
      await _loadBans();
    } catch (error) {
      if (mounted) {
        showAppToast(context, 'Failed to unban: $error', tone: AppToastTone.error);
      }
    }
  }

  Future<void> _loadChannelOverrides() async {
    final selectedChannel = _selectedOverrideChannel;
    if (selectedChannel == null) {
      if (mounted) {
        setState(() {
          _channelOverrides = const <ChannelPermissionOverride>[];
          _loadingOverrides = false;
        });
      }
      return;
    }

    setState(() {
      _loadingOverrides = true;
    });

    try {
      final overrides = await widget.repository.fetchChannelPermissionOverrides(
        selectedChannel.id,
      );
      if (!mounted || _selectedOverrideChannelId != selectedChannel.id) {
        return;
      }
      setState(() {
        _channelOverrides = overrides;
        _loadingOverrides = false;
      });
    } catch (error) {
      if (!mounted || _selectedOverrideChannelId != selectedChannel.id) {
        return;
      }
      setState(() {
        _error = error.toString();
        _loadingOverrides = false;
      });
    }
  }

  Future<void> _createRole() async {
    if (!_canManageRoles) {
      return;
    }

    final result = await showDialog<_RoleEditorResult>(
      context: context,
      builder: (context) => const _RoleEditorDialog(
        title: 'Create role',
        submitLabel: 'Create role',
      ),
    );
    if (result == null) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      final createdRole = await widget.repository.createRole(
        serverId: widget.server.id,
        name: result.name,
        colorHex: result.colorHex,
        permissions: result.permissions,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _roles = <ServerRole>[..._roles, createdRole];
      });
      _publishStateChange();
      showAppToast(context, 'Role created.', tone: AppToastTone.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  bool _canEditRole(ServerRole role) {
    if (!_canManageRoles) {
      return false;
    }
    return widget.access.isOwner || !_isProtectedOwnerRole(role);
  }

  Future<void> _editRole(ServerRole role) async {
    if (!_canEditRole(role)) {
      return;
    }

    final result = await showDialog<_RoleEditorResult>(
      context: context,
      builder: (context) => _RoleEditorDialog(
        title: 'Edit role',
        submitLabel: 'Save changes',
        initialName: role.name,
        initialColorHex: role.colorHex,
        initialPermissions: role.permissions,
      ),
    );
    if (result == null) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      final updatedRole = await widget.repository.updateRole(
        roleId: role.id,
        name: result.name,
        colorHex: result.colorHex,
        permissions: result.permissions,
      );
      if (!mounted) {
        return;
      }
      _replaceRole(updatedRole);
      showAppToast(context, 'Role updated.', tone: AppToastTone.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _editMemberRoles(ServerMember member) async {
    if (!_canManageRoles) {
      return;
    }

    final nextSelection = await showDialog<Set<String>>(
      context: context,
      builder: (context) => _MemberRoleDialog(
        member: member,
        roles: _roles,
        serverOwnerId: widget.server.ownerId,
      ),
    );
    if (nextSelection == null) {
      return;
    }

    await _saveMemberRoleSelections(
      selectionsByUserId: <String, Set<String>>{member.userId: nextSelection},
      successMessage: 'Updated roles for ${member.displayName}.',
    );
  }

  Future<void> _editSelectedMemberRoles(List<ServerMember> members) async {
    if (!_canManageRoles || members.isEmpty) {
      return;
    }
    if (members.length == 1) {
      await _editMemberRoles(members.single);
      return;
    }

    final result = await showDialog<_BulkMemberRoleEditorResult>(
      context: context,
      builder: (context) => _BulkMemberRoleDialog(
        members: members,
        roles: _roles,
        serverOwnerId: widget.server.ownerId,
      ),
    );
    if (result == null) {
      return;
    }

    final selectionsByUserId = <String, Set<String>>{};
    for (final member in members) {
      final nextRoleIds = member.roleIds.toSet()
        ..addAll(result.roleIdsToAdd)
        ..removeAll(result.roleIdsToRemove);
      selectionsByUserId[member.userId] = nextRoleIds;
    }

    await _saveMemberRoleSelections(
      selectionsByUserId: selectionsByUserId,
      successMessage: 'Updated roles for ${members.length} members.',
    );
  }

  Future<void> _saveMemberRoleSelections({
    required Map<String, Set<String>> selectionsByUserId,
    required String successMessage,
  }) async {
    final membersByUserId = {
      for (final member in _members) member.userId: member,
    };
    final operations =
        <
          ({
            String userId,
            Set<String> roleIdsToAdd,
            Set<String> roleIdsToRemove,
          })
        >[];
    for (final entry in selectionsByUserId.entries) {
      final member = membersByUserId[entry.key];
      if (member == null) {
        continue;
      }
      final roleIdsToAdd = entry.value.difference(member.roleIds);
      final roleIdsToRemove = member.roleIds.difference(entry.value);
      if (roleIdsToAdd.isEmpty && roleIdsToRemove.isEmpty) {
        continue;
      }
      operations.add((
        userId: entry.key,
        roleIdsToAdd: roleIdsToAdd,
        roleIdsToRemove: roleIdsToRemove,
      ));
    }
    if (operations.isEmpty) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      for (final operation in operations) {
        for (final roleId in operation.roleIdsToAdd) {
          await widget.repository.assignRole(
            serverId: widget.server.id,
            userId: operation.userId,
            roleId: roleId,
          );
        }
        for (final roleId in operation.roleIdsToRemove) {
          await widget.repository.removeRole(
            serverId: widget.server.id,
            userId: operation.userId,
            roleId: roleId,
          );
        }
      }
      if (!mounted) {
        return;
      }
      _applyMemberRoleSelectionsLocally(selectionsByUserId);
      showAppToast(context, successMessage, tone: AppToastTone.success);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppToast(context, error.toString(), tone: AppToastTone.error);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _editChannelOverride(ServerRole role) async {
    if (!_canManageChannels) {
      return;
    }

    final selectedChannel = _selectedOverrideChannel;
    if (selectedChannel == null) {
      return;
    }

    ChannelPermissionOverride? existingOverride;
    for (final overrideEntry in _channelOverrides) {
      if (overrideEntry.roleId == role.id) {
        existingOverride = overrideEntry;
        break;
      }
    }

    final result = await showDialog<_ChannelOverrideEditorResult>(
      context: context,
      builder: (context) => _ChannelOverrideDialog(
        role: role,
        channel: selectedChannel,
        initialAllow:
            existingOverride?.allowPermissions ?? const <ServerPermission>{},
        initialDeny:
            existingOverride?.denyPermissions ?? const <ServerPermission>{},
      ),
    );
    if (result == null) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      await widget.repository.saveChannelPermissionOverride(
        channelId: selectedChannel.id,
        roleId: role.id,
        allowPermissions: result.allowPermissions,
        denyPermissions: result.denyPermissions,
      );
      if (!mounted) {
        return;
      }
      _applyChannelOverrideLocally(
        channelId: selectedChannel.id,
        roleId: role.id,
        allowPermissions: result.allowPermissions,
        denyPermissions: result.denyPermissions,
      );
      showAppToast(
        context,
        'Updated access for ${role.name}.',
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
          _saving = false;
        });
      }
    }
  }

  Future<void> _runGeneralAction(Future<void> Function() action) async {
    await action();
    if (!mounted) {
      return;
    }
    await _load();
  }

  void _replaceRole(ServerRole updatedRole) {
    setState(() {
      final nextRoles = List<ServerRole>.from(_roles);
      final existingIndex = nextRoles.indexWhere(
        (role) => role.id == updatedRole.id,
      );
      if (existingIndex == -1) {
        nextRoles.add(updatedRole);
      } else {
        nextRoles[existingIndex] = updatedRole;
      }
      _roles = nextRoles;
    });
    _publishStateChange();
  }

  void _applyMemberRoleSelectionsLocally(
    Map<String, Set<String>> selectionsByUserId,
  ) {
    setState(() {
      _members = _members
          .map((member) {
            final nextRoleIds = selectionsByUserId[member.userId];
            if (nextRoleIds == null) {
              return member;
            }
            return ServerMember(
              userId: member.userId,
              displayName: member.displayName,
              avatarPath: member.avatarPath,
              joinedAt: member.joinedAt,
              roleIds: nextRoleIds,
            );
          })
          .toList(growable: false);
    });
    _publishStateChange();
  }

  void _applyChannelOverrideLocally({
    required String channelId,
    required String roleId,
    required Set<ServerPermission> allowPermissions,
    required Set<ServerPermission> denyPermissions,
  }) {
    if (_selectedOverrideChannelId != channelId) {
      return;
    }
    setState(() {
      final nextOverrides = _channelOverrides
          .where((overrideEntry) => overrideEntry.roleId != roleId)
          .toList(growable: true);
      if (allowPermissions.isNotEmpty || denyPermissions.isNotEmpty) {
        nextOverrides.add(
          ChannelPermissionOverride(
            channelId: channelId,
            roleId: roleId,
            allowPermissions: allowPermissions,
            denyPermissions: denyPermissions,
          ),
        );
      }
      _channelOverrides = nextOverrides;
    });
  }

  void _publishStateChange() {
    widget.onStateChanged?.call(
      server: _server,
      roles: List<ServerRole>.unmodifiable(_roles),
      members: List<ServerMember>.unmodifiable(_members),
    );
  }

  Future<void> _updateDiscoverySettings({
    required bool isPublic,
    required String description,
  }) async {
    setState(() {
      _saving = true;
    });
    try {
      final updatedServer = await widget.repository
          .updateServerDiscoverySettings(
            serverId: _server.id,
            isPublic: isPublic,
            description: description,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _server = updatedServer;
      });
      _publishStateChange();
      showAppToast(
        context,
        'Server visibility updated.',
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
          _saving = false;
        });
      }
    }
  }

  Future<void> _reviewJoinRequest(
    ServerJoinRequestSummary request, {
    required bool approve,
  }) async {
    setState(() {
      _saving = true;
    });
    try {
      await widget.repository.decideServerJoinRequest(
        requestId: request.id,
        approve: approve,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _joinRequests = _joinRequests
            .where((entry) => entry.id != request.id)
            .toList(growable: false);
      });
      _publishJoinRequestCount();
      showAppToast(
        context,
        approve
            ? 'Approved ${request.displayName}.'
            : 'Declined ${request.displayName}.',
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
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
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
                          '${_server.name} settings',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ActionChip(
                              onPressed: () =>
                                  _runGeneralAction(widget.onCopyInvite),
                              avatar: const Icon(Icons.content_copy, size: 18),
                              label: Text('Invite ${_server.inviteCode}'),
                            ),
                            if (widget.access.isOwner)
                              const Chip(label: Text('Owner')),
                            if (_saving) const Chip(label: Text('Saving...')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!),
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : DefaultTabController(
                        length: 4 +
                            (_canReviewJoinRequests ? 1 : 0) +
                            (_canBanMembers ? 1 : 0) +
                            (_canManageServer ? 1 : 0),
                        child: Column(
                          children: [
                            TabBar(
                              isScrollable: true,
                              tabAlignment: TabAlignment.start,
                              tabs: [
                                const Tab(text: 'General'),
                                const Tab(text: 'Roles'),
                                const Tab(text: 'Members'),
                                const Tab(text: 'Channel Access'),
                                if (_canReviewJoinRequests)
                                  Tab(
                                    child: _SettingsTabLabel(
                                      text: 'Join Requests',
                                      badgeCount: _joinRequests.length,
                                    ),
                                  ),
                                if (_canBanMembers)
                                  const Tab(text: 'Bans'),
                                if (_canManageServer)
                                  const Tab(text: 'Audit Log'),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  _GeneralTab(
                                    server: _server,
                                    canInviteMembers: _canInviteMembers,
                                    canManageChannels: _canManageChannels,
                                    canManageServer: _canManageServer,
                                    canEditServerPicture: _canEditServerPicture,
                                    onCopyInvite: () =>
                                        _runGeneralAction(widget.onCopyInvite),
                                    onCreateChannel: () => _runGeneralAction(
                                      widget.onCreateChannel,
                                    ),
                                    onCreateCategory: () => _runGeneralAction(
                                      widget.onCreateCategory,
                                    ),
                                    onPickServerAvatar: () => _runGeneralAction(
                                      widget.onPickServerAvatar,
                                    ),
                                    onUpdateDiscoverySettings:
                                        _updateDiscoverySettings,
                                  ),
                                  _RolesTab(
                                    roles: _roles,
                                    members: _members,
                                    canManageRoles: _canManageRoles,
                                    canEditRole: _canEditRole,
                                    onCreateRole: _createRole,
                                    onEditRole: _editRole,
                                  ),
                                  _MembersTab(
                                    server: _server,
                                    roles: _roles,
                                    members: _members,
                                    canManageRoles: _canManageRoles,
                                    onEditMemberRoles: _editMemberRoles,
                                    onEditSelectedMembers:
                                        _editSelectedMemberRoles,
                                    canBanMembers: _canBanMembers,
                                    onBanMember: _banMember,
                                  ),
                                  _ChannelAccessTab(
                                    channels: _channels,
                                    roles: _roles,
                                    loadingOverrides: _loadingOverrides,
                                    selectedChannelId:
                                        _selectedOverrideChannelId,
                                    overrides: _channelOverrides,
                                    canManageChannels: _canManageChannels,
                                    onSelectChannel: (channelId) async {
                                      setState(() {
                                        _selectedOverrideChannelId = channelId;
                                      });
                                      await _loadChannelOverrides();
                                    },
                                    onEditOverride: _editChannelOverride,
                                  ),
                                  if (_canReviewJoinRequests)
                                    _JoinRequestsTab(
                                      loading: _loadingJoinRequests,
                                      requests: _joinRequests,
                                      onApprove: (request) =>
                                          _reviewJoinRequest(
                                            request,
                                            approve: true,
                                          ),
                                      onReject: (request) => _reviewJoinRequest(
                                        request,
                                        approve: false,
                                      ),
                                    ),
                                  if (_canBanMembers)
                                    _BansTab(
                                      loading: _loadingBans,
                                      bans: _bans,
                                      onUnban: _unbanMember,
                                    ),
                                  if (_canManageServer)
                                    _AuditLogTab(
                                      loading: _loadingAuditLog,
                                      entries: _auditLog,
                                      actionFilter: _auditLogActionFilter,
                                      onFilterChanged: (filter) =>
                                          _loadAuditLog(actionFilter: filter),
                                    ),
                                ],
                              ),
                            ),
                          ],
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

class _SettingsTabLabel extends StatelessWidget {
  const _SettingsTabLabel({required this.text, required this.badgeCount});

  final String text;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        if (badgeCount > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              badgeCount > 99 ? '99+' : '$badgeCount',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GeneralTab extends StatelessWidget {
  const _GeneralTab({
    required this.server,
    required this.canInviteMembers,
    required this.canManageChannels,
    required this.canManageServer,
    required this.canEditServerPicture,
    required this.onCopyInvite,
    required this.onCreateChannel,
    required this.onCreateCategory,
    required this.onPickServerAvatar,
    required this.onUpdateDiscoverySettings,
  });

  final ServerSummary server;
  final bool canInviteMembers;
  final bool canManageChannels;
  final bool canManageServer;
  final bool canEditServerPicture;
  final Future<void> Function() onCopyInvite;
  final Future<void> Function() onCreateChannel;
  final Future<void> Function() onCreateCategory;
  final Future<void> Function() onPickServerAvatar;
  final Future<void> Function({
    required bool isPublic,
    required String description,
  })
  onUpdateDiscoverySettings;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final theme = Theme.of(context);
    final mutedStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withAlpha(140),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // ── Identity ──────────────────────────────────────────────────
        _GeneralSection(
          title: 'Server Identity',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar
                  Stack(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: palette.panelAccent,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: palette.border),
                        ),
                        child: Center(
                          child: Text(
                            server.name.isNotEmpty
                                ? server.name[0].toUpperCase()
                                : '?',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (canEditServerPicture)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: onPickServerAvatar,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: palette.panelStrong,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.edit,
                                size: 13,
                                color: theme.colorScheme.onPrimary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Created ${_formatServerDate(server.createdAt)}',
                          style: mutedStyle,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'ID: ${server.id}',
                          style: mutedStyle?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: 'Copy server ID',
                    child: IconButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: server.id));
                        if (!context.mounted) return;
                        showAppToast(
                          context,
                          'Server ID copied.',
                          tone: AppToastTone.success,
                        );
                      },
                      icon: const Icon(Icons.badge_outlined, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Access ────────────────────────────────────────────────────
        _GeneralSection(
          title: 'Access',
          children: [
            _GeneralRow(
              icon: Icons.link,
              label: 'Invite Code',
              value: server.inviteCode,
              trailing: Tooltip(
                message: 'Copy invite link',
                child: IconButton(
                  onPressed: onCopyInvite,
                  icon: const Icon(Icons.content_copy, size: 18),
                ),
              ),
            ),
            Divider(height: 1, color: palette.border),
            _GeneralRow(
              icon: server.isPublic
                  ? Icons.public
                  : Icons.lock_outline,
              label: 'Visibility',
              value: server.isPublic ? 'Public' : 'Private',
              trailing: canManageServer
                  ? TextButton(
                      onPressed: () async {
                        final result =
                            await showDialog<_ServerDiscoverySettingsResult>(
                              context: context,
                              builder: (context) =>
                                  _ServerDiscoverySettingsDialog(
                                    initialIsPublic: server.isPublic,
                                    initialDescription: server.description,
                                  ),
                            );
                        if (result == null) return;
                        await onUpdateDiscoverySettings(
                          isPublic: result.isPublic,
                          description: result.description,
                        );
                      },
                      child: const Text('Edit'),
                    )
                  : null,
            ),
            if (server.description.trim().isNotEmpty) ...[
              Divider(height: 1, color: palette.border),
              _GeneralRow(
                icon: Icons.info_outline,
                label: 'Description',
                value: server.description.trim(),
              ),
            ],
          ],
        ),

        // ── Channel management ────────────────────────────────────────
        if (canManageChannels) ...[
          const SizedBox(height: 16),
          _GeneralSection(
            title: 'Channels',
            children: [
              _GeneralRow(
                icon: Icons.add_comment_outlined,
                label: 'Create channel',
                value: 'Add a new text or voice channel',
                onTap: onCreateChannel,
              ),
              Divider(height: 1, color: palette.border),
              _GeneralRow(
                icon: Icons.create_new_folder_outlined,
                label: 'Create category',
                value: 'Group channels under a category',
                onTap: onCreateCategory,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _GeneralSection extends StatelessWidget {
  const _GeneralSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withAlpha(160),
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _GeneralRow extends StatelessWidget {
  const _GeneralRow({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedColor = theme.colorScheme.onSurface.withAlpha(140);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: mutedColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: mutedColor,
                  ),
                ),
              ],
            ),
          ),
          if (trailing case final t?) t,
          if (onTap != null && trailing == null)
            Icon(Icons.chevron_right, size: 18, color: mutedColor),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(onTap: onTap, child: row);
    }
    return row;
  }
}

class _RolesTab extends StatelessWidget {
  const _RolesTab({
    required this.roles,
    required this.members,
    required this.canManageRoles,
    required this.canEditRole,
    required this.onCreateRole,
    required this.onEditRole,
  });

  final List<ServerRole> roles;
  final List<ServerMember> members;
  final bool canManageRoles;
  final bool Function(ServerRole role) canEditRole;
  final Future<void> Function() onCreateRole;
  final Future<void> Function(ServerRole role) onEditRole;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final memberCountByRoleId = <String, int>{};
    for (final member in members) {
      for (final roleId in member.roleIds) {
        memberCountByRoleId.update(
          roleId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Manage each role here, including its name, color, and bundled permissions.',
              ),
            ),
            if (canManageRoles)
              FilledButton.icon(
                onPressed: onCreateRole,
                icon: const Icon(Icons.add),
                label: const Text('Create role'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.separated(
            itemCount: roles.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final role = roles[index];
              final roleColor = _tryParseRoleColor(role.colorHex);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: palette.panelStrong,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _RoleColorDot(color: roleColor),
                              Text(
                                role.name,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: roleColor,
                                ),
                              ),
                              if (role.isSystem)
                                const Chip(label: Text('System role')),
                            ],
                          ),
                        ),
                        if (canEditRole(role))
                          OutlinedButton.icon(
                            onPressed: () => onEditRole(role),
                            icon: const Icon(Icons.tune),
                            label: const Text('Edit'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${memberCountByRoleId[role.id] ?? 0} members • ${role.permissions.length} permissions',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: role.permissions.isEmpty
                          ? const [Chip(label: Text('No permissions'))]
                          : role.permissions
                                .map(
                                  (permission) =>
                                      Chip(label: Text(permission.label)),
                                )
                                .toList(),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _JoinRequestsTab extends StatelessWidget {
  const _JoinRequestsTab({
    required this.loading,
    required this.requests,
    required this.onApprove,
    required this.onReject,
  });

  final bool loading;
  final List<ServerJoinRequestSummary> requests;
  final Future<void> Function(ServerJoinRequestSummary request) onApprove;
  final Future<void> Function(ServerJoinRequestSummary request) onReject;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (requests.isEmpty) {
      return const Center(child: Text('No pending join requests right now.'));
    }
    return ListView.separated(
      itemCount: requests.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final request = requests[index];
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('Requested ${_formatServerDate(request.createdAt)}'),
                    const SizedBox(height: 4),
                    SelectableText(request.userId),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: () => onReject(request),
                child: const Text('Decline'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => onApprove(request),
                child: const Text('Approve'),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ServerDiscoverySettingsResult {
  const _ServerDiscoverySettingsResult({
    required this.isPublic,
    required this.description,
  });

  final bool isPublic;
  final String description;
}

class _ServerDiscoverySettingsDialog extends StatefulWidget {
  const _ServerDiscoverySettingsDialog({
    required this.initialIsPublic,
    required this.initialDescription,
  });

  final bool initialIsPublic;
  final String initialDescription;

  @override
  State<_ServerDiscoverySettingsDialog> createState() =>
      _ServerDiscoverySettingsDialogState();
}

class _ServerDiscoverySettingsDialogState
    extends State<_ServerDiscoverySettingsDialog> {
  late bool _isPublic = widget.initialIsPublic;
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.initialDescription);

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(
      _ServerDiscoverySettingsResult(
        isPublic: _isPublic,
        description: _descriptionController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server visibility'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isPublic,
              title: const Text('Public server'),
              subtitle: Text(
                _isPublic
                    ? 'Anyone who finds this server can join immediately.'
                    : 'Anyone who finds this server must request to join.',
              ),
              onChanged: (value) {
                setState(() {
                  _isPublic = value;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              minLines: 3,
              maxLines: 4,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Description',
                hintText: 'Tell people what the server is about.',
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
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _MembersTab extends StatefulWidget {
  const _MembersTab({
    required this.server,
    required this.roles,
    required this.members,
    required this.canManageRoles,
    required this.onEditMemberRoles,
    required this.onEditSelectedMembers,
    this.canBanMembers = false,
    this.onBanMember,
  });

  final ServerSummary server;
  final List<ServerRole> roles;
  final List<ServerMember> members;
  final bool canManageRoles;
  final Future<void> Function(ServerMember member) onEditMemberRoles;
  final Future<void> Function(List<ServerMember> members) onEditSelectedMembers;
  final bool canBanMembers;
  final Future<void> Function(ServerMember member)? onBanMember;

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedUserIds = <String>{};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MembersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final memberIds = widget.members.map((member) => member.userId).toSet();
    _selectedUserIds.removeWhere((userId) => !memberIds.contains(userId));
  }

  @override
  Widget build(BuildContext context) {
    final roleById = {for (final role in widget.roles) role.id: role};
    final roleOrder = _roleOrderMap(widget.roles);
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final query = _searchController.text.trim().toLowerCase();
    final visibleMembers = widget.members.where((member) {
      if (query.isEmpty) {
        return true;
      }
      if (member.displayName.toLowerCase().contains(query)) {
        return true;
      }
      final memberRoles = member.roleIds
          .map((roleId) => roleById[roleId])
          .whereType<ServerRole>();
      return memberRoles.any((role) => role.name.toLowerCase().contains(query));
    }).toList();
    final selectedMembers = widget.members
        .where((member) => _selectedUserIds.contains(member.userId))
        .toList(growable: false);
    final allVisibleSelected =
        visibleMembers.isNotEmpty &&
        visibleMembers.every(
          (member) => _selectedUserIds.contains(member.userId),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Assign roles to one person or select several members and update them together.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search members or roles',
                ),
              ),
            ),
            if (widget.canManageRoles) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: visibleMembers.isEmpty
                    ? null
                    : () {
                        setState(() {
                          if (allVisibleSelected) {
                            _selectedUserIds.removeAll(
                              visibleMembers.map((member) => member.userId),
                            );
                          } else {
                            _selectedUserIds.addAll(
                              visibleMembers.map((member) => member.userId),
                            );
                          }
                        });
                      },
                icon: Icon(
                  allVisibleSelected
                      ? Icons.deselect_outlined
                      : Icons.select_all_outlined,
                ),
                label: Text(
                  allVisibleSelected ? 'Clear visible' : 'Select visible',
                ),
              ),
            ],
          ],
        ),
        if (widget.canManageRoles) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: palette.panelStrong,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: palette.border),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  selectedMembers.isEmpty
                      ? 'No members selected'
                      : '${selectedMembers.length} members selected',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                FilledButton.icon(
                  onPressed: selectedMembers.isEmpty
                      ? null
                      : () => widget.onEditSelectedMembers(selectedMembers),
                  icon: const Icon(Icons.groups_2_outlined),
                  label: Text(
                    selectedMembers.length <= 1
                        ? 'Edit selected member'
                        : 'Edit selected members',
                  ),
                ),
                if (selectedMembers.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedUserIds.clear();
                      });
                    },
                    child: const Text('Clear selection'),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: visibleMembers.isEmpty
              ? const Center(child: Text('No members match that search.'))
              : ListView.separated(
                  itemCount: visibleMembers.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final member = visibleMembers[index];
                    final memberRoles = member.roleIds
                        .map((roleId) => roleById[roleId])
                        .whereType<ServerRole>()
                        .toList();
                    final primaryRole = _primaryRoleForMember(
                      member,
                      roleById,
                      roleOrder,
                    );
                    final primaryRoleColor = _tryParseRoleColor(
                      primaryRole?.colorHex,
                    );
                    final selected = _selectedUserIds.contains(member.userId);

                    return InkWell(
                      onTap: widget.canManageRoles
                          ? () {
                              setState(() {
                                if (selected) {
                                  _selectedUserIds.remove(member.userId);
                                } else {
                                  _selectedUserIds.add(member.userId);
                                }
                              });
                            }
                          : null,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: selected
                              ? palette.panelAccent
                              : palette.panelStrong,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : palette.border,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.canManageRoles) ...[
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: 8,
                                  top: 2,
                                ),
                                child: Checkbox(
                                  value: selected,
                                  onChanged: (value) {
                                    setState(() {
                                      if (value ?? false) {
                                        _selectedUserIds.add(member.userId);
                                      } else {
                                        _selectedUserIds.remove(member.userId);
                                      }
                                    });
                                  },
                                ),
                              ),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                _RoleColorDot(
                                                  color: primaryRoleColor,
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    member.displayName,
                                                    style: TextStyle(
                                                      fontSize: 18,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: primaryRoleColor,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'Joined ${_formatServerDate(member.joinedAt)}',
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (widget.canManageRoles)
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              widget.onEditMemberRoles(member),
                                          icon: const Icon(
                                            Icons.manage_accounts,
                                          ),
                                          label: const Text('Edit roles'),
                                        ),
                                      if (widget.canBanMembers &&
                                          member.userId !=
                                              widget.server.ownerId)
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              widget.onBanMember?.call(member),
                                          icon: const Icon(Icons.block),
                                          label: const Text('Ban'),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.red,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      if (member.userId ==
                                          widget.server.ownerId)
                                        const Chip(label: Text('Owner')),
                                      ...memberRoles.map(
                                        (role) => Chip(
                                          avatar: _RoleColorDot(
                                            color: _tryParseRoleColor(
                                              role.colorHex,
                                            ),
                                            size: 12,
                                          ),
                                          label: Text(role.name),
                                        ),
                                      ),
                                      if (memberRoles.isEmpty &&
                                          member.userId !=
                                              widget.server.ownerId)
                                        const Chip(label: Text('No roles')),
                                    ],
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
      ],
    );
  }
}

class _ChannelAccessTab extends StatelessWidget {
  const _ChannelAccessTab({
    required this.channels,
    required this.roles,
    required this.loadingOverrides,
    required this.selectedChannelId,
    required this.overrides,
    required this.canManageChannels,
    required this.onSelectChannel,
    required this.onEditOverride,
  });

  final List<ChannelSummary> channels;
  final List<ServerRole> roles;
  final bool loadingOverrides;
  final String? selectedChannelId;
  final List<ChannelPermissionOverride> overrides;
  final bool canManageChannels;
  final Future<void> Function(String channelId) onSelectChannel;
  final Future<void> Function(ServerRole role) onEditOverride;

  @override
  Widget build(BuildContext context) {
    final overridesByRole = {
      for (final overrideEntry in overrides)
        overrideEntry.roleId: overrideEntry,
    };
    final palette = Theme.of(context).extension<AppThemePalette>()!;

    if (channels.isEmpty) {
      return const Center(child: Text('Create a channel to configure access.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey<String?>(selectedChannelId),
                initialValue: selectedChannelId,
                decoration: const InputDecoration(labelText: 'Channel'),
                items: channels
                    .map(
                      (channel) => DropdownMenuItem<String>(
                        value: channel.id,
                        child: Text(
                          '${channel.kind == ChannelKind.text ? '#' : ''}${channel.name}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    unawaited(onSelectChannel(value));
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            const SizedBox(
              width: 300,
              child: Text(
                'Allow and deny channel-specific permissions per role. Deny beats allow, and allow beats the base server role.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (loadingOverrides)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView.separated(
              itemCount: roles.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final role = roles[index];
                final overrideEntry = overridesByRole[role.id];
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: palette.panelStrong,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: palette.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  role.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (role.isSystem)
                                  const Chip(label: Text('System role')),
                              ],
                            ),
                          ),
                          if (canManageChannels)
                            OutlinedButton.icon(
                              onPressed: () => onEditOverride(role),
                              icon: const Icon(Icons.rule),
                              label: const Text('Edit access'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _OverrideSummaryWrap(
                        title: 'Allow',
                        permissions:
                            overrideEntry?.allowPermissions ??
                            const <ServerPermission>{},
                        tone: const Color(0xFF143A2E),
                      ),
                      const SizedBox(height: 8),
                      _OverrideSummaryWrap(
                        title: 'Deny',
                        permissions:
                            overrideEntry?.denyPermissions ??
                            const <ServerPermission>{},
                        tone: const Color(0xFF3B1A1F),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _OverrideSummaryWrap extends StatelessWidget {
  const _OverrideSummaryWrap({
    required this.title,
    required this.permissions,
    required this.tone,
  });

  final String title;
  final Set<ServerPermission> permissions;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title),
        ...(permissions.isEmpty
            ? const [Chip(label: Text('Inherit'))]
            : permissions
                  .map(
                    (permission) => Chip(
                      backgroundColor: tone,
                      label: Text(permission.label),
                    ),
                  )
                  .toList()),
      ],
    );
  }
}

class _RoleEditorDialog extends StatefulWidget {
  const _RoleEditorDialog({
    required this.title,
    required this.submitLabel,
    this.initialName = '',
    this.initialColorHex,
    this.initialPermissions = const <ServerPermission>{},
  });

  final String title;
  final String submitLabel;
  final String initialName;
  final String? initialColorHex;
  final Set<ServerPermission> initialPermissions;

  @override
  State<_RoleEditorDialog> createState() => _RoleEditorDialogState();
}

class _RoleEditorDialogState extends State<_RoleEditorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _colorController = TextEditingController(
    text: widget.initialColorHex ?? '',
  );
  late final Set<ServerPermission> _selectedPermissions = widget
      .initialPermissions
      .toSet();
  String? _colorError;

  @override
  void dispose() {
    _nameController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      return;
    }
    final rawColor = _colorController.text.trim();
    final normalizedColor = _normalizeRoleColorHexInput(rawColor);
    if (rawColor.isNotEmpty && normalizedColor == null) {
      setState(() {
        _colorError = 'Use the format #RRGGBB.';
      });
      return;
    }
    Navigator.of(context).pop(
      _RoleEditorResult(
        name: name,
        colorHex: normalizedColor,
        permissions: _selectedPermissions,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final previewColor = _tryParseRoleColor(
      _normalizeRoleColorHexInput(_colorController.text.trim()),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Role name'),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _colorController,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) {
                        setState(() {
                          _colorError = null;
                        });
                      },
                      decoration: InputDecoration(
                        labelText: 'Role color',
                        hintText: '#72E0C1',
                        helperText:
                            'This color is used for member names and chat author names.',
                        errorText: _colorError,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: previewColor ?? palette.panel,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: previewColor == null
                            ? palette.border
                            : Colors.white.withAlpha(120),
                        width: 2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _colorController.clear();
                          _colorError = null;
                        });
                      },
                      child: const Text('Default'),
                    ),
                    ..._roleColorPresets.map((colorHex) {
                      final swatchColor = _tryParseRoleColor(colorHex)!;
                      final selected =
                          _normalizeRoleColorHexInput(_colorController.text) ==
                          colorHex;
                      return InkWell(
                        onTap: () {
                          setState(() {
                            _colorController.text = colorHex;
                            _colorError = null;
                          });
                        },
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: swatchColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white.withAlpha(96),
                              width: selected ? 3 : 1.5,
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Permissions',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedPermissions
                          ..clear()
                          ..addAll(ServerPermission.values);
                      });
                    },
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedPermissions.clear();
                      });
                    },
                    child: const Text('Clear all'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._rolePermissionSections.map((section) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.panelStrong,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: palette.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          section.title,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (section.description != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            section.description!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 8),
                        ...section.permissions.map((descriptor) {
                          return SwitchListTile(
                            value: _selectedPermissions.contains(
                              descriptor.permission,
                            ),
                            contentPadding: EdgeInsets.zero,
                            title: Text(descriptor.permission.label),
                            subtitle: Text(descriptor.description),
                            onChanged: (value) {
                              setState(() {
                                if (value) {
                                  _selectedPermissions.add(
                                    descriptor.permission,
                                  );
                                } else {
                                  _selectedPermissions.remove(
                                    descriptor.permission,
                                  );
                                }
                              });
                            },
                          );
                        }),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}

class _MemberRoleDialog extends StatefulWidget {
  const _MemberRoleDialog({
    required this.member,
    required this.roles,
    required this.serverOwnerId,
  });

  final ServerMember member;
  final List<ServerRole> roles;
  final String serverOwnerId;

  @override
  State<_MemberRoleDialog> createState() => _MemberRoleDialogState();
}

class _MemberRoleDialogState extends State<_MemberRoleDialog> {
  late final Set<String> _selectedRoleIds = widget.member.roleIds.toSet();

  bool _isLockedRole(ServerRole role) {
    if (!_isProtectedOwnerRole(role)) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return AlertDialog(
      title: Text('Roles for ${widget.member.displayName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose the exact roles this member should have. Their highest role color will be used in the server member list and text chat.',
              ),
              const SizedBox(height: 14),
              ...widget.roles.map((role) {
                final locked = _isLockedRole(role);
                final selected = _selectedRoleIds.contains(role.id);
                final enabled = !locked;
                final subtitle = role.permissions.isEmpty
                    ? 'No permissions'
                    : role.permissions
                          .map((permission) => permission.label)
                          .join(', ');
                final roleColor = _tryParseRoleColor(role.colorHex);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.panelStrong,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: palette.border),
                  ),
                  child: CheckboxListTile(
                    value: selected,
                    enabled: enabled,
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        _RoleColorDot(color: roleColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            role.name,
                            style: TextStyle(
                              color: roleColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (role.isSystem)
                          const Chip(label: Text('System role')),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(subtitle),
                    ),
                    onChanged: (value) {
                      setState(() {
                        if (value ?? false) {
                          _selectedRoleIds.add(role.id);
                        } else {
                          _selectedRoleIds.remove(role.id);
                        }
                      });
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedRoleIds),
          child: const Text('Save roles'),
        ),
      ],
    );
  }
}

enum _BulkRoleEditMode { keep, add, remove }

class _BulkMemberRoleDialog extends StatefulWidget {
  const _BulkMemberRoleDialog({
    required this.members,
    required this.roles,
    required this.serverOwnerId,
  });

  final List<ServerMember> members;
  final List<ServerRole> roles;
  final String serverOwnerId;

  @override
  State<_BulkMemberRoleDialog> createState() => _BulkMemberRoleDialogState();
}

class _BulkMemberRoleDialogState extends State<_BulkMemberRoleDialog> {
  late final Map<String, _BulkRoleEditMode> _roleModes = {
    for (final role in widget.roles) role.id: _BulkRoleEditMode.keep,
  };

  bool _isLockedRole(ServerRole role) => _isProtectedOwnerRole(role);

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return AlertDialog(
      title: Text('Update roles for ${widget.members.length} members'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pick which roles to add or remove. Any role left on Keep will stay exactly as it is for each selected member.',
              ),
              const SizedBox(height: 16),
              ...widget.roles.map((role) {
                final locked = _isLockedRole(role);
                final roleColor = _tryParseRoleColor(role.colorHex);
                final assignedCount = widget.members
                    .where((member) => member.roleIds.contains(role.id))
                    .length;
                final mode = _roleModes[role.id] ?? _BulkRoleEditMode.keep;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette.panelStrong,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: palette.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _RoleColorDot(color: roleColor),
                              const SizedBox(width: 8),
                              Text(
                                role.name,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: roleColor,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '$assignedCount of ${widget.members.length} selected members already have this role',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (role.isSystem)
                            const Chip(label: Text('System role')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<_BulkRoleEditMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<_BulkRoleEditMode>(
                            value: _BulkRoleEditMode.keep,
                            label: Text('Keep'),
                          ),
                          ButtonSegment<_BulkRoleEditMode>(
                            value: _BulkRoleEditMode.add,
                            label: Text('Add'),
                          ),
                          ButtonSegment<_BulkRoleEditMode>(
                            value: _BulkRoleEditMode.remove,
                            label: Text('Remove'),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: locked
                            ? null
                            : (selection) {
                                setState(() {
                                  _roleModes[role.id] = selection.first;
                                });
                              },
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: role.permissions.isEmpty
                            ? const [Chip(label: Text('No permissions'))]
                            : role.permissions
                                  .map(
                                    (permission) =>
                                        Chip(label: Text(permission.label)),
                                  )
                                  .toList(),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final roleIdsToAdd = _roleModes.entries
                .where((entry) => entry.value == _BulkRoleEditMode.add)
                .map((entry) => entry.key)
                .toSet();
            final roleIdsToRemove = _roleModes.entries
                .where((entry) => entry.value == _BulkRoleEditMode.remove)
                .map((entry) => entry.key)
                .toSet();
            Navigator.of(context).pop(
              _BulkMemberRoleEditorResult(
                roleIdsToAdd: roleIdsToAdd,
                roleIdsToRemove: roleIdsToRemove,
              ),
            );
          },
          child: const Text('Apply changes'),
        ),
      ],
    );
  }
}

enum _ChannelPermissionMode { inherit, allow, deny }

class _ChannelOverrideDialog extends StatefulWidget {
  const _ChannelOverrideDialog({
    required this.role,
    required this.channel,
    required this.initialAllow,
    required this.initialDeny,
  });

  final ServerRole role;
  final ChannelSummary channel;
  final Set<ServerPermission> initialAllow;
  final Set<ServerPermission> initialDeny;

  @override
  State<_ChannelOverrideDialog> createState() => _ChannelOverrideDialogState();
}

class _ChannelOverrideDialogState extends State<_ChannelOverrideDialog> {
  late final Map<ServerPermission, _ChannelPermissionMode> _modes = {
    for (final permission in ServerPermission.channelScoped)
      permission: widget.initialDeny.contains(permission)
          ? _ChannelPermissionMode.deny
          : widget.initialAllow.contains(permission)
          ? _ChannelPermissionMode.allow
          : _ChannelPermissionMode.inherit,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Access for ${widget.role.name}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Channel: ${widget.channel.kind == ChannelKind.text ? '#' : ''}${widget.channel.name}',
              ),
              const SizedBox(height: 18),
              ...ServerPermission.channelScoped.map((permission) {
                final mode =
                    _modes[permission] ?? _ChannelPermissionMode.inherit;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text(permission.label)),
                      SegmentedButton<_ChannelPermissionMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<_ChannelPermissionMode>(
                            value: _ChannelPermissionMode.inherit,
                            label: Text('Inherit'),
                          ),
                          ButtonSegment<_ChannelPermissionMode>(
                            value: _ChannelPermissionMode.allow,
                            label: Text('Allow'),
                          ),
                          ButtonSegment<_ChannelPermissionMode>(
                            value: _ChannelPermissionMode.deny,
                            label: Text('Deny'),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: (selection) {
                          setState(() {
                            _modes[permission] = selection.first;
                          });
                        },
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final allowPermissions = <ServerPermission>{};
            final denyPermissions = <ServerPermission>{};
            for (final entry in _modes.entries) {
              switch (entry.value) {
                case _ChannelPermissionMode.allow:
                  allowPermissions.add(entry.key);
                case _ChannelPermissionMode.deny:
                  denyPermissions.add(entry.key);
                case _ChannelPermissionMode.inherit:
                  break;
              }
            }
            Navigator.of(context).pop(
              _ChannelOverrideEditorResult(
                allowPermissions: allowPermissions,
                denyPermissions: denyPermissions,
              ),
            );
          },
          child: const Text('Save access'),
        ),
      ],
    );
  }
}

class _RoleEditorResult {
  const _RoleEditorResult({
    required this.name,
    required this.colorHex,
    required this.permissions,
  });

  final String name;
  final String? colorHex;
  final Set<ServerPermission> permissions;
}

class _BulkMemberRoleEditorResult {
  const _BulkMemberRoleEditorResult({
    required this.roleIdsToAdd,
    required this.roleIdsToRemove,
  });

  final Set<String> roleIdsToAdd;
  final Set<String> roleIdsToRemove;
}

class _ChannelOverrideEditorResult {
  const _ChannelOverrideEditorResult({
    required this.allowPermissions,
    required this.denyPermissions,
  });

  final Set<ServerPermission> allowPermissions;
  final Set<ServerPermission> denyPermissions;
}

const List<String> _roleColorPresets = <String>[
  '#F5B85A',
  '#FF8A65',
  '#F06292',
  '#BA68C8',
  '#7E57C2',
  '#7DD3FC',
  '#4FC3F7',
  '#4DB6AC',
  '#81C784',
  '#AED581',
  '#FFD54F',
  '#C6CBD5',
];

const List<_PermissionSectionDescriptor>
_rolePermissionSections = <_PermissionSectionDescriptor>[
  _PermissionSectionDescriptor(
    title: 'Server setup',
    description: 'High-level admin actions for the server itself.',
    permissions: <_PermissionDescriptor>[
      _PermissionDescriptor(
        permission: ServerPermission.manageServer,
        description:
            'Change server visibility and other top-level server settings.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.manageRoles,
        description: 'Create roles, edit permissions, and assign roles.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.manageChannels,
        description:
            'Create channels, categories, and edit channel-specific access.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.inviteMembers,
        description:
            'Invite people directly and review join requests when needed.',
      ),
    ],
  ),
  _PermissionSectionDescriptor(
    title: 'Text chat',
    description: 'What the role can do inside text channels.',
    permissions: <_PermissionDescriptor>[
      _PermissionDescriptor(
        permission: ServerPermission.viewChannel,
        description: 'See the server channels and read channel content.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.sendMessages,
        description: 'Send messages and attachments in text channels.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.manageMessages,
        description: 'Delete other people’s messages in server text channels.',
      ),
    ],
  ),
  _PermissionSectionDescriptor(
    title: 'Voice and streaming',
    description: 'Audio, camera, and screen sharing controls.',
    permissions: <_PermissionDescriptor>[
      _PermissionDescriptor(
        permission: ServerPermission.joinVoice,
        description: 'Join voice channels in the server.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.streamCamera,
        description: 'Turn on camera in voice channels.',
      ),
      _PermissionDescriptor(
        permission: ServerPermission.shareScreen,
        description: 'Share a screen or window in voice channels.',
      ),
    ],
  ),
];

class _PermissionSectionDescriptor {
  const _PermissionSectionDescriptor({
    required this.title,
    required this.permissions,
    this.description,
  });

  final String title;
  final String? description;
  final List<_PermissionDescriptor> permissions;
}

class _PermissionDescriptor {
  const _PermissionDescriptor({
    required this.permission,
    required this.description,
  });

  final ServerPermission permission;
  final String description;
}

class _RoleColorDot extends StatelessWidget {
  const _RoleColorDot({required this.color, this.size = 14});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? palette.panel,
        shape: BoxShape.circle,
        border: Border.all(color: palette.border),
      ),
    );
  }
}

String? _normalizeRoleColorHexInput(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) {
    return null;
  }
  if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

Color? _tryParseRoleColor(String? colorHex) {
  final normalized = _normalizeRoleColorHexInput(colorHex ?? '');
  if (normalized == null) {
    return null;
  }
  final hexValue = normalized.substring(1);
  return Color(int.parse('FF$hexValue', radix: 16));
}

Map<String, int> _roleOrderMap(List<ServerRole> roles) {
  return {
    for (var index = 0; index < roles.length; index++) roles[index].id: index,
  };
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
  if (_isProtectedOwnerRole(role)) {
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

bool _isProtectedOwnerRole(ServerRole role) {
  return role.isSystem &&
      role.permissions.length == ServerPermission.values.length &&
      role.permissions.containsAll(ServerPermission.values);
}

String _formatServerDate(DateTime timestamp) {
  final year = timestamp.year.toString().padLeft(4, '0');
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

// ─── Bans Tab ────────────────────────────────────────────────────────────────

class _BansTab extends StatelessWidget {
  const _BansTab({
    required this.loading,
    required this.bans,
    required this.onUnban,
  });

  final bool loading;
  final List<ServerBan> bans;
  final Future<void> Function(ServerBan ban) onUnban;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (bans.isEmpty) {
      return const Center(child: Text('No banned members.'));
    }
    return ListView.separated(
      itemCount: bans.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final ban = bans[index];
        return ListTile(
          title: Text(ban.displayName),
          subtitle: Text(
            ban.reason?.isNotEmpty == true
                ? 'Reason: ${ban.reason}'
                : 'Banned ${_formatServerDate(ban.createdAt)}',
          ),
          trailing: TextButton.icon(
            onPressed: () => onUnban(ban),
            icon: const Icon(Icons.undo),
            label: const Text('Unban'),
          ),
        );
      },
    );
  }
}

// ─── Audit Log Tab ───────────────────────────────────────────────────────────

const _kAuditLogActions = <String?>[
  null,
  'member_banned',
  'member_unbanned',
  'member_kicked',
];

const _kAuditLogActionLabels = <String?>[
  'All actions',
  'Member banned',
  'Member unbanned',
  'Member kicked',
];

class _AuditLogTab extends StatelessWidget {
  const _AuditLogTab({
    required this.loading,
    required this.entries,
    required this.actionFilter,
    required this.onFilterChanged,
  });

  final bool loading;
  final List<AuditLogEntry> entries;
  final String? actionFilter;
  final void Function(String? filter) onFilterChanged;

  String _actionLabel(String action) {
    final index = _kAuditLogActions.indexOf(action);
    if (index >= 0) return _kAuditLogActionLabels[index] ?? action;
    return action.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Filter: '),
            const SizedBox(width: 8),
            DropdownButton<String?>(
              value: actionFilter,
              items: List.generate(
                _kAuditLogActions.length,
                (i) => DropdownMenuItem<String?>(
                  value: _kAuditLogActions[i],
                  child: Text(_kAuditLogActionLabels[i] ?? 'All actions'),
                ),
              ),
              onChanged: onFilterChanged,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? const Center(child: Text('No audit log entries.'))
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final target = entry.targetDisplayName;
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.history, size: 18),
                      title: Text(
                        target != null
                            ? '${entry.actorDisplayName} → $target'
                            : entry.actorDisplayName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(_actionLabel(entry.action)),
                      trailing: Text(
                        _formatServerDate(entry.createdAt),
                        style: const TextStyle(fontSize: 11),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
