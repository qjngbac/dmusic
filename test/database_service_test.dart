import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
// The application already uses this interface through path_provider.
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TemporaryPaths extends PathProviderPlatform {
  _TemporaryPaths(this.directory);

  final String directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
}

Song _song(String id, String source, {int duration = 240}) => Song(
  id: id,
  source: source,
  name: 'Same title',
  artist: 'Same artist',
  album: '',
  durationSeconds: duration,
);

// PCM stereo, 44.1kHz/16bit, with lengths derived from the WAV specification.
Future<File> _wav(Directory directory, String name, {int seconds = 1}) async {
  final dataSize = seconds * 44100 * 4;
  final bytes = Uint8List(44 + dataSize);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  header.setUint32(4, 36 + dataSize, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, 44100, Endian.little);
  header.setUint32(28, 176400, Endian.little);
  header.setUint16(32, 4, Endian.little);
  header.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  header.setUint32(40, dataSize, Endian.little);
  return File('${directory.path}/$name').writeAsBytes(bytes);
}

Future<void> _seedLibrary(Directory directory, List<Song> downloads) async {
  await File('${directory.path}/dmusic_library.json').writeAsString(
    jsonEncode({
      'downloads': downloads.map((song) => song.toJson()).toList(),
      'favorites': [],
      'history': [],
      'searchHistory': [],
      'playlists': [],
      'enabledSources': ['网易云'],
    }),
  );
}

Future<Map<String, dynamic>> _inFreshDatabase(
  Future<Map<String, dynamic>> Function(DatabaseService, Directory) operation, {
  String? primary,
  String? backup,
  Future<void> Function(Directory)? initialize,
}) => Isolate.run(() async {
  final directory = await Directory.systemTemp.createTemp('dmusic-db-test-');
  PathProviderPlatform.instance = _TemporaryPaths(directory.path);
  try {
    if (primary != null) {
      await File(
        '${directory.path}/dmusic_library.json',
      ).writeAsString(primary);
    }
    if (backup != null) {
      await File(
        '${directory.path}/dmusic_library.json.bak',
      ).writeAsString(backup);
    }
    if (initialize != null) await initialize(directory);
    final database = DatabaseService();
    await database.init();
    return await operation(database, directory);
  } finally {
    // Let the production persistence debounce complete before deleting fixtures.
    await Future<void>.delayed(const Duration(milliseconds: 750));
    await directory.delete(recursive: true);
  }
});

