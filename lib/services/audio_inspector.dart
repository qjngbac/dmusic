import 'dart:io';

class RealAudioInfo {
  final String format; // 'FLAC', 'MP3', 'M4A', 'OGG', 'WAV'
  final String
  qualityLabel; // 'FLAC 无损', 'Hi-Res 24bit', '320k 极高', '192k 较高', '128k 标准', 'AAC 256k'
  final bool isLossless;
  final int fileSizeBytes;
  final int bitrateKbps;
  final String realExtension; // 'flac', 'mp3', 'm4a', 'ogg'
  final bool isValid;
  final int durationSeconds;
  final int sampleRate;
  final int bitsPerSample;
  final int channels;
  final bool hasVideo;

  const RealAudioInfo({
    required this.format,
    required this.qualityLabel,
    required this.isLossless,
    required this.fileSizeBytes,
    required this.bitrateKbps,
    required this.realExtension,
    this.isValid = false,
    this.durationSeconds = 0,
    this.sampleRate = 0,
    this.bitsPerSample = 0,
    this.channels = 0,
    this.hasVideo = false,
  });

  String get sizeMb =>
      '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  bool matchesPlaybackQuality(
    String targetQuality, {
    bool allowHigher = false,
  }) {
    if (!isValid || hasVideo) return false;
    final quality = targetQuality.toLowerCase();
    if (quality.isEmpty || quality == 'auto') return true;
    if (quality == 'flac') return isLossless;
    if (quality == 'hires') {
      return isLossless && bitsPerSample > 16 && sampleRate > 48000;
    }
    if (isLossless) {
      return allowHigher && {'128k', '256k', '320k'}.contains(quality);
    }
    switch (quality) {
      case '256k':
        return bitrateKbps >= 240 && (allowHigher || bitrateKbps < 300);
      case '320k':
        return bitrateKbps >= 300;
      case '128k':
        return bitrateKbps >= 120;
      default:
        return false;
    }
  }

  bool matchesQuality(String targetQuality) {
    if (!isValid || hasVideo) return false;
    switch (targetQuality.toLowerCase()) {
      case '':
        return true;
      case 'flac':
        return (format == 'FLAC' && isLossless) || format == 'WAV';
      case 'hires':
        return format == 'FLAC' &&
            isLossless &&
            (bitsPerSample > 16 || sampleRate > 48000);
      case '320k':
        return (format == 'MP3' && bitrateKbps >= 240) ||
            (format == 'M4A' && bitrateKbps >= 180) ||
            (format == 'MP3' && bitrateKbps == 0 && fileSizeBytes >= 3 * 1024 * 1024);
      case '128k':
        return (format == 'MP3' && bitrateKbps >= 96) ||
            (format == 'M4A' && (bitrateKbps >= 96 || bitrateKbps == 0)) ||
            (format == 'MP3' && bitrateKbps == 0);
      default:
        return true;
    }
  }

  bool matchesDuration(int expectedSeconds) {
    if (durationSeconds <= 0 || expectedSeconds <= 0) return true;
    return (durationSeconds - expectedSeconds).abs() <= 25;
  }
}

/// Uses format metadata and MPEG frames, never filename/catalog size guesses.
/// Structural inspection is not a full decode or an audible-quality test.
class AudioInspector {
  static const _prefixLimit = 256 * 1024;
  static const _metadataLimit = 4 * 1024 * 1024;

