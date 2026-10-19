import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:dmusic_app/services/player_service.dart';
import 'package:dmusic_app/views/library_tab.dart';
import 'package:dmusic_app/views/player_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audio_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late PlayerService player;
  late Song downloaded;
  final online = Song(
    id: 'online',
    name: 'Online song',
    artist: 'Artist',
    album: '',
    source: 'QQ音乐',
    quality: '320k 极高',
    lyric: '[00:00.00]test',
  );

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-ui-test-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
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
    final localFile = await File(
      '${directory.path}/download.mp3',
    ).writeAsBytes(mp3Fixture(bitrate: 320, frames: 2000));
    downloaded = Song(
      id: 'downloaded',
      name: 'Downloaded song',
      artist: 'Artist',
      album: '',
      source: 'QQ音乐',
      quality: '320k 极高',
      localFilePath: localFile.path,
      lyric: '[00:00.00]test',
    );
    await File('${directory.path}/dmusic_library.json').writeAsString(
      jsonEncode({
        'downloads': [downloaded.toJson()],
        'favorites': [],
        'history': [],
        'searchHistory': [],
        'playlists': [],
        'enabledSources': ['QQ音乐'],
      }),
    );
    final db = DatabaseService();
    await db.init();
    final playlist = await db.createPlaylist('UI playlist');
    await db.addSongToPlaylist(playlist.id, online);
    await db.addSongToPlaylist(
      playlist.id,
      downloaded.copyWith(localFilePath: null, fileSizeBytes: 0, size: ''),
    );
    player = PlayerService();
    await Future<void>.delayed(Duration.zero);
  });

  tearDownAll(() async {
    await player.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await directory.delete(recursive: true);
  });

  Future<void> restore(WidgetTester tester, Song song) async {
    await tester.runAsync(() async {
      await File(
        '${directory.path}/dmusic_playback_state.json',
      ).writeAsString(jsonEncode({'song': song.toJson()}));
      await player.restorePlaybackState();
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlayerBottomSheet())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(song.quality));
    await tester.pumpAndSettle();
  }

  for (final desired in ['256k', '256', '256k 高品']) {
    final actual = desired == '256' ? 'MP3 320kbps' : 'FLAC 16bit/44.1kHz';
    testWidgets(
      'quality menu selects desired $desired when stream is $actual',
      (tester) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final song = online.copyWith(quality: actual, audioUrlQuality: desired);
        await restore(tester, song);
        final selected = find.ancestor(
          of: find.text('256k 高品'),
          matching: find.byType(ListTile),
        );
        expect(selected, findsOneWidget);
        expect(
          find.descendant(
            of: selected,
            matching: find.byIcon(Icons.check_circle_rounded),
          ),
          findsOneWidget,
        );
        expect(find.text(actual), findsOneWidget);
        await tester.tap(selected);
        await tester.pumpAndSettle();
        expect(find.text('选择音频解码规格'), findsNothing);
        expect(player.currentSong?.quality, actual);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('quality menu uses actual tier without a requested quality', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await restore(
      tester,
      online.copyWith(quality: 'MP3 320kbps', audioUrlQuality: null),
    );
    final selected = find.ancestor(
      of: find.text('320k 极高'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(
        of: selected,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('player download opens all three choices before creating a task', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() {
      for (final task in DownloadService().tasks) {
        DownloadService().pauseTask(task);
      }
    });
    await restore(tester, online);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    final before = DownloadService().tasks.length;
    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('FLAC 无损母带音质'), findsOneWidget);
    expect(find.text('320k 极高标准音质'), findsOneWidget);
    expect(find.text('128k 标准流畅音质'), findsOneWidget);
    expect(DownloadService().tasks.length, before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'playlist matches database download and shows actual size without a local path',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = DatabaseService();
      expect(
        db.playlists.single.songs
            .singleWhere((s) => s.key == downloaded.key)
            .localFilePath,
        isNull,
      );
      final savedBytes = db.downloads.single.fileSizeBytes;
      addTearDown(() => db.downloads.single.fileSizeBytes = savedBytes);
      // Old metadata must not override the physical file's 2,088,000 bytes.
      db.downloads.single.fileSizeBytes = 99 * 1024 * 1024;
      await tester.pumpWidget(const MaterialApp(home: LibraryTab()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌单合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UI playlist'));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Downloaded song'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: row, matching: find.text('2.0MB')),
        findsOneWidget,
      );
      final action = find.descendant(
        of: row,
        matching: find.byTooltip('已下载，点击查看下载选项'),
      );
      expect(action, findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: action,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
      );
      expect(icon.color, const Color(0xFF10B981));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'playlist downloaded entry keeps the quality upgrade sheet available',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = DatabaseService();
      final playlistSong = db.playlists.single.songs.singleWhere(
        (s) => s.key == downloaded.key,
      );
      final savedQuality = playlistSong.quality;
      playlistSong.quality = 'FLAC 无损';
      addTearDown(() => playlistSong.quality = savedQuality);
      await tester.pumpWidget(const MaterialApp(home: LibraryTab()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌单合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UI playlist'));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Downloaded song'),
        matching: find.byType(ListTile),
      );
      final action = find.descendant(
        of: row,
        matching: find.byTooltip('已下载，可升级音质'),
      );
      expect(
        find.descendant(of: row, matching: find.text('2.0MB')),
        findsOneWidget,
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('检测到线上更高品质音质'), findsOneWidget);
      expect(find.text('升级下载此版'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('Downloaded song'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'playlist updates downloaded state from database stream and cache stays online',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = DatabaseService();
      // Cached playback keeps localFilePath empty, even with known bytes.
      final cached = online.copyWith(
        id: 'cached',
        name: 'Cached song',
        audioUrl: 'http://127.0.0.1:12345/cache/cached',
        fileSizeBytes: 3 * 1024 * 1024,
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          await db.deleteDownload(online.key);
          await db.removeSongFromPlaylist(db.playlists.single.id, cached.key);
        });
      });
      await tester.runAsync(
        () => db.addSongToPlaylist(db.playlists.single.id, cached),
      );
      await tester.pumpWidget(const MaterialApp(home: LibraryTab()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌单合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UI playlist'));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Online song'),
        matching: find.byType(ListTile),
      );
      final cachedRow = find.ancestor(
        of: find.text('Cached song'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: row, matching: find.byTooltip('下载')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('预估9.4MB')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cachedRow, matching: find.byTooltip('下载')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cachedRow,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: cachedRow, matching: find.text('预估3.0MB')),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final file = await File(
          '${directory.path}/online.mp3',
        ).writeAsBytes(mp3Fixture(bitrate: 320, frames: 2000));
        await db.addDownload(online, file);
      });
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.text('2.0MB')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.byTooltip('已下载，点击查看下载选项')),
        findsOneWidget,
      );
      await tester.runAsync(() => db.deleteDownload(online.key));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row, matching: find.byTooltip('下载')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => db.removeSongFromPlaylist(db.playlists.single.id, cached.key),
      );
    },
  );

  testWidgets(
    'playlist download sheet closes back to playlist with three tiers',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: LibraryTab()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌单合集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('UI playlist'));
      await tester.pumpAndSettle();
      final songRow = find.ancestor(
        of: find.text('Online song'),
        matching: find.byType(ListTile),
      );
      final download = find.descendant(
        of: songRow,
        matching: find.byTooltip('下载'),
      );
      expect(download, findsOneWidget);
      final queueBefore = player.playlist.map((s) => s.key).toList();
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(find.text('FLAC 无损母带音质'), findsOneWidget);
      expect(find.text('320k 极高标准音质'), findsOneWidget);
      expect(find.text('128k 标准流畅音质'), findsOneWidget);
      expect(find.text('256k 高品'), findsNothing);
      expect(player.playlist.map((s) => s.key), queueBefore);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Online song'), findsOneWidget);
      expect(find.byTooltip('移出合集 (保留在全部歌曲)'), findsNWidgets(2));
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()),
      );
      final downloadedRow = find.ancestor(
        of: find.text('Downloaded song'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: downloadedRow,
          matching: find.byTooltip('已下载，点击查看下载选项'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地曲库已存在此歌曲'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Online song'), findsOneWidget);
      await tester.longPress(find.text('Online song'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('下载'), findsNothing);
      expect(find.byTooltip('移出合集 (保留在全部歌曲)'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
