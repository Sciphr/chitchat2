import 'dart:async';

import 'package:flutter/foundation.dart';

const String kDesktopOAuthScheme = 'chitchat2';
const String kDesktopOAuthRedirectTo = '$kDesktopOAuthScheme://login-callback';

bool get supportsCustomDesktopFrame => false;

Stream<Uri> get desktopDeepLinks => const Stream.empty();

final ValueNotifier<bool> _desktopFullscreenPresentationNotifier =
    ValueNotifier<bool>(false);

ValueListenable<bool> get desktopFullscreenPresentationListenable =>
    _desktopFullscreenPresentationNotifier;

bool get desktopFullscreenPresentationActive =>
    _desktopFullscreenPresentationNotifier.value;

void initializeDesktopIntegration() {}

void configureDesktopWindow() {}

bool enterDesktopFullscreenPresentation() {
  _desktopFullscreenPresentationNotifier.value = true;
  return false;
}

void exitDesktopFullscreenPresentation({bool restoreWindow = false}) {
  _desktopFullscreenPresentationNotifier.value = false;
}
