import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/main.dart';
import 'package:dmusic_app/models/search_preferences.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _SearchPaths extends PathProviderPlatform {
  _SearchPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Finder _chip(String label) => find.widgetWithText(ChoiceChip, label);

// Filesystem completions need both the real IO loop and the widget fake loop.
Future<void> _flushPreferences(WidgetTester tester) async {
  var completed = false;
  Object? failure;
  DatabaseService()
      .saveSearchPreferences(DatabaseService().searchPreferences)
      .then(
        (_) => completed = true,
        onError: (Object error) {
          failure = error;
          completed = true;
        },
      );
  for (var attempt = 0; !completed && attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(failure, isNull);
  expect(completed, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-search-widget-');
    PathProviderPlatform.instance = _SearchPaths(directory.path);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.dmusic.app/widget'),
      (_) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$id'),
            MockStreamHandler.inline(onListen: (_, _) {}),
          );
        }
        return null;
      },
    );
    await File('${directory.path}/dmusic_library.json').writeAsString(
      jsonEncode({
        'downloads': [],
        'favorites': [],
        'history': [],
        'playlists': [],
        'enabledSources': ['网易云'],
        'searchPreferences': {
          'platforms': ['QQ音乐'],
          'qualities': ['FLAC'],
          'sizeRanges': ['15-30MB'],
          'durations': ['1-6分钟'],
          'versions': ['排除Live'],
          'downloadStatuses': ['未下载'],
          'sortOrder': '时长最长',
          'artists': ['不应保存的歌手'],
        },
      }),
    );
    await DatabaseService().init();
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await directory.delete(recursive: true);
  });

  testWidgets('saved filters survive searches, clear, and unavailable results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SearchTab())),
        );
        await tester.enterText(find.byType(TextField), 'first');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        // The selected platform has no results, but remains available to uncheck.
        expect(_chip('QQ音乐'), findsOneWidget);
        expect(tester.widget<ChoiceChip>(_chip('QQ音乐')).selected, isTrue);
        expect(tester.widget<ChoiceChip>(_chip('无损FLAC')).selected, isTrue);
        expect(find.text('未找到符合当前筛选条件的歌曲'), findsOneWidget);
        expect(find.text('Long studio'), findsNothing);

        await tester.tap(find.text('更多筛选'));
        await tester.pumpAndSettle();
        for (final label in ['15-30MB', '1-6分钟', '排除Live', '未下载', '时长最长']) {
          expect(tester.widget<ChoiceChip>(_chip(label)).selected, isTrue);
        }
        // Unchecking the unavailable platform retains quality and other filters.
        await tester.tap(_chip('QQ音乐'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('无损FLAC')).selected, isTrue);
        expect(find.text('找到 2 首歌曲'), findsOneWidget);
        expect(find.text('Standard studio'), findsNothing);
        expect(find.text('Stage (Live)'), findsNothing);
        expect(
          tester.getTopLeft(find.text('Long studio')).dy,
          lessThan(tester.getTopLeft(find.text('Short studio')).dy),
        );

        await tester.tap(_chip('Artist A'));
        await tester.pumpAndSettle();
        expect(find.text('找到 1 首歌曲'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'second');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('Artist A')).selected, isFalse);
        expect(find.text('找到 2 首歌曲'), findsOneWidget);
        expect(tester.widget<ChoiceChip>(_chip('时长最长')).selected, isTrue);

        await tester.tap(_chip('仅看Live'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('排除Live')).selected, isFalse);
        expect(find.text('找到 1 首歌曲'), findsOneWidget);
        await tester.tap(_chip('排除Live'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('仅看Live')).selected, isFalse);

        await tester.tap(_chip('< 5MB'));
        await tester.tap(_chip('< 1分钟'));
        await tester.tap(_chip('已下载'));
        await tester.tap(_chip('体积最大'));
        await tester.pumpAndSettle();
        await _flushPreferences(tester);
        expect(DatabaseService().searchPreferences.sortOrder, '体积最大');
        expect(DatabaseService().searchPreferences.sizeRanges, {
          '< 5MB',
          '15-30MB',
        });
        expect(DatabaseService().searchPreferences.durations, {
          '< 1分钟',
          '1-6分钟',
        });
        expect(DatabaseService().searchPreferences.downloadStatuses, {
          '未下载',
          '已下载',
        });
        await tester.tap(_chip('时长最长'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.close_rounded).first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'third');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('无损FLAC')).selected, isTrue);
        expect(tester.widget<ChoiceChip>(_chip('时长最长')).selected, isTrue);
        expect(find.text('找到 2 首歌曲'), findsOneWidget);
        for (final label in [
          '< 5MB',
          '15-30MB',
          '< 1分钟',
          '1-6分钟',
          '未下载',
          '已下载',
          '排除Live',
        ]) {
          expect(tester.widget<ChoiceChip>(_chip(label)).selected, isTrue);
        }

        // Complete the serialized write and recreate the search page.
        await _flushPreferences(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SearchTab())),
        );
        await tester.enterText(find.byType(TextField), 'after restart');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('无损FLAC')).selected, isTrue);
        expect(find.text('找到 2 首歌曲'), findsOneWidget);
        await tester.tap(find.text('更多筛选'));
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_chip('时长最长')).selected, isTrue);
        for (final label in [
          '< 5MB',
          '15-30MB',
          '< 1分钟',
          '1-6分钟',
          '未下载',
          '已下载',
          '排除Live',
        ]) {
          expect(tester.widget<ChoiceChip>(_chip(label)).selected, isTrue);
        }
        await tester.tap(find.text('重置'));
        await tester.pumpAndSettle();
        expect(find.text('找到 4 首歌曲'), findsOneWidget);
        await _flushPreferences(tester);
        final saved = await tester.runAsync(
          () async => jsonDecode(
            await File('${directory.path}/dmusic_library.json').readAsString(),
          ),
        );
        expect(saved['searchPreferences'], SearchPreferences().toJson());
        expect(
          (saved['searchPreferences'] as Map).containsKey('artists'),
          isFalse,
        );
      },
      () => MockClient((request) async {
        if (request.url.path.contains('cloudsearch')) {
          return http.Response(
            jsonEncode({
              'result': {
                'songs': [
                  {
                    'id': 1,
                    'name': 'Short studio',
                    'ar': [
                      {'name': 'Artist A'},
                    ],
                    'al': {},
                    'dt': 210000,
                    'sq': {'size': 20000000},
                  },
                  {
                    'id': 2,
                    'name': 'Long studio',
                    'ar': [
                      {'name': 'Artist B'},
                    ],
                    'al': {},
                    'dt': 240000,
                    'sq': {'size': 20000000},
                  },
                  {
                    'id': 3,
                    'name': 'Stage (Live)',
                    'ar': [
                      {'name': 'Artist A'},
                    ],
                    'al': {},
                    'dt': 240000,
                    'sq': {'size': 20000000},
                  },
                  {
                    'id': 4,
                    'name': 'Standard studio',
                    'ar': [
                      {'name': 'Artist A'},
                    ],
                    'al': {},
                    'dt': 240000,
                    'l': {'br': 128000},
                  },
                ],
              },
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
