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

  static String get _persistSessionKey =>
      'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

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
