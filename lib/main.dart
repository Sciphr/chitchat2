import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/app_bootstrap.dart';
import 'src/desktop_integration.dart';
import 'src/desktop_notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDesktopIntegration();
  await initializeDesktopNotifications();
  final bootstrap = await AppBootstrap.initialize();
  runApp(ChatApp(bootstrap: bootstrap));
  configureDesktopWindow();
}
