import 'dart:convert';
import 'dart:io';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/music_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'audio_fixtures.dart';

List<int> mp3(int bitrate, int seconds) {
  final index = bitrate == 320 ? 14 : 9;
  final frameSize = 144000 * bitrate ~/ 44100;
  final frame = List<int>.filled(frameSize, 0);
  frame.setRange(0, 4, [255, 251, index << 4, 0]);
  return [for (var i = 0; i < seconds * 44100 ~/ 1152; i++) ...frame];
}

void main() {
  test('unqualified cached preview cannot satisfy a FLAC request', () async {
    final song = Song(
      id: '1',
      name: 'Song',
      artist: 'Artist',
      album: '',
      source: 'unsupported',
      audioUrl: 'https://audio.test/preview.mp3',
      audioUrlTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
    final result = await http.runWithClient(
      () => MusicApi.resolveAudioUrl(song, targetQuality: 'flac'),
      () => MockClient(
        (request) async => http.Response.bytes(
          mp3(128, 180),
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      ),
    );
    expect(result, isNull);
  });

  test('valid short MP3 is accepted without a fixed 900KB cutoff', () async {
    final result = await http.runWithClient(
      () => MusicApi.isValidAudioUrl('https://audio.test/short.mp3'),
      () => MockClient((request) async {
        final bytes = mp3(128, 45);
        return http.Response.bytes(
          bytes,
          200,
          headers: {
            'content-type': 'audio/mpeg',
            'content-length': '${bytes.length}',
          },
        );
      }),
    );
    expect(result, isTrue);
  });

  test('HTML pretending to be audio/octet-stream is rejected', () async {
    final result = await http.runWithClient(
      () => MusicApi.isValidAudioUrl('https://audio.test/song.flac'),
      () => MockClient(
        (request) async => http.Response(
          '<html>not music</html>',
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': '3000000',
          },
        ),
      ),
    );
    expect(result, isFalse);
  });

  test('failed probe does not validate an unverified URL', () async {
    final result = await http.runWithClient(
      () => MusicApi.isValidAudioUrl('https://audio.test/song.mp3'),
      () =>
          MockClient((request) async => throw http.ClientException('offline')),
    );
    expect(result, isFalse);
  });

  test('automatic cross-source matching rejects unrelated results', () async {
    final song = Song(
      id: '1',
      name: 'Love Me More',
      artist: 'Apink',
      album: '',
      source: 'QQ音乐',
      durationSeconds: 180,
    );
    final wrongTrack = {
      'id': 2,
      'name': 'Unrelated Song',
      'ar': [
        {'name': 'Other Singer'},
      ],
      'al': {},
      'dt': 180000,
    };
    final result = await http.runWithClient(
      () => MusicApi.resolveCrossSource(
        song,
        preferLossless: false,
        targetQuality: '128k',
      ),
      () => MockClient((request) async {
        if (request.url.host == 'audio.test') {
          return http.Response.bytes(
            mp3(128, 180),
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }
        if (request.url.path.contains('cloudsearch')) {
          return http.Response(
            jsonEncode({
              'result': {
                'songs': [wrongTrack],
              },
            }),
            200,
          );
        }
        if (request.url.host == 'api.injahow.cn') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://audio.test/other.mp3'},
          );
        }
        if (request.url.host == 'api.bugpk.com') {
          return http.Response(
            jsonEncode({'url': 'https://audio.test/other.mp3'}),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    expect(result, isNull);
  });

  test('charts do not claim FLAC when no lossless metadata exists', () async {
    final charts = await http.runWithClient(
      () => MusicApi.fetchTopCharts(),
      () => MockClient(
        (request) async => http.Response(
          jsonEncode({
            'result': {
              'tracks': [
                {
                  'id': 1,
                  'name': 'Song',
                  'artists': [
                    {'name': 'Artist'},
                  ],
                  'duration': 180000,
                  'lMusic': {'bitrate': 128000, 'size': 2880000},
                },
              ],
            },
          }),
          200,
        ),
      ),
    );
    final song = (charts.first['songs'] as List<Song>).first;
    expect(song.isLossless, isFalse);
    expect(song.quality, '128k 标准');
  });

  test(
    'QQ playlist import reports unknown quality when sizes are absent',
    () async {
      final playlist = await http.runWithClient(
        () => MusicApi.importExternalPlaylist('https://y.qq.com/playlist/123'),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              'cdlist': [
                {
                  'dissname': 'Test',
                  'songlist': [
                    {
                      'songmid': '1',
                      'songname': 'Song',
                      'singer': [
                        {'name': 'Artist'},
                      ],
                    },
                  ],
                },
              ],
            }),
            200,
          ),
        ),
      );
      final song = (playlist!['songs'] as List<Song>).first;
      expect(song.isLossless, isFalse);
      expect(song.quality, '音质待检测');
    },
  );

  test(
    'automatic playback tries verified lossless even with unknown catalog quality',
    () async {
      final song = Song(
        id: '1',
        name: 'Song',
        artist: 'Artist',
        album: '',
        source: 'QQ音乐',
        durationSeconds: 180,
      );
      final result = await http.runWithClient(
        () => MusicApi.resolveAudioUrl(song, targetQuality: 'auto'),
        () => MockClient((request) async {
          if (request.url.host == 'audio.test') {
            final bytes = request.url.path.endsWith('.flac')
                ? flacFixture()
                : mp3(320, 180);
            return http.Response.bytes(
              bytes,
              200,
              headers: {'content-type': 'application/octet-stream'},
            );
          }
          if (request.url.host == 'musicapi.haitangw.net') {
            final format = request.url.queryParameters['level'] == 'lossless'
                ? 'flac'
                : 'mp3';
            return http.Response(
              jsonEncode({
                'data': {'url': 'https://audio.test/song.$format'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      expect(result, 'https://audio.test/song.flac');
      expect(song.quality, 'FLAC 无损');
      expect(song.audioUrlQuality, 'auto');
    },
  );

  test(
    'Kugou high quality resolves its independent hash and keeps song identity',
    () async {
      final song = Song(
        id: 'standard',
        name: 'Song',
        artist: 'Artist',
        album: '',
        source: '酷狗音乐',
        durationSeconds: 180,
        highQualityId: 'high',
      );
      final result = await http.runWithClient(
        () => MusicApi.resolveAudioUrl(song, targetQuality: '320k'),
        () => MockClient((request) async {
          if (request.url.host == 'cocodownloader.markqq.com') {
            final path = request.url.queryParameters['id'] == 'high'
                ? 'high.mp3'
                : 'low.mp3';
            return http.Response(
              jsonEncode({'url': 'https://audio.test/$path'}),
              200,
            );
          }
          if (request.url.host == 'audio.test') {
            return http.Response.bytes(
              mp3(request.url.path == '/high.mp3' ? 320 : 128, 180),
              200,
              headers: {'content-type': 'audio/mpeg'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      expect(result, 'https://audio.test/high.mp3');
      expect(song.id, 'standard');
      expect(song.quality, '320k 极高');
    },
  );

  test(
    'remote M4A with late metadata is probed without downloading its media',
    () async {
      final bytes = mp4Fixture(lateMoov: true);
      var transferred = 0;
      final valid = await http.runWithClient(
        () => MusicApi.isValidAudioUrl(
          'https://audio.test/late.m4a',
          durationSeconds: 10,
        ),
        () => MockClient((request) async {
          final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(
            request.headers['Range'] ?? request.headers['range'] ?? '',
          );
          final start = int.parse(range!.group(1)!);
          final end = (int.parse(range.group(2)!) + 1).clamp(0, bytes.length);
          final body = bytes.sublist(start, end);
          transferred += body.length;
          return http.Response.bytes(
            body,
            206,
            headers: {
              'content-type': 'audio/mp4',
              'content-range': 'bytes $start-${end - 1}/${bytes.length}',
            },
          );
        }),
      );
      expect(valid, isTrue);
      expect(transferred, lessThan(100000));
    },
  );

  test('cross-source matching requires all credited artists to match', () {
    Song recording(String artists) => Song(
      id: artists,
      name: 'Track',
      artist: artists,
      album: '',
      source: 'QQ音乐',
      durationSeconds: 180,
    );
    expect(
      MusicApi.isSameRecording(recording('A, B'), recording('A, C')),
      isFalse,
    );
    expect(
      MusicApi.isSameRecording(recording('A, B'), recording('B / A')),
      isTrue,
    );
  });

  test(
    'missing Migu catalog duration stays unknown rather than invented four minutes',
    () async {
      final songs = await http.runWithClient(
        () => MusicApi.searchMigu('Song'),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              'songResultData': {
                'result': [
                  {
                    'id': '1',
                    'name': 'Song',
                    'singers': [
                      {'name': 'Artist'},
                    ],
                  },
                ],
              },
            }),
            200,
          ),
        ),
      );
      expect(songs.single.durationSeconds, 0);
    },
  );

  test(
    'remote FLAC skips large artwork and verifies the first audio frame',
    () async {
      final flac = flacFixture();
      final info = flac.take(42).toList()..[4] = 0;
      final bytes = [
        ...info,
        134,
        4,
        147,
        224,
        ...List<int>.filled(300000, 0),
        ...flac.skip(42),
      ];
      var transferred = 0;
      final valid = await http.runWithClient(
        () => MusicApi.isValidAudioUrl(
          'https://audio.test/picture.flac',
          targetQuality: 'flac',
          durationSeconds: 180,
        ),
        () => MockClient((request) async {
          final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(
            request.headers['Range'] ?? request.headers['range'] ?? '',
          );
          final start = int.parse(range!.group(1)!);
          final end = (int.parse(range.group(2)!) + 1).clamp(0, bytes.length);
          final body = bytes.sublist(start, end);
          transferred += body.length;
          return http.Response.bytes(
            body,
            206,
            headers: {
              'content-type': 'audio/flac',
              'content-range': 'bytes $start-${end - 1}/${bytes.length}',
            },
          );
        }),
      );
      expect(valid, isTrue);
      expect(transferred, lessThan(100000));
    },
  );

  test(
    'known legacy Kugou CDN retries HTTP only after a TLS handshake failure',
    () async {
      final song = Song(
        id: 'standard',
        name: 'Song',
        artist: 'Artist',
        album: '',
        source: '酷狗音乐',
        durationSeconds: 180,
      );
      final result = await http.runWithClient(
        () => MusicApi.resolveAudioUrl(song, targetQuality: '320k'),
        () => MockClient((request) async {
          if (request.url.host == 'cocodownloader.markqq.com') {
            return http.Response(
              jsonEncode({
                'url': 'https://fs.youthandroid2.kugou.com/song.mp3',
              }),
              200,
            );
          }
          if (request.url.host == 'fs.youthandroid2.kugou.com') {
            if (request.url.scheme == 'https') {
              throw const HandshakeException('hostname mismatch');
            }
            return http.Response.bytes(
              mp3(320, 180),
              200,
              headers: {'content-type': 'audio/mpeg'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      expect(result, 'http://fs.youthandroid2.kugou.com/song.mp3');
      expect(song.quality, '320k 极高');
    },
  );

  test(
    'Kugou tries its original hash when a dedicated lossless hash is unavailable',
    () async {
      final song = Song(
        id: 'standard',
        losslessId: 'lossless',
        name: 'Song',
        artist: 'Artist',
        album: '',
        source: '酷狗音乐',
        durationSeconds: 180,
      );
      final result = await http.runWithClient(
        () => MusicApi.resolveAudioUrl(song, targetQuality: 'flac'),
        () => MockClient((request) async {
          if (request.url.host == 'cocodownloader.markqq.com') {
            return request.url.queryParameters['id'] == 'lossless'
                ? http.Response('{}', 500)
                : http.Response(
                    jsonEncode({'url': 'https://audio.test/song.flac'}),
                    200,
                  );
          }
          if (request.url.host == 'audio.test') {
            return http.Response.bytes(
              flacFixture(),
              200,
              headers: {'content-type': 'audio/flac'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      expect(result, 'https://audio.test/song.flac');
      expect(song.quality, 'FLAC 无损');
    },
  );

  test('unrecognized CDN TLS failures never downgrade to HTTP', () async {
    var insecureRequests = 0;
    final song = Song(
      id: 'standard',
      name: 'Song',
      artist: 'Artist',
      album: '',
      source: '酷狗音乐',
    );
    final result = await http.runWithClient(
      () => MusicApi.resolveAudioUrl(song, targetQuality: '320k'),
      () => MockClient((request) async {
        if (request.url.scheme == 'http') insecureRequests++;
        if (request.url.host == 'cocodownloader.markqq.com') {
          return http.Response(
            jsonEncode({'url': 'https://other.test/song.mp3'}),
            200,
          );
        }
        if (request.url.host == 'other.test') {
          throw const HandshakeException('certificate error');
        }
        return http.Response('{}', 200);
      }),
    );
    expect(result, isNull);
    expect(insecureRequests, 0);
  });
}
