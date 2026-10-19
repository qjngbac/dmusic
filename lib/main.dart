import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'models/song.dart';
import 'models/search_preferences.dart';
import 'services/music_api.dart';
import 'services/player_service.dart';
import 'services/download_service.dart';
import 'services/database_service.dart';
import 'services/widget_service.dart';
import 'views/player_bottom_sheet.dart';
import 'views/library_tab.dart';
import 'views/converter_tab.dart';
import 'views/download_sheet.dart';
import 'views/song_options_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseService().init();
  await DownloadService().init();
  await PlayerService().restorePlaybackState();
  WidgetService().init();
  runApp(const DMusicApp());
}

class DMusicApp extends StatelessWidget {
  const DMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DMusic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0D14),
        primaryColor: const Color(0xFF6366F1),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF06B6D4),
          surface: Color(0xFF131A29),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF1E2638),
          contentTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: const Color(0xFF6366F1).withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          elevation: 6,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0D14),
          elevation: 0,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  DateTime? _lastBackPressTime;

  final GlobalKey<SearchTabState> _searchTabKey = GlobalKey<SearchTabState>();
  final GlobalKey<LibraryTabState> _libraryTabKey = GlobalKey<LibraryTabState>();
  final GlobalKey<DownloadTabState> _downloadTabKey = GlobalKey<DownloadTabState>();

  late final List<Widget> _tabs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabs = [
      SearchTab(key: _searchTabKey),
      LibraryTab(key: _libraryTabKey),
      DownloadTab(key: _downloadTabKey),
      const ConverterTab(),
    ];
    PlayerService().errorStream.listen((err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err),
            backgroundColor: const Color(0xFFEF4444),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      PlayerService().savePlaybackStateNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 优先检查当前激活的 Tab 是否消费了返回键（如多选、搜索状态等）
        bool handled = false;
        if (_currentIndex == 0) {
          handled = _searchTabKey.currentState?.handleBackPressed() ?? false;
        } else if (_currentIndex == 1) {
          handled = _libraryTabKey.currentState?.handleBackPressed() ?? false;
        } else if (_currentIndex == 2) {
          handled = _downloadTabKey.currentState?.handleBackPressed() ?? false;
        }

        if (handled) return;

        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再按一次退出 DMusic'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else {
          PlayerService().savePlaybackStateNow();
          PlayerService().pause();
          WidgetService().stopPlaybackService();
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _currentIndex,
          children: _tabs,
        ),
        // 彻底消除黑框与悬空缺陷：将 BottomMiniPlayer 与 BottomNavigationBar 一体化贴合
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BottomMiniPlayer(),
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0E1420),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: SafeArea(
                top: false,
                child: BottomNavigationBar(
                  currentIndex: _currentIndex,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  type: BottomNavigationBarType.fixed,
                  selectedItemColor: const Color(0xFF6366F1),
                  unselectedItemColor: Colors.white54,
                  selectedFontSize: 11,
                  unselectedFontSize: 11,
                  onTap: (idx) => setState(() => _currentIndex = idx),
                  items: const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.search_rounded),
                      activeIcon: Icon(Icons.search_rounded, color: Color(0xFF6366F1)),
                      label: '搜索发现',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.library_music_rounded),
                      activeIcon: Icon(Icons.library_music_rounded, color: Color(0xFF6366F1)),
                      label: '我的歌单',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.download_rounded),
                      activeIcon: Icon(Icons.download_rounded, color: Color(0xFF6366F1)),
                      label: '下载管理',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.transform_rounded),
                      activeIcon: Icon(Icons.transform_rounded, color: Color(0xFF6366F1)),
                      label: '格式转换',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================= 同名多版本聚合分组模型 (建议 5) ================= */
class AggregatedSongGroup {
  final Song primarySong;
  final List<Song> variants;
  final String? stableGroupKey;

  AggregatedSongGroup({
    required this.primarySong,
    required this.variants,
    this.stableGroupKey,
  });

  int get totalCount => 1 + variants.length;
  bool get hasVariants => variants.isNotEmpty;
  String get groupKey => stableGroupKey ?? '${primarySong.baseName}::${primarySong.artist.toLowerCase()}';
}

/* ================= 搜索选项卡 ================= */
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => SearchTabState();
}

class SearchTabState extends State<SearchTab> {
  final _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<Song> _rawResults = [];
  bool _hasSearched = false;
  int _searchSeq = 0;
  bool _isLoading = false;
  bool _isBatchDownloadMode = false;
  final Set<String> _selectedSongKeys = {};

  /// 供主界面拦截返回键调用：若正处于批量下载多选模式，则优雅退出多选，绝不触发退出应用提示
  bool handleBackPressed() {
    if (_isBatchDownloadMode) {
      setState(() {
        _isBatchDownloadMode = false;
        _selectedSongKeys.clear();
      });
      return true;
    }
    return false;
  }
  bool _skipExistingDownloads = true; // 批量下载时自动跳过本地已下载的歌曲 (建议 3)
  bool _groupVariants = true; // 同名多版本聚合折叠展示 (建议 5)
  final Set<String> _expandedGroupKeys = {}; // 当前已展开异版的聚合歌曲Key
  final Map<String, String> _selectedVariantKeyByGroup = {}; // 聚合组当前选定展示的主版本Key (方案 A 动态提升)
  Set<String> _enabledSources = Set<String>.from(DatabaseService.defaultSources); // 首页选源配置 (默认全选)
  late Future<List<Map<String, dynamic>>> _chartsFuture;
  late Future<List<Map<String, dynamic>>> _hotKeywordsFuture;

