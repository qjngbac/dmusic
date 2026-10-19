import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dmusic_app/services/audio_inspector.dart';
import 'audio_fixtures.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dmusic_audio_test_');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<RealAudioInfo> inspect(
    List<int> bytes, {
    String name = 'audio.bin',
    int duration = 0,
  }) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(bytes);
    return AudioInspector.inspect(file, durationSeconds: duration);
  }

  test('HTML with a FLAC extension cannot become lossless audio', () async {
    final info = await inspect(
      '<html>permission denied</html>'.codeUnits,
      name: 'fake.flac',
    );
    expect(info.format, 'UNKNOWN');
    expect(info.isLossless, false);
    expect(info.bitrateKbps, 0);
  });
  test('256 kbps MP3 is never labeled as 320 kbps', () async {
    final info = await inspect(mp3Fixture(bitrate: 256, frames: 600));
    expect(info.bitrateKbps, 256);
    expect(info.qualityLabel, contains('256'));
    expect(info.qualityLabel, isNot(contains('320')));
  });
  test('large ID3 tags do not hide the real MP3 bitrate', () async {
    final info = await inspect(mp3Fixture(bitrate: 320, id3Size: 300000));
    expect(info.bitrateKbps, 320);
  });
  test('valid short PCM WAV is recognized without a fragment label', () async {
    final info = await inspect(wavFixture());
    expect(info.format, 'WAV');
    expect(info.qualityLabel, contains('PCM'));
    expect(info.bitrateKbps, 128);
  });
  test('RIFF AVI is not misidentified as lossless WAV', () async {
    final info = await inspect([
      ...'RIFF'.codeUnits,
      ...le32(32),
      ...'AVI '.codeUnits,
      ...List.filled(28, 0),
    ]);
    expect(info.format, 'UNKNOWN');
  });
  test(
    'M4A quality comes from its audio track rather than catalog duration',
    () async {
      final info = await inspect(mp4Fixture(), duration: 1);
      expect(info.format, 'M4A');
      expect(info.bitrateKbps, 128);
      expect(info.qualityLabel, 'AAC 128k');
    },
  );
  test('ID3 without MPEG audio frames is not MP3', () async {
    final info = await inspect([
      73,
      68,
      51,
      4,
      0,
      0,
      0,
      0,
      0,
      0,
      ...List.filled(200, 0),
    ]);
    expect(info.format, 'UNKNOWN');
  });
  test(
    '128 and 320 MP3 requests match measured headers, not catalog labels',
    () async {
      final standard = await inspect(mp3Fixture(bitrate: 128));
      final medium = await inspect(mp3Fixture(bitrate: 256));
      final high = await inspect(mp3Fixture(bitrate: 320));
      expect(standard.isValid, true);
      expect(standard.matchesQuality('128k'), true);
      expect(standard.matchesQuality('320k'), false);
      expect(medium.matchesQuality('320k'), false);
      expect(high.matchesQuality('320k'), true);
      expect(high.matchesQuality('128k'), true);
      expect(high.matchesQuality('flac'), false);
    },
  );
  test('large 16-bit FLAC stays CD quality and real 24-bit FLAC is Hi-Res', () {
    final cd = AudioInspector.inspectBytes(
      flacFixture(seconds: 600),
      fileSizeBytes: 45 * 1024 * 1024,
    );
    final hires = AudioInspector.inspectBytes(
      flacFixture(sampleRate: 96000, bits: 24),
      fileSizeBytes: 2000000,
    );
    expect(cd.isValid, true);
    expect(cd.durationSeconds, 600);
    expect(cd.bitsPerSample, 16);
    expect(cd.sampleRate, 44100);
    expect(cd.qualityLabel, 'FLAC 无损');
    expect(cd.matchesQuality('hires'), false);
    expect(hires.matchesQuality('hires'), true);
    expect(hires.qualityLabel, 'Hi-Res 24bit');
  });
  test('metadata-only FLAC cannot pass validation', () async {
    final info = await inspect(flacFixture().take(43).toList());
    expect(info.isValid, false);
  });
  test('FLAC with an intact header and truncated audio is rejected', () async {
    final bytes = flacFixture();
    final info = await inspect(bytes.take(60).toList());
    expect(info.isValid, false);
  });
  test('FLAC frame payload corruption is rejected by its checksum', () async {
    final bytes = flacFixture();
    bytes[bytes.length - 3] ^= 1;
    expect((await inspect(bytes)).isValid, false);
  });
  test(
    'FLAC missing complete trailing frames cannot trust stream duration',
    () async {
      final bytes = flacFixture();
      // Retain a complete first frame, but advertise the original sample count.
      final next = bytes.indexOf(255, 44);
      expect(next, greaterThan(42));
      expect((await inspect(bytes.take(next).toList())).isValid, false);
    },
  );
  test(
    'FLAC with unknown total samples derives duration from checked frames',
    () async {
      final bytes = flacFixture();
      bytes[21] &= 0xf0;
      bytes.fillRange(22, 26, 0);
      final info = await inspect(bytes);
      expect(info.isValid, true);
      expect(info.durationSeconds, 180);
    },
  );
  test(
    'FLAC frame header CRC is checked even when frame CRC is corrected',
    () async {
      final bytes = flacFixture(seconds: 1);
      bytes[49] ^= 1;
      final next = bytes.indexOf(255, 44);
      final crc = flacCrc(bytes.sublist(42, next - 2), 16, 0x8005);
      bytes[next - 2] = crc >> 8;
      bytes[next - 1] = crc & 255;
      expect((await inspect(bytes)).isValid, false);
    },
  );
  test(
    'FLAC scanning carries frame headers across file read boundaries',
    () async {
      final info = await inspect(flacFixture(seconds: 600));
      expect(info.isValid, true);
      expect(info.durationSeconds, 600);
    },
  );
  test(
    'ID3 before complete FLAC preserves frame and duration checks',
    () async {
      final info = await inspect([
        73,
        68,
        51,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        ...flacFixture(seconds: 1),
      ]);
      expect(info.isValid, true);
      expect(info.durationSeconds, 1);
    },
  );
  test('variable-block FLAC checks consecutive sample offsets', () async {
    List<int> frame(List<int> number) {
      final bytes = <int>[255, 249, 0x70, 0x10, ...number, 15, 255];
      bytes.add(flacCrc(bytes, 8, 7));
      bytes.addAll(List.filled(6, 0));
      final crc = flacCrc(bytes, 16, 0x8005);
      return [...bytes, crc >> 8, crc & 255];
    }

    final header = flacFixture(sampleRate: 8192, seconds: 1).take(42);
    final info = await inspect([
      ...header,
      ...frame([0]),
      ...frame([0xe1, 0x80, 0x80]),
    ]);
    expect(info.isValid, true);
    expect(info.durationSeconds, 1);
    expect(
      (await inspect([
        ...header,
        ...frame([0]),
        ...frame([0xe1, 0x80, 0x81]),
      ])).isValid,
      false,
    );
  });
  // Independent real encoder examples, RFC 9639 Appendix D.1/D.2/D.3:
  // https://www.rfc-editor.org/rfc/rfc9639.html#appendix-D
  final rfcExamples = [
    '664c6143800000221000100000000f00000f0ac442f0000000013e84b41807dc690307586a3dad1a2e0f'
        'fff869180000bf0358fd03128baa9a',
    '664c614300000022001000100000170000440ac442f000000013d5b0564975e98b8d8b930422757b8103'
        '030000120000000000000000000000000000000000100400003a20000000'
        '7265666572656e6365206c6962464c414320312e332e3320323031393038303401000000'
        '0e0000005449544c453dd7a9d79cd795d79d81000006000000000000'
        'fff86998000f9912086701623d1442998f5df70d6fe00c17caeb21000ee7a77a24a1590c'
        '1217b603097b784faa9a33d285e070ad5b1b4851b4010d99d2cd1a68f1e6b810'
        'fff869180102a402c382c40bc14a03ee48dd03b67c1330',
    '664c6143800000221000100000001f00001f07d0007000000018f8f9e396f5cbcfc6dc807f9977906b32'
        'fff868020017e944004f6f313d1047d227cb6d090831452bdc2822228057a3',
  ];
  for (var example = 0; example < rfcExamples.length; example++) {
    test(
      'RFC 9639 encoded FLAC example ${example + 1} passes full inspection',
      () async {
        final hex = rfcExamples[example];
        final bytes = [
          for (var p = 0; p < hex.length; p += 2)
            int.parse(hex.substring(p, p + 2), radix: 16),
        ];
        expect((await inspect(bytes)).isValid, true);
        bytes[bytes.length - 1] ^= 1;
        expect((await inspect(bytes)).isValid, false);
      },
    );
  }
  test(
    'measured one-minute MP3 cannot pass as the full three-minute song',
    () async {
      final info = await inspect(mp3Fixture(frames: 2297), duration: 180);
      expect(info.durationSeconds, 60);
      expect(info.matchesDuration(180), false);
      expect(info.matchesDuration(60), true);
      expect(info.matchesDuration(20), false);
      expect(info.matchesDuration(0), true);
    },
  );
  test('partial trailing MPEG frame is rejected', () async {
    final bytes = mp3Fixture(frames: 10);
    final info = await inspect(bytes.take(bytes.length - 30).toList());
    expect(info.isValid, false);
  });
  test('MPEG2 Layer III frame bitrate and sample rate are parsed', () async {
    final info = await inspect(mp3Fixture(mpeg2: true, bitrate: 64));
    expect(info.isValid, true);
    expect(info.bitrateKbps, 64);
    expect(info.sampleRate, 22050);
    expect(info.matchesQuality('128k'), false);
  });
  test(
    'Xing duration uses frame count and rejects missing advertised bytes',
    () async {
      final bytes = mp3Fixture(frames: 100, xingFrames: 100);
      final info = await inspect(bytes);
      expect(info.durationSeconds, 3);
      bytes.setRange(48, 52, be32(bytes.length + 500));
      final truncated = await inspect(bytes);
      expect(truncated.isValid, false);
    },
  );
  test('WAV data chunk cannot declare samples beyond the file end', () async {
    final bytes = wavFixture();
    final info = await inspect(bytes.take(bytes.length - 2).toList());
    expect(info.isValid, false);
  });
  test('MP4 video track cannot satisfy an audio download quality', () async {
    final info = await inspect(mp4Fixture(video: true));
    expect(info.hasVideo, true);
    expect(info.format, 'MP4');
    expect(info.realExtension, 'mp4');
    expect(info.bitrateKbps, 128);
    expect(info.durationSeconds, 10);
    expect(info.matchesQuality(''), false);
    expect(info.matchesQuality('320k'), false);
  });
  test('M4A with late moov is inspected by seeking past media', () async {
    final info = await inspect(mp4Fixture(lateMoov: true));
    expect(info.isValid, true);
    expect(info.durationSeconds, 10);
    expect(info.bitrateKbps, 128);
  });
  test(
    'remote MP4 prefix cannot ignore a resource smaller than declared mdat',
    () {
      final bytes = mp4Fixture();
      final info = AudioInspector.inspectBytes(
        bytes.take(4096).toList(),
        fileSizeBytes: 4096,
      );
      expect(info.isValid, false);
    },
  );
  test('truncated M4A media cannot pass sample size validation', () async {
    final bytes = mp4Fixture();
    final info = await inspect(bytes.take(bytes.length - 100).toList());
    expect(info.isValid, false);
  });
  test('VBRI frame count supplies duration without catalog timing', () async {
    final bytes = mp3Fixture(frames: 100);
    bytes.setRange(36, 40, 'VBRI'.codeUnits);
    bytes.setRange(46, 50, be32(bytes.length));
    bytes.setRange(50, 54, be32(100));
    final info = await inspect(bytes, duration: 240);
    expect(info.durationSeconds, 3);
    expect(info.bitrateKbps, 128);
  });
  List<int> adts() {
    final frame = List<int>.filled(300, 0);
    frame.setRange(0, 7, [255, 241, 80, 128, 37, 159, 252]);
    return [...frame, ...frame, ...frame];
  }

  test(
    'ADTS AAC bitrate follows complete frames rather than default duration',
    () async {
      final info = await inspect(adts(), duration: 240);
      expect(info.isValid, true);
      expect(info.format, 'AAC');
      expect(info.sampleRate, 44100);
      expect(info.channels, 2);
      expect(info.bitrateKbps, 103);
      expect(info.matchesQuality('320k'), false);
    },
  );
  test(
    'truncated final ADTS frame is invalid rather than lower bitrate',
    () async {
      final bytes = adts();
      final info = await inspect(bytes.take(bytes.length - 20).toList());
      expect(info.isValid, false);
    },
  );
  List<int> opus() => [
    ...'OggS'.codeUnits,
    0,
    2,
    ...List.filled(20, 0),
    1,
    19,
    ...'OpusHead'.codeUnits,
    1,
    2,
    0,
    0,
    ...le32(48000),
    0,
    0,
    0,
  ];
  test(
    'Opus identification remains honest when stream bitrate is unknown',
    () async {
      final info = await inspect(opus());
      expect(info.isValid, true);
      expect(info.format, 'OGG');
      expect(info.bitrateKbps, 0);
      expect(info.durationSeconds, 0);
      expect(info.qualityLabel, contains('未知'));
      expect(info.matchesQuality('320k'), false);
    },
  );
  test('truncated Ogg page cannot pass on an Opus signature alone', () async {
    final bytes = opus();
    bytes[27] = 255;
    final info = await inspect(bytes);
    expect(info.isValid, false);
  });
  List<int> pictureFlac({required bool audio}) {
    final streamInfo = flacFixture().take(42).toList();
    streamInfo[4] = 0;
    const pictureSize = 300000;
    return [
      ...streamInfo,
      0x86,
      (pictureSize >> 16) & 255,
      (pictureSize >> 8) & 255,
      pictureSize & 255,
      ...List.filled(pictureSize, 0),
      if (audio) ...flacFixture().skip(42) else ...List.filled(128, 0),
    ];
  }

  test('large FLAC artwork does not hide a junk audio tail', () async {
    final info = await inspect(pictureFlac(audio: false));
    expect(info.isValid, false);
    expect(info.matchesQuality('flac'), false);
  });
  test('FLAC prefix ending inside artwork cannot establish valid audio', () {
    final bytes = pictureFlac(audio: true);
    final info = AudioInspector.inspectBytes(
      bytes.take(65536).toList(),
      fileSizeBytes: bytes.length,
    );
    expect(info.isValid, false);
    expect(info.matchesQuality('flac'), false);
  });
  test(
    'full FLAC inspection seeks past artwork to verify audio frames',
    () async {
      final info = await inspect(pictureFlac(audio: true));
      expect(info.isValid, true);
      expect(info.durationSeconds, 180);
      expect(info.matchesQuality('flac'), true);
    },
  );
}
