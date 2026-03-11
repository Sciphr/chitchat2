import 'dart:async';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_bootstrap.dart';
import 'app_preferences.dart';
import 'desktop_integration.dart';
import 'repositories.dart';
import 'update_service.dart';
import 'workspace_screen.dart';

class ChatApp extends StatefulWidget {
  const ChatApp({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  final AppPreferences _preferences = AppPreferences();
  final AppUpdateController _updateController = AppUpdateController();
  StreamSubscription<Uri>? _desktopDeepLinkSubscription;

  @override
  void initState() {
    super.initState();
    _preferences.load();
    unawaited(_updateController.initialize());
    _desktopDeepLinkSubscription = desktopDeepLinks.listen((uri) {
      unawaited(_handleDesktopDeepLink(uri));
    });
  }

  Future<void> _handleDesktopDeepLink(Uri uri) async {
    if (!widget.bootstrap.isConfigured) {
      return;
    }

    try {
      await Supabase.instance.client.auth.getSessionFromUrl(uri);
    } catch (_) {
      // Supabase auth callbacks should update session state; invalid links are ignored.
    }
  }

  @override
  void dispose() {
    _desktopDeepLinkSubscription?.cancel();
    _updateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pointerCursor = WidgetStatePropertyAll<MouseCursor>(
      SystemMouseCursors.click,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([_preferences, _updateController]),
      builder: (context, _) {
        final colorScheme = colorSchemeForTheme(_preferences.themeScheme);
        final palette = paletteForTheme(_preferences.themeScheme);

        return MaterialApp(
          title: 'ChitChat',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: colorScheme,
            scaffoldBackgroundColor: colorScheme.surface,
            useMaterial3: true,
            fontFamily: 'Segoe UI',
            extensions: [palette],
            cardTheme: CardThemeData(
              color: palette.panel,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: palette.border),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: palette.panel,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: palette.border),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: palette.panelStrong,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.borderStrong, width: 1.5),
              ),
            ),
            filledButtonTheme: const FilledButtonThemeData(
              style: ButtonStyle(mouseCursor: pointerCursor),
            ),
            outlinedButtonTheme: const OutlinedButtonThemeData(
              style: ButtonStyle(mouseCursor: pointerCursor),
            ),
            textButtonTheme: const TextButtonThemeData(
              style: ButtonStyle(mouseCursor: pointerCursor),
            ),
            iconButtonTheme: const IconButtonThemeData(
              style: ButtonStyle(mouseCursor: pointerCursor),
            ),
            segmentedButtonTheme: const SegmentedButtonThemeData(
              style: ButtonStyle(mouseCursor: pointerCursor),
            ),
            checkboxTheme: const CheckboxThemeData(
              mouseCursor: WidgetStateMouseCursor.clickable,
            ),
          ),
          builder: (context, child) {
            final content = child ?? const SizedBox.shrink();
            if (!supportsCustomDesktopFrame) {
              return content;
            }
            return _DesktopWindowFrame(
              appVersion: _updateController.currentVersion,
              child: content,
            );
          },
          home: _AppShell(
            bootstrap: widget.bootstrap,
            preferences: _preferences,
            updateController: _updateController,
          ),
        );
      },
    );
  }
}

class _AppShell extends StatelessWidget {
  const _AppShell({
    required this.bootstrap,
    required this.preferences,
    required this.updateController,
  });

  final AppBootstrap bootstrap;
  final AppPreferences preferences;
  final AppUpdateController updateController;

  @override
  Widget build(BuildContext context) {
    if (!bootstrap.isConfigured) {
      return _SetupScreen(
        message: bootstrap.message,
        hasInitializationError: bootstrap.hasInitializationError,
      );
    }

    final client = Supabase.instance.client;
    final authService = AuthService(client);
    final workspaceRepository = WorkspaceRepository(
      client: client,
      authService: authService,
    );

    return StreamBuilder<AuthState>(
      stream: authService.authChanges,
      builder: (context, snapshot) {
        final session = snapshot.data?.session ?? client.auth.currentSession;
        if (session == null) {
          return SignInScreen(authService: authService);
        }
        return WorkspaceScreen(
          authService: authService,
          workspaceRepository: workspaceRepository,
          preferences: preferences,
          updateController: updateController,
        );
      },
    );
  }
}

class _SetupScreen extends StatelessWidget {
  const _SetupScreen({
    required this.message,
    required this.hasInitializationError,
  });

