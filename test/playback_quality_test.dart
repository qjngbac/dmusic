import 'dart:convert';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/audio_inspector.dart';
import 'package:dmusic_app/services/music_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'audio_fixtures.dart';

void main() {
  test('256k MP3 can be selected without pretending it is 320k', () {
    final bytes = mp3Fixture(bitrate: 256);
    final info = AudioInspector.inspectBytes(bytes, fileSizeBytes: bytes.length);
    expect(info.matchesPlaybackQuality('256k'), isTrue);
    expect(info.matchesQuality('320k'), isFalse);
    expect(info.matchesPlaybackQuality('320k'), isFalse);
  });
  test('cache may reuse higher quality but never a 128k file for 256k', () {
    final low = mp3Fixture();
    final high = mp3Fixture(bitrate: 320);
    expect(AudioInspector.inspectBytes(low, fileSizeBytes: low.length).matchesPlaybackQuality('256k', allowHigher: true), isFalse);
    expect(AudioInspector.inspectBytes(high, fileSizeBytes: high.length).matchesPlaybackQuality('256k', allowHigher: true), isTrue);
  });
  test('AAC 256k is playable but cannot satisfy a 320k MP3 download', () {
    const info = RealAudioInfo(format: 'M4A', qualityLabel: 'AAC 256k', isLossless: false,
      fileSizeBytes: 1000000, bitrateKbps: 256, realExtension: 'm4a', isValid: true);
    expect(info.matchesPlaybackQuality('256k'), isTrue);
    expect(info.matchesQuality('320k'), isFalse);
  });

  Song song() => Song(id: '1', name: 'Song', artist: 'Artist', album: '', source: 'QQ音乐');
  MockClient provider({int bitrate = 256, bool losslessOnly = false}) => MockClient((request) async {
    if (request.url.host == 'audio.test') {
      final bytes = losslessOnly ? flacFixture() : mp3Fixture(bitrate: bitrate);
      return http.Response.bytes(bytes, 200, headers: {'content-type': 'application/octet-stream'});
    }
    if (request.url.host == 'musicapi.haitangw.net') {
      return http.Response(jsonEncode({'data': {'url': 'https://audio.test/song'}}), 200);
    }
    return http.Response('{}', 404);
  });
  test('online playback requests 256 and reports actual 256', () async {
    final track = song();
    final result = await http.runWithClient(() => MusicApi.resolveAudioUrl(track,
      targetQuality: '256k', forPlayback: true), () => provider());
    expect(result, 'https://audio.test/song');
    expect(track.audioUrlQuality, '256k');
    expect(track.quality, contains('256'));
  });
  test('missing 256 falls back to verified 320 without relabeling it', () async {
    final track = song();
    final result = await http.runWithClient(() => MusicApi.resolveAudioUrl(track,
      targetQuality: '256k', forPlayback: true), () => provider(bitrate: 320));
    expect(result, 'https://audio.test/song');
    expect(track.audioUrlQuality, '256k');
    expect(track.quality, '320k 极高');
  });
  test('lossless-only source remains usable and shows lossless honestly', () async {
    final track = song();
    final result = await http.runWithClient(() => MusicApi.resolveAudioUrl(track,
      targetQuality: '256k', forPlayback: true), () => provider(losslessOnly: true));
    expect(result, 'https://audio.test/song');
    expect(track.quality, 'FLAC 无损');
  });
  test('default 256 never silently accepts only 128k', () async {
    final result = await http.runWithClient(() => MusicApi.resolveAudioUrl(song(),
      targetQuality: '256k', forPlayback: true), () => provider(bitrate: 128));
    expect(result, isNull);
  });
}
