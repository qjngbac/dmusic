import 'dart:io';
import 'package:dmusic_app/services/audio_converter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'audio_fixtures.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [path];
}

void main() {
  test(
    'missing encoder rejects conversion without creating a fake format',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'dmusic-convert-test-',
      );
      PathProviderPlatform.instance = _Paths(directory.path);
      final bytes = wavFixture();
      final source = await File(
        '${directory.path}/source.wav',
      ).writeAsBytes(bytes);
      try {
        final service = AudioConverterService();
        await expectLater(
          service.convertAudio(
            sourceFile: source,
            title: 'Test',
            artist: 'Artist',
            targetFormat: 'flac',
            sampleRate: 48000,
            saveToLibrary: false,
          ),
          throwsUnsupportedError,
        );
        expect(service.tasks.first.status, '转换失败');
        expect(service.tasks.first.outputPath, isNull);
        expect(await source.readAsBytes(), bytes);
        expect(directory.listSync().whereType<File>().length, 1);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
