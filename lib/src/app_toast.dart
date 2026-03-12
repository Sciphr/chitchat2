import 'dart:async';

import 'package:flutter/material.dart';

enum AppToastTone { neutral, success, error }

class _ToastRecord {
  const _ToastRecord({
    required this.id,
    required this.message,
    required this.tone,
  });

  final int id;
  final String message;
  final AppToastTone tone;
}

class _AppToastManager {
  OverlayEntry? _hostEntry;
  int _nextId = 0;
  final List<_ToastRecord> _toasts = <_ToastRecord>[];

  void show(
    BuildContext context,
    String message, {
    AppToastTone tone = AppToastTone.neutral,
    Duration duration = const Duration(seconds: 4),
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _ensureHost(overlay);
    final toast = _ToastRecord(id: _nextId++, message: message, tone: tone);
    _toasts.add(toast);
    _hostEntry?.markNeedsBuild();

    unawaited(
      Future<void>.delayed(duration, () {
        _toasts.removeWhere((entry) => entry.id == toast.id);
        if (_toasts.isEmpty) {
          _hostEntry?.remove();
          _hostEntry = null;
        } else {
          _hostEntry?.markNeedsBuild();
        }
      }),
    );
  }

  void _ensureHost(OverlayState overlay) {
    if (_hostEntry != null) {
      return;
    }
    _hostEntry = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        return IgnorePointer(
          child: SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final toast in _toasts) ...[
                        _ToastCard(
                          message: toast.message,
                          tone: toast.tone,
                          theme: theme,
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_hostEntry!);
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({
    required this.message,
    required this.tone,
    required this.theme,
  });

  final String message;
  final AppToastTone tone;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final colorScheme = theme.colorScheme;
    final (background, foreground, icon) = switch (tone) {
      AppToastTone.success => (
        colorScheme.secondaryContainer.withAlpha(230),
        colorScheme.onSecondaryContainer,
        Icons.check_circle_outline,
      ),
      AppToastTone.error => (
        colorScheme.errorContainer.withAlpha(235),
        colorScheme.onErrorContainer,
        Icons.error_outline,
      ),
      AppToastTone.neutral => (
        colorScheme.surfaceContainerHighest.withAlpha(235),
        colorScheme.onSurface,
        Icons.info_outline,
      ),
    };

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: foreground.withAlpha(60)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(45),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _AppToastManager _toastManager = _AppToastManager();

void showAppToast(
  BuildContext context,
  String message, {
  AppToastTone tone = AppToastTone.neutral,
  Duration duration = const Duration(seconds: 4),
}) {
  _toastManager.show(context, message, tone: tone, duration: duration);
}
