import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

class AppBootstrap {
  const AppBootstrap({
    required this.isConfigured,
    required this.hasInitializationError,
    this.message,
  });

  final bool isConfigured;
  final bool hasInitializationError;
  final String? message;

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );
  static const String updateRepository = String.fromEnvironment(
    'APP_UPDATE_REPOSITORY',
    defaultValue: 'Sciphr/chitchat2',
  );
  static const String liveKitUrl = String.fromEnvironment(
    'LIVEKIT_URL',
    defaultValue: '',
  );
  static const String liveKitTokenFunctionName = String.fromEnvironment(
    'LIVEKIT_TOKEN_FUNCTION_NAME',
    defaultValue: 'livekit-token',
  );
  static const String giphyApiKey = String.fromEnvironment(
    'GIPHY_API_KEY',
    defaultValue: '',
  );
  static const String webrtcIceServersJson = String.fromEnvironment(
    'WEBRTC_ICE_SERVERS_JSON',
    defaultValue: '',
  );
  static const String _defaultStunUrl = 'stun:stun.l.google.com:19302';

  static String get _persistSessionKey =>
      'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

  static List<Map<String, dynamic>> get webrtcIceServers {
    final raw = webrtcIceServersJson.trim();
    if (raw.isEmpty) {
      return _defaultIceServers();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return _defaultIceServers();
      }

      final normalized = decoded
          .whereType<Map>()
          .map<Map<String, dynamic>>(_normalizeIceServer)
          .where((server) => server['urls'] != null)
          .toList(growable: false);
      if (normalized.isEmpty) {
        return _defaultIceServers();
      }
      return normalized;
    } on FormatException {
      return _defaultIceServers();
    }
  }

  static Map<String, dynamic> _normalizeIceServer(Map<dynamic, dynamic> value) {
    final urlsValue = value['urls'];
    final urls = urlsValue is String
        ? <String>[urlsValue]
        : urlsValue is List
        ? urlsValue.map((item) => item.toString()).toList(growable: false)
        : const <String>[];
    if (urls.isEmpty) {
      return const <String, dynamic>{};
    }

    final normalized = <String, dynamic>{'urls': urls};
    final username = value['username']?.toString().trim();
    final credential = value['credential']?.toString().trim();
    if (username != null && username.isNotEmpty) {
      normalized['username'] = username;
    }
    if (credential != null && credential.isNotEmpty) {
      normalized['credential'] = credential;
    }
    return normalized;
  }

  static List<Map<String, dynamic>> _defaultIceServers() => const [
    <String, dynamic>{
      'urls': <String>[_defaultStunUrl],
    },
  ];

  static Future<AppBootstrap> initialize() async {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      return const AppBootstrap(
        isConfigured: false,
        hasInitializationError: false,
        message:
            'Missing SUPABASE_URL or SUPABASE_ANON_KEY. Provide both via --dart-define.',
      );
    }

    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
        authOptions: FlutterAuthClientOptions(
          autoRefreshToken: true,
          detectSessionInUri: true,
          localStorage: SharedPreferencesLocalStorage(
            persistSessionKey: _persistSessionKey,
          ),
        ),
      );
      return const AppBootstrap(
        isConfigured: true,
        hasInitializationError: false,
      );
    } catch (error) {
      return AppBootstrap(
        isConfigured: false,
        hasInitializationError: true,
        message: error.toString(),
      );
    }
  }
}
