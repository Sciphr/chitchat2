import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

bool _notificationsInitialized = false;

bool get _supportsDesktopNotifications =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<void> initializeDesktopNotifications() async {
  if (_notificationsInitialized || !_supportsDesktopNotifications) {
    return;
  }
  try {
    await localNotifier.setup(
      appName: 'ChitChat',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _notificationsInitialized = true;
  } catch (_) {
    _notificationsInitialized = false;
  }
}

Future<void> showDesktopNotification({
  required String title,
  String? body,
}) async {
  if (!_notificationsInitialized) {
    return;
  }
  try {
    final notification = LocalNotification(
      title: title,
      body: body,
      silent: true,
    );
    await notification.show();
  } catch (_) {
    // Native notifications should fail silently and leave the in-app toast path intact.
  }
}
