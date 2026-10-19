import 'dart:typed_data';

List<int> mp3Fixture({
  int bitrate = 128,
  int frames = 100,
  int id3Size = 0,
  bool mpeg2 = false,
  int? xingFrames,
}) {
  const rates = [
    0,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
    256,
    320,
  ];
  const lowRates = [
    0,
    8,
    16,
    24,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    144,
    160,
  ];
  final index = (mpeg2 ? lowRates : rates).indexOf(bitrate);
  final frameLength =
      ((mpeg2 ? 72000 : 144000) * bitrate ~/ (mpeg2 ? 22050 : 44100));
  final bytes = <int>[];
  if (id3Size > 0) {
    bytes.addAll([
      73,
      68,
      51,
      4,
      0,
      0,
      (id3Size >> 21) & 127,
      (id3Size >> 14) & 127,
      (id3Size >> 7) & 127,
      id3Size & 127,
    ]);
    bytes.addAll(List.filled(id3Size, 0));
  }
  for (var i = 0; i < frames; i++) {
    final frame = List<int>.filled(frameLength, 0);
    frame.setRange(0, 4, [255, mpeg2 ? 243 : 251, index << 4, 0]);
    if (i == 0 && xingFrames != null) {
      frame.setRange(36, 40, 'Xing'.codeUnits);
      frame.setRange(40, 44, be32(3));
      frame.setRange(44, 48, be32(xingFrames));
      frame.setRange(48, 52, be32(frameLength * frames));
    }
    bytes.addAll(frame);
  }
  return bytes;
}

List<int> flacFixture({
  int sampleRate = 44100,
  int bits = 16,
  int seconds = 180,
  int payloadSize = 128,
}) {
  final info = List<int>.filled(34, 0);
  info.setRange(0, 4, [0x10, 0, 0x10, 0]); // 4096 samples per block.
  final packed =
      (sampleRate << 44) |
      (1 << 41) |
      ((bits - 1) << 36) |
      (sampleRate * seconds);
  for (var i = 0; i < 8; i++) {
    info[10 + i] = (packed >> (56 - i * 8)) & 255;
  }
  final bytes = <int>[...'fLaC'.codeUnits, 0x80, 0, 0, 34, ...info];
  // RFC 9639 constant subframes: independent stereo silence. Real frames,
  // including CRCs and consecutive frame numbers, cover every declared sample.
  var remaining = sampleRate * seconds, frameNumber = 0;
  while (remaining > 0) {
    final count = remaining > 4096 ? 4096 : remaining;
    final number = <int>[];
    var value = frameNumber++;
    if (value < 128) {
      number.add(value);
    } else {
      while (value >= 64) {
        number.insert(0, 128 | (value & 63));
        value >>= 6;
      }
      // Select the shortest extended UTF-8 representation.
      while (value >= (1 << (6 - number.length))) {
        number.insert(0, 128 | (value & 63));
        value >>= 6;
      }
      number.insert(0, (256 - (1 << (7 - number.length))) | value);
    }
    final frame = <int>[
      255,
      248,
      0x70,
      0x10,
      ...number,
      ((count - 1) >> 8) & 255,
      (count - 1) & 255,
    ];
    frame.add(flacCrc(frame, 8, 0x07));
    // Constant subframe headers and zero-valued samples; final byte padding.
    frame.addAll(List.filled((2 * (8 + bits) + 7) ~/ 8, 0));
    final crc = flacCrc(frame, 16, 0x8005);
    frame.addAll([(crc >> 8) & 255, crc & 255]);
    bytes.addAll(frame);
    remaining -= count;
  }
  return bytes;
}

int flacCrc(List<int> bytes, int width, int polynomial) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte << (width - 8);
    for (var bit = 0; bit < 8; bit++) {
      crc =
          ((crc << 1) ^ (crc & (1 << (width - 1)) != 0 ? polynomial : 0)) &
          ((1 << width) - 1);
    }
  }
  return crc;
}

List<int> wavFixture({
  int seconds = 1,
  int sampleRate = 8000,
  int channels = 1,
  int bits = 16,
  int encoding = 1,
}) {
  final size = seconds * sampleRate * channels * (bits ~/ 8);
  return [
    ...'RIFF'.codeUnits,
    ...le32(size + 36),
    ...'WAVE'.codeUnits,
    ...'fmt '.codeUnits,
    ...le32(16),
    ...le16(encoding),
    ...le16(channels),
    ...le32(sampleRate),
    ...le32(sampleRate * channels * (bits ~/ 8)),
    ...le16(channels * (bits ~/ 8)),
    ...le16(bits),
    ...'data'.codeUnits,
    ...le32(size),
    ...List.filled(size, 0),
  ];
}

List<int> be32(int value) => [
  (value >> 24) & 255,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];
List<int> le32(int value) => be32(value).reversed.toList();
List<int> le16(int value) => [value & 255, (value >> 8) & 255];
List<int> atom(String type, List<int> body) => [
  ...be32(body.length + 8),
  ...type.codeUnits,
  ...body,
];

List<int> mp4Fixture({bool video = false, bool lateMoov = false}) {
  final mdhd = atom('mdhd', [
    ...List.filled(12, 0),
    ...be32(48000),
    ...be32(480000),
    ...List.filled(4, 0),
  ]);
  final hdlr = atom('hdlr', [
    ...List.filled(8, 0),
    ...'soun'.codeUnits,
    ...List.filled(12, 0),
  ]);
  final sample = List<int>.filled(28, 0);
  sample.setRange(16, 18, [0, 2]);
  sample.setRange(18, 20, [0, 16]);
  sample.setRange(24, 28, be32(48000 << 16));
  final stsd = atom('stsd', [
    ...List.filled(4, 0),
    ...be32(1),
    ...atom('mp4a', sample),
  ]);
  final stsz = atom('stsz', [
    ...List.filled(4, 0),
    ...be32(1000),
    ...be32(160),
  ]);
  final stts = atom('stts', [
    ...List.filled(4, 0),
    ...be32(1),
    ...be32(160),
    ...be32(3000),
  ]);
  final audio = atom(
    'trak',
    atom('mdia', [
      ...mdhd,
      ...hdlr,
      ...atom('minf', atom('stbl', [...stsd, ...stsz, ...stts])),
    ]),
  );
  final videoTrack = atom(
    'trak',
    atom(
      'mdia',
      atom('hdlr', [
        ...List.filled(8, 0),
        ...'vide'.codeUnits,
        ...List.filled(12, 0),
      ]),
    ),
  );
  final moov = atom('moov', [...audio, if (video) ...videoTrack]);
  final ftyp = atom('ftyp', [
    ...'M4A '.codeUnits,
    ...List.filled(4, 0),
    ...'isom'.codeUnits,
  ]);
  final mdat = atom('mdat', Uint8List(lateMoov ? 300000 : 160000));
  return [...ftyp, if (!lateMoov) ...moov, ...mdat, if (lateMoov) ...moov];
}
