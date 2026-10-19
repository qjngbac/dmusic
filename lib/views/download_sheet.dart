import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/database_service.dart';
import '../services/download_service.dart';
import '../services/player_service.dart';

/// 统一的歌曲下载与音质选择弹窗工具类
class DownloadSheet {
  /// 单曲下载流程：检测本地状态（防重/升级检测）并进入音质选择
  static void show(BuildContext context, Song song, {DownloadMatchResult? matchResult}) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    final match = matchResult ?? DatabaseService().checkDownloadStatus(song);

    // 0. 音质可升级：线上提供更高品质（如128k MP3 -> FLAC无损），醒目提示升级替换
    if (match.canUpgrade && match.matchedSong != null) {
      final downloaded = match.matchedSong!;
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF131A29),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const Icon(Icons.upgrade_rounded, color: Color(0xFF38BDF8), size: 44),
                const SizedBox(height: 10),
                const Text(
                  '检测到线上更高品质音质',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '《${song.name}》· ${song.artist}\n[本地已有: ${downloaded.quality}] ➔ [线上可升: ${song.quality}]',
                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF34D399),
                          side: const BorderSide(color: Color(0x6610B981)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        icon: const Icon(Icons.play_circle_fill_rounded, size: 18),
                        label: const Text('播放本地版', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          PlayerService().playSong(downloaded);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF38BDF8),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        icon: const Icon(Icons.upgrade_rounded, size: 18),
                        label: const Text('升级下载此版', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          proceedDownload(context, song);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ).whenComplete(() {
        FocusManager.instance.primaryFocus?.unfocus();
      });
      return;
    }

