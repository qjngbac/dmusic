import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'audio_inspector.dart';
import 'music_api.dart';

class CachedPlayback {
  final File file;
  final RealAudioInfo info;
  final Song song;
  final String key;
  final Future<void> Function() _release;
  bool _released = false;

  CachedPlayback._(this.file, this.info, this.song, this.key, this._release);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

class PlaybackCacheSource {
  final Uri uri;
  final String upstreamUrl;
  final Future<void> Function() _release;
  bool _released = false;

  PlaybackCacheSource._(this.uri, this.upstreamUrl, this._release);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

/// A playback-only loopback proxy. Each native GET supplies both the player and
/// its cache file; partial seeks are forwarded without assembling fragments.
class PlaybackCacheService {
  static final instance = PlaybackCacheService();
  static const defaultMaxBytes = 1024 * 1024 * 1024;
  static const unusedTtl = Duration(days: 7);

  final int maxBytes;
  final DateTime Function() _clock;
  Directory? _directory;
  Future<void>? _initialization;
  Future<void> _queue = Future.value();
  HttpServer? _server;
  Future<HttpServer>? _serverOpening;
  bool _disposed = false;
  DateTime? _lastCleanup;
  final _entries = <String, _Entry>{};
  final _invalidated = <String>{};
  final _pins = <String, int>{};
  final _sources = <String, _Source>{};
  final _writers = <String, _Writer>{};
  final _random = Random.secure();

  PlaybackCacheService({
    Directory? directory,
    this.maxBytes = defaultMaxBytes,
    DateTime Function()? clock,
    // Keep the injectable directory argument public while the field is private.
    // ignore: prefer_initializing_formals
  }) : _directory = directory,
       _clock = clock ?? DateTime.now {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  String _token() => List.generate(
    16,
    (_) => _random.nextInt(256),
  ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();

  String _identity(Song song) => sha256
      .convert(utf8.encode(jsonEncode([song.source, song.id])))
      .toString();

  File _file(String name) => File('${_directory!.path}/$name');

  static final _ownedName = RegExp(
    r'^[a-f0-9]{64}_[a-f0-9]{32}\.(part|mp3|flac|m4a|ogg|wav|aac|opus)$',
  );
  static final _indexTemp = RegExp(r'^index_[a-f0-9]{32}\.tmp$');

  Future<bool> _regularFile(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) ==
      FileSystemEntityType.file;

  Future<bool> _sameSize(File file, int size) async {
    try {
      return await _regularFile(file) && await file.length() == size;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _deleteOwned(String name) async {
    if (!_ownedName.hasMatch(name) && !_indexTemp.hasMatch(name)) return;
    final file = _file(name);
    if (await _regularFile(file)) await file.delete();
  }

  Future<void> _ensure() async {
    if (_disposed) throw StateError('Playback cache is disposed');
    await (_initialization ??= _initialize());
    // Mobile operating systems may purge the temporary directory at any time.
    final type = await FileSystemEntity.type(
      _directory!.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await _directory!.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Cache root must be a directory',
        _directory!.path,
      );
    }
  }

  Future<void> _initialize() async {
    _directory ??= Directory(
      '${(await getTemporaryDirectory()).path}/play_cache',
    );
    final type = await FileSystemEntity.type(
      _directory!.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await _directory!.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Cache root must be a directory',
        _directory!.path,
      );
    }
    final index = _file('index.json');
    if (await _regularFile(index)) {
      try {
        final data = jsonDecode(await index.readAsString());
        if (data is Map && data['version'] == 1 && data['entries'] is List) {
          for (final record in data['entries']) {
            final entry = _Entry.parse(record);
            if (entry != null &&
                _ownedName.hasMatch(entry.name) &&
                !entry.name.endsWith('.part') &&
                entry.name.startsWith('${entry.key}_')) {
              _entries[entry.key] = entry;
            }
          }
        }
      } catch (_) {
        // Cache metadata is expendable; malformed records never become paths.
      }
    } else if (await index.exists()) {
      throw FileSystemException(
        'Cache index must be a regular file',
        index.path,
      );
    }
    await _clean();
  }

  Future<void> _persist() async {
    final index = _file('index.json');
    final type = await FileSystemEntity.type(index.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException('Unsafe cache index', index.path);
    }
    final temporary = _file('index_${_token()}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'entries': _entries.values
              .where((e) => !_invalidated.contains(e.key))
              .map((e) => e.toJson())
              .toList(),
        }),
        flush: true,
      );
      await temporary.rename(index.path);
    } finally {
      if (await _regularFile(temporary)) await temporary.delete();
    }
  }

