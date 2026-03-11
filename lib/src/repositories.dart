import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_bootstrap.dart';
import 'desktop_integration.dart';
import 'models.dart';

class AuthService {
  AuthService(this.client);

  final SupabaseClient client;
  static const List<String> _preferredNameMetadataKeys = <String>[
    'display_name',
    'full_name',
    'name',
    'preferred_username',
    'user_name',
    'nickname',
  ];

  User get currentUser {
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('User is not signed in.');
    }
    return user;
  }

  Stream<AuthState> get authChanges => client.auth.onAuthStateChange;

  String get userId => currentUser.id;

  bool get hasCustomDisplayName {
    final metadataName = currentUser.userMetadata?['display_name'];
    return metadataName is String && metadataName.trim().isNotEmpty;
  }

  String get suggestedDisplayName {
    final metadata = currentUser.userMetadata;
    for (final key in _preferredNameMetadataKeys) {
      final value = metadata?[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    final email = currentUser.email;
    if (email != null && email.trim().isNotEmpty) {
      final localPart = email.split('@').first.trim();
      if (localPart.isNotEmpty) {
        return localPart;
      }
      return email.trim();
    }

    return 'Anonymous';
  }

  bool get shouldPromptForDisplayName => !hasCustomDisplayName;

  String get displayName {
    return suggestedDisplayName;
  }

  Future<void> signIn({required String email, required String password}) async {
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<String?> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final cleanEmail = email.trim();
    final cleanPassword = password;
    final cleanDisplayName = displayName.trim();

    try {
      final response = await client.auth.signUp(
        email: cleanEmail,
        password: cleanPassword,
        data: {
          if (cleanDisplayName.isNotEmpty) 'display_name': cleanDisplayName,
        },
      );
      if (response.session == null) {
        return 'Account created. Confirm the email address before signing in.';
      }
      return null;
    } catch (error) {
      final details = error.toString();
      if (!details.contains('Database error saving new user')) {
        rethrow;
      }

      final fallbackResponse = await client.auth.signUp(
        email: cleanEmail,
        password: cleanPassword,
      );
      if (fallbackResponse.session == null) {
        return 'Account created. Confirm the email address before signing in.';
      }
      return null;
    }
  }

  Future<void> signOut() async {
    await client.auth.signOut();
  }

  Future<void> signInWithGoogle() async {
    final launched = await client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: kIsWeb ? null : kDesktopOAuthRedirectTo,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );

    if (!launched) {
      throw StateError('Unable to launch Google sign-in.');
    }
  }

  Future<void> updateDisplayName(String displayName) async {
    final cleanDisplayName = displayName.trim();
    if (cleanDisplayName.isEmpty) {
      throw StateError('Display name is required.');
    }
    await client.auth.updateUser(
      UserAttributes(data: {'display_name': cleanDisplayName}),
    );
  }
}

class WorkspaceRepository {
  WorkspaceRepository({required this.client, required this.authService});

  final SupabaseClient client;
  final AuthService authService;

  bool get hasGiphyApiKey => AppBootstrap.giphyApiKey.trim().isNotEmpty;

  Future<void> ensureCurrentProfile() async {
    await client.from('user_profiles').upsert({
      'id': authService.userId,
      'display_name': authService.displayName,
    });
  }

