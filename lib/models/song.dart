import 'dart:io';

class Song {
  static const _unset = Object();
  static int? _parseInt(Object? value) => value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  final String id;
  final String name;
  final String artist;
  final String album;
  final String source;
  String quality;
  String size;
  final int durationSeconds;
  final String coverUrl;
  String? audioUrl;
  String? lyric;
  String? transLyric;
  bool isLossless;
  String? localFilePath;
  String? lrcPath;
  int fileSizeBytes;
  DateTime? downloadTime;
  int? audioUrlTimestamp;
  String? audioUrlQuality;
  String? audioUrlSource;
  final String? losslessId;
  final String? highQualityId;

  Song({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.source,
    this.quality = '音质待检测',
    this.size = '',
    this.durationSeconds = 0,
    this.coverUrl = '',
    this.audioUrl,
    this.lyric,
    this.transLyric,
    this.isLossless = false,
    this.localFilePath,
    this.lrcPath,
    this.fileSizeBytes = 0,
    this.downloadTime,
    this.audioUrlTimestamp,
    this.audioUrlQuality,
    this.audioUrlSource,
    this.losslessId,
    this.highQualityId,
  });

  bool get isDownloaded => localFilePath != null && localFilePath!.isNotEmpty;

  String get durationString {
    final m = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 智能计算单曲体积预估
  String get estimatedSizeStr {
    if (fileSizeBytes > 0) {
      final mb = fileSizeBytes / (1024 * 1024);
      return '${mb.toStringAsFixed(1)}MB';
    }
    if (localFilePath != null && localFilePath!.isNotEmpty) {
      try {
        final f = File(localFilePath!);
        if (f.existsSync()) {
          final bytes = f.lengthSync();
          if (bytes > 0) {
            fileSizeBytes = bytes;
            final mb = bytes / (1024 * 1024);
            return '${mb.toStringAsFixed(1)}MB';
          }
        }
      } catch (_) {}
    }
    if (size.isNotEmpty) return size;
    final dur = durationSeconds > 0 ? durationSeconds : 240; // 默认以4分钟估算
    final qLower = quality.toLowerCase();
    if (qLower.contains('hi-res') || qLower.contains('母带')) {
      final mb = (dur * 280) / 1024;
      return '${mb.toStringAsFixed(1)}MB';
    } else if (isLossless || qLower.contains('flac') || qLower.contains('无损')) {
      final mb = (dur * 115) / 1024;
      return '${mb.toStringAsFixed(1)}MB';
    } else if (qLower.contains('320k') || qLower.contains('极高')) {
      final mb = (dur * 40) / 1024;
      return '${mb.toStringAsFixed(1)}MB';
    } else if (qLower.contains('192k')) {
      final mb = (dur * 24) / 1024;
      return '${mb.toStringAsFixed(1)}MB';
    } else {
      final mb = (dur * 16) / 1024;
      return '${mb.toStringAsFixed(1)}MB';
    }
  }

  /// 智能计算单曲体积数值（MB）
  double get estimatedSizeMB {
    if (fileSizeBytes > 0) {
      return fileSizeBytes / (1024 * 1024);
    }
    if (localFilePath != null && localFilePath!.isNotEmpty) {
      try {
        final f = File(localFilePath!);
        if (f.existsSync()) {
          final bytes = f.lengthSync();
          if (bytes > 0) {
            fileSizeBytes = bytes;
            return bytes / (1024 * 1024);
          }
        }
      } catch (_) {}
    }
    if (size.isNotEmpty) {
      final clean = size.toUpperCase().replaceAll('MB', '').replaceAll('M', '').replaceAll('KB', '').replaceAll('K', '').trim();
      final val = double.tryParse(clean);
      if (val != null) {
        if (size.toUpperCase().contains('K')) return val / 1024;
        return val;
      }
    }
    final dur = durationSeconds > 0 ? durationSeconds : 240; // 默认以4分钟估算
    final qLower = quality.toLowerCase();
    if (qLower.contains('hi-res') || qLower.contains('母带')) {
      return (dur * 280) / 1024;
    } else if (isLossless || qLower.contains('flac') || qLower.contains('无损')) {
      return (dur * 115) / 1024;
    } else if (qLower.contains('320k') || qLower.contains('极高')) {
      return (dur * 40) / 1024;
    } else if (qLower.contains('192k')) {
      return (dur * 24) / 1024;
    } else {
      return (dur * 16) / 1024;
    }
  }

  /// 是否为纯伴奏 / 伴奏版本
  bool get isInstrumental {
    final lower = name.toLowerCase();
    return lower.contains('伴奏') || lower.contains('instrumental') || lower.contains('karaoke') || lower.contains('inst.');
  }

  /// 是否为 Live 现场版本
  bool get isLive {
    final lower = name.toLowerCase();
    return lower.contains('live') ||
        lower.contains('现场') ||
        lower.contains('演唱会') ||
        lower.contains('音乐会') ||
        lower.contains('巡演') ||
        lower.contains('巡回') ||
        lower.contains('专场') ||
        lower.contains('公演');
  }

  /// 获取去除中英文各类括号修饰后的纯净主歌名（例如消除 (Live)、（伴奏）、[2023重唱版]）
  String get baseName => cleanTitle(name);

  /// 清洗去除歌名中的括号修饰（支持各种全半角中英文括号、中括号、方头括号）
  static String cleanTitle(String input) {
    var cleaned = input
        .replaceAll(RegExp(r'[\(\（\[【][^\)\）\]】]*[\)\）\]】]'), '')
        .replaceAll(RegExp(r'[\(\（\[【][^\)\）\]】]*$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toLowerCase();
    return cleaned.isNotEmpty ? cleaned : input.trim().toLowerCase();
  }

  /// 歌手归一化比对（兼容多位歌手并列、斜杠、逗号与&符号）
  static bool isArtistMatch(String a1, String a2) {
    final clean1 = a1.trim().toLowerCase();
    final clean2 = a2.trim().toLowerCase();
    if (clean1.isEmpty || clean2.isEmpty || clean1 == '未知歌手' || clean2 == '未知歌手') return false;
    if (clean1 == clean2) return true;
    final parts1 = clean1.split(RegExp(r'[,;/、&]+')).map((s) => s.trim()).where((s) => s.isNotEmpty && s != '未知歌手').toSet();
    final parts2 = clean2.split(RegExp(r'[,;/、&]+')).map((s) => s.trim()).where((s) => s.isNotEmpty && s != '未知歌手').toSet();
    return parts1.intersection(parts2).isNotEmpty;
  }

  /// 音质权重等级 (1: 128k/标准, 2: 192k/高, 3: 320k/极高, 4: FLAC/无损, 5: Hi-Res/母带)
  int get qualityRank {
    final q = quality.toLowerCase();
    final ext = (localFilePath != null) ? localFilePath!.toLowerCase() : '';
    if (q.contains('hi-res') || q == 'hr' || q.contains('24bit')) return 5;
    if (isLossless || q.contains('flac') || q.contains('sq') || q.contains('无损') || ext.endsWith('.flac')) return 4;
    if (q.contains('320') || q.contains('hq') || q.contains('极高') || q.contains('高品')) return 3;
    if (q.contains('192') || q.contains('较高')) return 2;
    return 1;
  }

  String get key => '$source::$id';

  bool get isAudioUrlExpired {
    if (audioUrl == null || audioUrl!.isEmpty) return true;
    if (audioUrlTimestamp == null) return true;
    final age = DateTime.now().millisecondsSinceEpoch - audioUrlTimestamp!;
    return age < 0 || age > 15 * 60 * 1000;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'artist': artist,
    'album': album,
    'source': source,
    'quality': quality,
    'size': size,
    'durationSeconds': durationSeconds,
    'coverUrl': coverUrl,
    'audioUrl': audioUrl,
    'lyric': lyric,
    'transLyric': transLyric,
    'isLossless': isLossless,
    'localFilePath': localFilePath,
    'lrcPath': lrcPath,
    'fileSizeBytes': fileSizeBytes,
    'downloadTime': downloadTime?.toIso8601String(),
    'audioUrlTimestamp': audioUrlTimestamp,
    'audioUrlQuality': audioUrlQuality,
    'audioUrlSource': audioUrlSource,
    'losslessId': losslessId,
    'highQualityId': highQualityId,
  };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '未知曲目',
    artist: json['artist']?.toString() ?? '未知歌手',
    album: json['album']?.toString() ?? '',
    source: json['source']?.toString() ?? '网络',
    quality: json['quality']?.toString() ?? '音质待检测',
    size: json['size']?.toString() ?? '',
    durationSeconds: _parseInt(json['durationSeconds']) ?? 0,
    coverUrl: json['coverUrl']?.toString() ?? '',
    audioUrl: json['audioUrl']?.toString(),
    lyric: json['lyric']?.toString(),
    transLyric: json['transLyric']?.toString(),
    isLossless: json['isLossless'] == true,
    localFilePath: json['localFilePath']?.toString(),
    lrcPath: json['lrcPath']?.toString(),
    fileSizeBytes: _parseInt(json['fileSizeBytes']) ?? 0,
    downloadTime: json['downloadTime'] != null
        ? DateTime.tryParse(json['downloadTime'].toString())
        : null,
    audioUrlTimestamp: _parseInt(json['audioUrlTimestamp']),
    audioUrlQuality: json['audioUrlQuality']?.toString(),
    audioUrlSource: json['audioUrlSource']?.toString(),
    losslessId: json['losslessId']?.toString(),
    highQualityId: json['highQualityId']?.toString(),
  );

  Song copyWith({
    String? id,
    String? name,
    String? artist,
    String? album,
    String? source,
    String? quality,
    String? size,
    int? durationSeconds,
    String? coverUrl,
    Object? audioUrl = _unset,
    Object? lyric = _unset,
    Object? transLyric = _unset,
    bool? isLossless,
    Object? localFilePath = _unset,
    Object? lrcPath = _unset,
    int? fileSizeBytes,
    Object? downloadTime = _unset,
    Object? audioUrlTimestamp = _unset,
    Object? audioUrlQuality = _unset,
    Object? audioUrlSource = _unset,
    String? losslessId,
    String? highQualityId,
  }) => Song(
    id: id ?? this.id,
    name: name ?? this.name,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    source: source ?? this.source,
    quality: quality ?? this.quality,
    size: size ?? this.size,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    coverUrl: coverUrl ?? this.coverUrl,
    audioUrl: identical(audioUrl, _unset) ? this.audioUrl : audioUrl as String?,
    lyric: identical(lyric, _unset) ? this.lyric : lyric as String?,
    transLyric: identical(transLyric, _unset) ? this.transLyric : transLyric as String?,
    isLossless: isLossless ?? this.isLossless,
    localFilePath: identical(localFilePath, _unset) ? this.localFilePath : localFilePath as String?,
    lrcPath: identical(lrcPath, _unset) ? this.lrcPath : lrcPath as String?,
    fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    downloadTime: identical(downloadTime, _unset) ? this.downloadTime : downloadTime as DateTime?,
    audioUrlTimestamp: identical(audioUrlTimestamp, _unset) ? this.audioUrlTimestamp : audioUrlTimestamp as int?,
    audioUrlQuality: identical(audioUrlQuality, _unset) ? this.audioUrlQuality : audioUrlQuality as String?,
    audioUrlSource: identical(audioUrlSource, _unset) ? this.audioUrlSource : audioUrlSource as String?,
    losslessId: losslessId ?? this.losslessId,
    highQualityId: highQualityId ?? this.highQualityId,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id && source == other.source;

  @override
  int get hashCode => Object.hash(id, source);
}
