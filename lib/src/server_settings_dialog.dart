import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  });

  final ServerSummary server;
  final WorkspaceRepository repository;
  final ServerAccess access;
  final Future<void> Function() onCopyInvite;
  final Future<void> Function() onCreateChannel;
  final Future<void> Function() onCreateCategory;
  final Future<void> Function() onPickServerAvatar;

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  late ServerSummary _server = widget.server;
  bool _loading = true;
  bool _loadingOverrides = false;
  bool _loadingJoinRequests = false;
  bool _saving = false;
  bool _refreshWorkspaceOnClose = false;
  String? _error;
  List<ChannelSummary> _channels = const <ChannelSummary>[];
  List<ServerRole> _roles = const <ServerRole>[];
  List<ServerMember> _members = const <ServerMember>[];
  List<ServerJoinRequestSummary> _joinRequests =
      const <ServerJoinRequestSummary>[];
  List<ChannelPermissionOverride> _channelOverrides =
      const <ChannelPermissionOverride>[];
  String? _selectedOverrideChannelId;

  bool get _canManageRoles =>
      widget.access.hasPermission(ServerPermission.manageRoles);
  bool get _canManageChannels =>
      widget.access.hasPermission(ServerPermission.manageChannels);
  bool get _canInviteMembers =>
      widget.access.hasPermission(ServerPermission.inviteMembers);
  bool get _canManageServer =>
      widget.access.hasPermission(ServerPermission.manageServer);
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
      await _loadChannelOverrides();
      if (_canReviewJoinRequests) {
        await _loadJoinRequests();
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

  Future<void> _loadJoinRequests() async {
    setState(() {
      _loadingJoinRequests = true;
    });
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
      await widget.repository.createRole(
        serverId: widget.server.id,
        name: result.name,
        permissions: result.permissions,
      );
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      showAppToast(context, 'Role created.', tone: AppToastTone.success);
      await _load();
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
    return widget.access.isOwner || role.name != 'Owner';
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
        initialPermissions: role.permissions,
        lockName: role.name == 'Owner',
      ),
    );
    if (result == null) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      await widget.repository.updateRole(
        roleId: role.id,
        name: result.name,
        permissions: result.permissions,
      );
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      showAppToast(context, 'Role updated.', tone: AppToastTone.success);
      await _load();
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

    final roleIdsToAdd = nextSelection.difference(member.roleIds);
    final roleIdsToRemove = member.roleIds.difference(nextSelection);
    if (roleIdsToAdd.isEmpty && roleIdsToRemove.isEmpty) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      for (final roleId in roleIdsToAdd) {
        await widget.repository.assignRole(
          serverId: widget.server.id,
          userId: member.userId,
          roleId: roleId,
        );
      }
      for (final roleId in roleIdsToRemove) {
        await widget.repository.removeRole(
          serverId: widget.server.id,
          userId: member.userId,
          roleId: roleId,
        );
      }
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      showAppToast(
        context,
        'Member roles updated.',
        tone: AppToastTone.success,
      );
      await _load();
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
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      showAppToast(
        context,
        'Updated access for ${role.name}.',
        tone: AppToastTone.success,
      );
      await _loadChannelOverrides();
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
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      setState(() {
        _server = updatedServer;
      });
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
      _refreshWorkspaceOnClose = true;
      if (!mounted) {
        return;
      }
      showAppToast(
        context,
        approve
            ? 'Approved ${request.displayName}.'
            : 'Declined ${request.displayName}.',
        tone: AppToastTone.success,
      );
      await _loadJoinRequests();
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
                    onPressed: () =>
                        Navigator.of(context).pop(_refreshWorkspaceOnClose),
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
                        length: _canReviewJoinRequests ? 5 : 4,
                        child: Column(
                          children: [
                            TabBar(
                              tabs: [
                                const Tab(text: 'General'),
                                const Tab(text: 'Roles'),
                                const Tab(text: 'Members'),
                                const Tab(text: 'Channel Access'),
                                if (_canReviewJoinRequests)
                                  const Tab(text: 'Join Requests'),
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

    return ListView(
      children: [
        Text(
          'Manage the core server setup here. As more server options are added, they will live in this settings surface instead of the channel sidebar.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: palette.panelStrong,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Server info',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text('Name: ${server.name}'),
              const SizedBox(height: 6),
              Text('Visibility: ${server.isPublic ? 'Public' : 'Private'}'),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: onCopyInvite,
                icon: const Icon(Icons.content_copy, size: 18),
                label: Text('Invite code: ${server.inviteCode}'),
              ),
              if (server.description.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Description: ${server.description}'),
              ],
              const SizedBox(height: 6),
              Text('Created: ${_formatServerDate(server.createdAt)}'),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: server.id));
                  if (!context.mounted) {
                    return;
                  }
                  showAppToast(
                    context,
                    'Server ID copied to clipboard.',
                    tone: AppToastTone.success,
                  );
                },
                icon: const Icon(Icons.badge_outlined, size: 18),
                label: const Text('Copy server ID'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (canInviteMembers)
              FilledButton.tonalIcon(
                onPressed: onCopyInvite,
                icon: const Icon(Icons.link),
                label: const Text('Copy invite'),
              ),
            if (canManageServer)
              FilledButton.tonalIcon(
                onPressed: () async {
                  final result =
                      await showDialog<_ServerDiscoverySettingsResult>(
                        context: context,
                        builder: (context) => _ServerDiscoverySettingsDialog(
                          initialIsPublic: server.isPublic,
                          initialDescription: server.description,
                        ),
                      );
                  if (result == null) {
                    return;
                  }
                  await onUpdateDiscoverySettings(
                    isPublic: result.isPublic,
                    description: result.description,
                  );
                },
                icon: const Icon(Icons.public_outlined),
                label: const Text('Edit visibility'),
              ),
            if (canManageChannels)
              FilledButton.tonalIcon(
                onPressed: onCreateChannel,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Create channel'),
              ),
            if (canManageChannels)
              FilledButton.tonalIcon(
                onPressed: onCreateCategory,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Create category'),
              ),
            if (canEditServerPicture)
              FilledButton.tonalIcon(
                onPressed: onPickServerAvatar,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Change server picture'),
              ),
          ],
        ),
      ],
    );
  }
}

