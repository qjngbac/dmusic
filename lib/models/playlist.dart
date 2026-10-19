import 'song.dart';

class CustomPlaylist {
  final String id;
  String name;
  final DateTime createTime;
  final List<Song> songs;

  CustomPlaylist({
    required this.id,
    required this.name,
    required this.createTime,
    required this.songs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createTime': createTime.toIso8601String(),
    'songs': songs.map((s) => s.toJson()).toList(),
  };

  factory CustomPlaylist.fromJson(Map<String, dynamic> json) => CustomPlaylist(
    id: json['id'] ?? '',
    name: json['name'] ?? '新建歌单',
    createTime: DateTime.tryParse(json['createTime'] ?? '') ?? DateTime.now(),
    songs: (json['songs'] as List? ?? []).map((s) => Song.fromJson(s)).toList(),
  );
}
