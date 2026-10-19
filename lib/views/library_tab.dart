import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';
import '../services/player_service.dart';
import '../services/music_api.dart';
import 'playlist_dialogs.dart';
import 'download_sheet.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => LibraryTabState();
}

class LibraryTabState extends State<LibraryTab> {
  final DatabaseService _db = DatabaseService();
  final PlayerService _player = PlayerService();

  /// 供主界面拦截返回键调用：若正处于多选或搜索状态，则优雅退出当前状态，绝不触发退出应用提示
  bool handleBackPressed() {
    if (_isSearching) {
      setState(() {
        _isSearching = false;
        _searchController.clear();
        _searchQuery = '';
      });
      return true;
    }
    final isAnySelecting = _isDlSelecting || _isFavSelecting || _isHistorySelecting;
    if (isAnySelecting) {
      setState(() {
        _isDlSelecting = false;
        _selectedDlKeys.clear();
        _isFavSelecting = false;
        _selectedFavKeys.clear();
        _isHistorySelecting = false;
        _selectedHistoryKeys.clear();
      });
      return true;
    }
    return false;
  }

  int _selectedSubTab = 0; // 0: 全部歌曲, 1: 歌单合集, 2: 我的收藏, 3: 播放历史

  // 搜索状态 (右上角搜索)
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // 全部歌曲筛选与批量选择状态 (支持多选)
  final Set<String> _dlPlatforms = {'全部'};
  final Set<String> _dlQualities = {'全部'};
  final Set<String> _dlArtists = {'全部'};
  final Set<String> _dlSizes = {'全部'};
  bool _isDlSelecting = false;
  final Set<String> _selectedDlKeys = {};

  // 我的收藏筛选与批量选择状态 (支持多选)
  final Set<String> _favPlatforms = {'全部'};
  final Set<String> _favQualities = {'全部'};
  final Set<String> _favArtists = {'全部'};
  final Set<String> _favSizes = {'全部'};
  bool _isFavSelecting = false;
  final Set<String> _selectedFavKeys = {};

