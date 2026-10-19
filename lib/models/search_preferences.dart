/// Durable search controls. Artist choices belong only to the current query.
class SearchPreferences {
  static const platformOptions = {
    '全部',
    '网易云',
    'QQ音乐',
    '酷狗音乐',
    '酷我音乐',
    '咪咕音乐',
    '哔哩哔哩',
    '汽水音乐',
  };
  static const qualityOptions = {'全部', 'Hi-Res', 'FLAC', '320k', '标准'};
  static const sizeOptions = {'全部', '< 5MB', '5-15MB', '15-30MB', '> 30MB'};
  static const durationOptions = {'全部', '< 1分钟', '1-6分钟', '> 6分钟'};
  static const versionOptions = {'全部', '排除伴奏', '排除Live', '仅看Live'};
  static const downloadOptions = {'全部', '未下载', '已下载'};
  static const sortOptions = {'默认', '音质优先', '体积最大', '时长最长'};

  final Set<String> platforms;
  final Set<String> qualities;
  final Set<String> sizeRanges;
  final Set<String> durations;
  final Set<String> versions;
  final Set<String> downloadStatuses;
  final String sortOrder;

  SearchPreferences({
    Iterable<String> platforms = const ['全部'],
    Iterable<String> qualities = const ['全部'],
    Iterable<String> sizeRanges = const ['全部'],
    Iterable<String> durations = const ['全部'],
    Iterable<String> versions = const ['全部'],
    Iterable<String> downloadStatuses = const ['全部'],
    String sortOrder = '默认',
  }) : platforms = _selection(platforms, platformOptions),
       qualities = _selection(qualities, qualityOptions),
       sizeRanges = _selection(sizeRanges, sizeOptions),
       durations = _selection(durations, durationOptions),
       versions = _selection(versions, versionOptions, exclusiveLive: true),
       downloadStatuses = _selection(downloadStatuses, downloadOptions),
       sortOrder = sortOptions.contains(sortOrder) ? sortOrder : '默认';

  static Set<String> _selection(
    Iterable<String> values,
    Set<String> allowed, {
    bool exclusiveLive = false,
  }) {
    final result = values.where(allowed.contains).toSet();
    if (result.isEmpty || result.contains('全部')) {
      return Set.unmodifiable({'全部'});
    }
    if (exclusiveLive && result.contains('仅看Live')) result.remove('排除Live');
    return Set.unmodifiable(result);
  }

  factory SearchPreferences.fromJson(Object? json) {
    if (json is! Map) return SearchPreferences();
    Iterable<String> read(String key) {
      final value = json[key];
      return value is List ? value.whereType<String>() : const ['全部'];
    }

    return SearchPreferences(
      platforms: read('platforms'),
      qualities: read('qualities'),
      sizeRanges: read('sizeRanges'),
      durations: read('durations'),
      versions: read('versions'),
      downloadStatuses: read('downloadStatuses'),
      sortOrder: json['sortOrder'] is String
          ? json['sortOrder'] as String
          : '默认',
    );
  }

  Map<String, dynamic> toJson() => {
    'platforms': platforms.toList(),
    'qualities': qualities.toList(),
    'sizeRanges': sizeRanges.toList(),
    'durations': durations.toList(),
    'versions': versions.toList(),
    'downloadStatuses': downloadStatuses.toList(),
    'sortOrder': sortOrder,
  };
}
