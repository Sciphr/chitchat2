import 'dart:io';

Future<void> installWindowsUpdateFromRelease({
  required Uri downloadUrl,
  required String fileName,
}) async {
  final httpClient = HttpClient();
  final targetFile = File('${Directory.systemTemp.path}\\$fileName');

  if (await targetFile.exists()) {
    await targetFile.delete();
  }

  final request = await httpClient.getUrl(downloadUrl);
  final response = await request.close();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError(
      'Installer download failed with status ${response.statusCode}.',
    );
  }

  final sink = targetFile.openWrite();
  await response.pipe(sink);
  await sink.close();
  httpClient.close(force: true);

  final helperScript = File(
    '${targetFile.parent.path}\\chitchat_update_helper_${DateTime.now().microsecondsSinceEpoch}.ps1',
  );
  final currentExecutable = Platform.resolvedExecutable;
  final currentPid = pid;
  await helperScript.writeAsString('''
\$installerPath = ${_toPowerShellLiteral(targetFile.path)}
\$appPath = ${_toPowerShellLiteral(currentExecutable)}
\$targetPid = $currentPid
\$arguments = @(
  '/SP-',
  '/VERYSILENT',
  '/SUPPRESSMSGBOXES',
  '/NOCANCEL',
  '/NORESTART',
  '/CLOSEAPPLICATIONS',
  '/FORCECLOSEAPPLICATIONS',
  '/MERGETASKS=!desktopicon'
)

while (Get-Process -Id \$targetPid -ErrorAction SilentlyContinue) {
  Start-Sleep -Milliseconds 200
}

Start-Process -FilePath \$installerPath -ArgumentList \$arguments -Wait | Out-Null

if (Test-Path -LiteralPath \$appPath) {
  Start-Sleep -Milliseconds 400
  Start-Process -FilePath \$appPath | Out-Null
}

Remove-Item -LiteralPath \$installerPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
''');

  await Process.start('powershell.exe', <String>[
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    helperScript.path,
  ], mode: ProcessStartMode.detached);
  exit(0);
}

String _toPowerShellLiteral(String value) => "'${value.replaceAll("'", "''")}'";