class _RolesTab extends StatelessWidget {
  const _RolesTab({
    required this.roles,
    required this.canManageRoles,
    required this.canEditRole,
    required this.onCreateRole,
    required this.onEditRole,
  });

  final List<ServerRole> roles;
  final bool canManageRoles;
  final bool Function(ServerRole role) canEditRole;
  final Future<void> Function() onCreateRole;
  final Future<void> Function(ServerRole role) onEditRole;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Manage server roles and the permissions bundled into each one.',
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
                        if (canEditRole(role))
                          OutlinedButton.icon(
                            onPressed: () => onEditRole(role),
                            icon: const Icon(Icons.tune),
                            label: const Text('Edit'),
                          ),
                      ],
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

class _MembersTab extends StatelessWidget {
  const _MembersTab({
    required this.server,
    required this.roles,
    required this.members,
    required this.canManageRoles,
    required this.onEditMemberRoles,
  });

  final ServerSummary server;
  final List<ServerRole> roles;
  final List<ServerMember> members;
  final bool canManageRoles;
  final Future<void> Function(ServerMember member) onEditMemberRoles;

  @override
  Widget build(BuildContext context) {
    final roleById = {for (final role in roles) role.id: role};
    final palette = Theme.of(context).extension<AppThemePalette>()!;

    return ListView.separated(
      itemCount: members.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final member = members[index];
        final memberRoles = member.roleIds
            .map((roleId) => roleById[roleId])
            .whereType<ServerRole>()
            .toList();

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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          member.displayName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
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
                  if (canManageRoles)
                    OutlinedButton.icon(
                      onPressed: () => onEditMemberRoles(member),
                      icon: const Icon(Icons.manage_accounts),
                      label: const Text('Roles'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (member.userId == server.ownerId)
                    const Chip(label: Text('Owner')),
                  ...memberRoles.map((role) => Chip(label: Text(role.name))),
                  if (memberRoles.isEmpty && member.userId != server.ownerId)
                    const Chip(label: Text('No roles')),
                ],
              ),
            ],
          ),
        );
      },
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
    this.initialPermissions = const <ServerPermission>{},
    this.lockName = false,
  });

  final String title;
  final String submitLabel;
  final String initialName;
  final Set<ServerPermission> initialPermissions;
  final bool lockName;

  @override
  State<_RoleEditorDialog> createState() => _RoleEditorDialogState();
}

class _RoleEditorDialogState extends State<_RoleEditorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late final Set<ServerPermission> _selectedPermissions = widget
      .initialPermissions
      .toSet();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                enabled: !widget.lockName,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Role name'),
              ),
              const SizedBox(height: 18),
              ...ServerPermission.values.map((permission) {
                return CheckboxListTile(
                  value: _selectedPermissions.contains(permission),
                  title: Text(permission.label),
                  contentPadding: EdgeInsets.zero,
                  onChanged: (value) {
                    setState(() {
                      if (value ?? false) {
                        _selectedPermissions.add(permission);
                      } else {
                        _selectedPermissions.remove(permission);
                      }
                    });
                  },
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
            final name = _nameController.text.trim();
            if (name.isEmpty) {
              return;
            }
            Navigator.of(context).pop(
              _RoleEditorResult(name: name, permissions: _selectedPermissions),
            );
          },
          child: Text(widget.submitLabel),
        ),
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
    if (role.name != 'Owner') {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Roles for ${widget.member.displayName}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.roles.map((role) {
              final locked = _isLockedRole(role);
              final selected = _selectedRoleIds.contains(role.id);
              final enabled = !locked;
              final subtitle = role.permissions.isEmpty
                  ? 'No permissions'
                  : role.permissions
                        .map((permission) => permission.label)
                        .join(', ');
              return CheckboxListTile(
                value: selected,
                enabled: enabled,
                title: Text(role.name),
                subtitle: Text(subtitle),
                contentPadding: EdgeInsets.zero,
                onChanged: (value) {
                  setState(() {
                    if (value ?? false) {
                      _selectedRoleIds.add(role.id);
                    } else {
                      _selectedRoleIds.remove(role.id);
                    }
                  });
                },
              );
            }).toList(),
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
  const _RoleEditorResult({required this.name, required this.permissions});

  final String name;
  final Set<ServerPermission> permissions;
}

class _ChannelOverrideEditorResult {
  const _ChannelOverrideEditorResult({
    required this.allowPermissions,
    required this.denyPermissions,
  });

  final Set<ServerPermission> allowPermissions;
  final Set<ServerPermission> denyPermissions;
}

String _formatServerDate(DateTime timestamp) {
  final year = timestamp.year.toString().padLeft(4, '0');
  final month = timestamp.month.toString().padLeft(2, '0');
  final day = timestamp.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
