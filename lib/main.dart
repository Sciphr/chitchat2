import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/app_bootstrap.dart';
import 'src/desktop_integration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeDesktopIntegration();
  final bootstrap = await AppBootstrap.initialize();
  runApp(ChatApp(bootstrap: bootstrap));
  configureDesktopWindow();
}
