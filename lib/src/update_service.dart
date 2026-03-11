import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'app_bootstrap.dart';
import 'update_installer_stub.dart'
    if (dart.library.io) 'update_installer_io.dart';

enum UpdateActionResult {
  disabled,
  noUpdate,
  updateAvailable,
  installing,
  startedInstaller,
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  Timer? _backgroundTimer;
  bool _initialized = false;
  bool _checking = false;
  bool _installing = false;
  bool _hasUpdate = false;
  String? _currentVersion;
  String? _latestVersion;
  String? _downloadUrl;
  String? _downloadFileName;
  String? _errorMessage;
  bool _startupInstallAttempted = false;

  bool get enabled =>
      AppBootstrap.updateRepository.trim().isNotEmpty &&
      defaultTargetPlatform == TargetPlatform.windows &&
      !kIsWeb;
  bool get checking => _checking;
  bool get installing => _installing;
  bool get hasUpdate => _hasUpdate;
  bool get busy => _checking || _installing;
  String? get currentVersion => _currentVersion;
  String? get latestVersion => _latestVersion;
  String? get errorMessage => _errorMessage;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (!enabled) {
      return;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    _currentVersion = packageInfo.version;
    notifyListeners();

    unawaited(checkForUpdates(autoInstallIfAvailable: true));
    _backgroundTimer = Timer.periodic(const Duration(hours: 2), (_) {
      unawaited(checkForUpdates());
    });
  }

  Future<UpdateActionResult> checkForUpdates({
    bool autoInstallIfAvailable = false,
  }) async {
    if (!enabled) {
      return UpdateActionResult.disabled;
    }
    if (_checking || _installing) {
      return UpdateActionResult.installing;
    }

    _checking = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final request = http.Request(
        'GET',
        Uri.parse(
          'https://api.github.com/repos/${AppBootstrap.updateRepository}/releases/latest',
        ),
      );
      request.headers['Accept'] = 'application/vnd.github+json';
      request.headers['User-Agent'] = 'ChitChat-Updater';
      final response = await _httpClient.send(request);
      final body = await response.stream.bytesToString();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Update check failed with status ${response.statusCode}.');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final releaseVersion = _normalizeVersion(
        (json['tag_name'] as String?) ??
            (json['name'] as String?) ??
            '',
      );
      final currentVersion = _normalizeVersion(_currentVersion ?? '');
      final releaseAsset = _resolveInstallerAsset(json['assets']);
      if (releaseVersion == null || currentVersion == null || releaseAsset == null) {
        _hasUpdate = false;
        _latestVersion = releaseVersion;
        _downloadUrl = null;
        _downloadFileName = null;
        return UpdateActionResult.noUpdate;
      }

      _latestVersion = releaseVersion;
      _downloadUrl = releaseAsset.$1;
      _downloadFileName = releaseAsset.$2;
      _hasUpdate = _compareVersions(releaseVersion, currentVersion) > 0;

      if (_hasUpdate && autoInstallIfAvailable && !_startupInstallAttempted) {
        _startupInstallAttempted = true;
        return await installUpdate();
      }

      return _hasUpdate
          ? UpdateActionResult.updateAvailable
          : UpdateActionResult.noUpdate;
    } catch (error) {
      _errorMessage = error.toString();
      return UpdateActionResult.noUpdate;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<UpdateActionResult> installUpdate() async {
    if (!enabled) {
      return UpdateActionResult.disabled;
    }
    if (_installing || _downloadUrl == null || _downloadFileName == null) {
      return UpdateActionResult.noUpdate;
    }

    _installing = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await installWindowsUpdateFromRelease(
        downloadUrl: Uri.parse(_downloadUrl!),
        fileName: _downloadFileName!,
      );
      return UpdateActionResult.startedInstaller;
    } catch (error) {
      _errorMessage = error.toString();
      return UpdateActionResult.noUpdate;
    } finally {
      _installing = false;
      notifyListeners();
    }
  }

  (String, String)? _resolveInstallerAsset(Object? rawAssets) {
    if (rawAssets is! List) {
      return null;
    }

    for (final asset in rawAssets.whereType<Map>()) {
      final name = asset['name']?.toString() ?? '';
      final url = asset['browser_download_url']?.toString() ?? '';
      if (name.toLowerCase().endsWith('.exe') && url.isNotEmpty) {
        return (url, name);
      }
    }
    return null;
  }

  String? _normalizeVersion(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[^0-9]*'), '');
    if (cleaned.isEmpty) {
      return null;
    }
    final match = RegExp(r'^\d+(\.\d+){0,3}').firstMatch(cleaned);
    return match?.group(0);
  }

  int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList();
    final rightParts = right.split('.').map(int.parse).toList();
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final leftValue = index < leftParts.length ? leftParts[index] : 0;
      final rightValue = index < rightParts.length ? rightParts[index] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }
    return 0;
  }

  @override
  void dispose() {
    _backgroundTimer?.cancel();
    _httpClient.close();
    super.dispose();
  }
}