    // 1. 完全相同版本已在曲库：弹窗提示并提供快捷播放本地版 / 重新下载
    if (match.isExact && match.matchedSong != null) {
      final downloaded = match.matchedSong!;
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF131A29),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 44),
                const SizedBox(height: 10),
                const Text(
                  '本地曲库已存在此歌曲',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '《${downloaded.name}》· ${downloaded.artist}\n[已下载: ${downloaded.quality} / ${downloaded.estimatedSizeStr}]',
                  style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF34D399),
                          side: const BorderSide(color: Color(0x6610B981)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        icon: const Icon(Icons.play_circle_fill_rounded, size: 18),
                        label: const Text('播放本地版', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          PlayerService().playSong(downloaded);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: Colors.white70,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重新下载'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          proceedDownload(context, song);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ).whenComplete(() {
        FocusManager.instance.primaryFocus?.unfocus();
      });
      return;
    }

    proceedDownload(context, song, variantMatchedSong: match.isVariant ? match.matchedSong : null);
  }

  /// 弹出音质与格式选择（无损 FLAC / 320k 极高 MP3 / 128k 标准 MP3）
  static void proceedDownload(BuildContext context, Song song, {Song? variantMatchedSong}) {
    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
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
              if (variantMatchedSong != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline_rounded, color: Color(0xFF818CF8), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '💡 本地已有《${variantMatchedSong.name}》（${variantMatchedSong.quality}），当前为版本【${song.name}】，可继续下载。',
                          style: const TextStyle(color: Color(0xFFC7D2FE), fontSize: 11.5, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      song.coverUrl,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 44,
                        height: 44,
                        color: Colors.white12,
                        child: const Icon(Icons.music_note, color: Colors.white38),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${song.artist} · ${song.source}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '请选择下载音质与格式',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '可随时升级音质',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 10.5),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 选项列表：3档音质（FLAC无损、320k极高、128k标准）一目了然完整平铺，无需滑动，彻底去除右侧竖线与滚动条
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 选项 1: FLAC 无损品质 (高 60)
                  _buildQualityOption(
                    context: context,
                    ctx: ctx,
                    song: song,
                    icon: Icons.stars_rounded,
                    iconColor: const Color(0xFFF59E0B),
                    bgTintColor: const Color(0x15F59E0B),
                    borderColor: const Color(0x44F59E0B),
                    title: 'FLAC 无损母带音质',
                    tag: '.flac',
                    tagColor: const Color(0xFFF59E0B),
                    desc: '无压缩高保真 CD 音质 (~30MB)，纯净发烧级',
                    preferLossless: true,
                    targetQuality: 'flac',
                    snackText: '(.flac 无损母带)',
                  ),
                  const SizedBox(height: 10),
                  // 选项 2: 320k 极高 MP3 (高 60)
                  _buildQualityOption(
                    context: context,
                    ctx: ctx,
                    song: song,
                    icon: Icons.high_quality_rounded,
                    iconColor: const Color(0xFF06B6D4),
                    bgTintColor: Colors.white.withValues(alpha: 0.04),
                    borderColor: Colors.white12,
                    title: '320k 极高标准音质',
                    tag: '.mp3',
                    tagColor: const Color(0xFF06B6D4),
                    desc: '高兼容性 MP3 (~9MB)',
                    preferLossless: false,
                    targetQuality: '320k',
                    snackText: '(.mp3 320k 极高)',
                  ),
                  const SizedBox(height: 10),
                  // 选项 3: 128k 标准流畅音质 (高 60)
                  _buildQualityOption(
                    context: context,
                    ctx: ctx,
                    song: song,
                    icon: Icons.speed_rounded,
                    iconColor: const Color(0xFF34D399),
                    bgTintColor: const Color(0x1210B981),
                    borderColor: const Color(0x3310B981),
                    title: '128k 标准流畅音质',
                    tag: '.mp3',
                    tagColor: const Color(0xFF34D399),
                    desc: '极速轻量 MP3 (~3.5MB)，极小体积，下载超快',
                    preferLossless: false,
                    targetQuality: '128k',
                    snackText: '(.mp3 128k 标准)',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  /// 批量下载所选歌曲弹窗（提供无损与320k极高两种音质选择）
  static void showBatchDownload(
    BuildContext context,
    List<Song> songs, {
    String title = '批量下载',
  }) {
    if (songs.isEmpty) return;

    final downloads = DatabaseService().downloads;
    int existingCount = 0;
    for (final s in songs) {
      if (DatabaseService().checkDownloadStatus(s, downloads).isExact) {
        existingCount++;
      }
    }

    bool skipExisting = true;
    final total = songs.length;

    FocusScope.of(context).unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          final willDownloadCount = skipExisting ? (total - existingCount) : total;

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
                  Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 $total 首歌曲 · 本地曲库已拥有 $existingCount 首',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  // 智能跳过已存在复选框
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setModalState(() {
                        skipExisting = !skipExisting;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: skipExisting,
                              activeColor: const Color(0xFF6366F1),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              onChanged: (v) {
                                setModalState(() {
                                  skipExisting = v ?? true;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '自动跳过本地已下载的歌曲 ($existingCount 首)',
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 按钮 1: FLAC 无损下载
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.stars_rounded, size: 20),
                    label: Text(
                      '下载 FLAC 无损母带 ($willDownloadCount 首)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _executeBatchDownload(context, songs, preferLossless: true, skipExisting: skipExisting);
                    },
                  ),
                  const SizedBox(height: 10),
                  // 按钮 2: 320k 极高 MP3 下载
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(color: Color(0x6638BDF8)),
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.high_quality_rounded, size: 20),
                    label: Text(
                      '下载 320k 极高品质 MP3 ($willDownloadCount 首)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _executeBatchDownload(context, songs, preferLossless: false, targetQuality: '320k', skipExisting: skipExisting);
                    },
                  ),
                  const SizedBox(height: 10),
                  // 按钮 3: 128k 标准 MP3 下载
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF34D399),
                      side: const BorderSide(color: Color(0x6610B981)),
                      minimumSize: const Size(double.infinity, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.speed_rounded, size: 20),
                    label: Text(
                      '下载 128k 标准品质 MP3 ($willDownloadCount 首)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _executeBatchDownload(context, songs, preferLossless: false, targetQuality: '128k', skipExisting: skipExisting);
                    },
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

  static void _executeBatchDownload(
    BuildContext context,
    List<Song> songs, {
    required bool preferLossless,
    String targetQuality = '',
    required bool skipExisting,
  }) {
    int added = 0;
    int skipped = 0;
    final downloads = DatabaseService().downloads;
    for (final s in songs) {
      if (skipExisting) {
        final match = DatabaseService().checkDownloadStatus(s, downloads);
        if (match.isExact) {
          skipped++;
          continue;
        }
      }
      DownloadService().startDownload(s, preferLossless: preferLossless, targetQuality: targetQuality);
      added++;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skipped > 0
              ? '已添加 $added 首歌曲到后台下载队列 (已自动跳过 $skipped 首已在曲库歌曲)'
              : '已添加 $added 首歌曲到后台下载队列',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 单曲音质选择单项卡片（标准高度 60px，带图标、标题、标签与说明）
  static Widget _buildQualityOption({
    required BuildContext context,
    required BuildContext ctx,
    required Song song,
    required IconData icon,
    required Color iconColor,
    required Color bgTintColor,
    required Color borderColor,
    required String title,
    required String tag,
    required Color tagColor,
    required String desc,
    required bool preferLossless,
    required String targetQuality,
    required String snackText,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.pop(ctx);
        DownloadService().startDownload(
          song,
          preferLossless: preferLossless,
          targetQuality: targetQuality,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已加入下载: ${song.name} $snackText'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgTintColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tag,
                        style: TextStyle(
                          color: tagColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.download_rounded, color: iconColor, size: 20),
          ],
        ),
      ),
    );
  }
}