  bool _pinned(_Entry entry) =>
      (_pins[entry.key] ?? 0) > 0 ||
      _sources.values.any((source) => source.identity == entry.identity);

  int get _usedBytes =>
      _entries.values.fold(0, (sum, e) => sum + e.size) +
      _writers.values.fold(0, (sum, writer) => sum + writer.reserved);

  Future<void> _remove(_Entry entry) async {
    _entries.remove(entry.key);
    _invalidated.remove(entry.key);
    await _deleteOwned(entry.name);
  }

  Future<void> _removeInvalidated() async {
    var changed = false;
    for (final key in _invalidated.toList()) {
      final entry = _entries[key];
      if (entry != null && !_pinned(entry)) {
        await _remove(entry);
        changed = true;
      }
    }
    if (changed) await _persist();
  }

  Future<void> _periodicCleanup() async {
    final previous = _lastCleanup;
    if (previous == null ||
        _clock().difference(previous) >= const Duration(hours: 1)) {
      await _clean();
    }
  }

  Future<void> _trim(int incoming) async {
    if (_usedBytes + incoming <= maxBytes) return;
    final target = max(
      (maxBytes * .8).floor(),
      incoming +
          _writers.values.fold(0, (sum, writer) => sum + writer.reserved),
    );
    final candidates = _entries.values.where((e) => !_pinned(e)).toList()
      ..sort((a, b) => a.used.compareTo(b.used));
    for (final entry in candidates) {
      if (_usedBytes + incoming <= target) break;
      await _remove(entry);
    }
  }

  Future<void> _clean() async {
    final expiry = _clock().subtract(unusedTtl);
    for (final entry in _entries.values.toList()) {
      if (_pinned(entry)) continue;
      final file = _file(entry.name);
      if (_invalidated.contains(entry.key) ||
          entry.used.isBefore(expiry) ||
          !await _sameSize(file, entry.size)) {
        await _remove(entry);
      }
    }
    await _trim(0);
    final retained = _entries.values.map((e) => e.name).toSet()
      ..addAll(_writers.values.map((w) => w.name));
    await for (final item in _directory!.list(followLinks: false)) {
      final name = item.uri.pathSegments.last;
      if (!retained.contains(name)) await _deleteOwned(name);
    }
    await _persist();
    _lastCleanup = _clock();
  }

  Future<CachedPlayback?> find(
    Song song, {
    String targetQuality = '256k',
    bool forDownload = false,
  }) async {
    await _ensure();
    return _serial(() async {
      final identity = _identity(song);
      int rank(RealAudioInfo info) => forDownload
          ? (info.matchesQuality(targetQuality) ? 0 : 100)
          : _rank(info, targetQuality);
      final candidates =
          _entries.values.where((e) => e.identity == identity).toList()
            ..sort((a, b) => rank(a.info).compareTo(rank(b.info)));
      for (final entry in candidates) {
        if (_invalidated.contains(entry.key)) continue;
        if (!_pinned(entry) &&
            entry.used.isBefore(_clock().subtract(unusedTtl))) {
          await _remove(entry);
          continue;
        }
        if (rank(entry.info) >= 100) continue;
        final file = _file(entry.name);
        var intact = await _sameSize(file, entry.size);
        if (intact) {
          try {
            intact =
                (await sha256.bind(file.openRead()).first).toString() ==
                entry.digest;
          } on FileSystemException {
            intact = false;
          }
        }
        if (!intact) {
          if (!_pinned(entry)) await _remove(entry);
          continue;
        }
        final info = await AudioInspector.inspect(file);
        if (!info.isValid ||
            info.hasVideo ||
            !info.matchesDuration(song.durationSeconds) ||
            rank(info) >= 100) {
          if (!_pinned(entry)) await _remove(entry);
          continue;
        }
        entry.used = _clock();
        await _persist();
        _pins[entry.key] = (_pins[entry.key] ?? 0) + 1;
        return CachedPlayback._(
          file,
          info,
          _withInfo(song, info),
          entry.key,
          () => _serial(() async {
            final count = (_pins[entry.key] ?? 1) - 1;
            if (count <= 0) {
              _pins.remove(entry.key);
            } else {
              _pins[entry.key] = count;
            }
            await _removeInvalidated();
          }),
        );
      }
      await _persist();
      return null;
    });
  }

