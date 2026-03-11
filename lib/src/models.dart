enum ChannelKind { text, voice }

enum ShareKind { audio, camera, screen }

enum ServerPermission {
  viewChannel('view_channel', 'View channel'),
  manageServer('manage_server', 'Manage server'),
  manageRoles('manage_roles', 'Manage roles'),
  manageChannels('manage_channels', 'Manage channels'),
  inviteMembers('invite_members', 'Invite members'),
  sendMessages('send_messages', 'Send messages'),
  joinVoice('join_voice', 'Join voice'),
  streamCamera('stream_camera', 'Stream camera'),
  shareScreen('share_screen', 'Share screen');

  const ServerPermission(this.key, this.label);

  final String key;
  final String label;

  static ServerPermission? fromKey(String key) {
    for (final permission in ServerPermission.values) {
      if (permission.key == key) {
        return permission;
      }
    }
    return null;
  }

  static const Set<ServerPermission> channelScoped = {
    ServerPermission.viewChannel,
    ServerPermission.sendMessages,
    ServerPermission.joinVoice,
    ServerPermission.streamCamera,
    ServerPermission.shareScreen,
  };
}

class ServerSummary {
  const ServerSummary({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.inviteCode,
    required this.avatarPath,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String ownerId;
  final String inviteCode;
  final String? avatarPath;
  final DateTime createdAt;

  factory ServerSummary.fromMap(Map<String, dynamic> map) {
    return ServerSummary(
      id: map['id'] as String,
      name: map['name'] as String,
      ownerId: map['owner_id'] as String,
      inviteCode: map['invite_code'] as String,
      avatarPath: map['avatar_path'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class ChannelCategorySummary {
  const ChannelCategorySummary({
    required this.id,
    required this.serverId,
    required this.name,
    required this.position,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String name;
  final int position;
  final String createdBy;
  final DateTime createdAt;

  factory ChannelCategorySummary.fromMap(Map<String, dynamic> map) {
    return ChannelCategorySummary(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      name: map['name'] as String,
      position: map['position'] as int? ?? 0,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class ChannelSummary {
  const ChannelSummary({
    required this.id,
    required this.serverId,
    required this.categoryId,
    required this.name,
    required this.kind,
    required this.position,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String? categoryId;
  final String name;
  final ChannelKind kind;
  final int position;
  final String createdBy;
  final DateTime createdAt;

  factory ChannelSummary.fromMap(Map<String, dynamic> map) {
    final kindValue = map['kind'] as String;
    return ChannelSummary(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      categoryId: map['category_id'] as String?,
      name: map['name'] as String,
      kind: kindValue == 'voice' ? ChannelKind.voice : ChannelKind.text,
      position: map['position'] as int? ?? 0,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class ChannelMessage {
  const ChannelMessage({
    required this.id,
    required this.channelId,
    required this.body,
    required this.senderId,
    required this.senderDisplayName,
    required this.createdAt,
  });

  final String id;
  final String channelId;
  final String body;
  final String senderId;
  final String senderDisplayName;
  final DateTime createdAt;

  factory ChannelMessage.fromMap(Map<String, dynamic> map) {
    return ChannelMessage(
      id: map['id'] as String,
      channelId: map['channel_id'] as String,
      body: map['body'] as String,
      senderId: map['sender_id'] as String,
      senderDisplayName: map['sender_display_name'] as String? ?? 'Unknown',
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class VoiceParticipant {
  const VoiceParticipant({
    required this.clientId,
    required this.userId,
    required this.displayName,
    required this.isSelf,
    required this.isMuted,
    required this.shareKind,
    this.isSpeaking = false,
  });

  final String clientId;
  final String userId;
  final String displayName;
  final bool isSelf;
  final bool isMuted;
  final ShareKind shareKind;
  final bool isSpeaking;

  VoiceParticipant copyWith({
    String? clientId,
    String? userId,
    String? displayName,
    bool? isSelf,
    bool? isMuted,
    ShareKind? shareKind,
    bool? isSpeaking,
  }) {
    return VoiceParticipant(
      clientId: clientId ?? this.clientId,
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
      isSelf: isSelf ?? this.isSelf,
      isMuted: isMuted ?? this.isMuted,
      shareKind: shareKind ?? this.shareKind,
      isSpeaking: isSpeaking ?? this.isSpeaking,
    );
  }
}

class ServerRole {
  const ServerRole({
    required this.id,
    required this.serverId,
    required this.name,
    required this.permissions,
    required this.isSystem,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String name;
  final Set<ServerPermission> permissions;
  final bool isSystem;
  final DateTime createdAt;

  bool hasPermission(ServerPermission permission) =>
      permissions.contains(permission);

  Map<String, bool> get permissionMap => {
    for (final permission in ServerPermission.values)
      permission.key: permissions.contains(permission),
  };

  factory ServerRole.fromMap(Map<String, dynamic> map) {
    final rawPermissions = map['permissions'];
    final permissions = <ServerPermission>{};
    if (rawPermissions is Map) {
      for (final entry in rawPermissions.entries) {
        if (entry.value != true) {
          continue;
        }
        final permission = ServerPermission.fromKey(entry.key.toString());
        if (permission != null) {
          permissions.add(permission);
        }
      }
    }

    return ServerRole(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      name: map['name'] as String,
      permissions: permissions,
      isSystem: map['is_system'] as bool? ?? false,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class ServerMember {
  const ServerMember({
    required this.userId,
    required this.displayName,
    required this.joinedAt,
    required this.roleIds,
  });

  final String userId;
  final String displayName;
  final DateTime joinedAt;
  final Set<String> roleIds;
}

class ServerAccess {
  const ServerAccess({required this.isOwner, required this.permissions});

  final bool isOwner;
  final Set<ServerPermission> permissions;

  bool hasPermission(ServerPermission permission) {
    return isOwner || permissions.contains(permission);
  }
}

class ChannelPermissionOverride {
  const ChannelPermissionOverride({
    required this.channelId,
    required this.roleId,
    required this.allowPermissions,
    required this.denyPermissions,
  });

  final String channelId;
  final String roleId;
  final Set<ServerPermission> allowPermissions;
  final Set<ServerPermission> denyPermissions;

  factory ChannelPermissionOverride.fromMap(Map<String, dynamic> map) {
    Set<ServerPermission> parsePermissions(Object? raw) {
      final permissions = <ServerPermission>{};
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.value != true) {
            continue;
          }
          final permission = ServerPermission.fromKey(entry.key.toString());
          if (permission != null) {
            permissions.add(permission);
          }
        }
      }
      return permissions;
    }

    return ChannelPermissionOverride(
      channelId: map['channel_id'] as String,
      roleId: map['role_id'] as String,
      allowPermissions: parsePermissions(map['allow_permissions']),
      denyPermissions: parsePermissions(map['deny_permissions']),
    );
  }
}

class ChannelCategoryOrderUpdate {
  const ChannelCategoryOrderUpdate({
    required this.categoryId,
    required this.position,
  });

  final String categoryId;
  final int position;
}

class ChannelOrderUpdate {
  const ChannelOrderUpdate({
    required this.channelId,
    required this.position,
    required this.categoryId,
  });

  final String channelId;
  final int position;
  final String? categoryId;
}
