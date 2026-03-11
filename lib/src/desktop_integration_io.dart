import 'dart:async';
import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

const String kDesktopOAuthScheme = 'chitchat2';
const String kDesktopOAuthRedirectTo = '$kDesktopOAuthScheme://login-callback';
const MethodChannel _nativeWindowChannel = MethodChannel(
  'chitchat2/native_window',
);

final bool _isFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
final StreamController<Uri> _desktopDeepLinkController =
    StreamController<Uri>.broadcast();
bool _desktopIntegrationInitialized = false;

bool get supportsCustomDesktopFrame =>
    !_isFlutterTest &&
    !kIsWeb &&
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Stream<Uri> get desktopDeepLinks => _desktopDeepLinkController.stream;

void initializeDesktopIntegration() {
  if (_desktopIntegrationInitialized || !Platform.isWindows) {
    return;
  }
  _desktopIntegrationInitialized = true;
  _nativeWindowChannel.setMethodCallHandler((call) async {
    if (call.method != 'handleDeepLink') {
      return null;
    }

    final argument = call.arguments;
    if (argument is String && argument.isNotEmpty) {
      _desktopDeepLinkController.add(Uri.parse(argument));
    }
    return null;
  });
}

void configureDesktopWindow() {
  if (!supportsCustomDesktopFrame) {
    return;
  }

  doWhenWindowReady(() {
    final window = appWindow;
    const minSize = Size(1180, 760);
    window.minSize = minSize;
    window.size = const Size(1440, 900);
    window.alignment = Alignment.center;
    window.title = 'ChitChat';
    window.show();
  });

  if (Platform.isWindows) {
    _registerWindowsProtocolHandler();
  }
}

void _registerWindowsProtocolHandler() {
  final executable = Platform.resolvedExecutable;
  final prefix = 'SOFTWARE\\Classes\\$kDesktopOAuthScheme';
  final command = '"${_escapeRegistryValue(executable)}" "%1"';

  _regCreateStringKey(HKEY_CURRENT_USER, prefix, '', 'URL:ChitChat');
  _regCreateStringKey(HKEY_CURRENT_USER, prefix, 'URL Protocol', '');
  _regCreateStringKey(
    HKEY_CURRENT_USER,
    '$prefix\\DefaultIcon',
    '',
    executable,
  );
  _regCreateStringKey(
    HKEY_CURRENT_USER,
    '$prefix\\shell\\open\\command',
    '',
    command,
  );
}

int _regCreateStringKey(int hKey, String key, String valueName, String data) {
  final txtKey = TEXT(key);
  final txtValue = TEXT(valueName);
  final txtData = TEXT(data);
  try {
    return RegSetKeyValue(
      hKey,
      txtKey,
      txtValue,
      REG_SZ,
      txtData,
      txtData.length * 2 + 2,
    );
  } finally {
    free(txtKey);
    free(txtValue);
    free(txtData);
  }
}

String _escapeRegistryValue(String value) {
  return value.replaceAll('"', r'\"');
}
