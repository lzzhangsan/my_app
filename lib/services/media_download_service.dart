import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

import '../models/media_type.dart';
import 'database_service.dart';
import 'logger.dart';
import '../core/service_locator.dart';

/// HLS 单分片任务（解析 playlist 后用于并行拉取）。
class _HlsSegTask {
  _HlsSegTask({
    required this.url,
    required this.mediaSeq,
    required this.useAes128,
    this.aesKey,
    this.explicitIv,
  });
  final String url;
  final int mediaSeq;
  final bool useAes128;
  final Uint8List? aesKey;
  final Uint8List? explicitIv;
}

typedef DownloadProgressCallback = void Function(double fraction, {String? detail});

class MediaDownloadService {
  static final MediaDownloadService _instance = MediaDownloadService._internal();
  factory MediaDownloadService() => _instance;
  MediaDownloadService._internal();

  static const int _kHlsParallelSegmentFetches = 10;
  static const int _kHlsMaxConnectionsPerHost = 24;
  static const int _kMd5IsolateThresholdBytes = 4 * 1024 * 1024;
  static const int _kParallelRangeVideoMinBytes = 3 * 1024 * 1024;
  static const int _kParallelRangeVideoConnections = 6;

  final DatabaseService _databaseService = getService<DatabaseService>();