void main() {
  test('historical task recovery does not replace a newer registered download', () async {
    final result = await _inFreshDatabase((database, directory) async {
      final original = _song('1', '网易云', duration: 1);
      final registered = await database.addDownload(original, await _wav(directory, 'new.wav'));
      final oldFile = await _wav(directory, 'old.wav');
      await database.restoreExistingDownloads([
        original.copyWith(localFilePath: oldFile.path, downloadTime: DateTime(2020)),
      ]);
      return {
        'samePath': database.downloads.single.localFilePath == registered.localFilePath,
        'sameTime': database.downloads.single.downloadTime == registered.downloadTime,
        'oldExists': await oldFile.exists(),
        'count': database.downloads.length,
      };
    });
    expect(result, {'samePath': true, 'sameTime': true, 'oldExists': true, 'count': 1});
  });

  test('failed task recovery persistence rolls back rows and keeps the audio', () async {
    final result = await _inFreshDatabase((database, directory) async {
      final file = await _wav(directory, 'recover.wav');
      await Directory('${directory.path}/dmusic_library.json.tmp').create();
      var rejected = false;
      try {
        await database.restoreExistingDownloads([
          _song('1', '网易云', duration: 1).copyWith(localFilePath: file.path),
        ]);
      } on FileSystemException { rejected = true; }
      return {'rejected': rejected, 'count': database.downloads.length,
        'exists': await file.exists()};
    });
    expect(result, {'rejected': true, 'count': 0, 'exists': true});
  });

  test(
    'download registration is durable when its returned future completes',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        await database.addDownload(
          _song('1', '网易云'),
          await _wav(directory, 'durable.wav'),
        );
        final saved = File('${directory.path}/dmusic_library.json');
        return {
          'exists': await saved.exists(),
          'count': await saved.exists()
              ? (jsonDecode(await saved.readAsString())['downloads'] as List)
                    .length
              : 0,
        };
      });
      expect(result['exists'], isTrue);
      expect(result['count'], 1);
    },
  );

  test(
    'failed durable registration reports failure and rolls back its record',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        await Directory('${directory.path}/dmusic_library.json.tmp').create();
        var rejected = false;
        final audio = await _wav(directory, 'preserved.wav');
        try {
          await database.addDownload(_song('1', '网易云'), audio);
        } on FileSystemException {
          rejected = true;
        }
        return {
          'rejected': rejected,
          'count': database.downloads.length,
          'audioExists': await audio.exists(),
        };
      });
      expect(result['rejected'], isTrue);
      expect(result['count'], 0);
      expect(result['audioExists'], isTrue);
    },
  );

  test('cancelled registration does not create a library record', () async {
    final result = await _inFreshDatabase((database, directory) async {
      var cancelled = false;
      try {
        await database.addDownload(
          _song('1', '网易云'),
          await _wav(directory, 'cancelled.wav'),
          isCurrent: () => false,
        );
      } on StateError {
        cancelled = true;
      }
      return {'cancelled': cancelled, 'count': database.downloads.length};
    });
    expect(result['cancelled'], isTrue);
    expect(result['count'], 0);
  });

  test(
    'cancellation during persistence rolls back only the inserted record',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        var cancelled = false;
        try {
          await database.addDownload(
            _song('1', '网易云'),
            await _wav(directory, 'cancelled.wav'),
            isCurrent: () => database.downloads.isEmpty,
          );
        } on StateError {
          cancelled = true;
        }
        final saved = File('${directory.path}/dmusic_library.json');
        await Future<void>.delayed(const Duration(milliseconds: 750));
        return {
          'cancelled': cancelled,
          'count': database.downloads.length,
          'savedCount':
              (jsonDecode(await saved.readAsString())['downloads'] as List)
                  .length,
        };
      });
      expect(result['cancelled'], isTrue);
      expect(result['count'], 0);
      expect(result['savedCount'], 0);
    },
  );

  test(
    'same-title downloads from different sources preserve both files',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        final first = await _wav(directory, 'first.wav');
        final second = await _wav(directory, 'second.wav');
        await database.addDownload(_song('1', '网易云'), first);
        await database.addDownload(_song('2', 'QQ音乐'), second);
        return {
          'keys': database.downloads.map((song) => song.key).toList(),
          'firstExists': await first.exists(),
          'secondExists': await second.exists(),
        };
      });
      expect(result['keys'], unorderedEquals(['网易云::1', 'QQ音乐::2']));
      expect(result['firstExists'], isTrue);
      expect(result['secondExists'], isTrue);
    },
  );

  test('same-key replacement preserves the old physical recording', () async {
    final result = await _inFreshDatabase((database, directory) async {
      final first = await _wav(directory, 'old.wav');
      final second = await _wav(directory, 'new.wav');
      await database.addDownload(_song('1', '网易云'), first);
      await database.addDownload(_song('1', '网易云'), second);
      return {
        'count': database.downloads.length,
        'oldExists': await first.exists(),
        'currentPath': database.downloads.single.localFilePath,
        'newPath': second.path,
      };
    });
    expect(result['count'], 1);
    expect(result['oldExists'], isTrue);
    expect(result['currentPath'], result['newPath']);
  });

  test('extension correction never overwrites an existing recording', () async {
    final result = await _inFreshDatabase((database, directory) async {
      final existing = await _wav(directory, 'track.wav', seconds: 2);
      final input = await _wav(directory, 'track.mp3');
      final originalBytes = await existing.readAsBytes();
      final registered = await database.addDownload(_song('1', '网易云'), input);
      return {
        'existingUnchanged':
            base64Encode(await existing.readAsBytes()) ==
            base64Encode(originalBytes),
        'registeredPath': registered.localFilePath,
        'existingPath': existing.path,
        'registeredSize': await File(registered.localFilePath!).length(),
      };
    });
    expect(result['existingUnchanged'], isTrue);
    expect(result['registeredPath'], isNot(result['existingPath']));
    expect(result['registeredSize'], 176444);
  });

  test('download registration records the actual WAV duration', () async {
    final result = await _inFreshDatabase((database, directory) async {
      final file = await _wav(directory, 'short.wav', seconds: 2);
      final song = await database.addDownload(_song('1', '网易云'), file);
      return {'duration': song.durationSeconds};
    });
    expect(result['duration'], 2);
  });

  test(
    'download registration rejects disguised non-audio without renaming it',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        final file = await File(
          '${directory.path}/error.flac',
        ).writeAsString('<html>error</html>');
        var rejected = false;
        try {
          await database.addDownload(_song('1', '网易云'), file);
        } on FormatException {
          rejected = true;
        }
        return {
          'rejected': rejected,
          'count': database.downloads.length,
          'originalExists': await file.exists(),
        };
      });
      expect(result['rejected'], isTrue);
      expect(result['count'], 0);
      expect(result['originalExists'], isTrue);
    },
  );

  test(
    'moving a concrete song preserves another source with the same ID',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        final from = await database.createPlaylist('from');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        final to = await database.createPlaylist('to');
        final selected = _song('1', '网易云');
        await database.batchAddSongsToPlaylist(from.id, [
          selected,
          _song('1', 'QQ音乐'),
        ]);
        await database.batchMoveSongsToPlaylist(
          sourcePlaylistId: from.id,
          targetPlaylistId: to.id,
          songs: [selected],
        );
        return {
          'sourceKeys': from.songs.map((song) => song.key).toList(),
          'targetKeys': to.songs.map((song) => song.key).toList(),
        };
      });
      expect(result['sourceKeys'], ['QQ音乐::1']);
      expect(result['targetKeys'], ['网易云::1']);
    },
  );

  test(
    'a solo recording is not an exact match for a duet with the same title',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        final file = await _wav(directory, 'solo.wav');
        await database.addDownload(_song('1', '网易云'), file);
        final candidate = _song(
          '2',
          'QQ音乐',
        ).copyWith(artist: 'Same artist / Other artist');
        return {'isExact': database.checkDownloadStatus(candidate).isExact};
      });
      expect(result['isExact'], isFalse);
    },
  );

  test(
    'registered audio cache retains its quality and expiration metadata',
    () async {
      final result = await _inFreshDatabase((database, directory) async {
        final input = _song('1', '网易云').copyWith(
          audioUrl: 'https://example.invalid/audio.wav',
          audioUrlTimestamp: 123456,
          audioUrlQuality: 'flac',
          audioUrlSource: '网易云',
          losslessId: 'lossless-hash',
          highQualityId: 'high-hash',
          transLyric: 'translated lyric',
        );
        final registered = await database.addDownload(
          input,
          await _wav(directory, 'cache.wav'),
        );
        return {
          'timestamp': registered.audioUrlTimestamp,
          'quality': registered.audioUrlQuality,
          'source': registered.audioUrlSource,
          'losslessId': registered.losslessId,
          'highQualityId': registered.highQualityId,
          'transLyric': registered.transLyric,
        };
      });
      expect(result['timestamp'], 123456);
      expect(result['quality'], 'flac');
      expect(result['source'], '网易云');
      expect(result['losslessId'], 'lossless-hash');
      expect(result['highQualityId'], 'high-hash');
      expect(result['transLyric'], 'translated lyric');
    },
  );

  test(
    'loading a preview removes its record while preserving physical bytes',
    () async {
      final result = await _inFreshDatabase(
        (database, directory) async {
          return {
            'count': database.downloads.length,
            'exists': await File('${directory.path}/preview.wav').exists(),
          };
        },
        initialize: (directory) async {
          final file = await _wav(directory, 'preview.wav');
          await _seedLibrary(directory, [
            _song(
              '1',
              'QQ音乐',
              duration: 300,
            ).copyWith(localFilePath: file.path),
          ]);
        },
      );
      expect(result['count'], 0);
      expect(result['exists'], isTrue);
    },
  );

  test(
    'loading disguised HTML excludes it without deleting its bytes',
    () async {
      final result = await _inFreshDatabase(
        (database, directory) async {
          return {
            'count': database.downloads.length,
            'content': await File('${directory.path}/error.mp3').readAsString(),
          };
        },
        initialize: (directory) async {
          final file = await File(
            '${directory.path}/error.mp3',
          ).writeAsString('<html>error</html>');
          await _seedLibrary(directory, [
            _song('1', 'QQ音乐').copyWith(localFilePath: file.path),
          ]);
        },
      );
      expect(result['count'], 0);
      expect(result['content'], '<html>error</html>');
    },
  );

  test(
    'loading valid audio replaces old estimated labels with measured properties',
    () async {
      final result = await _inFreshDatabase(
        (database, directory) async {
          final restored = database.downloads.single;
          return {
            'quality': restored.quality,
            'lossless': restored.isLossless,
            'duration': restored.durationSeconds,
            'bytes': restored.fileSizeBytes,
          };
        },
        initialize: (directory) async {
          final file = await _wav(directory, 'full.wav', seconds: 2);
          await _seedLibrary(directory, [
            _song('1', 'QQ音乐', duration: 2).copyWith(
              localFilePath: file.path,
              quality: 'AAC 256k',
              isLossless: false,
            ),
          ]);
        },
      );
      expect(result['quality'], isNot('AAC 256k'));
      expect(result['lossless'], isTrue);
      expect(result['duration'], 2);
      expect(result['bytes'], 352844);
    },
  );

  for (final malformed in ['{broken', '[]', '{}', '{"downloads":42}']) {
    test('unrecoverable database preserves originals: $malformed', () async {
      final result = await _inFreshDatabase(
        (database, directory) async {
          await database.toggleFavorite(_song('1', '网易云'));
          await Future<void>.delayed(const Duration(milliseconds: 750));
          return {
            'primary': await File(
              '${directory.path}/dmusic_library.json',
            ).readAsString(),
            'backup': await File(
              '${directory.path}/dmusic_library.json.bak',
            ).readAsString(),
          };
        },
        primary: malformed,
        backup: '{also broken',
      );
      expect(result['primary'], malformed);
      expect(result['backup'], '{also broken');
    });
  }

  test(
    'invalid main schema recovers a valid backup before new writes',
    () async {
      final validBackup = jsonEncode({
        'downloads': [],
        'favorites': [_song('backup', '网易云').toJson()],
        'history': [],
        'searchHistory': [],
        'playlists': [],
        'enabledSources': ['网易云'],
      });
      final result = await _inFreshDatabase(
        (database, directory) async {
          final restoredKeys = database.favorites
              .map((song) => song.key)
              .toList();
          await database.toggleFavorite(_song('new', 'QQ音乐'));
          await Future<void>.delayed(const Duration(milliseconds: 750));
          return {
            'restoredKeys': restoredKeys,
            'savedKeys':
                (jsonDecode(
                          await File(
                            '${directory.path}/dmusic_library.json',
                          ).readAsString(),
                        )['favorites']
                        as List)
                    .map((song) => '${song['source']}::${song['id']}')
                    .toList(),
            'backup': await File(
              '${directory.path}/dmusic_library.json.bak',
            ).readAsString(),
          };
        },
        primary: '[]',
        backup: validBackup,
      );
      expect(result['restoredKeys'], ['网易云::backup']);
      expect(
        result['savedKeys'],
        unorderedEquals(['网易云::backup', 'QQ音乐::new']),
      );
      expect(result['backup'], validBackup);
    },
  );
}
