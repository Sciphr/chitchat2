import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeScheme { ocean, ember, forest }

class AppPreferences extends ChangeNotifier {
  AppThemeScheme _themeScheme = AppThemeScheme.ocean;
  bool _desktopNotifications = true;
  bool _playSounds = true;
  bool _messageAnimations = true;
  bool _reduceMotion = false;
  bool _use24HourTime = false;
  String? _preferredAudioInputId;
  String? _preferredAudioOutputId;
  String? _preferredVideoInputId;
  bool _noiseCancellation = true;
  double _inputSensitivity = 1.0;

  AppThemeScheme get themeScheme => _themeScheme;
  bool get desktopNotifications => _desktopNotifications;
  bool get playSounds => _playSounds;
  bool get messageAnimations => _messageAnimations;
  bool get reduceMotion => _reduceMotion;
  bool get use24HourTime => _use24HourTime;
  String? get preferredAudioInputId => _preferredAudioInputId;
  String? get preferredAudioOutputId => _preferredAudioOutputId;
  String? get preferredVideoInputId => _preferredVideoInputId;
  bool get noiseCancellation => _noiseCancellation;
  double get inputSensitivity => _inputSensitivity;

  Duration get motionDuration =>
      _reduceMotion ? Duration.zero : const Duration(milliseconds: 280);

  static const _themeKey = 'prefs.theme_scheme';
  static const _notificationsKey = 'prefs.desktop_notifications';
  static const _soundsKey = 'prefs.play_sounds';
  static const _messageAnimationsKey = 'prefs.message_animations';
  static const _reduceMotionKey = 'prefs.reduce_motion';
  static const _use24HourTimeKey = 'prefs.use_24_hour_time';
  static const _audioInputKey = 'prefs.audio_input_id';
  static const _audioOutputKey = 'prefs.audio_output_id';
  static const _videoInputKey = 'prefs.video_input_id';
  static const _noiseCancellationKey = 'prefs.noise_cancellation';
  static const _inputSensitivityKey = 'prefs.input_sensitivity';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString(_themeKey);
    _themeScheme = AppThemeScheme.values.firstWhere(
      (scheme) => scheme.name == themeName,
      orElse: () => AppThemeScheme.ocean,
    );
    _desktopNotifications = prefs.getBool(_notificationsKey) ?? true;
    _playSounds = prefs.getBool(_soundsKey) ?? true;
    _messageAnimations = prefs.getBool(_messageAnimationsKey) ?? true;
    _reduceMotion = prefs.getBool(_reduceMotionKey) ?? false;
    _use24HourTime = prefs.getBool(_use24HourTimeKey) ?? false;
    _preferredAudioInputId = prefs.getString(_audioInputKey);
    _preferredAudioOutputId = prefs.getString(_audioOutputKey);
    _preferredVideoInputId = prefs.getString(_videoInputKey);
    _noiseCancellation = prefs.getBool(_noiseCancellationKey) ?? true;
    _inputSensitivity = (prefs.getDouble(_inputSensitivityKey) ?? 1.0).clamp(
      0.5,
      2.0,
    );
    notifyListeners();
  }

  Future<void> setThemeScheme(AppThemeScheme scheme) async {
    _themeScheme = scheme;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, scheme.name);
  }

  Future<void> setDesktopNotifications(bool value) async {
    _desktopNotifications = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsKey, value);
  }

  Future<void> setPlaySounds(bool value) async {
    _playSounds = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_soundsKey, value);
  }

  Future<void> setMessageAnimations(bool value) async {
    _messageAnimations = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_messageAnimationsKey, value);
  }

  Future<void> setReduceMotion(bool value) async {
    _reduceMotion = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reduceMotionKey, value);
  }

  Future<void> setUse24HourTime(bool value) async {
    _use24HourTime = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_use24HourTimeKey, value);
  }

  Future<void> setPreferredAudioInputId(String? value) async {
    _preferredAudioInputId = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_audioInputKey);
    } else {
      await prefs.setString(_audioInputKey, value);
    }
  }

  Future<void> setPreferredAudioOutputId(String? value) async {
    _preferredAudioOutputId = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_audioOutputKey);
    } else {
      await prefs.setString(_audioOutputKey, value);
    }
  }

  Future<void> setPreferredVideoInputId(String? value) async {
    _preferredVideoInputId = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_videoInputKey);
    } else {
      await prefs.setString(_videoInputKey, value);
    }
  }

  Future<void> setNoiseCancellation(bool value) async {
    _noiseCancellation = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_noiseCancellationKey, value);
  }

  Future<void> setInputSensitivity(double value) async {
    _inputSensitivity = value.clamp(0.5, 2.0);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_inputSensitivityKey, _inputSensitivity);
  }
}

@immutable
class AppThemePalette extends ThemeExtension<AppThemePalette> {
  const AppThemePalette({
    required this.appBackground,
    required this.heroGradient,
    required this.panel,
    required this.panelMuted,
    required this.panelStrong,
    required this.panelAccent,
    required this.border,
    required this.borderStrong,
  });

  final Gradient appBackground;
  final Gradient heroGradient;
  final Color panel;
  final Color panelMuted;
  final Color panelStrong;
  final Color panelAccent;
  final Color border;
  final Color borderStrong;