  Future<List<ServerSummary>> fetchServers() async {
    final membershipRows =
        await client
                .from('server_members')
                .select('server_id')
                .eq('user_id', authService.userId)
            as List<dynamic>;

    final serverIds = membershipRows
        .map((row) => (row as Map<String, dynamic>)['server_id'] as String)
        .toSet()
        .toList();

    if (serverIds.isEmpty) {
      return const [];
    }

    final serverRows =
        await client
                .from('servers')
                .select(
                  'id, name, owner_id, invite_code, avatar_path, created_at',
                )
                .inFilter('id', serverIds)
                .order('created_at', ascending: true)
            as List<dynamic>;

    return serverRows
        .map((row) => ServerSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  Future<ServerSummary> createServer(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Server name is required.');
    }

    final row = await client
        .from('servers')
        .insert({'name': cleanName, 'owner_id': authService.userId})
        .select('id, name, owner_id, invite_code, avatar_path, created_at')
        .single();

    return ServerSummary.fromMap(row);
  }

  Future<ServerAccess> fetchServerAccess(ServerSummary server) async {
    if (server.ownerId == authService.userId) {
      return ServerAccess(
        isOwner: true,
        permissions: ServerPermission.values.toSet(),
      );
    }

    final membershipRoleRows =
        await client
                .from('server_member_roles')
                .select('role_id')
                .eq('server_id', server.id)
                .eq('user_id', authService.userId)
            as List<dynamic>;

    final roleIds = membershipRoleRows
        .map((row) => (row as Map<String, dynamic>)['role_id'] as String)
        .toList();
    if (roleIds.isEmpty) {
      return const ServerAccess(
        isOwner: false,
        permissions: <ServerPermission>{},
      );
    }

    final roleRows =
        await client
                .from('server_roles')
                .select(
                  'id, server_id, name, permissions, is_system, created_at',
                )
                .inFilter('id', roleIds)
            as List<dynamic>;

    final permissions = <ServerPermission>{};
    for (final role in roleRows) {
      permissions.addAll(
        ServerRole.fromMap(role as Map<String, dynamic>).permissions,
      );
    }

    return ServerAccess(isOwner: false, permissions: permissions);
  }

  Future<ServerSummary> joinServerByInvite(String inviteCode) async {
    final cleanCode = inviteCode.trim().toUpperCase();
    if (cleanCode.isEmpty) {
      throw StateError('Invite code is required.');
    }

    final row = await client.rpc(
      'join_server_by_invite',
      params: {'invite_code_input': cleanCode},
    );

    return ServerSummary.fromMap(Map<String, dynamic>.from(row as Map));
  }

  String? publicServerAvatarUrl(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) {
      return null;
    }
    return client.storage.from('server-assets').getPublicUrl(avatarPath);
  }

