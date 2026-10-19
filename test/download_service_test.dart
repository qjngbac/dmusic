import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:dmusic_app/services/playback_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'audio_fixtures.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => '$path/cache';
  @override
  Future<String?> getExternalStoragePath() async => path;
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [path];
}

class _InterruptedClient extends http.BaseClient {
  _InterruptedClient(this.inner);
  final http.Client inner;
  Stream<List<int>> _brokenBody() async* {
    yield [255, 251, 224, 0];
    throw http.ClientException('connection lost');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host == 'audio.test' &&
        !request.headers.containsKey('Range') &&
        !request.headers.containsKey('range')) {
      return http.StreamedResponse(
        _brokenBody(),
        200,
        contentLength: 7000000,
        headers: {'content-type': 'audio/mpeg'},
      );
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

final class _RenameOverrides extends IOOverrides {
  bool failWrites = false;
  final renamed = Completer<void>();
  final release = Completer<void>();
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.part') ? _GatedFile(file, this) : file;
  }
}

class _GatedFile implements File {
  _GatedFile(this.file, this.gate);
  final File file;
  final _RenameOverrides gate;
  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      file.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<int> length() => file.length();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => gate.failWrites
      ? File('${file.path}/blocked').openWrite(mode: mode, encoding: encoding)
      : file.openWrite(mode: mode, encoding: encoding);
  @override
  Future<File> rename(String newPath) async {
    final result = await file.rename(newPath);
    gate.renamed.complete();
    await gate.release.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-download-test-');
    PathProviderPlatform.instance = _Paths(directory.path);
    await DownloadService().init();
  });
  tearDownAll(() async {
    await PlaybackCacheService.instance.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await directory.delete(recursive: true);
  });

  Song song(String id, {String quality = '128k 标准', bool lossless = false}) =>
      Song(
        id: id,
        name: 'Track $id',
        artist: 'Artist',
        album: '',
        source: '酷我音乐',
        quality: quality,
        isLossless: lossless,
        durationSeconds: 180,
      );
  MockClient provider(List<int> bytes, {bool truncated = false}) => MockClient((
    request,
  ) async {
    if (request.url.host == 'audio.test') {
      final ranged =
          request.headers.containsKey('Range') ||
          request.headers.containsKey('range');
      if (!ranged && truncated) throw http.ClientException('stream cut off');
      return http.Response.bytes(
        bytes,
        200,
        headers: {
          'content-type': 'audio/mpeg',
          'content-length': '${bytes.length}',
        },
      );
    }
    if (request.url.host == 'musicapi.haitangw.net') {
      return http.Response(
        jsonEncode({
          'data': {'url': 'https://audio.test/song.mp3'},
        }),
        200,
      );
    }
    if (request.url.host == 'antiserver.kuwo.cn') {
      return http.Response('https://audio.test/song.mp3', 200);
    }
    return http.Response('{}', 200);
  });