  @override
  AppThemePalette copyWith({
    Gradient? appBackground,
    Gradient? heroGradient,
    Color? panel,
    Color? panelMuted,
    Color? panelStrong,
    Color? panelAccent,
    Color? border,
    Color? borderStrong,
  }) {
    return AppThemePalette(
      appBackground: appBackground ?? this.appBackground,
      heroGradient: heroGradient ?? this.heroGradient,
      panel: panel ?? this.panel,
      panelMuted: panelMuted ?? this.panelMuted,
      panelStrong: panelStrong ?? this.panelStrong,
      panelAccent: panelAccent ?? this.panelAccent,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
    );
  }

  @override
  AppThemePalette lerp(ThemeExtension<AppThemePalette>? other, double t) {
    if (other is! AppThemePalette) {
      return this;
    }
    return AppThemePalette(
      appBackground: other.appBackground,
      heroGradient: other.heroGradient,
      panel: Color.lerp(panel, other.panel, t) ?? panel,
      panelMuted: Color.lerp(panelMuted, other.panelMuted, t) ?? panelMuted,
      panelStrong: Color.lerp(panelStrong, other.panelStrong, t) ?? panelStrong,
      panelAccent: Color.lerp(panelAccent, other.panelAccent, t) ?? panelAccent,
      border: Color.lerp(border, other.border, t) ?? border,
      borderStrong:
          Color.lerp(borderStrong, other.borderStrong, t) ?? borderStrong,
    );
  }
}

ColorScheme colorSchemeForTheme(AppThemeScheme scheme) {
  switch (scheme) {
    case AppThemeScheme.ember:
      return const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFFFFB06A),
        onPrimary: Color(0xFF351300),
        secondary: Color(0xFFFFE38B),
        onSecondary: Color(0xFF3A2802),
        error: Color(0xFFFF8C7A),
        onError: Color(0xFF2E0701),
        surface: Color(0xFF241717),
        onSurface: Color(0xFFF8F1EC),
      );
    case AppThemeScheme.forest:
      return const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFF87DFA7),
        onPrimary: Color(0xFF0A2A16),
        secondary: Color(0xFFBDD98E),
        onSecondary: Color(0xFF20310B),
        error: Color(0xFFFF8C7A),
        onError: Color(0xFF2E0701),
        surface: Color(0xFF122119),
        onSurface: Color(0xFFF0F7F1),
      );
    case AppThemeScheme.ocean:
      return const ColorScheme(
        brightness: Brightness.dark,
        primary: Color(0xFF72E0C1),
        onPrimary: Color(0xFF092A22),
        secondary: Color(0xFFFFD38A),
        onSecondary: Color(0xFF382307),
        error: Color(0xFFFF8C7A),
        onError: Color(0xFF2E0701),
        surface: Color(0xFF132033),
        onSurface: Color(0xFFF2F4F7),
      );
  }
}

AppThemePalette paletteForTheme(AppThemeScheme scheme) {
  switch (scheme) {
    case AppThemeScheme.ember:
      return const AppThemePalette(
        appBackground: LinearGradient(
          colors: [Color(0xFF1A0D0A), Color(0xFF2D1710), Color(0xFF362316)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        heroGradient: RadialGradient(
          colors: [Color(0xFF6B3414), Color(0xFF26120B), Color(0xFF120907)],
          radius: 1.05,
          center: Alignment.topLeft,
        ),
        panel: Color(0xFF271914),
        panelMuted: Color(0xB82B1C17),
        panelStrong: Color(0xFF2F1E18),
        panelAccent: Color(0xFF493026),
        border: Color(0xFF714A37),
        borderStrong: Color(0xFFFFB06A),
      );
    case AppThemeScheme.forest:
      return const AppThemePalette(
        appBackground: LinearGradient(
          colors: [Color(0xFF07110C), Color(0xFF0D1E15), Color(0xFF112C1F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        heroGradient: RadialGradient(
          colors: [Color(0xFF234A32), Color(0xFF102016), Color(0xFF07110C)],
          radius: 1.1,
          center: Alignment.topLeft,
        ),
        panel: Color(0xFF102117),
        panelMuted: Color(0xB8112419),
        panelStrong: Color(0xFF14281D),
        panelAccent: Color(0xFF203C2C),
        border: Color(0xFF335A43),
        borderStrong: Color(0xFF87DFA7),
      );
    case AppThemeScheme.ocean:
      return const AppThemePalette(
        appBackground: LinearGradient(
          colors: [Color(0xFF061018), Color(0xFF0B1A2A), Color(0xFF11273B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        heroGradient: RadialGradient(
          colors: [Color(0xFF173658), Color(0xFF0A1320), Color(0xFF05080D)],
          radius: 1.1,
          center: Alignment.topLeft,
        ),
        panel: Color(0xFF0E1928),
        panelMuted: Color(0xA30B1522),
        panelStrong: Color(0xFF102033),
        panelAccent: Color(0xFF133656),
        border: Color(0xFF20344B),
        borderStrong: Color(0xFF72E0C1),
      );
  }
}
