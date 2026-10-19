import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';

class PlaylistDialogs {
  /// 单曲管理所属合集（复选框勾选，支持加入多个或移出，也可新建合集）
  static void showAddToPlaylistSheet(BuildContext context, Song song) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131A29),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final db = DatabaseService();
        return SafeArea(
          child: StreamBuilder<List<CustomPlaylist>>(
            stream: db.playlistsStream,
            initialData: db.playlists,
            builder: (context, snapshot) {
              final lists = snapshot.data ?? db.playlists;
              final containingPlIds = db.getPlaylistsContainingSong(song.key).map((p) => p.id).toSet();

              return StatefulBuilder(
                builder: (context, setSheetState) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
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
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '加入 / 管理所属合集',
                                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '《${song.name}》 - ${song.artist}',
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(foregroundColor: const Color(0xFF818CF8)),
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('新建合集'),
                              onPressed: () {
                                showCreatePlaylistDialog(context, initialSong: song);
                              },
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white12, height: 20),
                        if (lists.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(Icons.folder_open_rounded, size: 40, color: Colors.white24),
                                  SizedBox(height: 8),
                                  Text('暂无歌单合集，点击右上角新建', style: TextStyle(color: Colors.white38, fontSize: 13)),
                                ],
                              ),
                            ),
                          )
                        else
                          Flexible(
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: lists.length,
                              separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                              itemBuilder: (context, i) {
                                final pl = lists[i];
                                final isSelected = containingPlIds.contains(pl.id);

                                return CheckboxListTile(
                                  value: isSelected,
                                  activeColor: const Color(0xFF6366F1),
                                  title: Text(pl.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                                  subtitle: Text('${pl.songs.length} 首歌曲', style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
                                  secondary: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: isSelected ? const Color(0x336366F1) : const Color(0xFF1E293B),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(
                                      Icons.library_music_rounded,
                                      color: isSelected ? const Color(0xFF818CF8) : Colors.white54,
                                      size: 18,
                                    ),
                                  ),
                                  onChanged: (bool? checked) async {
                                    if (checked == true) {
                                      containingPlIds.add(pl.id);
                                    } else {
                                      containingPlIds.remove(pl.id);
                                    }
                                    setSheetState(() {});
                                    await db.updateSongPlaylists(song, containingPlIds.toList());
                                  },
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
    );
  }

  /// 批量加入合集弹窗
  static void showBatchAddToPlaylistDialog(BuildContext context, List<Song> songs, {VoidCallback? onComplete}) {
    if (songs.isEmpty) return;
    final db = DatabaseService();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('批量加入合集 (${songs.length}首)', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: StreamBuilder<List<CustomPlaylist>>(
            stream: db.playlistsStream,
            initialData: db.playlists,
            builder: (context, snapshot) {
              final lists = snapshot.data ?? db.playlists;
              if (lists.isEmpty) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    const Text('暂无歌单合集，请先创建', style: TextStyle(color: Colors.white38, fontSize: 13)),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('新建合集'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        showCreatePlaylistDialog(context, initialSongs: songs, onComplete: onComplete);
                      },
                    ),
                  ],
                );
              }

              return ListView.separated(
                shrinkWrap: true,
                itemCount: lists.length,
                separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                itemBuilder: (context, i) {
                  final pl = lists[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: const Icon(Icons.queue_music_rounded, color: Color(0xFF818CF8)),
                    title: Text(pl.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: Text('${pl.songs.length} 首歌曲', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white24, size: 14),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final added = await db.batchAddSongsToPlaylist(pl.id, songs);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已将选中的歌曲添加至【${pl.name}】(新增 $added 首)'),
                            backgroundColor: const Color(0xFF059669),
                          ),
                        );
                      }
                      onComplete?.call();
                    },
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            child: const Text('新建合集', style: TextStyle(color: Color(0xFF818CF8))),
            onPressed: () {
              Navigator.pop(ctx);
              showCreatePlaylistDialog(context, initialSongs: songs, onComplete: onComplete);
            },
          ),
          TextButton(
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  /// 新建合集弹窗
  static void showCreatePlaylistDialog(BuildContext context, {Song? initialSong, List<Song>? initialSongs, VoidCallback? onComplete}) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('新建歌单合集', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '例如：车载DJ、通勤慢摇、学习白噪音',
            hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
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
                final db = DatabaseService();
                final pl = await db.createPlaylist(name);
                if (initialSong != null) {
                  await db.addSongToPlaylist(pl.id, initialSong);
                } else if (initialSongs != null && initialSongs.isNotEmpty) {
                  await db.batchAddSongsToPlaylist(pl.id, initialSongs);
                }
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已创建合集【$name】${(initialSong != null || (initialSongs != null && initialSongs.isNotEmpty)) ? ' 并已加入歌曲' : ''}'),
                      backgroundColor: const Color(0xFF059669),
                    ),
                  );
                }
                onComplete?.call();
              }
            },
          ),
        ],
      ),
    );
  }
}