  // 播放历史筛选与批量选择状态 (支持多选)
  final Set<String> _histPlatforms = {'全部'};
  final Set<String> _histQualities = {'全部'};
  final Set<String> _histArtists = {'全部'};
  final Set<String> _histSizes = {'全部'};
  bool _isHistorySelecting = false;
  final Set<String> _selectedHistoryKeys = {};

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
        targetSet.add(item);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _db.init().then((_) {
      _db.cleanMissingLocalDownloads().then((count) {
        if (mounted && count > 0) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已自动同步并清理 $count 首外部已删除的音乐文件'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: const Color(0xFF0A0D14),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0A0D14),
          elevation: 0,
          title: _isSearching
              ? Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.35)),
                  ),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    textAlignVertical: TextAlignVertical.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索库内歌曲、歌手、平台...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF818CF8), size: 18),
                      prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.cancel_rounded, color: Colors.white38, size: 16),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onChanged: (v) {
                      setState(() => _searchQuery = v.trim().toLowerCase());
                    },
                  ),
                )
              : Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.library_music_rounded, color: Color(0xFF818CF8), size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '我的音乐库',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: _isSearching ? '关闭搜索' : '搜索曲目',
              icon: Icon(_isSearching ? Icons.close_rounded : Icons.search_rounded, color: const Color(0xFF818CF8)),
              onPressed: () {
                setState(() {
                  _isSearching = !_isSearching;
                  if (!_isSearching) {
                    _searchController.clear();
                    _searchQuery = '';
                  }
                });
              },
            ),
            IconButton(
              tooltip: '存储目录与容量',
              icon: const Icon(Icons.folder_open_rounded, color: Color(0xFF818CF8)),
              onPressed: _showStorageInfoDialog,
            ),
          ],
        ),
        body: Column(
          children: [
            // 顶部歌单分类分段选择器 (4个子标签)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFF131A29),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                children: [
                  _buildSubTabButton(0, '全部歌曲', _db.downloadsStream, _db.downloads.length),
                  _buildPlaylistsSubTabButton(1, '歌单合集'),
                  _buildSubTabButton(2, '我的收藏', _db.favoritesStream, _db.favorites.length),
                  _buildSubTabButton(3, '播放历史', _db.historyStream, _db.history.length),
                ],
              ),
            ),

            // 主内容视图
            Expanded(
              child: IndexedStack(
                index: _selectedSubTab,
                children: [
                  _buildDownloadsView(),
                  _buildCustomPlaylistsView(),
                  _buildFavoritesView(),
                  _buildHistoryView(),
                ],
              ),
            ),
          ],
        ),
      );
  }

  Widget _buildSubTabButton(int index, String label, Stream<List<Song>> stream, int initialCount) {
    final isSelected = _selectedSubTab == index;
    return Expanded(
      child: StreamBuilder<List<Song>>(
        stream: stream,
        builder: (context, snapshot) {
          final count = snapshot.hasData ? snapshot.data!.length : initialCount;
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedSubTab = index;
                _isHistorySelecting = false;
                _selectedHistoryKeys.clear();
                _isDlSelecting = false;
                _selectedDlKeys.clear();
                _isFavSelecting = false;
                _selectedFavKeys.clear();
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF6366F1) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.white.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaylistsSubTabButton(int index, String label) {
    final isSelected = _selectedSubTab == index;
    return Expanded(
      child: StreamBuilder<List<CustomPlaylist>>(
        stream: _db.playlistsStream,
        initialData: _db.playlists,
        builder: (context, snapshot) {
          final count = snapshot.hasData ? snapshot.data!.length : _db.playlists.length;
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedSubTab = index;
                _isHistorySelecting = false;
                _selectedHistoryKeys.clear();
                _isDlSelecting = false;
                _selectedDlKeys.clear();
                _isFavSelecting = false;
                _selectedFavKeys.clear();
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF6366F1) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white60,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.white.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ==================== 共享辅助方法 ====================
  void _shareSong(Song song) async {
    if (song.localFilePath != null) {
      final f = File(song.localFilePath!);
      if (f.existsSync()) {
        await SharePlus.instance.share(ShareParams(
          files: [XFile(f.path)],
          text: '来自 DMusic 分享: 《${song.name}》 - ${song.artist} [${song.quality}]',
        ));
        return;
      }
    }
    await SharePlus.instance.share(ShareParams(
      text: '来自 DMusic 分享: 《${song.name}》 - ${song.artist} [${song.quality}]\n平台: ${song.source}',
    ));
  }

  void _shareBatchDownloads(List<Song> allSongs) async {
    final selected = allSongs.where((s) => _selectedDlKeys.contains(s.key)).toList();
    if (selected.isEmpty) return;

    final xfiles = <XFile>[];
    for (final s in selected) {
      if (s.localFilePath != null) {
        final f = File(s.localFilePath!);
        if (f.existsSync()) {
          xfiles.add(XFile(f.path));
        }
      }
    }

    if (xfiles.isNotEmpty) {
      await SharePlus.instance.share(ShareParams(
        files: xfiles,
        text: '来自 DMusic 批量分享: 共 ${xfiles.length} 首高品质音乐',
      ));
    } else {
      final text = selected.map((s) => '《${s.name}》 - ${s.artist} [${s.quality}]').join('\n');
      await SharePlus.instance.share(ShareParams(
        text: '来自 DMusic 批量分享:\n$text',
      ));
    }
  }

  void _exportBatchDownloads(List<Song> allSongs) async {
    final selected = allSongs.where((s) => _selectedDlKeys.contains(s.key)).toList();
    if (selected.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在导出选中歌曲到手机公共音乐目录...'), duration: Duration(seconds: 1)),
    );

    final res = await _db.batchExportSongs(selected);
    final count = res['count'] as int? ?? 0;
    final path = res['targetPath'] as String? ?? '';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已成功导出 $count 首歌曲到公共存储:\n$path'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '查看导出文件',
            textColor: const Color(0xFF818CF8),
            onPressed: () => _showExportedFolderSheet(path),
          ),
        ),
      );
      setState(() {
        _isDlSelecting = false;
        _selectedDlKeys.clear();
      });
      // 导出完成后直接打开导出文件夹浏览器，一目了然
      _showExportedFolderSheet(path);
    }
  }

  /// 在应用内弹出直观的【已导出本地歌曲 (Music/DMusic)】视窗
  void _showExportedFolderSheet(String folderPath) {
    final dir = Directory(folderPath);
    List<FileSystemEntity> entities = [];
    try {
      if (dir.existsSync()) {
        entities = dir.listSync().where((e) {
          final ext = e.path.toLowerCase();
          return ext.endsWith('.mp3') || ext.endsWith('.flac') || ext.endsWith('.wav') || ext.endsWith('.m4a') || ext.endsWith('.lrc');
        }).toList();
        entities.sort((a, b) {
          try {
            return b.statSync().modified.compareTo(a.statSync().modified);
          } catch (_) {
            return 0;
          }
        });
      }
    } catch (_) {}

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161E2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (sheetContext, scrollController) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部拉手
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 标题栏
                  Row(
                    children: [
                      const Icon(Icons.folder_special_rounded, color: Color(0xFF10B981), size: 24),
                      const SizedBox(width: 8),
                      Text(
                        '已导出到手机公共存储 (${entities.length}首)',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 路径提示卡片（大白话，不改变大布局）
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.near_me_rounded, color: Color(0xFF818CF8), size: 14),
                            SizedBox(width: 6),
                            Text(
                              '手机自带【文件管理】查找路径：',
                              style: TextStyle(color: Color(0xFF818CF8), fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '内部存储  ➔  Music  ➔  DMusic',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            // 快捷复制搜索词 DMusic
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF818CF8),
                                  side: const BorderSide(color: Color(0xFF818CF8)),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                                ),
                                icon: const Icon(Icons.copy_rounded, size: 13),
                                label: const Text('复制名称: DMusic', style: TextStyle(fontSize: 11)),
                                onPressed: () {
                                  Clipboard.setData(const ClipboardData(text: 'DMusic'));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('已复制【DMusic】！在手机文件管理搜索栏直接粘贴即可秒搜！'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 打开手机系统文件管理
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF6366F1),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                                ),
                                icon: const Icon(Icons.folder_open_rounded, size: 14, color: Colors.white),
                                label: const Text('打开文件管理', style: TextStyle(color: Colors.white, fontSize: 11)),
                                onPressed: () async {
                                  await Clipboard.setData(const ClipboardData(text: 'DMusic'));
                                  try {
                                    const channel = MethodChannel('com.dmusic.app/widget');
                                    await channel.invokeMethod<bool>('openFolder', {'path': folderPath});
                                  } catch (_) {}
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('已唤起文件管理！在搜索栏直接粘贴【DMusic】或进入 Music 目录查看'),
                                        duration: Duration(seconds: 3),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '已导出的音乐文件（可在本应用内直接试听或分享）：',
                    style: TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  // 文件列表
                  Expanded(
                    child: entities.isEmpty
                        ? const Center(
                            child: Text('暂未检测到音频文件', style: TextStyle(color: Colors.white38, fontSize: 12)),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            itemCount: entities.length,
                            separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                            itemBuilder: (listCtx, index) {
                              final entity = entities[index];
                              final filename = entity.path.split(Platform.pathSeparator).last;
                              final isFlac = filename.toLowerCase().endsWith('.flac');
                              String sizeStr = '';
                              try {
                                final bytes = (entity as File).lengthSync();
                                sizeStr = '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
                              } catch (_) {}

                              return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isFlac
                                        ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                                        : const Color(0xFF06B6D4).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: isFlac
                                          ? const Color(0xFFF59E0B).withValues(alpha: 0.4)
                                          : const Color(0xFF06B6D4).withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: Text(
                                    isFlac ? 'FLAC' : 'MP3',
                                    style: TextStyle(
                                      color: isFlac ? const Color(0xFFF59E0B) : const Color(0xFF06B6D4),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  filename,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: sizeStr.isNotEmpty
                                    ? Text(sizeStr, style: const TextStyle(color: Colors.white38, fontSize: 10.5))
                                    : null,
                                trailing: IconButton(
                                  icon: const Icon(Icons.share_rounded, size: 16, color: Color(0xFF818CF8)),
                                  tooltip: '分享此音频文件',
                                  onPressed: () {
                                    SharePlus.instance.share(ShareParams(
                                      files: [XFile(entity.path)],
                                      text: filename,
                                    ));
                                  },
                                ),
                              );
                            },
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

  void _confirmBatchDeleteDownloads(List<Song> allSongs) {
    final selected = allSongs.where((s) => _selectedDlKeys.contains(s.key)).toList();
    final count = selected.length;
    if (count == 0) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161E2E),
        title: const Text('批量删除已下载歌曲', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定从手机存储和曲库中彻底移除选中的 $count 首歌曲及其音频、歌词文件吗？此操作不可撤销。',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text('彻底删除 ($count)', style: const TextStyle(color: Colors.white)),
            onPressed: () async {
              Navigator.pop(ctx);
              final deletedKeys = selected.map((s) => s.key).toList();
              // 先停止播放被删除的歌曲并安全剔除播放队列，杜绝磁盘音频文件占用报错
              _player.handleSongsDeleted(deletedKeys);
              final deleted = await _db.batchDeleteDownloads(deletedKeys);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已从手机存储彻底删除 $deleted 首歌曲及本地文件')),
                );
                setState(() {
                  _selectedDlKeys.removeAll(deletedKeys);
                  if (_selectedDlKeys.isEmpty) {
                    _isDlSelecting = false;
                  }
                });
              }
            },
          ),
        ],
      ),
    );
  }

  void _onDlPlatformSelected(String p, List<Song> list) {
    _toggleFilterItem(_dlPlatforms, p);
    final pSongs = _dlPlatforms.contains('全部')
        ? list
        : list.where((s) => _dlPlatforms.any((plat) => s.source.contains(plat))).toList();
    final qSet = <String>{'全部'};
    for (final s in pSongs) {
      if (s.quality.contains('Hi-Res')) qSet.add('Hi-Res');
      if (s.quality.contains('FLAC')) qSet.add('FLAC');
      if (s.quality.contains('320k')) qSet.add('320k');
      if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qSet.add('128k');
    }
    _dlQualities.removeWhere((q) => !qSet.contains(q));
    if (_dlQualities.isEmpty) _dlQualities.add('全部');

    final aSet = <String>{'全部'};
    for (final s in pSongs) {
      for (final part in s.artist.split(RegExp(r'[,/、&]'))) {
        final t = part.trim();
        if (t.isNotEmpty && t != '未知歌手') aSet.add(t);
      }
    }
    _dlArtists.removeWhere((a) => !aSet.contains(a));
    if (_dlArtists.isEmpty) _dlArtists.add('全部');
  }

  void _onFavPlatformSelected(String p, List<Song> list) {
    _toggleFilterItem(_favPlatforms, p);
    final pSongs = _favPlatforms.contains('全部')
        ? list
        : list.where((s) => _favPlatforms.any((plat) => s.source.contains(plat))).toList();
    final qSet = <String>{'全部'};
    for (final s in pSongs) {
      if (s.quality.contains('Hi-Res')) qSet.add('Hi-Res');
      if (s.quality.contains('FLAC')) qSet.add('FLAC');
      if (s.quality.contains('320k')) qSet.add('320k');
      if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qSet.add('128k');
    }
    _favQualities.removeWhere((q) => !qSet.contains(q));
    if (_favQualities.isEmpty) _favQualities.add('全部');

    final aSet = <String>{'全部'};
    for (final s in pSongs) {
      for (final part in s.artist.split(RegExp(r'[,/、&]'))) {
        final t = part.trim();
        if (t.isNotEmpty && t != '未知歌手') aSet.add(t);
      }
    }
    _favArtists.removeWhere((a) => !aSet.contains(a));
    if (_favArtists.isEmpty) _favArtists.add('全部');
  }

  void _onHistPlatformSelected(String p, List<Song> list) {
    _toggleFilterItem(_histPlatforms, p);
    final pSongs = _histPlatforms.contains('全部')
        ? list
        : list.where((s) => _histPlatforms.any((plat) => s.source.contains(plat))).toList();
    final qSet = <String>{'全部'};
    for (final s in pSongs) {
      if (s.quality.contains('Hi-Res')) qSet.add('Hi-Res');
      if (s.quality.contains('FLAC')) qSet.add('FLAC');
      if (s.quality.contains('320k')) qSet.add('320k');
      if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qSet.add('128k');
    }
    _histQualities.removeWhere((q) => !qSet.contains(q));
    if (_histQualities.isEmpty) _histQualities.add('全部');

    final aSet = <String>{'全部'};
    for (final s in pSongs) {
      for (final part in s.artist.split(RegExp(r'[,/、&]'))) {
        final t = part.trim();
        if (t.isNotEmpty && t != '未知歌手') aSet.add(t);
      }
    }
    _histArtists.removeWhere((a) => !aSet.contains(a));
    if (_histArtists.isEmpty) _histArtists.add('全部');
  }

  /// 通用级联筛选栏组件（平台 -> 联动音质、大小与歌手，全面支持多选）
  Widget _buildCascadingFilterBar({
    required List<String> platforms,
    required Set<String> selectedPlatforms,
    required ValueChanged<String> onPlatformSelected,
    required List<String> qualities,
    required Set<String> selectedQualities,
    required ValueChanged<String> onQualitySelected,
    required List<String> artists,
    required Set<String> selectedArtists,
    required ValueChanged<String> onArtistSelected,
    Set<String>? selectedSizes,
    ValueChanged<String>? onSizeSelected,
  }) {
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
          // 平台选择
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('平台: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                ...platforms.map((p) {
                  final active = selectedPlatforms.contains(p);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(p, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                      selected: active,
                      selectedColor: const Color(0xFF6366F1),
                      backgroundColor: const Color(0xFF0E1420),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onSelected: (_) => onPlatformSelected(p),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 音质选择（联动级联）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('音质: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                ...qualities.map((q) {
                  final active = selectedQualities.contains(q);
                  String label = q;
                  if (q == 'FLAC') label = '无损FLAC';
                  if (q == '320k') label = '320k极高';
                  if (q == '128k' || q == '标准') label = '128k标准';
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(label, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                      selected: active,
                      selectedColor: const Color(0xFF06B6D4),
                      backgroundColor: const Color(0xFF0E1420),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onSelected: (_) => onQualitySelected(q),
                    ),
                  );
                }),
              ],
            ),
          ),
          // 文件大小区间筛选（可选联动）
          if (onSizeSelected != null && selectedSizes != null) ...[
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('大小: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  ...['全部', '< 5MB', '5-15MB', '15-30MB', '> 30MB'].map((sz) {
                    final active = selectedSizes.contains(sz);
                    return Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        label: Text(sz, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                        selected: active,
                        selectedColor: const Color(0xFF10B981),
                        backgroundColor: const Color(0xFF0E1420),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        onSelected: (_) => onSizeSelected(sz),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
          const SizedBox(height: 4),
          // 歌手选择（联动级联）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Text('歌手: ', style: TextStyle(color: Colors.white38, fontSize: 11)),
                ...artists.map((ar) {
                  final active = selectedArtists.contains(ar);
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text(ar, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 10.5)),
                      selected: active,
                      selectedColor: const Color(0xFF8B5CF6),
                      backgroundColor: const Color(0xFF0E1420),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      onSelected: (_) => onArtistSelected(ar),
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String title, required String desc}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: Colors.white24),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text(desc, style: const TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  // ==================== 1. 已下载视图 ====================
  Widget _buildDownloadsView() {
    return StreamBuilder<List<Song>>(
      stream: _db.downloadsStream,
      initialData: _db.downloads,
      builder: (context, snapshot) {
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
          return _buildEmptyState(
            icon: Icons.cloud_download_rounded,
            title: '暂无已下载歌曲',
            desc: '在搜索发现中点击歌曲下载，音频文件将保存在此数据库中，断网也可离线收听。',
          );
        }

        // 1. 动态提取可用平台
        final platforms = <String>{'全部'};
        for (final s in list) {
          if (s.source.isNotEmpty) platforms.add(s.source);
        }

        // 2. 根据所选平台提取歌曲集合 (支持多选平台)
        final platformSongs = _dlPlatforms.contains('全部')
            ? list
            : list.where((s) => _dlPlatforms.any((plat) => s.source.contains(plat))).toList();

        // 3. 级联提取该平台下的可用音质
        final qualities = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.quality.contains('Hi-Res')) qualities.add('Hi-Res');
          if (s.quality.contains('FLAC')) qualities.add('FLAC');
          if (s.quality.contains('320k')) qualities.add('320k');
          if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qualities.add('128k');
        }

        // 4. 级联提取该平台下的可用歌手
        final artists = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.artist.isNotEmpty) {
            for (final part in s.artist.split(RegExp(r'[,/、&]'))) {
              final trimmed = part.trim();
              if (trimmed.isNotEmpty && trimmed != '未知歌手') artists.add(trimmed);
            }
          }
        }

        // 5. 综合过滤 (多选音质、大小、歌手 + 搜索关键词)
        var filtered = platformSongs;
        if (!_dlQualities.contains('全部')) {
          filtered = filtered.where((s) => _dlQualities.any((q) => s.quality.contains(q))).toList();
        }
        if (!_dlSizes.contains('全部')) {
          filtered = filtered.where((s) {
            final mb = s.estimatedSizeMB;
            for (final sz in _dlSizes) {
              if (sz == '< 5MB' && mb < 5) return true;
              if (sz == '5-15MB' && mb >= 5 && mb <= 15) return true;
              if (sz == '15-30MB' && mb > 15 && mb <= 30) return true;
              if (sz == '> 30MB' && mb > 30) return true;
            }
            return false;
          }).toList();
        }
        if (!_dlArtists.contains('全部')) {
          filtered = filtered.where((s) => _dlArtists.any((a) => s.artist.contains(a))).toList();
        }
        if (_searchQuery.isNotEmpty) {
          final cleanQ = Song.cleanTitle(_searchQuery);
          filtered = filtered.where((s) {
            return s.name.toLowerCase().contains(_searchQuery) ||
                (cleanQ.isNotEmpty && s.baseName.contains(cleanQ)) ||
                s.artist.toLowerCase().contains(_searchQuery) ||
                s.album.toLowerCase().contains(_searchQuery) ||
                s.source.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 四维级联筛选栏（平台 -> 联动音质、大小与歌手，随列表向上滑动并完全隐藏）
            SliverToBoxAdapter(
              child: _buildCascadingFilterBar(
                platforms: platforms.toList(),
                selectedPlatforms: _dlPlatforms,
                onPlatformSelected: (p) => _onDlPlatformSelected(p, list),
                qualities: qualities.toList(),
                selectedQualities: _dlQualities,
                onQualitySelected: (q) => _toggleFilterItem(_dlQualities, q),
                selectedSizes: _dlSizes,
                onSizeSelected: (sz) => _toggleFilterItem(_dlSizes, sz),
                artists: artists.toList(),
                selectedArtists: _dlArtists,
                onArtistSelected: (ar) => _toggleFilterItem(_dlArtists, ar),
              ),
            ),

            // 多选批量操作栏 OR 快捷播放控制栏（吸顶固定）
            SliverPersistentHeader(
              pinned: true,
              delegate: _LibraryStickyHeaderDelegate(
                height: 52,
                child: _isDlSelecting
                    ? _buildDownloadsSelectionBar(filtered)
                    : _buildPlaylistHeaderBar(
                        count: filtered.length,
                        title: '全部歌曲',
                        onPlayAll: () {
                          _player.setPlayMode(PlayMode.listLoop);
                          _player.setPlaylist(filtered, startIndex: 0);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('开始【顺序播放】全部歌曲 (共${filtered.length}首)'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        onShuffleAll: () {
                          _player.setPlayMode(PlayMode.shuffle);
                          final rand = filtered.isNotEmpty ? Random().nextInt(filtered.length) : 0;
                          _player.setPlaylist(filtered, startIndex: rand);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('开始【随机播放】全部歌曲 (共${filtered.length}首)'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        extraAction: TextButton.icon(
                          icon: const Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF818CF8)),
                          label: const Text('批量管理', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                          onPressed: () => setState(() => _isDlSelecting = true),
                        ),
                      ),
              ),
            ),

            // 歌曲列表
            if (filtered.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('无符合筛选条件的歌曲', style: TextStyle(color: Colors.white38, fontSize: 13)),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 140),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = filtered[index];
                      return _buildDownloadedSongCard(song, filtered, index);
                    },
                    childCount: filtered.length,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCompactBarIcon({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback? onPressed,
    double size = 19,
  }) {
    return IconButton(
      icon: Icon(icon, color: onPressed == null ? Colors.white24 : color, size: size),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(30, 30),
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildDownloadsSelectionBar(List<Song> songs) {
    final visibleKeys = songs.map((s) => s.key).toSet();
    final selectedInScope = _selectedDlKeys.intersection(visibleKeys);
    final isAllSelected = songs.isNotEmpty && selectedInScope.length == songs.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: isAllSelected,
            activeColor: const Color(0xFF6366F1),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selectedDlKeys.addAll(visibleKeys);
                } else {
                  _selectedDlKeys.removeAll(visibleKeys);
                }
              });
            },
          ),
          Text(
            '${selectedInScope.length}/${songs.length}',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          // 退出多选 (叉号移动到批量加入歌单的左边)
          _buildCompactBarIcon(
            icon: Icons.close_rounded,
            color: Colors.white70,
            tooltip: '退出多选',
            onPressed: () {
              setState(() {
                _isDlSelecting = false;
                _selectedDlKeys.clear();
              });
            },
          ),
          const SizedBox(width: 4),
          // 紧凑操作图标组：缩小彼此间距，让删除按钮靠左
          _buildCompactBarIcon(
            icon: Icons.queue_music_rounded,
            color: const Color(0xFF818CF8),
            tooltip: '批量加入合集',
            onPressed: selectedInScope.isEmpty
                ? null
                : () {
                    final selectedSongs = songs.where((s) => _selectedDlKeys.contains(s.key)).toList();
                    PlaylistDialogs.showBatchAddToPlaylistDialog(
                      context,
                      selectedSongs,
                      onComplete: () {
                        setState(() {
                          _isDlSelecting = false;
                          _selectedDlKeys.clear();
                        });
                      },
                    );
                  },
          ),
          const SizedBox(width: 4),
          _buildCompactBarIcon(
            icon: Icons.drive_file_move_rounded,
            color: const Color(0xFF10B981),
            tooltip: '导出到公开存储',
            onPressed: selectedInScope.isEmpty ? null : () => _exportBatchDownloads(songs.where((s) => _selectedDlKeys.contains(s.key)).toList()),
          ),
          const SizedBox(width: 4),
          _buildCompactBarIcon(
            icon: Icons.share_rounded,
            color: const Color(0xFF818CF8),
            tooltip: '批量分享',
            onPressed: selectedInScope.isEmpty ? null : () => _shareBatchDownloads(songs.where((s) => _selectedDlKeys.contains(s.key)).toList()),
          ),
          const SizedBox(width: 8),
          // 批量删除 (靠左并严格置于卡片底边框内)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              minimumSize: const Size(0, 29),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            ),
            icon: const Icon(Icons.delete_sweep_rounded, size: 14, color: Colors.white),
            label: Text(
              '删除(${selectedInScope.length})',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: selectedInScope.isEmpty ? null : () => _confirmBatchDeleteDownloads(songs.where((s) => _selectedDlKeys.contains(s.key)).toList()),
          ),
        ],
      ),
    );
  }

  /// 统一快捷控制栏：全部播放 & 随机播放 & 播放模式切换 (列表循环/单曲循环/随机播放)
  Widget _buildPlaylistHeaderBar({
    required int count,
    required VoidCallback onPlayAll,
    VoidCallback? onShuffleAll,
    String title = '全部播放',
    Widget? extraAction,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          // 顺序播放按钮
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: count > 0 ? onPlayAll : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: Color(0xFF6366F1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 6),
                Text(
                  '$title ($count)',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
          ),
          // 随机播放快捷入口
          if (onShuffleAll != null) ...[
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: count > 0 ? onShuffleAll : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0x22818CF8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0x44818CF8)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shuffle_rounded, size: 13, color: Color(0xFF818CF8)),
                    SizedBox(width: 4),
                    Text(
                      '随机',
                      style: TextStyle(color: Color(0xFFC7D2FE), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const Spacer(),
          ?extraAction,
        ],
      ),
    );
  }

  Widget _buildDownloadedSongCard(Song song, List<Song> list, int index) {
    return StreamBuilder<Song?>(
      stream: _player.currentSongStream,
      initialData: _player.currentSong,
      builder: (context, currentSnap) {
        final isPlaying = currentSnap.data != null &&
            currentSnap.data!.id == song.id &&
            currentSnap.data!.source == song.source;
        final isSelected = _selectedDlKeys.contains(song.key);

        // 批量选择模式下，边框与背景色严格由 isSelected 决定，防止“正在播放”与“批量选中”混淆
        final cardColor = _isDlSelecting
            ? (isSelected ? const Color(0x336366F1) : const Color(0xFF131A29).withValues(alpha: 0.8))
            : (isPlaying ? const Color(0x286366F1) : const Color(0xFF131A29).withValues(alpha: 0.8));

        final borderColor = _isDlSelecting
            ? (isSelected ? const Color(0xFF6366F1) : Colors.white.withValues(alpha: 0.04))
            : (isPlaying ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.04));

        final borderWidth = (_isDlSelecting && isSelected) || (!_isDlSelecting && isPlaying) ? 1.5 : 1.0;


        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: borderWidth,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              onTap: () {
                if (_isDlSelecting) {
                  setState(() {
                    if (isSelected) {
                      _selectedDlKeys.remove(song.key);
                    } else {
                      _selectedDlKeys.add(song.key);
                    }
                  });
                } else {
                  _player.setPlaylist(list, startIndex: index);
                }
              },
              onLongPress: () {
                if (!_isDlSelecting) {
                  setState(() {
                    _isDlSelecting = true;
                    _selectedDlKeys.add(song.key);
                  });
                }
              },
              leading: Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      width: 48,
                      height: 48,
                      color: const Color(0xFF1E293B),
                      child: song.coverUrl.isNotEmpty
                          ? Image.network(
                              song.coverUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const Icon(Icons.music_note, color: Colors.white54),
                            )
                          : const Icon(Icons.music_note, color: Colors.white54),
                    ),
                  ),
                  if (isPlaying)
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.equalizer_rounded, color: Color(0xFF818CF8), size: 24),
                    ),
                  if (_isDlSelecting)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                          color: isSelected ? const Color(0xFF6366F1) : Colors.white54,
                          size: 18,
                        ),
                      ),
                    ),
                ],
              ),
              title: Text(
                song.name,
                style: TextStyle(
                  color: isPlaying ? const Color(0xFF818CF8) : Colors.white,
                  fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        if (song.isLossless) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('《${song.name}》当前已是最高无损母带音质 (${song.quality})'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        } else {
                          DownloadSheet.show(context, song);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: song.isLossless
                              ? const Color(0x33F59E0B)
                              : const Color(0x3306B6D4),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              song.quality,
                              style: TextStyle(
                                color: song.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF22D3EE),
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (!song.isLossless) ...[
                              const SizedBox(width: 1),
                              const Icon(Icons.arrow_drop_down_rounded, size: 12, color: Color(0xFF22D3EE)),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${song.artist.isEmpty ? "未知歌手" : song.artist} · ${song.estimatedSizeStr}',
                        style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              trailing: _isDlSelecting
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.info_outline_rounded, color: Color(0xFF818CF8), size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                      onPressed: () => _showSongInfoSheet(song),
                      tooltip: '文件详情',
                    ),
            ),
          ),
        );
      },
    );
  }

  // ==================== 文件详情 ====================
  void _showSongInfoSheet(Song song) {
    int bytes = song.fileSizeBytes;
    if (bytes == 0 && song.localFilePath != null) {
      final f = File(song.localFilePath!);
      if (f.existsSync()) {
        bytes = f.lengthSync();
      }
    }
    final mbStr = (bytes / (1024 * 1024)).toStringAsFixed(2);
    final isFlac = song.localFilePath != null && song.localFilePath!.toLowerCase().endsWith('.flac');
    final extStr = isFlac ? 'FLAC (母带/无损)' : 'MP3 (高品压缩)';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 48,
                        height: 48,
                        color: const Color(0xFF1E293B),
                        child: song.coverUrl.isNotEmpty
                            ? Image.network(
                                song.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => const Icon(Icons.music_note, color: Colors.white54),
                              )
                            : const Icon(Icons.music_note, color: Colors.white54),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(song.artist, style: const TextStyle(color: Colors.white60, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text('文件存储信息', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0D14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('真实格式', extStr, valueColor: isFlac ? const Color(0xFFF59E0B) : const Color(0xFF06B6D4)),
                      const Divider(color: Colors.white10, height: 12),
                      _buildInfoRow('真实文件大小', '$mbStr MB ($bytes 字节)'),
                      const Divider(color: Colors.white10, height: 12),
                      _buildInfoRow('音质标签', song.quality),
                      const Divider(color: Colors.white10, height: 12),
                      _buildInfoRow('歌词状态', song.lrcPath != null ? '已同步 (.lrc)' : '无歌词'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text('本地存储绝对路径:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0D14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    song.localFilePath ?? '未知路径',
                    style: const TextStyle(color: Color(0xFF818CF8), fontSize: 10.5, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF10B981),
                      side: const BorderSide(color: Color(0xFF10B981)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.drive_file_move_rounded, size: 16),
                    label: const Text('导出至手机目录 (/Music/DMusic/)', style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final outPath = await _db.exportSongToPublic(song);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(outPath != null ? '已成功导出至:\n$outPath' : '导出失败，原文件是否存在？'),
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF818CF8),
                          side: const BorderSide(color: Color(0xFF6366F1)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text('复制路径', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          if (song.localFilePath != null) {
                            Clipboard.setData(ClipboardData(text: song.localFilePath!));
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制文件路径')),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
                        label: const Text('播放', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _player.playSong(song);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
        Text(value, style: TextStyle(color: valueColor ?? Colors.white, fontWeight: FontWeight.w600, fontSize: 11.5)),
      ],
    );
  }

  Future<void> _showStorageInfoDialog() async {
    final info = await _db.getStorageInfo();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.folder_special_rounded, color: Color(0xFF6366F1), size: 24),
                SizedBox(width: 10),
                Text('手机媒体存储库', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0D14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  _buildInfoRow('下载歌曲数', '${info["count"]} 首'),
                  const Divider(color: Colors.white10, height: 12),
                  _buildInfoRow('占用空间', '${info["totalMb"]} MB'),
                  const Divider(color: Colors.white10, height: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('存储目录 (应用专属私有)', style: TextStyle(color: Colors.white54, fontSize: 11.5)),
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () {
                              Clipboard.setData(ClipboardData(text: info["folderPath"].toString()));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('存储路径已复制到剪贴板'), duration: Duration(seconds: 1)),
                              );
                            },
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Row(
                                children: [
                                  Icon(Icons.copy_rounded, size: 12, color: Color(0xFF818CF8)),
                                  SizedBox(width: 3),
                                  Text('复制', style: TextStyle(color: Color(0xFF818CF8), fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Text(
                          info["folderPath"].toString(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '说明：此为 Android 应用沙盒私有存储。如需在系统文件管理或第三方播放器中访问，请在曲库多选中使用【导出到公开存储】。',
              style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.35),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('我知道了', style: TextStyle(color: Colors.white)),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 2. 我的收藏视图 ====================
  Widget _buildFavoritesView() {
    return StreamBuilder<List<Song>>(
      stream: _db.favoritesStream,
      initialData: _db.favorites,
      builder: (context, snapshot) {
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
          return _buildEmptyState(
            icon: Icons.favorite_border_rounded,
            title: '暂无收藏歌曲',
            desc: '在播放页或列表点击红心，喜爱的音乐就会出现在这里',
          );
        }

        // 1. 动态提取平台
        final platforms = <String>{'全部'};
        for (final s in list) {
          if (s.source.isNotEmpty) platforms.add(s.source);
        }

        // 2. 所选平台提取 (支持多选平台)
        final platformSongs = _favPlatforms.contains('全部')
            ? list
            : list.where((s) => _favPlatforms.any((plat) => s.source.contains(plat))).toList();

        // 3. 提取平台下的可用音质
        final qualities = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.quality.contains('Hi-Res')) qualities.add('Hi-Res');
          if (s.quality.contains('FLAC')) qualities.add('FLAC');
          if (s.quality.contains('320k')) qualities.add('320k');
          if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qualities.add('128k');
        }

        // 4. 提取平台下的可用歌手
        final artists = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.artist.isNotEmpty) {
            for (final part in s.artist.split(RegExp(r'[,/&、]'))) {
              final trimmed = part.trim();
              if (trimmed.isNotEmpty && trimmed != '未知歌手') artists.add(trimmed);
            }
          }
        }

        // 5. 综合过滤 (多选音质、大小、歌手 + 搜索关键字)
        var filtered = platformSongs;
        if (!_favQualities.contains('全部')) {
          filtered = filtered.where((s) => _favQualities.any((q) => s.quality.contains(q))).toList();
        }
        if (!_favSizes.contains('全部')) {
          filtered = filtered.where((s) {
            final mb = s.estimatedSizeMB;
            for (final sz in _favSizes) {
              if (sz == '< 5MB' && mb < 5) return true;
              if (sz == '5-15MB' && mb >= 5 && mb <= 15) return true;
              if (sz == '15-30MB' && mb > 15 && mb <= 30) return true;
              if (sz == '> 30MB' && mb > 30) return true;
            }
            return false;
          }).toList();
        }
        if (!_favArtists.contains('全部')) {
          filtered = filtered.where((s) => _favArtists.any((a) => s.artist.contains(a))).toList();
        }
        if (_searchQuery.isNotEmpty) {
          final cleanQ = Song.cleanTitle(_searchQuery);
          filtered = filtered.where((s) {
            return s.name.toLowerCase().contains(_searchQuery) ||
                (cleanQ.isNotEmpty && s.baseName.contains(cleanQ)) ||
                s.artist.toLowerCase().contains(_searchQuery) ||
                s.album.toLowerCase().contains(_searchQuery) ||
                s.source.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 多维级联筛选栏
            SliverToBoxAdapter(
              child: _buildCascadingFilterBar(
                platforms: platforms.toList(),
                selectedPlatforms: _favPlatforms,
                onPlatformSelected: (p) => _onFavPlatformSelected(p, list),
                qualities: qualities.toList(),
                selectedQualities: _favQualities,
                onQualitySelected: (q) => _toggleFilterItem(_favQualities, q),
                selectedSizes: _favSizes,
                onSizeSelected: (sz) => _toggleFilterItem(_favSizes, sz),
                artists: artists.toList(),
                selectedArtists: _favArtists,
                onArtistSelected: (ar) => _toggleFilterItem(_favArtists, ar),
              ),
            ),

            // 快捷播放条 / 多选固定条
            SliverPersistentHeader(
              pinned: true,
              delegate: _LibraryStickyHeaderDelegate(
                height: 52,
                child: _isFavSelecting
                    ? _buildFavoritesSelectionBar(filtered)
                    : _buildPlaylistHeaderBar(
                        count: filtered.length,
                        title: '我的收藏',
                        onPlayAll: () {
                          _player.setPlayMode(PlayMode.listLoop);
                          _player.setPlaylist(filtered, startIndex: 0);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('已开始顺序播放“我的收藏” (共${filtered.length}首)'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        onShuffleAll: () {
                          _player.setPlayMode(PlayMode.shuffle);
                          final rand = filtered.isNotEmpty ? Random().nextInt(filtered.length) : 0;
                          _player.setPlaylist(filtered, startIndex: rand);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('已开始随机播放“我的收藏” (共${filtered.length}首)'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                        extraAction: TextButton.icon(
                          icon: const Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF818CF8)),
                          label: const Text('批量管理', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                          onPressed: () => setState(() => _isFavSelecting = true),
                        ),
                      ),
              ),
            ),

            if (filtered.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('无符合筛选条件的收藏歌曲', style: TextStyle(color: Colors.white38, fontSize: 13)),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 140),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = filtered[index];
                      return _buildFavoriteSongCard(song, filtered, index);
                    },
                    childCount: filtered.length,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 我的收藏多选操作栏（对齐全部歌曲圆角卡片框与操作结构）
  Widget _buildFavoritesSelectionBar(List<Song> songs) {
    final visibleKeys = songs.map((s) => s.key).toSet();
    final selectedInScope = _selectedFavKeys.intersection(visibleKeys);
    final isAllSelected = songs.isNotEmpty && selectedInScope.length == songs.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Checkbox(
            value: isAllSelected,
            activeColor: const Color(0xFF6366F1),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selectedFavKeys.addAll(visibleKeys);
                } else {
                  _selectedFavKeys.removeAll(visibleKeys);
                }
              });
            },
          ),
          Text(
            '${selectedInScope.length}/${songs.length}',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          // 退出多选 (叉号，纯图标)
          _buildCompactBarIcon(
            icon: Icons.close_rounded,
            color: Colors.white70,
            tooltip: '退出多选',
            onPressed: () {
              setState(() {
                _isFavSelecting = false;
                _selectedFavKeys.clear();
              });
            },
          ),
          const SizedBox(width: 4),
          // 批量加入合集 (纯图标无文字)
          _buildCompactBarIcon(
            icon: Icons.queue_music_rounded,
            color: const Color(0xFF818CF8),
            tooltip: '批量加入合集',
            onPressed: selectedInScope.isEmpty
                ? null
                : () {
                    final selectedSongs = songs.where((s) => _selectedFavKeys.contains(s.key)).toList();
                    PlaylistDialogs.showBatchAddToPlaylistDialog(
                      context,
                      selectedSongs,
                      onComplete: () {
                        setState(() {
                          _isFavSelecting = false;
                          _selectedFavKeys.clear();
                        });
                      },
                    );
                  },
          ),
          const SizedBox(width: 4),
          // 批量分享 (纯图标无文字)
          _buildCompactBarIcon(
            icon: Icons.share_rounded,
            color: const Color(0xFF818CF8),
            tooltip: '批量分享',
            onPressed: selectedInScope.isEmpty
                ? null
                : () => _shareBatchFavorites(songs.where((s) => _selectedFavKeys.contains(s.key)).toList()),
          ),
          const SizedBox(width: 8),
          // 取消收藏 (红底胶囊按钮，换掉垃圾桶为镂空心形图标，改名为取消(N))
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              minimumSize: const Size(0, 29),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            ),
            icon: const Icon(Icons.favorite_border_rounded, size: 14, color: Colors.white),
            label: Text(
              '取消(${selectedInScope.length})',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
            onPressed: selectedInScope.isEmpty
                ? null
                : () => _confirmBatchDeleteFavorites(songs.where((s) => _selectedFavKeys.contains(s.key)).toList()),
          ),
        ],
      ),
    );
  }

  void _confirmBatchDeleteFavorites(List<Song> selectedSongs) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('取消收藏', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定要将选中的 ${selectedSongs.length} 首歌曲从收藏中移除吗？',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('确定取消', style: TextStyle(color: Colors.white)),
            onPressed: () async {
              for (final s in selectedSongs) {
                await _db.toggleFavorite(s);
              }
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {
                _isFavSelecting = false;
                _selectedFavKeys.clear();
              });
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已从收藏中移除 ${selectedSongs.length} 首歌曲')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _shareBatchFavorites(List<Song> selectedSongs) {
    if (selectedSongs.isEmpty) return;
    final text = selectedSongs.map((s) => '🎵 ${s.name} - ${s.artist} (${s.source})').join('\n');
    SharePlus.instance.share(ShareParams(
      text: '我的收藏精选 (${selectedSongs.length}首):\n$text\n来自 DMusic 音乐客户端',
      subject: '分享音乐',
    ));
  }

  /// 收藏单曲卡片
  Widget _buildFavoriteSongCard(Song song, List<Song> list, int index) {
    return StreamBuilder<Song?>(
      stream: _player.currentSongStream,
      initialData: _player.currentSong,
      builder: (context, currentSnap) {
        final isPlaying = currentSnap.data != null &&
            currentSnap.data!.id == song.id &&
            currentSnap.data!.source == song.source;
        final isSelected = _selectedFavKeys.contains(song.key);

        final cardColor = _isFavSelecting
            ? (isSelected ? const Color(0x336366F1) : const Color(0xFF131A29).withValues(alpha: 0.8))
            : (isPlaying ? const Color(0x286366F1) : const Color(0xFF131A29).withValues(alpha: 0.8));

        final borderColor = _isFavSelecting
            ? (isSelected ? const Color(0xFF6366F1) : Colors.white.withValues(alpha: 0.04))
            : (isPlaying ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.04));

        final borderWidth = (_isFavSelecting && isSelected) || (!_isFavSelecting && isPlaying) ? 1.5 : 1.0;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: borderWidth,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () {
                if (_isFavSelecting) {
                  setState(() {
                    if (isSelected) {
                      _selectedFavKeys.remove(song.key);
                    } else {
                      _selectedFavKeys.add(song.key);
                    }
                  });
                } else {
                  _player.setPlaylist(list, startIndex: index);
                }
              },
              onLongPress: () {
                if (!_isFavSelecting) {
                  setState(() {
                    _isFavSelecting = true;
                    _selectedFavKeys.add(song.key);
                  });
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // 左侧信息区严格占用卡片宽度的 17/20 (85%)
                    Expanded(
                      flex: 17,
                      child: Row(
                        children: [
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  color: const Color(0xFF1E293B),
                                  child: song.coverUrl.isNotEmpty
                                      ? Image.network(
                                          song.coverUrl,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => const Icon(Icons.music_note, color: Colors.white54),
                                        )
                                      : const Icon(Icons.music_note, color: Colors.white54),
                                ),
                              ),
                              if (isPlaying)
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.equalizer_rounded, color: Color(0xFF818CF8), size: 22),
                                ),
                              if (_isFavSelecting)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                      color: isSelected ? const Color(0xFF6366F1) : Colors.white54,
                                      size: 16,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  song.name,
                                  style: TextStyle(
                                    color: isPlaying ? const Color(0xFF818CF8) : Colors.white,
                                    fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                                    fontSize: 13.5,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (song.isDownloaded) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        margin: const EdgeInsets.only(right: 5),
                                        decoration: BoxDecoration(
                                          color: const Color(0x3310B981),
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                        child: const Text(
                                          '已下载',
                                          style: TextStyle(color: Color(0xFF34D399), fontSize: 9.5, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      margin: const EdgeInsets.only(right: 5),
                                      decoration: BoxDecoration(
                                        color: song.isLossless ? const Color(0x33F59E0B) : const Color(0x3306B6D4),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        song.quality,
                                        style: TextStyle(
                                          color: song.isLossless ? const Color(0xFFFBBF24) : const Color(0xFF22D3EE),
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '${song.artist.isEmpty ? "未知歌手" : song.artist} · ${song.source}',
                                        style: const TextStyle(color: Colors.white70, fontSize: 11.5),
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

                    // 右侧组件严格占用卡片宽度的 3/20 (15%)，靠右
                    Expanded(
                      flex: 3,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _isFavSelecting
                            ? StreamBuilder<List<Song>>(
                                stream: _db.downloadsStream,
                                initialData: _db.downloads,
                                builder: (context, snap) {
                                  final downloads = snap.data ?? _db.downloads;
                                  final match = _db.checkDownloadStatus(song, downloads);

                                  IconData iconData;
                                  Color iconColor;
                                  String labelText;
                                  Color labelColor;

                                  if (match.canUpgrade) {
                                    iconData = Icons.upgrade_rounded;
                                    iconColor = const Color(0xFF38BDF8);
                                    labelText = '升级';
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
                                    onTap: () => DownloadSheet.show(context, song, matchResult: match),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(iconData, color: iconColor, size: 19),
                                          const SizedBox(height: 1),
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
                              )
                            : IconButton(
                                icon: const Icon(Icons.favorite_rounded, color: Color(0xFFEF4444), size: 22),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                                onPressed: () => _db.toggleFavorite(song),
                                tooltip: '取消收藏',
                              ),
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

  // ==================== 3. 播放历史视图 (支持多选与长按删除) ====================
  Widget _buildHistoryView() {
    return StreamBuilder<List<Song>>(
      stream: _db.historyStream,
      initialData: _db.history,
      builder: (context, snapshot) {
        final list = snapshot.data ?? [];
        if (list.isEmpty) {
          return _buildEmptyState(
            icon: Icons.history_rounded,
            title: '暂无播放历史',
            desc: '播放过的曲目会在这里按时间展示',
          );
        }

        // 1. 动态提取平台
        final platforms = <String>{'全部'};
        for (final s in list) {
          if (s.source.isNotEmpty) platforms.add(s.source);
        }

        // 2. 所选平台提取 (支持多选平台)
        final platformSongs = _histPlatforms.contains('全部')
            ? list
            : list.where((s) => _histPlatforms.any((plat) => s.source.contains(plat))).toList();

        // 3. 提取平台下的可用音质
        final qualities = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.quality.contains('Hi-Res')) qualities.add('Hi-Res');
          if (s.quality.contains('FLAC')) qualities.add('FLAC');
          if (s.quality.contains('320k')) qualities.add('320k');
          if (s.quality.contains('128k') || s.quality.contains('标准') || s.quality.contains('192k')) qualities.add('128k');
        }

        // 4. 提取平台下的可用歌手
        final artists = <String>{'全部'};
        for (final s in platformSongs) {
          if (s.artist.isNotEmpty) {
            for (final part in s.artist.split(RegExp(r'[,/&、]'))) {
              final trimmed = part.trim();
              if (trimmed.isNotEmpty && trimmed != '未知歌手') artists.add(trimmed);
            }
          }
        }

        // 5. 综合过滤 (多选音质、大小、歌手 + 关键字)
        var filtered = platformSongs;
        if (!_histQualities.contains('全部')) {
          filtered = filtered.where((s) => _histQualities.any((q) => s.quality.contains(q))).toList();
        }
        if (!_histSizes.contains('全部')) {
          filtered = filtered.where((s) {
            final mb = s.estimatedSizeMB;
            for (final sz in _histSizes) {
              if (sz == '< 5MB' && mb < 5) return true;
              if (sz == '5-15MB' && mb >= 5 && mb <= 15) return true;
              if (sz == '15-30MB' && mb > 15 && mb <= 30) return true;
              if (sz == '> 30MB' && mb > 30) return true;
            }
            return false;
          }).toList();
        }
        if (!_histArtists.contains('全部')) {
          filtered = filtered.where((s) => _histArtists.any((a) => s.artist.contains(a))).toList();
        }
        if (_searchQuery.isNotEmpty) {
          filtered = filtered.where((s) {
            return s.name.toLowerCase().contains(_searchQuery) ||
                s.artist.toLowerCase().contains(_searchQuery) ||
                s.album.toLowerCase().contains(_searchQuery) ||
                s.source.toLowerCase().contains(_searchQuery);
          }).toList();
        }

        return CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 级联筛选栏
            SliverToBoxAdapter(
              child: _buildCascadingFilterBar(
                platforms: platforms.toList(),
                selectedPlatforms: _histPlatforms,
                onPlatformSelected: (p) => _onHistPlatformSelected(p, list),
                qualities: qualities.toList(),
                selectedQualities: _histQualities,
                onQualitySelected: (q) => _toggleFilterItem(_histQualities, q),
                selectedSizes: _histSizes,
                onSizeSelected: (sz) => _toggleFilterItem(_histSizes, sz),
                artists: artists.toList(),
                selectedArtists: _histArtists,
                onArtistSelected: (ar) => _toggleFilterItem(_histArtists, ar),
              ),
            ),

            // 历史操作栏
            SliverPersistentHeader(
              pinned: true,
              delegate: _LibraryStickyHeaderDelegate(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_isHistorySelecting) ...[
                        Builder(
                          builder: (context) {
                            final visibleKeys = filtered.map((s) => s.key).toSet();
                            final selectedInScope = _selectedHistoryKeys.intersection(visibleKeys);
                            final isAllSelected = filtered.isNotEmpty && selectedInScope.length == filtered.length;
                            return Row(
                              children: [
                                Checkbox(
                                  value: isAllSelected,
                                  activeColor: const Color(0xFF6366F1),
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        _selectedHistoryKeys.addAll(visibleKeys);
                                      } else {
                                        _selectedHistoryKeys.removeAll(visibleKeys);
                                      }
                                    });
                                  },
                                ),
                                Text(
                                  '已选 ${selectedInScope.length}/${filtered.length}',
                                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                ),
                              ],
                            );
                          },
                        ),
                        Builder(
                          builder: (context) {
                            final visibleKeys = filtered.map((s) => s.key).toSet();
                            final selectedInScope = _selectedHistoryKeys.intersection(visibleKeys);
                            return Row(
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white54),
                                  label: const Text('取消', style: TextStyle(color: Colors.white54, fontSize: 12)),
                                  onPressed: () {
                                    setState(() {
                                      _isHistorySelecting = false;
                                      _selectedHistoryKeys.clear();
                                    });
                                  },
                                ),
                                TextButton.icon(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                                  label: Text('删除(${selectedInScope.length})', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                                  onPressed: selectedInScope.isEmpty
                                      ? null
                                      : () => _confirmBatchDeleteHistory(filtered.where((s) => _selectedHistoryKeys.contains(s.key)).toList()),
                                ),
                              ],
                            );
                          },
                        ),
                      ] else ...[
                        Text('播放历史 (${filtered.length})', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        Row(
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF818CF8)),
                              label: const Text('批量管理', style: TextStyle(color: Color(0xFF818CF8), fontSize: 12)),
                              onPressed: () {
                                setState(() => _isHistorySelecting = true);
                              },
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.clear_all_rounded, size: 16, color: Colors.white38),
                              label: const Text('清空历史', style: TextStyle(color: Colors.white38, fontSize: 12)),
                              onPressed: () => _db.clearHistory(),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),

            if (filtered.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('无符合筛选条件的播放历史', style: TextStyle(color: Colors.white38, fontSize: 13)),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 140),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = filtered[index];
                      final isSelected = _selectedHistoryKeys.contains(song.key);
                      final isDownloaded = song.isDownloaded;
                      final match = _db.checkDownloadStatus(song, _db.downloads);

                      return StreamBuilder<Song?>(
                        stream: _player.currentSongStream,
                        initialData: _player.currentSong,
                        builder: (context, currentSnap) {
                          final isCurrent = currentSnap.data != null &&
                              currentSnap.data!.id == song.id &&
                              currentSnap.data!.source == song.source;

                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0x336366F1)
                                  : (isCurrent
                                      ? const Color(0x286366F1)
                                      : const Color(0xFF131A29).withValues(alpha: 0.6)),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF6366F1)
                                    : (isCurrent
                                        ? const Color(0xFF818CF8)
                                        : Colors.transparent),
                                width: (isSelected || isCurrent) ? 1.2 : 1.0,
                              ),
                            ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              if (_isHistorySelecting) {
                                setState(() {
                                  if (isSelected) {
                                    _selectedHistoryKeys.remove(song.key);
                                  } else {
                                    _selectedHistoryKeys.add(song.key);
                                  }
                                });
                              } else {
                                _player.setPlaylist(filtered, startIndex: index);
                              }
                            },
                            onLongPress: () {
                              if (!_isHistorySelecting) {
                                setState(() {
                                  _isHistorySelecting = true;
                                  _selectedHistoryKeys.add(song.key);
                                });
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  if (_isHistorySelecting)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Checkbox(
                                        value: isSelected,
                                        activeColor: const Color(0xFF6366F1),
                                        onChanged: (val) {
                                          setState(() {
                                            if (val == true) {
                                              _selectedHistoryKeys.add(song.key);
                                            } else {
                                              _selectedHistoryKeys.remove(song.key);
                                            }
                                          });
                                        },
                                      ),
                                    ),
                                  // 左侧信息区 (未多选时 flex: isDownloaded ? 4 : 3)
                                  Expanded(
                                    flex: _isHistorySelecting ? 1 : (isDownloaded ? 4 : 3),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          song.name,
                                          style: TextStyle(
                                            color: isCurrent ? const Color(0xFF818CF8) : Colors.white,
                                            fontSize: 13,
                                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          isCurrent
                                              ? (_player.isPlaying
                                                  ? '${song.artist} · ${song.source} · 正在播放'
                                                  : (_player.currentPosition > Duration.zero
                                                      ? '${song.artist} · ${song.source} · 上次听到 ${_player.currentPosition.inMinutes.remainder(60).toString().padLeft(2, '0')}:${_player.currentPosition.inSeconds.remainder(60).toString().padLeft(2, '0')}'
                                                      : '${song.artist} · ${song.source}'))
                                              : '${song.artist} · ${song.source}',
                                          style: TextStyle(
                                            color: isCurrent ? const Color(0xFFA5B4FC) : Colors.white38,
                                            fontSize: 11,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),

                                  // 右侧组件严格占用 2/5 (40%)，下载过的显示两键
                                  if (!_isHistorySelecting)
                                    Expanded(
                                      flex: isDownloaded ? 1 : 2,
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          if (!isDownloaded) ...[
                                            Tooltip(
                                              message: '下载歌曲',
                                              child: InkWell(
                                                borderRadius: BorderRadius.circular(6),
                                                onTap: () => DownloadSheet.show(context, song, matchResult: match),
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    mainAxisAlignment: MainAxisAlignment.center,
                                                    children: [
                                                      const Icon(Icons.download_rounded, color: Colors.white70, size: 18),
                                                      const SizedBox(height: 1),
                                                      Text(
                                                        song.estimatedSizeStr,
                                                        style: const TextStyle(color: Colors.white38, fontSize: 8.5),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 2),
                                          ],
                                          // 分享按钮
                                          Tooltip(
                                            message: '分享',
                                            child: InkResponse(
                                              onTap: () => _shareSong(song),
                                              radius: 14,
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 1.5, vertical: 6),
                                                child: Icon(Icons.share_rounded, color: Colors.white38, size: 18),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 2),
                                          // 删除按钮
                                          Tooltip(
                                            message: '删除记录',
                                            child: InkResponse(
                                              onTap: () => _db.deleteHistory(song.key),
                                              radius: 14,
                                              child: const Padding(
                                                padding: EdgeInsets.symmetric(horizontal: 1.5, vertical: 6),
                                                child: Icon(Icons.delete_outline_rounded, color: Colors.white24, size: 18),
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
                },
                    childCount: filtered.length,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _confirmBatchDeleteHistory(List<Song> songsToDelete) {
    final count = songsToDelete.length;
    if (count == 0) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('删除播放历史', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定要删除选中的 $count 条播放历史记录吗？',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('确定删除', style: TextStyle(color: Colors.white)),
            onPressed: () async {
              final keysToDelete = songsToDelete.map((s) => s.key).toList();
              await _db.batchDeleteHistory(keysToDelete);
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {
                _selectedHistoryKeys.removeAll(keysToDelete);
                if (_selectedHistoryKeys.isEmpty) {
                  _isHistorySelecting = false;
                }
              });
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已删除 $count 条播放记录')),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  // ==================== 4. 歌单合集视图 ====================
  Widget _buildCustomPlaylistsView() {
    return StreamBuilder<List<CustomPlaylist>>(
      stream: _db.playlistsStream,
      initialData: _db.playlists,
      builder: (context, snapshot) {
        final playlists = snapshot.data ?? [];

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '我的歌单合集 (${playlists.length})',
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF10B981),
                          side: const BorderSide(color: Color(0xFF10B981)),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.download_for_offline_rounded, size: 16),
                        label: const Text('导入外部歌单', style: TextStyle(fontSize: 12)),
                        onPressed: () => _showImportPlaylistDialog(),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6366F1),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 16, color: Colors.white),
                        label: const Text('新建合集', style: TextStyle(color: Colors.white, fontSize: 12)),
                        onPressed: () => PlaylistDialogs.showCreatePlaylistDialog(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: playlists.isEmpty
                  ? _buildEmptyState(
                      icon: Icons.queue_music_rounded,
                      title: '暂无歌单合集',
                      desc: '您可以将不同来源专栏合集（如车载DJ、纯音乐、通勤等）以独立合集分类管理，同一个合集内歌曲将独立连续播放。',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 140),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final pl = playlists[index];
                        return _buildPlaylistCard(pl);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPlaylistCard(CustomPlaylist pl) {
    final firstSongCover = pl.songs.isNotEmpty ? pl.songs.first.coverUrl : '';
    final dateStr = '${pl.createTime.year}-${pl.createTime.month.toString().padLeft(2, '0')}-${pl.createTime.day.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29).withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openPlaylistDetail(pl),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                // 信息区严格占用总宽度的 60% (3/5)
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          height: 48,
                          color: const Color(0xFF1E293B),
                          child: firstSongCover.isNotEmpty
                              ? Image.network(
                                  firstSongCover,
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, err, stack) => const Icon(Icons.queue_music_rounded, color: Color(0xFF818CF8)),
                                )
                              : const Icon(Icons.queue_music_rounded, color: Color(0xFF818CF8)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              pl.name,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${pl.songs.length} 首歌曲',
                              style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 1),
                            Text(
                              dateStr,
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 右侧组件严格占用总宽度的 40% (2/5)，靠右两端分散排列
                Expanded(
                  flex: 2,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 随机播放该合集
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.shuffle_rounded, color: Color(0xFF818CF8), size: 20),
                        tooltip: '随机播放该合集',
                        onPressed: pl.songs.isEmpty
                            ? null
                            : () {
                                _player.setPlayMode(PlayMode.shuffle);
                                final randIdx = Random().nextInt(pl.songs.length);
                                _player.setPlaylist(pl.songs, startIndex: randIdx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已开始随机播放“${pl.name}”合集 (共${pl.songs.length}首)')),
                                );
                              },
                      ),
                      // 顺序播放该合集
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF6366F1), size: 28),
                        tooltip: '顺序播放该合集',
                        onPressed: pl.songs.isEmpty
                            ? null
                            : () {
                                _player.setPlayMode(PlayMode.listLoop);
                                _player.setPlaylist(pl.songs, startIndex: 0);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已开始顺序播放“${pl.name}”合集 (共${pl.songs.length}首)')),
                                );
                              },
                      ),
                      // 更多操作
                      PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
                        color: const Color(0xFF161E2E),
                        onSelected: (val) {
                          if (val == 'rename') {
                            _showRenamePlaylistDialog(pl);
                          } else if (val == 'delete') {
                            _confirmDeletePlaylist(pl);
                          }
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit_rounded, color: Colors.white70, size: 18),
                                SizedBox(width: 8),
                                Text('重命名合集', style: TextStyle(color: Colors.white, fontSize: 13)),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                                SizedBox(width: 8),
                                Text('删除合集', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                              ],
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
        ),
      ),
    );
  }


  void _openPlaylistDetail(CustomPlaylist playlist) {
    bool isSelecting = false;
    bool isReordering = false;
    final Set<String> selectedSongKeys = {};

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F141F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return PopScope(
            canPop: !isSelecting && !isReordering,
            onPopInvokedWithResult: (didPop, result) {
              if (didPop) return;
              if (isReordering) {
                setSheetState(() => isReordering = false);
                return;
              }
              if (isSelecting) {
                setSheetState(() {
                  isSelecting = false;
                  selectedSongKeys.clear();
                });
              }
            },
            child: DraggableScrollableSheet(
              initialChildSize: 0.88,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                return StreamBuilder<List<CustomPlaylist>>(
                  stream: _db.playlistsStream,
                  initialData: _db.playlists,
                  builder: (context, snap) {
                    final curList = (snap.data ?? _db.playlists).firstWhere(
                      (p) => p.id == playlist.id,
                      orElse: () => playlist,
                    );

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        children: [
                          Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 14),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          // 1. 顶部区域：如果处于排序模式，展示专属沉浸顶栏；否则展示常规标题与操作栏
                          if (isReordering) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.swap_vert_rounded, color: Color(0xFF818CF8), size: 20),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              '${curList.name} · 调整顺序',
                                              style: const TextStyle(color: Colors.white, fontSize: 16.5, fontWeight: FontWeight.bold),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '上下长按把手调序 · 点击 ⤒ 一键置顶 (共 ${curList.songs.length} 首)',
                                        style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                                      ),
                                    ],
                                  ),
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF6366F1),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                                    elevation: 2,
                                  ),
                                  icon: const Icon(Icons.check_rounded, size: 16),
                                  label: const Text('完成', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                                  onPressed: () {
                                    setSheetState(() => isReordering = false);
                                  },
                                ),
                              ],
                            ),
                          ] else ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // 歌单名称：点击可直接重命名编辑
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => _showRenamePlaylistDialog(curList),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  curList.name,
                                                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              const Icon(Icons.edit_rounded, color: Colors.white38, size: 15),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      // 副标题：多选时显示“已选择 X/总数 首” + “全选”；普通时显示“X 首歌曲 · 专属独立播放队列”
                                      if (isSelecting)
                                        Row(
                                          children: [
                                            Text(
                                              '已选择 ${selectedSongKeys.length}/${curList.songs.length} 首',
                                              style: const TextStyle(color: Color(0xFF818CF8), fontSize: 11.5, fontWeight: FontWeight.w600),
                                            ),
                                            const SizedBox(width: 8),
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: () {
                                                setSheetState(() {
                                                  if (curList.songs.isNotEmpty && curList.songs.every((s) => selectedSongKeys.contains(s.key))) {
                                                    selectedSongKeys.clear();
                                                  } else {
                                                    selectedSongKeys.addAll(curList.songs.map((s) => s.key));
                                                  }
                                                });
                                              },
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                child: Text(
                                                  (curList.songs.isNotEmpty && curList.songs.every((s) => selectedSongKeys.contains(s.key))) ? '取消全选' : '全选',
                                                  style: const TextStyle(color: Color(0xFF6366F1), fontSize: 11.5, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      else
                                        Text(
                                          '${curList.songs.length} 首歌曲 · 专属独立播放队列',
                                          style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                                        ),
                                    ],
                                  ),
                                ),
                                if (curList.songs.isNotEmpty) ...[
                                  // 随机播放
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF818CF8),
                                      side: const BorderSide(color: Color(0x44818CF8)),
                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                                    ),
                                    icon: const Icon(Icons.shuffle_rounded, size: 14),
                                    label: const Text('随机', style: TextStyle(fontSize: 12)),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _player.setPlayMode(PlayMode.shuffle);
                                      final rand = Random().nextInt(curList.songs.length);
                                      _player.setPlaylist(curList.songs, startIndex: rand);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('已在【${curList.name}】中开启独立随机播放')),
                                      );
                                    },
                                  ),
                                  const SizedBox(width: 6),
                                  // 顺序播放全部
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF6366F1),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                                    ),
                                    icon: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                                    label: const Text('播放全部', style: TextStyle(color: Colors.white, fontSize: 12)),
                                    onPressed: () {
                                      Navigator.pop(ctx);
                                      _player.setPlayMode(PlayMode.listLoop);
                                      _player.setPlaylist(curList.songs, startIndex: 0);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('已在【${curList.name}】中开启独立列表播放')),
                                      );
                                    },
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 10),
                            // 2. 操作栏：添加歌曲 | 移动 | 移出 | 排序 | 批量管理
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.2),
                                    foregroundColor: const Color(0xFF34D399),
                                    side: const BorderSide(color: Color(0x5510B981)),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                                  label: const Text('添加歌曲', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  onPressed: () => _showAddSongsFromLibraryDialog(context, curList.id),
                                ),
                                if (isSelecting) ...[
                                  const SizedBox(width: 8),
                                  // 移动：移动符号 + “移动” (未勾选置灰禁用)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      foregroundColor: selectedSongKeys.isNotEmpty ? const Color(0xFF818CF8) : Colors.white24,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    ),
                                    icon: Icon(
                                      Icons.drive_file_move_rounded,
                                      size: 16,
                                      color: selectedSongKeys.isNotEmpty ? const Color(0xFF818CF8) : Colors.white24,
                                    ),
                                    label: const Text('移动', style: TextStyle(fontSize: 12)),
                                    onPressed: selectedSongKeys.isEmpty
                                        ? null
                                        : () => _showBatchMovePlaylistSongsDialog(context, setSheetState, curList, selectedSongKeys),
                                  ),
                                  const SizedBox(width: 4),
                                  // 移出：移出符号 + “移出” (未勾选置灰禁用)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      foregroundColor: selectedSongKeys.isNotEmpty ? Colors.redAccent : Colors.white24,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    ),
                                    icon: Icon(
                                      Icons.playlist_remove_rounded,
                                      size: 16,
                                      color: selectedSongKeys.isNotEmpty ? Colors.redAccent : Colors.white24,
                                    ),
                                    label: const Text('移出', style: TextStyle(fontSize: 12)),
                                    onPressed: selectedSongKeys.isEmpty
                                        ? null
                                        : () => _confirmBatchRemoveFromPlaylist(context, setSheetState, curList, selectedSongKeys),
                                  ),
                                  const Spacer(),
                                  // 取消：直接显示叉号，靠在最右端 (1. A)
                                  IconButton(
                                    tooltip: '退出多选',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                                    onPressed: () {
                                      setSheetState(() {
                                        isSelecting = false;
                                        selectedSongKeys.clear();
                                      });
                                    },
                                  ),
                                ] else ...[
                                  const Spacer(),
                                  if (curList.songs.isNotEmpty) ...[
                                    // 排序按钮 (点击唤起规则排序面板或长按拖拽)
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(0xFF818CF8),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      ),
                                      icon: const Icon(Icons.sort_rounded, size: 16),
                                      label: const Text('排序', style: TextStyle(fontSize: 12)),
                                      onPressed: () => _showPlaylistSortOrderSheet(
                                        context,
                                        curList,
                                        onEnterReorder: () => setSheetState(() => isReordering = true),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    // 批量管理完全靠右
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(0xFF818CF8),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      ),
                                      icon: const Icon(Icons.checklist_rounded, size: 16),
                                      label: const Text('批量管理', style: TextStyle(fontSize: 12)),
                                      onPressed: () {
                                        setSheetState(() {
                                          isSelecting = true;
                                        });
                                      },
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 6),
                          Expanded(
                            child: curList.songs.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.queue_music_rounded, size: 48, color: Colors.white24),
                                        const SizedBox(height: 10),
                                        const Text('合集内暂无歌曲', style: TextStyle(color: Colors.white54, fontSize: 14)),
                                        const SizedBox(height: 4),
                                        const Text('支持添加已下载歌曲与我的收藏歌曲', style: TextStyle(color: Colors.white38, fontSize: 11)),
                                        const SizedBox(height: 14),
                                        FilledButton.icon(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: const Color(0xFF6366F1),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          ),
                                          icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                                          label: const Text(
                                            '挑选歌曲加入合集',
                                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                          ),
                                          onPressed: () => _showAddSongsFromLibraryDialog(context, curList.id),
                                        ),
                                      ],
                                    ),
                                  )
                                : isReordering
                                    ? _buildReorderableSongList(curList, scrollController)
                                    : ListView.builder(
                                    controller: scrollController,
                                    itemCount: curList.songs.length,
                                    itemBuilder: (context, idx) {
                                      final song = curList.songs[idx];
                                       final isSelected = selectedSongKeys.contains(song.key);
                                      return Container(
                                        margin: const EdgeInsets.symmetric(vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isSelected ? const Color(0x336366F1) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: isSelected ? const Color(0xFF6366F1) : Colors.transparent),
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                          child: ListTile(
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                          leading: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (isSelecting)
                                                Checkbox(
                                                  value: isSelected,
                                                  activeColor: const Color(0xFF6366F1),
                                                  onChanged: (val) {
                                                    setSheetState(() {
                                                      if (val == true) {
                                                        selectedSongKeys.add(song.key);
                                                      } else {
                                                        selectedSongKeys.remove(song.key);
                                                      }
                                                    });
                                                  },
                                                ),
                                              ClipRRect(
                                                borderRadius: BorderRadius.circular(6),
                                                child: Container(
                                                  width: 40,
                                                  height: 40,
                                                  color: const Color(0xFF1E293B),
                                                  child: song.coverUrl.isNotEmpty
                                                      ? Image.network(
                                                          song.coverUrl,
                                                          fit: BoxFit.cover,
                                                          errorBuilder: (ctx, err, stack) => const Icon(Icons.music_note, color: Colors.white38),
                                                        )
                                                      : const Icon(Icons.music_note, color: Colors.white38),
                                                ),
                                              ),
                                            ],
                                          ),
                                          title: Text(
                                            song.name,
                                            style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          subtitle: Text(
                                            '${song.artist} · ${song.quality}',
                                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          onTap: () {
                                            if (isSelecting) {
                                              setSheetState(() {
                                                if (isSelected) {
                                                  selectedSongKeys.remove(song.key);
                                                } else {
                                                  selectedSongKeys.add(song.key);
                                                }
                                              });
                                            } else {
                                              Navigator.pop(ctx);
                                              _player.setPlaylist(curList.songs, startIndex: idx);
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('正在播放【${curList.name}】合集专属队列: ${song.name}'),
                                                  duration: const Duration(seconds: 1),
                                                ),
                                              );
                                            }
                                          },
                                          onLongPress: () {
                                            if (!isSelecting) {
                                              setSheetState(() {
                                                isSelecting = true;
                                                selectedSongKeys.add(song.key);
                                              });
                                            }
                                          },
                                          trailing: isSelecting
                                              ? null
                                              : Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    _buildPlaylistDownloadAction(song),
                                                    IconButton(
                                                      icon: const Icon(Icons.remove_circle_outline_rounded, color: Colors.redAccent, size: 19),
                                                      tooltip: '移出合集 (保留在全部歌曲)',
                                                      onPressed: () async {
                                                        await _db.removeSongFromPlaylist(curList.id, song.key);
                                                        if (context.mounted) {
                                                          ScaffoldMessenger.of(context).showSnackBar(
                                                            SnackBar(
                                                              content: Text('已从【${curList.name}】移出 (原歌曲与本地文件仍完好保留在全部歌曲中)'),
                                                              duration: const Duration(seconds: 2),
                                                            ),
                                                          );
                                                        }
                                                      },
                                                    ),
                                                  ],
                                                ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaylistDownloadAction(Song song) {
    return StreamBuilder<List<Song>>(
      stream: _db.downloadsStream,
      initialData: _db.downloads,
      builder: (context, snapshot) {
        final match = _db.checkDownloadStatus(song, snapshot.data ?? _db.downloads);
        final color = match.isExact
            ? const Color(0xFF10B981)
            : match.isVariant ? const Color(0xFF818CF8) : Colors.white54;
        var size = '预估${song.estimatedSizeStr}';
        if (match.isDownloaded) {
          size = '大小未知';
          final path = match.matchedSong?.localFilePath;
          if (path != null) {
            try {
              final bytes = File(path).lengthSync();
              size = '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
            } on FileSystemException catch (_) {}
          }
        }
        final tooltip = match.canUpgrade
            ? '已下载，可升级音质'
            : match.isExact ? '已下载，点击查看下载选项'
            : match.isVariant ? '已有其他版本，点击查看下载选项' : '下载';
        return IconButton(
          tooltip: tooltip,
          padding: const EdgeInsets.all(4),
          icon: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                match.canUpgrade ? Icons.upgrade_rounded
                    : match.isExact ? Icons.check_circle_rounded
                    : match.isVariant ? Icons.file_download_done_rounded
                    : Icons.download_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(height: 2),
              Text(size, style: TextStyle(color: color, fontSize: 9)),
            ],
          ),
          onPressed: () => DownloadSheet.show(context, song, matchResult: match),
        );
      },
    );
  }

  /// 自定义歌单拖拽排序列表
  Widget _buildReorderableSongList(CustomPlaylist curList, ScrollController scrollController) {
    return ReorderableListView.builder(
      scrollController: scrollController,
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 30),
      itemCount: curList.songs.length,
      // ignore: deprecated_member_use
      onReorder: (oldIdx, newIdx) async {
        await _db.reorderPlaylistSongs(curList.id, oldIdx, newIdx);
      },
      proxyDecorator: (Widget child, int index, Animation<double> animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(animation.value);
            return Transform.scale(
              scale: 1.02 + 0.02 * t,
              child: Material(
                color: Colors.transparent,
                elevation: 10,
                shadowColor: const Color(0xFF6366F1).withValues(alpha: 0.5),
                child: child,
              ),
            );
          },
          child: child,
        );
      },
      itemBuilder: (context, idx) {
        final song = curList.songs[idx];
        return Container(
          key: ValueKey('reorder_${song.key}'),
          margin: const EdgeInsets.symmetric(vertical: 2.0),
          decoration: BoxDecoration(
            color: const Color(0xFF131A29).withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 0.8),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            dense: true,
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顺位序号徽章
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: idx < 3
                        ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: idx < 3
                          ? const Color(0xFFFBBF24).withValues(alpha: 0.4)
                          : Colors.transparent,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    '${idx + 1}',
                    style: TextStyle(
                      color: idx < 3 ? const Color(0xFFFBBF24) : Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 36,
                    height: 36,
                    color: const Color(0xFF1E293B),
                    child: song.coverUrl.isNotEmpty
                        ? Image.network(
                            song.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, stack) => const Icon(Icons.music_note, color: Colors.white38),
                          )
                        : const Icon(Icons.music_note, color: Colors.white38),
                  ),
                ),
              ],
            ),
            title: Text(
              song.name,
              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${song.artist} · ${song.quality}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (idx > 0)
                  IconButton(
                    icon: const Icon(Icons.vertical_align_top_rounded, color: Color(0xFF818CF8), size: 20),
                    tooltip: '置顶到首位',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    onPressed: () async {
                      await _db.moveSongToTop(curList.id, song.key);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已将《${song.name}》置顶到首位')),
                        );
                      }
                    },
                  )
                else
                  Container(
                    width: 36,
                    alignment: Alignment.center,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.4), width: 0.8),
                      ),
                      child: const Text(
                        'TOP',
                        style: TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                ReorderableDragStartListener(
                  index: idx,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: const Icon(Icons.drag_indicator_rounded, color: Color(0xFF818CF8), size: 22),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 歌单排列顺序与规则排序面板
  void _showPlaylistSortOrderSheet(
    BuildContext ctx,
    CustomPlaylist curList, {
    required VoidCallback onEnterReorder,
  }) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sortCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('调整歌单播放与排列顺序', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.drag_handle_rounded, color: Color(0xFF818CF8)),
                title: const Text('手动自由拖拽排序', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: const Text('上下拖动把手，随心所欲定制歌曲顺序', style: TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: () {
                  Navigator.pop(sortCtx);
                  onEnterReorder();
                },
              ),
              const Divider(color: Colors.white10),
              ListTile(
                leading: const Icon(Icons.sort_by_alpha_rounded, color: Color(0xFF10B981)),
                title: const Text('按歌名名称排序 (A - Z)', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(sortCtx);
                  final sorted = List<Song>.from(curList.songs);
                  sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                  await _db.updatePlaylistSongOrder(curList.id, sorted);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('已按歌名名称 A-Z 重新排列歌单')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_rounded, color: Color(0xFF06B6D4)),
                title: const Text('按歌手姓名归类排序', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(sortCtx);
                  final sorted = List<Song>.from(curList.songs);
                  sorted.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
                  await _db.updatePlaylistSongOrder(curList.id, sorted);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('已按歌手姓名归类重新排列歌单')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.timer_rounded, color: Color(0xFFF59E0B)),
                title: const Text('按歌曲时长排序 (短歌在前)', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(sortCtx);
                  final sorted = List<Song>.from(curList.songs);
                  sorted.sort((a, b) => a.durationSeconds.compareTo(b.durationSeconds));
                  await _db.updatePlaylistSongOrder(curList.id, sorted);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('已按歌曲时长重新排列歌单')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_vert_rounded, color: Color(0xFFEC4899)),
                title: const Text('反转当前歌单顺序 (倒序/正序)', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(sortCtx);
                  final sorted = curList.songs.reversed.toList();
                  await _db.updatePlaylistSongOrder(curList.id, sorted);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('已反转当前歌单顺序')));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 歌单多选：批量移出歌单（保留在全部歌曲和本地）
  void _confirmBatchRemoveFromPlaylist(
    BuildContext context,
    StateSetter setSheetState,
    CustomPlaylist curList,
    Set<String> selectedSongKeys,
  ) {
    final count = selectedSongKeys.length;
    if (count == 0) return;

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('移出歌单', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定将选中的 $count 首歌曲从歌单【${curList.name}】中移出吗？\n\n（注：仅从该歌单合集中移除，原歌曲、我的收藏及已下载的本地音乐文件均完好保留，绝不会被删除）',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(dlgCtx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: Text('确认移出 ($count)', style: const TextStyle(color: Colors.white)),
            onPressed: () async {
              Navigator.pop(dlgCtx);
              await _db.batchRemoveSongsFromPlaylist(curList.id, selectedSongKeys.toList());
              setSheetState(() {
                selectedSongKeys.clear();
              });
              if (mounted) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text('已从【${curList.name}】移出 $count 首歌曲 (原歌曲与本地文件仍完好保留)'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// 歌单多选：批量移动至其他歌单
  void _showBatchMovePlaylistSongsDialog(
    BuildContext context,
    StateSetter setSheetState,
    CustomPlaylist curList,
    Set<String> selectedSongKeys,
  ) {
    final count = selectedSongKeys.length;
    if (count == 0) return;

    final otherPlaylists = _db.playlists.where((p) => p.id != curList.id).toList();

    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text('移动 $count 首歌曲至...', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (otherPlaylists.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '暂无其他歌单合集，请点击下方按钮新建合集并移入',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: otherPlaylists.length,
                    separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (ctx, index) {
                      final targetPl = otherPlaylists[index];
                      return ListTile(
                        leading: const Icon(Icons.queue_music_rounded, color: Color(0xFF818CF8)),
                        title: Text(
                          targetPl.name,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${targetPl.songs.length} 首歌曲',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        onTap: () async {
                          Navigator.pop(dlgCtx);
                          final songsToMove = curList.songs.where((s) => selectedSongKeys.contains(s.key)).toList();
                          final moved = await _db.batchMoveSongsToPlaylist(
                            sourcePlaylistId: curList.id,
                            targetPlaylistId: targetPl.id,
                            songs: songsToMove,
                          );
                          setSheetState(() {
                            selectedSongKeys.clear();
                          });
                          if (mounted) {
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              SnackBar(
                                content: Text('已成功将 $moved 首歌曲移动至【${targetPl.name}】'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF6366F1),
                  side: const BorderSide(color: Color(0xFF6366F1)),
                ),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('新建合集并移入', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  Navigator.pop(dlgCtx);
                  final songsToMove = curList.songs.where((s) => selectedSongKeys.contains(s.key)).toList();
                  PlaylistDialogs.showCreatePlaylistDialog(
                    context,
                    initialSongs: songsToMove,
                    onComplete: () async {
                      await _db.batchRemoveSongsFromPlaylist(curList.id, selectedSongKeys.toList());
                      setSheetState(() {
                        selectedSongKeys.clear();
                      });
                    },
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(dlgCtx),
          ),
        ],
      ),
    );
  }

  /// 从全部歌曲与收藏中挑选并批量添加进当前合集
  void _showAddSongsFromLibraryDialog(BuildContext context, String playlistId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final dlSongs = _db.downloads;
        final favSongs = _db.favorites;
        // 去重合并所有候选歌曲（保留已下载元数据或收藏元数据）
        final Map<String, Song> songMap = {};
        for (final s in dlSongs) {
          songMap[s.key] = s;
        }
        for (final s in favSongs) {
          songMap.putIfAbsent(s.key, () => s);
        }
        final allSongs = songMap.values.toList();

        final matching = _db.playlists.where((p) => p.id == playlistId);
        if (matching.isEmpty) return const SizedBox.shrink();
        final targetPlaylist = matching.first;
        final existingKeys = targetPlaylist.songs.map((s) => s.key).toSet();
        final selectedKeys = <String>{};
        String searchKw = '';
        int filterMode = 0; // 0: 全部, 1: 仅已下载, 2: 仅收藏

        return StatefulBuilder(
          builder: (context, setPickerState) {
            final filteredBySource = allSongs.where((s) {
              if (filterMode == 1) return dlSongs.any((d) => d.key == s.key);
              if (filterMode == 2) return favSongs.any((f) => f.key == s.key);
              return true;
            }).toList();

            final displaySongs = filteredBySource.where((s) {
              if (searchKw.isEmpty) return true;
              return s.name.toLowerCase().contains(searchKw.toLowerCase()) ||
                  s.artist.toLowerCase().contains(searchKw.toLowerCase());
            }).toList();

            // 当前筛选下尚未加入合集的歌曲
            final availableSongs = displaySongs.where((s) => !existingKeys.contains(s.key)).toList();
            final allAvailableSelected = availableSongs.isNotEmpty &&
                availableSongs.every((s) => selectedKeys.contains(s.key));

            return SafeArea(
              child: Container(
                height: MediaQuery.of(context).size.height * 0.85,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '添加歌曲至【${targetPlaylist.name}】',
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: selectedKeys.isEmpty
                              ? null
                              : () async {
                                  final toAdd = allSongs.where((s) => selectedKeys.contains(s.key)).toList();
                                  final added = await _db.batchAddSongsToPlaylist(playlistId, toAdd);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('已添加 $added 首歌曲到【${targetPlaylist.name}】'),
                                        backgroundColor: const Color(0xFF059669),
                                      ),
                                    );
                                  }
                                },
                          child: Text(
                            selectedKeys.isEmpty ? '加入' : '加入(${selectedKeys.length})',
                            style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // 筛选标签栏与全选按钮
                    Row(
                      children: [
                        _buildFilterChip('全部(${allSongs.length})', 0, filterMode, (v) => setPickerState(() => filterMode = v)),
                        const SizedBox(width: 6),
                        _buildFilterChip('已下载(${dlSongs.length})', 1, filterMode, (v) => setPickerState(() => filterMode = v)),
                        const SizedBox(width: 6),
                        _buildFilterChip('收藏(${favSongs.length})', 2, filterMode, (v) => setPickerState(() => filterMode = v)),
                        const Spacer(),
                        if (availableSongs.isNotEmpty)
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              foregroundColor: const Color(0xFF818CF8),
                            ),
                            onPressed: () {
                              setPickerState(() {
                                if (allAvailableSelected) {
                                  for (final s in availableSongs) {
                                    selectedKeys.remove(s.key);
                                  }
                                } else {
                                  for (final s in availableSongs) {
                                    selectedKeys.add(s.key);
                                  }
                                }
                              });
                            },
                            child: Text(allAvailableSelected ? '取消全选' : '全选', style: const TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // 搜索框
                    TextField(
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '搜索歌曲或歌手...',
                        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12.5),
                        prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 18),
                        filled: true,
                        fillColor: const Color(0xFF1A2333),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                      onChanged: (val) {
                        setPickerState(() => searchKw = val.trim());
                      },
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: displaySongs.isEmpty
                          ? const Center(
                              child: Text('没有找到可添加的歌曲', style: TextStyle(color: Colors.white38)),
                            )
                          : ListView.builder(
                              itemCount: displaySongs.length,
                              itemBuilder: (context, i) {
                                final song = displaySongs[i];
                                final alreadyIn = existingKeys.contains(song.key);
                                final isSelected = selectedKeys.contains(song.key);
                                final isDownloaded = dlSongs.any((d) => d.key == song.key);
                                final isFavorite = favSongs.any((f) => f.key == song.key);

                                return CheckboxListTile(
                                  value: alreadyIn ? true : isSelected,
                                  activeColor: alreadyIn ? Colors.white24 : const Color(0xFF6366F1),
                                  checkColor: alreadyIn ? Colors.white38 : Colors.white,
                                  onChanged: alreadyIn
                                      ? null
                                      : (bool? checked) {
                                          setPickerState(() {
                                            if (checked == true) {
                                              selectedKeys.add(song.key);
                                            } else {
                                              selectedKeys.remove(song.key);
                                            }
                                          });
                                        },
                                  title: Text(
                                    song.name,
                                    style: TextStyle(
                                      color: alreadyIn ? Colors.white38 : Colors.white,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Row(
                                    children: [
                                      if (isDownloaded)
                                        Container(
                                          margin: const EdgeInsets.only(right: 5),
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: const Text('已下载', style: TextStyle(color: Color(0xFF34D399), fontSize: 9.5)),
                                        ),
                                      if (isFavorite)
                                        Container(
                                          margin: const EdgeInsets.only(right: 5),
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.redAccent.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: const Text('收藏', style: TextStyle(color: Colors.redAccent, fontSize: 9.5)),
                                        ),
                                      Expanded(
                                        child: Text(
                                          alreadyIn ? '${song.artist} · 已在合集中' : '${song.artist} · ${song.quality}',
                                          style: TextStyle(color: alreadyIn ? Colors.white24 : Colors.white54, fontSize: 11),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  secondary: ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      width: 38,
                                      height: 38,
                                      color: const Color(0xFF1E293B),
                                      child: song.coverUrl.isNotEmpty
                                          ? Image.network(
                                              song.coverUrl,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) => const Icon(Icons.music_note, color: Colors.white38),
                                            )
                                          : const Icon(Icons.music_note, color: Colors.white38),
                                    ),
                                  ),
                                );
                              },
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

  Widget _buildFilterChip(String label, int value, int current, ValueChanged<int> onSelect) {
    final isSelected = value == current;
    return GestureDetector(
      onTap: () => onSelect(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1).withValues(alpha: 0.25) : const Color(0xFF1A2333),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? const Color(0xFF818CF8) : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  void _showImportPlaylistDialog() {
    final textController = TextEditingController();
    bool isImporting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: const [
                Icon(Icons.download_for_offline_rounded, color: Color(0xFF10B981), size: 22),
                SizedBox(width: 8),
                Text('导入外部歌单', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '支持网易云音乐或 QQ 音乐歌单分享链接、分享文本或歌单纯数字/字符 ID：',
                  style: TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: textController,
                  enabled: !isImporting,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: '例如: https://music.163.com/playlist?id=3778678 或分享文本',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 11.5),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF10B981)),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF10B981), size: 18),
                      tooltip: '粘贴剪贴板',
                      onPressed: isImporting
                          ? null
                          : () async {
                              final data = await Clipboard.getData(Clipboard.kTextPlain);
                              if (data?.text != null) {
                                textController.text = data!.text!;
                              }
                            },
                    ),
                  ),
                ),
                if (isImporting) ...[
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)),
                      ),
                      SizedBox(width: 10),
                      Text('正在解析提取外部歌单曲目...', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isImporting ? null : () => Navigator.pop(ctx),
                child: const Text('取消', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: isImporting
                    ? null
                    : () async {
                        final input = textController.text.trim();
                        final messenger = ScaffoldMessenger.of(context);
                        if (input.isEmpty) {
                          messenger.showSnackBar(
                            const SnackBar(content: Text('请输入或粘贴歌单链接/ID')),
                          );
                          return;
                        }

                        setDialogState(() => isImporting = true);

                        try {
                          final result = await MusicApi.importExternalPlaylist(input);
                          if (ctx.mounted) Navigator.pop(ctx);

                          if (result != null) {
                            final name = (result['title'] ?? result['name'] ?? '导入歌单').toString();
                            final songs = (result['songs'] as List?)?.whereType<Song>().toList() ?? <Song>[];

                            final pl = await _db.createPlaylist(name);
                            for (final s in songs) {
                              await _db.addSongToPlaylist(pl.id, s);
                            }

                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('成功导入歌单《$name》(共 ${songs.length} 首歌曲)'),
                                backgroundColor: const Color(0xFF059669),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          } else {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('未能解析出歌单歌曲，请确认链接或ID有效且为公开歌单'),
                                backgroundColor: Colors.redAccent,
                                duration: Duration(seconds: 3),
                              ),
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('导入失败: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      },
                child: const Text('一键导入', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showRenamePlaylistDialog(CustomPlaylist pl) {
    final textController = TextEditingController(text: pl.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('重命名歌单', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '请输入新的歌单名称',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            child: const Text('确认', style: TextStyle(color: Color(0xFF818CF8))),
            onPressed: () async {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                await _db.renamePlaylist(pl.id, name);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已重命名为: $name')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  void _confirmDeletePlaylist(CustomPlaylist pl) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('删除歌单', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '确定删除歌单“${pl.name}”吗？歌单内的歌曲不会被从手机存储中删除。',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('删除', style: TextStyle(color: Colors.white)),
            onPressed: () async {
              await _db.deletePlaylist(pl.id);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已删除歌单: ${pl.name}')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

/* ================= 我的歌单吸顶 Header 代理 ================= */
class _LibraryStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  _LibraryStickyHeaderDelegate({
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
      alignment: Alignment.center,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _LibraryStickyHeaderDelegate oldDelegate) {
    return true;
  }
}