  @override
  void initState() {
    super.initState();
    _chartsFuture = MusicApi.fetchTopCharts();
    _hotKeywordsFuture = MusicApi.fetchHotKeywords();
    _enabledSources = Set<String>.from(DatabaseService().enabledSources);
    final preferences = DatabaseService().searchPreferences;
    _filterPlatforms.clear(); _filterPlatforms.addAll(preferences.platforms);
    _filterQualities.clear(); _filterQualities.addAll(preferences.qualities);
    _filterSizeRanges.clear(); _filterSizeRanges.addAll(preferences.sizeRanges);
    _filterDurations.clear(); _filterDurations.addAll(preferences.durations);
    _filterVersions.clear(); _filterVersions.addAll(preferences.versions);
    _filterDownloadStatuses.clear(); _filterDownloadStatuses.addAll(preferences.downloadStatuses);
    _sortOrder = preferences.sortOrder;
    if (!_enabledSources.contains('汽水音乐') && _enabledSources.length >= 6) {
      _enabledSources.add('汽水音乐');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// 搜索结果聚合分组算法（按去括号主歌名与歌手归一化分组，方案 A 动态提升播放中/选中的版本为主卡片）
  List<AggregatedSongGroup> _groupSearchResults(List<Song> songs) {
    final groups = <AggregatedSongGroup>[];
    final processedIndices = <int>{};
    final currentSong = PlayerService().currentSong;

    for (int i = 0; i < songs.length; i++) {
      if (processedIndices.contains(i)) continue;
      final main = songs[i];
      final cleanMain = main.baseName;
      final allGroupMembers = <Song>[main];

      for (int j = i + 1; j < songs.length; j++) {
        if (processedIndices.contains(j)) continue;
        final candidate = songs[j];
        if (candidate.baseName == cleanMain && Song.isArtistMatch(main.artist, candidate.artist)) {
          allGroupMembers.add(candidate);
          processedIndices.add(j);
        }
      }
      processedIndices.add(i);

      // 稳定标识 groupKey，保证折叠/展开与选中状态不因主卡片切换而失效
      final stableKey = '$cleanMain::${main.artist.toLowerCase()}';

      // 方案 A 动态提升主卡片：
      // 1. 若当前正在播放的歌曲属于该聚合组，动态提升为主卡片 primarySong
      // 2. 否则若用户在界面上主动选定了某个子版本，提升为主卡片
      // 3. 否则默认以搜索结果首个版本为主卡片
      Song activePrimary = allGroupMembers.first;
      if (currentSong != null) {
        final playingIdx = allGroupMembers.indexWhere((s) =>
            s.key == currentSong.key ||
            (s.id == currentSong.id && s.source == currentSong.source));
        if (playingIdx != -1) {
          activePrimary = allGroupMembers[playingIdx];
        } else if (_selectedVariantKeyByGroup.containsKey(stableKey)) {
          final selKey = _selectedVariantKeyByGroup[stableKey];
          final selIdx = allGroupMembers.indexWhere((s) => s.key == selKey);
          if (selIdx != -1) activePrimary = allGroupMembers[selIdx];
        }
      } else if (_selectedVariantKeyByGroup.containsKey(stableKey)) {
        final selKey = _selectedVariantKeyByGroup[stableKey];
        final selIdx = allGroupMembers.indexWhere((s) => s.key == selKey);
        if (selIdx != -1) activePrimary = allGroupMembers[selIdx];
      }

      final variants = allGroupMembers.where((s) => s.key != activePrimary.key).toList();
      groups.add(AggregatedSongGroup(
        primarySong: activePrimary,
        variants: variants,
        stableGroupKey: stableKey,
      ));
    }
    return groups;
  }

  // 动态筛选状态与方案 B 折叠控制 (全面支持多选)
  final Set<String> _filterPlatforms = {'全部'};
  final Set<String> _filterQualities = {'全部'};
  final Set<String> _filterArtists = {'全部'};
  bool _isFilterExpanded = false; // 方案 B 折叠展开控制
  final Set<String> _filterSizeRanges = {'全部'}; // 全部, < 5MB, 5-15MB, 15-30MB, > 30MB
  final Set<String> _filterDurations = {'全部'}; // 全部, < 1分钟, 1-6分钟, > 6分钟
  final Set<String> _filterVersions = {'全部'}; // 全部, 排除伴奏, 排除Live, 仅看Live
  final Set<String> _filterDownloadStatuses = {'全部'}; // 全部, 未下载, 已下载
  String _sortOrder = '默认'; // 默认, 音质优先, 体积最大, 时长最长

  /// 筛选多选切换：点一下选中，再点一下取消选择；点击全部重置为全部
  void _toggleFilterItem(Set<String> targetSet, String item) {
    setState(() {
      if (item == '全部') {
        targetSet.clear();
        targetSet.add('全部');
        return;
      }
      targetSet.remove('全部');
      if (targetSet.contains(item)) {
        targetSet.remove(item);
        if (targetSet.isEmpty) {
          targetSet.add('全部');
        }
      } else {
        if (identical(targetSet, _filterVersions)) {
          if (item == '仅看Live') targetSet.remove('排除Live');
          if (item == '排除Live') targetSet.remove('仅看Live');
        }
        targetSet.add(item);
      }
    });
    if (!identical(targetSet, _filterArtists)) _saveSearchPreferences();
  }

  void _saveSearchPreferences() {
    final preferences = SearchPreferences(
      platforms: _filterPlatforms, qualities: _filterQualities,
      sizeRanges: _filterSizeRanges, durations: _filterDurations,
      versions: _filterVersions, downloadStatuses: _filterDownloadStatuses,
      sortOrder: _sortOrder,
    );
    unawaited(DatabaseService().saveSearchPreferences(preferences).catchError((Object _) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('筛选设置保存失败，请重试')),
      );
    }));
  }

  int get _activeFilterCount {
    int count = 0;
    if (!_filterPlatforms.contains('全部')) count++;
    if (!_filterQualities.contains('全部')) count++;
    if (!_filterArtists.contains('全部')) count++;
    if (!_filterSizeRanges.contains('全部')) count++;
    if (!_filterDurations.contains('全部')) count++;
    if (!_filterVersions.contains('全部')) count++;
    if (!_filterDownloadStatuses.contains('全部')) count++;
    if (_sortOrder != '默认') count++;
    return count;
  }

  void _resetFilters() {
    setState(() {
      _filterPlatforms.clear(); _filterPlatforms.add('全部');
      _filterQualities.clear(); _filterQualities.add('全部');
      _filterArtists.clear(); _filterArtists.add('全部');
      _filterSizeRanges.clear(); _filterSizeRanges.add('全部');
      _filterDurations.clear(); _filterDurations.add('全部');
      _filterVersions.clear(); _filterVersions.add('全部');
      _filterDownloadStatuses.clear(); _filterDownloadStatuses.add('全部');
      _sortOrder = '默认';
    });
    _saveSearchPreferences();
  }

  void _doSearch(String kw) async {
    final keyword = kw.trim();
    if (keyword.isEmpty) return;
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    DatabaseService().addSearchHistory(keyword);
    final currentSeq = ++_searchSeq;

    // 记录发起本次搜索前用户选中的具体作者（排除'全部'）
    final previousArtists = _filterArtists.where((a) => a != '全部').toSet();

    setState(() {
      _hasSearched = true;
      _isLoading = true;
      _isBatchDownloadMode = false;
      _selectedSongKeys.clear();
      _selectedVariantKeyByGroup.clear();
    });

    try {
      final activeSources = _enabledSources.isEmpty ? Set<String>.from(DatabaseService.defaultSources) : _enabledSources;
      final songs = await MusicApi.searchAll(keyword, enabledSources: activeSources);
      if (!mounted || currentSeq != _searchSeq) return;

      // 自适应作者固定：若本次搜索结果包含上一次选中的作者则保持选中，若没有则重置为全部
      if (previousArtists.isNotEmpty) {
        final newAvailableArtists = <String>{};
        for (final s in songs) {
          final parts = s.artist.split(RegExp(r'[,/、&·]'));
          for (final part in parts) {
            final ar = part.trim();
            if (ar.isNotEmpty && ar != '未知歌手') {
              newAvailableArtists.add(ar);
            }
          }
        }
        final matched = previousArtists.where((a) => newAvailableArtists.contains(a)).toSet();
        _filterArtists.clear();
        if (matched.isNotEmpty) {
          _filterArtists.addAll(matched);
        } else {
          _filterArtists.add('全部');
        }
      } else {
        _filterArtists.clear();
        _filterArtists.add('全部');
      }

      setState(() {
        _rawResults = songs;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted || currentSeq != _searchSeq) return;
      setState(() => _isLoading = false);
    }
  }

  void _clearSearch() {
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    _searchController.clear();
    _searchSeq++;
    setState(() {
      _hasSearched = false;
      _rawResults = [];
      _isBatchDownloadMode = false;
      _selectedSongKeys.clear();
      _selectedVariantKeyByGroup.clear();
      _filterArtists.clear(); _filterArtists.add('全部');
    });
  }

  List<String> get _dynamicPlatforms {
    final set = <String>{'全部', ..._filterPlatforms};
    for (final s in _rawResults) {
      if (s.source.isNotEmpty) {
        set.add(s.source);
      }
    }
    return set.toList();
  }

  List<Song> get _platformSongs {
    if (_filterPlatforms.contains('全部')) return _rawResults;
    return _rawResults.where((s) => _filterPlatforms.any((p) => s.source.contains(p))).toList();
  }

  List<String> get _dynamicQualities {
    final songs = _platformSongs;
    final set = <String>{'全部', ..._filterQualities};
    for (final s in songs) {
      if (s.quality.contains('Hi-Res')) set.add('Hi-Res');
      if (s.quality.contains('FLAC')) set.add('FLAC');
      if (s.quality.contains('320k')) set.add('320k');
      if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) set.add('标准');
    }
    return set.toList();
  }

  List<String> get _dynamicArtists {
    final songs = _platformSongs;
    final set = <String>{'全部'};
    for (final s in songs) {
      final parts = s.artist.split(RegExp(r'[,/、&·]'));
      for (final part in parts) {
        final ar = part.trim();
        if (ar.isNotEmpty && ar != '未知歌手') {
          set.add(ar);
        }
      }
    }
    return set.toList();
  }

  void _onPlatformSelected(String p) {
    _toggleFilterItem(_filterPlatforms, p);
    // 歌手只属于当前搜索上下文；音质选择即使暂时无结果也保留。
    final pSongs = _platformSongs;

    final aSet = <String>{'全部'};
    for (final s in pSongs) {
      final parts = s.artist.split(RegExp(r'[,/、&·]'));
      for (final part in parts) {
        final ar = part.trim();
        if (ar.isNotEmpty && ar != '未知歌手') {
          aSet.add(ar);
        }
      }
    }
    _filterArtists.removeWhere((a) => !aSet.contains(a));
    if (_filterArtists.isEmpty) _filterArtists.add('全部');
  }

  List<Song> get _filteredResults {
    final downloadedList = DatabaseService().downloads;

    final list = _platformSongs.where((s) {
      // 1. 音质筛选 (支持多选)
      if (!_filterQualities.contains('全部')) {
        final match = _filterQualities.any((q) {
          if (q == 'Hi-Res' && s.quality.contains('Hi-Res')) return true;
          if (q == 'FLAC' && s.quality.contains('FLAC')) return true;
          if (q == '320k' && s.quality.contains('320k')) return true;
          if (q == '标准' && (s.quality.contains('标准') || s.quality.contains('128k') || s.quality.contains('192k'))) return true;
          return false;
        });
        if (!match) return false;
      }
      // 2. 歌手筛选 (支持多选)
      if (!_filterArtists.contains('全部')) {
        final match = _filterArtists.any((a) => s.artist.contains(a));
        if (!match) return false;
      }

      // 3. 文件大小区间筛选 (支持多选)
      if (!_filterSizeRanges.contains('全部')) {
        final mb = s.estimatedSizeMB;
        final match = _filterSizeRanges.any((sz) {
          if (sz == '< 5MB' && mb < 5) return true;
          if (sz == '5-15MB' && (mb >= 5 && mb <= 15)) return true;
          if (sz == '15-30MB' && (mb > 15 && mb <= 30)) return true;
          if (sz == '> 30MB' && mb > 30) return true;
          return false;
        });
        if (!match) return false;
      }

      // 4. 时长筛选 (支持多选)
      if (!_filterDurations.contains('全部')) {
        final dur = s.durationSeconds;
        final match = _filterDurations.any((durRange) {
          if (durRange == '< 1分钟' && dur < 60) return true;
          if (durRange == '1-6分钟' && (dur >= 60 && dur <= 360)) return true;
          if (durRange == '> 6分钟' && dur > 360) return true;
          return false;
        });
        if (!match) return false;
      }

      // 5. 版本属性筛选 (支持多选)
      if (!_filterVersions.contains('全部')) {
        if (_filterVersions.contains('排除伴奏') && s.isInstrumental) return false;
        if (_filterVersions.contains('排除Live') && s.isLive) return false;
        if (_filterVersions.contains('仅看Live') && !s.isLive) return false;
      }

      // 6. 下载状态筛选 (支持多选)
      if (!_filterDownloadStatuses.contains('全部')) {
        final matchRes = DatabaseService().checkDownloadStatus(s, downloadedList);
        final isDl = matchRes.isDownloaded;
        if (_filterDownloadStatuses.contains('未下载') && isDl && !_filterDownloadStatuses.contains('已下载')) return false;
        if (_filterDownloadStatuses.contains('已下载') && !isDl && !_filterDownloadStatuses.contains('未下载')) return false;
      }

      return true;
    }).toList();

    // 7. 排序应用
    if (_sortOrder == '体积最大') {
      list.sort((a, b) => b.estimatedSizeMB.compareTo(a.estimatedSizeMB));
    } else if (_sortOrder == '时长最长') {
      list.sort((a, b) => b.durationSeconds.compareTo(a.durationSeconds));
    } else if (_sortOrder == '音质优先') {
      int score(Song s) {
        final q = s.quality.toLowerCase();
        if (q.contains('hi-res') || q.contains('母带')) return 4;
        if (s.isLossless || q.contains('flac') || q.contains('无损')) return 3;
        if (q.contains('320k') || q.contains('极高')) return 2;
        return 1;
      }
      list.sort((a, b) => score(b).compareTo(score(a)));
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final results = _filteredResults;
    final hasSearched = _hasSearched;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        _searchFocusNode.unfocus();
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶部标题
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(child: Text('🎵', style: TextStyle(fontSize: 18))),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'DMusic',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Spacer(),
                  _buildSourceSelectorButton(),
                ],
              ),
            ),

            // 搜索框
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF131A29),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white10),
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  textInputAction: TextInputAction.search,
                  onSubmitted: _doSearch,
                  decoration: InputDecoration(
                    hintText: '搜索歌名、歌手或专辑',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                    prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_searchController.text.isNotEmpty || hasSearched)
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                            onPressed: _clearSearch,
                          ),
                        IconButton(
                          icon: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF6366F1)),
                          onPressed: () => _doSearch(_searchController.text),
                        ),
                      ],
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ),

            // 内容区域（动态联动多维筛选栏 + 吸顶歌曲统计/批量操作栏 + 歌曲列表/加载/空状态）
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  if (_searchFocusNode.hasFocus) {
                    _searchFocusNode.unfocus();
                    FocusManager.instance.primaryFocus?.unfocus();
                  }
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                // 1. 顶部发现推荐 OR 动态联动多维筛选栏（随列表向上滑动并可完全隐藏）
                if (!hasSearched)
                  SliverToBoxAdapter(
                    child: _buildDefaultDiscoveryChips(),
                  )
                else
                  SliverToBoxAdapter(
                    child: _buildDynamicFilterSection(),
                  ),

                // 2. 批量下载工具条（吸顶固定：当筛选栏滑出屏幕后，此栏吸顶在搜索栏下方保持常驻）
                if (hasSearched && results.isNotEmpty)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _SearchStickyHeaderDelegate(
                      height: 44,
                      child: Container(
                        color: const Color(0xFF0A0D14),
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Text(
                                  '找到 ${results.length} 首歌曲${_isBatchDownloadMode ? ' (已选 ${_selectedSongKeys.length} 首)' : ''}',
                                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                                ),
                                if (!_isBatchDownloadMode) ...[
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: () => setState(() => _groupVariants = !_groupVariants),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: _groupVariants ? const Color(0x22818CF8) : Colors.white10,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: _groupVariants ? const Color(0x55818CF8) : Colors.white12,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _groupVariants ? Icons.layers_rounded : Icons.view_headline_rounded,
                                            size: 12,
                                            color: _groupVariants ? const Color(0xFF818CF8) : Colors.white54,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            _groupVariants ? '已聚合异版' : '平铺展示',
                                            style: TextStyle(
                                              color: _groupVariants ? const Color(0xFF818CF8) : Colors.white54,
                                              fontSize: 10.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            Row(
                              children: [
                                if (_isBatchDownloadMode) ...[
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        final visibleKeys = results.map((s) => s.key).toSet();
                                        if (results.isNotEmpty && _selectedSongKeys.containsAll(visibleKeys)) {
                                          _selectedSongKeys.removeAll(visibleKeys);
                                        } else {
                                          _selectedSongKeys.addAll(visibleKeys);
                                        }
                                      });
                                    },
                                    child: Text(
                                      (results.isNotEmpty && _selectedSongKeys.containsAll(results.map((s) => s.key))) ? '取消全选' : '全选',
                                      style: const TextStyle(color: Color(0xFF818CF8), fontSize: 12),
                                    ),
                                  ),
                                ],
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: Icon(
                                    _isBatchDownloadMode ? Icons.check_circle_rounded : Icons.checklist_rounded,
                                    size: 16,
                                    color: _isBatchDownloadMode ? const Color(0xFF10B981) : const Color(0xFF818CF8),
                                  ),
                                  label: Text(
                                    _isBatchDownloadMode ? '退出多选' : '批量下载',
                                    style: TextStyle(
                                      color: _isBatchDownloadMode ? const Color(0xFF10B981) : const Color(0xFF818CF8),
                                      fontSize: 12,
                                    ),
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _isBatchDownloadMode = !_isBatchDownloadMode;
                                      if (!_isBatchDownloadMode) {
                                        _selectedSongKeys.clear();
                                      }
                                    });
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 3. 歌曲列表区域 / 加载中 / 空结果状态
                if (_isLoading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Color(0xFF6366F1)),
                          SizedBox(height: 12),
                          Text('正在并发聚合各平台高品质音乐...', style: TextStyle(color: Colors.white38, fontSize: 13)),
                        ],
                      ),
                    ),
                  )
                else if (results.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.music_note_rounded, color: Colors.white12, size: 64),
                          SizedBox(height: 12),
                          Text(
                            hasSearched ? '未找到符合当前筛选条件的歌曲' : '输入歌曲名或歌手即可极速探索',
                            style: const TextStyle(color: Colors.white38, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 140),
                    sliver: Builder(
                      builder: (context) {
                        // 建议 5: 若开启聚合且不在多选模式，按同名主歌名折叠异版
                        if (!_isBatchDownloadMode && _groupVariants) {
                          return StreamBuilder<Song?>(
                            stream: PlayerService().currentSongStream,
                            initialData: PlayerService().currentSong,
                            builder: (context, _) {
                              final groups = _groupSearchResults(results);
                              return SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final group = groups[index];
                                    final isExpanded = _expandedGroupKeys.contains(group.groupKey);

                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SongListItem(
                                          song: group.primarySong,
                                          onTap: () => PlayerService().setPlaylist(results, startIndex: results.indexOf(group.primarySong)),
                                        ),
                                        if (group.hasVariants)
                                          Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 20),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF131A29).withValues(alpha: 0.8),
                                              borderRadius: BorderRadius.vertical(
                                                bottom: Radius.circular(isExpanded ? 0 : 10),
                                              ),
                                              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                                            ),
                                            child: InkWell(
                                              borderRadius: BorderRadius.vertical(bottom: Radius.circular(isExpanded ? 0 : 10)),
                                              onTap: () {
                                                setState(() {
                                                  if (isExpanded) {
                                                    _expandedGroupKeys.remove(group.groupKey);
                                                  } else {
                                                    _expandedGroupKeys.add(group.groupKey);
                                                  }
                                                });
                                              },
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                                      color: const Color(0xFF818CF8),
                                                      size: 16,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      '共 ${group.totalCount} 个同名版本（含 Live / 伴奏等）',
                                                      style: const TextStyle(color: Color(0xFF818CF8), fontSize: 11, fontWeight: FontWeight.w500),
                                                    ),
                                                    const Spacer(),
                                                    Text(
                                                      isExpanded ? '收起 ▴' : '展开 ▾',
                                                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (group.hasVariants && isExpanded)
                                          Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 20),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0C101A),
                                              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                                              border: Border.all(color: const Color(0x336366F1)),
                                            ),
                                            child: Column(
                                              children: group.variants.map((vSong) {
                                                final cur = PlayerService().currentSong;
                                                final isPlayingVSong = cur != null &&
                                                    (cur.key == vSong.key || (cur.id == vSong.id && cur.source == vSong.source));
                                                return Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: isPlayingVSong ? const Color(0xFF6366F1).withValues(alpha: 0.12) : Colors.transparent,
                                                    border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.03))),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        isPlayingVSong ? Icons.volume_up_rounded : Icons.subdirectory_arrow_right_rounded,
                                                        color: const Color(0xFF818CF8),
                                                        size: 15,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Expanded(
                                                        child: InkWell(
                                                          onTap: () {
                                                            setState(() {
                                                              _selectedVariantKeyByGroup[group.groupKey] = vSong.key;
                                                            });
                                                            final list = List<Song>.from(results);
                                                            final vIdx = list.indexOf(vSong);
                                                            if (vIdx != -1) {
                                                              PlayerService().setPlaylist(list, startIndex: vIdx);
                                                            } else {
                                                              final pIdx = list.indexOf(group.primarySong);
                                                              if (pIdx != -1) {
                                                                list[pIdx] = vSong;
                                                                PlayerService().setPlaylist(list, startIndex: pIdx);
                                                              } else {
                                                                PlayerService().playSong(vSong);
                                                              }
                                                            }
                                                          },
                                                          child: Column(
                                                            crossAxisAlignment: CrossAxisAlignment.start,
                                                            children: [
                                                              Row(
                                                                children: [
                                                                  Flexible(
                                                                    child: Text(
                                                                      vSong.name,
                                                                      style: TextStyle(
                                                                        color: isPlayingVSong ? const Color(0xFF818CF8) : Colors.white,
                                                                        fontSize: 12.5,
                                                                        fontWeight: isPlayingVSong ? FontWeight.bold : FontWeight.w500,
                                                                      ),
                                                                      maxLines: 1,
                                                                      overflow: TextOverflow.ellipsis,
                                                                    ),
                                                                  ),
                                                                  if (isPlayingVSong) ...[
                                                                    const SizedBox(width: 4),
                                                                    Container(
                                                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                                                                      decoration: BoxDecoration(
                                                                        color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                                                                        borderRadius: BorderRadius.circular(3),
                                                                        border: Border.all(color: const Color(0xFF818CF8), width: 0.8),
                                                                      ),
                                                                      child: const Text('播放中', style: TextStyle(color: Color(0xFF818CF8), fontSize: 8.5, fontWeight: FontWeight.bold)),
                                                                    ),
                                                                  ],
                                                                ],
                                                              ),
                                                              Row(
                                                                children: [
                                                                  Container(
                                                                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
                                                                    margin: const EdgeInsets.only(right: 6, top: 1),
                                                                    decoration: BoxDecoration(
                                                                      color: vSong.isLossless ? const Color(0x22F59E0B) : const Color(0x2206B6D4),
                                                                      borderRadius: BorderRadius.circular(3),
                                                                    ),
                                                                    child: Text(
                                                                      vSong.quality,
                                                                      style: TextStyle(
                                                                        color: vSong.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                                                                        fontSize: 8.5,
                                                                        fontWeight: FontWeight.bold,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  Expanded(
                                                                    child: Text(
                                                                      '${vSong.artist} · ${vSong.source}',
                                                                      style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                                                                      maxLines: 1,
                                                                      overflow: TextOverflow.ellipsis,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                      StreamBuilder<List<Song>>(
                                                        stream: DatabaseService().downloadsStream,
                                                        initialData: DatabaseService().downloads,
                                                        builder: (context, snap) {
                                                          final match = DatabaseService().checkDownloadStatus(vSong, snap.data);
                                                          IconData icon;
                                                          Color color;
                                                          if (match.canUpgrade) {
                                                            icon = Icons.upgrade_rounded;
                                                            color = const Color(0xFF38BDF8);
                                                          } else if (match.isExact) {
                                                            icon = Icons.check_circle_rounded;
                                                            color = const Color(0xFF10B981);
                                                          } else if (match.isVariant) {
                                                            icon = Icons.file_download_done_rounded;
                                                            color = const Color(0xFF818CF8);
                                                          } else {
                                                            icon = Icons.download_rounded;
                                                            color = Colors.white60;
                                                          }
                                                          return IconButton(
                                                            icon: Icon(icon, color: color, size: 17),
                                                            padding: EdgeInsets.zero,
                                                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                                            onPressed: () => SongListItem.showDownloadBottomSheet(context, vSong, matchResult: match),
                                                          );
                                                        },
                                                      ),
                                                      IconButton(
                                                        icon: const Icon(Icons.more_vert_rounded, color: Colors.white54, size: 18),
                                                        tooltip: '更多操作与详情',
                                                        padding: EdgeInsets.zero,
                                                        constraints: const BoxConstraints(minWidth: 26, minHeight: 28),
                                                        onPressed: () => SongListItem.showSongOptions(
                                                          context,
                                                          vSong,
                                                          onTap: () {
                                                            setState(() {
                                                              _selectedVariantKeyByGroup[group.groupKey] = vSong.key;
                                                            });
                                                            final list = List<Song>.from(results);
                                                            final vIdx = list.indexOf(vSong);
                                                            if (vIdx != -1) {
                                                              PlayerService().setPlaylist(list, startIndex: vIdx);
                                                            } else {
                                                              final pIdx = list.indexOf(group.primarySong);
                                                              if (pIdx != -1) {
                                                                list[pIdx] = vSong;
                                                                PlayerService().setPlaylist(list, startIndex: pIdx);
                                                              } else {
                                                                PlayerService().playSong(vSong);
                                                              }
                                                            }
                                                          },
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        const SizedBox(height: 4),
                                      ],
                                    );
                                  },
                                  childCount: groups.length,
                                ),
                              );
                            },
                          );
                        }

                        // 默认平铺或多选批量模式
                        return SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final song = results[index];
                              if (_isBatchDownloadMode) {
                                final isSelected = _selectedSongKeys.contains(song.key);
                                return InkWell(
                                  onTap: () {
                                    setState(() {
                                      if (isSelected) {
                                        _selectedSongKeys.remove(song.key);
                                      } else {
                                        _selectedSongKeys.add(song.key);
                                      }
                                    });
                                  },
                                  child: Row(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(left: 12),
                                        child: Checkbox(
                                          value: isSelected,
                                          activeColor: const Color(0xFF6366F1),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                          onChanged: (v) {
                                            setState(() {
                                              if (v == true) {
                                                _selectedSongKeys.add(song.key);
                                              } else {
                                                _selectedSongKeys.remove(song.key);
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                      Expanded(
                                        child: SongListItem(
                                          song: song,
                                          showDownloadButton: false,
                                          onTap: () {
                                            setState(() {
                                              if (isSelected) {
                                                _selectedSongKeys.remove(song.key);
                                              } else {
                                                _selectedSongKeys.add(song.key);
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return SongListItem(
                                song: song,
                                onTap: () => PlayerService().setPlaylist(results, startIndex: index),
                              );
                            },
                            childCount: results.length,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),

          // 批量下载悬浮底栏 (建议 3: 支持智能跳过本地已下载曲目)
          if (_isBatchDownloadMode && _selectedSongKeys.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              decoration: const BoxDecoration(
                color: Color(0xFF131A29),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          height: 22,
                          width: 22,
                          child: Checkbox(
                            value: _skipExistingDownloads,
                            activeColor: const Color(0xFF6366F1),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            onChanged: (v) => setState(() => _skipExistingDownloads = v ?? true),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '自动跳过本地已下载歌曲',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          '已选 ${_selectedSongKeys.length} 首',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        minimumSize: const Size(double.infinity, 44),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.download_rounded, color: Colors.white, size: 20),
                      label: Text('一键批量下载 (${_selectedSongKeys.length} 首)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        final toDownload = results.where((s) => _selectedSongKeys.contains(s.key)).toList();
                        setState(() {
                          _isBatchDownloadMode = false;
                          _selectedSongKeys.clear();
                        });
                        DownloadSheet.showBatchDownload(context, toDownload, title: '搜索结果批量下载');
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

  Widget _buildSourceSelectorButton() {
    final total = DatabaseService.defaultSources.length;
    final selectedCount = _enabledSources.length;
    final isAll = selectedCount >= total;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showSourceSelectorSheet(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isAll
                ? const Color(0xFF1E2638)
                : const Color(0xFF6366F1).withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isAll
                  ? Colors.white.withValues(alpha: 0.12)
                  : const Color(0xFF818CF8).withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hub_rounded,
                size: 13,
                color: isAll ? const Color(0xFF818CF8) : const Color(0xFF38BDF8),
              ),
              const SizedBox(width: 5),
              Text(
                isAll ? '音源: 全选 ($total)' : '已选 $selectedCount/$total 源',
                style: TextStyle(
                  color: isAll ? Colors.white70 : const Color(0xFF38BDF8),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: isAll ? Colors.white38 : const Color(0xFF38BDF8),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSourceSelectorSheet(BuildContext context) {
    final allSources = DatabaseService.defaultSources;
    final tempSelected = Set<String>.from(_enabledSources);

    final sourceDetails = <String, Map<String, dynamic>>{
      '网易云': {
        'name': '网易云音乐',
        'color': const Color(0xFFEF4444),
        'icon': Icons.cloud_queue_rounded,
        'desc': '曲库丰富 · 评论活跃 · FLAC/Hi-Res',
      },
      'QQ音乐': {
        'name': 'QQ音乐',
        'color': const Color(0xFF10B981),
        'icon': Icons.music_note_rounded,
        'desc': '独家版权 · 流行热歌 · 官方首发',
      },
      '酷狗音乐': {
        'name': '酷狗音乐',
        'color': const Color(0xFF0284C7),
        'icon': Icons.graphic_eq_rounded,
        'desc': '海量老歌 · 伴奏铃声 · 蝰蛇音效',
      },
      '酷我音乐': {
        'name': '酷我音乐',
        'color': const Color(0xFFF59E0B),
        'icon': Icons.album_rounded,
        'desc': '经典金曲 · 发烧无损 · 严选母带',
      },
      '咪咕音乐': {
        'name': '咪咕音乐',
        'color': const Color(0xFFEC4899),
        'icon': Icons.verified_rounded,
        'desc': '正版无损 · 周杰伦等稀缺版权',
      },
      '哔哩哔哩': {
        'name': '哔哩哔哩 (B站)',
        'color': const Color(0xFFFB7299),
        'icon': Icons.tv_rounded,
        'desc': 'Live现场 · 独家翻唱 · 影视原声 · 二创',
      },
      '汽水音乐': {
        'name': '汽水音乐 (抖音)',
        'color': const Color(0xFF00E599),
        'icon': Icons.bubble_chart_rounded,
        'desc': '抖音热歌 · 流行翻唱 · 节奏BGM · 潮流小众',
      },
    };

    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isAllSelected = tempSelected.length == allSources.length;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.hub_rounded, color: Color(0xFF818CF8), size: 18),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '搜索音乐源配置',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '已选 ${tempSelected.length}/${allSources.length} 个音源',
                                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () {
                              setSheetState(() {
                                if (isAllSelected) {
                                  // 如果已全选，点击反选时保留网易云
                                  tempSelected.clear();
                                  tempSelected.add('网易云');
                                } else {
                                  tempSelected.addAll(allSources);
                                }
                              });
                            },
                            child: Text(
                              isAllSelected ? '反选' : '全选',
                              style: const TextStyle(color: Color(0xFF818CF8), fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: Colors.white38, size: 15),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '搜索时仅向勾选的平台发送网络请求，既节省流量又大幅提升搜索速度。',
                            style: TextStyle(color: Colors.white54, fontSize: 11.5, height: 1.3),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 音源列表 (支持滑动防溢出)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.48,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: allSources.map((key) {
                          final detail = sourceDetails[key] ?? {
                            'name': key,
                            'color': const Color(0xFF8B5CF6),
                            'icon': Icons.music_note_rounded,
                            'desc': '在线音乐',
                          };
                          final isChecked = tempSelected.contains(key);
                          final color = detail['color'] as Color;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: isChecked ? color.withValues(alpha: 0.08) : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isChecked ? color.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.06),
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () {
                                setSheetState(() {
                                  if (isChecked) {
                                    if (tempSelected.length <= 1) {
                                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('请至少保留一个音乐源进行搜索'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                      return;
                                    }
                                    tempSelected.remove(key);
                                  } else {
                                    tempSelected.add(key);
                                  }
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: color.withValues(alpha: 0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(detail['icon'] as IconData, color: color, size: 18),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                detail['name'] as String,
                                                style: TextStyle(
                                                  color: isChecked ? Colors.white : Colors.white60,
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                decoration: BoxDecoration(
                                                  color: color.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  key,
                                                  style: TextStyle(
                                                    color: color,
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            detail['desc'] as String,
                                            style: TextStyle(
                                              color: isChecked ? Colors.white54 : Colors.white30,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Checkbox(
                                      value: isChecked,
                                      activeColor: color,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                      onChanged: (v) {
                                        setSheetState(() {
                                          if (v == true) {
                                            tempSelected.add(key);
                                          } else {
                                            if (tempSelected.length <= 1) {
                                              ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(
                                                  content: Text('请至少保留一个音乐源进行搜索'),
                                                  duration: Duration(seconds: 2),
                                                ),
                                              );
                                              return;
                                            }
                                            tempSelected.remove(key);
                                          }
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () {
                      final chosen = tempSelected.isEmpty ? Set<String>.from(allSources) : tempSelected;
                      setState(() {
                        _enabledSources = Set<String>.from(chosen);
                      });
                      DatabaseService().saveEnabledSources(chosen.toList());
                      Navigator.pop(ctx);

                      if (_hasSearched && _searchController.text.trim().isNotEmpty) {
                        _doSearch(_searchController.text);
                      } else {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('音源配置已保存，已启用 ${chosen.length} 个搜索平台'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    child: Text(
                      '确定保存 (已启用 ${tempSelected.length} 个音源)',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  // 未搜索时：搜索历史标签 + 热搜雷达 + 官方权威音乐榜单
  Widget _buildDefaultDiscoveryChips() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. 搜索历史
        StreamBuilder<List<String>>(
          stream: DatabaseService().searchHistoryStream,
          initialData: DatabaseService().searchHistory,
          builder: (context, histSnap) {
            final history = histSnap.data ?? [];
            if (history.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('搜索历史', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                      InkWell(
                        onTap: () async {
                          await DatabaseService().clearSearchHistory();
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline_rounded, size: 14, color: Colors.white38),
                              SizedBox(width: 2),
                              Text('清空', style: TextStyle(color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: history.map((kw) {
                      return InputChip(
                        label: Text(kw, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                        backgroundColor: const Color(0xFF131A29),
                        side: const BorderSide(color: Colors.white10),
                        deleteIconColor: Colors.white38,
                        deleteIcon: const Icon(Icons.close_rounded, size: 13),
                        onDeleted: () async {
                          await DatabaseService().removeSearchHistory(kw);
                        },
                        onPressed: () {
                          _searchController.text = kw;
                          _doSearch(kw);
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
            );
          },
        ),

        // 2. 热搜雷达 (流式热门搜索词)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  Icon(Icons.local_fire_department_rounded, color: Color(0xFFEF4444), size: 18),
                  SizedBox(width: 6),
                  Text('热搜雷达', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _hotKeywordsFuture,
                builder: (context, snapshot) {
                  final keywords = snapshot.data ?? [
                    {'name': '周杰伦', 'hot': true},
                    {'name': '陈奕迅', 'hot': true},
                    {'name': '林俊杰', 'hot': true},
                    {'name': '薛之谦', 'hot': false},
                    {'name': '告五人', 'hot': false},
                    {'name': '邓紫棋', 'hot': false},
                    {'name': '毛不易', 'hot': false},
                    {'name': '许嵩', 'hot': false},
                    {'name': '陶喆', 'hot': false},
                    {'name': '晴天', 'hot': false},
                    {'name': '经典老歌', 'hot': false},
                    {'name': '欧美流行榜', 'hot': false},
                  ];

                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: keywords.map((item) {
                      final name = item['name'] as String;
                      final isHot = item['hot'] as bool;
                      return ActionChip(
                        avatar: isHot ? const Icon(Icons.whatshot_rounded, size: 13, color: Color(0xFFEF4444)) : null,
                        label: Text(name, style: TextStyle(color: isHot ? const Color(0xFFFCA5A5) : Colors.white70, fontSize: 11.5)),
                        backgroundColor: isHot ? const Color(0x25EF4444) : const Color(0xFF131A29),
                        side: BorderSide(color: isHot ? const Color(0x55EF4444) : Colors.white10),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onPressed: () {
                          _searchController.text = name;
                          _doSearch(name);
                        },
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),

        // 3. 官方权威音乐榜单卡片 (自适应底栏高度：滑到底部时刚好贴合在播放栏上方，去除多余空白)
        StreamBuilder<Song?>(
          stream: PlayerService().currentSongStream,
          initialData: PlayerService().currentSong,
          builder: (context, songSnap) {
            final hasSong = songSnap.data != null;
            final bottomPad = kBottomNavigationBarHeight +
                MediaQuery.paddingOf(context).bottom +
                (hasSong ? 72.0 : 16.0);
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, bottomPad),
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.leaderboard_rounded, color: Color(0xFF818CF8), size: 18),
                      SizedBox(width: 6),
                      Text('官方权威榜单', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF818CF8)),
                    label: const Text('刷新', style: TextStyle(color: Color(0xFF818CF8), fontSize: 11)),
                    onPressed: () {
                      setState(() {
                        _chartsFuture = MusicApi.fetchTopCharts();
                        _hotKeywordsFuture = MusicApi.fetchHotKeywords();
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _chartsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 160,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF818CF8)),
                      ),
                    );
                  }
                  final charts = snapshot.data ?? [];
                  if (charts.isEmpty) {
                    return const SizedBox(
                      height: 80,
                      child: Center(child: Text('暂未能拉取到榜单数据', style: TextStyle(color: Colors.white38, fontSize: 12))),
                    );
                  }

                  return ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: charts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final chart = charts[i];
                      final songs = (chart['songs'] as List<dynamic>).cast<Song>();
                      final title = chart['title'] as String;
                      final badge = chart['badge'] as String;

                      Color startColor;
                      Color endColor;
                      IconData chartIcon;
                      if (title.contains('热歌')) {
                        startColor = const Color(0xFFEF4444);
                        endColor = const Color(0xFF991B1B);
                        chartIcon = Icons.local_fire_department_rounded;
                      } else if (title.contains('飙升')) {
                        startColor = const Color(0xFF8B5CF6);
                        endColor = const Color(0xFF5B21B6);
                        chartIcon = Icons.trending_up_rounded;
                      } else if (title.contains('新歌')) {
                        startColor = const Color(0xFF10B981);
                        endColor = const Color(0xFF065F46);
                        chartIcon = Icons.fiber_new_rounded;
                      } else {
                        startColor = const Color(0xFF3B82F6);
                        endColor = const Color(0xFF1E40AF);
                        chartIcon = Icons.star_rounded;
                      }

                      return InkWell(
                        onTap: () => _showChartDetailSheet(context, title, songs),
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131A29),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 榜单卡片封面
                              Container(
                                width: 85,
                                height: 85,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [startColor, endColor],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: startColor.withValues(alpha: 0.35),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Stack(
                                  children: [
                                    Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(chartIcon, color: Colors.white, size: 28),
                                          const SizedBox(height: 4),
                                          Text(
                                            title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Positioned(
                                      top: 4,
                                      left: 4,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.black38,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          badge,
                                          style: const TextStyle(color: Colors.white, fontSize: 8.5),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),

                              // 前 3 首榜单歌曲预览
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    ...songs.take(3).toList().asMap().entries.map((entry) {
                                      final rank = entry.key + 1;
                                      final s = entry.value;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 2),
                                        child: Row(
                                          children: [
                                            Text(
                                              '$rank. ',
                                              style: TextStyle(
                                                color: rank == 1
                                                    ? const Color(0xFFFBBF24)
                                                    : (rank == 2 ? const Color(0xFFCBD5E1) : Colors.white54),
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                '${s.name} - ${s.artist}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                  ],
                                ),
                              ),

                              // 一键播放全部按钮
                              IconButton(
                                icon: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xFF6366F1),
                                  ),
                                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
                                ),
                                onPressed: () {
                                  if (songs.isNotEmpty) {
                                    PlayerService().setPlaylist(songs, startIndex: 0);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('已开始播放【$title】全部 ${songs.length} 首歌曲'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                                tooltip: '一键播放全部',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    ),
  ],
);
  }

  void _showChartDetailSheet(BuildContext context, String title, List<Song> songs) {
    _searchFocusNode.unfocus();
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Container(
            height: MediaQuery.of(context).size.height * 0.78,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 顶部控制条：榜单名 + 批量下载 + 随机播放 + 顺序播放（同一行极简紧凑）
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const Spacer(),
                    // 批量下载当前榜单
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: const BorderSide(color: Color(0x4438BDF8)),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.download_rounded, size: 14),
                      label: const Text('批量下载', style: TextStyle(fontSize: 11.5)),
                      onPressed: () {
                        DownloadSheet.showBatchDownload(context, songs, title: '$title 批量下载');
                      },
                    ),
                    const SizedBox(width: 5),
                    // 随机播放全部
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF818CF8),
                        side: const BorderSide(color: Color(0x44818CF8)),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.shuffle_rounded, size: 14),
                      label: const Text('随机', style: TextStyle(fontSize: 11.5)),
                      onPressed: () {
                        if (songs.isNotEmpty) {
                          Navigator.pop(ctx);
                          PlayerService().setPlayMode(PlayMode.shuffle);
                          final randIdx = Random().nextInt(songs.length);
                          PlayerService().setPlaylist(songs, startIndex: randIdx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已开始【$title】随机播放 (共${songs.length}首)')),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 5),
                    // 顺序播放全部
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 16, color: Colors.white),
                      label: const Text('播放全部', style: TextStyle(color: Colors.white, fontSize: 11.5)),
                      onPressed: () {
                        if (songs.isNotEmpty) {
                          Navigator.pop(ctx);
                          PlayerService().setPlayMode(PlayMode.listLoop);
                          PlayerService().setPlaylist(songs, startIndex: 0);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已开始【$title】顺序播放全部 ${songs.length} 首')),
                          );
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(color: Colors.white10, height: 1),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.builder(
                    itemCount: songs.length,
                    itemBuilder: (context, idx) {
                      final s = songs[idx];
                      return _buildChartSongItem(context, s, idx, songs);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }


  Widget _buildChartSongItem(BuildContext context, Song s, int idx, List<Song> songs) {
    final rank = idx + 1;
    final isTop1 = rank == 1;
    final isTop2 = rank == 2;
    final isTop3 = rank == 3;

    Color rankColor;
    BoxDecoration? rankBadgeDeco;
    if (isTop1) {
      rankColor = Colors.white;
      rankBadgeDeco = BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFD97706)]),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(color: const Color(0xFFF59E0B).withValues(alpha: 0.35), blurRadius: 4, offset: const Offset(0, 1)),
        ],
      );
    } else if (isTop2) {
      rankColor = Colors.white;
      rankBadgeDeco = BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF94A3B8), Color(0xFF64748B)]),
        borderRadius: BorderRadius.circular(6),
      );
    } else if (isTop3) {
      rankColor = Colors.white;
      rankBadgeDeco = BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFB45309), Color(0xFF78350F)]),
        borderRadius: BorderRadius.circular(6),
      );
    } else {
      rankColor = Colors.white38;
      rankBadgeDeco = null;
    }

    return StreamBuilder<Song?>(
      stream: PlayerService().currentSongStream,
      initialData: PlayerService().currentSong,
      builder: (context, snap) {
        final isPlaying = snap.data?.id == s.id && snap.data?.source == s.source;

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: isPlaying ? const Color(0x1F6366F1) : const Color(0xFF131A29).withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPlaying ? const Color(0xFF6366F1).withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.04),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                PlayerService().setPlaylist(songs, startIndex: idx);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
                child: Row(
                  children: [
                    // 左侧内容区：占用框宽度的 80% (4/5)
                    Expanded(
                      flex: 4,
                      child: Row(
                        children: [
                          // 排名徽章
                          Container(
                            width: 25,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: rankBadgeDeco,
                            child: Text(
                              rank < 10 ? '0$rank' : '$rank',
                              style: TextStyle(
                                color: rankColor,
                                fontWeight: FontWeight.bold,
                                fontSize: (isTop1 || isTop2 || isTop3) ? 11.5 : 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),

                          // 封面
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Stack(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  color: const Color(0xFF1E293B),
                                  child: s.coverUrl.isNotEmpty
                                      ? Image.network(
                                          s.coverUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => const Icon(Icons.music_note_rounded, color: Colors.white38, size: 20),
                                        )
                                      : const Icon(Icons.music_note_rounded, color: Colors.white38, size: 20),
                                ),
                                if (isPlaying)
                                  Container(
                                    width: 40,
                                    height: 40,
                                    color: Colors.black45,
                                    child: const Center(
                                      child: Icon(Icons.volume_up_rounded, color: Color(0xFF818CF8), size: 18),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),

                          // 歌名与歌手信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  style: TextStyle(
                                    color: isPlaying ? const Color(0xFF818CF8) : Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color: const Color(0x22F59E0B),
                                        borderRadius: BorderRadius.circular(3),
                                        border: Border.all(color: const Color(0x44F59E0B)),
                                      ),
                                      child: const Text(
                                        'FLAC',
                                        style: TextStyle(color: Color(0xFFFBBF24), fontSize: 8.5, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '${s.artist}${s.album.isNotEmpty ? ' · ${s.album}' : ''}',
                                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 右侧操作区：占用框宽度的 20% (1/5)，在虚线右侧平均分散排布
                    Expanded(
                      flex: 1,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          StreamBuilder<List<Song>>(
                            stream: DatabaseService().downloadsStream,
                            initialData: DatabaseService().downloads,
                            builder: (context, snap) {
                              final downloads = snap.data ?? DatabaseService().downloads;
                              final match = DatabaseService().checkDownloadStatus(s, downloads);

                              IconData icon;
                              Color color;
                              String tip;
                              if (match.canUpgrade) {
                                icon = Icons.upgrade_rounded;
                                color = const Color(0xFF38BDF8);
                                tip = '可升级音质 (线上提供更高品质)';
                              } else if (match.isExact) {
                                icon = Icons.check_circle_rounded;
                                color = const Color(0xFF10B981);
                                tip = '已在本地曲库 (点击管理)';
                              } else if (match.isVariant) {
                                icon = Icons.file_download_done_rounded;
                                color = const Color(0xFF818CF8);
                                tip = '本地已有同名版本 (点击下载此版)';
                              } else {
                                icon = Icons.download_rounded;
                                color = Colors.white70;
                                tip = '下载歌曲';
                              }

                              return Tooltip(
                                message: tip,
                                child: InkResponse(
                                  onTap: () => _downloadChartSong(context, s, matchResult: match),
                                  radius: 14,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 1.5, vertical: 6),
                                    child: Icon(icon, color: color, size: 20),
                                  ),
                                ),
                              );
                            },
                          ),
                          Tooltip(
                            message: '更多操作',
                            child: InkResponse(
                              onTap: () => _showChartSongOptions(context, s, songs, idx),
                              radius: 14,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 1.5, vertical: 6),
                                child: Icon(Icons.more_vert_rounded, color: Colors.white54, size: 19),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _downloadChartSong(BuildContext context, Song song, {DownloadMatchResult? matchResult}) {
    DownloadSheet.show(context, song, matchResult: matchResult);
  }

  void _showChartSongOptions(BuildContext context, Song song, List<Song> songs, int idx) {
    SongOptionsSheet.show(context, song, playlistContext: songs, playlistIndex: idx);
  }

  // 已搜索时：方案 B 紧凑可折叠多维动态联动筛选栏
  Widget _buildDynamicFilterSection() {
    final platforms = _dynamicPlatforms;
    final qualities = _dynamicQualities;
    final artists = _dynamicArtists;
    final activeCount = _activeFilterCount;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部折叠栏控制条：筛选状态 & 展开/收起切换 & 重置按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, size: 14, color: Color(0xFF818CF8)),
                const SizedBox(width: 4),
                const Text('条件筛选', style: TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold)),
                if (activeCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$activeCount', style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: _resetFilters,
                    child: const Text('重置', style: TextStyle(color: Color(0xFFF87171), fontSize: 11)),
                  ),
                ],
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _isFilterExpanded = !_isFilterExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _isFilterExpanded ? '收起筛选' : '更多筛选',
                          style: TextStyle(
                            color: _isFilterExpanded ? const Color(0xFF818CF8) : Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          _isFilterExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: _isFilterExpanded ? const Color(0xFF818CF8) : Colors.white54,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // 基础第一行：平台选择（网易云、QQ音乐、酷狗、酷我、咪咕等）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('平台: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                ...platforms.map((p) {
                  final active = _filterPlatforms.contains(p);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(p, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                      selected: active,
                      selectedColor: const Color(0xFF6366F1),
                      backgroundColor: const Color(0xFF0E1420),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onSelected: (v) => _onPlatformSelected(p),
                    ),
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // 基础第二行：音质选择（随所选平台联动级联变化）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('音质: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                ...qualities.map((q) {
                  final active = _filterQualities.contains(q);
                  String label = q;
                  if (q == 'FLAC') label = '无损FLAC';
                  if (q == '320k') label = '320k极高';
                  if (q == '标准') label = '128k标准';
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(label, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                      selected: active,
                      selectedColor: const Color(0xFF06B6D4),
                      backgroundColor: const Color(0xFF0E1420),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onSelected: (v) => _toggleFilterItem(_filterQualities, q),
                    ),
                  );
                }),
              ],
            ),
          ),

          // 方案 B：折叠展开后的进阶多维筛选
          if (_isFilterExpanded) ...[
            const SizedBox(height: 4),
            // 第三行：文件大小区间筛选
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('大小: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['全部', '< 5MB', '5-15MB', '15-30MB', '> 30MB'].map((sz) {
                    final active = _filterSizeRanges.contains(sz);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(sz, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFF10B981),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) => _toggleFilterItem(_filterSizeRanges, sz),
                      ),
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // 第四行：歌手列表（随所选平台联动级联变化）
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('歌手: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...artists.map((ar) {
                    final active = _filterArtists.contains(ar);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(ar, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFF8B5CF6),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) => _toggleFilterItem(_filterArtists, ar),
                      ),
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // 第五行：时长选择
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('时长: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['全部', '< 1分钟', '1-6分钟', '> 6分钟'].map((dur) {
                    final active = _filterDurations.contains(dur);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(dur, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFFF59E0B),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) => _toggleFilterItem(_filterDurations, dur),
                      ),
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // 第六行：版本属性与下载状态
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('属性: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['全部', '排除伴奏', '排除Live', '仅看Live'].map((ver) {
                    final active = _filterVersions.contains(ver);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(ver, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFFEC4899),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) => _toggleFilterItem(_filterVersions, ver),
                      ),
                    );
                  }),
                  const SizedBox(width: 8),
                  const Text('状态: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['全部', '未下载', '已下载'].map((st) {
                    final active = _filterDownloadStatuses.contains(st);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(st, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFF3B82F6),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) => _toggleFilterItem(_filterDownloadStatuses, st),
                      ),
                    );
                  }),
                ],
              ),
            ),

            const SizedBox(height: 4),

            // 第七行：排序规则
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('排序: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['默认', '音质优先', '体积最大', '时长最长'].map((sort) {
                    final active = _sortOrder == sort;
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(sort, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFF14B8A6),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (v) {
                          setState(() => _sortOrder = sort);
                          _saveSearchPreferences();
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/* ================= 搜索页吸顶 Header 代理 ================= */
class _SearchStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  _SearchStickyHeaderDelegate({
    required this.height,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0D14),
        border: overlapsContent
            ? const Border(bottom: BorderSide(color: Colors.white10, width: 0.5))
            : null,
      ),
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _SearchStickyHeaderDelegate oldDelegate) {
    return true;
  }
}

/* ================= 歌曲列表条目 ================= */
class SongListItem extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool showDownloadButton;

  const SongListItem({
    super.key,
    required this.song,
    required this.onTap,
    this.showDownloadButton = true,
  });

  void _onDownloadTap(BuildContext context, {DownloadMatchResult? matchResult}) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    showDownloadBottomSheet(context, song, matchResult: matchResult);
  }

  /// 公共静态下载确认/防重/音质升级弹窗 (统一使用 DownloadSheet.show，全档位无损/320k/128k一致体验)
  static void showDownloadBottomSheet(BuildContext context, Song song, {DownloadMatchResult? matchResult}) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    DownloadSheet.show(context, song, matchResult: matchResult);
  }

  static Color _getPlatformColor(String source) {
    if (source.contains('网易')) return const Color(0xFFEF4444);
    if (source.contains('QQ')) return const Color(0xFF10B981);
    if (source.contains('酷狗')) return const Color(0xFF0284C7);
    if (source.contains('酷我')) return const Color(0xFFF59E0B);
    if (source.contains('咪咕')) return const Color(0xFFEC4899);
    if (source.contains('哔哩') || source.contains('bilibili') || source.contains('B站')) return const Color(0xFFFB7299);
    if (source.contains('汽水') || source.contains('soda') || source.contains('抖音')) return const Color(0xFF00E599);
    return const Color(0xFF8B5CF6);
  }

  static String _getPlatformShortName(String source) {
    if (source.contains('网易')) return '网易云';
    if (source.contains('QQ')) return 'QQ';
    if (source.contains('酷狗')) return '酷狗';
    if (source.contains('酷我')) return '酷我';
    if (source.contains('咪咕')) return '咪咕';
    if (source.contains('哔哩') || source.contains('bilibili') || source.contains('B站')) return 'B站';
    if (source.contains('汽水') || source.contains('soda') || source.contains('抖音')) return '汽水';
    return source.length > 3 ? source.substring(0, 3) : source;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Song?>(
      stream: PlayerService().currentSongStream,
      initialData: PlayerService().currentSong,
      builder: (context, playingSnap) {
        final current = playingSnap.data ?? PlayerService().currentSong;
        final isPlayingThis = current != null &&
            (current.key == song.key || (current.id == song.id && current.source == song.source));

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: isPlayingThis
                ? const Color(0xFF6366F1).withValues(alpha: 0.18)
                : const Color(0xFF131A29).withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isPlayingThis ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.04),
              width: isPlayingThis ? 1.5 : 1.0,
            ),
            boxShadow: isPlayingThis
                ? [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onTap: onTap,
              onLongPress: () {
                _showSongOptions(context);
              },
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 44,
                  height: 44,
                  color: const Color(0xFF1E293B),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      song.coverUrl.isNotEmpty
                          ? Image.network(
                              song.coverUrl,
                              fit: BoxFit.cover,
                              width: 44,
                              height: 44,
                              errorBuilder: (context, error, stack) => const Icon(Icons.music_note_rounded, color: Colors.white38),
                            )
                          : const Icon(Icons.music_note_rounded, color: Colors.white38),
                      if (isPlayingThis)
                        Container(
                          width: 44,
                          height: 44,
                          color: Colors.black.withValues(alpha: 0.45),
                          child: const Center(
                            child: Icon(Icons.volume_up_rounded, color: Color(0xFF818CF8), size: 20),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      song.name,
                      style: TextStyle(
                        color: isPlayingThis ? const Color(0xFF818CF8) : Colors.white,
                        fontWeight: isPlayingThis ? FontWeight.bold : FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isPlayingThis) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF818CF8), width: 0.8),
                      ),
                      child: const Text('播放中', style: TextStyle(color: Color(0xFF818CF8), fontSize: 9.5, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
              subtitle: Row(
                children: [
                  // 音质标签
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    margin: const EdgeInsets.only(right: 4, top: 3),
                    decoration: BoxDecoration(
                      color: song.isLossless ? const Color(0x22F59E0B) : const Color(0x2206B6D4),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: song.isLossless ? const Color(0x55F59E0B) : const Color(0x5506B6D4),
                      ),
                    ),
                    child: Text(
                      song.quality,
                      style: TextStyle(
                        color: song.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // 独立平台彩色微标 Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    margin: const EdgeInsets.only(right: 6, top: 3),
                    decoration: BoxDecoration(
                      color: _getPlatformColor(song.source).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: _getPlatformColor(song.source).withValues(alpha: 0.5),
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      _getPlatformShortName(song.source),
                      style: TextStyle(
                        color: _getPlatformColor(song.source),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // 歌手独占空间显示
                  Expanded(
                    child: Text(
                      song.artist,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showDownloadButton)
                    StreamBuilder<List<Song>>(
                      stream: DatabaseService().downloadsStream,
                      initialData: DatabaseService().downloads,
                      builder: (context, snap) {
                        final downloads = snap.data ?? DatabaseService().downloads;
                        final match = DatabaseService().checkDownloadStatus(song, downloads);

                        IconData iconData;
                        Color iconColor;
                        String labelText;
                        Color labelColor;

                        if (match.canUpgrade) {
                          iconData = Icons.upgrade_rounded;
                          iconColor = const Color(0xFF38BDF8);
                          labelText = '可升级';
                          labelColor = const Color(0xFF38BDF8);
                        } else if (match.isExact) {
                          iconData = Icons.check_circle_rounded;
                          iconColor = const Color(0xFF10B981);
                          labelText = '已下载';
                          labelColor = const Color(0xFF34D399);
                        } else if (match.isVariant) {
                          iconData = Icons.file_download_done_rounded;
                          iconColor = const Color(0xFF818CF8);
                          labelText = '已有版本';
                          labelColor = const Color(0xFF818CF8);
                        } else {
                          iconData = Icons.download_rounded;
                          iconColor = Colors.white70;
                          labelText = song.estimatedSizeStr;
                          labelColor = Colors.white38;
                        }

                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _onDownloadTap(context, matchResult: match),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(iconData, color: iconColor, size: 19),
                                Text(
                                  labelText,
                                  style: TextStyle(
                                    color: labelColor,
                                    fontSize: 9.0,
                                    fontWeight: (match.isDownloaded || match.canUpgrade) ? FontWeight.bold : FontWeight.w500,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white54, size: 19),
                    tooltip: '更多操作',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 32),
                    onPressed: () => _showSongOptions(context),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSongOptions(BuildContext context) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    showSongOptions(context, song, onTap: onTap);
  }

  /// 公共静态歌曲详情与操作弹窗（供主版本、聚合异版等列表条目统一复用）
  static void showSongOptions(BuildContext context, Song song, {VoidCallback? onTap}) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SongOptionsSheet.show(context, song, onTapPlay: onTap);
  }
}

/* ================= 底部迷你播放条 ================= */
class BottomMiniPlayer extends StatefulWidget {
  const BottomMiniPlayer({super.key});

  @override
  State<BottomMiniPlayer> createState() => _BottomMiniPlayerState();
}

class _BottomMiniPlayerState extends State<BottomMiniPlayer> with SingleTickerProviderStateMixin {
  bool _isCollapsed = false;
  late final AnimationController _spinController;
  StreamSubscription<PlayerState>? _playerStateSub;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    if (PlayerService().isPlaying) {
      _spinController.repeat();
    }
    _playerStateSub = PlayerService().stateStream.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.playing) {
        if (!_spinController.isAnimating) _spinController.repeat();
      } else {
        if (_spinController.isAnimating) _spinController.stop();
      }
    });
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = PlayerService();

    return StreamBuilder<Song?>(
      stream: playerService.currentSongStream,
      initialData: playerService.currentSong,
      builder: (context, songSnap) {
        final song = songSnap.data;
        if (song == null) return const SizedBox.shrink();

        return LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = constraints.maxWidth;
            final cardWidth = screenWidth - 20.0;
            const collapsedWidth = 62.0;
            const collapsedHeight = 52.0;

            final leftPosition = _isCollapsed ? (screenWidth - collapsedWidth) : 10.0;
            final curWidth = _isCollapsed ? collapsedWidth : cardWidth;
            final curHeight = _isCollapsed ? collapsedHeight : 60.0;
            final topPosition = _isCollapsed ? 8.0 : 4.0;

            return SizedBox(
              height: 70,
              width: screenWidth,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    left: leftPosition,
                    top: topPosition,
                    width: curWidth,
                    height: curHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        final dx = details.primaryDelta ?? 0;
                        if (_isCollapsed && dx < -5) {
                          setState(() => _isCollapsed = false);
                        } else if (!_isCollapsed && dx > 15) {
                          setState(() => _isCollapsed = true);
                        }
                      },
                      onHorizontalDragEnd: (details) {
                        final vx = details.primaryVelocity ?? 0;
                        if (_isCollapsed && vx < -80) {
                          setState(() => _isCollapsed = false);
                        } else if (!_isCollapsed && vx > 120) {
                          setState(() => _isCollapsed = true);
                        }
                      },
                      onTap: () {
                        if (_isCollapsed) {
                          setState(() => _isCollapsed = false);
                        } else {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => const PlayerBottomSheet(),
                          );
                        }
                      },
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _isCollapsed
                            ? _buildCollapsedVinylDock(song, playerService)
                            : _buildExpandedPlayerBar(song, playerService, cardWidth),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 折叠时展示的【贴边微光半圆黑胶唱片挂件】
  Widget _buildCollapsedVinylDock(Song song, PlayerService playerService) {
    return Container(
      key: const ValueKey('collapsed_vinyl_dock'),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(26)),
        border: Border.all(
          color: const Color(0xFF818CF8).withValues(alpha: 0.65),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(-2, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 左侧极简向左展开微光指示箭头
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(
              Icons.chevron_left_rounded,
              color: Color(0xFF818CF8),
              size: 16,
            ),
          ),
          const SizedBox(width: 2),
          // 核心黑胶唱片（带同心圆暗纹与自转动画）
          Container(
            width: 38,
            height: 38,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [
                  Color(0xFF334155),
                  Color(0xFF0F172A),
                  Color(0xFF020617),
                ],
                stops: [0.2, 0.7, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.2,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 4,
                ),
              ],
            ),
            child: RotationTransition(
              turns: _spinController,
              child: Padding(
                padding: const EdgeInsets.all(5.0),
                child: ClipOval(
                  child: song.coverUrl.isNotEmpty
                      ? Image.network(
                          song.coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _buildVinylCenterPlaceholder(),
                        )
                      : _buildVinylCenterPlaceholder(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVinylCenterPlaceholder() {
    return Container(
      color: const Color(0xFF1E293B),
      alignment: Alignment.center,
      child: const Icon(Icons.music_note_rounded, color: Color(0xFF818CF8), size: 16),
    );
  }

  /// 展开时的完整播放条
  Widget _buildExpandedPlayerBar(Song song, PlayerService playerService, double cardWidth) {
    return Container(
      key: const ValueKey('expanded_player_bar'),
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF161E2E).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF6366F1).withValues(alpha: 0.35),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 左侧歌曲信息区：严格占用框宽度的 11/20 (55%)
          Expanded(
            flex: 11,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 38,
                    height: 38,
                    color: const Color(0xFF1E293B),
                    child: song.coverUrl.isNotEmpty
                        ? Image.network(
                            song.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) =>
                                const Icon(Icons.music_note, color: Colors.white54),
                          )
                        : const Icon(Icons.music_note, color: Colors.white54),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.name,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${song.artist} · ${song.source}',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 右侧播放控制区：严格占用框宽度的 9/20 (45%)，在虚线右侧平均分散排布
          Expanded(
            flex: 9,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 1. 收藏按钮
                StreamBuilder<List<Song>>(
                  stream: DatabaseService().favoritesStream,
                  builder: (context, favSnap) {
                    final isFav = DatabaseService().isFavorite(song);
                    return Tooltip(
                      message: '收藏',
                      child: InkResponse(
                        onTap: () => DatabaseService().toggleFavorite(song),
                        radius: 14,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 6),
                          child: Icon(
                            isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: isFav ? const Color(0xFFEF4444) : Colors.white60,
                            size: 19,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 2. 上一首
                Tooltip(
                  message: '上一首',
                  child: InkResponse(
                    onTap: () => playerService.playPrev(),
                    radius: 14,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 6),
                      child: Icon(Icons.skip_previous_rounded, color: Colors.white70, size: 21),
                    ),
                  ),
                ),
                // 3. 播放/暂停
                StreamBuilder<PlayerState>(
                  stream: playerService.stateStream,
                  initialData: playerService.isPlaying ? PlayerState.playing : playerService.playerState,
                  builder: (context, snap) {
                    final isPlaying = (snap.data ?? playerService.playerState) == PlayerState.playing;
                    return Tooltip(
                      message: isPlaying ? '暂停' : '播放',
                      child: InkResponse(
                        onTap: () => playerService.togglePlay(),
                        radius: 16,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 6),
                          child: Icon(
                            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // 4. 下一首
                Tooltip(
                  message: '下一首',
                  child: InkResponse(
                    onTap: () => playerService.playNext(),
                    radius: 14,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 6),
                      child: Icon(Icons.skip_next_rounded, color: Colors.white70, size: 21),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ================= 下载管理选项卡 ================= */
class DownloadTab extends StatefulWidget {
  const DownloadTab({super.key});

  @override
  State<DownloadTab> createState() => DownloadTabState();
}

class DownloadTabState extends State<DownloadTab> {
  final Set<String> _filterStatuses = {'全部'};
  bool _isSelecting = false;
  final Set<String> _selectedTaskKeys = {};

  /// 供主界面拦截返回键调用：若正处于多选状态，则优雅退出多选，绝不触发退出应用提示
  bool handleBackPressed() {
    if (_isSelecting) {
      setState(() {
        _isSelecting = false;
        _selectedTaskKeys.clear();
      });
      return true;
    }
    return false;
  }

  void _toggleStatus(String st) {
    setState(() {
      _selectedTaskKeys.clear();
      _isSelecting = false;
      if (st == '全部') {
        _filterStatuses.clear();
        _filterStatuses.add('全部');
        return;
      }
      _filterStatuses.remove('全部');
      if (_filterStatuses.contains(st)) {
        _filterStatuses.remove(st);
        if (_filterStatuses.isEmpty) {
          _filterStatuses.add('全部');
        }
      } else {
        _filterStatuses.add(st);
      }
    });
  }

  bool _isTaskFailed(DownloadTask t) {
    final s = t.status;
    return _isLocalFileIssue(t) || s.contains('失败') || s.contains('失效') || s.contains('限制') || s.contains('版权') || s.contains('试听包');
  }

  bool _isLocalFileIssue(DownloadTask t) {
    final s = t.status;
    return s.contains('本地校验') || s.contains('本地文件') || s.contains('已有文件');
  }

  bool _isTaskInterrupted(DownloadTask t) {
    final s = t.status;
    return s.contains('未完成') || s.contains('暂停') || s.contains('中断');
  }

  List<DownloadTask> _getFilteredTasks(List<DownloadTask> tasks) {
    if (_filterStatuses.contains('全部')) return tasks;
    return tasks.where((t) {
      final isDl = t.status.contains('下载中') || t.status.contains('准备') || t.status.contains('重试') || t.status.contains('解析') || _isTaskInterrupted(t);
      final isDone = t.status == '已完成';
      final isFail = _isTaskFailed(t);
      if (_filterStatuses.contains('下载中') && isDl) return true;
      if (_filterStatuses.contains('已完成') && isDone) return true;
      if (_filterStatuses.contains('失败/受限') && isFail) return true;
      return false;
    }).toList();
  }

  void _confirmBatchDelete(DownloadService ds) {
    final count = _selectedTaskKeys.length;
    if (count == 0) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161E2E),
        title: const Text('批量清理任务', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定从下载任务队列中清理选中的 $count 个任务吗？\n（注：已成功下载到手机的本地音乐文件不受影响）',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text('彻底清理 ($count)', style: const TextStyle(color: Colors.white)),
            onPressed: () {
              Navigator.pop(ctx);
              ds.removeTasks(_selectedTaskKeys.toList());
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已成功清理 $count 个下载任务')),
                );
                setState(() {
                  _isSelecting = false;
                  _selectedTaskKeys.clear();
                });
              }
            },
          ),
        ],
      ),
    );
  }

  void _showAlternativeSourcesModal(DownloadTask task) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _AlternativeSourcesSheet(task: task),
    );
  }

  void _showLocalFileIssue(DownloadTask task) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161E2E),
        title: const Text('本地文件待检查', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${task.song.name} - ${task.song.artist}', style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 12),
              Text(task.status, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13, height: 1.4)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不处理', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              DownloadService().resumeTask(task);
            },
            child: const Text('重试下载', style: TextStyle(color: Color(0xFF818CF8))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showAlternativeSourcesModal(task);
            },
            child: const Text('全网换源', style: TextStyle(color: Color(0xFF818CF8))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = DownloadService();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        leading: _isSelecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
                onPressed: () {
                  setState(() {
                    _isSelecting = false;
                    _selectedTaskKeys.clear();
                  });
                },
              )
            : null,
        title: _isSelecting
            ? Text(
                '已选择 ${_selectedTaskKeys.length} 项',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              )
            : LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    if (constraints.maxWidth >= 100) ...[
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.download_rounded, color: Color(0xFF818CF8), size: 20),
                      ),
                      const SizedBox(width: 10),
                    ],
                    const Flexible(
                      child: Text(
                        '下载任务队列',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
        actions: _isSelecting
            ? [
                StreamBuilder<List<DownloadTask>>(
                  stream: downloadService.tasksStream,
                  initialData: downloadService.tasks,
                  builder: (context, snap) {
                    final allTasks = snap.data ?? [];
                    final filtered = _getFilteredTasks(allTasks);
                    final visibleKeys = filtered.map((t) => t.song.key).toSet();
                    final isAllSelected = filtered.isNotEmpty && visibleKeys.every((k) => _selectedTaskKeys.contains(k));
                    return TextButton(
                      child: Text(
                        isAllSelected ? '全不选' : '全选',
                        style: const TextStyle(color: Color(0xFF818CF8), fontSize: 13),
                      ),
                      onPressed: () {
                        setState(() {
                          if (isAllSelected) {
                            _selectedTaskKeys.removeAll(visibleKeys);
                            if (_selectedTaskKeys.isEmpty) _isSelecting = false;
                          } else {
                            _selectedTaskKeys.addAll(visibleKeys);
                          }
                        });
                      },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
                  tooltip: '批量清理选中任务',
                  onPressed: _selectedTaskKeys.isEmpty ? null : () => _confirmBatchDelete(downloadService),
                ),
              ]
            : [
                StreamBuilder<List<DownloadTask>>(
                  stream: downloadService.tasksStream,
                  initialData: downloadService.tasks,
                  builder: (context, snap) {
                    final all = snap.data ?? [];
                    final hasCompleted = all.any((t) => t.status == '已完成');
                    final hasFailed = all.any(_isTaskFailed);
                    final hasInterrupted = all.any(_isTaskInterrupted);

                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 全部恢复按钮 (带清晰边框与胶囊背景，紧挨着清理按钮)
                          if (hasInterrupted || hasFailed) ...[
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                downloadService.resumeAll();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已开始批量恢复下载任务')),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0x1F818CF8),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0x55818CF8)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.play_arrow_rounded, size: 14, color: Color(0xFF818CF8)),
                                    SizedBox(width: 3),
                                    Text('全部恢复', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12, fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          // 最右侧清理按钮 (带边框与下拉菜单，可选择清理受限项或清理已完成)
                          Theme(
                            data: Theme.of(context).copyWith(
                              popupMenuTheme: const PopupMenuThemeData(
                                color: Color(0xFF1E293B),
                                textStyle: TextStyle(color: Colors.white),
                              ),
                            ),
                            child: PopupMenuButton<String>(
                              tooltip: '清理任务选项',
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: const BorderSide(color: Color(0x33F87171)),
                              ),
                              onSelected: (val) {
                                if (val == 'failed') {
                                  downloadService.clearFailed();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已清除所有受限/失败任务')),
                                  );
                                } else if (val == 'completed') {
                                  downloadService.clearCompleted();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已清除所有已完成任务')),
                                  );
                                }
                              },
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'failed',
                                  enabled: hasFailed,
                                  child: Row(
                                    children: [
                                      Icon(Icons.remove_circle_outline_rounded, size: 16, color: hasFailed ? const Color(0xFFF87171) : Colors.white24),
                                      const SizedBox(width: 8),
                                      Text(
                                        '清理受限项',
                                        style: TextStyle(
                                          color: hasFailed ? const Color(0xFFF87171) : Colors.white24,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'completed',
                                  enabled: hasCompleted,
                                  child: Row(
                                    children: [
                                      Icon(Icons.cleaning_services_rounded, size: 16, color: hasCompleted ? const Color(0xFF38BDF8) : Colors.white24),
                                      const SizedBox(width: 8),
                                      Text(
                                        '清理已完成',
                                        style: TextStyle(
                                          color: hasCompleted ? Colors.white : Colors.white24,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0x1CF87171),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0x55F87171)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.cleaning_services_rounded, size: 13, color: Color(0xFFF87171)),
                                    SizedBox(width: 4),
                                    Text('清理', style: TextStyle(color: Color(0xFFF87171), fontSize: 12, fontWeight: FontWeight.w600)),
                                    Icon(Icons.arrow_drop_down_rounded, size: 15, color: Color(0xFFF87171)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
      ),
      body: StreamBuilder<List<DownloadTask>>(
        stream: downloadService.tasksStream,
        initialData: downloadService.tasks,
        builder: (context, snap) {
          final tasks = snap.data ?? [];
          if (tasks.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_for_offline_rounded, color: Colors.white12, size: 56),
                  SizedBox(height: 12),
                  Text('暂无下载队列任务', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  SizedBox(height: 6),
                  Text('在搜索发现中点击下载即可在此监控实时网速与进度', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            );
          }

          final filteredTasks = _getFilteredTasks(tasks);

          return Column(
            children: [
              // 状态筛选标签栏
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    ...['全部', '下载中', '已完成', '失败/受限'].map((st) {
                      int count = 0;
                      if (st == '全部') {
                        count = tasks.length;
                      } else if (st == '下载中') {
                        count = tasks.where((t) => t.status.contains('下载中') || t.status.contains('准备') || t.status.contains('重试') || t.status.contains('解析') || _isTaskInterrupted(t)).length;
                      } else if (st == '已完成') {
                        count = tasks.where((t) => t.status == '已完成').length;
                      } else if (st == '失败/受限') {
                        count = tasks.where(_isTaskFailed).length;
                      }
                      final active = _filterStatuses.contains(st);
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text('$st ($count)', style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 11)),
                          selected: active,
                          selectedColor: const Color(0xFF6366F1),
                          backgroundColor: const Color(0xFF131A29),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          onSelected: (_) => _toggleStatus(st),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              Expanded(
                child: filteredTasks.isEmpty
                    ? const Center(
                        child: Text('没有符合所选状态的任务', style: TextStyle(color: Colors.white38, fontSize: 13)),
                      )
                    : ListView.builder(
                        itemCount: filteredTasks.length,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
                        itemBuilder: (context, index) {
                          final task = filteredTasks[index];
                          final isCompleted = task.status == '已完成';
                          final isFailed = _isTaskFailed(task);
                          final isLocalIssue = _isLocalFileIssue(task);
                          final isInterrupted = _isTaskInterrupted(task);
                          final isSelected = _selectedTaskKeys.contains(task.song.key);

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131A29),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF6366F1)
                                    : Colors.white.withValues(alpha: 0.05),
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onLongPress: () {
                                  HapticFeedback.mediumImpact();
                                  setState(() {
                                    _isSelecting = true;
                                    _selectedTaskKeys.add(task.song.key);
                                  });
                                },
                                onTap: () {
                                  if (_isSelecting) {
                                    setState(() {
                                      if (_selectedTaskKeys.contains(task.song.key)) {
                                        _selectedTaskKeys.remove(task.song.key);
                                        if (_selectedTaskKeys.isEmpty) {
                                          _isSelecting = false;
                                        }
                                      } else {
                                        _selectedTaskKeys.add(task.song.key);
                                      }
                                    });
                                  } else {
                                    if (isLocalIssue) {
                                      _showLocalFileIssue(task);
                                    } else if (isFailed) {
                                      // 点击受限/失败任务，调起全网换源推荐弹窗
                                      _showAlternativeSourcesModal(task);
                                    } else if (isCompleted) {
                                      PlayerService().playSong(task.song);
                                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('正在播放: 《${task.song.name}》'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    } else if (task.status == '下载中' || task.status.contains('解析') || task.status.contains('重试')) {
                                      // 活跃下载中，点击暂停
                                      downloadService.pauseTask(task);
                                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('已暂停下载: 《${task.song.name}》'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    } else {
                                      // 未完成、已暂停或中断任务，点击恢复下载
                                      downloadService.resumeTask(task);
                                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('正在恢复下载: 《${task.song.name}》'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (_isSelecting) ...[
                                            Padding(
                                              padding: const EdgeInsets.only(right: 10),
                                              child: Icon(
                                                isSelected
                                                    ? Icons.check_circle_rounded
                                                    : Icons.radio_button_unchecked_rounded,
                                                color: isSelected
                                                    ? const Color(0xFF6366F1)
                                                    : Colors.white30,
                                                size: 22,
                                              ),
                                            ),
                                          ],
                                          Expanded(
                                            child: Text(
                                              '${task.song.name} - ${task.song.artist}',
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13.5),
                                              maxLines: isFailed ? null : 1,
                                              overflow: isFailed ? TextOverflow.visible : TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (!isCompleted && !isFailed) ...[
                                            GestureDetector(
                                              onTap: () {
                                                if (task.status == '下载中' || task.status.contains('解析') || task.status.contains('重试')) {
                                                  downloadService.pauseTask(task);
                                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text('已暂停下载: 《${task.song.name}》'),
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                } else {
                                                  downloadService.resumeTask(task);
                                                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text('正在恢复下载: 《${task.song.name}》'),
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                }
                                              },
                                              child: Padding(
                                                padding: const EdgeInsets.only(right: 6),
                                                child: Icon(
                                                  (task.status == '下载中' || task.status.contains('解析') || task.status.contains('重试'))
                                                      ? Icons.pause_circle_outline_rounded
                                                      : Icons.play_circle_outline_rounded,
                                                  color: const Color(0xFF06B6D4),
                                                  size: 20,
                                                ),
                                              ),
                                            ),
                                          ],
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: isCompleted
                                                  ? const Color(0x2210B981)
                                                  : isFailed
                                                      ? const Color(0x22EF4444)
                                                      : (isInterrupted || task.status.contains('暂停'))
                                                          ? const Color(0x22F59E0B)
                                                          : const Color(0x226366F1),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              isFailed ? (isLocalIssue ? '待检查' : '下载失败') : task.status,
                                              style: TextStyle(
                                                color: isCompleted
                                                    ? const Color(0xFF34D399)
                                                    : isFailed
                                                        ? const Color(0xFFF87171)
                                                        : (isInterrupted || task.status.contains('暂停'))
                                                            ? const Color(0xFFFBBF24)
                                                            : const Color(0xFF818CF8),
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: [
                                          Text(
                                            '${task.song.quality} · ${task.displaySizeStr} · ${task.song.source}',
                                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                                          ),
                                          if (task.speed.isNotEmpty)
                                            Text(
                                              task.speed,
                                              style: const TextStyle(color: Color(0xFF06B6D4), fontSize: 11, fontWeight: FontWeight.bold),
                                            ),
                                        ],
                                      ),
                                      if (task.status.contains('下载中')) ...[
                                        const SizedBox(height: 8),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(4),
                                          child: LinearProgressIndicator(
                                            value: task.progress > 0 ? task.progress : null,
                                            backgroundColor: Colors.white10,
                                            valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)),
                                            minHeight: 5,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${(task.progress * 100).toStringAsFixed(1)}%',
                                              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                                            ),
                                            const Text(
                                              '自动同步保存 .lrc 歌词',
                                              style: TextStyle(color: Color(0xFF10B981), fontSize: 10.5),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (isInterrupted && !_isSelecting) ...[
                                        const SizedBox(height: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF59E0B).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.25)),
                                          ),
                                          child: const Row(
                                            children: [
                                              Icon(Icons.replay_rounded, color: Color(0xFFFBBF24), size: 14),
                                              SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  '上次退出中断，点击卡片立即继续下载',
                                                  style: TextStyle(color: Color(0xFFFDE68A), fontSize: 11, fontWeight: FontWeight.w500),
                                                ),
                                              ),
                                              Icon(Icons.chevron_right_rounded, color: Color(0xFFFBBF24), size: 16),
                                            ],
                                          ),
                                        ),
                                      ],
                                      if (isFailed) ...[
                                        const SizedBox(height: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.25)),
                                          ),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Icon(isLocalIssue ? Icons.info_outline_rounded : Icons.error_outline_rounded, color: const Color(0xFF818CF8), size: 14),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      task.status,
                                                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 11, height: 1.4),
                                                    ),
                                                    if (!_isSelecting) ...[
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        isLocalIssue
                                                            ? '点击查看详情，可选择重试下载或全网换源'
                                                            : '可用顶部恢复重试，或点击全网换源',
                                                        style: const TextStyle(color: Color(0xFFC7D2FE), fontSize: 11, height: 1.4),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              if (!_isSelecting)
                                                const Icon(Icons.chevron_right_rounded, color: Color(0xFF818CF8), size: 16),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/* ================= 全网多源智能换源推荐弹窗 ================= */
class _AlternativeSourcesSheet extends StatefulWidget {
  final DownloadTask task;
  const _AlternativeSourcesSheet({required this.task});

  @override
  State<_AlternativeSourcesSheet> createState() => _AlternativeSourcesSheetState();
}

class _AlternativeSourcesSheetState extends State<_AlternativeSourcesSheet> {
  bool _isLoading = true;
  List<Song> _candidates = [];

  @override
  void initState() {
    super.initState();
    _loadAlternatives();
  }

  Future<void> _loadAlternatives() async {
    setState(() => _isLoading = true);
    try {
      final results = await MusicApi.searchAlternatives(widget.task.song);
      if (mounted) {
        setState(() {
          _candidates = results;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Color _getSourceColor(String source) {
    switch (source) {
      case 'QQ音乐':
        return const Color(0xFF10B981);
      case '酷狗音乐':
        return const Color(0xFF06B6D4);
      case '酷我音乐':
        return const Color(0xFFF59E0B);
      case '咪咕音乐':
        return const Color(0xFFEC4899);
      case '网易云':
        return const Color(0xFFEF4444);
      case '哔哩哔哩':
        return const Color(0xFFFB7299);
      case '汽水音乐':
        return const Color(0xFF00E599);
      default:
        return const Color(0xFF818CF8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final curSong = widget.task.song;

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部拖动条
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题与原受限信息
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.swap_horizontal_circle_rounded, color: Color(0xFF818CF8), size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '全网智能换源推荐',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '《${curSong.name}》- ${curSong.artist} · 原音源：${curSong.source}',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
                  tooltip: '重新检索全网可用源',
                  onPressed: _isLoading ? null : _loadAlternatives,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 10),

            // 候选列表
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF6366F1)),
                      SizedBox(height: 14),
                      Text(
                        '正在并发检索全网各主流平台可用音源...',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              )
            else if (_candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.music_off_rounded, color: Colors.white24, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        '暂未找到匹配的可用音源',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '可稍后重新检索，或返回下载队列重试',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _candidates.length,
                  itemBuilder: (context, idx) {
                    final cand = _candidates[idx];
                    final srcColor = _getSourceColor(cand.source);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                      ),
                      child: Row(
                        children: [
                          // 平台徽标
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: srcColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: srcColor.withValues(alpha: 0.4)),
                            ),
                            child: Text(
                              cand.source,
                              style: TextStyle(
                                color: srcColor,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // 歌曲信息
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  cand.name,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      margin: const EdgeInsets.only(right: 6),
                                      decoration: BoxDecoration(
                                        color: cand.isLossless ? const Color(0x22F59E0B) : const Color(0x2206B6D4),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        cand.quality,
                                        style: TextStyle(
                                          color: cand.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${cand.artist} · ${cand.durationString}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // 试听按钮
                          IconButton(
                            icon: const Icon(Icons.play_circle_outline_rounded, color: Colors.white70, size: 24),
                            tooltip: '在线试听鉴赏',
                            onPressed: () {
                              PlayerService().playSong(cand);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('正在试听来自【${cand.source}】的《${cand.name}》')),
                              );
                            },
                          ),
                          // 换此源下载按钮
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF6366F1),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('换源下载', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              final ds = DownloadService();
                              // 移除原失败任务
                              ds.removeTask(curSong.id, source: curSong.source);
                              // 开启新源下载
                              ds.startDownload(cand,
                                preferLossless: widget.task.preferLossless,
                                targetQuality: widget.task.targetQuality);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('已自动切换至【${cand.source}】启动下载: 《${cand.name}》'),
                                  backgroundColor: const Color(0xFF10B981),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
