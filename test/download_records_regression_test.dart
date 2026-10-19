import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'audio_fixtures.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
}

Future<Map<String, dynamic>> _restore({
  bool video = false,
  bool corrupt = false,
  bool missing = false,
  bool preview = false,
  bool absentFromLibrary = false,
  String status = '已完成',
}) => Isolate.run(() async {
  final directory = await Directory.systemTemp.createTemp('dmusic-records-');
  PathProviderPlatform.instance = _Paths(directory.path);
  final file = File('${directory.path}/old-file.mp3');
  final bytes = corrupt ? '<html>not audio</html>'.codeUnits : mp4Fixture(video: video);
  try {
    if (!missing) await file.writeAsBytes(bytes);
    final song = Song(id: 'old', name: 'Old download', artist: 'Artist', album: '',
      source: '网易云', quality: 'AAC 256k', durationSeconds: preview ? 300 : 10,
      localFilePath: file.path, downloadTime: DateTime(2025, 1, 2));
    final libraryFile = File('${directory.path}/dmusic_library.json');
    await libraryFile.writeAsString(jsonEncode({
      'downloads': absentFromLibrary ? [] : [song.toJson()],
      'favorites': [], 'history': [], 'playlists': [],
    }));
    await File('${directory.path}/dmusic_download_tasks.json').writeAsString(jsonEncode([
      DownloadTask(song: song, status: status, savedPath: file.path,
        targetQuality: '320k', progress: 1).toJson(),
    ]));
    var requests = 0;
    final db = DatabaseService();
    await http.runWithClient(() async {
      await db.init();
      await DownloadService().init();
    }, () => MockClient((_) async {
      requests++;
      return http.Response('{}', 503);
    }));
    // Unrelated durable writes must not erase records awaiting verification.
    await db.saveSearchPreferences(db.searchPreferences);
    final tasks = DownloadService().tasks;
    return {
      'requests': requests,
      'tasks': tasks.map((task) => task.toJson()).toList(),
      'downloads': db.downloads.map((item) => item.toJson()).toList(),
      'savedDownloads': jsonDecode(await libraryFile.readAsString())['downloads'],
      'exists': await file.exists(),
      'sameBytes': missing || (await file.readAsBytes()).toString() == bytes.toString(),
      'files': (await directory.list().toList()).map((item) => item.path.split(Platform.pathSeparator).last).toList(),
    };
  } finally {
    await Future<void>.delayed(const Duration(milliseconds: 850));
    await directory.delete(recursive: true);
  }
});

void main() {
  test('full legacy AAC stays completed despite an old MP3 target', () async {
    final result = await _restore();
    final task = (result['tasks'] as List).single as Map;
    expect(task['status'], '已完成');
    expect(task['targetQuality'], '320k');
    expect(task['song']['quality'], startsWith('AAC '));
    expect((result['downloads'] as List).length, 1);
    expect(result['requests'], 0);
    expect(result['sameBytes'], true);
    expect((result['files'] as List).where((name) => name == 'old-file.m4a'), isEmpty);
  });

  test('a misclassified saved task restores the missing library record offline', () async {
    final result = await _restore(absentFromLibrary: true,
      status: '下载失败：已有文件音质不符或为试听片段 (点击恢复)');
    expect(((result['tasks'] as List).single as Map)['status'], '已完成');
    final restored = (result['downloads'] as List).single as Map;
    expect(restored['id'], 'old');
    expect(restored['downloadTime'], DateTime(2025, 1, 2).toIso8601String());
    expect((result['savedDownloads'] as List).length, 1);
    expect(result['requests'], 0);
    expect(result['sameBytes'], true);
  });

  test('legacy MP4 with a valid full audio track remains available honestly', () async {
    final result = await _restore(video: true);
    expect(((result['tasks'] as List).single as Map)['status'], '已完成');
    final restored = (result['downloads'] as List).single as Map;
    expect(restored['quality'], contains('MP4'));
    expect(restored['localFilePath'], endsWith('old-file.mp3'));
    expect(result['sameBytes'], true);
  });

  test('unrecognized local files retain metadata and get a specific local error', () async {
    final result = await _restore(corrupt: true);
    expect(((result['tasks'] as List).single as Map)['status'], contains('无法识别音频'));
    expect(result['downloads'], isEmpty);
    expect((result['savedDownloads'] as List).length, 1);
    expect(result['sameBytes'], true);
  });

  test('a real preview is not completed but retains the original file and record', () async {
    final result = await _restore(preview: true);
    expect(((result['tasks'] as List).single as Map)['status'], contains('时长不符'));
    expect(result['downloads'], isEmpty);
    expect((result['savedDownloads'] as List).length, 1);
    expect(result['sameBytes'], true);
  });

  test('temporarily missing local files keep their task and recovery path', () async {
    final result = await _restore(missing: true);
    final task = (result['tasks'] as List).single as Map;
    expect(task['status'], contains('本地文件缺失'));
    expect(task['savedPath'], endsWith('old-file.mp3'));
    expect((result['savedDownloads'] as List).length, 1);
    expect(result['exists'], false);
  });
}
