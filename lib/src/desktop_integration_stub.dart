import 'dart:async';

const String kDesktopOAuthScheme = 'chitchat2';
const String kDesktopOAuthRedirectTo = '$kDesktopOAuthScheme://login-callback';

bool get supportsCustomDesktopFrame => false;

Stream<Uri> get desktopDeepLinks => const Stream.empty();

void initializeDesktopIntegration() {}

void configureDesktopWindow() {}
