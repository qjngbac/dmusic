import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/main.dart';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _DownloadPaths extends PathProviderPlatform {
  _DownloadPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadTask task;
  const title = '这是一首需要显示完整名称的很长歌曲（现场特别纪念版） - 演唱者与合作歌手';

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-download-ui-');
    PathProviderPlatform.instance = _DownloadPaths(directory.path);
    final initial = DownloadTask(
      song: Song(
        id: 'failed-song',
        name: '这是一首需要显示完整名称的很长歌曲（现场特别纪念版）',
        artist: '演唱者与合作歌手',
        album: '',
        source: 'QQ音乐',
        quality: 'FLAC 24bit/192kHz',
      ),
      status: '下载失败：请求超时，请稍后重试',
    );
    await File(
      '${directory.path}/dmusic_download_tasks.json',
    ).writeAsString(jsonEncode([initial.toJson()]));
    await DownloadService().init();
    task = DownloadService().tasks.single;
  });

  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  Future<void> showTask(WidgetTester tester, String status) async {
    task.status = status;
    tester.view.physicalSize = const Size(320, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const DownloadTab(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('failed task wraps the complete song and separates its reason', (
    tester,
  ) async {
    const reason = '下载失败：已有文件音质不符或为试听片段 (点击恢复)';
    await showTask(tester, reason);

    final song = find.text(title);
    final paragraph = tester.renderObject<RenderParagraph>(song);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.size.height, greaterThan(54));
    expect(find.text('待检查'), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(reason)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(song).dy),
    );
    expect(find.textContaining('源站版权受限'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.longPress(song);
    await tester.pumpAndSettle();
    expect(find.text(reason), findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(song).didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('local missing file remains in the failed filter', (
    tester,
  ) async {
    const reason = '本地文件缺失或暂不可访问 (点击恢复)';
    await showTask(tester, reason);
    final filter = find.widgetWithText(ChoiceChip, '失败/受限 (1)');
    expect(filter, findsOneWidget);
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(find.text('待检查'), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(find.textContaining('源站版权受限'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local issue explains recovery choices before any download', (
    tester,
  ) async {
    const reason = '本地校验失败：无法识别音频（文件已保留）';
    await http.runWithClient(() async {
      await showTask(tester, reason);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(reason), findsNWidgets(2));
      expect(find.widgetWithText(TextButton, '重试下载'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '全网换源'), findsOneWidget);
      expect(task.status, reason);
      expect(find.text('全网智能换源推荐'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, '暂不处理'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(task.status, reason);
    }, () => MockClient((_) async => http.Response('{}', 200)));
  });

  testWidgets(
    'alternative search never invents source restrictions or payment',
    (tester) async {
      await http.runWithClient(() async {
        await showTask(tester, '下载失败：请求超时，请稍后重试');
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.text('全网智能换源推荐'), findsOneWidget);
        for (final misleading in ['受限', '付费', '独家']) {
          expect(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.textContaining(misleading),
            ),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
      }, () => MockClient((_) async => http.Response('{}', 200)));
    },
  );

  for (final reason in [
    '本地校验失败：无法识别音频（文件已保留）',
    '本地校验失败：时长不符（文件已保留）',
    '下载失败：请求超时，请稍后重试',
    '版权限制：该歌曲暂不可下载',
  ]) {
    testWidgets('failure card keeps the actual reason: $reason', (
      tester,
    ) async {
      await showTask(tester, reason);
      expect(find.text(reason), findsOneWidget);
      expect(find.textContaining('全网换源'), findsOneWidget);
      if (!reason.contains('版权')) {
        expect(find.textContaining('版权'), findsNothing);
      }
      expect(
        tester
            .renderObject<RenderParagraph>(find.text(title))
            .didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
