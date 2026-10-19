import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dmusic_app/models/search_preferences.dart';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _PreferencePaths extends PathProviderPlatform {
  _PreferencePaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Map<String, dynamic> _library({Object? preferences}) => {
  'downloads': [],
  'favorites': [
    Song(
      id: 'saved',
      name: 'Favorite',
      artist: 'Artist',
      album: '',
      source: '网易云',
    ).toJson(),
  ],
  'history': [],
  'playlists': [],
  'searchHistory': ['earlier search'],
  'enabledSources': ['网易云'],
  'searchPreferences': ?preferences,
};

Future<Map<String, dynamic>> _freshDatabase(
  Map<String, dynamic> seed,
  Future<Map<String, dynamic>> Function(DatabaseService, File) action,
) => Isolate.run(() async {
  final directory = await Directory.systemTemp.createTemp(
    'dmusic-preferences-',
  );
  PathProviderPlatform.instance = _PreferencePaths(directory.path);
  final file = File('${directory.path}/dmusic_library.json');
  try {
    await file.writeAsString(jsonEncode(seed));
    final database = DatabaseService();
    await database.init();
    return await action(database, file);
  } finally {
    await directory.delete(recursive: true);
  }
});

void main() {
  test(
    'preferences round-trip every durable filter and exclude artist state',
    () {
      final preferences = SearchPreferences(
        platforms: ['网易云', 'QQ音乐'],
        qualities: ['FLAC', '320k'],
        sizeRanges: ['15-30MB'],
        durations: ['1-6分钟'],
        versions: ['排除伴奏', '排除Live'],
        downloadStatuses: ['未下载'],
        sortOrder: '时长最长',
      );
      final json = preferences.toJson();
      expect(SearchPreferences.fromJson(json).toJson(), json);
      expect(json.containsKey('artists'), isFalse);
      expect(() => preferences.platforms.add('酷狗音乐'), throwsUnsupportedError);
    },
  );

  test(
    'invalid optional fields default without discarding valid selections',
    () {
      final preferences = SearchPreferences.fromJson({
        'platforms': ['QQ音乐', 'nonexistent', 7],
        'qualities': ['bad'],
        'sizeRanges': 'wrong type',
        'durations': [],
        'versions': ['排除伴奏', '排除Live', '仅看Live'],
        'downloadStatuses': ['全部', '已下载'],
        'sortOrder': 'bad',
      });
      expect(preferences.platforms, {'QQ音乐'});
      expect(preferences.qualities, {'全部'});
      expect(preferences.sizeRanges, {'全部'});
      expect(preferences.durations, {'全部'});
      expect(preferences.versions, {'排除伴奏', '仅看Live'});
      expect(preferences.downloadStatuses, {'全部'});
      expect(preferences.sortOrder, '默认');
      expect(
        SearchPreferences.fromJson(null).toJson(),
        SearchPreferences().toJson(),
      );
      expect(
        SearchPreferences.fromJson(42).toJson(),
        SearchPreferences().toJson(),
      );
    },
  );

  test(
    'old libraries and malformed optional preferences preserve existing data',
    () async {
      for (final seed in [
        _library(),
        _library(preferences: ['malformed']),
      ]) {
        final result = await _freshDatabase(
          seed,
          (database, file) async => {
            'preferences': database.searchPreferences.toJson(),
            'favorites': database.favorites.map((song) => song.id).toList(),
            'history': database.searchHistory,
          },
        );
        expect(result['preferences'], SearchPreferences().toJson());
        expect(result['favorites'], ['saved']);
        expect(result['history'], ['earlier search']);
      }
    },
  );

  test(
    'saved preferences restore with all filter fields from the library',
    () async {
      final preferences = SearchPreferences(
        platforms: ['QQ音乐'],
        qualities: ['FLAC'],
        sizeRanges: ['> 30MB'],
        durations: ['> 6分钟'],
        versions: ['排除伴奏', '仅看Live'],
        downloadStatuses: ['已下载'],
        sortOrder: '体积最大',
      );
      final result = await _freshDatabase(
        _library(preferences: preferences.toJson()),
        (database, file) async => database.searchPreferences.toJson(),
      );
      expect(result, preferences.toJson());
    },
  );

  test(
    'rapid preference writes persist the latest snapshot before completion',
    () async {
      final result = await _freshDatabase(_library(), (database, file) async {
        final first = database.saveSearchPreferences(
          SearchPreferences(qualities: ['FLAC']),
        );
        final latest = database.saveSearchPreferences(
          SearchPreferences(
            platforms: ['QQ音乐'],
            qualities: ['320k'],
            sortOrder: '时长最长',
          ),
        );
        await Future.wait([first, latest]);
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      });
      expect(
        result['searchPreferences'],
        SearchPreferences(
          platforms: ['QQ音乐'],
          qualities: ['320k'],
          sortOrder: '时长最长',
        ).toJson(),
      );
      expect((result['favorites'] as List).single['id'], 'saved');
      expect(result['searchHistory'], ['earlier search']);
    },
  );

  test('reset preferences writes defaults immediately', () async {
    final result = await _freshDatabase(
      _library(
        preferences: SearchPreferences(
          qualities: ['FLAC'],
          sortOrder: '体积最大',
        ).toJson(),
      ),
      (database, file) async {
        await database.saveSearchPreferences(SearchPreferences());
        return jsonDecode(await file.readAsString())['searchPreferences']
            as Map<String, dynamic>;
      },
    );
    expect(result, SearchPreferences().toJson());
  });
}
