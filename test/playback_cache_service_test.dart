import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/playback_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'audio_fixtures.dart';

void main() {
  late Directory directory;
  late PlaybackCacheService cache;
  late HttpServer upstream;
  late List<int> bytes;
  late int requests;
  late DateTime now;

  Song song(String id) => Song(
    id: id,
    name: 'Track',
    artist: 'Artist',
    album: '',
    source: 'Test',
    audioUrl: 'https://expired.example/signed?token=secret',
  );

  Future<List<int>> fetch(
    Uri uri, {
    String? range,
    String method = 'GET',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      if (range != null) request.headers.set('range', range);
      final response = await request.close();
      return await response.fold<List<int>>([], (a, b) => a..addAll(b));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> fill(String id) async {
    final source = await cache.createSource(
      song(id),
      'http://127.0.0.1:${upstream.port}/track',
    );
    expect(await fetch(source.uri), bytes);
    await source.release();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('playback_cache_test_');
    now = DateTime.utc(2026, 10, 13);
    cache = PlaybackCacheService(directory: directory, clock: () => now);
    bytes = mp3Fixture(bitrate: 256, frames: 100);
    requests = 0;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      requests++;
      request.response.headers.set('content-type', 'audio/mpeg');
      request.response.headers.set('accept-ranges', 'bytes');
      final range = request.headers.value('range');
      if (range != null) {
        final start = int.parse(range.split('=')[1].split('-')[0]);
        final endText = range.split('-')[1];
        final end = endText.isEmpty ? bytes.length - 1 : int.parse(endText);
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
      } else {
        request.response.contentLength = bytes.length;
        if (request.method != 'HEAD') request.response.add(bytes);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await cache.dispose();
    await upstream.close(force: true);
    await directory.delete(recursive: true);
  });

  test('one playback GET tees to inspected cache and reuses offline', () async {
    await fill('one');
    expect(requests, 1);
    await upstream.close(force: true);
    final hit = await cache.find(song('one'));
    expect(hit, isNotNull);
    expect(hit!.info.bitrateKbps, 256);
    expect(hit.song.audioUrl, isNull);
    expect(hit.song.localFilePath, isNull);
    expect(await hit.file.readAsBytes(), bytes);
    expect(requests, 1);
    final index = await File('${directory.path}/index.json').readAsString();
    expect(index, isNot(contains('expired.example')));
    expect(index, isNot(contains('127.0.0.1')));
    await hit.release();
  });

  test(
    'HEAD and partial Range preserve headers without a complete cache',
    () async {
      final source = await cache.createSource(
        song('range'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      final client = HttpClient();
      final head = await (await client.headUrl(source.uri)).close();
      expect(head.contentLength, bytes.length);
      expect(head.headers.contentType?.mimeType, 'audio/mpeg');
      await head.drain<void>();
      final request = await client.getUrl(source.uri);
      request.headers.set('range', 'bytes=100-199');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(
        response.headers.value('content-range'),
        'bytes 100-199/${bytes.length}',
      );
      expect(
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        bytes.sublist(100, 200),
      );
      client.close(force: true);
      await source.release();
      expect(await cache.find(song('range')), isNull);
    },
  );

  test(
    'full resource 206 is cacheable but 128 kbps never satisfies 256',
    () async {
      final source = await cache.createSource(
        song('fullrange'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      await fetch(source.uri, range: 'bytes=0-');
      await source.release();
      final full = await cache.find(song('fullrange'));
      expect(full, isNotNull);
      await full!.release();
      bytes = mp3Fixture(bitrate: 128, frames: 100);
      await fill('low');
      expect(await cache.find(song('low')), isNull);
      final low = await cache.find(song('low'), targetQuality: '128k');
      expect(low, isNotNull);
      await low!.release();
    },
  );

  test(
    'expired unpinned entries are removed and pinned files survive',
    () async {
      await fill('pinned');
      await fill('old');
      final hit = await cache.find(song('pinned'));
      now = now.add(const Duration(days: 8));
      await cache.cleanup();
      expect(await hit!.file.exists(), isTrue);
      expect(await cache.find(song('old')), isNull);
      await hit.release();
      await cache.cleanup();
      expect(await hit.file.exists(), isFalse);
    },
  );

  test(
    'find expires an entry after seven unused days without explicit cleanup',
    () async {
      await fill('idle');
      now = now.add(const Duration(days: 8));
      expect(await cache.find(song('idle')), isNull);
      expect(
        directory.listSync().where((f) => f.path.endsWith('.mp3')),
        isEmpty,
      );
    },
  );

  test(
    'source creation periodically cleans expired unrelated cache files',
    () async {
      await fill('unrelated');
      now = now.add(const Duration(days: 8));
      final source = await cache.createSource(
        song('new-stream'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      expect(
        directory.listSync().where((f) => f.path.endsWith('.mp3')),
        isEmpty,
      );
      await source.release();
    },
  );

  test(
    'invalidation blocks reuse immediately and defers pinned file deletion',
    () async {
      await fill('invalidated');
      final hit = await cache.find(song('invalidated'));
      final source = await cache.createSource(
        song('invalidated'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      await cache.invalidate(hit!.key);
      expect(await cache.find(song('invalidated')), isNull);
      expect(await hit.file.exists(), isTrue);
      final index =
          jsonDecode(await File('${directory.path}/index.json').readAsString())
              as Map;
      expect(index['entries'], isEmpty);
      await hit.release();
      expect(await hit.file.exists(), isTrue);
      await source.release();
      expect(await hit.file.exists(), isFalse);
    },
  );

  test('failed lookup index writes never leak a cache pin', () async {
    await fill('persist-failure');
    final hit = await cache.find(song('persist-failure'));
    await hit!.release();
    final index = File('${directory.path}/index.json');
    await index.delete();
    final blockedIndex = await Directory(index.path).create();
    await expectLater(
      cache.find(song('persist-failure')),
      throwsA(isA<FileSystemException>()),
    );
    await blockedIndex.delete();
    await cache.invalidate(hit.key);
    expect(await hit.file.exists(), isFalse);
  });

  test('missing and corrupt cached files are misses', () async {
    await fill('missing');
    final missing = await cache.find(song('missing'));
    await missing!.release();
    await missing.file.delete();
    expect(await cache.find(song('missing')), isNull);
    await fill('corrupt');
    final corrupt = await cache.find(song('corrupt'));
    await corrupt!.release();
    await corrupt.file.writeAsString('<html>denied</html>');
    expect(await cache.find(song('corrupt')), isNull);
  });

  test(
    'oversize resources still stream through without retaining parts',
    () async {
      await cache.dispose();
      cache = PlaybackCacheService(
        directory: directory,
        maxBytes: bytes.length - 1,
      );
      await fill('big');
      expect(await cache.find(song('big')), isNull);
      expect(
        directory.listSync().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test('quota pressure evicts LRU to 80 percent and respects pins', () async {
    await cache.dispose();
    cache = PlaybackCacheService(
      directory: directory,
      maxBytes: bytes.length * 3,
      clock: () => now,
    );
    await fill('a');
    now = now.add(const Duration(minutes: 1));
    await fill('b');
    now = now.add(const Duration(minutes: 1));
    await fill('c');
    final pin = await cache.find(song('b'));
    now = now.add(const Duration(minutes: 1));
    await fill('d');
    expect(await cache.find(song('a')), isNull);
    expect(await cache.find(song('c')), isNull);
    expect(await pin!.file.exists(), isTrue);
    final newest = await cache.find(song('d'));
    expect(newest, isNotNull);
    await newest!.release();
    await pin.release();
  });

  test('startup removes orphan parts and ignores unsafe index paths', () async {
    await fill('unsafe');
    final index =
        jsonDecode(await File('${directory.path}/index.json').readAsString())
            as Map<String, dynamic>;
    await cache.dispose();
    final outside = await Directory.systemTemp.createTemp('cache_outside_');
    try {
      final formal = await File(
        '${outside.path}/formal.mp3',
      ).writeAsBytes(bytes);
      await File(
        '${directory.path}/${'a' * 64}_${'b' * 32}.part',
      ).writeAsBytes([1, 2]);
      (index['entries'] as List).first['file'] = formal.path;
      await File(
        '${directory.path}/index.json',
      ).writeAsString(jsonEncode(index));
      cache = PlaybackCacheService(directory: directory);
      await cache.cleanup();
      expect(await formal.exists(), isTrue);
      expect(
        directory.listSync().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    } finally {
      await outside.delete(recursive: true);
    }
  });

  test('default quota is exactly one GiB', () {
    final defaults = PlaybackCacheService(directory: directory);
    expect(defaults.maxBytes, 1024 * 1024 * 1024);
  });

  test(
    'concurrent native requests never mix or replace an active entry',
    () async {
      final source = await cache.createSource(
        song('concurrent'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      final results = await Future.wait([fetch(source.uri), fetch(source.uri)]);
      expect(results, everyElement(bytes));
      await source.release();
      final hit = await cache.find(song('concurrent'));
      expect(hit, isNotNull);
      expect(await hit!.file.readAsBytes(), bytes);
      expect(
        directory.listSync().where((f) => f.path.endsWith('.mp3')).length,
        1,
      );
      expect(
        directory.listSync().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
      await hit.release();
    },
  );

  test(
    'release cancels a stalled transfer and removes its partial file',
    () async {
      await upstream.close(force: true);
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sent = Completer<void>();
      final finish = Completer<void>();
      upstream.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 2000));
        await request.response.flush();
        sent.complete();
        await finish.future;
        try {
          await request.response.close();
        } catch (_) {}
      });
      final source = await cache.createSource(
        song('cancelled'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      final fetching = fetch(source.uri).then((_) {}, onError: (Object _) {});
      await sent.future;
      await source.release().timeout(const Duration(seconds: 2));
      finish.complete();
      await fetching;
      expect(await cache.find(song('cancelled')), isNull);
      expect(
        directory.listSync().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test('each source captures its own HTTP client Zone', () async {
    final highBytes = mp3Fixture(bitrate: 320, frames: 100);
    final first = await http.runWithClient(
      () => cache.createSource(song('zone1'), 'https://first.example/audio'),
      () => MockClient((request) async {
        expect(request.url.host, 'first.example');
        return http.Response.bytes(bytes, 200);
      }),
    );
    final second = await http.runWithClient(
      () => cache.createSource(song('zone2'), 'https://second.example/audio'),
      () => MockClient((request) async {
        expect(request.url.host, 'second.example');
        return http.Response.bytes(highBytes, 200);
      }),
    );
    expect(await fetch(second.uri), highBytes);
    expect(await fetch(first.uri), bytes);
    await first.release();
    await second.release();
    final firstHit = await cache.find(song('zone1'));
    final secondHit = await cache.find(song('zone2'));
    expect(firstHit!.info.bitrateKbps, 256);
    expect(secondHit!.info.bitrateKbps, 320);
    await firstHit.release();
    await secondHit.release();
  });

  test(
    'download lookup selects MP3 without a lossless cache shadowing it',
    () async {
      bytes = flacFixture();
      await fill('download-quality');
      bytes = mp3Fixture(bitrate: 128, frames: 100);
      await fill('download-quality');
      final playback = await cache.find(
        song('download-quality'),
        targetQuality: '128k',
      );
      expect(playback!.info.isLossless, isTrue);
      await playback.release();
      final download = await cache.find(
        song('download-quality'),
        targetQuality: '128k',
        forDownload: true,
      );
      expect(download!.info.format, 'MP3');
      expect(download.info.bitrateKbps, 128);
      await download.release();
    },
  );

  test('cache survives restart without retaining upstream URL', () async {
    await fill('restart');
    await cache.dispose();
    cache = PlaybackCacheService(directory: directory, clock: () => now);
    final restored = await cache.find(song('restart'));
    expect(restored, isNotNull);
    expect(await restored!.file.readAsBytes(), bytes);
    await restored.release();
  });

  test('256 selection prefers measured 256 over 320 and lossless', () async {
    bytes = mp3Fixture(bitrate: 320, frames: 100);
    await fill('quality');
    bytes = wavFixture();
    await fill('quality');
    final high = await cache.find(song('quality'));
    expect(high!.info.bitrateKbps, 320);
    await high.release();
    bytes = mp3Fixture(bitrate: 256, frames: 100);
    await fill('quality');
    final medium = await cache.find(song('quality'));
    expect(medium!.info.bitrateKbps, 256);
    await medium.release();
  });

  test(
    'invalid audio and wrong recording duration never enter cache',
    () async {
      bytes = '<html>access denied</html>'.codeUnits;
      await fill('html');
      expect(await cache.find(song('html'), targetQuality: ''), isNull);
      bytes = mp3Fixture(bitrate: 256, frames: 100);
      final source = await cache.createSource(
        song('short').copyWith(durationSeconds: 180),
        'http://127.0.0.1:${upstream.port}/track',
      );
      expect(await fetch(source.uri), bytes);
      await source.release();
      expect(await cache.find(song('short'), targetQuality: ''), isNull);
    },
  );

  test(
    'OS purging the entire temporary cache directory is a cache miss',
    () async {
      await fill('purged');
      await directory.delete(recursive: true);
      expect(await cache.find(song('purged')), isNull);
      await fill('new');
      final hit = await cache.find(song('new'));
      expect(hit, isNotNull);
      await hit!.release();
    },
  );

  test(
    'proxy retains CDN Referer and browser User-Agent with identity encoding',
    () async {
      final source = await http.runWithClient(
        () => cache.createSource(
          song('referer'),
          'https://upos-sz-mirrorcos.bilivideo.com/audio',
        ),
        () => MockClient((request) async {
          expect(request.headers['referer'], 'https://www.bilibili.com/');
          expect(request.headers['user-agent'], contains('Mozilla'));
          expect(request.headers['accept-encoding'], 'identity');
          return http.Response.bytes(bytes, 200);
        }),
      );
      expect(await fetch(source.uri), bytes);
      await source.release();
    },
  );

  test(
    'native disconnect and source release clean an incomplete cache',
    () async {
      await upstream.close(force: true);
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finish = Completer<void>();
      upstream.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 2000));
        await request.response.flush();
        await finish.future;
        try {
          request.response.add(bytes.sublist(2000));
          await request.response.close();
        } catch (_) {}
      });
      final source = await cache.createSource(
        song('disconnect'),
        'http://127.0.0.1:${upstream.port}/track',
      );
      final client = HttpClient();
      final response = await (await client.getUrl(
        source.uri,
      )).close().timeout(const Duration(seconds: 2));
      final subscription = response.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      client.close(force: true);
      await subscription.cancel();
      await source.release().timeout(const Duration(seconds: 2));
      finish.complete();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (directory.listSync().any((f) => f.path.endsWith('.part')) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        directory.listSync().where((f) => f.path.endsWith('.part')),
        isEmpty,
      );
      expect(await cache.find(song('disconnect')), isNull);
    },
  );
}
