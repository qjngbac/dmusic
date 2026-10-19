class LrcLine {
  final Duration time;
  final String text;
  String? translation;

  LrcLine({
    required this.time,
    required this.text,
    this.translation,
  });

  LrcLine copyWith({
    Duration? time,
    String? text,
    String? translation,
  }) {
    return LrcLine(
      time: time ?? this.time,
      text: text ?? this.text,
      translation: translation ?? this.translation,
    );
  }
}

class LyricParser {
  static final RegExp _timeRegex = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]');

  static List<LrcLine> parse(String rawLrc, {String? translationLrc, String? transLrcText, int offsetMs = 0}) {
    final effectiveTransLrc = translationLrc ?? transLrcText;
    final lines = <LrcLine>[];
    final rawLines = rawLrc.split('\n');

    for (final line in rawLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final matches = _timeRegex.allMatches(trimmed);
      if (matches.isEmpty) continue;

      final text = trimmed.replaceAll(_timeRegex, '').trim();
      if (text.isEmpty) continue;

      for (final m in matches) {
        final minutes = int.tryParse(m.group(1) ?? '0') ?? 0;
        final seconds = int.tryParse(m.group(2) ?? '0') ?? 0;
        final fractionStr = m.group(3) ?? '0';
        int milliseconds = 0;
        if (fractionStr.length == 2) {
          milliseconds = (int.tryParse(fractionStr) ?? 0) * 10;
        } else if (fractionStr.length == 3) {
          milliseconds = int.tryParse(fractionStr) ?? 0;
        }

        final duration = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds + offsetMs,
        );

        lines.add(LrcLine(time: duration, text: text));
      }
    }

    lines.sort((a, b) => a.time.compareTo(b.time));

    // 如果提供了翻译歌词，按时间戳对齐合并到每行
    if (effectiveTransLrc != null && effectiveTransLrc.isNotEmpty) {
      final transLines = <LrcLine>[];
      for (final line in effectiveTransLrc.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final matches = _timeRegex.allMatches(trimmed);
        if (matches.isEmpty) continue;
        final text = trimmed.replaceAll(_timeRegex, '').trim();
        if (text.isEmpty) continue;
        for (final m in matches) {
          final minutes = int.tryParse(m.group(1) ?? '0') ?? 0;
          final seconds = int.tryParse(m.group(2) ?? '0') ?? 0;
          final fractionStr = m.group(3) ?? '0';
          int milliseconds = 0;
          if (fractionStr.length == 2) {
            milliseconds = (int.tryParse(fractionStr) ?? 0) * 10;
          } else if (fractionStr.length == 3) {
            milliseconds = int.tryParse(fractionStr) ?? 0;
          }
          transLines.add(LrcLine(
            time: Duration(minutes: minutes, seconds: seconds, milliseconds: milliseconds + offsetMs),
            text: text,
          ));
        }
      }

      // 时间容差 800ms 内对齐
      for (final orig in lines) {
        for (final trans in transLines) {
          final diff = (orig.time.inMilliseconds - trans.time.inMilliseconds).abs();
          if (diff <= 800) {
            orig.translation = trans.text;
            break;
          }
        }
      }
    }

    return lines;
  }

  static int findActiveIndex(List<LrcLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    for (int i = lines.length - 1; i >= 0; i--) {
      if (position >= lines[i].time) {
        return i;
      }
    }
    return 0;
  }
}
