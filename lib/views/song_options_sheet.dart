import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../models/song.dart';
import '../services/database_service.dart';
import '../services/player_service.dart';
import '../services/music_api.dart';
import 'download_sheet.dart';
import 'playlist_dialogs.dart';

/// 现代化高颜值歌曲详情与更多操作弹窗
class SongOptionsSheet {
  /// 唤起歌曲操作面板
  static void show(
    BuildContext context,
    Song song, {
    VoidCallback? onTapPlay,
    List<Song>? playlistContext,
    int? playlistIndex,
  }) {
    final match = DatabaseService().checkDownloadStatus(song);

    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 顶部圆角拉手
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

              // 2. 歌曲详情卡片 (封面 + 歌名/歌手/专辑 + 标签)
              _buildHeaderCard(context, song),

              const SizedBox(height: 18),

              // 3. 高频操作快捷动作栏 (立即播放 / 下一首 / 下载 / 收藏)
              _buildQuickActions(ctx, song, match, onTapPlay, playlistContext, playlistIndex),

              const SizedBox(height: 18),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 6),

              // 4. 次级操作列表 (整洁统一单行)
              _buildSecondaryActions(ctx, song),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  /// 头部歌曲元数据卡片
  static Widget _buildHeaderCard(BuildContext context, Song song) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 专辑封面 (56x56 圆角)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: song.coverUrl.isNotEmpty
                ? Image.network(
                    song.coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Icon(Icons.music_note_rounded, color: Colors.white38, size: 28),
                  )
                : const Icon(Icons.music_note_rounded, color: Colors.white38, size: 28),
          ),
        ),
        const SizedBox(width: 14),
        // 文本信息与元数据徽章
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 歌名
              Text(
                song.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              // 歌手 · 所属专辑
              Text(
                song.album.isNotEmpty ? '${song.artist} · 《${song.album}》' : song.artist,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              // 标签胶囊行
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _buildSourceBadge(song.source),
                  _buildQualityBadge(song.quality, song.estimatedSizeStr),
                  if (song.durationSeconds > 0)
                    _buildDurationBadge(song.durationSeconds),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 平台徽章
  static Widget _buildSourceBadge(String source) {
    Color bg;
    Color border;
    Color text;
    if (source.contains('网易云')) {
      bg = const Color(0x22EF4444);
      border = const Color(0x55EF4444);
      text = const Color(0xFFF87171);
    } else if (source.contains('QQ')) {
      bg = const Color(0x2210B981);
      border = const Color(0x5510B981);
      text = const Color(0xFF34D399);
    } else if (source.contains('酷狗')) {
      bg = const Color(0x2238BDF8);
      border = const Color(0x5538BDF8);
      text = const Color(0xFF38BDF8);
    } else if (source.contains('咪咕')) {
      bg = const Color(0x22F59E0B);
      border = const Color(0x55F59E0B);
      text = const Color(0xFFFBBF24);
    } else if (source.contains('酷我')) {
      bg = const Color(0x22F43F5E);
      border = const Color(0x55F43F5E);
      text = const Color(0xFFFB7185);
    } else if (source.contains('哔哩') || source.contains('B站')) {
      bg = const Color(0x22EC4899);
      border = const Color(0x55EC4899);
      text = const Color(0xFFF472B6);
    } else {
      bg = const Color(0x228B5CF6);
      border = const Color(0x558B5CF6);
      text = const Color(0xFFA78BFA);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Text(
        source,
        style: TextStyle(color: text, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// 音质与文件大小徽章
  static Widget _buildQualityBadge(String quality, String sizeStr) {
    final isLossless = quality.toLowerCase().contains('flac') ||
        quality.contains('无损') ||
        quality.toLowerCase().contains('hi-res');
    final bg = isLossless ? const Color(0x20F59E0B) : const Color(0x1806B6D4);
    final border = isLossless ? const Color(0x44F59E0B) : const Color(0x3306B6D4);
    final text = isLossless ? const Color(0xFFFBBF24) : const Color(0xFF22D3EE);

    final label = sizeStr.isNotEmpty && sizeStr != '未知大小'
        ? '$quality · $sizeStr'
        : quality;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLossless) ...[
            Icon(Icons.stars_rounded, size: 11, color: text),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(color: text, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// 歌曲时长徽章
  static Widget _buildDurationBadge(int durationSeconds) {
    final m = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (durationSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white12, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.access_time_rounded, size: 10, color: Colors.white60),
          const SizedBox(width: 3),
          Text(
            '$m:$s',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }

  /// 高频核心快捷动作栏
  static Widget _buildQuickActions(
    BuildContext ctx,
    Song song,
    DownloadMatchResult match,
    VoidCallback? onTapPlay,
    List<Song>? playlistContext,
    int? playlistIndex,
  ) {
    return Row(
      children: [
        // 1. 立即播放
        Expanded(
          child: _buildActionButton(
            icon: Icons.play_arrow_rounded,
            iconColor: const Color(0xFF818CF8),
            bgColor: const Color(0x226366F1),
            borderColor: const Color(0x446366F1),
            label: '立即播放',
            onTap: () {
              Navigator.pop(ctx);
              if (playlistContext != null && playlistIndex != null) {
                PlayerService().setPlaylist(playlistContext, startIndex: playlistIndex);
              } else if (onTapPlay != null) {
                onTapPlay();
              } else {
                PlayerService().playSong(song);
              }
            },
          ),
        ),
        const SizedBox(width: 10),

        // 2. 下一首播放
        Expanded(
          child: _buildActionButton(
            icon: Icons.playlist_play_rounded,
            iconColor: Colors.white70,
            label: '下一首',
            onTap: () {
              Navigator.pop(ctx);
              PlayerService().insertNext(song);
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('已加入下一首播放: ${song.name}')),
              );
            },
          ),
        ),
        const SizedBox(width: 10),

        // 3. 下载歌曲
        Expanded(
          child: _buildActionButton(
            icon: match.canUpgrade
                ? Icons.upgrade_rounded
                : (match.isExact ? Icons.check_circle_rounded : Icons.download_rounded),
            iconColor: match.canUpgrade
                ? const Color(0xFF38BDF8)
                : (match.isExact ? const Color(0xFF10B981) : Colors.white70),
            label: match.canUpgrade ? '升级' : (match.isExact ? '已下载' : '下载'),
            onTap: () {
              Navigator.pop(ctx);
              DownloadSheet.show(ctx, song, matchResult: match);
            },
          ),
        ),
        const SizedBox(width: 10),

        // 4. 收藏歌曲
        Expanded(
          child: StreamBuilder<List<Song>>(
            stream: DatabaseService().favoritesStream,
            builder: (context, favSnap) {
              final isFav = DatabaseService().isFavorite(song);
              return _buildActionButton(
                icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                iconColor: isFav ? const Color(0xFFEF4444) : Colors.white70,
                label: isFav ? '已收藏' : '收藏',
                onTap: () async {
                  final newFav = await DatabaseService().toggleFavorite(song);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(newFav ? '已加入我的收藏' : '已移出我的收藏')),
                    );
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// 快捷动作胶囊按钮
  static Widget _buildActionButton({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    Color? bgColor,
    Color? borderColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bgColor ?? Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor ?? Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// 次级操作单行列表
  static Widget _buildSecondaryActions(BuildContext ctx, Song song) {
    return Column(
      children: [
        // 加入歌单合集
        _buildActionTile(
          icon: Icons.playlist_add_rounded,
          iconColor: const Color(0xFF10B981),
          title: '加入歌单合集',
          onTap: () {
            Navigator.pop(ctx);
            PlaylistDialogs.showAddToPlaylistSheet(ctx, song);
          },
        ),
        // 全网换源 / 寻找其他音源版本
        _buildActionTile(
          icon: Icons.swap_horiz_rounded,
          iconColor: const Color(0xFF818CF8),
          title: '全网其他音源版本 (换源)',
          onTap: () {
            Navigator.pop(ctx);
            _showAlternativeSourcesSheet(ctx, song);
          },
        ),
        // 分享歌曲
        _buildActionTile(
          icon: Icons.share_rounded,
          iconColor: Colors.white70,
          title: '分享歌曲',
          onTap: () {
            Navigator.pop(ctx);
            if (song.isDownloaded && song.localFilePath != null && File(song.localFilePath!).existsSync()) {
              SharePlus.instance.share(ShareParams(
                files: [XFile(song.localFilePath!)],
                text: '分享音乐: ${song.name} - ${song.artist}',
              ));
            } else {
              SharePlus.instance.share(ShareParams(
                text: '分享音乐: 《${song.name}》 - ${song.artist} [${song.source} / ${song.quality}]\n来自 DMusic 音乐客户端',
              ));
            }
          },
        ),
      ],
    );
  }

  /// 单行列表项
  static Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 21),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 18),
          ],
        ),
      ),
    );
  }

  /// 全网其他音源版本候选弹窗
  static void _showAlternativeSourcesSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
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
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.swap_horiz_rounded, color: Color(0xFF818CF8), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '全网候选版本: 《${song.name}》',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<Song>>(
                  future: MusicApi.searchAlternatives(song),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SizedBox(
                        height: 140,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF818CF8)),
                        ),
                      );
                    }
                    final list = snapshot.data ?? [];
                    if (list.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: Text('全网其他平台暂未检索到更多同名版本', style: TextStyle(color: Colors.white38, fontSize: 13)),
                        ),
                      );
                    }
                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: list.length,
                        separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (context, i) {
                          final alt = list[i];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            leading: _buildSourceBadge(alt.source),
                            title: Text(
                              alt.name,
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${alt.artist} · ${alt.quality}',
                              style: const TextStyle(color: Colors.white54, fontSize: 11),
                              maxLines: 1,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF6366F1), size: 24),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    PlayerService().playSong(alt);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.download_rounded, color: Color(0xFF10B981), size: 22),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    DownloadSheet.show(context, alt);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
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
}