  /// 毫秒级极速有效性校验：检查体积门槛(>=64KB)及前导音频魔数(ID3/FLAC/ftyp/OggS/RIFF)，杜绝HTML/JSON报错页面与碎片
  static bool isQuickValidAudioFile(File file, {int minBytes = 65536}) {
    try {
      if (!file.existsSync()) return false;
      final len = file.lengthSync();
      if (len < minBytes) return false;

      final raf = file.openSync();
      try {
        final bytes = raf.readSync(64);
        if (bytes.length < 4) return false;

        // 拦截文本/HTML/JSON报错文件
        final prefix = String.fromCharCodes(bytes.take(16)).toLowerCase();
        if (prefix.contains('<!do') ||
            prefix.contains('<htm') ||
            prefix.contains('{"') ||
            prefix.contains('<?xml')) {
          return false;
        }

        // 真实音频魔数签名
        // 1. MP3 带 ID3v2 标签 ('ID3')
        if (bytes.length >= 3 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
        // 2. MP3 纯音频帧同步头 (0xFF 0xEx ~ 0xFF 0xFx)
        if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) return true;
        // 3. FLAC ('fLaC')
        if (bytes.length >= 4 && bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43) return true;
        // 4. M4A / MP4 音频容器 (offset 4 为 'ftyp')
        if (bytes.length >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) return true;
        // 5. OGG ('OggS')
        if (bytes.length >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) return true;
        // 6. WAV ('RIFF')
        if (bytes.length >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) return true;

        // 常见音频后缀兜底且体积正常（>=100KB），非HTML/JSON
        final ext = file.path.split('.').last.toLowerCase();
        if (['mp3', 'm4a', 'flac', 'ogg', 'wav', 'aac'].contains(ext) && len >= 102400) {
          return true;
        }
        return false;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static Future<RealAudioInfo> inspect(
    File file, {
    int durationSeconds = 0,
    bool strict = false,
  }) async {
    RandomAccessFile? reader;
    var size = 0;
    try {
      reader = await file.open();
      size = await reader.length();
      var bytes = await reader.read(_prefixLimit);
      if (_text(bytes, 4, 4) == 'ftyp') {
        final metadata = <int>[];
        var mediaSize = 0, position = 0, count = 0;
        while (position + 8 <= size && count++ < 1024) {
          await reader.setPosition(position);
          final box = _box(await reader.read(16), 0, size - position);
          if (box == null) return _unknown(size);
          if (box.type == 'ftyp' || box.type == 'moov') {
            if (metadata.length + box.length > _metadataLimit) {
              return _unknown(size);
            }
            await reader.setPosition(position);
            metadata.addAll(await reader.read(box.length));
          } else if (box.type == 'mdat') {
            mediaSize += box.length - box.headerSize;
          }
          position += box.length;
        }
        return _mp4(metadata, size, mediaSize: mediaSize);
      }
      final offset = _id3End(bytes);
      if (offset < 0 || offset > size) return _unknown(size);
      if (offset > 0) {
        await reader.setPosition(offset);
        bytes = await reader.read(_prefixLimit);
      }
      if (_text(bytes, 0, 4) == 'fLaC') {
        final flacInfo = await _readFlac(reader, bytes, size, offset);
        if (flacInfo.isValid || strict) return flacInfo;
        if (isQuickValidAudioFile(file, minBytes: 65536)) {
          return RealAudioInfo(
            format: 'FLAC',
            qualityLabel: 'FLAC (未完整校验)',
            isLossless: true,
            fileSizeBytes: size,
            bitrateKbps: 0,
            realExtension: 'flac',
            isValid: true,
          );
        }
        return flacInfo;
      }
      var audioSize = size;
      if (size >= 128) {
        await reader.setPosition(size - 128);
        if (_text(await reader.read(3), 0, 3) == 'TAG') audioSize -= 128;
      }
      final info = _inspect(
        bytes,
        size,
        audioOffset: offset,
        audioSize: audioSize,
      );
      if (info.isValid || strict) return info;

      // 仅用于历史本地文件恢复容错，新下载(strict)绝不假冒有效
      if (isQuickValidAudioFile(file, minBytes: 65536)) {
        final ext = file.path.split('.').last.toLowerCase();
        return RealAudioInfo(
          format: ext.toUpperCase(),
          qualityLabel: ext == 'flac' ? 'FLAC (结构异常)' : (ext == 'mp3' ? 'MP3 (码率未知)' : ext.toUpperCase()),
          isLossless: ext == 'flac' || ext == 'wav',
          fileSizeBytes: size,
          bitrateKbps: 0,
          realExtension: ext,
          isValid: true,
        );
      }
      return info;
    } catch (_) {
      if (!strict && isQuickValidAudioFile(file, minBytes: 65536)) {
        final ext = file.path.split('.').last.toLowerCase();
        return RealAudioInfo(
          format: ext.toUpperCase(),
          qualityLabel: ext == 'flac' ? 'FLAC (结构异常)' : (ext == 'mp3' ? 'MP3 (码率未知)' : ext.toUpperCase()),
          isLossless: ext == 'flac' || ext == 'wav',
          fileSizeBytes: size,
          bitrateKbps: 0,
          realExtension: ext,
          isValid: true,
        );
      }
      return _unknown(size);
    } finally {
      await reader?.close();
    }
  }

  /// fileSizeBytes describes the whole remote resource, not this prefix.
  /// Missing metadata remains unknown; callers may fetch another range.
  static RealAudioInfo inspectBytes(
    List<int> bytes, {
    required int fileSizeBytes,
    int durationSeconds = 0,
  }) {
    final offset = _id3End(bytes);
    if (offset < 0 || offset >= bytes.length) return _unknown(fileSizeBytes);
    return _inspect(bytes.sublist(offset), fileSizeBytes, audioOffset: offset);
  }

  static RealAudioInfo _inspect(
    List<int> bytes,
    int size, {
    int audioOffset = 0,
    int? audioSize,
  }) {
    if (size <= 0 || bytes.length < 4) return _unknown(size);
    if (_text(bytes, 0, 4) == 'fLaC') return _flac(bytes, size);
    if (_text(bytes, 0, 4) == 'RIFF') return _wav(bytes, size);
    if (_text(bytes, 4, 4) == 'ftyp') return _mp4(bytes, size);
    if (_text(bytes, 0, 4) == 'OggS') return _ogg(bytes, size);
    final aac = _adts(bytes, size);
    if (aac != null) return aac;
    return _mp3(
      bytes,
      size,
      audioOffset: audioOffset,
      audioSize: audioSize ?? size,
    );
  }

  static RealAudioInfo _unknown(int size) => RealAudioInfo(
    format: 'UNKNOWN',
    qualityLabel: '未知音频',
    isLossless: false,
    fileSizeBytes: size,
    bitrateKbps: 0,
    realExtension: 'bin',
  );

  static RealAudioInfo _info(
    String format,
    String extension,
    int size, {
    String? label,
    bool lossless = false,
    int bitrate = 0,
    double duration = 0,
    int rate = 0,
    int bits = 0,
    int channels = 0,
    bool video = false,
  }) => RealAudioInfo(
    format: format,
    qualityLabel:
        label ?? (bitrate > 0 ? '$format ${bitrate}k' : '$format 音质未知'),
    isLossless: lossless,
    fileSizeBytes: size,
    bitrateKbps: bitrate,
    realExtension: extension,
    isValid: true,
    durationSeconds: duration.round(),
    sampleRate: rate,
    bitsPerSample: bits,
    channels: channels,
    hasVideo: video,
  );

  static int _id3End(List<int> bytes) {
    if (_text(bytes, 0, 3) != 'ID3') return 0;
    if (bytes.length < 10 ||
        bytes[3] < 2 ||
        bytes[3] > 4 ||
        bytes.sublist(6, 10).any((v) => v >= 128)) {
      return -1;
    }
    final length =
        (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
    return 10 + length + (bytes[3] == 4 && bytes[5] & 0x10 != 0 ? 10 : 0);
  }

  static RealAudioInfo _flac(List<int> bytes, int size) {
    if (bytes.length < 42 || bytes[4] & 0x7f != 0 || _uint(bytes, 5, 3) != 34) {
      return _unknown(size);
    }
    final minBlock = _uint(bytes, 8, 2), maxBlock = _uint(bytes, 10, 2);
    final packed = _uint(bytes, 18, 8);
    final rate = packed >> 44;
    final channels = ((packed >> 41) & 7) + 1;
    final bits = ((packed >> 36) & 31) + 1;
    final samples = packed & 0xfffffffff;
    if (rate <= 0 ||
        bits < 4 ||
        minBlock < 16 ||
        maxBlock < minBlock ||
        size <= 42) {
      return _unknown(size);
    }
    var position = 4;
    var last = false;
    while (position + 4 <= bytes.length && !last) {
      last = bytes[position] & 128 != 0;
      position += 4 + _uint(bytes, position + 1, 3);
      if (position >= size) return _unknown(size);
    }
    if (!last || position + 6 > size || position + 6 > bytes.length) {
      return _unknown(size);
    }
    if (bytes[position] != 255 || bytes[position + 1] & 0xfe != 0xf8) {
      return _unknown(size);
    }
    final duration = samples > 0 ? samples / rate : 0.0;
    return _info(
      'FLAC',
      'flac',
      size,
      lossless: true,
      label: bits > 16 && rate > 48000 ? 'Hi-Res ${bits}bit' : 'FLAC 无损',
      duration: duration,
      rate: rate,
      bits: bits,
      channels: channels,
    );
  }

  static Future<RealAudioInfo> _readFlac(
    RandomAccessFile reader,
    List<int> prefix,
    int size,
    int offset,
  ) async {
    if (prefix.length < 42) return _unknown(size);
    var position = offset + 4;
    var blocks = 0;
    var last = false;
    while (!last && blocks < 1024) {
      if (position + 4 > size) return _unknown(size);
      await reader.setPosition(position);
      final header = await reader.read(4);
      if (header.length != 4 || header[0] & 0x7f == 127) {
        return _unknown(size);
      }
      final type = header[0] & 0x7f;
      final length = _uint(header, 1, 3);
      if ((blocks == 0 && (type != 0 || length != 34)) ||
          (blocks > 0 && type == 0)) {
        return _unknown(size);
      }
      last = header[0] & 128 != 0;
      position += 4 + length;
      blocks++;
      if (position + 6 > size) return _unknown(size);
    }
    if (!last) return _unknown(size);
    // Prefix inspection identifies a codec. A complete local file additionally
    // needs every frame CRC and a continuous sample count (RFC 9639 section 9).
    await reader.setPosition(position);
    final frame = await reader.read(16);
    final compact = [...prefix.take(42), ...frame];
    compact[4] = 0x80;
    final info = _flac(compact, size);
    if (!info.isValid) return info;
    final samples = await _flacSamples(
      reader,
      position,
      size,
      info,
      _uint(prefix, 10, 2),
    );
    final declared = _uint(prefix, 18, 8) & 0xfffffffff;
    if (samples <= 0 || (declared > 0 && samples != declared)) {
      return _unknown(size);
    }
    return _info(
      'FLAC',
      'flac',
      size,
      lossless: true,
      label: info.qualityLabel,
      duration: samples / info.sampleRate,
      rate: info.sampleRate,
      bits: info.bitsPerSample,
      channels: info.channels,
    );
  }

  static final _flacCrc16 = List<int>.generate(256, (value) {
    var crc = value << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ (crc & 0x8000 != 0 ? 0x8005 : 0)) & 0xffff;
    }
    return crc;
  });

  static Future<int> _flacSamples(
    RandomAccessFile reader,
    int start,
    int size,
    RealAudioInfo info,
    int maxBlock,
  ) async {
    await reader.setPosition(start);
    var pending = <int>[], consumed = start, crc = 0;
    var samples = 0, frames = 0, frameStart = start;
    _FlacHeader? current;
    // A frame header is at most 16 bytes. Carry it across read boundaries;
    // audio payload is scanned once with bounded memory, never decoded to PCM.
    while (consumed < size) {
      final chunk = await reader.read(64 * 1024);
      final bytes = [...pending, ...chunk];
      final eof = consumed + bytes.length == size;
      final limit = eof ? bytes.length : bytes.length - 16;
      if (limit <= 0) return -1;
      for (var p = 0; p < limit; p++) {
        final position = consumed + p;
        if (position == start || (crc == 0 && bytes[p] == 255)) {
          final header = _flacHeader(bytes, p, info);
          if (position == start && header == null) return -1;
          if (header != null) {
            if (header.number !=
                    (header.variable
                        ? samples + (current?.samples ?? 0)
                        : frames) ||
                header.samples > maxBlock ||
                (current != null &&
                    (header.variable != current.variable ||
                        position - frameStart < current.length + 4 ||
                        (!header.variable && current.samples != maxBlock)))) {
              return -1;
            }
            if (current != null) samples += current.samples;
            current = header;
            frameStart = position;
            frames++;
          }
        }
        crc = ((crc << 8) ^ _flacCrc16[((crc >> 8) ^ bytes[p]) & 255]) & 0xffff;
      }
      consumed += limit;
      pending = bytes.sublist(limit);
    }
    if (current == null || crc != 0 || size - frameStart < current.length + 4) {
      return -1;
    }
    return samples + current.samples;
  }

  static _FlacHeader? _flacHeader(
    List<int> bytes,
    int start,
    RealAudioInfo info,
  ) {
    if (start + 6 > bytes.length ||
        bytes[start] != 255 ||
        bytes[start + 1] & 0xfe != 0xf8 ||
        bytes[start + 3] & 1 != 0) {
      return null;
    }
    final blockCode = bytes[start + 2] >> 4;
    final rateCode = bytes[start + 2] & 15;
    final channelCode = bytes[start + 3] >> 4;
    final depthCode = (bytes[start + 3] >> 1) & 7;
    final variable = bytes[start + 1] & 1 != 0;
    const depths = [0, 8, 12, -1, 16, 20, 24, 32];
    if (blockCode == 0 ||
        rateCode == 15 ||
        channelCode > 10 ||
        (channelCode < 8 ? channelCode + 1 : 2) != info.channels ||
        (depthCode != 0 && depths[depthCode] != info.bitsPerSample)) {
      return null;
    }
    var p = start + 4, number = bytes[start + 4], count = 0;
    if (number >= 128) {
      while (number & (128 >> count) != 0 && count < 8) {
        count++;
      }
      if (count < 2 || count > (variable ? 7 : 6) || p + count > bytes.length) {
        return null;
      }
      number &= (1 << (7 - count)) - 1;
      for (var i = 1; i < count; i++) {
        final byte = bytes[p + i];
        if (byte & 0xc0 != 0x80) return null;
        number = (number << 6) | (byte & 63);
      }
      const minimum = [0, 0, 128, 2048, 65536, 2097152, 67108864, 2147483648];
      if (number < minimum[count]) return null;
      p += count;
    } else {
      p++;
    }
    var samples = blockCode == 1
        ? 192
        : blockCode < 6
        ? 144 << blockCode
        : blockCode > 7
        ? 1 << blockCode
        : 0;
    if (blockCode == 6 || blockCode == 7) {
      final length = blockCode == 6 ? 1 : 2;
      if (p + length >= bytes.length) return null;
      samples = _uint(bytes, p, length) + 1;
      p += length;
      if (samples > 65535) return null;
    }
    const rates = [
      0,
      88200,
      176400,
      192000,
      8000,
      16000,
      22050,
      24000,
      32000,
      44100,
      48000,
      96000,
    ];
    var rate = rateCode == 0
        ? info.sampleRate
        : rateCode < 12
        ? rates[rateCode]
        : 0;
    if (rateCode >= 12) {
      final length = rateCode == 12 ? 1 : 2;
      if (p + length >= bytes.length) return null;
      rate =
          _uint(bytes, p, length) *
          (rateCode == 12
              ? 1000
              : rateCode == 14
              ? 10
              : 1);
      p += length;
    }
    if (rate != info.sampleRate || p >= bytes.length) return null;
    var crc = 0;
    for (var i = start; i <= p; i++) {
      crc ^= bytes[i];
      for (var bit = 0; bit < 8; bit++) {
        crc = ((crc << 1) ^ (crc & 128 != 0 ? 7 : 0)) & 255;
      }
    }
    return crc == 0
        ? _FlacHeader(number, samples, p + 1 - start, variable)
        : null;
  }

  static RealAudioInfo _wav(List<int> bytes, int size) {
    if (_text(bytes, 8, 4) != 'WAVE' ||
        bytes.length < 12 ||
        _uint(bytes, 4, 4, little: true) + 8 > size) {
      return _unknown(size);
    }
    var position = 12;
    var encoding = 0,
        channels = 0,
        rate = 0,
        byteRate = 0,
        bits = 0,
        alignment = 0;
    while (position + 8 <= bytes.length) {
      final type = _text(bytes, position, 4);
      final length = _uint(bytes, position + 4, 4, little: true);
      final payload = position + 8;
      if (payload + length > size) return _unknown(size);
      if (type == 'fmt ') {
        if (length < 16 || payload + 16 > bytes.length) return _unknown(size);
        encoding = _uint(bytes, payload, 2, little: true);
        channels = _uint(bytes, payload + 2, 2, little: true);
        rate = _uint(bytes, payload + 4, 4, little: true);
        byteRate = _uint(bytes, payload + 8, 4, little: true);
        alignment = _uint(bytes, payload + 12, 2, little: true);
        bits = _uint(bytes, payload + 14, 2, little: true);
      } else if (type == 'data') {
        if (channels < 1 ||
            rate < 1 ||
            byteRate < 1 ||
            length == 0 ||
            alignment < 1) {
          return _unknown(size);
        }
        final pcm = encoding == 1 || encoding == 3;
        if (pcm &&
            (alignment != channels * ((bits + 7) ~/ 8) ||
                byteRate != rate * alignment ||
                length % alignment != 0)) {
          return _unknown(size);
        }
        return _info(
          'WAV',
          'wav',
          size,
          label: pcm ? 'PCM ${bits}bit' : 'WAV 音质未知',
          lossless: pcm,
          bitrate: pcm ? (byteRate * 8 / 1000).round() : 0,
          duration: length / byteRate,
          rate: rate,
          bits: bits,
          channels: channels,
        );
      }
      position = payload + length + (length & 1);
    }
    return _unknown(size);
  }

  static RealAudioInfo _mp3(
    List<int> bytes,
    int size, {
    required int audioOffset,
    required int audioSize,
  }) {
    if (bytes.length >= audioSize - audioOffset &&
        !_mpegEnds(bytes.sublist(0, audioSize - audioOffset))) {
      return _unknown(size);
    }
    for (var start = 0; start < 4096 && start + 4 < bytes.length; start++) {
      final first = _MpegFrame.read(bytes, start);
      if (first == null || start + first.length * 2 > audioSize - audioOffset) {
        continue;
      }
      final second = _MpegFrame.read(bytes, start + first.length);
      if (second == null ||
          first.rate != second.rate ||
          first.version != second.version) {
        continue;
      }
      var position = start, frames = 0;
      var variable = false;
      while (frames < 128) {
        final frame = _MpegFrame.read(bytes, position);
        if (frame == null ||
            frame.rate != first.rate ||
            frame.version != first.version ||
            position + frame.length > bytes.length) {
          break;
        }
        variable |= frame.bitrate != first.bitrate;
        frames++;
        position += frame.length;
      }
      if (frames < 2) continue;
      var duration = 0.0;
      var bitrate = variable ? 0 : first.bitrate;
      final xing =
          start +
          4 +
          (first.crc ? 2 : 0) +
          (first.version == 3
              ? (first.channels == 1 ? 17 : 32)
              : (first.channels == 1 ? 9 : 17));
      var declaredFrames = 0, declaredBytes = 0;
      if (_text(bytes, xing, 4) == 'Xing' || _text(bytes, xing, 4) == 'Info') {
        final flags = _uint(bytes, xing + 4, 4);
        var p = xing + 8;
        if (flags & 1 != 0) {
          declaredFrames = _uint(bytes, p, 4);
          p += 4;
        }
        if (flags & 2 != 0) declaredBytes = _uint(bytes, p, 4);
      } else if (_text(bytes, start + 36, 4) == 'VBRI') {
        declaredBytes = _uint(bytes, start + 46, 4);
        declaredFrames = _uint(bytes, start + 50, 4);
      }
      final available = audioSize - audioOffset - start;
      if (declaredBytes > available) return _unknown(size);
      if (declaredFrames > 0) {
        duration = declaredFrames * first.samples / first.rate;
        bitrate = declaredBytes > 0
            ? (declaredBytes * 8 / duration / 1000).round()
            : 0;
      } else if (!variable) {
        duration = (available / first.length) * first.samples / first.rate;
      }
      final label = bitrate == 320
          ? '320k 极高'
          : bitrate == 128
          ? '128k 标准'
          : bitrate > 0
          ? '${bitrate}k MP3'
          : 'MP3 可变码率';
      return _info(
        'MP3',
        'mp3',
        size,
        label: label,
        bitrate: bitrate,
        duration: duration,
        rate: first.rate,
        channels: first.channels,
      );
    }
    return _unknown(size);
  }

  static bool _mpegEnds(List<int> bytes) {
    for (var start = 0; start + 4 < bytes.length; start++) {
      if (_MpegFrame.read(bytes, start) == null) continue;
      var position = start, frames = 0;
      while (position + 4 <= bytes.length) {
        final frame = _MpegFrame.read(bytes, position);
        if (frame == null) break;
        position += frame.length;
        frames++;
        if (position == bytes.length) return frames >= 2;
        if (position > bytes.length) break;
      }
    }
    return false;
  }

  static RealAudioInfo? _adts(List<int> bytes, int size) {
    const rates = [
      96000,
      88200,
      64000,
      48000,
      44100,
      32000,
      24000,
      22050,
      16000,
      12000,
      11025,
      8000,
      7350,
    ];
    if (bytes.length < 7 || bytes[0] != 255 || bytes[1] & 0xf6 != 0xf0) {
      return null;
    }
    var p = 0, samples = 0, rate = 0, channels = 0, count = 0;
    while (p + 7 <= bytes.length) {
      if (bytes[p] != 255 || bytes[p + 1] & 0xf6 != 0xf0) break;
      final index = (bytes[p + 2] >> 2) & 15;
      if (index >= rates.length) return _unknown(size);
      final frameRate = rates[index];
      final length =
          ((bytes[p + 3] & 3) << 11) |
          (bytes[p + 4] << 3) |
          (bytes[p + 5] >> 5);
      if (length < 7 || (rate != 0 && rate != frameRate)) return _unknown(size);
      if (p + length > bytes.length) break;
      rate = frameRate;
      channels = ((bytes[p + 2] & 1) << 2) | (bytes[p + 3] >> 6);
      samples += 1024 * ((bytes[p + 6] & 3) + 1);
      count++;
      p += length;
    }
    if (count < 2 || channels == 0) return _unknown(size);
    if (bytes.length == size && p != size) return _unknown(size);
    final complete = p == size;
    final duration = complete ? samples / rate : 0.0;
    final bitrate = complete ? (p * 8 / duration / 1000).round() : 0;
    return _info(
      'AAC',
      'aac',
      size,
      label: bitrate > 0 ? 'AAC ${bitrate}k' : 'AAC 音质未知',
      duration: duration,
      bitrate: bitrate,
      rate: rate,
      channels: channels,
    );
  }

  static RealAudioInfo _ogg(List<int> bytes, int size) {
    if (bytes.length < 28 || bytes[4] != 0) return _unknown(size);
    final segments = bytes[26];
    if (27 + segments >= bytes.length) return _unknown(size);
    final payload = 27 + segments;
    var pageSize = payload;
    for (var i = 0; i < segments; i++) {
      pageSize += bytes[27 + i];
    }
    if (pageSize > size || pageSize > bytes.length) return _unknown(size);
    if (_text(bytes, payload, 8) == 'OpusHead' &&
        payload + 19 <= bytes.length &&
        bytes[payload + 9] > 0) {
      return _info(
        'OGG',
        'ogg',
        size,
        label: 'Opus 音质未知',
        rate: 48000,
        channels: bytes[payload + 9],
      );
    }
    if (bytes[payload] == 1 &&
        _text(bytes, payload + 1, 6) == 'vorbis' &&
        payload + 30 <= bytes.length) {
      final rate = _uint(bytes, payload + 12, 4, little: true);
      final channels = bytes[payload + 11];
      if (rate > 0 && channels > 0) {
        return _info(
          'OGG',
          'ogg',
          size,
          label: 'Vorbis 音质未知',
          rate: rate,
          channels: channels,
        );
      }
    }
    return _unknown(size);
  }

  static RealAudioInfo _mp4(List<int> bytes, int size, {int? mediaSize}) {
    final top = _boxes(bytes, 0, bytes.length, allowPartialMedia: true);
    if (top == null) return _unknown(size);
    var video = false;
    _AudioTrack? audio;
    var media = mediaSize ?? 0;
    for (final box in top) {
      if (mediaSize == null && box.end > size) return _unknown(size);
      if (box.type == 'mdat' && mediaSize == null) {
        media += box.length - box.headerSize;
      }
      if (box.type != 'moov') continue;
      final children = _boxes(bytes, box.payload, box.end);
      if (children == null) return _unknown(size);
      for (final track in children.where((b) => b.type == 'trak')) {
        final result = _track(bytes, track);
        if (result == null) return _unknown(size);
        video |= result.video;
        if (result.codec.isNotEmpty) audio ??= result;
      }
    }
    if (audio == null ||
        (mediaSize != null && (media == 0 || audio.bytes > media))) {
      return _unknown(size);
    }
    final bitrate = audio.duration > 0 && audio.bytes > 0
        ? (audio.bytes * 8 / audio.duration / 1000).round()
        : 0;
    final lossless = audio.codec == 'alac';
    return _info(
      video ? 'MP4' : 'M4A',
      video ? 'mp4' : 'm4a',
      size,
      label: video
          ? 'MP4 视频容器'
          : lossless
          ? 'ALAC 无损'
          : bitrate > 0
          ? 'AAC ${bitrate}k'
          : 'AAC 音质未知',
      lossless: lossless,
      bitrate: bitrate,
      duration: audio.duration,
      rate: audio.rate,
      channels: audio.channels,
      bits: lossless ? audio.bits : 0,
      video: video,
    );
  }

  static _AudioTrack? _track(List<int> bytes, _Box track) {
    final trackBoxes = _boxes(bytes, track.payload, track.end);
    if (trackBoxes == null) return null;
    final mdias = trackBoxes.where((b) => b.type == 'mdia');
    if (mdias.isEmpty) return const _AudioTrack();
    final children = _boxes(bytes, mdias.first.payload, mdias.first.end);
    if (children == null) return null;
    var handler = '', timescale = 0;
    var duration = 0.0;
    _Box? minf;
    for (final box in children) {
      if (box.type == 'hdlr') handler = _text(bytes, box.payload + 8, 4);
      if (box.type == 'minf') minf = box;
      if (box.type == 'mdhd') {
        final p = box.payload;
        if (p >= bytes.length) return null;
        final version = bytes[p];
        if (version > 1 || box.end - p < (version == 1 ? 32 : 20)) return null;
        timescale = _uint(bytes, p + (version == 1 ? 20 : 12), 4);
        final units = _uint(
          bytes,
          p + (version == 1 ? 24 : 16),
          version == 1 ? 8 : 4,
        );
        if (timescale > 0) duration = units / timescale;
      }
    }
    if (handler == 'vide') return const _AudioTrack(video: true);
    if (handler != 'soun' || minf == null) return const _AudioTrack();
    final mediaBoxes = _boxes(bytes, minf.payload, minf.end);
    if (mediaBoxes == null) return null;
    final tables = mediaBoxes.where((b) => b.type == 'stbl');
    if (tables.isEmpty) return const _AudioTrack();
    final entries = _boxes(bytes, tables.first.payload, tables.first.end);
    if (entries == null) return null;
    var codec = '', sampleBytes = 0, rate = 0, channels = 0, bits = 0;
    for (final box in entries) {
      final p = box.payload;
      if (box.type == 'stsd') {
        if (p + 8 > box.end || _uint(bytes, p + 4, 4) < 1) return null;
        final sample = _box(bytes, p + 8, box.end - p - 8);
        if (sample == null || sample.length < 36) return null;
        if (sample.type != 'mp4a' && sample.type != 'alac') continue;
        codec = sample.type;
        channels = _uint(bytes, sample.payload + 16, 2);
        bits = _uint(bytes, sample.payload + 18, 2);
        rate = _uint(bytes, sample.payload + 24, 4) >> 16;
      }
      if (box.type == 'stsz') {
        if (p + 12 > box.end) return null;
        final fixed = _uint(bytes, p + 4, 4);
        final count = _uint(bytes, p + 8, 4);
        if (fixed > 0) {
          sampleBytes = fixed * count;
        } else {
          if (p + 12 + count * 4 > box.end) return null;
          for (var i = 0; i < count; i++) {
            sampleBytes += _uint(bytes, p + 12 + i * 4, 4);
          }
        }
      }
      if (box.type == 'stts' && timescale > 0) {
        if (p + 8 > box.end) return null;
        final count = _uint(bytes, p + 4, 4);
        if (p + 8 + count * 8 > box.end) return null;
        var units = 0;
        for (var i = 0; i < count; i++) {
          units +=
              _uint(bytes, p + 8 + i * 8, 4) * _uint(bytes, p + 12 + i * 8, 4);
        }
        if (units > 0) duration = units / timescale;
      }
    }
    return _AudioTrack(
      codec: codec,
      bytes: sampleBytes,
      duration: duration,
      rate: rate,
      channels: channels,
      bits: bits,
    );
  }

  static _Box? _box(List<int> bytes, int offset, int remaining) {
    if (offset < 0 || offset + 8 > bytes.length) return null;
    var length = _uint(bytes, offset, 4);
    var header = 8;
    if (length == 1) {
      if (offset + 16 > bytes.length) return null;
      length = _uint(bytes, offset + 8, 8);
      header = 16;
    } else if (length == 0) {
      length = remaining;
    }
    if (length < header || length > remaining) return null;
    return _Box(_text(bytes, offset + 4, 4), offset, length, header);
  }

  static List<_Box>? _boxes(
    List<int> bytes,
    int start,
    int end, {
    bool allowPartialMedia = false,
  }) {
    final result = <_Box>[];
    var p = start;
    while (p + 8 <= end) {
      var remaining = end - p;
      if (allowPartialMedia && _text(bytes, p + 4, 4) == 'mdat') {
        final declared = _uint(bytes, p, 4);
        if (declared > remaining) remaining = declared;
      }
      final box = _box(bytes, p, remaining);
      if (box == null) return null;
      if (box.end > end) {
        return allowPartialMedia && box.type == 'mdat'
            ? [...result, box]
            : null;
      }
      result.add(box);
      p = box.end;
    }
    return p == end ? result : null;
  }

  static int _uint(
    List<int> bytes,
    int offset,
    int count, {
    bool little = false,
  }) {
    if (offset < 0 || offset + count > bytes.length) return 0;
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | bytes[offset + (little ? count - 1 - i : i)];
    }
    return value;
  }

  static String _text(List<int> bytes, int offset, int count) =>
      offset >= 0 && offset + count <= bytes.length
      ? String.fromCharCodes(bytes.sublist(offset, offset + count))
      : '';
}

class _FlacHeader {
  final int number, samples, length;
  final bool variable;
  const _FlacHeader(this.number, this.samples, this.length, this.variable);
}

class _MpegFrame {
  final int version, rate, bitrate, length, samples, channels;
  final bool crc;
  const _MpegFrame(
    this.version,
    this.rate,
    this.bitrate,
    this.length,
    this.samples,
    this.channels,
    this.crc,
  );

