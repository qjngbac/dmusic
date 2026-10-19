import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import 'audio_inspector.dart';

class MusicApi {
  static bool _hasCatalogTier(Map item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      if (value is Map && ['size', 'br', 'bitrate'].any((field) => (num.tryParse('${value[field]}') ?? 0) > 0)) return true;
    }
    return false;
  }

  static String _neteaseQuality(Map item) {
    if (_hasCatalogTier(item, ['hr', 'sq', 'sqMusic'])) return 'FLAC 无损';
    if (_hasCatalogTier(item, ['h', 'hMusic'])) return '320k 极高';
    if (_hasCatalogTier(item, ['m', 'mMusic'])) return '192k 较高';
    if (_hasCatalogTier(item, ['l', 'lMusic', 'bMusic'])) return '128k 标准';
    return '音质待检测';
  }

  static String _qqQuality(Map item) {
    final file = item['file'];
    final flac = num.tryParse('${item['sizeflac'] ?? (file is Map ? file['size_flac'] : null)}') ?? 0;
    final high = num.tryParse('${item['size320'] ?? (file is Map ? file['size_320mp3'] : null)}') ?? 0;
    final standard = num.tryParse('${item['size128'] ?? (file is Map ? file['size_128mp3'] : null)}') ?? 0;
    if (flac > 0) return 'FLAC 无损';
    if (high > 0) return '320k 极高';
    if (standard > 0) return '128k 标准';
    return '音质待检测';
  }
  static final Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
  };

  /// 过滤非音乐、垃圾音频或电台有声书
  static bool _isValidMusic(String name, String artist, int dur) {
    // 音乐一般在 45秒 到 900秒(15分钟) 之间
    if (dur > 900) return false;
    final lowerName = name.toLowerCase();
    final lowerArtist = artist.toLowerCase();
    final badWords = [
      '有声', '朗读', '评书', '朗诵', '白噪音', 'asmr', '小说',
      '第0', '第1', '第2', '第3', '第4', '第5', '第6', '第7', '第8', '第9',
      '广播剧', '早安问候', '晚安心语', '冥想', '助眠引导'
    ];
    for (final bad in badWords) {
      if (lowerName.contains(bad) || lowerArtist.contains(bad)) {
        return false;
      }
    }
    return true;
  }

  /// 并发全网多主流音乐平台聚合搜索 (网易云 + QQ音乐 + 酷狗 + 酷我 + 咪咕 + 哔哩哔哩 + 汽水音乐)
  static Future<List<Song>> searchAll(String keyword, {Set<String>? enabledSources}) async {
    final sources = enabledSources ?? {'网易云', 'QQ音乐', '酷狗音乐', '酷我音乐', '咪咕音乐', '哔哩哔哩', '汽水音乐'};
    final futures = <Future<List<Song>>>[];
    if (sources.contains('网易云')) futures.add(searchNetease(keyword));
    if (sources.contains('QQ音乐')) futures.add(searchQQ(keyword));
    if (sources.contains('酷狗音乐')) futures.add(searchKugou(keyword));
    if (sources.contains('酷我音乐')) futures.add(searchKuwo(keyword));
    if (sources.contains('咪咕音乐')) futures.add(searchMigu(keyword));
    if (sources.contains('哔哩哔哩')) futures.add(searchBilibili(keyword));
    if (sources.contains('汽水音乐')) futures.add(searchSoda(keyword));

    final results = await Future.wait(futures);
    final allSongs = <Song>[];
    for (final list in results) {
      allSongs.addAll(list);
    }
    // 优质正规音乐排前：时长正常(2~6分钟)、有无损或高码率的优先
    allSongs.sort((a, b) {
      if (a.isLossless && !b.isLossless) return -1;
      if (!a.isLossless && b.isLossless) return 1;
      return 0;
    });
    return allSongs;
  }

  /// 酷我音乐搜索 (精准提取 N_MINFO 多档音质与体积，严格过滤下架和版权受限试听截断项)
  static Future<List<Song>> searchKuwo(String keyword) async {
    try {
      final url = Uri.parse(
        'http://www.kuwo.cn/search/searchMusicBykeyWord?vipver=1&client=kt&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&mobi=1&issubtitle=1&show_copyright_off=0&pn=0&rn=25&all=${Uri.encodeComponent(keyword)}'
      );
      final resp = await http.get(url, headers: _headers).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = data['abslist'] as List? ?? [];
      final songs = <Song>[];
      for (final item in list) {
        final rid = (item['MUSICRID'] ?? item['musicrid'] ?? '').toString().replaceFirst('MUSIC_', '');
        if (rid.isEmpty) continue;

        // 过滤下架/无版权歌曲
        final online = (item['ONLINE'] ?? item['online'] ?? '1').toString();
        if (online == '0') continue;

        final payInfo = item['payInfo'] ?? {};

        final name = (item['SONGNAME'] ?? item['name'] ?? '未知歌曲').toString();
        final artist = (item['ARTIST'] ?? item['artist'] ?? '未知歌手').toString();
        final album = (item['ALBUM'] ?? item['album'] ?? '').toString();
        final dur = int.tryParse((item['DURATION'] ?? item['duration'] ?? 0).toString()) ?? 0;
        final pic = (item['hts_MVPIC'] ?? item['albumpic'] ?? item['pic'] ?? '').toString();

        if (!_isValidMusic(name, artist, dur)) continue;

        // 深入解析 N_MINFO 与 payInfo 获取真实音质
        final nMinfo = (item['N_MINFO'] ?? '').toString();
        final payTag = (payInfo is Map ? payInfo['paytagindex'] : null) ?? {};

        final bool hasHiRes = nMinfo.contains('zpga') || (payTag is Map && payTag['HR'] != null);
        final bool hasFlac = hasHiRes || nMinfo.contains('flac') || (payTag is Map && payTag['F'] != null);
        final bool has320 = nMinfo.contains('bitrate:320') || (payTag is Map && payTag['H'] != null);
        final bool has192 = nMinfo.contains('bitrate:192');

        String quality = '128k 标准';
        if (hasHiRes) {
          quality = 'Hi-Res 24bit';
        } else if (hasFlac) {
          quality = 'FLAC 无损';
        } else if (has320) {
          quality = '320k 极高';
        } else if (has192) {
          quality = '192k 较高';
        }

        songs.add(Song(
          id: rid,
          name: name,
          artist: artist,
          album: album,
          source: '酷我音乐',
          quality: quality,
          isLossless: hasFlac,
          durationSeconds: dur,
          coverUrl: pic,
        ));
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 网易云音乐搜索 (精准提取 hr/sq/h/m/l 音质)
  static Future<List<Song>> searchNetease(String keyword) async {
    try {
      final url = Uri.parse('https://music.163.com/api/cloudsearch/pc');
      final resp = await http.post(
        url,
        headers: {
          ..._headers,
          'Referer': 'https://music.163.com/',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: {'s': keyword, 'type': '1', 'limit': '25', 'offset': '0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final songsList = (data['result']?['songs'] as List?) ?? [];
      final songs = <Song>[];
      for (final item in songsList) {
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final name = (item['name'] ?? '未知歌曲').toString();
        final arList = item['ar'] as List? ?? [];
        final artist = arList.map((a) => a['name']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');
        final al = item['al'] ?? {};
        final album = (al['name'] ?? '').toString();
        final pic = (al['picUrl'] ?? '').toString();
        final dt = (item['dt'] ?? 0) as int;
        final durSeconds = dt ~/ 1000;

        if (!_isValidMusic(name, artist, durSeconds)) continue;

        final quality = _neteaseQuality(item);
        final hasFlac = quality.contains('FLAC');

        songs.add(Song(
          id: id,
          name: name,
          artist: artist.isEmpty ? '未知歌手' : artist,
          album: album,
          source: '网易云',
          quality: quality,
          isLossless: hasFlac,
          durationSeconds: durSeconds,
          coverUrl: pic,
        ));
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 咪咕音乐搜索
  static Future<List<Song>> searchMigu(String keyword) async {
    try {
      final url = Uri.parse(
        'https://c.musicapp.migu.cn/v1.0/content/search_all.do?text=${Uri.encodeComponent(keyword)}&pageNo=1&pageSize=20&searchSwitch=%7B%22song%22%3A1%7D'
      );
      final resp = await http.get(url, headers: {
        ..._headers,
        'Origin': 'https://h5.nf.migu.cn',
        'Referer': 'https://h5.nf.migu.cn/',
        'ua': 'Android_migu',
        'version': '6.8.8',
        'channel': '014021I'
      }).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = (data['songResultData']?['result'] as List?) ?? [];
      final songs = <Song>[];
      for (final item in list) {
        final id = (item['id'] ?? item['contentId'] ?? '').toString();
        if (id.isEmpty) continue;
        final name = (item['name'] ?? '未知歌曲').toString();
        final singers = (item['singers'] as List?) ?? [];
        final artist = singers.map((s) => s['name']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');
        final album = (item['album'] is Map ? item['album']['name'] : '').toString();
        final imgItems = (item['imgItems'] as List?) ?? [];
        String pic = '';
        if (imgItems.isNotEmpty && imgItems.first is Map) {
          pic = (imgItems.first['img'] ?? '').toString();
        }

        int duration = 0;
        final rawDur = item['duration'] ?? item['length'] ?? item['totalTime'];
        if (rawDur is int) {
          duration = rawDur > 1000 ? (rawDur / 1000).round() : rawDur;
        } else if (rawDur is String && rawDur.isNotEmpty) {
          if (rawDur.contains(':')) {
            final parts = rawDur.split(':');
            if (parts.length == 2) {
              duration = (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
            } else if (parts.length == 3) {
              duration = (int.tryParse(parts[0]) ?? 0) * 3600 + (int.tryParse(parts[1]) ?? 0) * 60 + (int.tryParse(parts[2]) ?? 0);
            }
          } else {
            final parsed = int.tryParse(rawDur);
            if (parsed != null) {
              duration = parsed > 1000 ? (parsed / 1000).round() : parsed;
            }
          }
        }
        if (duration < 0) duration = 0;

        final rateFormats = (item['rateFormats'] as List?) ?? [];
        if (duration <= 0 && rateFormats.isNotEmpty) {
          for (final rf in rateFormats) {
            if (rf is! Map) continue;
            final fmtType = (rf['formatType'] ?? '').toString().toUpperCase();
            final size = int.tryParse((rf['size'] ?? 0).toString()) ?? 0;
            if (size > 0) {
              if (fmtType == 'HQ') {
                duration = (size * 8 / (320 * 1000)).round();
                break;
              } else if (fmtType == 'LQ') {
                duration = (size * 8 / (128 * 1000)).round();
              }
            }
          }
        }

        if (!_isValidMusic(name, artist, duration)) continue;
        bool hasFlac = false;
        bool has320 = false;
        bool hasHiRes = false;
        for (final rf in rateFormats) {
          if (rf is! Map) continue;
          final fmtType = (rf['formatType'] ?? '').toString().toUpperCase();
          final fileType = (rf['fileType'] ?? '').toString().toLowerCase();
          if (fmtType == 'SQ' || fileType == 'flac') hasFlac = true;
          if (fmtType.contains('ZQ')) hasHiRes = true;
          if (fmtType == 'HQ' || fileType == 'mp3') has320 = true;
        }

        String quality = '128k 标准';
        if (hasHiRes) {
          quality = 'Hi-Res 24bit';
        } else if (hasFlac) {
          quality = 'FLAC 无损';
        } else if (has320) {
          quality = '320k 极高';
        }

        songs.add(Song(
          id: id,
          name: name,
          artist: artist.isEmpty ? '未知歌手' : artist,
          album: album,
          source: '咪咕音乐',
          quality: quality,
          isLossless: hasFlac || hasHiRes,
          durationSeconds: duration,
          coverUrl: pic,
        ));
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// QQ 音乐搜索 (提取高质量真实音质规格与高保真专辑大图)
  static Future<List<Song>> searchQQ(String keyword) async {
    try {
      final url = Uri.parse(
        'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?g_tk=5381&uin=0&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=h5&needNewCode=1&w=${Uri.encodeComponent(keyword)}&zhidaqu=1&catZhida=1&t=0&flag=1&ie=utf-8&sem=1&aggr=0&perpage=25&n=25&p=1&remoteplace=txt.mqq.all'
      );
      final resp = await http.get(url, headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.38',
        'Referer': 'https://m.y.qq.com/',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = (data['data']?['song']?['list'] as List?) ?? [];
      final songs = <Song>[];
      for (final item in list) {
        final mid = (item['songmid'] ?? '').toString();
        if (mid.isEmpty) continue;
        final name = (item['songname'] ?? '未知歌曲').toString();
        final singerList = (item['singer'] as List?) ?? [];
        final artist = singerList.map((s) => s['name']?.toString() ?? '').where((s) => s.isNotEmpty).join(', ');
        final album = (item['albumname'] ?? '').toString();
        final albumMid = (item['albummid'] ?? '').toString();
        final dur = int.tryParse((item['interval'] ?? 0).toString()) ?? 0;
        final pic = albumMid.isNotEmpty
            ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg'
            : '';

        if (!_isValidMusic(name, artist, dur)) continue;

        final sizeFlac = int.tryParse((item['sizeflac'] ?? 0).toString()) ?? 0;
        final size320 = int.tryParse((item['size320'] ?? 0).toString()) ?? 0;
        final size128 = int.tryParse((item['size128'] ?? 0).toString()) ?? 0;

        final quality = _qqQuality(item);
        final isLossless = quality.contains('FLAC');

        songs.add(Song(
          id: mid,
          name: name,
          artist: artist.isEmpty ? '未知歌手' : artist,
          album: album,
          source: 'QQ音乐',
          quality: quality,
          isLossless: isLossless,
          durationSeconds: dur,
          coverUrl: pic,
          fileSizeBytes: sizeFlac > 0 ? sizeFlac : (size320 > 0 ? size320 : size128),
        ));
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 酷狗音乐搜索 (提取 SQ/HQ 标识与真实哈希)
  static Future<List<Song>> searchKugou(String keyword) async {
    try {
      final url = Uri.parse(
        'https://songsearch.kugou.com/song_search_v2?format=json&keyword=${Uri.encodeComponent(keyword)}&platform=WebFilter&page=1&pagesize=25'
      );
      final resp = await http.get(url, headers: _headers).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = (data['data']?['lists'] as List?) ?? [];
      final songs = <Song>[];
      for (final item in list) {
        final hash = (item['FileHash'] ?? '').toString();
        if (hash.isEmpty) continue;
        final name = (item['SongName'] ?? item['FileName'] ?? '未知歌曲').toString();
        final artist = (item['SingerName'] ?? '未知歌手').toString();
        final album = (item['AlbumName'] ?? '').toString();
        final dur = int.tryParse((item['Duration'] ?? 0).toString()) ?? 0;
        String pic = (item['Image'] ?? '').toString();
        if (pic.contains('{size}')) {
          pic = pic.replaceAll('{size}', '300');
        }

        if (!_isValidMusic(name, artist, dur)) continue;

        final sqHash = (item['SQFileHash'] ?? '').toString();
        final sqSize = int.tryParse((item['SQFileSize'] ?? 0).toString()) ?? 0;
        final hqHash = (item['HQFileHash'] ?? '').toString();
        final hqSize = int.tryParse((item['HQFileSize'] ?? 0).toString()) ?? 0;
        final stdSize = int.tryParse((item['FileSize'] ?? 0).toString()) ?? 0;

        final hasFlac = sqHash.isNotEmpty && sqSize > 0;
        final has320 = hqHash.isNotEmpty && hqSize > 0;

        String quality = '128k 标准';
        if (hasFlac) {
          quality = 'FLAC 无损';
        } else if (has320) {
          quality = '320k 极高';
        }

        songs.add(Song(
          id: hash,
          losslessId: hasFlac ? sqHash : null,
          highQualityId: has320 ? hqHash : null,
          name: name,
          artist: artist,
          album: album,
          source: '酷狗音乐',
          quality: quality,
          isLossless: hasFlac,
          durationSeconds: dur,
          coverUrl: pic,
          fileSizeBytes: hasFlac ? sqSize : (has320 ? hqSize : stdSize),
        ));
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 哔哩哔哩 (B站音频/Live/现场/二创) 搜索
  static Future<List<Song>> searchBilibili(String keyword) async {
    try {
      final url = Uri.parse(
        'https://api.bilibili.com/x/web-interface/search/all/v2?keyword=${Uri.encodeComponent(keyword)}&page=1&pagesize=20'
      );
      final resp = await http.get(url, headers: {
        ..._headers,
        'Referer': 'https://www.bilibili.com',
        'Cookie': 'buvid3=infoc;',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final resultList = data['data']?['result'] as List? ?? [];
      final songs = <Song>[];

      for (final cat in resultList) {
        if (cat is Map && cat['result_type'] == 'video') {
          final videoList = cat['data'] as List? ?? [];
          for (final item in videoList) {
            final bvid = (item['bvid'] ?? '').toString();
            if (bvid.isEmpty) continue;
            final rawTitle = (item['title'] ?? '未知视频').toString();
            final title = rawTitle.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            final author = (item['author'] ?? 'B站UP主').toString();
            var pic = (item['pic'] ?? '').toString();
            if (pic.startsWith('//')) {
              pic = 'https:$pic';
            }
            final rawDur = (item['duration'] ?? '').toString();
            int durSeconds = 0;
            if (rawDur.contains(':')) {
              final parts = rawDur.split(':');
              if (parts.length == 2) {
                durSeconds = (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
              } else if (parts.length == 3) {
                durSeconds = (int.tryParse(parts[0]) ?? 0) * 3600 + (int.tryParse(parts[1]) ?? 0) * 60 + (int.tryParse(parts[2]) ?? 0);
              }
            } else {
              durSeconds = int.tryParse(rawDur) ?? 0;
            }

            if (!_isValidMusic(title, author, durSeconds)) continue;

            songs.add(Song(
              id: bvid,
              name: title,
              artist: author,
              album: 'B站现场/原声',
              source: '哔哩哔哩',
              quality: '音质待检测',
              isLossless: false,
              durationSeconds: durSeconds,
              coverUrl: pic,
            ));
          }
        }
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 汽水音乐 (抖音/Soda Music) 搜索 (提取千万级抖音热歌、流行翻唱与纯正BGM)
  static Future<List<Song>> searchSoda(String keyword) async {
    try {
      final params = {
        'device_platform': 'android',
        'os': 'android',
        'ssmix': 'a',
        'cdid': '46556f98-1720-4248-83da-62b74b60b46a',
        'channel': 'xiaomi_8478_64',
        'aid': '386088',
        'app_name': 'luna',
        'version_code': '100198030',
        'version_name': '19.8.0',
        'package': 'com.luna.music',
        '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
        'q': keyword,
        'cursor': '0',
        'count': '25',
      };
      final uri = Uri.https('api.qishui.com', '/luna/search/track', params);
      final resp = await http.get(uri, headers: {
        'User-Agent': 'com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)',
        'Accept-Encoding': 'gzip',
        'content-type': 'application/json; charset=UTF-8',
      }).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return [];
      final j = jsonDecode(resp.body);
      final groups = j['result_groups'] as List? ?? [];
      final songs = <Song>[];
      for (final g in groups) {
        final data = g['data'] as List? ?? [];
        for (final item in data) {
          final entity = item['entity'] as Map<String, dynamic>? ?? {};
          final t = entity['track'] ?? item['track'] ?? entity;
          final id = (t['id'] ?? '').toString();
          if (id.isEmpty) continue;
          final name = (t['name'] ?? t['title'] ?? '未知歌曲').toString();
          final artistList = t['artists'] as List? ?? [];
          final artist = artistList
              .map((a) => (a['name'] ?? a['simple_display_name'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .join(', ');
          final album = (t['album']?['name'] ?? '').toString();
          final dur = ((t['duration'] ?? t['dt'] ?? 0) as num).toInt() ~/ 1000;

          if (!_isValidMusic(name, artist, dur)) continue;

          // 封面图提取
          String pic = '';
          final coverObj = t['album']?['url_cover'] ?? t['cover_url'];
          if (coverObj is Map) {
            final uriStr = (coverObj['uri'] ?? '').toString();
            final tpl = (coverObj['template_prefix'] ?? 'tplv-b829550vbb').toString();
            if (uriStr.isNotEmpty) {
              pic = 'https://p3-luna.douyinpic.com/img/$uriStr~$tpl-resize:400:400.png';
            } else {
              final urls = coverObj['urls'] as List? ?? [];
              if (urls.isNotEmpty) pic = urls.first.toString();
            }
          }

          // 音质判定
          final bitRates = t['bit_rates'] as List? ?? [];
          bool hasLossless = false;
          bool hasHighest = false;
          int maxSize = 0;
          for (final br in bitRates) {
            if (br is Map) {
              final q = (br['quality'] ?? '').toString();
              final sz = ((br['size'] ?? 0) as num).toInt();
              if (sz > maxSize) maxSize = sz;
              if (q == 'lossless' || q == 'hi_res') hasLossless = true;
              if (q == 'highest') hasHighest = true;
            }
          }

          String quality = '128k 标准';
          if (hasLossless) {
            quality = 'FLAC 无损';
          } else if (hasHighest) {
            quality = '320k 极高';
          }

          songs.add(Song(
            id: id,
            name: name,
            artist: artist.isEmpty ? '未知歌手' : artist,
            album: album,
            source: '汽水音乐',
            quality: quality,
            isLossless: hasLossless,
            durationSeconds: dur,
            coverUrl: pic,
            fileSizeBytes: maxSize,
          ));
        }
      }
      return songs;
    } catch (_) {
      return [];
    }
  }

  /// 转换汽水/抖音时间轴歌词为标准 LRC 格式
  static String convertSodaLyricToLrc(String rawSodaLyric) {
    if (!rawSodaLyric.contains('[') || !rawSodaLyric.contains(',')) {
      return rawSodaLyric;
    }
    final sb = StringBuffer();
    final lines = rawSodaLyric.split('\n');
    final timeRegex = RegExp(r'^\[(\d+),\s*(\d+)\](.*)$');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final m = timeRegex.firstMatch(trimmed);
      if (m != null) {
        final startMs = int.tryParse(m.group(1) ?? '0') ?? 0;
        final rawWords = m.group(3) ?? '';
        final cleanWords = rawWords.replaceAll(RegExp(r'<[^>]+>'), '').trim();
        final totalSec = startMs ~/ 1000;
        final min = (totalSec ~/ 60).toString().padLeft(2, '0');
        final sec = (totalSec % 60).toString().padLeft(2, '0');
        final ms = ((startMs % 1000) ~/ 10).toString().padLeft(2, '0');
        sb.writeln('[$min:$sec.$ms]$cleanWords');
      } else {
        sb.writeln(trimmed);
      }
    }
    return sb.toString();
  }

  /// 对所有音源使用相同的字节/格式/时长检查，探测失败不能算成功。
  static Future<RealAudioInfo?> inspectAudioUrl(String? url, {int durationSeconds = 0, void Function()? onTlsFailure}) async {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) return null;
    if (url!.contains('588957081') || url.contains('refuse')) return null;
    final client = http.Client();
    try {
      Future<http.StreamedResponse> requestRange(int start, {int length = 65536}) {
        final request = http.Request('GET', uri)
          ..headers.addAll(audioHeaders(url))
          ..headers['Range'] = 'bytes=$start-${start + length - 1}'
          ..maxRedirects = 5;
        return client.send(request).timeout(const Duration(seconds: 6));
      }
      Future<List<int>> readPrefix(http.StreamedResponse response, {int limit = 65536}) async {
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(const Duration(seconds: 6))) {
          final remaining = limit - bytes.length;
          bytes.addAll(chunk.take(remaining));
          if (bytes.length >= limit) break;
        }
        return bytes;
      }
      final response = await requestRange(0);
      if (response.statusCode != 200 && response.statusCode != 206) return null;
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      if (type.contains('text/') || type.contains('json')) return null;
      final totalMatch = RegExp(r'/([0-9]+)$').firstMatch(response.headers['content-range'] ?? '');
      final total = totalMatch != null ? int.parse(totalMatch.group(1)!)
          : (response.statusCode == 200 ? response.contentLength ?? 0 : 0);
      var bytes = await readPrefix(response);
      var audioSize = total;
      int number(List<int> data, int start, int length) {
        if (start + length > data.length) return 0;
        return data.sublist(start, start + length).fold(0, (value, byte) => (value << 8) | byte);
      }
      // 封面可能使 ID3 标签超过探测窗口，需要直接定位真正的音频帧。
      if (bytes.length >= 10 && bytes[0] == 73 && bytes[1] == 68 && bytes[2] == 51) {
        final tagSize = 10 + ((bytes[6] & 127) << 21) + ((bytes[7] & 127) << 14)
            + ((bytes[8] & 127) << 7) + (bytes[9] & 127) + ((bytes[5] & 16) != 0 ? 10 : 0);
        if (tagSize >= bytes.length && (total == 0 || tagSize < total)) {
          final audioResponse = await requestRange(tagSize);
          if (audioResponse.statusCode != 206) return null;
          bytes = await readPrefix(audioResponse);
          audioSize = total > tagSize ? total - tagSize : 0;
        }
      }
      var info = AudioInspector.inspectBytes(bytes, fileSizeBytes: audioSize);
      if (!info.isValid && total > 42 && bytes.length >= 42 && String.fromCharCodes(bytes.take(4)) == 'fLaC') {
        var position = 4;
        for (var count = 0; count < 1024 && position + 4 <= total; count++) {
          List<int> header;
          if (position + 4 <= bytes.length) {
            header = bytes.sublist(position, position + 4);
          } else {
            final part = await requestRange(position, length: 4);
            if (part.statusCode != 206) return null;
            header = await readPrefix(part, limit: 4);
          }
          if (header.length < 4) return null;
          final last = header[0] & 128 != 0;
          position += 4 + number(header, 1, 3);
          if (position + 6 > total) return null;
          if (last) {
            final part = await requestRange(position, length: 16);
            if (part.statusCode != 206) return null;
            final frame = await readPrefix(part, limit: 16);
            final compact = bytes.take(42).toList()..[4] = 128;
            info = AudioInspector.inspectBytes([...compact, ...frame], fileSizeBytes: total);
            break;
          }
        }
      }
      // M4A 的 moov 可能在媒体数据之后，按顶层 box 偏移跳过媒体，仅取元数据。
      if (!info.isValid && total > 0 && bytes.length >= 16 && String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
        final metadata = <int>[];
        var position = 0;
        for (var count = 0; count < 128 && position + 8 <= total; count++) {
          List<int> boxBytes;
          if (position + 16 <= bytes.length) {
            boxBytes = bytes.sublist(position);
          } else {
            final part = await requestRange(position);
            if (part.statusCode != 206) return null;
            boxBytes = await readPrefix(part);
          }
          if (boxBytes.length < 8) return null;
          final type = String.fromCharCodes(boxBytes.sublist(4, 8));
          var length = number(boxBytes, 0, 4);
          final header = length == 1 ? 16 : 8;
          if (length == 1) length = number(boxBytes, 8, 8);
          if (length == 0) length = total - position;
          if (length < header || position + length > total) return null;
          if (type == 'ftyp' || type == 'moov') {
            if (metadata.length + length > 4 * 1024 * 1024) return null;
            if (length > boxBytes.length) {
              final part = await requestRange(position, length: length);
              if (part.statusCode != 206) return null;
              boxBytes = await readPrefix(part, limit: length);
            }
            if (boxBytes.length < length) return null;
            metadata.addAll(boxBytes.take(length));
            if (type == 'moov') {
              info = AudioInspector.inspectBytes(metadata, fileSizeBytes: total);
              break;
            }
          }
          position += length;
        }
      }
      if (!info.isValid || info.hasVideo) return null;
      final dur = info.durationSeconds > 0
          ? info.durationSeconds
          : (info.bitrateKbps > 0 && info.fileSizeBytes > 0 ? (info.fileSizeBytes * 8 / (info.bitrateKbps * 1000)).round() : 0);
      final isTrialSnippet = (dur > 0 && dur <= 90) ||
          (durationSeconds > 60 && dur > 0 && dur < durationSeconds * 0.75) ||
          (durationSeconds > 60 && dur <= 0 && info.fileSizeBytes > 0 && info.fileSizeBytes < 2.5 * 1024 * 1024);
      if (isTrialSnippet) {
        return null;
      }
      return info;
    } catch (error) {
      if (error is HandshakeException) onTlsFailure?.call();
      return null;
    } finally {
      client.close();
    }
  }

  static Map<String, String> audioHeaders(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    String? referer;
    if (host.endsWith('bilivideo.com') || host.endsWith('bilibili.com')) {
      referer = 'https://www.bilibili.com/';
    } else if (host.endsWith('163.com') || host.endsWith('126.net')) {
      referer = 'https://music.163.com/';
    } else if (host.endsWith('kugou.com')) {
      referer = 'https://www.kugou.com/';
    } else if (host.endsWith('qq.com') || host.endsWith('qqmusic.qq.com')) {
      referer = 'https://y.qq.com/';
    }
    return {..._headers, 'Accept-Encoding': 'identity', 'Referer': ?referer};
  }

  static Future<bool> isValidAudioUrl(String? url, {String targetQuality = '', int durationSeconds = 0}) async {
    final info = await inspectAudioUrl(url, durationSeconds: durationSeconds);
    return info != null && _matchesResolvedQuality(info, targetQuality);
  }

  /// 空档位兼容既有调用；auto 优先本源可验证的无损/320k，再尝试标准档。
  static Future<String?> resolveAudioUrl(
    Song song, {
    bool preferLossless = true,
    bool forceRefresh = false,
    String targetQuality = '',
    Set<String> excludedUrls = const {},
    bool forPlayback = false,
  }) async {
    final requested = targetQuality.isEmpty ? (preferLossless ? 'flac' : '320k') : targetQuality;
    if (!{'auto', 'flac', 'hires', '320k', '128k', if (forPlayback) '256k'}.contains(requested)) {
      throw ArgumentError.value(targetQuality, 'targetQuality', '不支持的音质档位');
    }
    final expectedDuration = song.durationSeconds;
    if (!forceRefresh && !song.isAudioUrlExpired && song.audioUrlQuality == requested
        && !excludedUrls.contains(song.audioUrl)) {
      final info = await inspectAudioUrl(song.audioUrl, durationSeconds: expectedDuration);
      if (info != null && (forPlayback ? info.matchesPlaybackQuality(requested, allowHigher: requested == '256k' || requested == '320k') : info.matchesQuality(requested == 'auto' ? '' : requested))) {
        _applyAudioInfo(song, info);
        return song.audioUrl;
      }
    }
    song.audioUrl = null;
    song.audioUrlTimestamp = null;
    song.audioUrlQuality = null;
    song.audioUrlSource = null;
    final levels = _resolutionLevels(requested, forPlayback);
    for (final level in levels) {
      final url = await _resolveSource(song, level, excludedUrls);
      if (url == null || excludedUrls.contains(url)) continue;
      final info = await inspectAudioUrl(url, durationSeconds: expectedDuration);
      if (info == null) continue;
      if (!_matchesResolvedQuality(info, level)) continue;
      song.audioUrl = url;
      song.audioUrlTimestamp = DateTime.now().millisecondsSinceEpoch;
      song.audioUrlQuality = _sourceTargetQuality(level);
      song.audioUrlSource = song.source;
      _applyAudioInfo(song, info);
      return url;
    }
    final fallback = await resolveCrossSource(song, preferLossless: preferLossless,
        targetQuality: requested, excludedUrls: excludedUrls, forPlayback: forPlayback);
    if (fallback != null) {
      song.audioUrlQuality = requested;
      song.audioUrlTimestamp = DateTime.now().millisecondsSinceEpoch;
    }
    return fallback;
  }

  static String _sourceTargetQuality(String quality) => quality.startsWith('play:') ? quality.substring(5) : quality;

  static bool _matchesResolvedQuality(RealAudioInfo info, String quality) => quality.startsWith('play:')
      ? info.matchesPlaybackQuality(quality.substring(5)) : info.matchesQuality(quality);

  static List<String> _resolutionLevels(String requested, bool forPlayback) {
    if (forPlayback) {
      final levels = requested == 'auto' ? ['flac', '320k', '256k', '128k', '']
          : requested == '256k' ? ['256k', '320k', 'flac']
          : requested == '320k' ? ['320k', 'flac'] : [requested];
      return levels.map((q) => 'play:$q').toList();
    }
    // 下载模式严格尊重用户所选规格，不进行静默降级或反向升级
    if (requested == 'auto' || requested.isEmpty) {
      return ['flac', '320k', '128k'];
    }
    return [requested];
  }

  static void _applyAudioInfo(Song song, RealAudioInfo info) {
    song.quality = info.qualityLabel;
    song.isLossless = info.isLossless;
    song.fileSizeBytes = info.fileSizeBytes;
    song.size = info.fileSizeBytes > 0 ? info.sizeMb : '';
  }

  static Future<String?> _resolveSource(Song song, String quality, Set<String> excludedUrls) async {
    final tier = _sourceTargetQuality(quality);
    final preferLossless = tier == 'flac' || tier == 'hires';
    String? url;
    switch (song.source) {
      case 'QQ音乐':
        url = await _resolveQQ(song, preferLossless: preferLossless, targetQuality: quality);
      case '酷狗音乐':
        url = await _resolveKugou(song, preferLossless: preferLossless, targetQuality: quality);
      case '酷我音乐':
        url = await _resolveKuwo(song, preferLossless: preferLossless, targetQuality: quality);
      case '网易云':
        url = await _resolveNetease(song, preferLossless: preferLossless, targetQuality: quality);
      case '咪咕音乐':
        url = await _resolveMigu(song, preferLossless: preferLossless, targetQuality: quality);
      case '哔哩哔哩':
        url = await _resolveBilibili(song, targetQuality: quality);
      case '汽水音乐':
        url = await _resolveSoda(song, preferLossless: preferLossless, targetQuality: quality);
    }
    return excludedUrls.contains(url) ? null : url;
  }

  static Future<String?> _jsonAudioUrl(Uri uri, Song song, String targetQuality,
      {String field = 'data', Map<String, String>? headers, int timeoutSeconds = 5}) async {
    try {
      final response = await http.get(uri, headers: headers ?? _headers).timeout(Duration(seconds: timeoutSeconds));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      final object = field.isEmpty ? json : json[field];
      final link = object is Map ? object['url']?.toString() : null;
      if (link != null) return _checkedAudioUrl(link, song, targetQuality);
    } catch (_) {}
    return null;
  }

  static Future<String?> _checkedAudioUrl(String link, Song song, String quality) async {
    var tlsFailed = false;
    final info = await inspectAudioUrl(link, durationSeconds: song.durationSeconds,
        onTlsFailure: () => tlsFailed = true);
    if (info != null && _matchesResolvedQuality(info, quality)) return link;
    final uri = Uri.tryParse(link);
    // 此旧 CDN 已验证存在主机名证书错误。仅握手失败才兼容其原有 HTTP 服务；不放宽 HTTPS 证书校验。
    if (tlsFailed && uri?.scheme == 'https' && uri?.host == 'fs.youthandroid2.kugou.com') {
      final legacy = uri!.replace(scheme: 'http').toString();
      if (await isValidAudioUrl(legacy, targetQuality: quality, durationSeconds: song.durationSeconds)) return legacy;
    }
    return null;
  }

  static Future<String?> _redirectAudioUrl(Uri uri, Song song, String targetQuality) async {
    final client = http.Client();
    try {
      final request = http.Request('HEAD', uri)..headers.addAll(_headers)..followRedirects = false;
      final response = await client.send(request).timeout(const Duration(seconds: 4));
      final location = response.headers['location'];
      if (location != null && await isValidAudioUrl(location, targetQuality: targetQuality, durationSeconds: song.durationSeconds)) {
        return location;
      }
    } catch (_) {} finally {
      client.close();
    }
    return null;
  }

  static Future<String?> _resolveQQ(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    final tier = _sourceTargetQuality(targetQuality);
    final level = tier == '128k' ? '128' : tier == '256k' ? '256' : (preferLossless ? 'lossless' : '320');
    // 1. Try vkeys API
    try {
      final vkeysUri = Uri.https('api.vkeys.cn', '/v2/music/tencent', {'mid': song.id});
      final resp = await http.get(vkeysUri, headers: _headers).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final data = json['data'];
        if (data is Map) {
          final quality = (data['quality'] ?? '').toString();
          final link = (data['url'] ?? '').toString();
          // Filter out VIP preview/trial (音乐试听, /RS0 prefix) and broken links
          final isPreview = quality.contains('试听') || link.contains('/RS0') || link.contains('RS02');
          if (!isPreview && link.startsWith('http') && !link.contains('&redirect=1')) {
            final checked = await _checkedAudioUrl(link, song, targetQuality);
            if (checked != null) return checked;
          }
        }
      }
    } catch (_) {}

    // 2. Try haitangw API
    try {
      final haitangUri = Uri.https('musicapi.haitangw.net', '/kgqq/qq.php', {'id': song.id, 'level': level, 'type': 'json'});
      final resp = await http.get(haitangUri, headers: _headers).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final data = json['data'];
        final link = data is Map ? data['url']?.toString() : null;
        if (link != null && link.startsWith('http') && !link.contains('&redirect=1') && !link.contains('/RS0')) {
          final checked = await _checkedAudioUrl(link, song, targetQuality);
          if (checked != null) return checked;
        }
      }
    } catch (_) {}

    return null;
  }

  static Future<String?> _resolveKugou(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    final hash = preferLossless ? (song.losslessId ?? song.id)
        : {'320k', '256k'}.contains(_sourceTargetQuality(targetQuality)) ? (song.highQualityId ?? song.id) : song.id;
    return _jsonAudioUrl(Uri.https('cocodownloader.markqq.com', '/api/url',
        {'id': hash, 'provider': 'kugou'}), song, targetQuality, field: '', timeoutSeconds: 2);
  }

  static Future<String?> _resolveSoda(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    try {
      final response = await http.get(Uri.https('beta-luna.douyin.com', '/luna/h5/seo_track',
          {'track_id': song.id, 'device_platform': 'web'}), headers: _headers).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      final lyric = json['lyric'];
      if (lyric is Map && lyric['content'] != null && (song.lyric == null || song.lyric!.isEmpty)) {
        song.lyric = convertSodaLyricToLrc(lyric['content'].toString());
      }
      final player = json['track_player'] ?? {};
      final links = <String>[];
      final playerInfo = player['url_player_info']?.toString();
      if (playerInfo != null && playerInfo.isNotEmpty) {
        final result = await http.get(Uri.parse(playerInfo), headers: _headers).timeout(const Duration(seconds: 5));
        if (result.statusCode == 200) {
          final list = jsonDecode(result.body)['Result']?['Data']?['PlayInfoList'] as List? ?? [];
          for (final item in list) {
            for (final key in ['MainPlayUrl', 'BackupPlayUrl']) {
              if (item[key] != null) links.add(item[key].toString());
            }
          }
        }
      }
      dynamic model = player['video_model'];
      if (model is String && model.isNotEmpty) model = jsonDecode(model);
      if (model is Map) {
        final list = model['video_list'];
        final entries = list is Map ? list.values : (list is List ? list : const []);
        for (final item in entries) {
          if (item is! Map) continue;
          for (final key in ['main_url', 'backup_url']) {
            var url = item[key]?.toString();
            if (url == null) continue;
            if (!url.startsWith('http')) {
              try { url = utf8.decode(base64.decode(url)); } catch (_) { continue; }
            }
            links.add(url);
          }
        }
      }
      RealAudioInfo? best;
      String? bestUrl;
      for (final link in links.toSet()) {
        final info = await inspectAudioUrl(link, durationSeconds: song.durationSeconds);
        if (info == null || !_matchesResolvedQuality(info, targetQuality)) continue;
        if (best == null || (info.isLossless && !best.isLossless) || info.bitrateKbps > best.bitrateKbps) {
          best = info;
          bestUrl = link;
        }
      }
      return bestUrl;
    } catch (_) { return null; }
  }

  static Future<String?> _resolveKuwo(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    final tier = _sourceTargetQuality(targetQuality);
    final level = tier == '128k' ? '128' : tier == '256k' ? '256' : (preferLossless ? 'lossless' : '320');
    final url = await _jsonAudioUrl(Uri.https('musicapi.haitangw.net', '/music/kw.php',
        {'id': song.id, 'level': level, 'type': 'json'}), song, targetQuality, timeoutSeconds: 3);
    if (url != null) return url;
    if (preferLossless) {
      final nxinxzUrl = await _jsonAudioUrl(Uri.http('music.nxinxz.com', '/kw.php',
          {'id': song.id, 'level': level, 'type': 'json'}), song, targetQuality, timeoutSeconds: 3);
      if (nxinxzUrl != null) return nxinxzUrl;
    }
    if (_sourceTargetQuality(targetQuality) == '128k' || _sourceTargetQuality(targetQuality).isEmpty) {
      try {
        final response = await http.get(Uri.http('antiserver.kuwo.cn', '/anti.s',
            {'type': 'convert_url', 'rid': song.id, 'format': 'mp3', 'response': 'url'}), headers: _headers).timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final link = response.body.trim();
          if (await isValidAudioUrl(link, targetQuality: targetQuality, durationSeconds: song.durationSeconds)) return link;
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<String?> _resolveMigu(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    return _redirectAudioUrl(Uri.https('api.injahow.cn', '/meting/',
        {'server': 'migu', 'type': 'url', 'id': song.id}), song, targetQuality);
  }

  static Future<String?> _resolveNetease(Song song, {bool preferLossless = true, String targetQuality = ''}) async {
    final meting = await _redirectAudioUrl(Uri.https('api.injahow.cn', '/meting/',
        {'type': 'url', 'id': song.id}), song, targetQuality);
    if (meting != null) return meting;
    return _redirectAudioUrl(Uri.https('music.163.com', '/song/media/outer/url',
        {'id': '${song.id}.mp3'}), song, targetQuality);
  }

  /// DASH 音频轨独立于视频；不再将 durl 视频或第一段视频当成歌曲。
  static Future<String?> _resolveBilibili(Song song, {String targetQuality = ''}) async {
    try {
      final headers = {..._headers, 'Referer': 'https://www.bilibili.com/', 'Cookie': 'buvid3=infoc;'};
      final view = await http.get(Uri.https('api.bilibili.com', '/x/web-interface/view', {'bvid': song.id}), headers: headers)
          .timeout(const Duration(seconds: 5));
      if (view.statusCode != 200) return null;
      final cid = jsonDecode(view.body)['data']?['cid']?.toString();
      if (cid == null || cid.isEmpty) return null;
      final response = await http.get(Uri.https('api.bilibili.com', '/x/player/playurl',
          {'bvid': song.id, 'cid': cid, 'fnval': '4048', 'fnver': '0', 'fourk': '1'}), headers: headers)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final dash = jsonDecode(response.body)['data']?['dash'];
      if (dash is! Map) return null;
      final tracks = <Map>[];
      final audio = dash['audio'];
      if (audio is List) tracks.addAll(audio.whereType<Map>());
      final flac = dash['flac']?['audio'];
      if (flac is Map) tracks.add(flac);
      tracks.sort((a, b) => ((b['bandwidth'] as num?) ?? 0).compareTo((a['bandwidth'] as num?) ?? 0));
      for (final track in tracks) {
        final urls = [track['baseUrl'] ?? track['base_url'], ...((track['backupUrl'] ?? track['backup_url']) as List? ?? [])];
        for (final link in urls.whereType<String>()) {
          if (await isValidAudioUrl(link, targetQuality: targetQuality, durationSeconds: song.durationSeconds)) return link;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 换源先核对歌曲身份与版本，再校验实际音频；保持原目标档位。
  static bool isSameRecording(Song original, Song candidate) {
    Set<String> artists(String value) => value.toLowerCase().split(RegExp(r'[,;/、&+\s]+'))
        .map((s) => s.trim()).where((s) => s.isNotEmpty && s != '未知歌手').toSet();
    final originalArtists = artists(original.artist);
    final candidateArtists = artists(candidate.artist);
    String normTitle(String t) {
      return Song.cleanTitle(t)
          .replaceAll('零', '0')
          .replaceAll('一', '1')
          .replaceAll('二', '2')
          .replaceAll('三', '3')
          .replaceAll('四', '4')
          .replaceAll('五', '5')
          .replaceAll('六', '6')
          .replaceAll('七', '7')
          .replaceAll('八', '8')
          .replaceAll('九', '9');
    }
    if (normTitle(original.name) != normTitle(candidate.name)) {
      return false;
    }
    if (originalArtists.isNotEmpty && candidateArtists.isNotEmpty) {
      final hasMatch = originalArtists.any((oa) => candidateArtists.any((ca) => ca.contains(oa) || oa.contains(ca)));
      if (!hasMatch) return false;
    }
    if (original.isLive != candidate.isLive || original.isInstrumental != candidate.isInstrumental) {
      return false;
    }
    for (final marker in ['remix', '翻唱', 'cover', '重制', '重录', '伴奏', 'acoustic', 'sped up', 'slowed']) {
      if (original.name.toLowerCase().contains(marker) != candidate.name.toLowerCase().contains(marker)) return false;
    }
    if (original.durationSeconds > 60 && candidate.durationSeconds > 0 && candidate.durationSeconds <= 90) {
      return false;
    }
    if (original.durationSeconds > 0 && candidate.durationSeconds > 0) {
      if ((original.durationSeconds - candidate.durationSeconds).abs() > 25) { return false; }
    }
    return true;
  }

  static Future<String?> resolveCrossSource(Song song, {bool preferLossless = true,
      String targetQuality = '', Set<String> excludedUrls = const {}, bool forPlayback = false}) async {
    const sources = {'酷我音乐', 'QQ音乐', '酷狗音乐', '网易云', '咪咕音乐', '哔哩哔哩', '汽水音乐'};
    if (!sources.contains(song.source)) return null;
    final requested = targetQuality.isEmpty ? (preferLossless ? 'flac' : '320k') : targetQuality;
    final query = '${Song.cleanTitle(song.name)} ${song.artist}'.trim();
    const allPlatforms = ['网易云', '酷我音乐', 'QQ音乐', '酷狗音乐', '咪咕音乐', '汽水音乐', '哔哩哔哩'];
    final platforms = allPlatforms.where((s) => s != song.source).toList();
    Future<({String url, Song candidate, RealAudioInfo info})?> trySource(String source) async {
      try {
        final List<Song> candidates;
        switch (source) {
          case '网易云': candidates = await searchNetease(query);
          case '酷我音乐': candidates = await searchKuwo(query);
          case '酷狗音乐': candidates = await searchKugou(query);
          case 'QQ音乐': candidates = await searchQQ(query);
          case '咪咕音乐': candidates = await searchMigu(query);
          case '汽水音乐': candidates = await searchSoda(query);
          default: candidates = await searchBilibili(query);
        }
        for (final candidate in candidates.where((s) => isSameRecording(song, s)).take(3)) {
          final levels = _resolutionLevels(requested, forPlayback);
          for (final level in levels) {
            final url = await _resolveSource(candidate, level, excludedUrls);
            if (url == null) continue;
            final info = await inspectAudioUrl(url, durationSeconds: song.durationSeconds);
            if (info != null) {
              if (!_matchesResolvedQuality(info, level)) continue;
              return (url: url, candidate: candidate, info: info);
            }
          }
        }
      } catch (_) {}
      return null;
    }
    final results = <({String url, Song candidate, RealAudioInfo info})>[];
    // 分批并发探测（每批 2 平台，防触发 429），命中最佳档位即刻短路退出
    const batchSize = 2;
    for (var i = 0; i < platforms.length; i += batchSize) {
      final batch = platforms.sublist(i, (i + batchSize).clamp(0, platforms.length));
      final batchResults = await Future.wait(batch.map((source) => trySource(source)));
      for (final res in batchResults) {
        if (res != null) results.add(res);
      }
      final hasOptimal = results.any((res) => requested == 'flac'
          ? res.info.isLossless
          : (requested == '320k' ? (!res.info.isLossless && res.info.bitrateKbps >= 240) : true));
      if (hasOptimal) break;
    }
    results.sort((a, b) {
      if (forPlayback && requested != 'auto') {
        final levels = _resolutionLevels(requested, true);
        int priority(RealAudioInfo info) => levels.indexWhere((q) => _matchesResolvedQuality(info, q));
        final difference = priority(a.info).compareTo(priority(b.info));
        if (difference != 0) return difference;
      }
      if (requested == 'flac' || requested == 'hires') {
        if (a.info.isLossless != b.info.isLossless) return a.info.isLossless ? -1 : 1;
        return b.info.bitrateKbps.compareTo(a.info.bitrateKbps);
      } else if (requested == '320k') {
        final aIs320 = !a.info.isLossless && a.info.bitrateKbps >= 240;
        final bIs320 = !b.info.isLossless && b.info.bitrateKbps >= 240;
        if (aIs320 != bIs320) return aIs320 ? -1 : 1;
        return b.info.bitrateKbps.compareTo(a.info.bitrateKbps);
      } else {
        return b.info.bitrateKbps.compareTo(a.info.bitrateKbps);
      }
    });
    if (results.isEmpty) return null;
    final result = results.first;
    song.audioUrl = result.url;
    song.audioUrlTimestamp = DateTime.now().millisecondsSinceEpoch;
    song.audioUrlQuality = requested;
    song.audioUrlSource = result.candidate.source;
    _applyAudioInfo(song, result.info);
    return result.url;
  }

  /// 全网跨源检索同名同歌手候选版本（供用户在下载失败时手动换源挑选）
  static Future<List<Song>> searchAlternatives(Song song) async {
    final cleanTitle = Song.cleanTitle(song.name);
    final query = '$cleanTitle ${song.artist}'.trim();
    final futures = <Future<List<Song>>>[
      searchKuwo(query),
      searchQQ(query),
      searchKugou(query),
      searchMigu(query),
      searchNetease(query),
      searchBilibili(query),
      searchSoda(query),
    ];
    final allResults = await Future.wait(futures);
    final candidates = <Song>[];
    for (final list in allResults) {
      for (final s in list) {
        if (s.id == song.id && s.source == song.source) continue;
        candidates.add(s);
      }
    }
    // 优先排前：无损或高码率优先
    candidates.sort((a, b) {
      if (a.isLossless && !b.isLossless) return -1;
      if (!a.isLossless && b.isLossless) return 1;
      return 0;
    });
    return candidates;
  }

  /// 抓取歌词并格式化为标准 LRC（支持双语翻译歌词）
  static Future<String?> fetchLyric(Song song) async {
    if (song.lyric != null && song.lyric!.isNotEmpty) return song.lyric;

    if (song.source == '网易云') {
      try {
        final u = Uri.parse('https://music.163.com/api/song/lyric?id=${song.id}&lv=1&kv=1&tv=-1');
        final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final lrc = j['lrc']?['lyric']?.toString();
          final tlyric = j['tlyric']?['lyric']?.toString();
          if (lrc != null && lrc.isNotEmpty) {
            song.lyric = lrc;
            if (tlyric != null && tlyric.isNotEmpty) {
              song.transLyric = tlyric;
            }
            return song.lyric;
          }
        }
      } catch (_) {}
    } else if (song.source == '酷我音乐') {
      try {
        final u = Uri.parse('http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=${song.id}');
        final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final lrcList = j['data']?['lrclist'] as List? ?? [];
          final sb = StringBuffer();
          for (final item in lrcList) {
            final t = double.tryParse((item['time'] ?? '0').toString()) ?? 0.0;
            final m = (t ~/ 60).toString().padLeft(2, '0');
            final s = (t % 60).toStringAsFixed(2).padLeft(5, '0');
            final txt = (item['lineLyric'] ?? '').toString();
            sb.writeln('[$m:$s]$txt');
          }
          if (sb.isNotEmpty) {
            song.lyric = sb.toString();
            return song.lyric;
          }
        }
      } catch (_) {}
    } else if (song.source == '汽水音乐') {
      try {
        final u = Uri.parse('https://beta-luna.douyin.com/luna/h5/seo_track?track_id=${song.id}&device_platform=web');
        final r = await http.get(u, headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        }).timeout(const Duration(seconds: 5));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final lyricMap = j['lyric'];
          if (lyricMap is Map && lyricMap['content'] != null) {
            final raw = lyricMap['content'].toString();
            final lrc = convertSodaLyricToLrc(raw);
            if (lrc.isNotEmpty) {
              song.lyric = lrc;
              return lrc;
            }
          }
        }
      } catch (_) {}
    }

    // 若原平台未拿到歌词或需要双语翻译，跨平台从网易云精准匹配歌词与翻译
    try {
      final query = '${song.name} ${song.artist}';
      final u = Uri.parse('https://music.163.com/api/cloudsearch/pc');
      final resp = await http.post(
        u,
        headers: {
          ..._headers,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 's=${Uri.encodeComponent(query)}&type=1&offset=0&limit=1',
      ).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        final songs = j['result']?['songs'] as List? ?? [];
        if (songs.isNotEmpty) {
          final nid = songs.first['id'];
          final lu = Uri.parse('https://music.163.com/api/song/lyric?id=$nid&lv=1&kv=1&tv=-1');
          final lr = await http.get(lu, headers: _headers).timeout(const Duration(seconds: 4));
          if (lr.statusCode == 200) {
            final lj = jsonDecode(lr.body);
            final lrc = lj['lrc']?['lyric']?.toString();
            final tlyric = lj['tlyric']?['lyric']?.toString();
            if (lrc != null && lrc.isNotEmpty) {
              song.lyric = lrc;
              if (tlyric != null && tlyric.isNotEmpty) {
                song.transLyric = tlyric;
              }
              return song.lyric;
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// 获取官方权威音乐榜单（热歌榜、飙升榜、新歌榜、原创榜）
  static Future<List<Map<String, dynamic>>> fetchTopCharts() async {
    final chartConfigs = [
      {'title': '热歌榜', 'id': '3778678', 'badge': 'TOP 50', 'desc': '官方权威热度风向标'},
      {'title': '飙升榜', 'id': '19723756', 'badge': '100% 飙升', 'desc': '网易云官方权威飙升榜'},
      {'title': '新歌榜', 'id': '3779629', 'badge': '今日上新', 'desc': '流行华语新歌每日精选'},
      {'title': '原创榜', 'id': '2884035', 'badge': '独立原创', 'desc': '品质华语独立原创榜单'},
    ];

    final results = <Map<String, dynamic>>[];

    for (final cfg in chartConfigs) {
      final songs = <Song>[];
      try {
        final u = Uri.parse('https://music.163.com/api/playlist/detail?id=${cfg['id']}');
        final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final tracks = j['result']?['tracks'] as List? ?? [];
          for (final t in tracks.take(50)) {
            final id = (t['id'] ?? '').toString();
            final name = (t['name'] ?? '未知曲目').toString();
            final artistsList = t['artists'] as List? ?? t['ar'] as List? ?? [];
            var artist = artistsList.map((a) => (a['name'] ?? '').toString()).where((s) => s.isNotEmpty).join(' / ');
            if (artist.isEmpty) {
              artist = (t['album']?['artist']?['name'] ?? '未知歌手').toString();
            }
            final album = (t['album']?['name'] ?? t['al']?['name'] ?? '').toString();
            var pic = (t['album']?['picUrl'] ?? t['al']?['picUrl'] ?? '').toString();
            if (pic.startsWith('http://')) {
              pic = pic.replaceFirst('http://', 'https://');
            }
            final dur = ((int.tryParse((t['duration'] ?? t['dt'] ?? 0).toString()) ?? 0) ~/ 1000);
            songs.add(Song(
              id: id,
              name: name,
              artist: artist.isEmpty ? '未知歌手' : artist,
              album: album,
              source: '网易云',
              durationSeconds: dur,
              coverUrl: pic,
              quality: _neteaseQuality(t),
              isLossless: _neteaseQuality(t).contains('FLAC'),
            ));
          }
        }
      } catch (_) {}

      results.add({
        'title': cfg['title']!,
        'badge': cfg['badge']!,
        'desc': cfg['desc']!,
        'songs': songs,
      });
    }

    return results;
  }

  /// 获取全网实时热搜关键词（优先接入权威实时热搜API，失败自动降级到精选热词）
  static Future<List<Map<String, dynamic>>> fetchHotKeywords() async {
    try {
      final u = Uri.parse('https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg');
      final r = await http.get(u, headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        'Referer': 'https://y.qq.com/',
      }).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        final hotkeys = j['data']?['hotkey'] as List? ?? [];
        if (hotkeys.isNotEmpty) {
          final result = <Map<String, dynamic>>[];
          for (int i = 0; i < hotkeys.length && i < 15; i++) {
            final k = hotkeys[i]['k']?.toString().trim() ?? '';
            if (k.isNotEmpty && !result.any((item) => item['name'] == k)) {
              result.add({
                'name': k,
                'hot': i < 3,
              });
            }
          }
          if (result.isNotEmpty) return result;
        }
      }
    } catch (_) {}

    return [
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
  }

  /// 导入外部歌单（网易云音乐、QQ音乐分享链接/ID）
  static Future<Map<String, dynamic>?> importExternalPlaylist(String input) async {
    final cleanInput = input.trim();
    if (cleanInput.isEmpty) return null;

    // 1. 网易云音乐歌单解析
    String? neteaseId;
    if (cleanInput.contains('163.com') || cleanInput.contains('126.net')) {
      final match = RegExp(r'id=(\d+)').firstMatch(cleanInput);
      if (match != null) {
        neteaseId = match.group(1);
      }
    } else if (RegExp(r'^\d+$').hasMatch(cleanInput)) {
      neteaseId = cleanInput;
    }

    if (neteaseId != null) {
      try {
        final u = Uri.parse('https://music.163.com/api/playlist/detail?id=$neteaseId');
        final r = await http.get(u, headers: _headers).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body);
          final res = j['result'];
          if (res != null) {
            final title = (res['name'] ?? '导入歌单').toString();
            final cover = (res['coverImgUrl'] ?? '').toString();
            final tracks = res['tracks'] as List? ?? [];
            final songs = <Song>[];
            for (final t in tracks) {
              final id = (t['id'] ?? '').toString();
              final name = (t['name'] ?? '未知曲目').toString();
              final artistsList = t['artists'] as List? ?? t['ar'] as List? ?? [];
              final artist = artistsList.map((a) => (a['name'] ?? '').toString()).where((s) => s.isNotEmpty).join(' / ');
              final album = (t['album']?['name'] ?? t['al']?['name'])?.toString() ?? '';
              final pic = (t['album']?['picUrl'] ?? t['al']?['picUrl'])?.toString() ?? '';
              final dur = ((int.tryParse((t['duration'] ?? t['dt'] ?? 0).toString()) ?? 0) ~/ 1000);
              songs.add(Song(
                id: id,
                name: name,
                artist: artist.isEmpty ? '未知歌手' : artist,
                album: album,
                source: '网易云',
                durationSeconds: dur,
                coverUrl: pic,
                quality: _neteaseQuality(t),
                isLossless: _neteaseQuality(t).contains('FLAC'),
              ));
            }
            return {
              'title': title,
              'name': title,
              'coverUrl': cover,
              'songs': songs,
              'platform': '网易云音乐',
            };
          }
        }
      } catch (_) {}
    }

    // 2. QQ音乐歌单解析
    if (cleanInput.contains('qq.com')) {
      final match = RegExp(r'id=(\d+)|playlist/(\d+)').firstMatch(cleanInput);
      final tid = match?.group(1) ?? match?.group(2);
      if (tid != null) {
        try {
          final u = Uri.parse('https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=$tid');
          final r = await http.get(u, headers: {
            ..._headers,
            'Referer': 'https://y.qq.com/',
          }).timeout(const Duration(seconds: 10));
          if (r.statusCode == 200) {
            final text = r.body;
            final cleanJson = text.replaceAll(RegExp(r'^\w+\('), '').replaceAll(RegExp(r'\)$'), '');
            final j = jsonDecode(cleanJson);
            final cd = (j['cdlist'] as List?)?.firstOrNull;
            if (cd != null) {
              final title = (cd['dissname'] ?? 'QQ音乐导入歌单').toString();
              final cover = (cd['logo'] ?? '').toString();
              final songlist = cd['songlist'] as List? ?? [];
              final songs = <Song>[];
              for (final s in songlist) {
                final mid = (s['songmid'] ?? '').toString();
                final name = (s['songname'] ?? '未知曲目').toString();
                final singerList = s['singer'] as List? ?? [];
                final artist = singerList.map((a) => (a['name'] ?? '').toString()).where((x) => x.isNotEmpty).join(' / ');
                final album = (s['albumname'] ?? '').toString();
                final albumMid = (s['albummid'] ?? '').toString();
                final pic = albumMid.isNotEmpty
                    ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg'
                    : '';
                final dur = int.tryParse((s['interval'] ?? 0).toString()) ?? 0;
                songs.add(Song(
                  id: mid,
                  name: name,
                  artist: artist.isEmpty ? '未知歌手' : artist,
                  album: album,
                  source: 'QQ音乐',
                  durationSeconds: dur,
                  coverUrl: pic,
                  quality: _qqQuality(s),
                  isLossless: _qqQuality(s).contains('FLAC'),
                ));
              }
              return {
                'title': title,
                'name': title,
                'coverUrl': cover,
                'songs': songs,
                'platform': 'QQ音乐',
              };
            }
          }
        } catch (_) {}
      }
    }

    return null;
  }
}
