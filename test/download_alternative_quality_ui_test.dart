import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/main.dart';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final tasks = [
    for (final quality in ['128k', 'flac'])
      DownloadTask(
        song: Song(
          id: 'original-$quality',
          name: 'Original $quality',
          artist: 'Artist',
          album: '',
          source: 'QQ音乐',
        ),
        targetQuality: quality,
        preferLossless: quality == 'flac',
        status: '下载失败：请求超时',
      ),
  ];
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-alternative-ui-');
    PathProviderPlatform.instance = _Paths(directory.path);
    await File(
      '${directory.path}/dmusic_download_tasks.json',
    ).writeAsString(jsonEncode(tasks.map((t) => t.toJson()).toList()));
    await DownloadService().init();
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await directory.delete(recursive: true);
  });

  for (final quality in ['128k', 'flac']) {
    testWidgets('manual alternative preserves the requested $quality tier', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        for (final task in DownloadService().tasks.where(
          (t) => t.song.id.startsWith('candidate-'),
        )) {
          DownloadService().pauseTask(task);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 3; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      });
      await http.runWithClient(
        () async {
          await tester.pumpWidget(const MaterialApp(home: DownloadTab()));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Original $quality - Artist'));
          await tester.pumpAndSettle();
          expect(find.text('换源下载'), findsOneWidget);
          await tester.tap(find.text('换源下载'));
          await tester.pump();
          final replacement = DownloadService().tasks.singleWhere(
            (t) => t.song.id == 'candidate-$quality',
          );
          DownloadService().pauseTask(replacement);
          expect(replacement.targetQuality, quality);
          expect(replacement.preferLossless, quality == 'flac');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        },
        () => MockClient((request) async {
          if (request.url.path.contains('search_for_qq_cp')) {
            return http.Response(
              jsonEncode({
                'data': {
                  'song': {
                    'list': [
                      {
                        'songmid': 'candidate-$quality',
                        'songname': 'Candidate $quality',
                        'singer': [
                          {'name': 'Artist'},
                        ],
                        'interval': 180,
                        // Deliberately advertise the opposite tier to the original task.
                        if (quality == '128k') 'sizeflac': 20000000,
                        if (quality == 'flac') 'size320': 7000000,
                      },
                    ],
                  },
                },
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );
    });
  }
}