  static int _rank(RealAudioInfo info, String quality) {
    if (!info.isValid || info.hasVideo) return 100;
    switch (quality.toLowerCase()) {
      case '256k':
        if (!info.isLossless &&
            info.bitrateKbps >= 240 &&
            info.bitrateKbps < 300) {
          return 0;
        }
        if (!info.isLossless && info.bitrateKbps >= 300) return 1;
        if (info.isLossless) return 2;
        return 100;
      case '320k':
        if (!info.isLossless && info.bitrateKbps >= 300) return 0;
        return info.isLossless ? 1 : 100;
      case '128k':
        return info.isLossless || info.bitrateKbps >= 120 ? 0 : 100;
      case 'flac':
        return info.isLossless ? 0 : 100;
      case '':
        return 0;
      default:
        return 100;
    }
  }

  static Song _withInfo(Song song, RealAudioInfo info) => song.copyWith(
    quality: info.qualityLabel,
    size: info.sizeMb,
    isLossless: info.isLossless,
    fileSizeBytes: info.fileSizeBytes,
    audioUrl: null,
    audioUrlTimestamp: null,
    audioUrlQuality: null,
    audioUrlSource: null,
    localFilePath: null,
    lrcPath: null,
    downloadTime: null,
  );

  Future<PlaybackCacheSource> createSource(
    Song song,
    String upstreamUrl,
  ) async {
    // Construct in the caller's Zone, where runWithClient test injection lives.
    final client = http.Client();
    try {
      final upstream = Uri.parse(upstreamUrl);
      if ((upstream.scheme != 'http' && upstream.scheme != 'https') ||
          upstream.host.isEmpty ||
          upstream.userInfo.isNotEmpty) {
        throw ArgumentError.value(upstreamUrl, 'upstreamUrl');
      }
      await _ensure();
      await _serial(_periodicCleanup);
      final server = await (_serverOpening ??=
          HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
            _server = server;
            server.listen((request) {
              unawaited(_serve(request));
            });
            return server;
          }));
      if (_disposed) throw StateError('Playback cache is disposed');
      final token = _token();
      final source = _Source(
        song.copyWith(),
        _identity(song),
        upstream,
        client,
      );
      _sources[token] = source;
      final uri = Uri.parse('http://127.0.0.1:${server.port}/$token');
      return PlaybackCacheSource._(
        uri,
        upstreamUrl,
        () => _releaseSource(token),
      );
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  Future<void> _releaseSource(String token) async {
    final source = _sources.remove(token);
    if (source == null) return;
    source.released = true;
    for (final transfer in source.transfers.toList()) {
      final writer = transfer.writer;
      if (writer == null || writer.received != writer.reserved) {
        transfer.cancel();
      }
    }
    await Future.wait(source.transfers.map((t) => t.done.future));
    source.client.close();
    await _serial(_removeInvalidated);
  }

  Future<_Writer?> _beginWriter(_Source source, int? total) =>
      _serial(() async {
        if (source.released ||
            total == null ||
            total <= 0 ||
            total > maxBytes ||
            _writers.containsKey(source.identity)) {
          return null;
        }
        await _trim(total);
        if (_usedBytes + total > maxBytes) return null;
        final writer = _Writer('${source.identity}_${_token()}.part', total);
        _writers[source.identity] = writer;
        try {
          writer.handle = await _file(writer.name).open(mode: FileMode.write);
          await _persist();
          return writer;
        } catch (_) {
          _writers.remove(source.identity);
          await writer.handle?.close();
          await _deleteOwned(writer.name);
          return null;
        }
      });

  static int? _wholeLength(http.StreamedResponse response) {
    if (response.headers['content-encoding'] != null &&
        response.headers['content-encoding']!.toLowerCase() != 'identity') {
      return null;
    }
    if (response.statusCode == 200) return response.contentLength;
    if (response.statusCode != 206) return null;
    final match = RegExp(
      r'^bytes 0-(\d+)/(\d+)$',
    ).firstMatch(response.headers['content-range'] ?? '');
    if (match == null) return null;
    final total = int.tryParse(match.group(2)!);
    final end = int.tryParse(match.group(1)!);
    return total != null &&
            end == total - 1 &&
            (response.contentLength == null || response.contentLength == total)
        ? total
        : null;
  }

