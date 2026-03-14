import 'dart:typed_data';

enum ChannelKind { text, voice }

enum UserStatus {
  online('online', 'Online'),
  away('away', 'Away'),
  dnd('dnd', 'Do Not Disturb'),
  invisible('invisible', 'Invisible');

  const UserStatus(this.key, this.label);

  final String key;
  final String label;

  static UserStatus fromKey(String key) {
    return UserStatus.values.firstWhere(
      (s) => s.key == key,
      orElse: () => UserStatus.online,
    );
  }
}

enum ShareKind { audio, camera, screen }

enum MessageAttachmentKind { image, video, audio, file }

enum ServerPermission {
  viewChannel('view_channel', 'View channel'),
  manageServer('manage_server', 'Manage server'),
  manageRoles('manage_roles', 'Manage roles'),
  manageChannels('manage_channels', 'Manage channels'),
  manageMessages('manage_messages', 'Manage messages'),
  inviteMembers('invite_members', 'Invite members'),
  sendMessages('send_messages', 'Send messages'),
  joinVoice('join_voice', 'Join voice'),
  streamCamera('stream_camera', 'Stream camera'),
  shareScreen('share_screen', 'Share screen'),
  banMembers('ban_members', 'Ban members'),
  useSoundboard('use_soundboard', 'Use soundboard'),
  manageSoundboard('manage_soundboard', 'Manage soundboard');

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
    ServerPermission.manageMessages,
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
    required this.description,
    required this.isPublic,
    required this.avatarPath,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String ownerId;
  final String inviteCode;
  final String description;
  final bool isPublic;
  final String? avatarPath;
  final DateTime createdAt;

