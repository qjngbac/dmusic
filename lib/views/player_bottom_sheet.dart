import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:share_plus/share_plus.dart';
import '../models/song.dart';
import '../models/lyric.dart';
import '../models/playlist.dart';
import '../services/player_service.dart';
import '../services/database_service.dart';
import 'download_sheet.dart';

class PlayerBottomSheet extends StatefulWidget {
  const PlayerBottomSheet({super.key});

  @override
  State<PlayerBottomSheet> createState() => _PlayerBottomSheetState();
}

class _PlayerBottomSheetState extends State<PlayerBottomSheet>
    with TickerProviderStateMixin {
  final PlayerService _playerService = PlayerService();
  final DatabaseService _dbService = DatabaseService();
  final ScrollController _lyricsScrollController = ScrollController();

  bool _showLyrics = false;
  bool _showOffsetToolbar = false;
  int _lastActiveLyricIndex = -1;
  double? _dragPositionSeconds;
  final Map<int, GlobalKey> _lyricKeys = {};
  bool _isUserScrollingLyrics = false;
  Timer? _userScrollResumeTimer;
  String? _currentSongId;

  late AnimationController _discAnimController;
  late AnimationController _armAnimController;
  late Animation<double> _armAnimation;
  StreamSubscription<PlayerState>? _playerStateSub;

  @override
  void initState() {
    super.initState();
    _discAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    );
    _armAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _armAnimation = Tween<double>(begin: -0.38, end: 0.05).animate(
      CurvedAnimation(parent: _armAnimController, curve: Curves.easeInOut),
    );

    if (_playerService.isPlaying) {
      _discAnimController.repeat();
      _armAnimController.value = 1.0;
    }

    _playerStateSub = _playerService.stateStream.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.playing) {
        if (!_discAnimController.isAnimating) {
          _discAnimController.repeat();
        }
        _armAnimController.forward();
      } else {
        _discAnimController.stop();
        _armAnimController.reverse();
      }
    });
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _userScrollResumeTimer?.cancel();
    _discAnimController.dispose();
    _armAnimController.dispose();
    _lyricsScrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveLyric(int activeIndex, {bool force = false}) {
    if (!_showLyrics || activeIndex < 0) return;
    if (_isUserScrollingLyrics && !force) return;
    if (!force && activeIndex == _lastActiveLyricIndex) return;
    _lastActiveLyricIndex = activeIndex;

    final key = _lyricKeys[activeIndex];
    final ctx = key?.currentContext;
    if (ctx != null && ctx.mounted) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5, // 永远将当前正在唱的歌词高亮行精准锁定在视口中央
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    } else if (_lyricsScrollController.hasClients && _lyricsScrollController.position.hasContentDimensions) {
      // 容错兜底 (M6-1)：当歌词被划出屏幕较远导致 Widget 被 Flutter 回收（ctx == null）时，
      // 基于列表当前高度与歌词总数进行平滑比例滚动召回，并在挂载后精准居中
      final totalItems = _playerService.currentLyrics.length;
      if (totalItems > 0) {
        final maxScroll = _lyricsScrollController.position.maxScrollExtent;
        final targetOffset = (activeIndex / totalItems * maxScroll).clamp(0.0, maxScroll);
        _lyricsScrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeInOutCubic,
        ).then((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final retryCtx = _lyricKeys[activeIndex]?.currentContext;
            if (retryCtx != null && retryCtx.mounted) {
              Scrollable.ensureVisible(
                retryCtx,
                alignment: 0.5,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
              );
            }
          });
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return StreamBuilder<Song?>(
      stream: _playerService.currentSongStream,
      initialData: _playerService.currentSong,
      builder: (context, songSnap) {
        final song = songSnap.data;
        if (song == null) {
          return const SizedBox(
            height: 220,
            child: Center(
              child: Text('暂无正在播放的歌曲', style: TextStyle(color: Colors.white60)),
            ),
          );
        }

        if (song.id != _currentSongId) {
          _currentSongId = song.id;
          _lyricKeys.clear();
          _lastActiveLyricIndex = -1;
          _dragPositionSeconds = null;
        }

        return Container(
          height: screenHeight * 0.94,
          clipBehavior: Clip.antiAlias,
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Stack(
            children: [
              // 1. 底层高斯模糊氛围微光背景
              if (song.coverUrl.isNotEmpty)
                Positioned.fill(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
                    child: Image.network(
                      song.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, err, stack) => Container(color: const Color(0xFF0B0F19)),
                    ),
                  ),
                ),
              // 渐变暗化遮罩层
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0xFF090D16).withValues(alpha: 0.85),
                        const Color(0xFF0F1422).withValues(alpha: 0.96),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. 前景主体内容
              SafeArea(
                child: Column(
                  children: [
                    // 顶部导航栏 (下滑收起 & 标题 & 均衡器EQ快捷入口)
                    _buildTopBar(context, song),

                    // 中间视觉区：黑胶唱片 或 全屏卡拉OK歌词
                    Expanded(
                      child: _showLyrics
                          ? _buildLyricsView(song)
                          : _buildVinylTurntable(song),
                    ),

                    // 歌名、歌手与操作列
                    _buildSongMetaAndActions(context, song),

                    // 进度条与播放时长
                    _buildScrubber(song),

                    // 核心播放控制按钮栏 (模式, 上一首, 播放/暂停, 下一首, 队列)
                    _buildPlaybackControls(context),

                    // 辅助功能行 (睡眠定时器, 倍速, 10段EQ均衡器)
                    _buildAuxiliaryBar(context),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 顶部栏
  Widget _buildTopBar(BuildContext context, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 30),
            onPressed: () => Navigator.pop(context),
            tooltip: '收起播放器',
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                _showLyrics ? '歌词同步' : '正在播放',
                style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.equalizer_rounded, color: Color(0xFF818CF8), size: 24),
            onPressed: () => _showEqSheet(context),
            tooltip: '10段均衡器 EQ',
          ),
        ],
      ),
    );
  }

  /// 黑胶唱片模式 (旋转黑胶盘 + 唱针起落 + 左右滑动切歌)
  Widget _buildVinylTurntable(Song song) {
    final size = MediaQuery.of(context).size;
    final discSize = (size.width * 0.60).clamp(190.0, 255.0);
    final coverSize = discSize * 0.62;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -250) {
            _playerService.playNext();
          } else if (details.primaryVelocity! > 250) {
            _playerService.playPrev();
          }
        }
      },
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta != null && details.primaryDelta! > 14) {
          Navigator.pop(context);
        }
      },
      onTap: () {
        setState(() {
          _showLyrics = true;
          _lastActiveLyricIndex = -1;
        });
      },
      child: Center(
        child: SizedBox(
          height: discSize + 36,
          width: size.width,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 旋转黑胶唱片
              AnimatedBuilder(
                animation: _discAnimController,
                builder: (context, child) {
                  return Transform.rotate(
                    angle: _discAnimController.value * 2 * pi,
                    child: child,
                  );
                },
                child: Container(
                  width: discSize,
                  height: discSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: [
                        Color(0xFF0F172A),
                        Color(0xFF1E293B),
                        Color(0xFF080B13),
                        Color(0xFF1A2333),
                        Color(0xFF04060A),
                      ],
                      stops: [0.0, 0.38, 0.68, 0.88, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.7),
                        blurRadius: 32,
                        spreadRadius: 4,
                        offset: const Offset(0, 12),
                      ),
                      BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                        blurRadius: 40,
                        spreadRadius: -4,
                      ),
                    ],
                    border: Border.all(color: const Color(0xFF334155), width: 3.5),
                  ),
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        ClipOval(
                          child: SizedBox(
                            width: coverSize,
                            height: coverSize,
                            child: song.coverUrl.isNotEmpty
                                ? Image.network(
                                    song.coverUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => _buildDefaultCover(),
                                  )
                                : _buildDefaultCover(),
                          ),
                        ),
                        // 黑胶中心孔
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0F172A),
                            border: Border.all(color: Colors.white38, width: 2),
                            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
                          ),
                          child: Center(
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 唱针 (Tonearm) 摆动起落动画
              Positioned(
                top: 0,
                right: (size.width - discSize) / 2 + 18,
                child: AnimatedBuilder(
                  animation: _armAnimation,
                  builder: (context, child) {
                    return Transform(
                      alignment: Alignment.topRight,
                      transform: Matrix4.rotationZ(_armAnimation.value),
                      child: child,
                    );
                  },
                  child: _buildTonearmWidget(),
                ),
              ),

              // 底部轻触翻转歌词提示
              Positioned(
                bottom: 2,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.touch_app_rounded, size: 14, color: Colors.white38),
                    SizedBox(width: 4),
                    Text('轻触翻转歌词 · 左右滑动切歌', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 唱针组件
  Widget _buildTonearmWidget() {
    return SizedBox(
      width: 72,
      height: 125,
      child: Stack(
        children: [
          // 转轴金属底座
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF94A3B8),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
              ),
              child: Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF334155),
                  ),
                ),
              ),
            ),
          ),
          // 针杆
          Positioned(
            top: 18,
            right: 11,
            child: Container(
              width: 4,
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
                boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
              ),
            ),
          ),
          // 唱头
          Positioned(
            bottom: 10,
            right: 3,
            child: Transform.rotate(
              angle: -0.32,
              child: Container(
                width: 14,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: const Color(0xFF818CF8), width: 1.5),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 全屏卡拉OK歌词与时间轴校准
  Widget _buildLyricsView(Song song) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          // 歌词顶部控制条：切回唱片、双语翻译开关、校准工具入口
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                InkWell(
                  onTap: () => setState(() => _showLyrics = false),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: const [
                        Icon(Icons.album_rounded, size: 16, color: Color(0xFF818CF8)),
                        SizedBox(width: 4),
                        Text('唱片模式', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    // 双语翻译切换开关
                    StreamBuilder<bool>(
                      stream: _playerService.showTranslationStream,
                      initialData: _playerService.showTranslation,
                      builder: (context, transSnap) {
                        final showTrans = transSnap.data ?? _playerService.showTranslation;
                        return TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            minimumSize: Size.zero,
                          ),
                          icon: Icon(
                            Icons.translate_rounded,
                            size: 15,
                            color: showTrans ? const Color(0xFF818CF8) : Colors.white38,
                          ),
                          label: Text(
                            showTrans ? '译文开' : '译文关',
                            style: TextStyle(
                              color: showTrans ? const Color(0xFF818CF8) : Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          onPressed: () => _playerService.toggleTranslation(),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    // 时间轴校准入口
                    IconButton(
                      icon: Icon(
                        Icons.av_timer_rounded,
                        size: 20,
                        color: _showOffsetToolbar ? const Color(0xFF818CF8) : Colors.white60,
                      ),
                      tooltip: '歌词校准 (±0.5s)',
                      onPressed: () {
                        setState(() {
                          _showOffsetToolbar = !_showOffsetToolbar;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 时间轴微调工具栏 (展开时显示)
          if (_showOffsetToolbar)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)),
              ),
              child: StreamBuilder<int>(
                stream: _playerService.lyricOffsetStream,
                initialData: _playerService.lyricOffsetMs,
                builder: (context, offsetSnap) {
                  final offset = offsetSnap.data ?? _playerService.lyricOffsetMs;
                  final secStr = (offset / 1000.0).toStringAsFixed(1);

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('歌词对齐:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline_rounded, size: 18, color: Color(0xFF818CF8)),
                            onPressed: () => _playerService.adjustLyricOffset(-500),
                            tooltip: '提前 0.5 秒',
                          ),
                          Text(
                            offset == 0 ? '标准 (0.0s)' : '${offset > 0 ? "+" : ""}${secStr}s',
                            style: const TextStyle(
                              color: Color(0xFFC7D2FE),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline_rounded, size: 18, color: Color(0xFF818CF8)),
                            onPressed: () => _playerService.adjustLyricOffset(500),
                            tooltip: '延后 0.5 秒',
                          ),
                        ],
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                        ),
                        onPressed: () => _playerService.resetLyricOffset(),
                        child: const Text('复位', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      ),
                    ],
                  );
                },
              ),
            ),

          // 滚动歌词主体
          Expanded(
            child: StreamBuilder<List<LrcLine>>(
              stream: _playerService.lyricsStream,
              initialData: _playerService.currentLyrics,
              builder: (context, lrcSnap) {
                final lyrics = lrcSnap.data ?? [];
                if (lyrics.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF818CF8)),
                        SizedBox(height: 12),
                        Text('歌词加载中 / 纯音乐暂无歌词', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  );
                }

                return StreamBuilder<Duration>(
                  stream: _playerService.positionStream,
                  initialData: _playerService.currentPosition,
                  builder: (context, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    final activeIdx = LyricParser.findActiveIndex(lyrics, pos);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _scrollToActiveLyric(activeIdx);
                    });

                    return StreamBuilder<bool>(
                      stream: _playerService.showTranslationStream,
                      initialData: _playerService.showTranslation,
                      builder: (context, transSnap) {
                        final showTrans = transSnap.data ?? _playerService.showTranslation;

                        return NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is UserScrollNotification) {
                              _isUserScrollingLyrics = notification.direction != ScrollDirection.idle;
                              _userScrollResumeTimer?.cancel();
                              if (!_isUserScrollingLyrics) {
                                _userScrollResumeTimer = Timer(const Duration(milliseconds: 2500), () {
                                  if (mounted) {
                                    _isUserScrollingLyrics = false;
                                    _scrollToActiveLyric(activeIdx, force: true);
                                  }
                                });
                              }
                            }
                            return false;
                          },
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final halfHeight = constraints.maxHeight > 100 ? constraints.maxHeight / 2 - 20 : 160.0;
                              return ListView.builder(
                                controller: _lyricsScrollController,
                                padding: EdgeInsets.symmetric(vertical: halfHeight, horizontal: 16),
                                itemCount: lyrics.length,
                                itemBuilder: (context, idx) {
                                  final line = lyrics[idx];
                                  final isActive = idx == activeIdx;
                                  final hasTrans = showTrans && line.translation != null && line.translation!.isNotEmpty;
                                  final itemKey = _lyricKeys.putIfAbsent(idx, () => GlobalKey());

                                  return GestureDetector(
                                    key: itemKey,
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      _playerService.seek(line.time);
                                      _scrollToActiveLyric(idx, force: true);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      child: Column(
                                        children: [
                                          Text(
                                            line.text,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: isActive ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.45),
                                              fontSize: isActive ? 18.5 : 14.5,
                                              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                              shadows: isActive
                                                  ? [
                                                      BoxShadow(
                                                        color: const Color(0xFF818CF8).withValues(alpha: 0.7),
                                                        blurRadius: 14,
                                                      )
                                                    ]
                                                  : null,
                                            ),
                                          ),
                                          if (hasTrans)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 4),
                                              child: Text(
                                                line.translation!,
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  color: isActive ? const Color(0xFFC7D2FE) : Colors.white30,
                                                  fontSize: isActive ? 13.5 : 12,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 歌名、歌手与可交互音质切换
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
    if (source.contains('QQ')) return 'QQ音乐';
    if (source.contains('酷狗')) return '酷狗音乐';
    if (source.contains('酷我')) return '酷我音乐';
    if (source.contains('咪咕')) return '咪咕音乐';
    if (source.contains('哔哩') || source.contains('bilibili') || source.contains('B站')) return '哔哩哔哩';
    if (source.contains('汽水') || source.contains('soda') || source.contains('抖音')) return '汽水音乐';
    return source;
  }

  /// 歌名、歌手与紧凑发烧控制栏重构 (格局优化：歌手信息完整显示，操作按钮紧凑化)
  Widget _buildSongMetaAndActions(BuildContext context, Song song) {
    final platformColor = _getPlatformColor(song.source);
    final platformName = _getPlatformShortName(song.source);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上层：歌名、歌手与可交互音质切换
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        // 独立平台微标 Badge (杜绝被截断)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: platformColor.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: platformColor.withValues(alpha: 0.5), width: 0.8),
                          ),
                          child: Text(
                            platformName,
                            style: TextStyle(
                              color: platformColor,
                              fontSize: 9.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        // 歌手名称（完整显示，如毛不易）
                        Expanded(
                          child: Text(
                            song.album.isNotEmpty ? '${song.artist} · ${song.album}' : song.artist,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // 可点化音质角标
              GestureDetector(
                onTap: () => _showQualitySelectSheet(context, song),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: song.isLossless ? const Color(0x33F59E0B) : const Color(0x3306B6D4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: song.isLossless ? const Color(0x88F59E0B) : const Color(0x8806B6D4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.displayQuality,
                        style: TextStyle(
                          color: song.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.arrow_drop_down_rounded,
                        size: 15,
                        color: song.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 下层：发烧控制栏 (收藏、加入歌单、分享、下载) - 紧凑横向均匀排布，精致轻巧
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // 1. 收藏
                StreamBuilder<List<Song>>(
                  stream: _dbService.favoritesStream,
                  builder: (context, favSnap) {
                    final isFav = _dbService.isFavorite(song);
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async {
                        final added = await _dbService.toggleFavorite(song);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(added ? '已收藏: ${song.name}' : '已取消收藏: ${song.name}'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              color: isFav ? const Color(0xFFEF4444) : Colors.white70,
                              size: 17,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isFav ? '已收藏' : '收藏',
                              style: TextStyle(
                                color: isFav ? const Color(0xFFEF4444) : Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                Container(width: 1, height: 14, color: Colors.white12),
                // 2. 加入歌单
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showAddToPlaylistDialog(context, song),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.playlist_add_rounded, color: Colors.white70, size: 18),
                        SizedBox(width: 3),
                        Text('歌单', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, height: 14, color: Colors.white12),
                // 3. 分享
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    if (song.isDownloaded && song.localFilePath != null && File(song.localFilePath!).existsSync()) {
                      SharePlus.instance.share(ShareParams(
                        files: [XFile(song.localFilePath!)],
                        text: '分享音乐: ${song.name} - ${song.artist}',
                      ));
                    } else {
                      SharePlus.instance.share(ShareParams(
                        text: '正在聆听: 《${song.name}》 - ${song.artist} [${song.source} / ${song.quality}]\n来自 DMusic 发烧音乐客户端',
                      ));
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.share_rounded, color: Colors.white70, size: 16),
                        SizedBox(width: 3),
                        Text('分享', style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, height: 14, color: Colors.white12),
                // 4. 下载
                StreamBuilder<List<Song>>(
                  stream: _dbService.downloadsStream,
                  initialData: _dbService.downloads,
                  builder: (context, dlSnap) {
                    final match = _dbService.checkDownloadStatus(song);
                    final isDone = match.isExact;
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => DownloadSheet.show(context, song, matchResult: match),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isDone ? Icons.check_circle_rounded : Icons.download_rounded,
                              color: isDone ? const Color(0xFF10B981) : Colors.white70,
                              size: 17,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              isDone ? '已下载' : '下载',
                              style: TextStyle(
                                color: isDone ? const Color(0xFF34D399) : Colors.white70,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 进度条与播放时长
  Widget _buildScrubber(Song song) {
    return StreamBuilder<Duration>(
      stream: _playerService.durationStream,
      initialData: _playerService.currentDuration,
      builder: (context, durSnap) {
        final streamDur = durSnap.data;
        final hasValidStreamDur = streamDur != null && streamDur.inSeconds > 0;
        final dur = hasValidStreamDur
            ? streamDur
            : (song.durationSeconds > 0 ? Duration(seconds: song.durationSeconds) : Duration.zero);

        return StreamBuilder<Duration>(
          stream: _playerService.positionStream,
          initialData: _playerService.currentPosition,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final maxSec = dur.inSeconds > 0 ? dur.inSeconds.toDouble() : 1.0;
            final curSec = (_dragPositionSeconds ?? pos.inSeconds.toDouble()).clamp(0.0, maxSec);
            final displayPos = _dragPositionSeconds != null
                ? Duration(seconds: _dragPositionSeconds!.toInt())
                : pos;

            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF6366F1),
                    inactiveTrackColor: Colors.white12,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  ),
                  child: Slider(
                    value: curSec,
                    max: maxSec,
                    onChangeStart: (v) {
                      setState(() {
                        _dragPositionSeconds = v;
                      });
                    },
                    onChanged: (v) {
                      setState(() {
                        _dragPositionSeconds = v;
                      });
                    },
                    onChangeEnd: (v) {
                      final target = Duration(seconds: v.toInt());
                      setState(() {
                        _dragPositionSeconds = null;
                      });
                      _playerService.seek(target);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatTime(displayPos), style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      Text(
                        dur > Duration.zero ? _formatTime(dur) : '--:--',
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 核心播放控制按钮
  Widget _buildPlaybackControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 循环模式切换
          StreamBuilder<PlayMode>(
            stream: _playerService.playModeStream,
            initialData: _playerService.playMode,
            builder: (context, modeSnap) {
              final mode = modeSnap.data ?? _playerService.playMode;
              IconData icon = Icons.repeat_rounded;
              if (mode == PlayMode.singleLoop) icon = Icons.repeat_one_rounded;
              if (mode == PlayMode.shuffle) icon = Icons.shuffle_rounded;
              if (mode == PlayMode.sequentialPlaylists) icon = Icons.playlist_play_rounded;

              return IconButton(
                icon: Icon(icon, color: Colors.white70, size: 26),
                tooltip: '模式: ${_playerService.playModeName}',
                onPressed: () {
                  _playerService.togglePlayMode();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已切换为: ${_playerService.playModeName}'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36),
            onPressed: () => _playerService.playPrev(),
          ),
          StreamBuilder<bool>(
            stream: _playerService.transitioningStream,
            initialData: _playerService.isTransitioning,
            builder: (context, transSnap) {
              final isBuffering = transSnap.data ?? _playerService.isTransitioning;
              return StreamBuilder<PlayerState>(
                stream: _playerService.stateStream,
                initialData: _playerService.isPlaying ? PlayerState.playing : _playerService.playerState,
                builder: (context, snap) {
                  final isPlaying = (snap.data ?? _playerService.playerState) == PlayerState.playing;
                  return GestureDetector(
                    onTap: isBuffering ? null : () => _playerService.togglePlay(),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x666366F1),
                            blurRadius: 20,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: isBuffering
                          ? const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.8,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                            )
                          : Icon(
                              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 38,
                            ),
                    ),
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36),
            onPressed: () => _playerService.playNext(),
          ),
          IconButton(
            icon: const Icon(Icons.queue_music_rounded, color: Colors.white70, size: 28),
            onPressed: () => _showPlaylistQueueSheet(context),
            tooltip: '播放队列',
          ),
        ],
      ),
    );
  }

  /// 辅助功能行 (定时器、倍速、10段EQ)
  Widget _buildAuxiliaryBar(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 睡眠定时器
        StreamBuilder<int>(
          stream: _playerService.sleepTimerStream,
          initialData: _playerService.remainingSleepSeconds,
          builder: (context, timerSnap) {
            final sec = timerSnap.data ?? _playerService.remainingSleepSeconds;
            final isTimerOn = _playerService.isSleepTimerActive;
            String timerLabel = '定时关闭';
            if (_playerService.sleepAfterCurrentSong) {
              timerLabel = '播完停';
            } else if (sec > 0) {
              final m = sec ~/ 60;
              final s = sec % 60;
              timerLabel = '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
            }

            return InkWell(
              onTap: () => _showSleepTimerSheet(context),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: isTimerOn ? const Color(0x336366F1) : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isTimerOn ? const Color(0xFF6366F1) : Colors.white12,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bedtime_rounded,
                      size: 14,
                      color: isTimerOn ? const Color(0xFF818CF8) : Colors.white60,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      timerLabel,
                      style: TextStyle(
                        color: isTimerOn ? const Color(0xFF818CF8) : Colors.white60,
                        fontSize: 11.5,
                        fontWeight: isTimerOn ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 10),

        // 倍速控制
        InkWell(
          onTap: () => _showPlaybackSpeedSheet(context),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: _playerService.playbackRate != 1.0
                  ? const Color(0x336366F1)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _playerService.playbackRate != 1.0
                    ? const Color(0xFF6366F1)
                    : Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.speed_rounded,
                  size: 14,
                  color: _playerService.playbackRate != 1.0 ? const Color(0xFF818CF8) : Colors.white60,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_playerService.playbackRate}x',
                  style: TextStyle(
                    color: _playerService.playbackRate != 1.0 ? const Color(0xFF818CF8) : Colors.white60,
                    fontSize: 11.5,
                    fontWeight: _playerService.playbackRate != 1.0 ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),

        // 均衡器 (EQ) 状态角标
        InkWell(
          onTap: () => _showEqSheet(context),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: _playerService.currentEqPreset != '纯净原声'
                  ? const Color(0x336366F1)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _playerService.currentEqPreset != '纯净原声'
                    ? const Color(0xFF6366F1)
                    : Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.equalizer_rounded,
                  size: 14,
                  color: Color(0xFF818CF8),
                ),
                const SizedBox(width: 4),
                Text(
                  'EQ: ${_playerService.currentEqPreset}',
                  style: const TextStyle(
                    color: Color(0xFFC7D2FE),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 音质切换底部弹窗
  void _showQualitySelectSheet(BuildContext context, Song song) {
    final qualities = [
      {'name': 'FLAC 无损', 'target': 'flac', 'desc': '无损音频，位深与采样率以实际音源为准'},
      {'name': '320k 极高', 'target': '320k', 'desc': 'MP3 320Kbps 发烧标准 纯正饱满'},
      {'name': '256k 高品', 'target': '256k', 'desc': '优先 256Kbps；缺少此档时尝试更高品质音源'},
      {'name': '128k 标准', 'target': '128k', 'desc': 'MP3 128Kbps 极速秒开 流畅省流'},
    ];
    String? qualityTarget(String? value) {
      final quality = value?.trim().toLowerCase() ?? '';
      if (quality.contains('flac') || quality.contains('lossless') ||
          quality.contains('无损') || quality.contains('hires')) {
        return 'flac';
      }
      for (final bitrate in ['320', '256', '128']) {
        if (quality.contains(bitrate)) return '${bitrate}k';
      }
      return null;
    }
    final selectedQuality = qualityTarget(song.audioUrlQuality) ??
        qualityTarget(song.quality);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  '选择音频解码规格',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ...qualities.map((q) {
                  final isCur = selectedQuality == q['target'];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isCur ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: isCur ? const Color(0xFF6366F1) : Colors.white38,
                      size: 20,
                    ),
                    title: Text(
                      q['name']!,
                      style: TextStyle(
                        color: isCur ? const Color(0xFF818CF8) : Colors.white,
                        fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      q['desc']!,
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    onTap: () async {
                      Navigator.pop(ctx);
                      if (!isCur) {
                        await _playerService.switchQuality(song, q['name']!);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('音质偏好已设为: ${q['name']}；当前: ${_playerService.currentSong?.quality ?? song.quality}'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      }
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 10段专业发烧均衡器 (EQ) 弹窗
  void _showEqSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111726),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.equalizer_rounded, color: Color(0xFF818CF8)),
                            SizedBox(width: 8),
                            Text(
                              '10段专业发烧均衡器 (EQ)',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.tune_rounded, size: 14, color: Color(0xFF818CF8)),
                              label: const Text('系统杜比/音效', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                              onPressed: () async {
                                final ok = await _playerService.openSystemEqualizer();
                                if (!ok && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('当前设备未检测到独立系统音效面板，已使用内置EQ调节')),
                                  );
                                }
                              },
                            ),
                            TextButton(
                              onPressed: () {
                                _playerService.resetEq();
                                setSheetState(() {});
                              },
                              child: const Text('重置原声', style: TextStyle(color: Colors.white54, fontSize: 12)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // 声学预设 Chips
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: PlayerService.eqPresets.keys.map((preset) {
                          final isCur = _playerService.currentEqPreset == preset;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(preset),
                              selected: isCur,
                              selectedColor: const Color(0xFF6366F1),
                              backgroundColor: Colors.white.withValues(alpha: 0.08),
                              labelStyle: TextStyle(
                                color: isCur ? Colors.white : Colors.white70,
                                fontSize: 12,
                                fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                              ),
                              onSelected: (_) {
                                _playerService.setEqPreset(preset);
                                setSheetState(() {});
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // 10段增益滑动控件
                    SizedBox(
                      height: 170,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(PlayerService.eqBandFrequencies.length, (i) {
                          final freq = PlayerService.eqBandFrequencies[i];
                          final gain = _playerService.eqBands[i];

                          return Column(
                            children: [
                              Text(
                                '${gain > 0 ? "+" : ""}${gain.toInt()}dB',
                                style: const TextStyle(color: Colors.white38, fontSize: 9),
                              ),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                                      activeTrackColor: const Color(0xFF6366F1),
                                      inactiveTrackColor: Colors.white12,
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      min: -12.0,
                                      max: 12.0,
                                      value: gain,
                                      onChanged: (v) {
                                        _playerService.setEqBand(i, v);
                                        setSheetState(() {});
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                freq,
                                style: const TextStyle(color: Colors.white60, fontSize: 10),
                              ),
                            ],
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 现代化播放队列管理 (支持长按拖拽排序 ReorderableListView、左滑移除、清空)
  void _showPlaylistQueueSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return StreamBuilder<List<Song>>(
          stream: _playerService.playlistStream,
          initialData: _playerService.playlist,
          builder: (context, queueSnap) {
            final playlist = queueSnap.data ?? _playerService.playlist;

            return SafeArea(
              child: Container(
                height: MediaQuery.of(context).size.height * 0.65,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '播放队列 (${playlist.length}首)',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        Row(
                          children: [
                            StreamBuilder<PlayMode>(
                              stream: _playerService.playModeStream,
                              initialData: _playerService.playMode,
                              builder: (context, modeSnap) {
                                final mode = modeSnap.data ?? _playerService.playMode;
                                IconData icon = Icons.repeat_rounded;
                                if (mode == PlayMode.singleLoop) icon = Icons.repeat_one_rounded;
                                if (mode == PlayMode.shuffle) icon = Icons.shuffle_rounded;
                                if (mode == PlayMode.sequentialPlaylists) icon = Icons.playlist_play_rounded;
                                return TextButton.icon(
                                  icon: Icon(icon, color: const Color(0xFF818CF8), size: 16),
                                  label: Text(
                                    _playerService.playModeName,
                                    style: const TextStyle(color: Color(0xFFC7D2FE), fontSize: 12),
                                  ),
                                  onPressed: () => _playerService.togglePlayMode(),
                                );
                              },
                            ),
                            const SizedBox(width: 4),
                            TextButton.icon(
                              icon: const Icon(Icons.delete_sweep_rounded, size: 16, color: Colors.redAccent),
                              label: const Text('清空', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                              onPressed: () {
                                _playerService.clearPlaylist();
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white10),
                    if (playlist.isEmpty)
                      const Expanded(
                        child: Center(child: Text('播放队列为空', style: TextStyle(color: Colors.white38))),
                      )
                    else
                      Expanded(
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            canvasColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                          ),
                          child: ReorderableListView.builder(
                            itemCount: playlist.length,
                            // ignore: deprecated_member_use
                            onReorder: (oldIdx, newIdx) {
                              _playerService.reorderPlaylist(oldIdx, newIdx);
                            },
                            itemBuilder: (context, idx) {
                              final item = playlist[idx];
                              final isCurrent = _playerService.currentSong == item;

                              return Dismissible(
                                key: ValueKey('queue_item_${item.key}_$idx'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: 20),
                                  color: Colors.redAccent.withValues(alpha: 0.8),
                                  child: const Icon(Icons.delete_rounded, color: Colors.white),
                                ),
                                onDismissed: (_) {
                                  _playerService.removeSongFromPlaylist(item);
                                },
                                child: Container(
                                  key: ValueKey('tile_${item.key}_$idx'),
                                  margin: const EdgeInsets.symmetric(vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isCurrent ? const Color(0x226366F1) : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: ListTile(
                                    dense: true,
                                    leading: Icon(
                                      isCurrent ? Icons.volume_up_rounded : Icons.music_note_rounded,
                                      color: isCurrent ? const Color(0xFF818CF8) : Colors.white38,
                                      size: 18,
                                    ),
                                    title: Text(
                                      item.name,
                                      style: TextStyle(
                                        color: isCurrent ? const Color(0xFF818CF8) : Colors.white,
                                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                        fontSize: 13,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      '${item.artist} · ${item.quality}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white30),
                                          onPressed: () => _playerService.removeFromPlaylist(idx),
                                        ),
                                        ReorderableDragStartListener(
                                          index: idx,
                                          child: const Icon(Icons.drag_handle_rounded, color: Colors.white38, size: 20),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      _playerService.playSong(item);
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 睡眠定时器
  void _showSleepTimerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  '睡眠定时关闭',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _buildSleepOption(ctx, '15 分钟', () => _playerService.setSleepTimer(minutes: 15)),
                _buildSleepOption(ctx, '30 分钟', () => _playerService.setSleepTimer(minutes: 30)),
                _buildSleepOption(ctx, '45 分钟', () => _playerService.setSleepTimer(minutes: 45)),
                _buildSleepOption(ctx, '60 分钟', () => _playerService.setSleepTimer(minutes: 60)),
                _buildSleepOption(ctx, '播完当前歌曲后停止', () => _playerService.setSleepTimer(afterCurrentSong: true)),
                if (_playerService.isSleepTimerActive)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 20),
                    title: const Text('关闭定时器', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
                    onTap: () {
                      _playerService.cancelSleepTimer();
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已取消定时关闭'), duration: Duration(seconds: 1)),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSleepOption(BuildContext ctx, String label, VoidCallback onSelect) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.timer_outlined, color: Color(0xFF818CF8), size: 20),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 18),
      onTap: () {
        onSelect();
        Navigator.pop(ctx);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已开启定时: $label'), duration: const Duration(seconds: 1)),
        );
      },
    );
  }

  /// 倍速播放
  void _showPlaybackSpeedSheet(BuildContext context) {
    final speeds = [0.8, 1.0, 1.25, 1.5, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  '播放倍速设置',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: speeds.map((speed) {
                    final isCur = _playerService.playbackRate == speed;
                    return InkWell(
                      onTap: () {
                        _playerService.setPlaybackRate(speed);
                        Navigator.pop(ctx);
                        setState(() {});
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: isCur ? const Color(0xFF6366F1) : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isCur ? const Color(0xFF818CF8) : Colors.transparent,
                          ),
                        ),
                        child: Text(
                          '${speed}x',
                          style: TextStyle(
                            color: isCur ? Colors.white : Colors.white70,
                            fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 收藏至歌单弹窗
  void _showAddToPlaylistDialog(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StreamBuilder<List<CustomPlaylist>>(
            stream: _dbService.playlistsStream,
            initialData: _dbService.playlists,
            builder: (context, plSnap) {
              final lists = plSnap.data ?? [];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '收藏至歌单',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.add_rounded, size: 18, color: Color(0xFF818CF8)),
                          label: const Text('新建歌单', style: TextStyle(color: Color(0xFF818CF8))),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showCreatePlaylistDialog(context, song);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (lists.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('暂无自定义歌单，点击右上角新建', style: TextStyle(color: Colors.white38)),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: lists.length,
                          itemBuilder: (context, i) {
                            final pl = lists[i];
                            final alreadyIn = pl.songs.any((s) => s.id == song.id && s.source == song.source);

                            return ListTile(
                              leading: const Icon(Icons.queue_music_rounded, color: Color(0xFF818CF8)),
                              title: Text(pl.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
                              subtitle: Text('${pl.songs.length} 首歌曲', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                              trailing: alreadyIn
                                  ? const Text('已加入', style: TextStyle(color: Colors.white38, fontSize: 12))
                                  : const Icon(Icons.add_circle_outline_rounded, color: Color(0xFF818CF8), size: 20),
                              onTap: alreadyIn
                                  ? null
                                  : () async {
                                      await _dbService.addSongToPlaylist(pl.id, song);
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('已加入歌单: ${pl.name}')),
                                        );
                                      }
                                    },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showCreatePlaylistDialog(BuildContext context, Song? songToAdd) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('新建歌单', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '请输入歌单名称',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            child: const Text('创建', style: TextStyle(color: Color(0xFF818CF8))),
            onPressed: () async {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                final pl = await _dbService.createPlaylist(name);
                if (songToAdd != null) {
                  await _dbService.addSongToPlaylist(pl.id, songToAdd);
                }
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已创建歌单: $name')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultCover() {
    return Container(
      color: const Color(0xFF1E293B),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Color(0xFF6366F1), size: 64),
      ),
    );
  }

  String _formatTime(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
