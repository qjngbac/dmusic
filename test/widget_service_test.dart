import 'dart:async';
import 'dart:io';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/widget_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.dmusic.app/widget');
  final updates = <Map<String, dynamic>>[];
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-widget-test-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateWidget') {
        updates.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
  });

  setUp(updates.clear);
  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  Song song(String id) => Song(
    id: id,
    name: id,
    artist: 'artist',
    album: 'album',
    source: 'test',
    coverUrl: 'https://covers.example/$id.jpg',
    durationSeconds: 120,
  );

  test(
    'publishes song state while its cover request is still pending',
    () async {
      final requested = Completer<void>();
      final cover = Completer<http.Response>();
      await http.runWithClient(
        () async {
          WidgetService().syncWidget(song: song('immediate'));
          await requested.future;
          try {
            expect(updates, isNotEmpty);
            expect(updates.last['title'], 'immediate');
            expect(updates.last['coverPath'], isNull);
          } finally {
            cover.complete(http.Response.bytes([1, 2, 3], 200));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        () => MockClient((_) {
          requested.complete();
          return cover.future;
        }),
      );
    },
  );

  test('late cover for an old song cannot replace the latest song', () async {
    final requestedA = Completer<void>();
    final requestedB = Completer<void>();
    final coverA = Completer<http.Response>();
    final coverB = Completer<http.Response>();
    await http.runWithClient(
      () async {
        WidgetService().syncWidget(song: song('A'));
        await requestedA.future;
        WidgetService().syncWidget(song: song('B'));
        await requestedB.future;
        coverB.complete(http.Response.bytes([4, 5, 6], 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(updates.last['title'], 'B');
        expect(updates.last['coverPath'], isNotNull);
        coverA.complete(http.Response.bytes([1, 2, 3], 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(updates.last['title'], 'B');
      },
      () => MockClient((request) {
        if (request.url.path == '/A.jpg') {
          requestedA.complete();
          return coverA.future;
        }
        requestedB.complete();
        return coverB.future;
      }),
    );
  });
}