  Future<void> _serve(HttpRequest request) async {
    final source = _sources[request.uri.path.substring(1)];
    if (source == null ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      request.response.statusCode = source == null ? 404 : 405;
      await request.response.close();
      return;
    }
    final transfer = _Transfer(request.response);
    source.transfers.add(transfer);
    _Writer? writer;
    var complete = false;
    request.response.done.then(
      (_) {
        transfer.cancel();
      },
      onError: (Object _) {
        transfer.cancel();
      },
    );
    try {
      final outgoing = http.AbortableRequest(
        request.method,
        source.upstream,
        abortTrigger: transfer.abort.future,
      );
      outgoing.headers.addAll(
        MusicApi.audioHeaders(source.upstream.toString()),
      );
      outgoing.headers['accept-encoding'] = 'identity';
      for (final name in [
        'range',
        'if-range',
        'if-none-match',
        'if-modified-since',
      ]) {
        final value = request.headers.value(name);
        if (value != null) outgoing.headers[name] = value;
      }
      final response = await source.client.send(outgoing);
      request.response.statusCode = response.statusCode;
      for (final name in [
        'content-type',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
        'content-encoding',
        'cache-control',
      ]) {
        final value = response.headers[name];
        if (value != null) request.response.headers.set(name, value);
      }
      if (response.contentLength != null) {
        request.response.contentLength = response.contentLength!;
      }
      if (request.method == 'HEAD') {
        await response.stream.drain<void>();
      } else {
        try {
          writer = await _beginWriter(source, _wholeLength(response));
        } catch (_) {
          /* Cache I/O must not interrupt playback. */
        }
        transfer.writer = writer;
        var reachedEof = true;
        await for (final chunk in response.stream) {
          if (source.released || transfer.cancelled) {
            reachedEof = false;
            break;
          }
          if (writer != null) {
            writer.received += chunk.length;
            if (writer.received > writer.reserved) {
              try {
                await writer.handle?.close();
              } catch (_) {}
              writer.handle = null;
            } else if (writer.handle != null) {
              try {
                await writer.handle!.writeFrom(chunk);
              } catch (_) {
                try {
                  await writer.handle?.close();
                } catch (_) {}
                writer.handle = null;
              }
            }
          }
          request.response.add(chunk);
          await request.response.flush();
        }
        complete = reachedEof && !transfer.cancelled;
      }
      if (writer != null) {
        try {
          await _finishWriter(source, writer, complete);
        } catch (_) {}
      }
      writer = null;
      await request.response.close();
    } catch (_) {
      transfer.cancel();
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      try {
        if (writer != null) await _finishWriter(source, writer, false);
      } catch (_) {
        // Startup cleanup removes any part left after filesystem failures.
      } finally {
        source.transfers.remove(transfer);
        if (!transfer.done.isCompleted) transfer.done.complete();
      }
    }
  }

  Future<void> _finishWriter(
    _Source source,
    _Writer writer,
    bool complete,
  ) async {
    final hadHandle = writer.handle != null;
    try {
      await writer.handle?.close();
    } catch (_) {
      complete = false;
    }
    writer.handle = null;
    await _serial(() async {
      try {
        if (!complete || !hadHandle || writer.received != writer.reserved) {
          return;
        }
        final part = _file(writer.name);
        if (!await _regularFile(part)) return;
        final info = await AudioInspector.inspect(part);
        if (!info.isValid ||
            info.hasVideo ||
            !info.matchesDuration(source.song.durationSeconds)) {
          return;
        }
        final extension = info.realExtension.toLowerCase();
        if (![
          'mp3',
          'flac',
          'm4a',
          'ogg',
          'wav',
          'aac',
          'opus',
        ].contains(extension)) {
          return;
        }
        final quality = info.isLossless ? 'lossless' : '${info.bitrateKbps}k';
        final key = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  source.song.source,
                  source.song.id,
                  info.format,
                  quality,
                ]),
              ),
            )
            .toString();
        // Another request may finish while a pinned existing entry is playing.
        final old = _entries[key];
        if (_invalidated.contains(key)) return;
        if (old != null && _pinned(old)) return;
        final digest = (await sha256.bind(part.openRead()).first).toString();
        final name = '${key}_${_token()}.$extension';
        await part.rename(_file(name).path);
        final entry = _Entry(
          key,
          source.identity,
          name,
          writer.received,
          digest,
          _clock(),
          _withInfo(source.song, info),
          info,
        );
        _entries[key] = entry;
        try {
          await _persist();
        } catch (_) {
          if (old == null) {
            _entries.remove(key);
          } else {
            _entries[key] = old;
          }
          await _deleteOwned(name);
          rethrow;
        }
        if (old != null) await _deleteOwned(old.name);
      } finally {
        _writers.remove(source.identity);
        await _deleteOwned(writer.name);
        await _periodicCleanup();
      }
    });
  }

  Future<void> invalidate(String key) async {
    await _ensure();
    await _serial(() async {
      final entry = _entries[key];
      if (entry != null) {
        _invalidated.add(key);
        if (!_pinned(entry)) await _remove(entry);
      }
      await _persist();
    });
  }

  Future<void> cleanup() async {
    await _ensure();
    await _serial(_clean);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait(_sources.keys.toList().map(_releaseSource));
    await _queue;
    if (_serverOpening != null) {
      try {
        await _serverOpening;
      } catch (_) {}
    }
    await _server?.close(force: true);
  }
}