  Future<void> warmCache(Song track, List<int> bytes) async {
    final source = await http.runWithClient(
      () => PlaybackCacheService.instance.createSource(track, 'https://warm.test/audio'),
      () => MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(source.uri)).close();
      await response.drain<void>();
    } finally {
      client.close(force: true);
      await source.release();
    }
  }

  test('an early output open error is reported without an unhandled future', () async {
    final gate = _RenameOverrides()..failWrites = true;
    final original = song('early-output-error');
    final bytes = mp3Fixture(bitrate: 320, frames: 6891);
    await IOOverrides.runWithIOOverrides(() => http.runWithClient(
      () => DownloadService().startDownload(original, targetQuality: '320k'),
      () => MockClient((request) async {
        final ranged = request.headers.keys.any((key) => key.toLowerCase() == 'range');
        if (request.url.host == 'audio.test' && !ranged) {
          // The output open fails while response headers are still in flight.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return provider(bytes).get(request.url, headers: request.headers);
      }),
    ), gate);
    final task = DownloadService().tasks.firstWhere((task) => task.song.key == original.key);
    expect(task.status, contains('文件保存失败'));
    expect(task.savedPath, isNull);
    expect(DatabaseService().downloads.where((item) => item.key == original.key), isEmpty);
  });

  test('download reuses warmed playback cache and survives cache eviction', () async {
    final original = song('cache-copy')..lyric = '[00:00.00]Cached lyrics';
    final bytes = mp3Fixture(bitrate: 320, frames: 6891);
    await warmCache(original, bytes);
    var audioRequests = 0;
    await http.runWithClient(
      () => DownloadService().startDownload(original, targetQuality: '320k'),
      () => MockClient((request) async {
        // A cache hit needs neither audio resolution nor an audio transfer.
        audioRequests++;
        return http.Response('{}', 503);
      }),
    );
    final task = DownloadService().tasks.firstWhere((t) => t.song.key == original.key);
    expect(task.status, '已完成');
    expect(audioRequests, 0);
    final cached = await PlaybackCacheService.instance.find(original, targetQuality: '320k');
    expect(cached, isNotNull);
    expect(task.savedPath, isNot(cached!.file.path));
    expect(DatabaseService().downloads.singleWhere((s) => s.key == original.key).localFilePath, task.savedPath);
    final cacheFile = cached.file;
    final cacheKey = cached.key;
    await cached.release();
    await PlaybackCacheService.instance.invalidate(cacheKey);
    expect(await cacheFile.exists(), isFalse);
    expect(await File(task.savedPath!).readAsBytes(), bytes);
    expect(await File(task.song.lrcPath!).readAsString(), '[00:00.00]Cached lyrics');
  });

  test('warmed 128k playback cache cannot satisfy a FLAC download', () async {
    final original = song('cache-low');
    await warmCache(original, mp3Fixture(frames: 6891));
    await http.runWithClient(
      () => DownloadService().startDownload(original, targetQuality: 'flac'),
      () => MockClient((_) async => http.Response('{}', 503)),
    );
    final task = DownloadService().tasks.firstWhere((t) => t.song.key == original.key);
    expect(task.status, isNot('已完成'));
    expect(task.savedPath, isNull);
    expect(DatabaseService().downloads.where((s) => s.key == original.key), isEmpty);
    final cached = await PlaybackCacheService.instance.find(original, targetQuality: '128k');
    expect(cached, isNotNull);
    await cached!.release();
  });

  test('cache index failure falls back to a normal independent download', () async {
    final original = song('cache-index-error');
    final bytes = mp3Fixture(bitrate: 320, frames: 6891);
    await warmCache(original, bytes);
    final cached = await PlaybackCacheService.instance.find(original, targetQuality: '320k');
    final cacheFile = cached!.file;
    final cacheKey = cached.key;
    await cached.release();
    final index = File('${cacheFile.parent.path}/index.json');
    final savedIndex = await index.rename('${index.path}.held');
    final blockedIndex = await Directory(index.path).create();
    try {
      await http.runWithClient(
        () => DownloadService().startDownload(original, targetQuality: '320k'),
        () => provider(bytes),
      );
      final task = DownloadService().tasks.firstWhere((t) => t.song.key == original.key);
      expect(task.status, '已完成');
      expect(task.savedPath, isNot(cacheFile.path));
      expect(await File(task.savedPath!).readAsBytes(), bytes);
    } finally {
      await blockedIndex.delete();
      await savedIndex.rename(index.path);
    }
    await PlaybackCacheService.instance.invalidate(cacheKey);
    expect(await cacheFile.exists(), isFalse);
  });

  test('cancelled cache download releases its lease and preserves an old download', () async {
    final original = song('cache-cancel');
    final bytes = mp3Fixture(bitrate: 320, frames: 6891);
    final oldFile = await File('${directory.path}/old-cache-cancel.mp3').writeAsBytes(bytes);
    await DatabaseService().addDownload(original.copyWith(localFilePath: oldFile.path), oldFile);
    await warmCache(original, bytes);
    final cached = await PlaybackCacheService.instance.find(original, targetQuality: '320k');
    final cacheKey = cached!.key;
    final cacheFile = cached.file;
    await cached.release();
    final lyricStarted = Completer<void>();
    final finishLyric = Completer<void>();
    final work = http.runWithClient(
      () => DownloadService().startDownload(original, targetQuality: '320k'),
      () => MockClient((request) async {
        if (request.url.path.contains('songinfoandlrc')) {
          lyricStarted.complete();
          await finishLyric.future;
        }
        return http.Response('{}', 503);
      }),
    );
    await lyricStarted.future.timeout(const Duration(seconds: 10));
    final task = DownloadService().tasks.firstWhere((t) => t.song.key == original.key);
    DownloadService().cancelTask(task);
    finishLyric.complete();
    await work;
    expect(task.status, '已取消');
    expect(task.savedPath, isNull);
    expect(await cacheFile.readAsBytes(), bytes);
    expect(await oldFile.readAsBytes(), bytes);
    expect(DatabaseService().downloads.singleWhere((s) => s.key == original.key).localFilePath, oldFile.path);
    expect(directory.listSync().whereType<File>().where((f) =>
        f.path.contains('Track cache-cancel') && !f.path.endsWith('.json')), isEmpty);
    await PlaybackCacheService.instance.invalidate(cacheKey);
    expect(await cacheFile.exists(), isFalse);
  });

  test(
    'bool-only 320k request never derives 128k from search metadata',
    () async {
      final bytes = mp3Fixture(bitrate: 320, frames: 6891);
      final original = song('320');
      await http.runWithClient(
        () => DownloadService().startDownload(original, preferLossless: false),
        () => provider(bytes),
      );
      final task = DownloadService().tasks.firstWhere(
        (task) => task.song.key == original.key,
      );
      expect(task.targetQuality, '320k');
      expect(task.status, '已完成');
      expect(task.song.quality, '320k 极高');
    },
  );

  test('0.9MB preview is rejected for a three minute song', () async {
    final bytes = mp3Fixture(
      frames: 2300,
    ); // about 60 seconds, over the old 900KB cutoff.
    final original = song('preview');
    await http.runWithClient(
      () => DownloadService().startDownload(original, targetQuality: '128k'),
      () => provider(bytes),
    );
    final task = DownloadService().tasks.firstWhere(
      (task) => task.song.key == original.key,
    );
    expect(task.status, isNot('已完成'));
    expect(task.savedPath, isNull);
  });

  for (final failure in ['timeout', 'http', 'quality']) {
    test('download failure retains the observed $failure reason', () async {
      final original = song('reason-$failure');
      final good = mp3Fixture(bitrate: 320, frames: 6891);
      await http.runWithClient(
        () => DownloadService().startDownload(original, targetQuality: '320k'),
        () => MockClient((request) {
          final ranged = request.headers.keys.any((key) => key.toLowerCase() == 'range');
          if (request.url.host == 'audio.test' && !ranged) {
            if (failure == 'timeout') throw TimeoutException('test timeout');
            if (failure == 'http') return Future.value(http.Response('{}', 503));
            return Future.value(http.Response.bytes(mp3Fixture(frames: 6891), 200));
          }
          return provider(good).get(request.url, headers: request.headers);
        }),
      );
      final task = DownloadService().tasks.firstWhere((task) => task.song.key == original.key);
      expect(task.status, contains(switch (failure) {
        'timeout' => '超时',
        'http' => 'HTTP 503',
        _ => '实际128k',
      }));
      expect(task.status, isNot(contains('版权')));
      expect(task.savedPath, isNull);
    });
  }

  test(
    'FLAC request fails honestly rather than downloading a 128k cache',
    () async {
      final original = song('flac')
        ..audioUrl = 'https://audio.test/old.mp3'
        ..audioUrlTimestamp = DateTime.now().millisecondsSinceEpoch;
      await http.runWithClient(
        () => DownloadService().startDownload(original, preferLossless: true),
        () => provider(mp3Fixture(frames: 6891)),
      );
      final task = DownloadService().tasks.firstWhere(
        (task) => task.song.key == original.key,
      );
      expect(task.targetQuality, 'flac');
      expect(task.status, isNot('已完成'));
    },
  );

  test(
    'cancel during resolving prevents any later download and registration',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      var fileRequests = 0;
      final bytes = mp3Fixture(bitrate: 320, frames: 6891);
      final original = song('cancel');
      final client = MockClient((request) async {
        if (request.url.host == 'musicapi.haitangw.net') {
          if (!started.isCompleted) started.complete();
          await gate.future;
          return http.Response(
            jsonEncode({
              'data': {'url': 'https://audio.test/cancel.mp3'},
            }),
            200,
          );
        }
        if (request.url.host == 'audio.test') {
          if (!request.headers.containsKey('Range') &&
              !request.headers.containsKey('range')) {
            fileRequests++;
          }
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }
        return http.Response('{}', 200);
      });
      final future = http.runWithClient(
        () => DownloadService().startDownload(original, targetQuality: '320k'),
        () => client,
      );
      await started.future;
      final task = DownloadService().tasks.firstWhere(
        (task) => task.song.key == original.key,
      );
      DownloadService().cancelTask(task);
      gate.complete();
      await future;
      expect(task.status, '已取消');
      expect(fileRequests, 0);
      expect(task.savedPath, isNull);
    },
  );

  test(
    'failed replacement leaves an existing complete file unchanged',
    () async {
      final original = song('safe');
      final complete = await File(
        '${directory.path}/Artist - Track safe.mp3',
      ).writeAsBytes([1, 2, 3, 4]);
      await http.runWithClient(
        () => DownloadService().startDownload(original, targetQuality: '320k'),
        () => _InterruptedClient(
          provider(mp3Fixture(bitrate: 320, frames: 6891)),
        ),
      );
      expect(await complete.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('batch resolves at most three downloads concurrently', () async {
    final gate = Completer<void>();
    final firstThreeStarted = Completer<void>();
    var started = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'musicapi.haitangw.net') {
        started++;
        if (started == 3) firstThreeStarted.complete();
        await gate.future;
      }
      return http.Response('{}', 200);
    });
    final work = http.runWithClient(
      () => Future.wait([
        for (var i = 0; i < 7; i++)
          DownloadService().startDownload(
            song('batch$i'),
            targetQuality: '320k',
          ),
      ]),
      () => client,
    );
    late int beforeRelease;
    try {
      await firstThreeStarted.future.timeout(const Duration(seconds: 10));
      beforeRelease = started;
    } finally {
      gate.complete();
      await work;
    }
    expect(beforeRelease, 3);
  });

  test(
    'cancel during final rename removes only the new unpublished audio',
    () async {
      final gate = _RenameOverrides();
      final original = song('rename-cancel');
      final before = directory
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .toSet();
      await IOOverrides.runWithIOOverrides(() async {
        final work = http.runWithClient(
          () =>
              DownloadService().startDownload(original, targetQuality: '320k'),
          () => provider(mp3Fixture(bitrate: 320, frames: 6891)),
        );
        await gate.renamed.future;
        final task = DownloadService().tasks.firstWhere(
          (t) => t.song.key == original.key,
        );
        DownloadService().cancelTask(task);
        gate.release.complete();
        await work;
        expect(task.status, '已取消');
        expect(task.savedPath, isNull);
      }, gate);
      final newAudio = directory
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                !before.contains(f.path) &&
                (f.path.endsWith('.mp3') ||
                    f.path.endsWith('.part') ||
                    f.path.endsWith('.lrc')),
          )
          .toList();
      expect(newAudio, isEmpty);
    },
  );
}