  final String? message;
  final bool hasInitializationError;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final tone = hasInitializationError
        ? Theme.of(context).colorScheme.errorContainer
        : Theme.of(context).colorScheme.secondaryContainer;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: palette.appBackground),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasInitializationError
                          ? 'Supabase initialization failed'
                          : 'Supabase configuration required',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message ??
                          'Provide your Supabase project URL and anon key with --dart-define.',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: palette.panelStrong,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: palette.border),
                      ),
                      child: SelectableText(
                        'flutter run -d windows '
                        '--dart-define-from-file=config/dart_defines.local.json',
                        style: TextStyle(color: tone),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();

  bool _createAccount = false;
  bool _submitting = false;
  bool _googleSubmitting = false;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _message = null;
    });

    try {
      if (_createAccount) {
        final signUpMessage = await widget.authService.signUp(
          email: _emailController.text,
          password: _passwordController.text,
          displayName: _displayNameController.text,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _message = signUpMessage ?? 'Account created and signed in.';
        });
      } else {
        await widget.authService.signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  Future<void> _submitGoogle() async {
    setState(() {
      _googleSubmitting = true;
      _message = null;
    });

    try {
      await widget.authService.signInWithGoogle();
      if (!mounted) {
        return;
      }
      setState(() {
        _message = 'Google sign-in opened in your browser.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _googleSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: palette.heroGradient),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 112,
                            height: 112,
                            decoration: BoxDecoration(
                              gradient: palette.heroGradient,
                              borderRadius: BorderRadius.circular(32),
                              border: Border.all(color: palette.border),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.forum_rounded, size: 56),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'ChitChat',
                            style: Theme.of(context).textTheme.displayMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 420,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: const [
                                ButtonSegment<bool>(
                                  value: false,
                                  label: Text('Sign In'),
                                ),
                                ButtonSegment<bool>(
                                  value: true,
                                  label: Text('Create Account'),
                                ),
                              ],
                              selected: {_createAccount},
                              onSelectionChanged: (selection) {
                                setState(() {
                                  _createAccount = selection.first;
                                  _message = null;
                                });
                              },
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Password',
                              ),
                            ),
                            if (_createAccount) ...[
                              const SizedBox(height: 14),
                              TextField(
                                controller: _displayNameController,
                                decoration: const InputDecoration(
                                  labelText: 'Display name',
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: _submitting ? null : _submit,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  child: _submitting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          _createAccount
                                              ? 'Create account'
                                              : 'Sign in',
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(child: Divider(color: palette.border)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'or',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                                Expanded(child: Divider(color: palette.border)),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _submitting || _googleSubmitting
                                    ? null
                                    : _submitGoogle,
                                icon: _googleSubmitting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.login),
                                label: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 14),
                                  child: Text('Continue with Google'),
                                ),
                              ),
                            ),
                            if (_message != null) ...[
                              const SizedBox(height: 14),
                              Text(_message!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowFrame extends StatelessWidget {
  const _DesktopWindowFrame({required this.child, this.appVersion});

  final Widget child;
  final String? appVersion;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return WindowBorder(
      color: palette.border,
      width: 1,
      child: Column(
        children: [
          _DesktopTitleBar(appVersion: appVersion),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _DesktopTitleBar extends StatelessWidget {
  const _DesktopTitleBar({this.appVersion});

  final String? appVersion;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    return WindowTitleBarBox(
      child: Container(
        height: 46,
        color: palette.panelMuted,
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: palette.heroGradient,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.border),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.forum_rounded, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MoveWindow(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    appVersion == null || appVersion!.isEmpty
                        ? 'ChitChat'
                        : 'ChitChat v$appVersion',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            const _DesktopWindowButtons(),
          ],
        ),
      ),
    );
  }
}

class _DesktopWindowButtons extends StatelessWidget {
  const _DesktopWindowButtons();

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).extension<AppThemePalette>()!;
    final buttonColors = WindowButtonColors(
      iconNormal: Theme.of(context).colorScheme.onSurface,
      mouseOver: palette.panelStrong,
      mouseDown: palette.panelAccent,
      iconMouseOver: Theme.of(context).colorScheme.onSurface,
      iconMouseDown: Theme.of(context).colorScheme.onSurface,
    );
    final closeButtonColors = WindowButtonColors(
      iconNormal: Theme.of(context).colorScheme.onSurface,
      mouseOver: Theme.of(context).colorScheme.error,
      mouseDown: Theme.of(context).colorScheme.errorContainer,
      iconMouseOver: Theme.of(context).colorScheme.onError,
      iconMouseDown: Theme.of(context).colorScheme.onErrorContainer,
    );

    return Row(
      children: [
        MinimizeWindowButton(colors: buttonColors),
        MaximizeWindowButton(colors: buttonColors),
        CloseWindowButton(colors: closeButtonColors),
      ],
    );
  }
}
