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

  await Process.start(
    targetFile.path,
    const <String>[],
    mode: ProcessStartMode.detached,
  );
}