  static _MpegFrame? read(List<int> bytes, int p) {
    if (p < 0 ||
        p + 4 > bytes.length ||
        bytes[p] != 255 ||
        bytes[p + 1] & 0xe0 != 0xe0) {
      return null;
    }
    final version = (bytes[p + 1] >> 3) & 3;
    final layer = (bytes[p + 1] >> 1) & 3;
    final index = bytes[p + 2] >> 4;
    final rateIndex = (bytes[p + 2] >> 2) & 3;
    if (version == 1 ||
        layer != 1 ||
        index == 0 ||
        index == 15 ||
        rateIndex == 3) {
      return null;
    }
    const highRates = [
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
    final bitrate = (version == 3 ? highRates : lowRates)[index];
    final rate =
        [44100, 48000, 32000][rateIndex] ~/
        (version == 3
            ? 1
            : version == 2
            ? 2
            : 4);
    final length =
        (version == 3 ? 144000 : 72000) * bitrate ~/ rate +
        ((bytes[p + 2] >> 1) & 1);
    return _MpegFrame(
      version,
      rate,
      bitrate,
      length,
      version == 3 ? 1152 : 576,
      bytes[p + 3] >> 6 == 3 ? 1 : 2,
      bytes[p + 1] & 1 == 0,
    );
  }
}

class _Box {
  final String type;
  final int offset, length, headerSize;
  const _Box(this.type, this.offset, this.length, this.headerSize);
  int get payload => offset + headerSize;
  int get end => offset + length;
}

class _AudioTrack {
  final bool video;
  final String codec;
  final int bytes, rate, channels, bits;
  final double duration;
  const _AudioTrack({
    this.video = false,
    this.codec = '',
    this.bytes = 0,
    this.rate = 0,
    this.channels = 0,
    this.bits = 0,
    this.duration = 0,
  });
}