  Future<String> fetchLiveKitToken({
    required String channelId,
  }) async {
    final response = await client.functions.invoke(
      AppBootstrap.liveKitTokenFunctionName,
      body: <String, dynamic>{
        'channelId': channelId,
      },
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

  Future<ServerSummary> uploadServerAvatar({
    required String serverId,
    required Uint8List bytes,
    required String fileExtension,
  }) async {
    final cleanExtension = fileExtension.trim().toLowerCase();
    final normalizedExtension = cleanExtension.isEmpty
        ? 'png'
        : cleanExtension.replaceAll('.', '');
    final path = '$serverId/avatar.$normalizedExtension';

    await client.storage
        .from('server-assets')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(cacheControl: '3600', upsert: true),
        );

    final row = await client
        .from('servers')
        .update({'avatar_path': path})
        .eq('id', serverId)
        .select('id, name, owner_id, invite_code, avatar_path, created_at')
        .single();

    return ServerSummary.fromMap(row);
  }

  Future<List<ChannelSummary>> fetchChannels(String serverId) async {
    final channelRows =
        await client
                .from('channels')
                .select(
                  'id, server_id, category_id, name, kind, position, created_by, created_at',
                )
                .eq('server_id', serverId)
                .order('category_id', ascending: true)
                .order('position', ascending: true)
                .order('created_at', ascending: true)
            as List<dynamic>;

    return channelRows
        .map((row) => ChannelSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<ChannelCategorySummary>> fetchChannelCategories(
    String serverId,
  ) async {
    final rows =
        await client
                .from('channel_categories')
                .select('id, server_id, name, position, created_by, created_at')
                .eq('server_id', serverId)
                .order('position', ascending: true)
                .order('created_at', ascending: true)
            as List<dynamic>;

    return rows
        .map(
          (row) => ChannelCategorySummary.fromMap(row as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<ChannelPermissionOverride>> fetchChannelPermissionOverrides(
    String channelId,
  ) async {
    final rows =
        await client
                .from('channel_permission_overrides')
                .select(
                  'channel_id, role_id, allow_permissions, deny_permissions',
                )
                .eq('channel_id', channelId)
            as List<dynamic>;

    return rows
        .map(
          (row) =>
              ChannelPermissionOverride.fromMap(row as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<ServerRole>> fetchServerRoles(String serverId) async {
    final roleRows =
        await client
                .from('server_roles')
                .select(
                  'id, server_id, name, permissions, is_system, created_at',
                )
                .eq('server_id', serverId)
                .order('created_at', ascending: true)
            as List<dynamic>;

    return roleRows
        .map((row) => ServerRole.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<ServerMember>> fetchServerMembers(String serverId) async {
    final memberRows =
        await client
                .from('server_members')
                .select('user_id, joined_at')
                .eq('server_id', serverId)
                .order('joined_at', ascending: true)
            as List<dynamic>;

    final userIds = memberRows
        .map((row) => (row as Map<String, dynamic>)['user_id'] as String)
        .toList();

    final profileRows = userIds.isEmpty
        ? const <dynamic>[]
        : await client
                  .from('user_profiles')
                  .select('id, display_name')
                  .inFilter('id', userIds)
              as List<dynamic>;
    final profilesById = {
      for (final row in profileRows)
        (row as Map<String, dynamic>)['id'] as String:
            row['display_name'] as String? ?? 'Unknown',
    };

    final memberRoleRows =
        await client
                .from('server_member_roles')
                .select('user_id, role_id')
                .eq('server_id', serverId)
            as List<dynamic>;
    final roleIdsByUser = <String, Set<String>>{};
    for (final row in memberRoleRows) {
      final record = row as Map<String, dynamic>;
      final userId = record['user_id'] as String;
      final roleId = record['role_id'] as String;
      roleIdsByUser.putIfAbsent(userId, () => <String>{}).add(roleId);
    }

    return memberRows.map((row) {
      final record = row as Map<String, dynamic>;
      final userId = record['user_id'] as String;
      final fallbackName = 'User ${userId.substring(0, 8)}';
      return ServerMember(
        userId: userId,
        displayName: profilesById[userId] ?? fallbackName,
        joinedAt: DateTime.parse(record['joined_at'] as String).toLocal(),
        roleIds: roleIdsByUser[userId] ?? const <String>{},
      );
    }).toList();
  }

  Future<ChannelSummary> createChannel({
    required String serverId,
    required String? categoryId,
    required String name,
    required ChannelKind kind,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Channel name is required.');
    }

    final lastChannel = await client
        .from('channels')
        .select('position')
        .eq('server_id', serverId)
        .filter(
          'category_id',
          categoryId == null ? 'is' : 'eq',
          categoryId ?? 'null',
        )
        .order('position', ascending: false)
        .limit(1)
        .maybeSingle();

    final nextPosition = (lastChannel?['position'] as int? ?? -1) + 1;

    final row = await client
        .from('channels')
        .insert({
          'server_id': serverId,
          'category_id': categoryId,
          'name': cleanName,
          'kind': kind.name,
          'position': nextPosition,
          'created_by': authService.userId,
        })
        .select(
          'id, server_id, category_id, name, kind, position, created_by, created_at',
        )
        .single();

    return ChannelSummary.fromMap(row);
  }

  Future<ChannelCategorySummary> createChannelCategory({
    required String serverId,
    required String name,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Category name is required.');
    }

    final lastCategory = await client
        .from('channel_categories')
        .select('position')
        .eq('server_id', serverId)
        .order('position', ascending: false)
        .limit(1)
        .maybeSingle();

    final nextPosition = (lastCategory?['position'] as int? ?? -1) + 1;

    final row = await client
        .from('channel_categories')
        .insert({
          'server_id': serverId,
          'name': cleanName,
          'position': nextPosition,
          'created_by': authService.userId,
        })
        .select('id, server_id, name, position, created_by, created_at')
        .single();

    return ChannelCategorySummary.fromMap(row);
  }

  Future<ChannelCategorySummary> renameChannelCategory({
    required String categoryId,
    required String name,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Category name is required.');
    }

    final row = await client
        .from('channel_categories')
        .update({'name': cleanName})
        .eq('id', categoryId)
        .select('id, server_id, name, position, created_by, created_at')
        .single();

    return ChannelCategorySummary.fromMap(row);
  }

  Future<void> reorderChannelCategories(
    List<ChannelCategoryOrderUpdate> updates,
  ) async {
    for (final update in updates) {
      await client
          .from('channel_categories')
          .update({'position': update.position})
          .eq('id', update.categoryId);
    }
  }

  Future<void> reorderChannels(List<ChannelOrderUpdate> updates) async {
    for (final update in updates) {
      await client
          .from('channels')
          .update({
            'position': update.position,
            'category_id': update.categoryId,
          })
          .eq('id', update.channelId);
    }
  }

  Future<void> removeMemberFromServer({
    required String serverId,
    required String userId,
  }) async {
    await client
        .from('server_members')
        .delete()
        .eq('server_id', serverId)
        .eq('user_id', userId);
  }

  Future<void> deleteServer(String serverId) async {
    await client.from('servers').delete().eq('id', serverId);
  }

  Future<ServerRole> createRole({
    required String serverId,
    required String name,
    required Set<ServerPermission> permissions,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Role name is required.');
    }

    final row = await client
        .from('server_roles')
        .insert({
          'server_id': serverId,
          'name': cleanName,
          'permissions': {
            for (final permission in ServerPermission.values)
              permission.key: permissions.contains(permission),
          },
        })
        .select('id, server_id, name, permissions, is_system, created_at')
        .single();

    return ServerRole.fromMap(row);
  }

  Future<ServerRole> updateRole({
    required String roleId,
    required String name,
    required Set<ServerPermission> permissions,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw StateError('Role name is required.');
    }

    final row = await client
        .from('server_roles')
        .update({
          'name': cleanName,
          'permissions': {
            for (final permission in ServerPermission.values)
              permission.key: permissions.contains(permission),
          },
        })
        .eq('id', roleId)
        .select('id, server_id, name, permissions, is_system, created_at')
        .single();

    return ServerRole.fromMap(row);
  }

  Future<void> assignRole({
    required String serverId,
    required String userId,
    required String roleId,
  }) async {
    await client.from('server_member_roles').insert({
      'server_id': serverId,
      'user_id': userId,
      'role_id': roleId,
    });
  }

  Future<void> removeRole({
    required String serverId,
    required String userId,
    required String roleId,
  }) async {
    await client
        .from('server_member_roles')
        .delete()
        .eq('server_id', serverId)
        .eq('user_id', userId)
        .eq('role_id', roleId);
  }

  Future<void> saveChannelPermissionOverride({
    required String channelId,
    required String roleId,
    required Set<ServerPermission> allowPermissions,
    required Set<ServerPermission> denyPermissions,
  }) async {
    Map<String, bool> toJsonMap(Set<ServerPermission> permissions) {
      return {
        for (final permission in ServerPermission.channelScoped)
          permission.key: permissions.contains(permission),
      };
    }

    if (allowPermissions.isEmpty && denyPermissions.isEmpty) {
      await client
          .from('channel_permission_overrides')
          .delete()
          .eq('channel_id', channelId)
          .eq('role_id', roleId);
      return;
    }

    await client.from('channel_permission_overrides').upsert({
      'channel_id': channelId,
      'role_id': roleId,
      'allow_permissions': toJsonMap(allowPermissions),
      'deny_permissions': toJsonMap(denyPermissions),
    });
  }

  Stream<List<ChannelMessage>> watchChannelMessages(String channelId) {
    return client
        .from('channel_messages')
        .stream(primaryKey: ['id'])
        .eq('channel_id', channelId)
        .order('created_at', ascending: true)
        .map(
          (rows) => rows
              .map((row) => ChannelMessage.fromMap(row))
              .where((message) => !message.deleted)
              .toList(),
        );
  }

  Future<void> sendChannelMessage({
    required String channelId,
    required String body,
    ChannelMessage? replyToMessage,
  }) async {
    final cleanBody = body.trim();
    if (cleanBody.isEmpty) {
      return;
    }

    await client.from('channel_messages').insert({
      'channel_id': channelId,
      'sender_id': authService.userId,
      'sender_display_name': authService.displayName,
      'body': cleanBody,
      'reply_to_message_id': replyToMessage?.id,
      'reply_to_body': replyToMessage == null ? null : _replyPreview(replyToMessage.body),
      'reply_to_sender_display_name': replyToMessage?.senderDisplayName,
    });
  }

  Future<void> deleteChannelMessage(String messageId) async {
    await client.rpc(
      'delete_channel_message',
      params: <String, dynamic>{'message_id_input': messageId},
    );
  }

  Future<void> toggleChannelMessageReaction({
    required String messageId,
    required String emoji,
  }) async {
    await client.rpc(
      'toggle_channel_message_reaction',
      params: <String, dynamic>{
        'message_id_input': messageId,
        'emoji_input': emoji.trim(),
      },
    );
  }

  Future<String> createOrGetDirectConversation({
    required String otherUserId,
  }) async {
    final response = await client.rpc(
      'create_or_get_direct_conversation',
      params: <String, dynamic>{'other_user_id_input': otherUserId},
    );
    if (response is String && response.isNotEmpty) {
      return response;
    }
    throw StateError('Unable to create a direct conversation.');
  }

  Future<List<DirectConversationSummary>> fetchDirectConversationSummaries() async {
    final response = await client.rpc('list_direct_conversations');
    if (response is! List) {
      return const <DirectConversationSummary>[];
    }
    return response
        .map((row) => DirectConversationSummary.fromMap(Map<String, dynamic>.from(row as Map)))
        .toList()
      ..sort((left, right) {
        final rightTime = right.lastMessageAt;
        final leftTime = left.lastMessageAt;
        if (leftTime == null && rightTime == null) {
          return left.otherDisplayName.toLowerCase().compareTo(
            right.otherDisplayName.toLowerCase(),
          );
        }
        if (leftTime == null) {
          return 1;
        }
        if (rightTime == null) {
          return -1;
        }
        return rightTime.compareTo(leftTime);
      });
  }

  Stream<List<DirectConversationSummary>> watchDirectConversationSummaries() {
    late final StreamController<List<DirectConversationSummary>> controller;
    StreamSubscription<List<Map<String, dynamic>>>? conversationsSub;
    StreamSubscription<List<Map<String, dynamic>>>? membershipsSub;
    StreamSubscription<List<Map<String, dynamic>>>? profilesSub;
    var active = true;

    Future<void> emitLatest() async {
      if (!active) {
        return;
      }
      try {
        controller.add(await fetchDirectConversationSummaries());
      } catch (error, stackTrace) {
        if (active) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller = StreamController<List<DirectConversationSummary>>.broadcast(
      onListen: () {
        unawaited(emitLatest());
        conversationsSub = client
            .from('direct_conversations')
            .stream(primaryKey: ['id'])
            .listen((_) => unawaited(emitLatest()));
        membershipsSub = client
            .from('direct_conversation_members')
            .stream(primaryKey: ['conversation_id', 'user_id'])
            .eq('user_id', authService.userId)
            .listen((_) => unawaited(emitLatest()));
        profilesSub = client
            .from('user_profiles')
            .stream(primaryKey: ['id'])
            .listen((_) => unawaited(emitLatest()));
      },
      onCancel: () async {
        active = false;
        await conversationsSub?.cancel();
        await membershipsSub?.cancel();
        await profilesSub?.cancel();
      },
    );

    return controller.stream;
  }

  Stream<List<DirectMessage>> watchDirectMessages(String conversationId) {
    return client
        .from('direct_messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at', ascending: true)
        .map((rows) => rows.map((row) => DirectMessage.fromMap(row)).toList());
  }

  Future<void> sendDirectMessage({
    required String conversationId,
    required String body,
    DirectMessage? replyToMessage,
  }) async {
    final cleanBody = body.trim();
    if (cleanBody.isEmpty) {
      return;
    }

    await client.from('direct_messages').insert({
      'conversation_id': conversationId,
      'sender_id': authService.userId,
      'sender_display_name': authService.displayName,
      'body': cleanBody,
      'reply_to_message_id': replyToMessage?.id,
      'reply_to_body': replyToMessage == null ? null : _replyPreview(replyToMessage.body),
      'reply_to_sender_display_name': replyToMessage?.senderDisplayName,
    });
  }

  Future<void> markDirectConversationRead(String conversationId) async {
    await client
        .from('direct_conversation_members')
        .update({'last_read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', authService.userId);
  }

  Future<void> deleteDirectMessage(String messageId) async {
    await client.rpc(
      'delete_direct_message',
      params: <String, dynamic>{'message_id_input': messageId},
    );
  }

  Future<void> toggleDirectMessageReaction({
    required String messageId,
    required String emoji,
  }) async {
    await client.rpc(
      'toggle_direct_message_reaction',
      params: <String, dynamic>{
        'message_id_input': messageId,
        'emoji_input': emoji.trim(),
      },
    );
  }

  Future<List<GiphyGifResult>> searchGifs({
    String query = '',
    int limit = 24,
  }) async {
    final apiKey = AppBootstrap.giphyApiKey.trim();
    if (apiKey.isEmpty) {
      return const <GiphyGifResult>[];
    }

    final normalizedQuery = query.trim();
    final uri = normalizedQuery.isEmpty
        ? Uri.https(
            'api.giphy.com',
            '/v1/gifs/trending',
            <String, String>{
              'api_key': apiKey,
              'limit': '$limit',
              'rating': 'pg-13',
            },
          )
        : Uri.https(
            'api.giphy.com',
            '/v1/gifs/search',
            <String, String>{
              'api_key': apiKey,
              'q': normalizedQuery,
              'limit': '$limit',
              'rating': 'pg-13',
              'lang': 'en',
            },
          );

    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Giphy search failed with status ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      return const <GiphyGifResult>[];
    }
    final data = decoded['data'];
    if (data is! List) {
      return const <GiphyGifResult>[];
    }

    return data
        .whereType<Map>()
        .map(
          (item) => GiphyGifResult.fromMap(Map<String, dynamic>.from(item)),
        )
        .where(
          (gif) => gif.previewUrl.isNotEmpty && gif.gifUrl.isNotEmpty,
        )
        .toList(growable: false);
  }

  String _replyPreview(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 140) {
      return normalized;
    }
    return '${normalized.substring(0, 137)}...';
  }
}
