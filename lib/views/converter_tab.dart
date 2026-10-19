import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../models/song.dart';
import '../services/audio_converter_service.dart';
import '../services/database_service.dart';
import '../services/player_service.dart';

class ConverterTab extends StatefulWidget {
  const ConverterTab({super.key});

  @override
  State<ConverterTab> createState() => _ConverterTabState();
}

class _ConverterTabState extends State<ConverterTab> {
  final AudioConverterService _converter = AudioConverterService();
  final DatabaseService _db = DatabaseService();
  final PlayerService _player = PlayerService();

  Song? _selectedSong;
  String _targetFormat = 'mp3';
  String _targetBitrate = '320k';
  int _sampleRate = 44100;
  bool _isConverting = false;
  bool _saveToLibrary = true;
  bool _exportToPublic = true;

  final List<String> _formats = ['mp3', 'wav', 'flac', 'aac', 'm4a'];
  final List<String> _bitrates = ['320k', '256k', '192k', '128k', '64k'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0D14),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF06B6D4).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.transform_rounded, color: Color(0xFF22D3EE), size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              '音频格式转换工作台',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 提示横幅
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF06B6D4).withValues(alpha: 0.15),
                    const Color(0xFF6366F1).withValues(alpha: 0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF06B6D4).withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFF22D3EE), size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '纯本地音频重编码与格式重容器化，转换后自动存入手机媒体库，车载与各类便携设备即开即听。',
                      style: TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // 1. 选择待转换源文件
            const Text('1. 选择源音频文件', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF131A29),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _selectedSong != null
                              ? '${_selectedSong!.name} (${_selectedSong!.quality})'
                              : '请选择待转换音频（支持手机外部文件与本地曲库）',
                          style: TextStyle(
                            color: _selectedSong != null ? Colors.white : Colors.white38,
                            fontSize: 13,
                            fontWeight: _selectedSong != null ? FontWeight.w600 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 外部导入
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF34D399),
                          side: const BorderSide(color: Color(0x6610B981)),
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.file_open_rounded, size: 14),
                        label: const Text('外部导入', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                        onPressed: _pickExternalFile,
                      ),
                      const SizedBox(width: 6),
                      // 本地曲库
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: const Color(0xFF818CF8),
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.playlist_add_check_rounded, size: 14),
                        label: const Text('曲库选择', style: TextStyle(fontSize: 11.5)),
                        onPressed: _showSongPicker,
                      ),
                    ],
                  ),
                  if (_selectedSong?.localFilePath != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A0D14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: (_selectedSong!.source == '外部导入' ? const Color(0xFF10B981) : const Color(0xFF6366F1))
                                  .withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              _selectedSong!.source == '外部导入' ? '外部文件' : '软件曲库',
                              style: TextStyle(
                                color: _selectedSong!.source == '外部导入' ? const Color(0xFF34D399) : const Color(0xFF818CF8),
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _selectedSong!.localFilePath!,
                              style: const TextStyle(color: Colors.white38, fontSize: 10, fontFamily: 'monospace'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // 2. 目标格式选择
            const Text('2. 目标输出格式', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _formats.map((fmt) {
                final isSelected = _targetFormat == fmt;
                return ChoiceChip(
                  label: Text(fmt.toUpperCase(), style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                  selected: isSelected,
                  selectedColor: const Color(0xFF6366F1),
                  backgroundColor: const Color(0xFF131A29),
                  onSelected: (v) {
                    if (v) setState(() => _targetFormat = fmt);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // 3. 码率选择
            const Text('3. 编码比特率', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _bitrates.map((br) {
                final isSelected = _targetBitrate == br;
                return ChoiceChip(
                  label: Text(br, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 12)),
                  selected: isSelected,
                  selectedColor: const Color(0xFF06B6D4),
                  backgroundColor: const Color(0xFF131A29),
                  onSelected: (v) {
                    if (v) setState(() => _targetBitrate = br);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 20),

            // 4. 采样率
            const Text('4. 声学采样率', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildSampleRateChip(44100, '44.1 kHz (标准CD)'),
                const SizedBox(width: 8),
                _buildSampleRateChip(48000, '48.0 kHz (高保真影音)'),
              ],
            ),
            const SizedBox(height: 20),

            // 5. 产物留存与导出设定
            const Text('5. 产物留存与导出设定', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF131A29),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Material(
                color: Colors.transparent,
                child: Column(
                  children: [
                    CheckboxListTile(
                      value: _saveToLibrary,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: const Color(0xFF6366F1),
                      title: const Text('留在本软件内 (加入已下载曲库)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: const Text('可在“我的歌单-全部歌曲”中管理与播放，支持加入专属合集', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      onChanged: (v) => setState(() => _saveToLibrary = v ?? true),
                    ),
                    const Divider(color: Colors.white10, height: 1),
                    CheckboxListTile(
                      value: _exportToPublic,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeColor: const Color(0xFF10B981),
                      title: const Text('导出到手机公共存储 (/Music/DMusic)', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: const Text('自动备份至公共 Music 目录，车载音响与第三方播放器即插即用', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      onChanged: (v) => setState(() => _exportToPublic = v ?? false),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // 6. 立即转换按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 6,
                ),
                icon: _isConverting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.flash_on_rounded, color: Colors.white),
                label: Text(
                  _isConverting ? '正在重编码转码中...' : '开始转换格式',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
                onPressed: _isConverting ? null : _startConvert,
              ),
            ),
            const SizedBox(height: 28),

            // 6. 转换历史与任务成果
            const Text('转换任务与成果记录', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            StreamBuilder<List<ConversionTask>>(
              stream: _converter.tasksStream,
              initialData: _converter.tasks,
              builder: (context, snapshot) {
                final tasks = snapshot.data ?? [];
                if (tasks.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(20),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF131A29).withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('暂无转换记录，点击上方按钮即可开始转换', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  );
                }

                return Column(
                  children: tasks.map((t) => _buildConversionTaskCard(t)).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSampleRateChip(int rate, String label) {
    final isSelected = _sampleRate == rate;
    return ChoiceChip(
      label: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 11.5)),
      selected: isSelected,
      selectedColor: const Color(0xFF8B5CF6),
      backgroundColor: const Color(0xFF131A29),
      onSelected: (v) {
        if (v) setState(() => _sampleRate = rate);
      },
    );
  }

  Widget _buildConversionTaskCard(ConversionTask task) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '${task.title} ➔ ${task.targetFormat.toUpperCase()} (${task.targetBitrate})',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: task.status == '已完成'
                      ? const Color(0x3310B981)
                      : const Color(0x336366F1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  task.status,
                  style: TextStyle(
                    color: task.status == '已完成' ? const Color(0xFF34D399) : const Color(0xFF818CF8),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (task.status != '已完成') ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: task.progress,
              backgroundColor: const Color(0xFF1E293B),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF06B6D4)),
            ),
          ],
          if (task.outputPath != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '体积: ${(task.outputSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
                    '${task.isSavedToLibrary ? " · 已存入曲库" : " · 未存入曲库"}'
                    '${task.exportedPublicPath != null ? " · 已导出外部" : ""}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                // 试听播放
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF22D3EE),
                    side: const BorderSide(color: Color(0x6622D3EE)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.play_circle_fill, size: 14),
                  label: const Text('试听播放', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    final path = task.outputPath;
                    if (path == null || path.isEmpty || !File(path).existsSync()) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('转换文件不存在或已被移动')),
                      );
                      return;
                    }
                    final s = Song(
                      id: 'play_conv_${path.hashCode}',
                      name: '${task.title} [${task.targetFormat.toUpperCase()}]',
                      artist: task.artist.isEmpty ? '本地转换' : task.artist,
                      album: '本地转换',
                      source: '本地转换',
                      localFilePath: path,
                    );
                    _player.playSong(s);
                  },
                ),
                // 补存入曲库 (若尚未加入)
                if (!task.isSavedToLibrary)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF818CF8),
                      side: const BorderSide(color: Color(0x66818CF8)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 30),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.bookmark_add_rounded, size: 14),
                    label: const Text('存入曲库', style: TextStyle(fontSize: 11.5)),
                    onPressed: () async {
                      await _converter.saveTaskToAppLibrary(task);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已将【${task.title}】存入已下载曲库')),
                        );
                      }
                    },
                  ),
                // 导出到外部公共存储
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF10B981),
                    side: const BorderSide(color: Color(0x6610B981)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.drive_file_move_rounded, size: 14),
                  label: Text(task.exportedPublicPath != null ? '已导出外部' : '导出外部', style: const TextStyle(fontSize: 11.5)),
                  onPressed: () async {
                    final dest = await _converter.exportTaskToPublic(task);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(dest != null ? '已成功导出至: $dest' : '导出失败，请检查公共目录权限')),
                      );
                    }
                  },
                ),
                // 分享到其他应用
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(0, 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.share_rounded, size: 14),
                  label: const Text('分享外部', style: TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    final path = task.outputPath;
                    if (path != null && File(path).existsSync()) {
                      SharePlus.instance.share(ShareParams(
                        files: [XFile(path)],
                        text: '分享音频文件: ${task.title}.${task.targetFormat}',
                      ));
                    }
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _showSongPicker() {
    final list = _db.downloads;
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载库中暂无歌曲，请先在搜索发现中下载一首歌曲')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161E2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        String filterTag = '全部';
        return StatefulBuilder(
          builder: (context, setModalState) {
            var displayList = list;
            if (filterTag == '仅看FLAC无损') {
              displayList = list.where((s) => s.isLossless || s.quality.toLowerCase().contains('flac') || (s.localFilePath != null && s.localFilePath!.toLowerCase().endsWith('.flac'))).toList();
            } else if (filterTag == '仅看大文件 (>15MB)') {
              displayList = list.where((s) => s.estimatedSizeMB > 15).toList();
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.65,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('选择需要转换的音频文件', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('共 ${displayList.length} 首', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 快速筛选标签
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ...['全部', '仅看FLAC无损', '仅看大文件 (>15MB)'].map((tag) {
                          final active = filterTag == tag;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(tag, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 11)),
                              selected: active,
                              selectedColor: const Color(0xFF6366F1),
                              backgroundColor: const Color(0xFF111827),
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              onSelected: (_) => setModalState(() => filterTag = tag),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: displayList.isEmpty
                        ? Center(
                            child: Text('没有符合【$filterTag】的已下载音频', style: const TextStyle(color: Colors.white38, fontSize: 13)),
                          )
                        : ListView.builder(
                            itemCount: displayList.length,
                            itemBuilder: (c, i) {
                              final s = displayList[i];
                              return ListTile(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                leading: const Icon(Icons.audio_file_rounded, color: Color(0xFF6366F1)),
                                title: Text(s.name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                subtitle: Text('${s.artist} · ${s.quality} · ${s.estimatedSizeStr}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                onTap: () {
                                  setState(() => _selectedSong = s);
                                  Navigator.pop(ctx);
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
    );
  }

  Future<void> _pickExternalFile() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'ape', 'wma'],
      );

      if (picked == null || picked.path == null) {
        return;
      }

      final file = File(picked.path!);
      final fileName = picked.name;
      final fileLength = await file.length();

      // 解析文件名作为歌名和歌手 (例如 "歌手 - 歌名.mp3" 或 "歌名.flac")
      String title = fileName;
      String artist = '外部导入';

      final dotIndex = fileName.lastIndexOf('.');
      final baseName = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
      final ext = dotIndex > 0 ? fileName.substring(dotIndex + 1).toUpperCase() : 'AUDIO';

      if (baseName.contains(' - ')) {
        final parts = baseName.split(' - ');
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      } else {
        title = baseName.trim();
      }

      final externalSong = Song(
        id: 'ext_${DateTime.now().millisecondsSinceEpoch}',
        name: title,
        artist: artist,
        album: '外部文件导入',
        source: '外部导入',
        quality: ext,
        durationSeconds: 0,
        localFilePath: file.path,
        fileSizeBytes: fileLength,
      );

      setState(() {
        _selectedSong = externalSong;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功导入外部音频：$title ($ext)'),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('挑选外部文件失败: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _startConvert() async {
    if (_selectedSong == null || _selectedSong!.localFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择待转换的歌曲（支持外部导入或软件曲库）'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final srcFile = File(_selectedSong!.localFilePath!);
    final fileExists = await srcFile.exists();
    if (!mounted) return;
    if (!fileExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('源音频文件不存在或已移除'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isConverting = true);

    try {
      final task = await _converter.convertAudio(
        sourceFile: srcFile,
        title: _selectedSong!.name,
        artist: _selectedSong!.artist,
        targetFormat: _targetFormat,
        targetBitrate: _targetBitrate,
        sampleRate: _sampleRate,
        saveToLibrary: _saveToLibrary,
        exportToPublic: _exportToPublic,
      );

      if (mounted) {
        setState(() => _isConverting = false);
        final List<String> notices = [];
        if (_saveToLibrary) notices.add('已存入软件曲库');
        if (_exportToPublic && task.exportedPublicPath != null) {
          notices.add('已导出到公共存储');
        }
        final msg = notices.isNotEmpty
            ? '转换成功！${notices.join('，')}'
            : '转换完成！已在临时目录生成 ${_targetFormat.toUpperCase()}';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConverting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('转换失败: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