  factory ServerSummary.fromMap(Map<String, dynamic> map) {
    return ServerSummary(
      id: map['id'] as String,
      name: map['name'] as String,
      ownerId: map['owner_id'] as String,
      inviteCode: map['invite_code'] as String,
      description: map['description'] as String? ?? '',
      isPublic: map['is_public'] as bool? ?? false,
      avatarPath: map['avatar_path'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class DiscoverableServerSummary {
  const DiscoverableServerSummary({
    required this.id,
    required this.name,
    required this.description,
    required this.avatarPath,
    required this.isPublic,
    required this.memberCount,
    required this.isMember,
    required this.hasPendingRequest,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String description;
  final String? avatarPath;
  final bool isPublic;
  final int memberCount;
  final bool isMember;
  final bool hasPendingRequest;
  final DateTime createdAt;

  factory DiscoverableServerSummary.fromMap(Map<String, dynamic> map) {
    return DiscoverableServerSummary(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String? ?? '',
      avatarPath: map['avatar_path'] as String?,
      isPublic: map['is_public'] as bool? ?? false,
      memberCount: map['member_count'] as int? ?? 0,
      isMember: map['is_member'] as bool? ?? false,
      hasPendingRequest: map['has_pending_request'] as bool? ?? false,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class UserProfileSummary {
  const UserProfileSummary({
    required this.id,
    required this.displayName,
    required this.avatarPath,
    this.status = UserStatus.online,
    this.activityText,
  });

  final String id;
  final String displayName;
  final String? avatarPath;
  final UserStatus status;
  final String? activityText;

  factory UserProfileSummary.fromMap(Map<String, dynamic> map) {
    return UserProfileSummary(
      id: map['id'] as String,
      displayName: map['display_name'] as String? ?? 'Unknown',
      avatarPath: map['avatar_path'] as String?,
      status: UserStatus.fromKey(map['status'] as String? ?? 'online'),
      activityText: map['activity_text'] as String?,
    );
  }
}

class ServerJoinRequestSummary {
  const ServerJoinRequestSummary({
    required this.id,
    required this.serverId,
    required this.userId,
    required this.displayName,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String userId;
  final String displayName;
  final DateTime createdAt;

  factory ServerJoinRequestSummary.fromMap(Map<String, dynamic> map) {
    return ServerJoinRequestSummary(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      userId: map['user_id'] as String,
      displayName: map['display_name'] as String? ?? 'Unknown',
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
    required this.senderAvatarPath,
    required this.createdAt,
    this.replyToMessageId,
    this.replyToBody,
    this.replyToSenderDisplayName,
    this.deletedAt,
    this.deletedBy,
    this.attachments = const <MessageAttachment>[],
    this.reactions = const <MessageReactionSummary>[],
  });

  final String id;
  final String channelId;
  final String body;
  final String senderId;
  final String senderDisplayName;
  final String? senderAvatarPath;
  final DateTime createdAt;
  final String? replyToMessageId;
  final String? replyToBody;
  final String? replyToSenderDisplayName;
  final DateTime? deletedAt;
  final String? deletedBy;
  final List<MessageAttachment> attachments;
  final List<MessageReactionSummary> reactions;

  bool get deleted => deletedAt != null;

  factory ChannelMessage.fromMap(Map<String, dynamic> map) {
    return ChannelMessage(
      id: map['id'] as String,
      channelId: map['channel_id'] as String,
      body: map['body'] as String,
      senderId: map['sender_id'] as String,
      senderDisplayName: map['sender_display_name'] as String? ?? 'Unknown',
      senderAvatarPath: map['sender_avatar_path'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      replyToMessageId: map['reply_to_message_id'] as String?,
      replyToBody: map['reply_to_body'] as String?,
      replyToSenderDisplayName: map['reply_to_sender_display_name'] as String?,
      deletedAt: map['deleted_at'] == null
          ? null
          : DateTime.parse(map['deleted_at'] as String).toLocal(),
      deletedBy: map['deleted_by'] as String?,
      attachments: MessageAttachment.listFromRaw(map['attachments']),
      reactions: MessageReactionSummary.listFromRaw(map['reactions']),
    );
  }
}

class DirectConversationSummary {
  const DirectConversationSummary({
    required this.conversationId,
    required this.otherUserId,
    required this.otherDisplayName,
    required this.otherAvatarPath,
    required this.lastMessageAt,
    required this.lastMessagePreview,
    required this.lastMessageSenderId,
    required this.unreadCount,
  });

  final String conversationId;
  final String otherUserId;
  final String otherDisplayName;
  final String? otherAvatarPath;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final String? lastMessageSenderId;
  final int unreadCount;

  factory DirectConversationSummary.fromMap(Map<String, dynamic> map) {
    return DirectConversationSummary(
      conversationId: map['conversation_id'] as String,
      otherUserId: map['other_user_id'] as String,
      otherDisplayName: map['other_display_name'] as String? ?? 'Unknown',
      otherAvatarPath: map['other_avatar_path'] as String?,
      lastMessageAt: map['last_message_at'] == null
          ? null
          : DateTime.parse(map['last_message_at'] as String).toLocal(),
      lastMessagePreview: map['last_message_preview'] as String?,
      lastMessageSenderId: map['last_message_sender_id'] as String?,
      unreadCount: map['unread_count'] as int? ?? 0,
    );
  }
}

class DirectMessage {
  const DirectMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.senderId,
    required this.senderDisplayName,
    required this.senderAvatarPath,
    required this.createdAt,
    this.replyToMessageId,
    this.replyToBody,
    this.replyToSenderDisplayName,
    this.deletedAt,
    this.deletedBy,
    this.attachments = const <MessageAttachment>[],
    this.reactions = const <MessageReactionSummary>[],
  });

  final String id;
  final String conversationId;
  final String body;
  final String senderId;
  final String senderDisplayName;
  final String? senderAvatarPath;
  final DateTime createdAt;
  final String? replyToMessageId;
  final String? replyToBody;
  final String? replyToSenderDisplayName;
  final DateTime? deletedAt;
  final String? deletedBy;
  final List<MessageAttachment> attachments;
  final List<MessageReactionSummary> reactions;

  bool get deleted => deletedAt != null;

  factory DirectMessage.fromMap(Map<String, dynamic> map) {
    return DirectMessage(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      body: map['body'] as String,
      senderId: map['sender_id'] as String,
      senderDisplayName: map['sender_display_name'] as String? ?? 'Unknown',
      senderAvatarPath: map['sender_avatar_path'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      replyToMessageId: map['reply_to_message_id'] as String?,
      replyToBody: map['reply_to_body'] as String?,
      replyToSenderDisplayName: map['reply_to_sender_display_name'] as String?,
      deletedAt: map['deleted_at'] == null
          ? null
          : DateTime.parse(map['deleted_at'] as String).toLocal(),
      deletedBy: map['deleted_by'] as String?,
      attachments: MessageAttachment.listFromRaw(map['attachments']),
      reactions: MessageReactionSummary.listFromRaw(map['reactions']),
    );
  }
}

class MessageAttachment {
  const MessageAttachment({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.kind,
    this.contentType,
  });

  final String path;
  final String fileName;
  final int sizeBytes;
  final MessageAttachmentKind kind;
  final String? contentType;

  bool get isImage => kind == MessageAttachmentKind.image;

  factory MessageAttachment.fromMap(Map<String, dynamic> map) {
    final rawKind = map['kind']?.toString();
    final kind = MessageAttachmentKind.values.firstWhere(
      (value) => value.name == rawKind,
      orElse: () => MessageAttachmentKind.file,
    );
    return MessageAttachment(
      path: map['path'] as String? ?? '',
      fileName: map['file_name'] as String? ?? 'Attachment',
      sizeBytes: map['size_bytes'] as int? ?? 0,
      kind: kind,
      contentType: map['content_type'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'path': path,
      'file_name': fileName,
      'size_bytes': sizeBytes,
      'kind': kind.name,
      'content_type': contentType,
    }..removeWhere((key, value) => value == null);
  }

  static List<MessageAttachment> listFromRaw(Object? raw) {
    if (raw is! List) {
      return const <MessageAttachment>[];
    }
    return raw
        .whereType<Map>()
        .map(
          (item) => MessageAttachment.fromMap(Map<String, dynamic>.from(item)),
        )
        .where((attachment) => attachment.path.isNotEmpty)
        .toList(growable: false);
  }
}

class OutgoingMessageAttachment {
  const OutgoingMessageAttachment({
    required this.fileName,
    required this.bytes,
    required this.kind,
    this.contentType,
  });

  final String fileName;
  final Uint8List bytes;
  final MessageAttachmentKind kind;
  final String? contentType;

  int get sizeBytes => bytes.lengthInBytes;
}

class MessageReactionSummary {
  const MessageReactionSummary({required this.emoji, required this.userIds});

  final String emoji;
  final List<String> userIds;

  int get count => userIds.length;

  bool includes(String userId) => userIds.contains(userId);

  static List<MessageReactionSummary> listFromRaw(Object? raw) {
    if (raw is! Map) {
      return const <MessageReactionSummary>[];
    }
    final reactions = <MessageReactionSummary>[];
    for (final entry in raw.entries) {
      final emoji = entry.key.toString();
      final value = entry.value;
      if (value is! List) {
        continue;
      }
      final userIds = value
          .map((item) => item?.toString())
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .toList();
      if (emoji.isEmpty || userIds.isEmpty) {
        continue;
      }
      reactions.add(MessageReactionSummary(emoji: emoji, userIds: userIds));
    }
    reactions.sort((left, right) => left.emoji.compareTo(right.emoji));
    return reactions;
  }
}

class GiphyGifResult {
  const GiphyGifResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.gifUrl,
    required this.giphyPageUrl,
  });

  final String id;
  final String title;
  final String previewUrl;
  final String gifUrl;
  final String giphyPageUrl;

  factory GiphyGifResult.fromMap(Map<String, dynamic> map) {
    final images = map['images'];
    final imagesMap = images is Map
        ? Map<String, dynamic>.from(images)
        : const <String, dynamic>{};
    final fixedWidth = imagesMap['fixed_width'];
    final fixedWidthMap = fixedWidth is Map
        ? Map<String, dynamic>.from(fixedWidth)
        : const <String, dynamic>{};
    final original = imagesMap['original'];
    final originalMap = original is Map
        ? Map<String, dynamic>.from(original)
        : const <String, dynamic>{};

    return GiphyGifResult(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? 'GIF',
      previewUrl:
          fixedWidthMap['url'] as String? ??
          originalMap['url'] as String? ??
          '',
      gifUrl:
          originalMap['url'] as String? ??
          fixedWidthMap['url'] as String? ??
          '',
      giphyPageUrl: map['url'] as String? ?? '',
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
    required this.colorHex,
    required this.permissions,
    required this.isSystem,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String name;
  final String? colorHex;
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
      colorHex: map['color_hex'] as String?,
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
    required this.avatarPath,
    required this.joinedAt,
    required this.roleIds,
  });

  final String userId;
  final String displayName;
  final String? avatarPath;
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

class ServerBan {
  const ServerBan({
    required this.id,
    required this.serverId,
    required this.userId,
    required this.bannedBy,
    required this.displayName,
    required this.reason,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String userId;
  final String bannedBy;
  final String displayName;
  final String? reason;
  final DateTime createdAt;

  factory ServerBan.fromMap(Map<String, dynamic> map) {
    return ServerBan(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      userId: map['user_id'] as String,
      bannedBy: map['banned_by'] as String,
      displayName: map['display_name'] as String? ?? 'Unknown',
      reason: map['reason'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.serverId,
    required this.actorId,
    required this.actorDisplayName,
    required this.targetUserId,
    required this.targetDisplayName,
    required this.action,
    required this.details,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String actorId;
  final String actorDisplayName;
  final String? targetUserId;
  final String? targetDisplayName;
  final String action;
  final Map<String, dynamic> details;
  final DateTime createdAt;

  factory AuditLogEntry.fromMap(Map<String, dynamic> map) {
    final rawDetails = map['details'];
    final details = rawDetails is Map
        ? Map<String, dynamic>.from(rawDetails)
        : const <String, dynamic>{};
    return AuditLogEntry(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      actorId: map['actor_id'] as String,
      actorDisplayName: map['actor_display_name'] as String? ?? 'Unknown',
      targetUserId: map['target_user_id'] as String?,
      targetDisplayName: map['target_display_name'] as String?,
      action: map['action'] as String,
      details: details,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class MessageSearchResult {
  const MessageSearchResult({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.body,
    required this.senderId,
    required this.senderDisplayName,
    required this.senderAvatarPath,
    required this.createdAt,
  });

  final String id;
  final String channelId;
  final String channelName;
  final String body;
  final String senderId;
  final String senderDisplayName;
  final String? senderAvatarPath;
  final DateTime createdAt;

  factory MessageSearchResult.fromMap(Map<String, dynamic> map) {
    return MessageSearchResult(
      id: map['id'] as String,
      channelId: map['channel_id'] as String,
      channelName: map['channel_name'] as String? ?? '',
      body: map['body'] as String,
      senderId: map['sender_id'] as String,
      senderDisplayName: map['sender_display_name'] as String? ?? 'Unknown',
      senderAvatarPath: map['sender_avatar_path'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class SoundboardClip {
  const SoundboardClip({
    required this.id,
    required this.serverId,
    required this.name,
    required this.filePath,
    required this.createdBy,
    required this.createdAt,
  });

  final String id;
  final String serverId;
  final String name;
  final String filePath;
  final String createdBy;
  final DateTime createdAt;

  factory SoundboardClip.fromMap(Map<String, dynamic> map) {
    return SoundboardClip(
      id: map['id'] as String,
      serverId: map['server_id'] as String,
      name: map['name'] as String,
      filePath: map['file_path'] as String,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}