  Dio _createDownloadDio({
    Duration? connectTimeout,
    Duration? receiveTimeout,
    bool forVideoDownload = false,
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: connectTimeout ?? const Duration(seconds: 15),
        receiveTimeout: receiveTimeout ?? (forVideoDownload ? const Duration(seconds: 60) : const Duration(seconds: 30)),
        sendTimeout: const Duration(seconds: 15),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) => true;
      if (forVideoDownload) {
        client.maxConnectionsPerHost = _kHlsMaxConnectionsPerHost;
        client.idleTimeout = const Duration(seconds: 90);
      }
      return client;
    };
    return dio;
  }

  Future<File?> downloadFile(
    String url,
    MediaType mediaType, {
    required String referer,
    required String userAgent,
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
  }) async {
    try {
      final downloadUrl = _getCleanMediaUrl(url);
      final downloadDio = mediaType == MediaType.image
          ? _createDownloadDio(connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 10))
          : _createDownloadDio(forVideoDownload: true);

      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      final uuid = const Uuid().v4();
      String extension = _getFileExtension(url);

      if (extension.isEmpty) {
        final mimeType = _guessMimeType(url);
        extension = _getExtensionFromMime(mimeType, mediaType);
      }

      final filePath = '${mediaDir.path}/$uuid$extension';
      final headers = {
        'User-Agent': userAgent,
        'Referer': referer,
        'Accept': '*/*',
        if (referer.startsWith('http')) 'Origin': Uri.tryParse(referer)?.origin ?? referer,
      };

      if (mediaType == MediaType.video && _supportsParallelRange(extension) && extension != '.m3u8' && extension != '.m3u') {
        final parallelFile = await _tryParallelRangeDownload(
          downloadDio: downloadDio,
          url: downloadUrl,
          filePath: filePath,
          headers: headers,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
        if (parallelFile != null) return parallelFile;
      }

      await downloadDio.download(
        downloadUrl,
        filePath,
        deleteOnError: true,
        cancelToken: cancelToken,
        options: Options(
          headers: headers,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status >= 200 && status < 300,
        ),
        onReceiveProgress: (received, total) {
          if (onProgress == null) return;
          if (extension == '.m3u8' || extension == '.m3u') {
            onProgress(0.01, detail: '正在获取播放列表...');
          } else if (total > 0) {
            onProgress(received / total, detail: '${_formatBytes(received)} / ${_formatBytes(total)}');
          }
        },
      );

      if (extension == '.m3u8' || extension == '.m3u') {
        final merged = await handleM3u8Download(filePath, downloadUrl, downloadDio, onMergeProgress: onProgress);
        if (await File(filePath).exists()) await File(filePath).delete();
        return merged;
      }

      return File(filePath);
    } catch (e) {
      Logger.log('Download failed: $e');
      rethrow;
    }
  }

  Future<File?> handleM3u8Download(
    String m3u8Path,
    String pageUrl,
    Dio client, {
    DownloadProgressCallback? onMergeProgress,
  }) async {
    String content = await File(m3u8Path).readAsString();
    Uri baseUri = Uri.parse(pageUrl);

    final lines = content.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (lines.any((l) => l.contains('EXT-X-STREAM-INF'))) {
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('EXT-X-STREAM-INF') && i + 1 < lines.length && !lines[i + 1].startsWith('#')) {
          final nextUrl = lines[i + 1].startsWith('http') ? lines[i + 1] : baseUri.resolve(lines[i + 1]).toString();
          return handleM3u8Download(m3u8Path, nextUrl, client, onMergeProgress: onMergeProgress);
        }
      }
    }

    final outputPath = p.setExtension(m3u8Path, '.ts');
    final outFile = File(outputPath);
    final sink = outFile.openWrite();
    final tasks = await _parseHlsTasks(lines, baseUri, client);

    if (tasks == null || tasks.isEmpty) {
      await sink.close();
      return null;
    }

    var mergedBytes = 0;
    for (var i = 0; i < tasks.length; i += _kHlsParallelSegmentFetches) {
      final end = min(i + _kHlsParallelSegmentFetches, tasks.length);
      final batch = tasks.sublist(i, end);
      final raws = await Future.wait(batch.map((t) => _downloadSegment(client, t.url)));

      for (var j = 0; j < batch.length; j++) {
        final raw = raws[j];
        if (raw == null) {
          await sink.close();
          return null;
        }
        final t = batch[j];
        var data = raw;
        if (t.useAes128 && t.aesKey != null) {
          final iv = t.explicitIv ?? _hlsIvFromSeq(t.mediaSeq);
          data = _decryptAes128(t.aesKey!, iv, raw);
        }
        sink.add(data);
        mergedBytes += data.length;
        onMergeProgress?.call((i + j + 1) / tasks.length, detail: 'HLS 分片 ${i + j + 1}/${tasks.length} · 已合并 ${_formatBytes(mergedBytes)}');
      }
    }

    await sink.close();
    return outFile;
  }

  Future<List<_HlsSegTask>?> _parseHlsTasks(List<String> lines, Uri baseUri, Dio client) async {
    final tasks = <_HlsSegTask>[];
    Uint8List? aesKey;
    Uint8List? explicitIv;
    bool useAes128 = false;
    int seq = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        seq = int.tryParse(line.substring(22)) ?? 0;
      } else if (line.startsWith('#EXT-X-KEY')) {
        if (line.contains('METHOD=AES-128')) {
          final uri = RegExp(r'URI="([^"]+)"').firstMatch(line)?.group(1);
          if (uri != null) {
            final keyUrl = uri.startsWith('http') ? uri : baseUri.resolve(uri).toString();
            final resp = await client.get<List<int>>(keyUrl, options: Options(responseType: ResponseType.bytes));
            aesKey = Uint8List.fromList(resp.data!);
            useAes128 = true;
            final ivHex = RegExp(r'IV=0x([0-9a-fA-F]+)').firstMatch(line)?.group(1);
            if (ivHex != null) explicitIv = _hexToBytes(ivHex);
          }
        }
      } else if (line.startsWith('#EXTINF')) {
        final url = lines[++i];
        tasks.add(_HlsSegTask(
          url: url.startsWith('http') ? url : baseUri.resolve(url).toString(),
          mediaSeq: seq++,
          useAes128: useAes128,
          aesKey: aesKey,
          explicitIv: explicitIv,
        ));
      }
    }
    return tasks;
  }

  Future<Uint8List?> _downloadSegment(Dio client, String url) async {
    try {
      final r = await client.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      return Uint8List.fromList(r.data!);
    } catch (_) {
      return null;
    }
  }

  Uint8List _decryptAes128(Uint8List key, Uint8List iv, Uint8List data) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.cbc));
    return Uint8List.fromList(encrypter.decryptBytes(enc.Encrypted(data), iv: enc.IV(iv)));
  }

  Uint8List _hlsIvFromSeq(int seq) {
    final iv = Uint8List(16);
    for (var i = 0; i < 4; i++) {
      iv[15 - i] = (seq >> (i * 8)) & 0xff;
    }
    return iv;
  }

  Uint8List _hexToBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(
        hex.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
    }
    return bytes;
  }

  Future<File?> _tryParallelRangeDownload({
    required Dio downloadDio,
    required String url,
    required String filePath,
    required Map<String, String> headers,
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
  }) async {
    try {
      final head = await downloadDio.head(url, options: Options(headers: headers));
      final total = int.tryParse(head.headers.value('content-length') ?? '');
      if (total == null || total < _kParallelRangeVideoMinBytes) return null;

      final parts = _kParallelRangeVideoConnections;
      final chunkSize = (total / parts).ceil();
      final partPaths = List.generate(parts, (i) => '$filePath.part$i');
      final progresses = List.filled(parts, 0);

      await Future.wait(List.generate(parts, (i) async {
        final start = i * chunkSize;
        final end = min(start + chunkSize - 1, total - 1);
        final sink = File(partPaths[i]).openWrite();
        final resp = await downloadDio.get<ResponseBody>(
          url,
          options: Options(headers: {...headers, 'Range': 'bytes=$start-$end'}, responseType: ResponseType.stream),
          cancelToken: cancelToken,
        );
        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          progresses[i] += chunk.length;
          final sum = progresses.reduce((a, b) => a + b);
          onProgress?.call(sum / total, detail: '多连接 ${_formatBytes(sum)} / ${_formatBytes(total)}');
        }
        await sink.close();
      }));

      final out = File(filePath).openWrite();
      for (final p in partPaths) {
        await out.addStream(File(p).openRead());
        await File(p).delete();
      }
      await out.close();
      return File(filePath);
    } catch (_) {
      return null;
    }
  }

  String _getCleanMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.query.contains('x-bce-process') || uri.query.contains('image/')) {
      return uri.replace(query: '').toString();
    }
    return url;
  }

  String _getFileExtension(String path) {
    final dot = path.lastIndexOf('.');
    return dot != -1 ? path.substring(dot) : '';
  }

  String _getExtensionFromMime(String mime, MediaType type) {
    if (mime.startsWith('image/')) return mime == 'image/png' ? '.png' : (mime == 'image/gif' ? '.gif' : '.jpg');
    if (mime.startsWith('video/')) return '.mp4';
    if (mime.startsWith('audio/')) return '.mp3';
    return type == MediaType.image ? '.jpg' : (type == MediaType.video ? '.mp4' : '.bin');
  }

  String _guessMimeType(String url) {
    final path = url.toLowerCase();
    if (path.contains('.jpg') || path.contains('.jpeg')) return 'image/jpeg';
    if (path.contains('.png')) return 'image/png';
    if (path.contains('.gif')) return 'image/gif';
    if (path.contains('.mp4')) return 'video/mp4';
    if (path.contains('.m3u8')) return 'application/x-mpegURL';
    return 'application/octet-stream';
  }

  bool _supportsParallelRange(String ext) {
    return ['.mp4', '.webm', '.mov', '.mkv'].contains(ext.toLowerCase());
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<String> calculateMd5(File file) async {
    final size = await file.length();
    if (size < _kMd5IsolateThresholdBytes) {
      return md5.convert(await file.readAsBytes()).toString();
    }
    return await Isolate.run(() async {
      final bytes = await file.readAsBytes();
      return md5.convert(bytes).toString();
    });
  }

  Future<Map<String, dynamic>> saveToMediaLibrary(File file, MediaType mediaType, {String? name}) async {
    final fileName = name ?? p.basename(file.path);
    final fileHash = await calculateMd5(file);
    
    // 检查重复
    final existing = await _databaseService.findDuplicateMediaItem(fileHash, fileName);
    if (existing != null) return existing;

    final item = {
      'id': const Uuid().v4(),
      'name': fileName,
      'path': file.path,
      'type': mediaType.index,
      'file_hash': fileHash,
      'date_added': DateTime.now().toIso8601String(),
      'directory': 'root',
    };
    await _databaseService.insertMediaItem(item);
    return item;
  }
}
