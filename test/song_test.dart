import 'package:dmusic_app/models/song.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Song song() =>
      Song(id: '1', name: 'Song', artist: 'Artist', album: '', source: 'QQ音乐');

  test('copyWith can explicitly clear cached URL and timestamp', () {
    final original = song()
      ..audioUrl = 'https://audio.test/song.mp3'
      ..audioUrlTimestamp = 123;
    final cleared = original.copyWith(audioUrl: null, audioUrlTimestamp: null);
    expect(cleared.audioUrl, isNull);
    expect(cleared.audioUrlTimestamp, isNull);
    expect(original.audioUrl, isNotNull);
    expect(original.copyWith().audioUrl, original.audioUrl);
  });

  test('URL without acquisition timestamp is expired', () {
    final original = song()..audioUrl = 'https://audio.test/song.mp3';
    expect(original.isAudioUrlExpired, isTrue);
  });

  test('empty and unknown artists cannot match arbitrary singers', () {
    expect(Song.isArtistMatch('', 'Apink'), isFalse);
    expect(Song.isArtistMatch('未知歌手', '未知歌手'), isFalse);
    expect(Song.isArtistMatch('Pink', 'Apink'), isFalse);
    expect(Song.isArtistMatch('EJAE;AUDREY NUNA', 'EJAE'), isTrue);
  });

  test('legacy numeric strings restore without type cast failures', () {
    final restored = Song.fromJson({
      'id': '1',
      'durationSeconds': '180',
      'fileSizeBytes': '123456',
      'audioUrlTimestamp': '987654',
    });
    expect(restored.durationSeconds, 180);
    expect(restored.fileSizeBytes, 123456);
    expect(restored.audioUrlTimestamp, 987654);
  });
}
