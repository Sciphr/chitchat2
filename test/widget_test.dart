import 'package:flutter_test/flutter_test.dart';

import 'package:chitchat2/src/app.dart';
import 'package:chitchat2/src/app_bootstrap.dart';

void main() {
  testWidgets('shows setup instructions when Supabase is not configured', (
    WidgetTester tester,
  ) async {
    const bootstrap = AppBootstrap(
      isConfigured: false,
      hasInitializationError: false,
      message: 'Missing SUPABASE_URL or SUPABASE_ANON_KEY.',
    );

    await tester.pumpWidget(const ChatApp(bootstrap: bootstrap));

    expect(find.text('Supabase configuration required'), findsOneWidget);
    expect(
      find.textContaining(
        '--dart-define-from-file=config/dart_defines.local.json',
      ),
      findsOneWidget,
    );
  });
}