class _Source {
  final Song song;
  final String identity;
  final Uri upstream;
  final http.Client client;
  final transfers = <_Transfer>{};
  bool released = false;
  _Source(this.song, this.identity, this.upstream, this.client);
}

class _Transfer {
  final HttpResponse response;
  final abort = Completer<void>();
  final done = Completer<void>();
  bool cancelled = false;
  _Writer? writer;
  _Transfer(this.response);
  void cancel() {
    cancelled = true;
    if (!abort.isCompleted) abort.complete();
  }
}

class _Writer {
  final String name;
  final int reserved;
  RandomAccessFile? handle;
  int received = 0;
  _Writer(this.name, this.reserved);
}

class _Entry {
  final String key, identity, name, digest;
  final int size;
  DateTime used;
  final Song song;
  final RealAudioInfo info;
  _Entry(
    this.key,
    this.identity,
    this.name,
    this.size,
    this.digest,
    this.used,
    this.song,
    this.info,
  );

  Map<String, Object?> toJson() => {
    'key': key,
    'identity': identity,
    'file': name,
    'size': size,
    'digest': digest,
    'used': used.toIso8601String(),
    'song': song.toJson(),
    'info': {
      'format': info.format,
      'qualityLabel': info.qualityLabel,
      'isLossless': info.isLossless,
      'fileSizeBytes': info.fileSizeBytes,
      'bitrateKbps': info.bitrateKbps,
      'realExtension': info.realExtension,
      'isValid': info.isValid,
      'durationSeconds': info.durationSeconds,
      'sampleRate': info.sampleRate,
      'bitsPerSample': info.bitsPerSample,
      'channels': info.channels,
      'hasVideo': info.hasVideo,
    },
  };

  static _Entry? parse(dynamic record) {
    try {
      if (record is! Map) return null;
      final key = record['key'] as String;
      final identity = record['identity'] as String;
      final digest = record['digest'] as String;
      if (![
        key,
        identity,
        digest,
      ].every((s) => RegExp(r'^[a-f0-9]{64}$').hasMatch(s))) {
        return null;
      }
      final size = record['size'] as int;
      if (size <= 0) return null;
      final data = Map<String, dynamic>.from(record['info'] as Map);
      final info = RealAudioInfo(
        format: data['format'] as String,
        qualityLabel: data['qualityLabel'] as String,
        isLossless: data['isLossless'] == true,
        fileSizeBytes: data['fileSizeBytes'] as int,
        bitrateKbps: data['bitrateKbps'] as int,
        realExtension: data['realExtension'] as String,
        isValid: data['isValid'] == true,
        durationSeconds: data['durationSeconds'] as int,
        sampleRate: data['sampleRate'] as int,
        bitsPerSample: data['bitsPerSample'] as int,
        channels: data['channels'] as int,
        hasVideo: data['hasVideo'] == true,
      );
      if (!info.isValid || info.hasVideo || info.fileSizeBytes != size) {
        return null;
      }
      final song = Song.fromJson(
        Map<String, dynamic>.from(record['song'] as Map),
      );
      return _Entry(
        key,
        identity,
        record['file'] as String,
        size,
        digest,
        DateTime.parse(record['used'] as String),
        song,
        info,
      );
    } catch (_) {
      return null;
    }
  }
}
