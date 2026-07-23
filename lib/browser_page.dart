import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' show min, max;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as p;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:video_thumbnail/video_thumbnail.dart';

import 'core/service_locator.dart';
import 'services/database_service.dart';
import 'utils/export_import_error_utils.dart';
import 'utils/media_download_utils.dart';
import 'models/media_item.dart';
import 'models/media_type.dart';
import 'media_manager_page.dart';
import 'media_preview_page.dart';
import 'widgets/safe_modal_sheet_body.dart';
import 'services/logger.dart';
import 'services/network_service.dart';

bool _hasUsefulRasterContent(Uint8List bytes) {
  final image = image_lib.decodeImage(bytes);
  if (image == null || image.width < 120 || image.height < 90) return false;
  const grid = 32;
  var visible = 0;
  var sum = 0.0;
  var sumSquares = 0.0;
  var minLuma = 255.0;
  var maxLuma = 0.0;
  final colors = <int, int>{};
  for (var gy = 0; gy < grid; gy++) {
    final y = min(image.height - 1, (gy * image.height / grid).floor());
    for (var gx = 0; gx < grid; gx++) {
      final x = min(image.width - 1, (gx * image.width / grid).floor());
      final pixel = image.getPixel(x, y);
      final alpha = pixel.a.toDouble();
      if (alpha < 24) continue;
      final red = pixel.r.toDouble();
      final green = pixel.g.toDouble();
      final blue = pixel.b.toDouble();
      final luma = red * 0.2126 + green * 0.7152 + blue * 0.0722;
      visible++;
      sum += luma;
      sumSquares += luma * luma;
      minLuma = min(minLuma, luma);
      maxLuma = max(maxLuma, luma);
      final bucket = ((red ~/ 32) << 6) | ((green ~/ 32) << 3) | (blue ~/ 32);
      colors[bucket] = (colors[bucket] ?? 0) + 1;
    }
  }
  if (visible < grid * grid * 0.2) return false;
  final mean = sum / visible;
  final variance = max(0.0, sumSquares / visible - mean * mean);
  final dominant = colors.values.fold<int>(0, max) / visible;
  return maxLuma - minLuma >= 10 && variance >= 18 && dominant < 0.985;
}

/// HLS 单分片任务（解析 playlist 后用于并行拉取）。
class _HlsSegTask {
  _HlsSegTask({
    required this.url,
    required this.mediaSeq,
    required this.useAes128,
    this.aesKey,
    this.explicitIv,
    this.rangeStart,
    this.rangeEnd,
    this.fallbackUrl,
  });
  final String url;
  final int mediaSeq;
  final bool useAes128;
  final Uint8List? aesKey;
  final int? rangeStart;
  final int? rangeEnd;
  final String? fallbackUrl;

  /// 来自 #EXT-X-KEY；为 null 时用 [mediaSeq] 生成 IV。
  final Uint8List? explicitIv;
}

class _CapturedWebResource {
  const _CapturedWebResource({
    required this.url,
    required this.initiatorType,
    required this.pageUrl,
    required this.capturedAt,
  });

  final String url;
  final String initiatorType;
  final String pageUrl;
  final DateTime capturedAt;
}

class _DashTrackPlan {
  const _DashTrackPlan({
    required this.mimeType,
    required this.codecs,
    required this.bandwidth,
    required this.initializationUrl,
    required this.segmentUrls,
  });

  final String mimeType;
  final String codecs;
  final int bandwidth;
  final String initializationUrl;
  final List<String> segmentUrls;
}

/// 同时发起的 HLS 分片 HTTP 请求数（需 ≤ [ _kHlsMaxConnectionsPerHost ]，过大易被 CDN 限流）。
const int _kHlsParallelSegmentFetches = 10;

/// DASH 单轨最大并发数；音视频轨会同时下载，合计仍低于单主机连接上限。
const int _kDashParallelSegmentFetches = 10;

/// 单主机最大并行连接数，应 ≥ 分片并行数，否则多余请求会在客户端排队。
const int _kHlsMaxConnectionsPerHost = 24;

/// 超过此大小的文件在独立 Isolate 中计算 MD5，减轻下载完成后主线程长时间卡顿。
const int _kMd5IsolateThresholdBytes = 4 * 1024 * 1024;

/// 单文件视频（mp4/webm 等）启用 HTTP Range 多连接并行下载的最小体积。
const int _kParallelRangeVideoMinBytes = 3 * 1024 * 1024;

/// 并行分片数（与 [ _kHlsMaxConnectionsPerHost ] 类似，过大易被 CDN 限流）。
const int _kParallelRangeVideoConnections = 6;

/// 下载进度：`fraction` 为 0~1；`detail` 为可选说明（如 HLS 分片、已下字节）。
typedef DownloadProgressCallback =
    void Function(double fraction, {String? detail});

/// 保存到媒体库的 SnackBar 时长（缩短展示时间，减少遮挡）
const Duration _kMediaSaveSnackDuration = Duration(seconds: 2);

/// 同一 HTTP(S) 媒体 URL 在内存中的「占用」超时：超过后允许再次进入下载（防止 finally 未跑导致永久无法重下）
const Duration _kMediaUrlInFlightTtl = Duration(seconds: 45);

/// MediaRecorder fallback may emit a tiny container with no playable frames when
/// the page blocks capture. Do not import that as a black, unplayable video.
const int _kMinBase64VideoBytes = 16 * 1024;

const int _kMaxCapturedWebResources = 600;

const String _kBrowserMediaUserAgent =
    'Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

const String _kEarlyMediaSnifferScript = r'''
(() => {
  if (window.__appEarlyMediaSnifferInstalled) return;
  window.__appEarlyMediaSnifferInstalled = true;
  window.__appEarlyMediaRequests = window.__appEarlyMediaRequests || new Map();
  const mediaHosts = [String(location.hostname || '').toLowerCase()];
  try {
    if (document.referrer) {
      mediaHosts.push(String(new URL(document.referrer).hostname || '').toLowerCase());
    }
  } catch (_) {}
  const isElementBoundFeedPage = mediaHosts.some(mediaHost =>
    mediaHost === 'tik.porn' || mediaHost.endsWith('.tik.porn') ||
    mediaHost === 'pin.porn' || mediaHost.endsWith('.pin.porn'));
  const mediaBufferUrls = new WeakMap();
  const sourceBufferOwners = new WeakMap();
  const mediaSourceByBlobUrl = new Map();
  const mediaSourceActivity = new WeakMap();
  const videoRequestActivity = new WeakMap();
  const videoRequestState = new WeakMap();
  let latestMediaBuffer = null;

  const bindRequestToVisibleVideo = (url) => {
    if (!isElementBoundFeedPage || !url) return;
    try {
      const videos = Array.from(document.querySelectorAll('video'));
      const vw = Math.max(1, window.innerWidth || 1);
      const vh = Math.max(1, window.innerHeight || 1);
      const cx = vw / 2;
      const cy = vh / 2;
      let best = null;
      let bestScore = -Infinity;
      for (const video of videos) {
        const rect = video.getBoundingClientRect();
        const visibleW = Math.max(0, Math.min(rect.right, vw) - Math.max(rect.left, 0));
        const visibleH = Math.max(0, Math.min(rect.bottom, vh) - Math.max(rect.top, 0));
        const visibleArea = visibleW * visibleH;
        if (visibleArea <= 0) continue;
        const vx = (Math.max(rect.left, 0) + Math.min(rect.right, vw)) / 2;
        const vy = (Math.max(rect.top, 0) + Math.min(rect.bottom, vh)) / 2;
        let score = visibleArea - Math.hypot(vx - cx, vy - cy) * 500;
        if (!video.paused && !video.ended) score += 1000000000;
        if (Number(video.currentTime || 0) > 0) score += 10000000;
        if (score > bestScore) {
          bestScore = score;
          best = video;
        }
      }
      if (!best) return;
      let activity = videoRequestActivity.get(best);
      const sourceIdentity = String(best.currentSrc || best.src || '');
      const currentTime = Number(best.currentTime || 0);
      const previousState = videoRequestState.get(best);
      const sourceChanged = previousState && sourceIdentity &&
        previousState.sourceIdentity && sourceIdentity !== previousState.sourceIdentity;
      const playbackRestarted = previousState && isFinite(currentTime) &&
        currentTime + 0.75 < previousState.currentTime;
      if (sourceChanged || playbackRestarted) {
        const nextActivity = new Map();
        const now = Date.now();
        // Some players fetch the next manifest immediately before swapping
        // the reused video element. Carry only very recent whole-media URLs
        // across that boundary; old manifests and all old segments are lost.
        if (activity) {
          for (const [candidate, stats] of activity.entries()) {
            const value = String(candidate || '').toLowerCase();
            const isWholeMedia = /\.(m3u8|m3u|mpd|mp4|webm|mov)(\?|#|$)/.test(value) &&
              !/[?&](range|sq|rn|rbuf)=/.test(value);
            if (isWholeMedia && now - Number(stats.latest || 0) <= 8000) {
              nextActivity.set(candidate, stats);
            }
          }
        }
        activity = nextActivity;
        videoRequestActivity.set(best, activity);
      }
      if (!activity) {
        activity = new Map();
        videoRequestActivity.set(best, activity);
      }
      videoRequestState.set(best, {
        sourceIdentity,
        currentTime: isFinite(currentTime) ? currentTime : 0,
        updatedAt: Date.now()
      });
      const previous = activity.get(url) || { count: 0, latest: 0 };
      activity.set(url, { count: previous.count + 1, latest: Date.now() });
      if (activity.size > 80) {
        const oldest = Array.from(activity.entries())
          .sort((a, b) => a[1].latest - b[1].latest)
          .slice(0, activity.size - 80);
        for (const entry of oldest) activity.delete(entry[0]);
      }
    } catch (_) {}
  };

  const rememberMediaBuffer = (buffer, rawUrl) => {
    if (!isElementBoundFeedPage || !buffer || !rawUrl || typeof buffer !== 'object') return;
    try {
      const url = new URL(String(rawUrl), location.href).toString();
      mediaBufferUrls.set(buffer, url);
      if (ArrayBuffer.isView(buffer) && buffer.buffer) {
        mediaBufferUrls.set(buffer.buffer, url);
      }
      latestMediaBuffer = { url, timestamp: Date.now() };
    } catch (_) {}
  };
  window.__appRememberMediaBuffer = rememberMediaBuffer;

  if (isElementBoundFeedPage) {
    try {
      const originalCreateObjectURL = URL.createObjectURL;
      URL.createObjectURL = function(object) {
        const blobUrl = originalCreateObjectURL.apply(this, arguments);
        try {
          if (typeof MediaSource !== 'undefined' && object instanceof MediaSource) {
            mediaSourceByBlobUrl.set(blobUrl, object);
          }
        } catch (_) {}
        return blobUrl;
      };
      const originalRevokeObjectURL = URL.revokeObjectURL;
      URL.revokeObjectURL = function(url) {
        try { mediaSourceByBlobUrl.delete(String(url)); } catch (_) {}
        return originalRevokeObjectURL.apply(this, arguments);
      };
    } catch (_) {}

    try {
      const originalAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function() {
        const sourceBuffer = originalAddSourceBuffer.apply(this, arguments);
        try { sourceBufferOwners.set(sourceBuffer, this); } catch (_) {}
        return sourceBuffer;
      };
      const originalAppendBuffer = SourceBuffer.prototype.appendBuffer;
      SourceBuffer.prototype.appendBuffer = function(buffer) {
        try {
          const owner = sourceBufferOwners.get(this);
          let url = mediaBufferUrls.get(buffer);
          if (!url && ArrayBuffer.isView(buffer) && buffer.buffer) {
            url = mediaBufferUrls.get(buffer.buffer);
          }
          if (!url && latestMediaBuffer && Date.now() - latestMediaBuffer.timestamp < 1500) {
            url = latestMediaBuffer.url;
          }
          if (owner && url) {
            let activity = mediaSourceActivity.get(owner);
            if (!activity) {
              activity = new Map();
              mediaSourceActivity.set(owner, activity);
            }
            const previous = activity.get(url) || { count: 0, latest: 0 };
            activity.set(url, { count: previous.count + 1, latest: Date.now() });
          }
        } catch (_) {}
        return originalAppendBuffer.apply(this, arguments);
      };
    } catch (_) {}

    window.__appMediaFragmentsForVideo = function(video) {
      try {
        const blobUrl = String(video && (video.currentSrc || video.src) || '');
        const mediaSource = mediaSourceByBlobUrl.get(blobUrl);
        const combined = new Map();
        const merge = (activity) => {
          if (!activity) return;
          for (const [url, stats] of activity.entries()) {
            const previous = combined.get(url) || { count: 0, latest: 0 };
            combined.set(url, {
              count: previous.count + Number(stats.count || 0),
              latest: Math.max(previous.latest, Number(stats.latest || 0))
            });
          }
        };
        const exactMediaSourceActivity = mediaSource && mediaSourceActivity.get(mediaSource);
        if (exactMediaSourceActivity && exactMediaSourceActivity.size > 0) {
          // The MediaSource belongs to this exact Blob/video. Never mix its
          // consumed segments with page-level requests that may preload the
          // next feed item.
          merge(exactMediaSourceActivity);
        } else {
          merge(videoRequestActivity.get(video));
        }
        const wholeMediaPriority = (url) => {
          const value = String(url || '').toLowerCase();
          if (/\.(m3u8|m3u|mpd)(\?|#|$)/.test(value)) return 4;
          if (/\.(mp4|webm|mov)(\?|#|$)/.test(value) &&
              !/[?&](range|sq|rn|rbuf)=/.test(value)) return 3;
          if (/\.(m4s|ts|cmfv|cmfa)(\?|#|$)/.test(value) ||
              value.includes('/segment/') || value.includes('/chunk/')) return 0;
          return 1;
        };
        return Array.from(combined.entries())
          .sort((a, b) =>
            (wholeMediaPriority(b[0]) - wholeMediaPriority(a[0])) ||
            (b[1].latest - a[1].latest) ||
            (b[1].count - a[1].count))
          .slice(0, 32)
          .map(entry => entry[0]);
      } catch (_) {
        return [];
      }
    };
  }

  const remember = (rawUrl, contentType, source) => {
    try {
      if (!rawUrl) return;
      const url = new URL(String(rawUrl), location.href).toString();
      if (!/^https?:/i.test(url)) return;
      window.__appEarlyMediaRequests.set(url, {
        contentType: String(contentType || '').toLowerCase(),
        source: source || '',
        timestamp: Date.now()
      });
      bindRequestToVisibleVideo(url);
      if (window.__appEarlyMediaRequests.size > 500) {
        const first = window.__appEarlyMediaRequests.keys().next().value;
        window.__appEarlyMediaRequests.delete(first);
      }
    } catch (_) {}
  };

  try {
    const originalFetch = window.fetch;
    window.fetch = async function(input, init) {
      const response = await originalFetch.apply(this, arguments);
      try {
        const url = typeof input === 'string' ? input : (input && input.url);
        remember(url, response && response.headers && response.headers.get('content-type'), 'fetch');
        if (isElementBoundFeedPage && response && typeof response.arrayBuffer === 'function') {
          const originalArrayBuffer = response.arrayBuffer.bind(response);
          response.arrayBuffer = async function() {
            const buffer = await originalArrayBuffer();
            rememberMediaBuffer(buffer, url);
            return buffer;
          };
        }
      } catch (_) {}
      return response;
    };
  } catch (_) {}

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url) {
      this.__appMediaUrl = url;
      return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function() {
      try {
        this.addEventListener('load', () => {
          let contentType = '';
          try { contentType = this.getResponseHeader('content-type') || ''; } catch (_) {}
          remember(this.__appMediaUrl, contentType, 'xhr');
          try { rememberMediaBuffer(this.response, this.__appMediaUrl); } catch (_) {}
        }, { once: true });
      } catch (_) {}
      return originalSend.apply(this, arguments);
    };
  } catch (_) {}

  try {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        remember(entry && entry.name, '', (entry && entry.initiatorType) || 'resource');
      }
    });
    observer.observe({ type: 'resource', buffered: true });
  } catch (_) {}
})();
''';

const String _kMediaFragmentUrlScript = r'''
function isMediaFragmentUrl(url) {
  if (!url || typeof url !== 'string') return false;
  const lower = url.toLowerCase();
  if (/\.(m4s|cmfv|cmfa)(\?|#|$)/.test(lower)) return true;
  if ([
    'dash-init', 'dash_init', 'dash-segment', 'dash_segment', 'dash-chunk', 'dash_chunk',
    '/segment/', '/segments/', '/chunk/', '/chunks/',
    '/fragment/', '/fragments/', '/init.mp4', '/init.m4s'
  ].some(p => lower.includes(p))) return true;
  if (/(^|[\/_.-])(seg|segment|chunk|fragment|frag|part)[-_]?\d+([_.-]|\/|\?|#|$)/.test(lower)) return true;
  try {
    const baseUrl =
      (typeof location !== 'undefined' && location.href) || 'https://localhost/';
    const parsed = new URL(url, baseUrl);
    const range = parsed.searchParams.get('range') || '';
    const sequence = parsed.searchParams.get('sq') || '';
    return /^\d+-\d+$/.test(range) || /^\d+$/.test(sequence);
  } catch (_) {
    return false;
  }
}

function normalizeMediaCandidateUrl(url) {
  if (!url || typeof url !== 'string') return null;
  let parsed;
  try {
    const baseUrl =
      (typeof location !== 'undefined' && location.href) || 'https://localhost/';
    parsed = new URL(url, baseUrl);
  } catch (_) {
    return null;
  }
  if (!isMediaFragmentUrl(parsed.href)) return parsed.href;
  const path = parsed.pathname.toLowerCase();
  if (
    /\.(m4s|cmfv|cmfa)$/.test(path) ||
    ['dash-init', 'dash_init', 'dash-segment', 'dash_segment', 'dash-chunk', 'dash_chunk',
     '/segment/', '/segments/', '/chunk/', '/chunks/',
     '/fragment/', '/fragments/', '/init.mp4', '/init.m4s']
      .some(p => path.includes(p))
  ) {
    return null;
  }
  let changed = false;
  for (const key of ['range', 'sq', 'rn', 'rbuf']) {
    if (parsed.searchParams.has(key)) {
      parsed.searchParams.delete(key);
      changed = true;
    }
  }
  return changed ? parsed.href : null;
}
''';

// Top-level function for ZIP encoding to avoid blocking UI
List<int>? encodeArchive(Archive archive) {
  return ZipEncoder().encode(archive);
}

class _ExistingMediaDuplicateException implements Exception {
  const _ExistingMediaDuplicateException(this.existingRow);

  final Map<String, dynamic> existingRow;
}

class _MediaLibrarySaveException implements Exception {
  const _MediaLibrarySaveException(this.cause);

  final Object cause;

  @override
  String toString() => '媒体文件已下载，但写入媒体库失败: $cause';
}

class BrowserPage extends StatefulWidget {
  final ValueChanged<bool>? onBrowserHomePageChanged;

  /// 当前主界面选中的标签页索引（0=封面 1=目录 2=媒体 3=浏览器 4=日记），用于从其他标签切换过来时显示主界面
  final int? currentMainPageIndex;

  const BrowserPage({
    Key? key,
    this.onBrowserHomePageChanged,
    this.currentMainPageIndex,
  }) : super(key: key);

  @override
  _BrowserPageState createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage>
    with AutomaticKeepAliveClientMixin {
  /// 将相对 URL 解析为绝对 URL（使用当前页面地址作为基准）
  String _toAbsoluteUrl(String url) {
    if (url.isEmpty) return url;
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('data:') ||
        trimmed.startsWith('blob:')) {
      return trimmed;
    }
    String base = _urlController.text.trim();
    if (base.isEmpty) base = _currentUrl;
    if (base.isEmpty) base = 'https://www.baidu.com';
    final baseUri = Uri.tryParse(base);
    if (baseUri == null || !baseUri.hasAuthority) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    return baseUri.resolve(trimmed).toString();
  }

  /// 是否为 API 接口（返回 JSON 而非图片），应跳过下载
  bool _isApiEndpointUrl(String url) {
    if (url.startsWith('blob:') || url.startsWith('data:')) return false;
    final lower = url.toLowerCase();
    if (RegExp(
      r'\.(jpg|jpeg|png|gif|webp|mp4|webm|mov|m3u8|ts|mp3|m4a)(\?|$)',
      caseSensitive: false,
    ).hasMatch(url))
      return false;
    final videoHosts = [
      'tik.',
      'porn',
      'xvideos',
      'xhamster',
      'pornhub',
      'redtube',
      'cdn.',
      'stream',
      'video.',
      'media.',
    ];
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (videoHosts.any((h) => host.contains(h))) return false;
    } catch (_) {}
    const apiPatterns = [
      'detailrecommend',
      'wisesearchsetpic',
      'wisejson',
      'getrelatedvideos',
      'getuserbyslug',
      '/graphql',
      '/v1/',
      '/v2/',
      '/v3/',
      '/models',
      '/model/',
      '/slug',
      '/users/',
      '/search?',
      '/query',
      '/json',
      '/rest/',
      '/endpoint',
      '/service',
      'getuser',
      'getpost',
      'relatedvideos',
      'userbyslug',
      'byslug',
    ];
    if (apiPatterns.any((p) => lower.contains(p))) return true;
    return RegExp(
      r'/(get|post|api|graphql|rest|v1|v2|models|user|slug)/',
    ).hasMatch(url);
  }

  Future<String> _resolveFinalUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    final absoluteUrl = _toAbsoluteUrl(url);
    try {
      final networkService = NetworkService();
      await networkService.initialize();
      final cookie = await _browserCookieHeaderForUrl(absoluteUrl);
      final resp = await networkService.dio.head(
        absoluteUrl,
        options: Options(
          method: 'HEAD',
          headers: {
            'User-Agent': _kBrowserMediaUserAgent,
            ...?headers,
            if (cookie.isNotEmpty && !(headers?.containsKey('Cookie') ?? false))
              'Cookie': cookie,
          },
        ),
      );
      final finalUrl = resp.realUri.toString();
      return finalUrl.isNotEmpty ? finalUrl : absoluteUrl;
    } catch (_) {
      return absoluteUrl;
    }
  }

  Future<String> _browserCookieHeaderForUrl(String url) async {
    try {
      final absolute = _toAbsoluteUrl(url);
      final uri = Uri.tryParse(absolute);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        return '';
      }
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(absolute),
      );
      final parts = <String>[];
      for (final c in cookies) {
        final name = c.name.trim();
        final value = c.value.trim();
        if (name.isEmpty) continue;
        parts.add('$name=$value');
      }
      return parts.join('; ');
    } catch (e) {
      debugPrint('读取 WebView Cookie 失败: $e');
      return '';
    }
  }

  Future<void> _flushBrowserCookies() async {
    if (!Platform.isAndroid) return;
    try {
      await const MethodChannel(
        'browser_cookies',
      ).invokeMethod<bool>('flushCookies');
    } catch (e) {
      debugPrint('Failed to persist browser cookies: $e');
    }
  }

  Future<Map<String, String>> _browserLikeMediaHeaders(
    String mediaUrl, {
    required String referer,
    String accept = '*/*',
    bool includeOrigin = false,
  }) async {
    final headers = <String, String>{
      'User-Agent': _kBrowserMediaUserAgent,
      'Referer': referer,
      'Accept': accept,
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
      if (includeOrigin && referer.startsWith('http'))
        'Origin': Uri.tryParse(referer)?.origin ?? referer,
    };
    final cookie = await _browserCookieHeaderForUrl(mediaUrl);
    if (cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  @override
  bool get wantKeepAlive => true;

  InAppWebViewController? _controller;
  final LinkedHashMap<String, _CapturedWebResource> _capturedWebResources =
      LinkedHashMap<String, _CapturedWebResource>();
  final LinkedHashMap<String, DateTime> _trustedMediaCandidateUrls =
      LinkedHashMap<String, DateTime>();
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  double _loadingProgress = 0.0;
  String _currentUrl = 'https://www.baidu.com';
  late final DatabaseService _databaseService;
  List<Map<String, String>> _bookmarks = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _showHomePage = true;
  bool _isBrowsingWebPage = false;

  void _recordLoadedWebResource(LoadedResource resource) {
    final rawUrl = resource.url?.toString().trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty ||
        _isLikelyAdUrl(rawUrl)) {
      return;
    }
    final initiator = (resource.initiatorType ?? '').trim().toLowerCase();
    const ignoredInitiators = <String>{
      'css',
      'script',
      'link',
      'font',
      'beacon',
    };
    if (ignoredInitiators.contains(initiator)) return;

    _capturedWebResources.remove(rawUrl);
    _capturedWebResources[rawUrl] = _CapturedWebResource(
      url: rawUrl,
      initiatorType: initiator,
      pageUrl: _currentUrl,
      capturedAt: DateTime.now(),
    );
    final captured = _capturedWebResources[rawUrl]!;
    if (_capturedResourceMatchesType(captured, MediaType.video) ||
        _capturedResourceMatchesType(captured, MediaType.image)) {
      _trustMediaCandidate(rawUrl);
    }
    while (_capturedWebResources.length > _kMaxCapturedWebResources) {
      _capturedWebResources.remove(_capturedWebResources.keys.first);
    }
  }

  bool _urlLooksLikeImageResource(String url) {
    final lower = url.toLowerCase();
    return RegExp(
      r'\.(jpe?g|png|gif|webp|bmp|svg|ico|tiff?|avif|heic|heif|jxl)(\?|#|$)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  bool _capturedResourceMatchesType(
    _CapturedWebResource resource,
    MediaType mediaType,
  ) {
    final initiator = resource.initiatorType;
    if (mediaType == MediaType.image) {
      return initiator == 'img' ||
          initiator == 'image' ||
          _urlLooksLikeImageResource(resource.url);
    }
    if (mediaType == MediaType.video) {
      if (_looksLikeMediaFragmentUrl(resource.url)) return false;
      return initiator == 'video' ||
          initiator == 'media' ||
          (_isLikelyDirectMediaUrl(resource.url) &&
              !_looksLikeMediaFragmentUrl(resource.url));
    }
    return initiator == 'audio';
  }

  List<String> _recentCapturedMediaCandidates(
    MediaType mediaType, {
    String? pageUrl,
    DateTime? notBefore,
    int limit = 24,
  }) {
    final now = DateTime.now();
    final requestedPage = Uri.tryParse((pageUrl ?? _currentUrl).trim());
    final scored = <(_CapturedWebResource resource, int score)>[];
    for (final resource in _capturedWebResources.values) {
      if (notBefore != null && resource.capturedAt.isBefore(notBefore))
        continue;
      final age = now.difference(resource.capturedAt);
      if (age > const Duration(minutes: 30) ||
          !_capturedResourceMatchesType(resource, mediaType)) {
        continue;
      }
      final capturedPage = Uri.tryParse(resource.pageUrl);
      if (requestedPage != null &&
          capturedPage != null &&
          requestedPage.host.isNotEmpty &&
          capturedPage.host.isNotEmpty &&
          requestedPage.host != capturedPage.host) {
        continue;
      }
      var score = max(0, 1800 - age.inSeconds);
      if (resource.initiatorType == 'video' ||
          resource.initiatorType == 'img' ||
          resource.initiatorType == 'image') {
        score += 3000;
      }
      if (mediaType == MediaType.video) {
        score += _scoreFavoriteVideoUrl(resource.url);
      } else if (_urlLooksLikeImageResource(resource.url)) {
        score += 1200;
      }
      scored.add((resource, score));
    }
    scored.sort((a, b) {
      final scoreOrder = b.$2.compareTo(a.$2);
      if (scoreOrder != 0) return scoreOrder;
      // 同一秒内可能连续加载多个信息流视频；分数相同时必须优先最新资源。
      return b.$1.capturedAt.compareTo(a.$1.capturedAt);
    });
    return scored.take(limit).map((entry) => entry.$1.url).toList();
  }

  bool _isXPlatformPage(String? url) {
    final host = Uri.tryParse((url ?? '').trim())?.host.toLowerCase() ?? '';
    return host == 'x.com' ||
        host.endsWith('.x.com') ||
        host == 'twitter.com' ||
        host.endsWith('.twitter.com');
  }

  bool _isXMediaViewerPage(String? url) {
    final uri = Uri.tryParse((url ?? '').trim());
    if (uri == null || !_isXPlatformPage(url)) return false;
    final path = uri.path.toLowerCase();
    return path.contains('/mediaviewer') ||
        uri.queryParameters.containsKey('currentTweet');
  }

  bool _isXStatusDetailPage(String? url) {
    final uri = Uri.tryParse((url ?? '').trim());
    if (uri == null || !_isXPlatformPage(url)) return false;
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final statusIndex = segments.indexWhere(
      (part) => part.toLowerCase() == 'status',
    );
    return statusIndex >= 0 &&
        statusIndex + 1 < segments.length &&
        RegExp(r'^\d+$').hasMatch(segments[statusIndex + 1]);
  }

  bool _isSameXSmartReturnPage(String expected, String actual) {
    if (_isSameLoadedDocument(expected, actual)) return true;
    final expectedUri = Uri.tryParse(expected);
    final actualUri = Uri.tryParse(actual);
    if (expectedUri == null ||
        actualUri == null ||
        !_isXPlatformPage(expected) ||
        !_isXPlatformPage(actual) ||
        _isXStatusDetailPage(actual) ||
        _isXMediaViewerPage(actual)) {
      return false;
    }
    final expectedPath =
        expectedUri.path.isEmpty ? '/' : expectedUri.path.toLowerCase();
    final actualPath =
        actualUri.path.isEmpty ? '/' : actualUri.path.toLowerCase();
    return (expectedPath == '/' && actualPath == '/home') ||
        (expectedPath == '/home' && actualPath == '/');
  }

  String _xMediaIdentity(String url) {
    final match = RegExp(
      r'/(?:amplify_video|ext_tw_video|tweet_video)/(\d+)/',
      caseSensitive: false,
    ).firstMatch(url);
    return match?.group(1) ?? '';
  }

  int _scoreXVideoCandidate(String url) {
    final lower = url.toLowerCase();
    var score = _scoreFavoriteVideoUrl(url);
    if (!lower.contains('video.twimg.com/')) return score;
    if (RegExp(r'/pl/[^/]+\.m3u8(?:\?|$)').hasMatch(lower)) score += 10000;
    if (lower.contains('/pl/avc1/')) score += 4000;
    if (lower.contains('/vid/avc1/')) score += 3000;
    if (lower.contains('/pl/mp4a/') || lower.contains('/aud/mp4a/')) {
      score -= 20000;
    }
    return score;
  }

  Future<List<String>> _resolveXLongPressVideoCandidates({
    required String primaryUrl,
    required List<String> candidates,
    required String pageUrl,
    String expectedMediaId = '',
    DateTime? notBefore,
  }) async {
    if (!_isXPlatformPage(pageUrl) && !_isXPlatformPage(_currentUrl)) {
      return <String>[
        primaryUrl,
        ...candidates,
      ].where((url) => url.trim().isNotEmpty).toSet().toList();
    }
    final mediaId =
        expectedMediaId.trim().isNotEmpty
            ? expectedMediaId.trim()
            : _xMediaIdentity(primaryUrl);
    var merged = <String>[primaryUrl, ...candidates];
    for (var attempt = 0; attempt < 20; attempt++) {
      merged = <String>[
        ...merged,
        ..._recentCapturedMediaCandidates(
          MediaType.video,
          pageUrl: pageUrl,
          // X often loads the master before playback. The media-ID filter
          // below prevents this wider capture window from crossing posts.
          notBefore: mediaId.isEmpty ? notBefore : null,
          limit: 48,
        ),
      ];
      final sameMedia =
          merged
              .where((url) {
                if (url.trim().isEmpty) return false;
                return mediaId.isEmpty || _xMediaIdentity(url) == mediaId;
              })
              .toSet()
              .toList()
            ..sort(
              (left, right) => _scoreXVideoCandidate(
                right,
              ).compareTo(_scoreXVideoCandidate(left)),
            );
      final hasUsableVideo = sameMedia.any(
        (url) =>
            _scoreXVideoCandidate(url) > 0 &&
            !url.toLowerCase().contains('/mp4a/') &&
            !url.toLowerCase().contains('/aud/'),
      );
      if (hasUsableVideo) return sameMedia;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final fallback =
        merged
            .where((url) {
              if (url.trim().isEmpty) return false;
              return mediaId.isEmpty || _xMediaIdentity(url) == mediaId;
            })
            .toSet()
            .toList()
          ..sort(
            (left, right) => _scoreXVideoCandidate(
              right,
            ).compareTo(_scoreXVideoCandidate(left)),
          );
    return fallback;
  }

  List<String> _recentActiveDashManifestCandidates({
    String? pageUrl,
    DateTime? notBefore,
    int limit = 4,
  }) {
    final now = DateTime.now();
    final requestedPage = Uri.tryParse((pageUrl ?? _currentUrl).trim());
    final activity = <String, ({int count, DateTime latest})>{};
    for (final resource in _capturedWebResources.values) {
      if (notBefore != null && resource.capturedAt.isBefore(notBefore))
        continue;
      if (now.difference(resource.capturedAt) > const Duration(minutes: 10) ||
          !_looksLikeMediaFragmentUrl(resource.url)) {
        continue;
      }
      final lowerUrl = resource.url.toLowerCase();
      if (lowerUrl.contains('dash-init') ||
          lowerUrl.contains('dash_init') ||
          lowerUrl.contains('/init.')) {
        // 下一条视频通常会预加载初始化分片，但这不代表用户正在观看它。
        continue;
      }
      final capturedPage = Uri.tryParse(resource.pageUrl);
      if (requestedPage != null &&
          capturedPage != null &&
          requestedPage.host.isNotEmpty &&
          capturedPage.host.isNotEmpty &&
          requestedPage.host != capturedPage.host) {
        continue;
      }
      final manifest = recoverWholeMediaUrlFromFragment(resource.url);
      if (manifest == null ||
          !(Uri.tryParse(manifest)?.path.toLowerCase().endsWith('.mpd') ??
              false)) {
        continue;
      }
      final previous = activity[manifest];
      activity[manifest] = (
        count: (previous?.count ?? 0) + 1,
        latest:
            previous == null || resource.capturedAt.isAfter(previous.latest)
                ? resource.capturedAt
                : previous.latest,
      );
    }
    final ranked =
        activity.entries.toList()..sort((a, b) {
          final timeOrder = b.value.latest.compareTo(a.value.latest);
          if (timeOrder != 0) return timeOrder;
          return b.value.count.compareTo(a.value.count);
        });
    return ranked.take(limit).map((entry) => entry.key).toList();
  }

  double? _extractDashManifestDurationSeconds(String xml) {
    String durationFromTag(String tag) {
      final match = RegExp(
        '<$tag\\b([^>]*)>',
        caseSensitive: false,
      ).firstMatch(xml);
      return _dashAttributes(match?.group(1) ?? '')['duration'] ?? '';
    }

    final mpd = RegExp(r'<MPD\b([^>]*)>', caseSensitive: false).firstMatch(xml);
    final mpdDuration = _parseDashDurationSeconds(
      _dashAttributes(mpd?.group(1) ?? '')['mediaPresentationDuration'] ?? '',
    );
    if (mpdDuration != null && mpdDuration > 0) return mpdDuration;
    final periodDuration = _parseDashDurationSeconds(durationFromTag('Period'));
    if (periodDuration != null && periodDuration > 0) return periodDuration;

    for (final template in RegExp(
      r'<SegmentTemplate\b([^>]*)>([\s\S]*?)</SegmentTemplate>',
      caseSensitive: false,
    ).allMatches(xml)) {
      final attrs = _dashAttributes(template.group(1) ?? '');
      final timescale = int.tryParse(attrs['timescale'] ?? '') ?? 1;
      if (timescale <= 0) continue;
      var timelineUnits = 0;
      for (final segment in RegExp(
        r'<S\b([^>]*)/?>',
        caseSensitive: false,
      ).allMatches(template.group(2) ?? '')) {
        final segmentAttrs = _dashAttributes(segment.group(1) ?? '');
        final duration = int.tryParse(segmentAttrs['d'] ?? '');
        final repeat = int.tryParse(segmentAttrs['r'] ?? '') ?? 0;
        if (duration == null || duration <= 0 || repeat < 0) continue;
        timelineUnits += duration * (repeat + 1);
      }
      if (timelineUnits > 0) return timelineUnits / timescale;
    }
    return null;
  }

  Future<String?> _selectDashManifestForLongPress(
    List<String> candidates, {
    required double targetDurationSeconds,
  }) async {
    if (candidates.isEmpty) return null;
    if (targetDurationSeconds <= 0) {
      return candidates.first;
    }
    final networkService = NetworkService();
    await networkService.initialize();
    final checks = candidates.take(4).map((candidate) async {
      try {
        final headers = await _browserLikeMediaHeaders(
          candidate,
          referer: _getMediaReferer(candidate),
          accept: 'application/dash+xml,application/xml,text/xml,*/*',
        );
        final response = await networkService.dio.get<String>(
          candidate,
          options: Options(
            responseType: ResponseType.plain,
            headers: headers,
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        final duration = _extractDashManifestDurationSeconds(
          response.data ?? '',
        );
        return duration == null ? null : (url: candidate, duration: duration);
      } catch (_) {
        return null;
      }
    });
    final matches =
        (await Future.wait(
          checks,
        )).whereType<({String url, double duration})>();
    ({String url, double duration})? best;
    var bestDifference = double.infinity;
    for (final match in matches) {
      final difference = (match.duration - targetDurationSeconds).abs();
      if (difference < bestDifference) {
        best = match;
        bestDifference = difference;
      }
    }
    // 清单预检可能受临时鉴权限制；完全无法解析时保留上一版的活跃分片选择结果。
    if (best == null) return candidates.first;
    // Player duration and MPD duration may use different timelines or rounding.
    // Prefer the closest manifest, but do not turn an uncertain match into a
    // guaranteed download failure. The caller can retain the other manifests
    // as fallbacks when this candidate cannot be downloaded.
    return best.url;
  }

  bool _isCapturedVideoCandidate(String url) {
    final resource = _capturedWebResources[url];
    if (resource == null) return false;
    return DateTime.now().difference(resource.capturedAt) <=
            const Duration(minutes: 30) &&
        _capturedResourceMatchesType(resource, MediaType.video);
  }

  void _trustMediaCandidate(String url) {
    final absolute = _toAbsoluteUrl(url);
    final uri = Uri.tryParse(absolute);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        _isLikelyAdUrl(absolute) ||
        _looksLikeMediaFragmentUrl(absolute)) {
      return;
    }
    _trustedMediaCandidateUrls.remove(absolute);
    _trustedMediaCandidateUrls[absolute] = DateTime.now();
    while (_trustedMediaCandidateUrls.length > 300) {
      _trustedMediaCandidateUrls.remove(_trustedMediaCandidateUrls.keys.first);
    }
  }

  bool _isTrustedMediaCandidate(String url) {
    final capturedAt = _trustedMediaCandidateUrls[_toAbsoluteUrl(url)];
    return capturedAt != null &&
        DateTime.now().difference(capturedAt) <= const Duration(minutes: 30);
  }

  // 下载任务列表：支持查看、取消
  final List<Map<String, dynamic>> _downloadTasks = [];
  final ValueNotifier<List<Map<String, dynamic>>> _downloadTasksNotifier =
      ValueNotifier([]);
  final Map<String, int> _dashConcurrencyByHost = {};
  final Map<String, DateTime> _recentDuplicatePromptTimes = {};
  static const int _maxDisplayTasks = 8;
  static const Duration _duplicatePromptCooldown = Duration(seconds: 12);
  bool _downloadPanelExpanded = false;
  bool _mediaDuplicateDialogActive = false;
  Offset? _downloadPanelPosition;
  Timer? _favoriteProgressSyncTimer;

  // 1. 新增历史记录变量
  List<Map<String, dynamic>> _history = [];
  static const String _kSharedFavoriteVideosPrefsKey =
      'doc_web_video_favorites_v1';
  static const bool _favoriteDownloadDiagnosticsEnabled = true;

  /// 长按下载：直链失败后 canvas/base64 可能晚到，用定时器合并为「仅一条」失败提示。
  Timer? _mediaDownloadFailHintTimer;
  bool _mediaDownloadSaveResolved = false;
  bool _longPressVideoDownloadInProgress = false;

  void _notifyMediaDownloadSaved() {
    _mediaDownloadSaveResolved = true;
    _mediaDownloadFailHintTimer?.cancel();
    _mediaDownloadFailHintTimer = null;
  }

  /// 与网页端 [markMediaUrlProcessing] 配对：一次下载流程结束后允许同一 URL 再次长按保存。
  void _releaseJsProcessedUrl(String url) {
    final c = _controller;
    if (c == null || url.isEmpty) return;
    final encoded = jsonEncode(url);
    unawaited(
      c.evaluateJavascript(
        source:
            'try{window.processedMediaUrls&&window.processedMediaUrls.delete($encoded);}catch(e){}',
      ),
    );
  }

  /// 登记本次将要处理的 HTTP(S) 媒体 URL。若短期内重复则返回 false（需提示用户）；超时自动视为可重试。
  bool _tryRegisterMediaUrlForProcessing(String url) {
    final now = DateTime.now();
    final prev = _processedMediaUrlsSince[url];
    if (prev != null) {
      if (now.difference(prev) > _kMediaUrlInFlightTtl) {
        _processedMediaUrlsSince.remove(url);
      } else {
        return false;
      }
    }
    _processedMediaUrlsSince[url] = now;
    return true;
  }

  /// 常见「拉活 / 应用商店 / 站内 App」协议：拦截即可，不尝试唤起、也不弹「无法打开」。
  bool _isNoisyExternalAppScheme(String lowerUrl) {
    return lowerUrl.startsWith('baiduboxapp://') ||
        lowerUrl.startsWith('bdapp://') ||
        lowerUrl.startsWith('baiduhaokan://') ||
        lowerUrl.startsWith('tbopen://') ||
        lowerUrl.startsWith('snssdk://') ||
        lowerUrl.startsWith('sinaweibo://') ||
        lowerUrl.startsWith('weixin://') ||
        lowerUrl.startsWith('alipays://') ||
        lowerUrl.startsWith('intent://') ||
        lowerUrl.startsWith('samsungapps://') ||
        lowerUrl.startsWith('market://') ||
        lowerUrl.startsWith('hap://');
  }

  Future<void> _launchExternalApp(String url) async {
    debugPrint('尝试启动外部应用: $url');
    try {
      final Uri? uri = Uri.tryParse(url);
      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('成功启动外部应用');
      } else {
        debugPrint('无法启动外部应用: $url');
        final lower = url.toLowerCase();
        final isAppScheme = _isNoisyExternalAppScheme(lower);
        if (!isAppScheme && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('无法打开: $url')));
        }
      }
    } catch (e) {
      debugPrint('启动外部应用时出错: $e');
      final lower = url.toLowerCase();
      final isAppScheme = _isNoisyExternalAppScheme(lower);
      if (!isAppScheme && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开链接时出错: $e')));
      }
    }
  }

  bool _shouldKeepWebPageState = false;
  String? _lastBrowsedUrl;

  final List<Map<String, dynamic>> _commonWebsites = [
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': Icons.search},
    {'name': '百度', 'url': 'https://www.baidu.com', 'icon': Icons.search},
  ];
  Map<String, dynamic>? _smartDownloadTask;
  bool _smartDownloadAdvancing = false;
  Offset? _smartOperationPoint;
  String _smartOperationLabel = '';
  final List<String> _smartKeywordHistory = <String>[];
  static const String _kSmartKeywordHistoryKey =
      'browser_smart_download_keyword_history_v1';
  static const String _kSmartDownload24hRegistryKey =
      'browser_smart_download_24h_registry_v1';
  static const String _kSmartStrategyProfilesKey =
      'browser_smart_strategy_profiles_v1';
  final List<Map<String, dynamic>> _smartDownload24hRegistry = [];
  final Map<String, Map<String, dynamic>> _smartStrategyProfiles = {};
  bool _smartDownload24hRegistryLoaded = false;
  Future<void>? _smartDownloadRegistryLoadFuture;
  Future<void> _smartDownloadRegistryWrite = Future<void>.value();

  // 移除编辑模式状态变量
  // bool _isEditMode = false;

  // 保留此方法但简化功能，因为我们已移除编辑模式
  Future<void> _saveWebsites() async {
    await _saveCommonWebsites();
  }

  Future<void> _removeWebsite(int index) async {
    final removedSite = _commonWebsites[index]['name'];
    setState(() => _commonWebsites.removeAt(index));
    await _saveCommonWebsites();
    debugPrint('已删除并保存网站: $removedSite');
  }

  Future<void> _reorderWebsites(int oldIndex, int newIndex) async {
    // 如果是添加网站按钮，不允许拖动
    if (oldIndex >= _commonWebsites.length ||
        newIndex > _commonWebsites.length) {
      return;
    }

    // 调整newIndex，因为ReorderableGridView的newIndex计算方式与ReorderableListView不同
    if (newIndex > _commonWebsites.length) newIndex = _commonWebsites.length;

    setState(() {
      if (oldIndex < newIndex) newIndex -= 1;
      final item = _commonWebsites.removeAt(oldIndex);
      _commonWebsites.insert(newIndex, item);
    });
    await _saveCommonWebsites();
    debugPrint('已移动并保存网站从位置 $oldIndex 到 $newIndex');
  }

  Future<void> _addWebsite(String name, String url, IconData icon) async {
    setState(
      () => _commonWebsites.add({
        'name': name,
        'url': url,
        'iconCode': icon.codePoint,
      }),
    );
    await _saveCommonWebsites();
    debugPrint('已添加并立即保存网站: $name');
  }

  @override
  void initState() {
    super.initState();
    _databaseService = getService<DatabaseService>();
    _initializeDownloader();
    _loadBookmarks();
    _loadCommonWebsites();
    _loadHistory();
    _loadVideoSourceUrlMap();
    unawaited(_loadSmartKeywordHistory());
    unawaited(_loadSmartDownload24hRegistry());
    unawaited(_loadSmartStrategyProfiles());
    _favoriteProgressSyncTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_syncCurrentFavoriteProgress()),
    );
  }

  @override
  void didUpdateWidget(covariant BrowserPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他标签页（如媒体）滑动到浏览器时，应显示主界面而非空白网页
    final idx = widget.currentMainPageIndex;
    final oldIdx = oldWidget.currentMainPageIndex;
    if (idx == 3 && oldIdx != 3 && !_showHomePage) {
      _goToHomePage();
    }
  }

  Future<void> _initializeDownloader() async {
    await FlutterDownloader.initialize();
    await _requestPermissions();
  }

  Future<void> _loadVideoSourceUrlMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kVideoSourceUrlMapPrefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _videoSourceUrlToMediaId
        ..clear()
        ..addAll(decoded.map((k, v) => MapEntry(k.toString(), v.toString())));
    } catch (e) {
      debugPrint('加载视频来源映射失败: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _loadSharedFavoriteVideos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSharedFavoriteVideosPrefsKey);
    if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      final list =
          decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where((e) => (e['pageUrl'] ?? '').toString().trim().isNotEmpty)
              .toList();
      return _normalizeSharedFavorites(list);
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _saveSharedFavoriteVideos(
    List<Map<String, dynamic>> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeSharedFavorites(
      items.map((e) => Map<String, dynamic>.from(e)).toList(),
    );
    await prefs.setString(
      _kSharedFavoriteVideosPrefsKey,
      jsonEncode(normalized),
    );
  }

  List<Map<String, dynamic>> _normalizeSharedFavorites(
    List<Map<String, dynamic>> raw,
  ) {
    final nowIso = DateTime.now().toIso8601String();
    for (int i = 0; i < raw.length; i++) {
      final row = raw[i];
      row['customName'] = (row['customName'] ?? '').toString();
      row['pinned'] = row['pinned'] == true;
      row['favoritedAt'] =
          (row['favoritedAt'] ?? row['updatedAt'] ?? nowIso).toString();
      row['sortOrder'] = (row['sortOrder'] as num?)?.toInt() ?? i;
      row['downloaded'] = row['downloaded'] == true;
      row['downloadedAt'] = (row['downloadedAt'] ?? '').toString();
    }
    raw.sort((a, b) {
      final pa = a['pinned'] == true ? 1 : 0;
      final pb = b['pinned'] == true ? 1 : 0;
      if (pa != pb) return pb - pa;
      final sa = (a['sortOrder'] as num?)?.toInt() ?? 0;
      final sb = (b['sortOrder'] as num?)?.toInt() ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      final ta = DateTime.tryParse((a['favoritedAt'] ?? '').toString());
      final tb = DateTime.tryParse((b['favoritedAt'] ?? '').toString());
      return (tb ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        ta ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
    return raw;
  }

  bool _isFavoriteLikelyDownloaded(Map<String, dynamic> item) {
    if (item['downloaded'] == true) return true;
    final urls = <String>[(item['videoUrl'] ?? '').toString().trim()];
    final candidateRaw = item['candidateUrls'];
    if (candidateRaw is List) {
      for (final e in candidateRaw) {
        if (e is String && e.trim().isNotEmpty) {
          urls.add(e.trim());
        }
      }
    }
    for (final u in urls) {
      if (u.isEmpty) continue;
      final norm = _normalizeVideoSourceUrl(u);
      if (_videoSourceUrlToMediaId.containsKey(norm)) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>?> _findExistingMediaForItem(
    Map<String, dynamic> item,
  ) async {
    final primaryUrl = (item['videoUrl'] ?? '').toString().trim();
    final urls = <String>[if (primaryUrl.isNotEmpty) primaryUrl];
    final isSmartBatch = item['downloadOrigin'] == 'smart_batch';
    final pageUrl = (item['pageUrl'] ?? '').toString().trim();
    if (isSmartBatch && _smartStablePageKey(pageUrl).isNotEmpty) {
      final existingByPage = await _findExistingVideoBeforeDownload(pageUrl);
      if (existingByPage != null) return existingByPage;
    }
    // Long-press candidates may include media preloaded for adjacent feed
    // items. Only its primary URL is suitable for a tentative pre-check.
    if (item['downloadOrigin'] != 'long_press' && !isSmartBatch) {
      final candidateRaw = item['candidateUrls'];
      if (candidateRaw is List) {
        for (final e in candidateRaw) {
          if (e is String && e.trim().isNotEmpty) {
            urls.add(e.trim());
          }
        }
      }
    }
    for (final u in urls) {
      final existing = await _findExistingVideoBeforeDownload(u);
      if (existing != null) return existing;
    }
    return null;
  }

  Future<void> _markFavoriteDownloaded(
    Map<String, dynamic> item, {
    bool downloaded = true,
  }) async {
    final pageUrl = (item['pageUrl'] ?? '').toString().trim();
    final videoUrl = (item['videoUrl'] ?? '').toString().trim();
    if (pageUrl.isEmpty && videoUrl.isEmpty) return;
    final list = List<Map<String, dynamic>>.from(
      await _loadSharedFavoriteVideos(),
    );
    final nowIso = DateTime.now().toIso8601String();
    var changed = false;
    for (final row in list) {
      final p = (row['pageUrl'] ?? '').toString().trim();
      final v = (row['videoUrl'] ?? '').toString().trim();
      final matches =
          videoUrl.isNotEmpty
              ? v == videoUrl
              : pageUrl.isNotEmpty && p == pageUrl;
      if (matches) {
        row['downloaded'] = downloaded;
        row['downloadedAt'] = downloaded ? nowIso : '';
        row['updatedAt'] = nowIso;
        changed = true;
        break;
      }
    }
    if (changed) {
      await _saveSharedFavoriteVideos(list);
    }
  }

  String _normalizeUrlForKey(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null) return url.trim();
    final filtered = <String, dynamic>{};
    for (final e in u.queryParameters.entries) {
      final k = e.key.toLowerCase();
      if (k.startsWith('utm_')) continue;
      if (k == 'fbclid' ||
          k == 'gclid' ||
          k == 'igshid' ||
          k == 'spm' ||
          k == 'spm_id_from' ||
          k == 'from' ||
          k == 'source' ||
          k == 'ref' ||
          k == 'ref_src' ||
          k == 'referrer' ||
          k == 'session' ||
          k == 'sid') {
        continue;
      }
      filtered[e.key] = e.value;
    }
    final next = u.replace(
      fragment: '',
      queryParameters: filtered.isEmpty ? null : filtered,
    );
    return next.toString();
  }

  bool _isLikelyAdUrl(String url) {
    final s = url.toLowerCase();
    const patterns = [
      'doubleclick.net',
      'googleads',
      'googlesyndication',
      'adsystem',
      'adservice',
      'adnxs',
      'openx.net',
      'rubiconproject',
      'pubmatic',
      'taboola',
      'outbrain',
      'criteo',
      'amazon-adsystem',
      '/ads/',
      '/ad/',
      '/adv/',
      'pixel.',
      'analytics.',
      'tracking',
      'telemetry',
      'prebid',
      'header-bidding',
      'banner',
      'sponsor',
      'promo',
      'advertising',
      'vast',
      'vpaid',
      'mraid',
      'popunder',
      'popup',
      'interstitial',
    ];
    return patterns.any(s.contains);
  }

  String _fmtFavoriteDate(String iso) {
    if (iso.isEmpty) return '未知';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso.length > 10 ? iso.substring(0, 10) : iso;
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  Future<String?> _promptRenameFavorite({
    required BuildContext context,
    required String initialText,
  }) async {
    final ctl = TextEditingController(text: initialText);
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名收藏'),
            content: TextField(
              controller: ctl,
              maxLines: 1,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入新名称'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  Future<void> _syncCurrentFavoriteProgress() async {
    if (_showHomePage || _controller == null) return;
    final pageUrl = _currentUrl.trim();
    if (pageUrl.isEmpty) return;
    try {
      final raw = await _controller!.evaluateJavascript(
        source: '''
(() => {
  try {
    const videos = Array.from(document.querySelectorAll('video'));
    if (!videos.length) return { hasVideo: false };
    const vw = Math.max(1, window.innerWidth || 1);
    const vh = Math.max(1, window.innerHeight || 1);
    const cx = vw / 2;
    const cy = vh / 2;
    const area = (r) => Math.max(0, r.width) * Math.max(0, r.height);
    const dist = (r) => {
      const x = (r.left + r.right) / 2;
      const y = (r.top + r.bottom) / 2;
      return Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
    };
    let best = null;
    let bestScore = -1e18;
    for (const v of videos) {
      const r = v.getBoundingClientRect();
      const d = Number(v.duration || 0);
      const p = Number(v.currentTime || 0);
      const src = String(v.currentSrc || v.src || '');
      let s = area(r) * 0.7;
      if (!v.paused && !v.ended) s += 1000000;
      if (p > 0.4) s += 160000;
      s += Math.max(0, 220000 - dist(r) * 380);
      if (isFinite(d) && d > 0) s += Math.min(d, 2400) * 300;
      if (src.includes('.m3u8') || src.includes('.mp4') || src.includes('.webm')) s += 100000;
      if (s > bestScore) {
        bestScore = s;
        best = { src, d, p };
      }
    }
    if (!best) return { hasVideo: false };
    return {
      hasVideo: true,
      pageUrl: location.href || '',
      videoUrl: best.src || '',
      positionSec: isFinite(best.p) ? best.p : 0,
      durationSec: isFinite(best.d) ? best.d : 0,
      title: (document.title || '').trim(),
    };
  } catch (_) {
    return { hasVideo: false };
  }
})();
''',
      );
      if (raw is! Map || raw['hasVideo'] != true) return;
      final page = (raw['pageUrl'] ?? pageUrl).toString().trim();
      final video = (raw['videoUrl'] ?? '').toString().trim();
      final pos = (raw['positionSec'] as num?)?.toDouble() ?? 0.0;
      final dur = (raw['durationSec'] as num?)?.toDouble() ?? 0.0;
      if (page.isEmpty || pos < 0) return;
      final list = List<Map<String, dynamic>>.from(
        await _loadSharedFavoriteVideos(),
      );
      var changed = false;
      for (int i = 0; i < list.length; i++) {
        final p = (list[i]['pageUrl'] ?? '').toString().trim();
        final v = (list[i]['videoUrl'] ?? '').toString().trim();
        final matchByVideo = video.isNotEmpty && v.isNotEmpty && v == video;
        final matchByPage = p == page;
        if (!(matchByVideo || matchByPage)) continue;
        list[i]['positionSec'] = pos;
        list[i]['durationSec'] = dur;
        list[i]['updatedAt'] = DateTime.now().toIso8601String();
        if (video.isNotEmpty) list[i]['videoUrl'] = video;
        final t = (raw['title'] ?? '').toString().trim();
        if (t.isNotEmpty) list[i]['title'] = t;
        changed = true;
        break;
      }
      if (changed) await _saveSharedFavoriteVideos(list);
    } catch (_) {}
  }

  Future<void> _addSharedFavoriteFromBrowser({
    required String pageUrl,
    required String videoUrl,
    required String title,
    required double positionSec,
    required double durationSec,
    List<String>? candidateUrls,
  }) async {
    if (pageUrl.trim().isEmpty) return;
    final list = List<Map<String, dynamic>>.from(
      await _loadSharedFavoriteVideos(),
    );
    final normPage = pageUrl.trim();
    final normVideo = videoUrl.trim();
    final pageKey = _normalizeUrlForKey(normPage);
    final videoKey = normVideo.isEmpty ? '' : _normalizeUrlForKey(normVideo);
    list.removeWhere((e) {
      final p = (e['pageUrl'] ?? '').toString().trim();
      final v = (e['videoUrl'] ?? '').toString().trim();
      final pKey =
          (e['pageKey'] ?? '').toString().trim().isNotEmpty
              ? (e['pageKey'] ?? '').toString().trim()
              : _normalizeUrlForKey(p);
      final vKey =
          (e['videoKey'] ?? '').toString().trim().isNotEmpty
              ? (e['videoKey'] ?? '').toString().trim()
              : _normalizeUrlForKey(v);
      return (videoKey.isNotEmpty && vKey == videoKey) ||
          (pageKey.isNotEmpty && pKey == pageKey);
    });
    list.insert(0, {
      'pageUrl': normPage,
      'videoUrl': normVideo,
      'pageKey': pageKey,
      'videoKey': videoKey,
      'title': title.trim(),
      'customName': '',
      'positionSec': positionSec,
      'durationSec': durationSec,
      'updatedAt': DateTime.now().toIso8601String(),
      'favoritedAt': DateTime.now().toIso8601String(),
      'pinned': false,
      'sortOrder': 0,
      'isFavorite': true,
      'downloaded': false,
      'downloadedAt': '',
      if (candidateUrls != null && candidateUrls.isNotEmpty)
        'candidateUrls': candidateUrls.take(24).toList(),
    });
    await _saveSharedFavoriteVideos(list);
  }

  String _fmtSec(double sec) {
    final s = sec.isFinite ? sec.round().clamp(0, 360000) : 0;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _showSharedFavoriteVideosSheet() async {
    final favorites = List<Map<String, dynamic>>.from(
      await _loadSharedFavoriteVideos(),
    );
    if (!mounted) return;
    if (favorites.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无收藏视频记录')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder:
          (sheetCtx) => StatefulBuilder(
            builder:
                (ctx, setSheetState) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.of(ctx).size.height * 0.82,
                    child: Column(
                      children: [
                        ListTile(
                          dense: true,
                          title: const Text('收藏视频'),
                          subtitle: Text('共${favorites.length}条'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '一键清空',
                                onPressed: () async {
                                  final shouldClear =
                                      await showDialog<bool>(
                                        context: context,
                                        builder:
                                            (ctx) => AlertDialog(
                                              title: const Text('确认清空'),
                                              content: Text(
                                                '确定要删除全部 ${favorites.length} 条收藏视频记录吗？',
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed:
                                                      () => Navigator.pop(
                                                        ctx,
                                                        false,
                                                      ),
                                                  child: const Text('取消'),
                                                ),
                                                TextButton(
                                                  onPressed:
                                                      () => Navigator.pop(
                                                        ctx,
                                                        true,
                                                      ),
                                                  style: TextButton.styleFrom(
                                                    foregroundColor: Colors.red,
                                                  ),
                                                  child: const Text('全部删除'),
                                                ),
                                              ],
                                            ),
                                      ) ??
                                      false;
                                  if (shouldClear) {
                                    final pinnedCount =
                                        favorites
                                            .where((e) => e['pinned'] == true)
                                            .length;
                                    favorites.removeWhere(
                                      (e) => e['pinned'] != true,
                                    );
                                    await _saveSharedFavoriteVideos(favorites);
                                    setSheetState(() {});
                                    if (favorites.isEmpty && mounted) {
                                      Navigator.of(sheetCtx).pop();
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('收藏记录已清空'),
                                        ),
                                      );
                                    } else if (mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '非置顶内容已清空，保留了 $pinnedCount 条置顶视频',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(
                                  Icons.delete_sweep_outlined,
                                  color: Colors.red,
                                ),
                              ),
                              IconButton(
                                tooltip: '一键下载全部',
                                onPressed:
                                    () => unawaited(
                                      _downloadFavoritesBatch(
                                        List<Map<String, dynamic>>.from(
                                          favorites,
                                        ),
                                      ),
                                    ),
                                icon: const Icon(
                                  Icons.download_for_offline_outlined,
                                ),
                              ),
                              IconButton(
                                tooltip: '一键重新下载全部',
                                onPressed: () async {
                                  final downloadedItems =
                                      favorites
                                          .where(_isFavoriteLikelyDownloaded)
                                          .map(
                                            (item) =>
                                                Map<String, dynamic>.from(item),
                                          )
                                          .toList();
                                  if (downloadedItems.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('暂无标示为已下载的视频'),
                                      ),
                                    );
                                    return;
                                  }
                                  final shouldRedownload =
                                      await showDialog<bool>(
                                        context: context,
                                        builder:
                                            (ctx) => AlertDialog(
                                              title: const Text('重新下载全部'),
                                              content: Text(
                                                '将重新下载全部 ${downloadedItems.length} 条已标示为下载的视频，是否继续？',
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed:
                                                      () => Navigator.pop(
                                                        ctx,
                                                        false,
                                                      ),
                                                  child: const Text('取消'),
                                                ),
                                                FilledButton(
                                                  onPressed:
                                                      () => Navigator.pop(
                                                        ctx,
                                                        true,
                                                      ),
                                                  child: const Text('重新下载'),
                                                ),
                                              ],
                                            ),
                                      ) ??
                                      false;
                                  if (!shouldRedownload) return;
                                  unawaited(
                                    _downloadFavoritesBatch(
                                      downloadedItems,
                                      forceRedownload: true,
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.refresh_rounded),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: ReorderableListView.builder(
                            itemCount: favorites.length,
                            onReorder: (oldIdx, newIdx) async {
                              if (oldIdx < newIdx) newIdx -= 1;
                              final item = favorites.removeAt(oldIdx);
                              favorites.insert(newIdx, item);
                              await _saveSharedFavoriteVideos(favorites);
                              setSheetState(() {});
                            },
                            itemBuilder: (c, i) {
                              final it = favorites[i];
                              final isPinned = it['pinned'] == true;
                              final pageUrl = (it['pageUrl'] ?? '').toString();
                              final title =
                                  (it['customName'] ?? '')
                                          .toString()
                                          .trim()
                                          .isNotEmpty
                                      ? (it['customName'] ?? '')
                                          .toString()
                                          .trim()
                                      : (it['title'] ?? '').toString().trim();
                              final downloaded = _isFavoriteLikelyDownloaded(
                                it,
                              );
                              final favoritedAt =
                                  (it['favoritedAt'] ??
                                          it['favorited_at'] ??
                                          it['updatedAt'] ??
                                          it['date_added'] ??
                                          it['dateAdded'] ??
                                          '')
                                      .toString();
                              final downloadedAt =
                                  (it['downloadedAt'] ?? '').toString();
                              final pos =
                                  (it['positionSec'] as num?)?.toDouble() ??
                                  0.0;
                              final dur =
                                  (it['durationSec'] as num?)?.toDouble() ??
                                  0.0;
                              return ListTile(
                                key: ValueKey('fav_${it['videoUrl']}_$i'),
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isPinned)
                                      const Icon(
                                        Icons.push_pin,
                                        color: Colors.orange,
                                        size: 16,
                                      ),
                                    if (isPinned) const SizedBox(width: 4),
                                    if (downloaded)
                                      const Icon(
                                        Icons.download_done_rounded,
                                        color: Colors.green,
                                      )
                                    else
                                      const Icon(
                                        Icons.video_library_outlined,
                                        color: Colors.grey,
                                      ),
                                  ],
                                ),
                                title: Text(
                                  title.isNotEmpty ? title : pageUrl,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${_fmtSec(pos)} / ${_fmtSec(dur)} · ${_fmtFavoriteDate(favoritedAt)}${downloaded ? ' · 已下载' : ''}',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                ),
                                onTap: () {
                                  Navigator.of(sheetCtx).pop();
                                  _openFavoriteInBrowser(
                                    Map<String, dynamic>.from(it),
                                  );
                                },
                                trailing: PopupMenuButton<String>(
                                  onSelected: (v) {
                                    unawaited(() async {
                                      if (v == 'pin') {
                                        final currentPinned =
                                            it['pinned'] == true;
                                        it['pinned'] = !currentPinned;
                                        // 如果是置顶，移到最前面（在现有置顶之后，或最前面）
                                        if (it['pinned'] == true) {
                                          favorites.removeAt(i);
                                          favorites.insert(0, it);
                                        }
                                        await _saveSharedFavoriteVideos(
                                          favorites,
                                        );
                                        setSheetState(() {});
                                      } else if (v == 'download') {
                                        final ok = await _downloadOneFavorite(
                                          item: it,
                                          showResultHint: true,
                                        );
                                        if (ok) {
                                          it['downloaded'] = true;
                                          it['downloadedAt'] =
                                              DateTime.now().toIso8601String();
                                          await _saveSharedFavoriteVideos(
                                            favorites,
                                          );
                                          setSheetState(() {});
                                        }
                                      } else if (v == 'locate' || v == 'play') {
                                        Navigator.of(sheetCtx).pop();
                                        await Future<void>.delayed(
                                          const Duration(milliseconds: 180),
                                        );
                                        await _openDownloadedFavorite(
                                          Map<String, dynamic>.from(it),
                                          locate: v == 'locate',
                                        );
                                      } else if (v == 'redownload') {
                                        Navigator.of(sheetCtx).pop();
                                        await Future<void>.delayed(
                                          const Duration(milliseconds: 180),
                                        );
                                        await _redownloadFavorite(
                                          Map<String, dynamic>.from(it),
                                        );
                                      } else if (v == 'rename') {
                                        final renamed =
                                            await _promptRenameFavorite(
                                              context: context,
                                              initialText:
                                                  title.isNotEmpty
                                                      ? title
                                                      : pageUrl,
                                            );
                                        if (renamed != null) {
                                          it['customName'] = renamed;
                                          await _saveSharedFavoriteVideos(
                                            favorites,
                                          );
                                          setSheetState(() {});
                                        }
                                      } else if (v == 'delete') {
                                        favorites.removeAt(i);
                                        await _saveSharedFavoriteVideos(
                                          favorites,
                                        );
                                        setSheetState(() {});
                                      }
                                    }());
                                  },
                                  itemBuilder:
                                      (_) => [
                                        PopupMenuItem(
                                          value: 'pin',
                                          child: Text(
                                            it['pinned'] == true
                                                ? '取消置顶'
                                                : '置顶视频',
                                          ),
                                        ),
                                        if (downloaded) ...const [
                                          PopupMenuItem(
                                            value: 'locate',
                                            child: Text('查看位置'),
                                          ),
                                          PopupMenuItem(
                                            value: 'play',
                                            child: Text('直接播放'),
                                          ),
                                          PopupMenuItem(
                                            value: 'redownload',
                                            child: Text('重新下载'),
                                          ),
                                        ] else
                                          const PopupMenuItem(
                                            value: 'download',
                                            child: Text('下载到媒体库'),
                                          ),
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('重命名'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('删除收藏'),
                                        ),
                                      ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ),
    );
  }

  void _openFavoriteInBrowser(Map<String, dynamic> item) {
    final pageUrl = (item['pageUrl'] ?? '').toString().trim();
    final videoUrl = (item['videoUrl'] ?? '').toString().trim();
    final target =
        pageUrl.isNotEmpty ? pageUrl : (videoUrl.isNotEmpty ? videoUrl : '');
    if (target.isEmpty) return;
    _loadUrl(target);
  }

  Future<void> _openDownloadedFavorite(
    Map<String, dynamic> item, {
    required bool locate,
  }) async {
    final existing = await _findExistingMediaForItem(item);
    if (!mounted) return;
    if (existing == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未在媒体库中找到该视频，可尝试重新下载')));
      return;
    }
    if (locate) {
      await _openMediaLibraryAt(existing);
      return;
    }
    final mediaItem = MediaItem.fromMap(Map<String, dynamic>.from(existing));
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => MediaPreviewPage(mediaItems: [mediaItem], initialIndex: 0),
      ),
    );
  }

  Future<bool> _redownloadFavorite(Map<String, dynamic> item) async {
    final retryItem = Map<String, dynamic>.from(item)
      ..['allowSourceUrlReuse'] = true;
    return _downloadOneFavorite(item: retryItem, showResultHint: true);
  }

  bool _isLikelyDirectMediaUrl(String url) {
    final u = url.trim().toLowerCase();
    if (u.isEmpty) return false;
    if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
    if (u.startsWith('blob:') || u.startsWith('data:')) return false;
    return u.contains('.m3u8') ||
        u.contains('.mpd') ||
        u.contains('.mp4') ||
        u.contains('.webm') ||
        u.contains('.mov') ||
        u.contains('/hls/') ||
        u.contains('/manifest') ||
        u.contains('/stream');
  }

  Future<String?> _resolveFavoriteDownloadUrl({
    required String pageUrl,
    required String videoUrl,
  }) async {
    if (_isLikelyDirectMediaUrl(videoUrl) ||
        _isTrustedMediaCandidate(videoUrl)) {
      return videoUrl;
    }
    if (_isLikelyDirectMediaUrl(pageUrl) || _isTrustedMediaCandidate(pageUrl)) {
      return pageUrl;
    }
    if (pageUrl.isEmpty ||
        !(pageUrl.startsWith('http://') || pageUrl.startsWith('https://'))) {
      return null;
    }
    try {
      final networkService = NetworkService();
      await networkService.initialize();
      final pageHeaders = await _browserLikeMediaHeaders(
        pageUrl,
        referer: pageUrl,
        accept:
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      final resp = await networkService.dio.get<String>(
        pageUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: pageHeaders,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final html = (resp.data ?? '')
          .replaceAll(r'\/', '/')
          .replaceAll(r'\u002F', '/')
          .replaceAll(r'\u002f', '/')
          .replaceAll('&amp;', '&');
      if (html.isEmpty) return null;
      final baseUri = Uri.tryParse(pageUrl);
      if (baseUri == null) return null;
      final candidates = <String>{};
      final re = RegExp(
        r"""https?:\/\/[^"'\s<>]+?(?:\.m3u8|\.mp4|\.webm|\.mov)(?:\?[^"'\s<>]*)?""",
        caseSensitive: false,
      );
      for (final m in re.allMatches(html)) {
        final v = m.group(0)?.trim();
        if (v != null && v.isNotEmpty && _isLikelyDirectMediaUrl(v)) {
          candidates.add(v);
        }
      }
      final relRe = RegExp(
        r"""["']([^"']+?(?:\.m3u8|\.mp4|\.webm|\.mov)(?:\?[^"']*)?)["']""",
        caseSensitive: false,
      );
      for (final m in relRe.allMatches(html)) {
        final rel = m.group(1)?.trim();
        if (rel == null || rel.isEmpty) continue;
        final abs = baseUri.resolve(rel).toString();
        if (_isLikelyDirectMediaUrl(abs)) {
          candidates.add(abs);
        }
      }
      final scriptRe = RegExp(
        r"""setVideoUrl(?:High|Low|HLS)\(['"]([^'"]+)['"]\)""",
        caseSensitive: false,
      );
      for (final m in scriptRe.allMatches(html)) {
        final v = m.group(1)?.trim();
        if (v != null && v.isNotEmpty) {
          final abs = baseUri.resolve(v).toString();
          if (_isLikelyDirectMediaUrl(abs)) {
            candidates.add(abs);
          }
        }
      }
      if (candidates.isEmpty) return null;
      final primary = videoUrl.isNotEmpty ? videoUrl : pageUrl;
      return _chooseBestFavoriteVideoUrl(primary, candidates.toList());
    } catch (_) {
      return null;
    }
  }

  bool _isXVideoLikeHost(String url) {
    final s = url.toLowerCase();
    return s.contains('xvideos.') ||
        s.contains('xvideos-cdn') ||
        s.contains('xv-vod') ||
        s.contains('xhcdn');
  }

  bool _isTikPornPage(String? url) {
    final host = Uri.tryParse((url ?? '').trim())?.host.toLowerCase() ?? '';
    return host == 'tik.porn' || host.endsWith('.tik.porn');
  }

  bool _is91ContentPage(String? url) {
    final uri = Uri.tryParse((url ?? '').trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (host != '91cg1.com' && !host.endsWith('.91cg1.com')) return false;
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    return segments.length >= 2 &&
        segments.first.toLowerCase() == 'archives' &&
        RegExp(r'^\d+$').hasMatch(segments[1]);
  }

  String _smartStablePageKey(String pageUrl) {
    if (!_is91ContentPage(pageUrl)) return '';
    final uri = Uri.tryParse(pageUrl.trim());
    if (uri == null) return '';
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    return '$host/archives/${segments[1]}';
  }

  bool _isSame91TaskPage(String left, String right) {
    final leftKey = _smartStablePageKey(left);
    final rightKey = _smartStablePageKey(right);
    if (leftKey.isNotEmpty || rightKey.isNotEmpty) {
      return leftKey.isNotEmpty && leftKey == rightKey;
    }
    return _isSameLoadedDocument(left, right);
  }

  bool _isElementBoundFeedPage(String? url) {
    final host = Uri.tryParse((url ?? '').trim())?.host.toLowerCase() ?? '';
    return host == 'tik.porn' ||
        host.endsWith('.tik.porn') ||
        host == 'pin.porn' ||
        host.endsWith('.pin.porn') ||
        host == 'x.com' ||
        host.endsWith('.x.com') ||
        host == 'twitter.com' ||
        host.endsWith('.twitter.com');
  }

  bool _looksLikePreviewClipUrl(String u) {
    final s = u.toLowerCase();
    const hints = [
      'preview',
      'sample',
      'trailer',
      'teaser',
      'thumb',
      'poster',
      'storyboard',
      'sprite',
      'clip',
      'snippet',
      'init.',
      '/init',
      '.m4s',
      '/seg',
      '/chunk',
      '/fragment',
    ];
    return hints.any(s.contains);
  }

  bool _looksLikeMediaFragmentUrl(String url) {
    return isMediaFragmentUrl(url);
  }

  int _scoreFavoriteVideoUrl(String url) {
    final s = url.toLowerCase();
    var score = 0;
    if (_isLikelyAdUrl(s)) score -= 5000;
    if (s.contains('.m3u8') || s.contains('.m3u')) score += 1800;
    if (s.contains('.mpd')) score += 1700;
    if (s.contains('mpegurl') ||
        s.contains('/hls/') ||
        s.contains('/playlist')) {
      score += 1200;
    }
    if (s.contains('.mp4')) score += 900;
    if (s.contains('.webm')) score += 450;
    if (_isXVideoLikeHost(s)) score += 500;
    if (s.contains('setvideourlhigh') || s.contains('high')) score += 220;
    if (_looksLikePreviewClipUrl(s)) score -= 1200;
    return score;
  }

  List<String> _buildFavoriteAttempts(
    String primary,
    List<String> candidates, {
    bool preservePrimary = false,
  }) {
    final merged = <String>[];
    final seen = <String>{};
    void push(String? u) {
      if (u == null) return;
      final s = u.trim();
      if (s.isEmpty) return;
      final abs = _toAbsoluteUrl(s);
      if (abs.isEmpty ||
          seen.contains(abs) ||
          _isLikelyAdUrl(abs) ||
          _looksLikeMediaFragmentUrl(abs)) {
        return;
      }
      seen.add(abs);
      merged.add(abs);
    }

    push(primary);
    for (final c in candidates) {
      push(c);
    }
    final insertionOrder = <String, int>{
      for (var i = 0; i < merged.length; i++) merged[i]: i,
    };
    int compareCandidates(String a, String b) {
      final aScore =
          _xMediaIdentity(a).isNotEmpty
              ? _scoreXVideoCandidate(a)
              : _scoreFavoriteVideoUrl(a);
      final bScore =
          _xMediaIdentity(b).isNotEmpty
              ? _scoreXVideoCandidate(b)
              : _scoreFavoriteVideoUrl(b);
      final scoreOrder = bScore.compareTo(aScore);
      if (scoreOrder != 0) return scoreOrder;
      return insertionOrder[a]!.compareTo(insertionOrder[b]!);
    }

    if (preservePrimary && merged.length > 1) {
      final primaryUrl = merged.first;
      final fallbacks = merged.sublist(1)..sort(compareCandidates);
      return <String>[primaryUrl, ...fallbacks];
    }
    merged.sort(compareCandidates);
    return merged;
  }

  String _chooseBestFavoriteVideoUrl(String primary, List<String> candidates) {
    final attempts = _buildFavoriteAttempts(primary, candidates);
    return attempts.isEmpty ? primary : attempts.first;
  }

  Future<List<String>> _resniffFavoriteCandidatesFromSourcePage(
    String pageUrl,
  ) async {
    if (pageUrl.isEmpty ||
        !(pageUrl.startsWith('http://') || pageUrl.startsWith('https://'))) {
      return const <String>[];
    }
    try {
      final networkService = NetworkService();
      await networkService.initialize();
      final pageHeaders = await _browserLikeMediaHeaders(
        pageUrl,
        referer: pageUrl,
        accept:
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      final resp = await networkService.dio.get<String>(
        pageUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: pageHeaders,
        ),
      );
      final html = (resp.data ?? '')
          .replaceAll(r'\/', '/')
          .replaceAll(r'\u002F', '/')
          .replaceAll(r'\u002f', '/')
          .replaceAll('&amp;', '&');
      if (html.isEmpty) return const <String>[];
      final baseUri = Uri.tryParse(pageUrl);
      if (baseUri == null) return const <String>[];
      final out = <String>{};
      void addCandidate(String? raw) {
        if (raw == null) return;
        final s = raw.trim();
        if (s.isEmpty) return;
        final abs = baseUri.resolve(s).toString();
        if (_isLikelyDirectMediaUrl(abs)) out.add(abs);
      }

      final genericDirect = RegExp(
        r"""https?:\/\/[^"'\s<>]+?(?:\.m3u8|\.mp4|\.webm|\.mov)(?:\?[^"'\s<>]*)?""",
        caseSensitive: false,
      );
      for (final m in genericDirect.allMatches(html)) {
        addCandidate(m.group(0));
      }

      final xvideoJs = RegExp(
        r"""setVideoUrl(?:High|Low|HLS)\(['"]([^'"]+)['"]\)""",
        caseSensitive: false,
      );
      for (final m in xvideoJs.allMatches(html)) {
        addCandidate(m.group(1));
      }

      final schemaVideo = RegExp(
        r'''"contentUrl"\s*:\s*"([^"]+)"''',
        caseSensitive: false,
      );
      for (final m in schemaVideo.allMatches(html)) {
        addCandidate(m.group(1));
      }

      final playerConfigUrl = RegExp(
        r'''["'](?:url|file|src|source|videoUrl|playUrl|hls|manifest)["']\s*:\s*["']([^"']+)["']''',
        caseSensitive: false,
      );
      for (final m in playerConfigUrl.allMatches(html)) {
        addCandidate(m.group(1));
      }

      final dataSrc = RegExp(
        r'''(?:data-src|src)\s*=\s*["']([^"']+\.(?:m3u8|mp4|webm|mov)(?:\?[^"']*)?)["']''',
        caseSensitive: false,
      );
      for (final m in dataSrc.allMatches(html)) {
        addCandidate(m.group(1));
      }
      return out.toList();
    } catch (_) {
      return const <String>[];
    }
  }

  Future<bool> _downloadOneFavorite({
    required Map<String, dynamic> item,
    bool showResultHint = false,
    bool showModalDialog = false,
    void Function(String failureType)? onFailureType,
  }) async {
    return _downloadMediaRobustly(
      item: item,
      showResultHint: showResultHint,
      showModalDialog: showModalDialog, // 允许外部控制是否显示弹窗
      onFailureType: onFailureType,
    );
  }

  /// 稳健下载媒体：具备多候选重试、自动嗅探补偿和全局进度对话框。
  /// 用于收藏栏下载和网页长按下载，解决 XVideo 等站点直接下载 Blob 导致的断流或文件残缺问题。
  Future<bool> _downloadMediaRobustly({
    required Map<String, dynamic> item,
    bool showResultHint = false,
    bool showModalDialog = false, // 是否显示全局阻塞式进度弹窗
    void Function(String failureType)? onFailureType,
    int? minFileBytes,
    int? maxFileBytes,
  }) async {
    final isLongPress = item['downloadOrigin'] == 'long_press';
    final isSmartBatch = item['downloadOrigin'] == 'smart_batch';
    final isSmartGesture = item['isSmartGesture'] == true;
    final isSmartDownload = isSmartBatch || isSmartGesture;
    final smartTask =
        item['smartTask'] is Map<String, dynamic>
            ? item['smartTask'] as Map<String, dynamic>
            : null;
    if (isSmartGesture) smartTask?.remove('lastGestureFailureType');
    final existingMedia = await _findExistingMediaForItem(item);
    if (existingMedia != null && item['allowSourceUrlReuse'] != true) {
      if (isSmartDownload) {
        if (isSmartGesture) {
          smartTask?['lastGestureFailureType'] = 'already_in_library';
        }
        onFailureType?.call('already_in_library');
        return false;
      }
      final downloadAnyway = await _confirmSourceUrlDuplicateBeforeDownload(
        existingMedia,
      );
      if (!downloadAnyway) {
        await _markFavoriteDownloaded(item, downloaded: true);
        onFailureType?.call('already_in_library');
        return true;
      }
      // URL matches are only hints. The downloaded content hash remains the
      // authoritative duplicate check for dynamic and signed media URLs.
    }
    final pageUrl = (item['pageUrl'] ?? '').toString().trim();
    final videoUrl = (item['videoUrl'] ?? '').toString().trim();
    final candidateRaw = item['candidateUrls'];
    final candidateUrls = <String>[];
    if (candidateRaw is List) {
      for (final e in candidateRaw) {
        if (e is String && e.trim().isNotEmpty) {
          candidateUrls.add(e.trim());
        }
      }
    }
    if (!isLongPress) {
      candidateUrls.addAll(
        _recentCapturedMediaCandidates(MediaType.video, pageUrl: pageUrl),
      );
    }
    var downloadUrl =
        isLongPress
            ? videoUrl
            : await _resolveFavoriteDownloadUrl(
              pageUrl: pageUrl,
              videoUrl: videoUrl,
            );
    if ((downloadUrl == null || downloadUrl.isEmpty) &&
        candidateUrls.isNotEmpty) {
      final directCandidates =
          candidateUrls
              .where(
                (url) =>
                    _isLikelyDirectMediaUrl(url) ||
                    _isCapturedVideoCandidate(url) ||
                    _isTrustedMediaCandidate(url),
              )
              .toList();
      if (directCandidates.isNotEmpty) {
        downloadUrl = _chooseBestFavoriteVideoUrl(
          videoUrl.isNotEmpty ? videoUrl : directCandidates.first,
          directCandidates,
        );
      }
    }
    if (downloadUrl == null || downloadUrl.isEmpty) {
      if (isSmartGesture) {
        smartTask?['lastGestureFailureType'] = 'no_direct_url';
      }
      onFailureType?.call('no_direct_url');
      if (showResultHint && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该媒体缺少可下载的直链，请先在网页播放后再尝试'),
            duration: Duration(milliseconds: 1500),
          ),
        );
      }
      return false;
    }
    final progress = ValueNotifier<double?>(null);
    final detailNotifier = ValueNotifier<String>('准备下载...');
    var shownDialog = false;
    if (showModalDialog && mounted) {
      shownDialog = true;
      final mediaName = item['title'] ?? item['name'] ?? '未知媒体';
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'robust_media_download',
        barrierColor: Colors.black.withValues(alpha: 0.15),
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder:
            (_, __, ___) => Center(
              child: Container(
                width: 240,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<double?>(
                      valueListenable: progress,
                      builder: (_, p, __) {
                        if (p == null) {
                          return const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.greenAccent,
                              ),
                              backgroundColor: Colors.white24,
                            ),
                          );
                        }
                        return SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                            value: p.clamp(0.0, 1.0),
                            strokeWidth: 3,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.greenAccent,
                            ),
                            backgroundColor: Colors.white24,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '正在下载：$mediaName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ValueListenableBuilder<String>(
                      valueListenable: detailNotifier,
                      builder:
                          (_, t, __) => Text(
                            t,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
      );
    }
    final taskLenBefore = _downloadTasks.length;
    final attempts = _buildFavoriteAttempts(
      downloadUrl,
      candidateUrls
          .where(
            (url) =>
                _isLikelyDirectMediaUrl(url) ||
                _isCapturedVideoCandidate(url) ||
                _isTrustedMediaCandidate(url),
          )
          .toList(),
      // Once smart selection has bound a concrete media URL, keep it first
      // just like a long press. Fallback candidates are tried only on failure.
      preservePrimary:
          isLongPress ||
          (isSmartBatch &&
              (downloadUrl.startsWith('http://') ||
                  downloadUrl.startsWith('https://'))),
    );
    // X exposes a master playlist together with separate audio/video streams.
    // Keep one media ID per smart-download step and prefer the complete master.
    final smartXMediaId =
        isSmartBatch
            ? <String>[downloadUrl, videoUrl, ...attempts]
                .map(_xMediaIdentity)
                .firstWhere((id) => id.isNotEmpty, orElse: () => '')
            : '';
    Map<String, String>? smartVideoStates;
    if (smartTask != null && smartXMediaId.isNotEmpty) {
      final existingStates = smartTask['videoMediaStates'];
      smartVideoStates =
          existingStates is Map<String, String>
              ? existingStates
              : <String, String>{};
      smartTask['videoMediaStates'] = smartVideoStates;
      if (smartVideoStates.containsKey(smartXMediaId)) {
        if (isSmartGesture) {
          smartTask?['lastGestureFailureType'] = 'already_in_smart_task';
        }
        onFailureType?.call('already_in_smart_task');
        return false;
      }
      attempts.removeWhere((url) {
        final id = _xMediaIdentity(url);
        return id.isNotEmpty && id != smartXMediaId;
      });
      attempts.sort(
        (left, right) =>
            _scoreXVideoCandidate(right).compareTo(_scoreXVideoCandidate(left)),
      );
      smartVideoStates[smartXMediaId] = 'downloading';
    }
    if (isLongPress && attempts.length > 3) {
      attempts.removeRange(3, attempts.length);
    } else if (isSmartBatch && attempts.length > 3) {
      // 智能批量任务应快速换媒体，不能在同一候选上无限消耗时间。
      attempts.removeRange(3, attempts.length);
    }
    detailNotifier.value = '已获取下载地址，准备开始...';
    if (_favoriteDownloadDiagnosticsEnabled) {
      Logger.log(
        '[稳健下载诊断] 开始: 候选总数=${attempts.length}, pageUrl=${pageUrl.isEmpty ? "-" : pageUrl}, videoUrl=${videoUrl.isEmpty ? "-" : videoUrl}',
      );
    }
    var ok = false;
    int successIndex = -1;
    var lastFailureType = 'unknown';
    for (int i = 0; i < attempts.length; i++) {
      final sw = Stopwatch()..start();
      var failureType = 'unknown';
      progress.value = null;
      detailNotifier.value = '候选 ${i + 1}/${attempts.length}：正在连接...';
      if (smartTask != null &&
          !_reserveSmartMediaName(
            smartTask,
            attempts[i],
            title: (item['title'] ?? '').toString(),
            pageUrl: pageUrl,
          )) {
        failureType = 'duplicate_name_in_smart_task';
        lastFailureType = failureType;
        detailNotifier.value = '同一任务已处理过同名媒体，正在换下一个';
        continue;
      }
      ok = await _performBackgroundDownload(
        attempts[i],
        MediaType.video,
        skipFailurePrompt: i < attempts.length - 1,
        onFailureType: (t) => failureType = t,
        inactivityTimeout:
            isSmartDownload
                ? const Duration(minutes: 2)
                : isLongPress
                ? const Duration(minutes: 2)
                : const Duration(minutes: 3),
        maxRequestAttempts:
            isSmartDownload
                ? 4
                : isLongPress
                ? 4
                : null,
        showSuccessPrompt: false,
        showDuplicatePrompt: !isSmartDownload,
        validateSmartMedia: isSmartDownload,
        isSmartBatchMedia: isSmartDownload,
        smartTask: smartTask,
        smartMediaTitle: (item['title'] ?? '').toString(),
        smartPageUrl: pageUrl,
        minFileBytes: minFileBytes,
        maxFileBytes: maxFileBytes,
        onProgress: (fraction, {String? detail}) {
          progress.value = fraction.clamp(0.0, 1.0);
          if (detail != null && detail.trim().isNotEmpty) {
            detailNotifier.value = '候选 ${i + 1}/${attempts.length}：$detail';
          }
        },
      );
      sw.stop();
      lastFailureType = failureType;
      if (!ok && smartTask != null && failureType != 'already_in_library') {
        _releaseSmartMediaName(
          smartTask,
          attempts[i],
          title: (item['title'] ?? '').toString(),
          pageUrl: pageUrl,
        );
      }
      if (_favoriteDownloadDiagnosticsEnabled) {
        Logger.log(
          '[稳健下载诊断] 尝试#${i + 1}/${attempts.length}: ${ok ? "成功" : "失败"} | failureType=${ok ? "none" : failureType} | elapsedMs=${sw.elapsedMilliseconds} | url=${attempts[i]}',
        );
      }
      if (ok) {
        successIndex = i + 1;
        break;
      }
      if (failureType == 'library_save_failed' ||
          failureType == 'already_in_library' ||
          (failureType == 'outside_requested_size_range' &&
              item['downloadOrigin'] != 'smart_batch') ||
          failureType == 'cancelled') {
        break;
      }
      if (smartXMediaId.isNotEmpty &&
          failureType == 'invalid_smart_media_content') {
        // Remaining X candidates are normally lower renditions of the same
        // media ID. Re-downloading them wastes time without finding a new item.
        break;
      }
    }
    if (!ok &&
        !isLongPress &&
        !isSmartBatch &&
        lastFailureType != 'library_save_failed' &&
        lastFailureType != 'already_in_library' &&
        lastFailureType != 'cancelled' &&
        pageUrl.startsWith('http')) {
      detailNotifier.value = '第3步：重新打开源页并二次嗅探...';
      final resniffCandidates = await _resniffFavoriteCandidatesFromSourcePage(
        pageUrl,
      );
      if (resniffCandidates.isNotEmpty) {
        final tried = attempts.toSet();
        final secondAttempts =
            _buildFavoriteAttempts(downloadUrl, [
              ...candidateUrls,
              ...resniffCandidates,
            ]).where((u) => !tried.contains(u)).toList();
        for (int i = 0; i < secondAttempts.length; i++) {
          final sw = Stopwatch()..start();
          var failureType = 'unknown';
          progress.value = null;
          detailNotifier.value =
              '二次嗅探候选 ${i + 1}/${secondAttempts.length}：正在连接...';
          ok = await _performBackgroundDownload(
            secondAttempts[i],
            MediaType.video,
            skipFailurePrompt: i < secondAttempts.length - 1,
            onFailureType: (t) => failureType = t,
            inactivityTimeout: const Duration(minutes: 3),
            showSuccessPrompt: false,
            showDuplicatePrompt: !isSmartDownload,
            validateSmartMedia: isSmartDownload,
            isSmartBatchMedia: isSmartDownload,
            smartTask: smartTask,
            smartMediaTitle: (item['title'] ?? '').toString(),
            smartPageUrl: pageUrl,
            minFileBytes: minFileBytes,
            maxFileBytes: maxFileBytes,
            onProgress: (fraction, {String? detail}) {
              progress.value = fraction.clamp(0.0, 1.0);
              if (detail != null && detail.trim().isNotEmpty) {
                detailNotifier.value =
                    '二次嗅探候选 ${i + 1}/${secondAttempts.length}：$detail';
              }
            },
          );
          sw.stop();
          lastFailureType = failureType;
          if (_favoriteDownloadDiagnosticsEnabled) {
            Logger.log(
              '[稳健下载诊断] 二次嗅探尝试#${i + 1}/${secondAttempts.length}: ${ok ? "成功" : "失败"} | failureType=${ok ? "none" : failureType} | elapsedMs=${sw.elapsedMilliseconds} | url=${secondAttempts[i]}',
            );
          }
          if (ok) {
            break;
          }
          if (failureType == 'library_save_failed' ||
              failureType == 'already_in_library' ||
              (failureType == 'outside_requested_size_range' &&
                  item['downloadOrigin'] != 'smart_batch') ||
              failureType == 'cancelled') {
            break;
          }
        }
      } else {
        lastFailureType = 'resniff_no_candidate';
      }
    }
    if (_favoriteDownloadDiagnosticsEnabled) {
      Logger.log(
        '[稳健下载诊断] 结束: ${ok ? "成功" : "失败"} | 命中候选=${ok ? successIndex : 0}',
      );
    }
    if (smartVideoStates != null && smartXMediaId.isNotEmpty) {
      smartVideoStates[smartXMediaId] = ok ? 'completed' : 'failed';
    }
    if (_downloadTasks.length > taskLenBefore) {
      final last = _downloadTasks.first;
      final p = (last['progress'] as num?)?.toDouble();
      progress.value = p == null ? null : p.clamp(0.0, 1.0);
      final d = (last['progressDetail'] ?? '').toString();
      detailNotifier.value = d.isNotEmpty ? d : (ok ? '下载完成，正在入库...' : '下载失败');
    }
    progress.value = 1.0;
    detailNotifier.value = ok ? '已保存到媒体库' : '下载失败';
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (shownDialog && mounted) {
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }
    progress.dispose();
    detailNotifier.dispose();
    if (!ok) {
      if (isSmartGesture) {
        smartTask?['lastGestureFailureType'] = lastFailureType;
      }
      onFailureType?.call(lastFailureType);
    }
    if (ok && lastFailureType != 'already_downloading') {
      await _markFavoriteDownloaded(item, downloaded: true);
    }
    if (showResultHint && mounted && lastFailureType != 'already_in_library') {
      final canView = ok || lastFailureType == 'already_in_library';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (isLongPress ? '已保存当前长按的媒体' : '已加入下载：$downloadUrl')
                : (lastFailureType == 'library_save_failed'
                    ? '文件已下载，但写入媒体库失败；已停止重复下载'
                    : lastFailureType == 'already_in_library'
                    ? '媒体库中已存在相同文件，未重复保存'
                    : (isLongPress ? '当前长按的媒体保存失败，已停止尝试' : '下载失败，请稍后重试')),
          ),
          duration: Duration(seconds: canView ? 3 : 2),
          action:
              canView
                  ? SnackBarAction(label: '查看', onPressed: _openMediaLibrary)
                  : null,
        ),
      );
    }
    return ok;
  }

  bool _isRetryableFavoriteFailure(String failureType) {
    return failureType == 'timeout' ||
        failureType == 'connection_error' ||
        failureType == 'dio_error' ||
        failureType == 'http_5xx';
  }

  Future<void> _downloadFavoritesBatch(
    List<Map<String, dynamic>> items, {
    bool forceRedownload = false,
  }) async {
    if (items.isEmpty || !mounted) return;
    final batchTaskId = const Uuid().v4();
    final batchCancelToken = CancelToken();
    var success = 0;
    var failed = 0;
    var skipped = 0;
    var retried = 0;
    var processed = 0;
    final retryQueue = <Map<String, dynamic>>[];
    _addDownloadTask(
      batchTaskId,
      'favorite-batch://$batchTaskId',
      MediaType.video,
      batchCancelToken,
      displayName:
          forceRedownload
              ? '收藏批量重新下载（${items.length}）'
              : '收藏批量下载（${items.length}）',
      isFavoriteBatch: true,
    );

    void updateBatchProgress(String currentName, {bool retrying = false}) {
      final baseProgress = processed / items.length;
      _updateDownloadTask(
        batchTaskId,
        progress: (retrying ? 0.75 + baseProgress * 0.24 : baseProgress * 0.75)
            .clamp(0.0, 0.99),
        progressDetail:
            '${retrying ? "正在重试" : "已处理"} $processed/${items.length} · '
            '成功 $success · 跳过 $skipped · 当前：$currentName',
      );
    }

    try {
      for (int i = 0; i < items.length; i++) {
        if (batchCancelToken.isCancelled) break;
        final currentItem = items[i];
        final currentName =
            (currentItem['title'] ?? currentItem['name'] ?? '未知媒体').toString();
        updateBatchProgress(currentName);

        if (!forceRedownload && _isFavoriteLikelyDownloaded(currentItem)) {
          skipped++;
          processed++;
          updateBatchProgress(currentName);
          continue;
        }
        final downloadItem = Map<String, dynamic>.from(currentItem);
        if (forceRedownload) {
          downloadItem['allowSourceUrlReuse'] = true;
        }
        var failureType = 'unknown';
        final ok = await _downloadOneFavorite(
          item: downloadItem,
          showResultHint: false,
          showModalDialog: false, // 批量下载时，不显示单个文件的弹窗
          onFailureType: (t) => failureType = t,
        );
        if (ok) {
          success++;
        } else {
          failed++;
          if (_isRetryableFavoriteFailure(failureType)) {
            retryQueue.add(Map<String, dynamic>.from(currentItem));
          }
        }
        processed++;
        updateBatchProgress(currentName);
      }
      if (retryQueue.isNotEmpty && !batchCancelToken.isCancelled) {
        for (int j = 0; j < retryQueue.length; j++) {
          if (batchCancelToken.isCancelled) break;
          final currentItem = retryQueue[j];
          final currentName =
              (currentItem['title'] ?? currentItem['name'] ?? '未知媒体')
                  .toString();
          updateBatchProgress(currentName, retrying: true);

          retried++;
          await Future<void>.delayed(const Duration(milliseconds: 320));
          final ok = await _downloadOneFavorite(
            item: Map<String, dynamic>.from(currentItem)
              ..['allowSourceUrlReuse'] = forceRedownload,
            showResultHint: false,
            showModalDialog: false, // 重试时同样不显示单个文件弹窗
          );
          if (ok) {
            success++;
            failed--;
          }
          _updateDownloadTask(
            batchTaskId,
            progress: (0.75 + ((j + 1) / retryQueue.length) * 0.24).clamp(
              0.0,
              0.99,
            ),
            progressDetail:
                '重试 ${j + 1}/${retryQueue.length} · 成功 $success · 跳过 $skipped · 当前：$currentName',
          );
        }
      }
    } finally {
      final cancelled = batchCancelToken.isCancelled;
      _updateDownloadTask(
        batchTaskId,
        status: cancelled ? 'cancelled' : 'completed',
        progress: cancelled ? (processed / items.length).clamp(0.0, 1.0) : 1.0,
        progressDetail:
            cancelled
                ? '已停止：成功 $success，失败 $failed，跳过 $skipped'
                : '完成：成功 $success，失败 $failed，跳过 $skipped',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cancelled
                  ? '批量下载已停止：成功 $success 条，失败 $failed 条，跳过 $skipped 条'
                  : '${forceRedownload ? "批量重新下载" : "批量下载"}完成：成功 $success 条，失败 $failed 条，跳过 $skipped 条',
            ),
            duration: const Duration(milliseconds: 1500),
          ),
        );
        if (retried > 0 && !cancelled) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('二轮重试已执行：$retried 条（仅超时/网络类失败）'),
              duration: const Duration(milliseconds: 1300),
            ),
          );
        }
      }
    }
  }

  Future<void> _saveVideoSourceUrlMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kVideoSourceUrlMapPrefsKey,
        jsonEncode(_videoSourceUrlToMediaId),
      );
    } catch (e) {
      debugPrint('保存视频来源映射失败: $e');
    }
  }

  String _normalizeVideoSourceUrl(String url) {
    final uri = Uri.tryParse(_toAbsoluteUrl(url));
    if (uri == null) return url;
    const ignoredParams = <String>{
      'token',
      'sig',
      'signature',
      'expires',
      'expire',
      'exp',
      'auth',
      'auth_key',
      'x-amz-signature',
      'x-amz-date',
      'x-amz-credential',
      'x-amz-security-token',
      'x-amz-algorithm',
      'x-amz-expires',
      'x-signature',
    };
    final keptEntries = <MapEntry<String, String>>[];
    for (final e in uri.queryParametersAll.entries) {
      final key = e.key.toLowerCase();
      if (ignoredParams.contains(key)) continue;
      for (final value in e.value) {
        keptEntries.add(MapEntry(e.key, value));
      }
    }
    keptEntries.sort((a, b) {
      final c = a.key.compareTo(b.key);
      if (c != 0) return c;
      return a.value.compareTo(b.value);
    });
    final query = keptEntries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return uri.replace(query: query, fragment: '').toString();
  }

  Future<String> _resolveMediaLocationLabel(
    Map<String, dynamic> mediaRow,
  ) async {
    final dir = mediaRow['directory']?.toString() ?? '';
    if (dir.isEmpty || dir == 'root') return '根目录';
    if (dir == 'favorites') return '收藏夹';
    if (dir == 'recycle_bin') return '回收站';
    final parent = await _databaseService.getMediaItemById(dir);
    final name = parent?['name']?.toString();
    if (name != null && name.isNotEmpty) return name;
    return dir;
  }

  Future<Map<String, dynamic>?> _findExistingVideoBySourceUrl(
    String url,
  ) async {
    final normalized = _normalizeVideoSourceUrl(url);
    final mediaId = _videoSourceUrlToMediaId[normalized];
    if (mediaId == null || mediaId.isEmpty) return null;
    final row = await _databaseService.getMediaItemById(mediaId);
    if (row == null) {
      _videoSourceUrlToMediaId.remove(normalized);
      await _saveVideoSourceUrlMap();
      return null;
    }
    final type = DatabaseService.mediaTypeIndex(row);
    if (type != MediaType.video.index) return null;
    final directory = row['directory']?.toString() ?? '';
    // 仅将「当前媒体库可见/可用」的视频视为已存在；回收站中的旧记录不阻止再次下载。
    if (directory == 'recycle_bin') {
      _videoSourceUrlToMediaId.remove(normalized);
      await _saveVideoSourceUrlMap();
      return null;
    }
    final path = row['path']?.toString() ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      _videoSourceUrlToMediaId.remove(normalized);
      await _saveVideoSourceUrlMap();
      return null;
    }
    return row;
  }

  Future<Map<String, dynamic>?> _findExistingVideoBeforeDownload(
    String url,
  ) async {
    return _findExistingVideoBySourceUrl(url);
  }

  void _openMediaLibrary() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const MediaManagerPage(showRouteBackButton: true),
      ),
    );
  }

  Future<void> _openMediaLibraryAt(Map<String, dynamic> mediaRow) async {
    if (!mounted) return;
    final directory = (mediaRow['directory'] ?? 'root').toString().trim();
    final mediaId = (mediaRow['id'] ?? '').toString().trim();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => MediaManagerPage(
              showRouteBackButton: true,
              initialDirectoryId: directory.isEmpty ? 'root' : directory,
              highlightMediaId: mediaId.isEmpty ? null : mediaId,
            ),
      ),
    );
  }

  Future<void> _showMediaDuplicateDialog(
    Map<String, dynamic> existingRow,
  ) async {
    final smartTask = _smartDownloadTask;
    if (smartTask != null && smartTask['gestureDownloadPending'] == true) {
      smartTask['lastGestureFailureType'] = 'already_in_library';
      smartTask['duplicateSkipped'] =
          ((smartTask['duplicateSkipped'] as int?) ?? 0) + 1;
      debugPrint('智能下载检测到重复媒体：自动跳过，不显示阻塞弹窗');
      return;
    }
    // A direct download and its canvas/screenshot fallback can discover the
    // same duplicate almost simultaneously. Keep one prompt active through
    // the entire locate/preview flow so a late result cannot cover that page.
    if (!mounted || _mediaDuplicateDialogActive) return;
    final duplicateKey = <Object?>[
          existingRow['id'],
          existingRow['file_hash'],
          existingRow['path'],
          existingRow['name'],
        ]
        .map((value) => value?.toString().trim() ?? '')
        .firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => existingRow.toString(),
        );
    final now = DateTime.now();
    _recentDuplicatePromptTimes.removeWhere(
      (_, promptedAt) =>
          now.difference(promptedAt) > const Duration(minutes: 2),
    );
    final lastPromptedAt = _recentDuplicatePromptTimes[duplicateKey];
    if (lastPromptedAt != null &&
        now.difference(lastPromptedAt) < _duplicatePromptCooldown) {
      return;
    }
    _recentDuplicatePromptTimes[duplicateKey] = now;
    _mediaDuplicateDialogActive = true;
    try {
      final location = await _resolveMediaLocationLabel(existingRow);
      if (!mounted) return;
      final mediaType = DatabaseService.mediaTypeIndex(existingRow);
      final mediaLabel = mediaType == MediaType.image.index ? '图片' : '视频';
      final title = existingRow['name']?.toString() ?? '该$mediaLabel';
      final mediaItem = MediaItem.fromMap(
        Map<String, dynamic>.from(existingRow),
      );
      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text('$mediaLabel已存在'),
            content: Text('媒体库中已经有这个$mediaLabel了。\n\n文件名：$title\n位置：$location'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop('locate'),
                child: const Text('定位查看'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop('preview'),
                child: const Text('直接查看'),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      if (action == 'locate') {
        await _openMediaLibraryAt(existingRow);
      } else if (action == 'preview') {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) =>
                    MediaPreviewPage(mediaItems: [mediaItem], initialIndex: 0),
          ),
        );
      }
    } finally {
      // Refresh on return from preview/library. Delayed canvas or screenshot
      // results from the same long press may only finish after this route pops.
      _recentDuplicatePromptTimes[duplicateKey] = DateTime.now();
      _mediaDuplicateDialogActive = false;
    }
  }

  Future<bool> _confirmSourceUrlDuplicateBeforeDownload(
    Map<String, dynamic> existingRow,
  ) async {
    if (!mounted || _mediaDuplicateDialogActive) return false;
    _mediaDuplicateDialogActive = true;
    try {
      final location = await _resolveMediaLocationLabel(existingRow);
      if (!mounted) return false;
      final mediaType = DatabaseService.mediaTypeIndex(existingRow);
      final mediaLabel = mediaType == MediaType.image.index ? '图片' : '视频';
      final title = existingRow['name']?.toString() ?? '该$mediaLabel';
      final mediaItem = MediaItem.fromMap(
        Map<String, dynamic>.from(existingRow),
      );
      final action = await showDialog<String>(
        context: context,
        builder:
            (dialogContext) => AlertDialog(
              title: Text('发现疑似重复$mediaLabel'),
              content: Text(
                '根据网页下载地址，媒体库中可能已有这个$mediaLabel。'
                '部分网站会为不同媒体复用同一地址，你可以继续下载并由文件内容再次准确查重。'
                '\n\n文件名：$title\n位置：$location',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('不下载'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('locate'),
                  child: const Text('定位查看'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop('preview'),
                  child: const Text('直接查看'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop('download'),
                  child: const Text('仍然下载'),
                ),
              ],
            ),
      );
      if (!mounted) return false;
      if (action == 'locate') {
        await _openMediaLibraryAt(existingRow);
      } else if (action == 'preview') {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (context) =>
                    MediaPreviewPage(mediaItems: [mediaItem], initialIndex: 0),
          ),
        );
      }
      return action == 'download';
    } finally {
      _mediaDuplicateDialogActive = false;
    }
  }

  Future<void> _requestPermissions() async {
    var storageStatus = await Permission.storage.request();
    debugPrint('存储权限状态: $storageStatus');
    if (Platform.isAndroid) {
      var manageStorageStatus =
          await Permission.manageExternalStorage.request();
      debugPrint('管理外部存储权限状态: $manageStorageStatus');
    }
    var recordStatus = await Permission.microphone.request();
    debugPrint('录音权限状态: $recordStatus');
  }

  void _setupWebViewController(InAppWebViewController ctrl) {
    _controller = ctrl;
    ctrl.addJavaScriptHandler(
      handlerName: 'Flutter',
      callback: (args) {
        if (args.isNotEmpty && args[0] != null) {
          debugPrint('来自JavaScript的消息: ${args[0]}');
          _handleJavaScriptMessage(args[0].toString());
        }
      },
    );
  }

  bool _isYouTubeLink(String url) {
    return url.contains('youtube.com') || url.contains('youtu.be');
  }

  final Set<String> _downloadingUrls = {};
  final Map<String, String> _videoSourceUrlToMediaId = {};
  static const String _kVideoSourceUrlMapPrefsKey =
      'browser_video_source_url_map_v1';

  /// 记录非 Base64 媒体 URL 最近一次开始处理的时间；与 [markMediaUrlProcessing] 配合，避免永久占用。
  final Map<String, DateTime> _processedMediaUrlsSince = {};
  bool _awaitingCanvasFallbackResult = false;
  bool _canvasFallbackSucceeded = false;
  Completer<bool>? _canvasFallbackCompleter;
  String _lastMediaHandlerFailureUrl = '';
  DateTime? _lastMediaHandlerFailureAt;

  bool _isSameLoadedDocument(String expected, String actual) {
    final expectedUri = Uri.tryParse(expected);
    final actualUri = Uri.tryParse(actual);
    if (expectedUri == null || actualUri == null) return expected == actual;
    return expectedUri.replace(fragment: '') == actualUri.replace(fragment: '');
  }

  Future<bool> _injectDownloadHandlers({
    bool allowRetry = true,
    String? expectedUrl,
  }) async {
    final controller = _controller;
    if (controller == null) return false;
    final injectionUrl =
        expectedUrl ?? (await controller.getUrl())?.toString() ?? _currentUrl;
    debugPrint('正在安装网页媒体长按处理程序');
    try {
      await controller.evaluateJavascript(
        source: '''
      (() => {
      const handlerVersion = 'media-download-v18';
      if (window.__appMediaDownloadHandlersVersion === handlerVersion) return true;
      window.Flutter = window.Flutter || { postMessage: function(m){ try { if(window.flutter_inappwebview && window.flutter_inappwebview.callHandler) window.flutter_inappwebview.callHandler('Flutter', m); } catch(e){} } };
      window.MediaInterceptor = window.MediaInterceptor || {
        processedUrls: new Set(),
        interceptedRequests: new Map(),
        blobUrls: new Map(),
        m3u8Segments: new Map(),
        mediaElements: new Set(),
        shadowRoots: new Set(),
        iframeContents: new Set(),
        dynamicContent: new Set()
      };
      try {
        const early = window.__appEarlyMediaRequests;
        if (early && typeof early.forEach === 'function') {
          early.forEach((info, requestUrl) => {
            const candidateUrl = normalizeMediaCandidateUrl(requestUrl);
            if (!candidateUrl) return;
            window.MediaInterceptor.interceptedRequests.set(candidateUrl, {
              method: 'GET',
              timestamp: (info && info.timestamp) || Date.now(),
              type: (info && info.source) || 'early',
              contentType: (info && info.contentType) || ''
            });
          });
        }
      } catch (_) {}

      // 增强的Blob URL检测
      function isBlobUrl(url) {
        return url && typeof url === 'string' && url.startsWith('blob:');
      }

      // 排除 API 接口（返回 JSON 而非媒体）- 但视频站 CDN 等需放行
      function isApiUrl(url) {
        if (!url) return false;
        if (url.startsWith('blob:') || url.startsWith('data:')) return false;
        if (isAdUrl(url)) return true; // 广告也视为不可直接作为媒体
        const lower = url.toLowerCase();
        try {
          const known = window.__appEarlyMediaRequests && window.__appEarlyMediaRequests.get(url);
          const knownType = String((known && known.contentType) || '').toLowerCase();
          if (knownType.startsWith('video/') || knownType.startsWith('image/') || knownType.includes('mpegurl')) return false;
        } catch (_) {}
        try {
          const u = new URL(url);
          const path = u.pathname.toLowerCase();
          const host = u.hostname.toLowerCase();
          const hasMediaExt = /\\.(jpg|jpeg|png|gif|webp|mp4|webm|mov|m3u8|mpd|ts|mp3|m4a)(\\?|\$)/.test(path);
          if (hasMediaExt) return false;
          const videoSiteHosts = ['tik.', 'porn', 'xvideos', 'xhamster', 'pornhub', 'redtube', 'cdn.', 'stream', 'video.', 'media.'];
          if (videoSiteHosts.some(h => host.includes(h))) return false;
          const apiPatterns = [
            'detailrecommend', 'wisesearchsetpic', 'wisejson',
            'getrelatedvideos', 'getuserbyslug', '/graphql', '/v1/', '/v2/', '/v3/',
            '/models', '/model/', '/slug', '/users/', '/search?', '/query', '/rest/', '/endpoint', '/service',
            'getuser', 'getpost', 'comment', 'like', 'share', 'follow', 'unfollow', 'subscribe'
          ];
          if (apiPatterns.some(p => lower.includes(p))) return true;
          const looksLikeApi = /\\/(get|post|api|graphql|rest|v1|v2|models|user|slug)/.test(path);
          if (looksLikeApi) return true;
        } catch (e) {}
        return false;
      }

      function isAdUrl(url) {
        if (!url) return false;
        const lower = url.toLowerCase();
        const adPatterns = [
          'doubleclick.net', 'googleads', 'googlesyndication', 'adsystem', 'adservice', 'adnxs',
          'openx.net', 'rubiconproject', 'pubmatic', 'taboola', 'outbrain', 'criteo', 'amazon-adsystem',
          '/ads/', '/ad/', '/adv/', 'pixel.', 'analytics.', 'tracking', 'telemetry',
          'prebid', 'header-bidding', 'banner', 'sponsor', 'promo', 'advertising',
          'vast', 'vpaid', 'mraid', 'popunder', 'popup', 'interstitial'
        ];
        return adPatterns.some(p => lower.includes(p));
      }

      $_kMediaFragmentUrlScript

      // 增强的媒体URL检测 - 优先扩展名，避免误判 API
      function isMediaUrl(url) {
        if (!url) return false;
        if (isApiUrl(url)) return false;
        if (isMediaFragmentUrl(url)) return false;
        
        const mediaExtensions = [
          '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico', '.tiff', '.tif', '.heic', '.heif',
          '.mp4', '.webm', '.mov', '.avi', '.mkv', '.flv', '.wmv', '.m3u8', '.m3u', '.mpd', '.ts', '.m4v', '.3gp', '.ogv', '.f4v',
          '.mp3', '.wav', '.ogg', '.m4a', '.aac', '.flac', '.wma', '.opus'
        ];
        
        const lowerUrl = url.toLowerCase();
        
        // 1. 扩展名最可靠
        if (mediaExtensions.some(ext => lowerUrl.includes(ext))) return true;
        
        // 2. 可信路径模式（含媒体目录或 CDN）及视频站域名
        const trustedPatterns = [
          '/cdn.', '/static/', '/assets/', '/uploads/', '/media/', '/images/', '/videos/', '/photos/',
          '/img/', '/video/', '/videopage/', '/thumb/', '/preview.', '/thumbnail.', '/stream',
          'youtube.com', 'youtu.be', 'vimeo.com', 'dailymotion.com', 'bilibili.com',
          'videopress', '/mp4', '/webm', '/m3u8', '/hls/', '/manifest', '/segment',
          'tik.', 'xvideos', 'xhamster', 'pornhub', 'redtube', 'eporner', 'streamable'
        ];
        if (trustedPatterns.some(p => lowerUrl.includes(p))) return true;
        
        // 3. 查询参数（仅当 URL 已像媒体时）
        const mediaParams = ['image=', 'video=', 'media=', 'file=', 'url='];
        if (mediaParams.some(p => lowerUrl.includes(p))) return true;
        
        return false;
      }

      // 从 data URL 正确提取 base64（MIME 可能含逗号如 video/webm;codecs=vp9,opus）
      function extractBase64FromDataUrl(dataUrl) {
        if (!dataUrl || typeof dataUrl !== 'string') return null;
        const idx = dataUrl.indexOf(';base64,');
        if (idx >= 0) return dataUrl.substring(idx + 8);
        const parts = dataUrl.split(',');
        return parts.length > 1 ? parts[parts.length - 1] : null;
      }

      // MediaRecorder 录制视频流（blob失败时的兜底）
      function tryMediaRecorderCapture(videoEl, onDone) {
        const captureStream = videoEl.captureStream ? videoEl.captureStream() : (videoEl.mozCaptureStream && videoEl.mozCaptureStream());
        if (!captureStream || captureStream.getTracks().length === 0) {
          if (onDone) onDone(false);
          return;
        }
        const mime = MediaRecorder.isTypeSupported('video/webm;codecs=vp9') ? 'video/webm;codecs=vp9' : (MediaRecorder.isTypeSupported('video/webm') ? 'video/webm' : 'video/mp4');
        let recorder;
        try {
          recorder = new MediaRecorder(captureStream, { mimeType: mime, videoBitsPerSecond: 2500000 });
        } catch (e) {
          try { recorder = new MediaRecorder(captureStream); } catch (e2) { if (onDone) onDone(false); return; }
        }
        const chunks = [];
        recorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) chunks.push(e.data); };
        recorder.onstop = () => {
          if (chunks.length === 0) { if (onDone) onDone(false); return; }
          const blob = new Blob(chunks, { type: recorder.mimeType || 'video/webm' });
          if (blob.size < 16384) { if (onDone) onDone(false); return; }
          const reader = new FileReader();
          reader.onloadend = () => {
            try {
              const b64 = extractBase64FromDataUrl(reader.result);
              if (b64) {
                Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'video', mimeType: blob.type || recorder.mimeType || mime, url: b64, isBase64: true, action: 'download' }));
                updateFeedbackStatus('已录制保存视频', true);
                if (onDone) onDone(true);
              } else { if (onDone) onDone(false); }
            } catch (e) { if (onDone) onDone(false); }
          };
          reader.onerror = () => { if (onDone) onDone(false); };
          reader.readAsDataURL(blob);
        };
        recorder.onerror = () => { if (onDone) onDone(false); };
        recorder.start(1000);
        const duration = Math.min(30, (videoEl.duration && !isNaN(videoEl.duration) ? videoEl.duration - videoEl.currentTime : 15));
        setTimeout(() => {
          if (recorder.state === 'recording') {
            recorder.stop();
            captureStream.getTracks().forEach(t => t.stop());
          }
        }, Math.max(3000, duration * 1000));
      }

      // 增强的Blob URL解析 - 支持 fetch/XHR，正确处理 Response.blob
      async function resolveBlobUrl(blobUrl, mediaType) {
        try {
          console.log('正在解析Blob URL:', blobUrl);
          
          let blob;
          try {
            const resp = await fetch(blobUrl, { 
              method: 'GET', 
              credentials: 'omit',
              cache: 'no-cache'
            });
            if (!resp.ok) throw new Error('Fetch status ' + resp.status);
            blob = await resp.blob();
          } catch (fetchError) {
            console.log('Fetch失败，尝试XMLHttpRequest:', fetchError);
            blob = await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open('GET', blobUrl, true);
              xhr.responseType = 'blob';
              xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) resolve(xhr.response);
                else reject(new Error('XHR status ' + xhr.status));
              };
              xhr.onerror = () => reject(new Error('XHR error'));
              xhr.send();
            });
          }
          
          if (!blob || blob.size === 0) throw new Error('Empty blob');
          if (blob.size > 150 * 1024 * 1024) throw new Error('Blob too large for base64');
          
          const reader = new FileReader();
          return new Promise((resolve, reject) => {
            reader.onloadend = () => {
              try {
                const result = reader.result;
                if (!result || typeof result !== 'string') { reject(new Error('Read failed')); return; }
                const base64Data = extractBase64FromDataUrl(result);
                if (!base64Data) { reject(new Error('No base64 data')); return; }
                resolve({ resolvedUrl: base64Data, isBase64: true, mediaType: mediaType });
              } catch (error) {
                reject(error);
              }
            };
            reader.onerror = () => reject(new Error('FileReader error: ' + (reader.error && reader.error.message)));
            reader.readAsDataURL(blob);
          });
        } catch (error) {
          console.error('Error resolving Blob URL:', error);
          return null;
        }
      }

      // 深度扫描DOM树查找媒体元素
      function deepScanForMediaElements(root = document) {
        const mediaElements = [];
        
        // 递归扫描函数
        function scanNode(node) {
          if (!node) return;
          
          // 检查Shadow DOM
          if (node.shadowRoot) {
            scanNode(node.shadowRoot);
          }
          
          // 检查iframe内容
          if (node.tagName === 'IFRAME' && node.contentDocument) {
            try {
              scanNode(node.contentDocument);
            } catch (e) {
              console.log('无法访问iframe内容:', e);
            }
          }
          
          // 检查当前节点
          const tagName = node.tagName ? node.tagName.toLowerCase() : '';
          const nodeName = node.nodeName ? node.nodeName.toLowerCase() : '';
          
          // 媒体元素检测
          if (['img', 'video', 'audio', 'source', 'picture'].includes(tagName)) {
            mediaElements.push(node);
          }
          
          // 链接元素检测
          if (tagName === 'a' && node.href && isMediaUrl(node.href)) {
            mediaElements.push(node);
          }
          
          // 背景图片检测
          if (node.style && node.style.backgroundImage) {
            const bgImage = node.style.backgroundImage;
            if (bgImage !== 'none' && bgImage.includes('url(')) {
              const urlMatch = bgImage.match(/url\(['"]?([^'")]+)['"]?\)/);
              if (urlMatch && isMediaUrl(urlMatch[1])) {
                mediaElements.push({
                  tagName: 'div',
                  href: urlMatch[1],
                  style: { backgroundImage: bgImage }
                });
              }
            }
          }
          
          // 递归扫描子节点
          if (node.childNodes) {
            for (const child of node.childNodes) {
              scanNode(child);
            }
          }
        }
        
        scanNode(root);
        return mediaElements;
      }

      // 监听动态内容变化
      function observeDynamicContent() {
        const observer = new MutationObserver((mutations) => {
          mutations.forEach((mutation) => {
            mutation.addedNodes.forEach((node) => {
              if (node.nodeType === Node.ELEMENT_NODE) {
                const mediaElements = deepScanForMediaElements(node);
                mediaElements.forEach(element => {
                  window.MediaInterceptor.mediaElements.add(element);
                });
              }
            });
          });
        });
        
        const observeTarget = document.body || document.documentElement;
        if (!observeTarget) return null;
        observer.observe(observeTarget, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['src', 'href', 'data-src', 'data-href']
        });
        
        return observer;
      }

      (function() {
        const originalXHROpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
          this._interceptedUrl = url;
          this._interceptedMethod = method;
          return originalXHROpen.apply(this, arguments);
        };

        const originalXHRSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function(data) {
          const xhr = this;
          const url = this._interceptedUrl;
          const requestCandidate = normalizeMediaCandidateUrl(url);
          const mightBeVideo = requestCandidate && !isApiUrl(requestCandidate) && (
            isMediaUrl(requestCandidate) || /\\/(v|video|stream)\\/|\\.(mp4|webm)(\\?|\$)/i.test(requestCandidate)
          );
          if (mightBeVideo) {
            window.MediaInterceptor.interceptedRequests.set(requestCandidate, {
              method: this._interceptedMethod,
              timestamp: Date.now(),
              type: 'xhr'
            });
          }
          const originalOnLoad = this.onload;
          this.onload = function() {
            try {
              if (typeof window.__appRememberMediaBuffer === 'function') {
                window.__appRememberMediaBuffer(this.response, requestCandidate);
              }
            } catch (_) {}
            if (isMediaUrl(requestCandidate) && this.response) console.log('媒体请求完成 (XHR):', requestCandidate);
            if (originalOnLoad) originalOnLoad.apply(this, arguments);
          };
          return originalXHRSend.apply(this, arguments);
        };
      })();

      (function() {
        const originalFetch = window.fetch;
        window.fetch = async function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url);
          const resp = await originalFetch.apply(this, arguments);
          if (url && resp && resp.ok) {
            const ct = (resp.headers.get('content-type') || '').toLowerCase();
            const requestCandidate = normalizeMediaCandidateUrl(url);
            if (requestCandidate && (ct.startsWith('video/') || ct.startsWith('image/') || ct.includes('mpegurl') || ct.includes('m3u8'))) {
              window.MediaInterceptor.interceptedRequests.set(requestCandidate, {
                method: (init && init.method) || 'GET',
                timestamp: Date.now(),
                type: 'fetch',
                contentType: ct
              });
            } else if (requestCandidate && isMediaUrl(requestCandidate)) {
              window.MediaInterceptor.interceptedRequests.set(requestCandidate, {
                method: (init && init.method) || 'GET',
                timestamp: Date.now(),
                type: 'fetch'
              });
            }
          }
          return resp;
        };
      })();

      window.processedMediaUrls = window.MediaInterceptor.processedUrls;

      function markMediaUrlProcessing(url) {
        if (!url) return false;
        if (window.processedMediaUrls.has(url)) return false;
        window.processedMediaUrls.add(url);
        setTimeout(function() {
          try { window.processedMediaUrls.delete(url); } catch (e) {}
        }, 45000);
        return true;
      }

      let pressTimer;
      let pressedElement = null;
      let feedbackElement = null;
      let favTapCount = 0;
      let favLastTapAt = 0;
      let favLastX = 0;
      let favLastY = 0;

      function createFeedbackElement(touchX, touchY) {
        removeFeedbackElement();
        feedbackElement = document.createElement('div');
        feedbackElement.style.position = 'fixed';
        feedbackElement.style.left = (touchX - 50) + 'px';
        feedbackElement.style.top = (touchY - 50) + 'px';
        feedbackElement.style.width = '100px';
        feedbackElement.style.height = '100px';
        feedbackElement.style.borderRadius = '50%';
        feedbackElement.style.backgroundColor = 'rgba(0, 0, 0, 0.5)';
        feedbackElement.style.zIndex = '9999';
        feedbackElement.style.display = 'flex';
        feedbackElement.style.justifyContent = 'center';
        feedbackElement.style.alignItems = 'center';
        feedbackElement.style.color = 'white';
        feedbackElement.style.fontSize = '14px';
        feedbackElement.style.textAlign = 'center';
        feedbackElement.style.transition = 'transform 0.5s, opacity 0.5s';
        feedbackElement.style.transform = 'scale(0.5)';
        feedbackElement.style.opacity = '0.7';
        feedbackElement.innerText = '正在检测媒体...';
        document.body.appendChild(feedbackElement);
        setTimeout(() => {
          if (feedbackElement) {
            feedbackElement.style.transform = 'scale(1)';
            feedbackElement.style.opacity = '1';
          }
        }, 10);
      }

      function removeFeedbackElement() {
        if (feedbackElement) {
          feedbackElement.style.transform = 'scale(0.5)';
          feedbackElement.style.opacity = '0';
          setTimeout(() => {
            if (feedbackElement && feedbackElement.parentNode) {
              feedbackElement.parentNode.removeChild(feedbackElement);
              feedbackElement = null;
            }
          }, 300);
        }
      }

      function updateFeedbackStatus(status, success) {
        if (feedbackElement) {
          feedbackElement.innerText = status;
          var bg;
          if (success === null) {
            bg = 'rgba(30, 120, 200, 0.55)';
          } else {
            bg = success ? 'rgba(0, 128, 0, 0.5)' : 'rgba(255, 0, 0, 0.5)';
          }
          feedbackElement.style.backgroundColor = bg;
          setTimeout(removeFeedbackElement, 1000);
        }
      }

      // 增强的长按检测 - 支持更多媒体元素类型
      document.addEventListener('touchstart', function(e) {
        // 媒体元素选择器 - 匹配媒体及常见视频站容器
        const mediaSelectors = [
          'video', 'video[src]', 'video source[src]', 'img[src]', 'img[data-src]', 'source[src]', 'picture source[srcset]',
          
          // 链接 - 仅含媒体扩展名或明确媒体路径
          'a[href*=".jpg"]', 'a[href*=".jpeg"]', 'a[href*=".png"]', 'a[href*=".gif"]', 
          'a[href*=".webp"]', 'a[href*=".mp4"]', 'a[href*=".webm"]', 'a[href*=".mov"]', 
          'a[href*=".m3u8"]', 'a[href*="/media/"]', 'a[href*="/video/"]', 'a[href*="/image/"]',
          'a[href*="/photo/"]', 'a[href*="imgur.com"]', 'a[href*="i.imgur.com"]',
          
          // 数据属性 - 明确媒体
          'img[data-src]', '[data-src*=".jpg"]', '[data-src*=".png"]', '[data-src*=".mp4"]',
          '[data-poster]', '[data-video-src]', '[data-media]',
          
          // 背景图 - 仅 style 含 url(
          'div[style*="background-image: url"]', 'div[style*="background: url"]',
          
          // 视频播放器容器 - 含 video 子元素才有效
          '[class*="videojs"]', '[class*="plyr"]', '[class*="dplayer"]', '[class*="jwplayer"]',
          '.video-container video', '.media-container video', '.video-player video',
          
          // 社交媒体
          '[data-testid="tweetPhoto"]', '[data-testid="tweetVideo"]',
          '[data-testid="instagram-media"]', '[data-testid="ig-media"]',
          // 下载按钮（长按可获取页面视频）
          '[aria-label*="ownload"]', '[aria-label*="下载"]', 'button[class*="download"]', 'a[class*="download"]'
        ];
        
        // 尝试找到媒体元素
        let foundElement = null;
        
        // 方法1: 使用closest查找最近的媒体元素
        for (const selector of mediaSelectors) {
          foundElement = e.target.closest(selector);
          if (foundElement) break;
        }
        
        // 方法2: 如果没找到，检查当前元素及其父元素
        if (!foundElement) {
          let currentElement = e.target;
          while (currentElement && currentElement !== document.body) {
            // 检查元素属性
            const hasMediaAttr = currentElement.src || currentElement.href || 
                               currentElement.getAttribute('data-src') || 
                               currentElement.getAttribute('data-href') ||
                               currentElement.getAttribute('data-url') ||
                               currentElement.getAttribute('data-original');
            
            // 检查样式
            const hasMediaStyle = currentElement.style && 
                                (currentElement.style.backgroundImage || 
                                 currentElement.style.background);
            
            // 检查类名和ID
            const className = currentElement.className || '';
            const id = currentElement.id || '';
            const hasMediaClass = /(media|video|image|photo|picture|download|player|stream)/i.test(className + ' ' + id);
            
            if (hasMediaAttr || hasMediaStyle || hasMediaClass) {
              foundElement = currentElement;
              break;
            }
            
            currentElement = currentElement.parentElement;
          }
        }
        
        // 方法3: 深度扫描周围区域 + 优先视频
        if (!foundElement) {
          const rect = e.target.getBoundingClientRect();
          const centerX = rect.left + rect.width / 2;
          const centerY = rect.top + rect.height / 2;
          
          const nearbyElements = document.elementsFromPoint(centerX, centerY);
          let videoCandidate = null;
          let otherCandidate = null;
          for (const element of nearbyElements) {
            if (element === e.target) continue;
            const tag = (element.tagName || '').toLowerCase();
            const hasMediaContent = element.src || element.href || 
                                  element.currentSrc ||
                                  element.getAttribute('data-src') ||
                                  element.getAttribute('data-href') ||
                                  element.getAttribute('data-video-src') ||
                                  (element.style && element.style.backgroundImage);
            if (tag === 'video' && (element.currentSrc || element.src)) {
              videoCandidate = element;
              break;
            }
            if (hasMediaContent) otherCandidate = element;
          }
          foundElement = videoCandidate || otherCandidate;
        }
        
        // 方法4: 容器内查找 - 若找到的是容器div，尝试取其内的 video/img（含 shadow DOM）
        if (foundElement && !foundElement.src && !foundElement.href && !foundElement.currentSrc) {
          const findMedia = (root) => {
            if (!root) return null;
            const v = root.querySelector && root.querySelector('video');
            const i = root.querySelector && root.querySelector('img');
            if (v && (v.currentSrc || v.src)) return v;
            if (i && (i.src || i.currentSrc || i.getAttribute('data-src'))) return i;
            return null;
          };
          const inner = findMedia(foundElement) || (foundElement.shadowRoot && findMedia(foundElement.shadowRoot));
          if (inner) foundElement = inner;
        }
        
        pressedElement = foundElement;
        
        if (pressedElement) {
          const touch = e.touches[0];
          const touchX = touch.clientX;
          const touchY = touch.clientY;
          window._lastTouchX = touchX;
          window._lastTouchY = touchY;
          pressTimer = setTimeout(function() {
            createFeedbackElement(touchX, touchY);
            handleMediaDownload(pressedElement, e);
          }, 400);
        }
      }, true);

      document.addEventListener('touchmove', function(e) {
        clearTimeout(pressTimer);
        removeFeedbackElement();
        pressedElement = null;
      }, true);

      document.addEventListener('touchend', function(e) {
        clearTimeout(pressTimer);
        try {
          const t = Date.now();
          const touch = (e.changedTouches && e.changedTouches[0]) ? e.changedTouches[0] : null;
          const x = touch ? touch.clientX : 0;
          const y = touch ? touch.clientY : 0;
          const dt = t - favLastTapAt;
          const moved = Math.abs(x - favLastX) > 36 || Math.abs(y - favLastY) > 36;
          if (dt > 40 && dt < 420 && !moved) favTapCount += 1;
          else favTapCount = 1;
          favLastTapAt = t;
          favLastX = x;
          favLastY = y;
          if (favTapCount >= 3) {
            favTapCount = 0;
            const videos = Array.from(document.querySelectorAll('video'));
            if (videos.length) {
              const vw = Math.max(1, window.innerWidth || 1);
              const vh = Math.max(1, window.innerHeight || 1);
              const cx = vw / 2, cy = vh / 2;
              const area = (r) => Math.max(0, r.width) * Math.max(0, r.height);
              const dist = (r) => {
                const x0 = (r.left + r.right) / 2;
                const y0 = (r.top + r.bottom) / 2;
                return Math.sqrt((x0 - cx) * (x0 - cx) + (y0 - cy) * (y0 - cy));
              };
              let pick = null;
              let best = -1e18;
              for (const v of videos) {
                const r = v.getBoundingClientRect();
                const d = Number(v.duration || 0);
                const p = Number(v.currentTime || 0);
                const src = String(v.currentSrc || v.src || '');
                let s = area(r) * 0.7;
                if (!v.paused && !v.ended) s += 1200000;
                if (p > 0.4) s += 220000;
                s += Math.max(0, 250000 - dist(r) * 420);
                if (isFinite(d) && d > 0) {
                  s += Math.min(d, 1800) * 350;
                  if (d < 7) s -= 900000;
                  else if (d < 15) s -= 260000;
                }
                if (src.includes('.m3u8') || src.includes('.mp4') || src.includes('.webm')) s += 120000;
                if (s > best) { best = s; pick = v; }
              }
              if (pick) {
                const rawSrc = String(pick.currentSrc || pick.src || '');
                const d = Number(pick.duration || 0);
                const p = Number(pick.currentTime || 0);
                const looksPreview = (u) => {
                  if (!u) return false;
                  const s = String(u).toLowerCase();
                  const hints = ['preview','sample','trailer','teaser','thumb','poster','storyboard','sprite','clip','snippet','init.','/init','.m4s','/seg','/chunk','/fragment'];
                  return hints.some(h => s.includes(h));
                };
                let bestUrl = '';
                if (window.MediaInterceptor && window.MediaInterceptor.interceptedRequests) {
                  const now = Date.now();
                  let bestScore = -1;
                  for (const [u, info] of window.MediaInterceptor.interceptedRequests) {
                    if (!u) continue;
                    if ((now - info.timestamp) > 1800000) continue;
                    if (isApiUrl(u) || isAdUrl(u) || isMediaFragmentUrl(u)) continue;
                    const lower = String(u).toLowerCase();
                    const hasMediaHint = lower.includes('.m3u8') || lower.includes('.m3u') || lower.includes('.mpd') || lower.includes('.mp4') || lower.includes('.webm') || lower.includes('.ts') || lower.includes('mpegurl');
                    if (!hasMediaHint) continue;
                    if (looksPreview(lower)) continue;
                    let bonus = 0;
                    if (lower.includes('.m3u8') || lower.includes('.m3u') || lower.includes('.mpd') || lower.includes('mpegurl')) bonus += 1000000000;
                    else if (lower.includes('.ts')) bonus += 500000000;
                    else if (lower.includes('.mp4') || lower.includes('.webm')) bonus += 200000000;
                    const score = (info.timestamp || 0) + bonus;
                    if (score > bestScore) {
                      bestScore = score;
                      bestUrl = u;
                    }
                  }
                }
                const finalUrl = (bestUrl && !isApiUrl(bestUrl) && !isAdUrl(bestUrl)) ? bestUrl : rawSrc;
                if (!finalUrl || isBlobUrl(finalUrl) || isApiUrl(finalUrl) || isAdUrl(finalUrl)) {
                  updateFeedbackStatus('请先播放后再收藏', false);
                  return;
                }
                const cands = [];
                const seen = new Set();
                const push = (u) => {
                  if (!u || typeof u !== 'string') return;
                  let s = u.trim();
                  if (!s) return;
                  if (!s.startsWith('http://') && !s.startsWith('https://')) {
                    try { s = new URL(s, location.href).toString(); } catch (_) {}
                  }
                  if (!s || seen.has(s) || isApiUrl(s) || isAdUrl(s) || looksPreview(s)) return;
                  seen.add(s);
                  cands.push(s);
                };
                push(finalUrl);
                push(rawSrc);
                try {
                  const srcs = Array.from(pick.querySelectorAll('source')).map(s => s.src || s.getAttribute('src'));
                  for (const s of srcs) push(s || '');
                } catch (_) {}
                if (window.MediaInterceptor && window.MediaInterceptor.interceptedRequests) {
                  const now = Date.now();
                  let added = 0;
                  for (const [u, info] of window.MediaInterceptor.interceptedRequests) {
                    if (added >= 8) break;
                    if (!u) continue;
                    if ((now - info.timestamp) > 1800000) continue;
                    if (isApiUrl(u) || isAdUrl(u) || isMediaFragmentUrl(u) || looksPreview(u)) continue;
                    const lower = String(u).toLowerCase();
                    const hasMediaHint = lower.includes('.m3u8') || lower.includes('.m3u') || lower.includes('.mpd') || lower.includes('.mp4') || lower.includes('.webm') || lower.includes('.ts') || lower.includes('mpegurl');
                    if (!hasMediaHint) continue;
                    push(u);
                    added += 1;
                  }
                }
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  action: 'favorite',
                  mediaType: 'video',
                  url: finalUrl,
                  pageUrl: location.href || '',
                  title: document.title || '',
                  positionSec: isFinite(p) ? p : 0,
                  durationSec: isFinite(d) ? d : 0,
                  candidates: cands
                }));
                updateFeedbackStatus('已收藏当前视频', true);
              }
            }
          }
        } catch (_) {}
        if (!pressedElement) removeFeedbackElement();
        pressedElement = null;
      }, true);

      // 添加点击事件监听器处理blob URL
      document.addEventListener('click', function(e) {
        const target = e.target;
        const link = target.closest('a');
        if (link && link.href && isBlobUrl(link.href)) {
          e.preventDefault();
          console.log('检测到blob URL点击:', link.href);
          resolveBlobUrl(link.href, 'video').then(resolved => {
            if (resolved) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: resolved.mediaType || 'video',
                url: resolved.resolvedUrl,
                isBase64: resolved.isBase64,
                action: 'download'
              }));
              console.log('已发送blob URL下载请求');
            } else {
              console.error('解析blob URL失败');
            }
          });
        }
      }, true);

      // 增强的媒体下载处理 - 近100%成功率
      async function handleMediaDownload(target, e) {
        if (!target) {
          updateFeedbackStatus('未找到媒体元素', false);
          return;
        }
        const longPressSessionId = 'lp-' + Date.now() + '-' + Math.random().toString(36).slice(2, 10);
        const isSmartGesture = !!(target && target.getAttribute &&
          target.getAttribute('data-app-smart-gesture') === '1');
        let isPinPornContext = false;
        let isTikPornContext = false;
        let isXPlatformContext = false;
        try {
          const hosts = [location.hostname || ''];
          if (document.referrer) hosts.push(new URL(document.referrer).hostname || '');
          isPinPornContext = hosts.some(host => {
            const normalized = String(host).toLowerCase();
            return normalized === 'pin.porn' || normalized.endsWith('.pin.porn');
          });
          isTikPornContext = hosts.some(host => {
            const normalized = String(host).toLowerCase();
            return normalized === 'tik.porn' || normalized.endsWith('.tik.porn');
          });
          isXPlatformContext = hosts.some(host => {
            const normalized = String(host).toLowerCase();
            return normalized === 'x.com' || normalized.endsWith('.x.com') ||
              normalized === 'twitter.com' || normalized.endsWith('.twitter.com');
          });
        } catch (_) {}
        
        function pickCurrentVideo(x, y) {
          const videos = Array.from(document.querySelectorAll('video'));
          let picked = null;
          let bestScore = -Infinity;
          const vw = Math.max(1, window.innerWidth || 1);
          const vh = Math.max(1, window.innerHeight || 1);
          for (const video of videos) {
            const rect = video.getBoundingClientRect();
            const visibleW = Math.max(0, Math.min(rect.right, vw) - Math.max(rect.left, 0));
            const visibleH = Math.max(0, Math.min(rect.bottom, vh) - Math.max(rect.top, 0));
            const visibleArea = visibleW * visibleH;
            if (visibleArea <= 0) continue;
            const containsPoint = x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
            const cx = (rect.left + rect.right) / 2;
            const cy = (rect.top + rect.bottom) / 2;
            const distance = Math.hypot(cx - x, cy - y);
            let score = visibleArea - distance * 200;
            if (containsPoint) score += 1000000000;
            if (!video.paused && !video.ended) score += 100000000;
            if (Number(video.currentTime || 0) > 0) score += 1000000;
            if (score > bestScore) { bestScore = score; picked = video; }
          }
          return picked;
        }

        function xStatusInfoAtPoint(x, y) {
          if (!isXPlatformContext) return null;
          try {
            const stack = document.elementsFromPoint(x, y);
            let article = null;
            for (const element of stack) {
              const candidate = element && element.closest &&
                element.closest('article[data-testid="tweet"], article');
              if (candidate) { article = candidate; break; }
            }
            const mediaIdFromScope = scope => {
              if (!scope) return '';
              const values = [];
              const add = value => { if (value) values.push(String(value)); };
              const mediaNodes = String(scope.tagName || '').toLowerCase() === 'video'
                ? [scope]
                : Array.from(scope.querySelectorAll(
                    'video, img, [style*="background-image"], [data-src], [data-poster]'
                  ));
              mediaNodes.sort((left, right) => {
                const lr = left.getBoundingClientRect();
                const rr = right.getBoundingClientRect();
                const leftContains = x >= lr.left && x <= lr.right && y >= lr.top && y <= lr.bottom;
                const rightContains = x >= rr.left && x <= rr.right && y >= rr.top && y <= rr.bottom;
                if (leftContains !== rightContains) return leftContains ? -1 : 1;
                const ld = Math.abs(lr.top + lr.height / 2 - y) +
                  Math.abs(lr.left + lr.width / 2 - x) * 0.25;
                const rd = Math.abs(rr.top + rr.height / 2 - y) +
                  Math.abs(rr.left + rr.width / 2 - x) * 0.25;
                return ld - rd;
              }).forEach(media => {
                add(media.poster);
                add(media.getAttribute && media.getAttribute('poster'));
                add(media.currentSrc); add(media.src);
                add(media.getAttribute && media.getAttribute('src'));
                add(media.getAttribute && media.getAttribute('srcset'));
                add(media.getAttribute && media.getAttribute('data-src'));
                add(media.getAttribute && media.getAttribute('data-poster'));
                add(media.getAttribute && media.getAttribute('style'));
              });
              for (const value of values) {
                const lower = value.toLowerCase();
                for (const marker of ['/amplify_video_thumb/', '/ext_tw_video_thumb/',
                  '/tweet_video_thumb/', '/amplify_video/', '/ext_tw_video/', '/tweet_video/']) {
                  const index = lower.indexOf(marker);
                  if (index < 0) continue;
                  const id = value.substring(index + marker.length).split('/')[0];
                  if (id && Array.from(id).every(ch => ch >= '0' && ch <= '9')) return id;
                }
              }
              return '';
            };
            const locationUrl = new URL(location.href);
            const currentTweet = locationUrl.searchParams.get('currentTweet') || '';
            let currentScope = article;
            if (!currentScope && currentTweet) {
              const currentLink = Array.from(document.querySelectorAll('a[href*="/status/"]'))
                .find(link => String(link.href || link.getAttribute('href') || '')
                  .includes('/status/' + currentTweet));
              currentScope = currentLink && currentLink.closest(
                'article[data-testid="tweet"], article, [role="dialog"], main'
              );
            }
            const pointVideo = pickCurrentVideo(x, y);
            if (!currentScope && pointVideo) {
              currentScope = pointVideo.closest('[role="dialog"], main') || pointVideo.parentElement;
            }
            const statusLink = currentTweet
              ? location.origin + '/i/status/' + currentTweet
              : (currentScope ? Array.from(currentScope.querySelectorAll('a[href*="/status/"]'))
                  .map(link => link.href || link.getAttribute('href') || '')
                  .find(href => String(href).includes('/status/')) : '');
            const statusTail = String(statusLink || '').split('/status/')[1] || '';
            const statusId = (statusTail.match(/^[0-9]+/) || [''])[0];
            const videos = currentScope
              ? Array.from(currentScope.querySelectorAll('video'))
              : (pointVideo ? [pointVideo] : []);
            const video = videos.sort((left, right) => {
              const lr = left.getBoundingClientRect();
              const rr = right.getBoundingClientRect();
              const leftContains = x >= lr.left && x <= lr.right && y >= lr.top && y <= lr.bottom;
              const rightContains = x >= rr.left && x <= rr.right && y >= rr.top && y <= rr.bottom;
              if (leftContains !== rightContains) return leftContains ? -1 : 1;
              if (left.paused !== right.paused) return left.paused ? 1 : -1;
              return Math.abs(lr.top + lr.height / 2 - y) -
                Math.abs(rr.top + rr.height / 2 - y);
            })[0] || null;
            let mediaId = mediaIdFromScope(video);
            let node = video && video.parentElement;
            for (let depth = 0; !mediaId && node && depth < 7; depth++, node = node.parentElement) {
              mediaId = mediaIdFromScope(node);
            }
            if (!mediaId) mediaId = mediaIdFromScope(currentScope);
            return { article: currentScope, video: video || pointVideo,
              statusUrl: statusLink || location.href, statusId: statusId || currentTweet,
              mediaId };
          } catch (_) {
            return null;
          }
        }

        function pickTikPornVideo(x, y) {
          try {
            // TikPORN places controls/overlays above the video. Resolve the
            // player under the finger first instead of comparing preloaded
            // videos that may occupy the same viewport rectangle.
            const stack = document.elementsFromPoint(x, y);
            for (const element of stack) {
              if (!element) continue;
              if (String(element.tagName || '').toLowerCase() === 'video') {
                return element;
              }
              const player = element.closest && (
                element.closest('[class*="player_wrapper"]') ||
                element.closest('[class*="Player-module"][class*="player"]')
              );
              const playerVideo = player && player.querySelector && player.querySelector('video');
              if (playerVideo) return playerVideo;
            }
          } catch (_) {}
          return pickCurrentVideo(x, y);
        }

        function exactTikPornSource(video) {
          if (!video) return '';
          try {
            const sources = Array.from(video.querySelectorAll('source'));
            for (const source of sources) {
              const raw = String(source.src || source.getAttribute('src') || '').trim();
              if (!raw) continue;
              const absolute = new URL(raw, location.href).toString();
              const path = String(new URL(absolute).pathname || '').toLowerCase();
              const supported = ['.mp4', '.webm', '.mov', '.m3u8', '.m3u', '.mpd']
                .some(extension => path.endsWith(extension));
              if (/^https?:/i.test(absolute) && supported) {
                return absolute;
              }
            }
          } catch (_) {}
          return '';
        }

        function tikPornVideoId(video) {
          if (!video) return '';
          const values = [];
          const push = value => {
            const normalized = String(value || '').trim();
            if (normalized) values.push(normalized);
          };
          try {
            push(video.poster);
            push(video.getAttribute('poster'));
            const player = video.closest && video.closest('[class*="player_wrapper"]');
            if (player) {
              const poster = player.querySelector('[class*="posterContainer"]');
              push(poster && poster.style && poster.style.backgroundImage);
            }
          } catch (_) {}
          for (const value of values) {
            const markerIndex = value.toLowerCase().indexOf('/video/');
            if (markerIndex < 0) continue;
            const tail = value.substring(markerIndex + 7).split('?')[0].split('#')[0];
            const parts = tail.split('/').filter(Boolean);
            const candidates = parts.length > 1
              ? [parts[1], parts[0]]
              : parts;
            for (const candidate of candidates) {
              const numeric = Number(candidate);
              if (candidate && Number.isInteger(numeric) && numeric > 0) {
                return candidate;
              }
            }
          }
          return '';
        }

        async function resolveTikPornVideoSource(video) {
          const direct = exactTikPornSource(video);
          const videoId = tikPornVideoId(video);
          if (!videoId) return { url: direct, videoId: '' };
          window.__appTikPornSourceCache = window.__appTikPornSourceCache || new Map();
          const cached = window.__appTikPornSourceCache.get(videoId);
          if (cached) return { url: cached, videoId: videoId };
          try {
            const response = await fetch('/video/' + encodeURIComponent(videoId), {
              credentials: 'include',
              headers: { Accept: 'text/html' },
              cache: 'no-store'
            });
            if (response && response.ok) {
              const html = await response.text();
              const parsed = new DOMParser().parseFromString(html, 'text/html');
              const scripts = Array.from(parsed.querySelectorAll('script[type="application/ld+json"]'));
              let resolved = '';
              const inspect = value => {
                if (!value || resolved) return;
                if (Array.isArray(value)) {
                  value.forEach(inspect);
                  return;
                }
                if (typeof value !== 'object') return;
                const type = String(value['@type'] || '').toLowerCase();
                const pageUrl = String(value.url || value['@id'] || '');
                if (type === 'videoobject' &&
                    pageUrl.includes('/video/' + videoId) &&
                    typeof value.contentUrl === 'string') {
                  resolved = value.contentUrl.trim();
                  return;
                }
                Object.values(value).forEach(inspect);
              };
              for (const script of scripts) {
                try { inspect(JSON.parse(script.textContent || 'null')); } catch (_) {}
                if (resolved) break;
              }
              if (/^https?:/i.test(resolved)) {
                window.__appTikPornSourceCache.set(videoId, resolved);
                return { url: resolved, videoId: videoId };
              }
            }
          } catch (_) {}
          return { url: direct, videoId: videoId };
        }

        function effectiveVideoDuration(video) {
          if (!video) return 0;
          const direct = Number(video.duration || 0);
          if (isFinite(direct) && direct > 0) return direct;
          try {
            if (video.seekable && video.seekable.length) {
              const end = Number(video.seekable.end(video.seekable.length - 1));
              if (isFinite(end) && end > 0) return end;
            }
          } catch (_) {}
          const durationAttrs = ['data-duration', 'data-video-duration', 'duration'];
          let node = video;
          for (let depth = 0; node && depth < 6; depth++, node = node.parentElement) {
            for (const name of durationAttrs) {
              const raw = node.getAttribute && node.getAttribute(name);
              const parsed = Number(raw || 0);
              if (isFinite(parsed) && parsed > 0) return parsed;
            }
            const text = String(node.innerText || '');
            const times = Array.from(text.matchAll(/(?:^|\s)(\d{1,2}):(\d{2})(?=\s|\$)/g));
            let longest = 0;
            for (const match of times) {
              const seconds = Number(match[1]) * 60 + Number(match[2]);
              if (seconds > longest) longest = seconds;
            }
            if (longest > 0) return longest;
          }
          return 0;
        }

        // 触点上即使覆盖着网页按钮，也优先选择触点范围内真正可见、正在播放的视频。
        let bestTarget = target;
        if (typeof window._lastTouchX === 'number' && typeof window._lastTouchY === 'number') {
          const xStatus = xStatusInfoAtPoint(window._lastTouchX, window._lastTouchY);
          const currentVideo = isTikPornContext
            ? pickTikPornVideo(window._lastTouchX, window._lastTouchY)
            : ((xStatus && xStatus.video) ||
              pickCurrentVideo(window._lastTouchX, window._lastTouchY));
          const atPoint = document.elementsFromPoint(window._lastTouchX, window._lastTouchY);
          let pointVideo = null;
          for (const el of atPoint) {
            const tag = (el.tagName || '').toLowerCase();
            if (tag === 'video' && (el.currentSrc || el.src)) {
              bestTarget = el;
              pointVideo = el;
              break;
            }
            if (tag === 'img' && (el.currentSrc || el.src)) {
              bestTarget = el;
              break;
            }
          }
          const selectedTag = (bestTarget.tagName || '').toLowerCase();
          const selectedImage = selectedTag === 'img' || selectedTag === 'image' ||
            selectedTag === 'picture';
          if (currentVideo &&
              !selectedImage &&
              (!isXPlatformContext || !pointVideo) &&
              (isXPlatformContext || !selectedImage)) {
            bestTarget = currentVideo;
          }
          if (isXPlatformContext && xStatus && bestTarget) {
            bestTarget.__appXStatusId = xStatus.statusId || '';
            bestTarget.__appXStatusUrl = xStatus.statusUrl || '';
            bestTarget.__appXMediaId = xStatus.mediaId || '';
          }
          if (bestTarget === target) {
            const txt = (target.textContent || target.innerText || '').toLowerCase();
            const aria = (target.getAttribute('aria-label') || '').toLowerCase();
            if ((txt.includes('download') || txt.includes('下载') || aria.includes('download') || aria.includes('下载')) && !target.querySelector('video')) {
              const visibleVideo = pickCurrentVideo(window._lastTouchX, window._lastTouchY);
              if (visibleVideo) bestTarget = visibleVideo;
            }
          }
        }
        target = bestTarget;

        if (isXPlatformContext &&
            String(target.tagName || '').toLowerCase() === 'video') {
          try {
            Array.from(document.querySelectorAll('video')).forEach(video => {
              if (video !== target) video.pause();
            });
            target.muted = true;
            target.play().catch(() => {});
          } catch (_) {}
        }

        if (isTikPornContext &&
            typeof window._lastTouchX === 'number' &&
            typeof window._lastTouchY === 'number') {
          const exactVideo = pickTikPornVideo(window._lastTouchX, window._lastTouchY);
          if (exactVideo) {
            target = exactVideo;
            // Resolve the stable card ID to its own detail-page content URL.
            // The three mounted players otherwise expose interleaved MSE
            // traffic for the previous, current, and next feed items.
            updateFeedbackStatus('正在确认当前视频…', null);
            const resolved = await resolveTikPornVideoSource(exactVideo);
            target.__appTikDownloadUrl = resolved.url || '';
            target.__appTikVideoId = resolved.videoId || '';
          }
        }

        // PinPorn exposes the exact MP4 for each Swiper item in video[data-src].
        // Bind to the slide under the finger instead of any globally sniffed
        // request, because adjacent slides are deliberately preloaded.
        if (isPinPornContext &&
            typeof window._lastTouchX === 'number' &&
            typeof window._lastTouchY === 'number') {
          try {
            const touched = document.elementFromPoint(window._lastTouchX, window._lastTouchY);
            // Swiper may mark adjacent items as visible, but only one item is
            // active. Use it before all touch/visibility fallbacks.
            const slide = document.querySelector('.swiper-slide-active') ||
              (touched && touched.closest && touched.closest('.swiper-slide')) ||
              document.querySelector('.swiper-slide-visible') ||
              (target && target.closest && target.closest('.swiper-slide'));
            const slideVideo = slide && slide.querySelector && slide.querySelector('video[data-src]');
            const dataSrc = slideVideo && slideVideo.getAttribute('data-src');
            if (slideVideo && dataSrc) {
              target = slideVideo;
              const playingSrc = String(slideVideo.currentSrc || slideVideo.src || '').trim();
              // data-src belongs to the active slide's API item. currentSrc
              // can briefly retain the previous item while Swiper reuses DOM.
              target.__appPinnedDownloadUrl = new URL(dataSrc, location.href).toString();
              target.__appPinPlayingFallbackUrl = playingSrc ?
                new URL(playingSrc, location.href).toString() : '';
              target.__appPinSlideId = String(slide.getAttribute('data-id') || '');
            }
          } catch (_) {}
        }
        
        // 懒加载/预加载触发 - 视频常需 load() 或短暂 play 才能获取 currentSrc
        try {
          if (typeof target.loading !== 'undefined') target.loading = 'eager';
          if (typeof target.decode === 'function') target.decode();
          if (typeof target.scrollIntoView === 'function') target.scrollIntoView({block: 'center'});
          const v = (target.tagName && target.tagName.toLowerCase() === 'video') ? target : (target.querySelector && target.querySelector('video'));
          if (v) {
            if (!v.currentSrc && v.src) v.load();
            else if (!v.currentSrc && !v.src) {
              const src = v.querySelector && v.querySelector('source');
              if (src && (src.src || src.getAttribute('src'))) {
                v.src = src.src || src.getAttribute('src');
                v.load();
              }
            }
          }
        } catch (err) { console.log('懒加载触发失败', err); }
        
        // canvas截图兜底
        if (target.tagName && target.tagName.toLowerCase() === 'canvas') {
          try {
            const dataUrl = target.toDataURL('image/png');
            if (dataUrl && dataUrl.startsWith('data:image/')) {
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'image',
                url: extractBase64FromDataUrl(dataUrl),
                isBase64: true,
                isSmartGesture: isSmartGesture,
                action: 'download'
              }));
              updateFeedbackStatus('已截图保存canvas', true);
              return;
            }
          } catch (err) {
            updateFeedbackStatus('canvas截图失败', false);
          }
        }
        
        // 超全面的URL提取逻辑 - 优先用拦截到的直链(比blob更可靠)，其次 currentSrc
        let url = null;
        let interceptedStreamUrl = null;
        const parentLink = target.closest ? target.closest('a') : null;
        const tagName = (target.tagName || '').toLowerCase();
        const videoEl = tagName === 'video' ? target : (target.querySelector && target.querySelector('video'));
        if (videoEl &&
            window.MediaInterceptor &&
            window.MediaInterceptor.interceptedRequests &&
            !(isTikPornContext && target.__appTikDownloadUrl)) {
          // 补充扫描性能条目，防止 Hook 遗漏（例如缓存命中或某些特殊的加载方式）
          try {
            performance.getEntriesByType('resource').forEach(entry => {
              const u = normalizeMediaCandidateUrl(entry.name);
              if (u && !isApiUrl(u) && !isAdUrl(u) && (u.includes('.m3u8') || u.includes('.m3u') || u.includes('.mpd') || u.includes('.mp4') || u.includes('.webm'))) {
                if (!window.MediaInterceptor.interceptedRequests.has(u)) {
                  window.MediaInterceptor.interceptedRequests.set(u, { method: 'GET', timestamp: Date.now(), type: 'performance', contentType: '' });
                }
              }
            });
          } catch (e) {}

          const now = Date.now();
          let best = null, bestScore = -1;
          for (const [u, info] of window.MediaInterceptor.interceptedRequests) {
            if (!u || (now - info.timestamp) > 600000) continue;
            if (isAdUrl(u) || isMediaFragmentUrl(u)) continue;

            if (isXPlatformContext) {
              const bound = String((videoEl && (videoEl.currentSrc || videoEl.src)) || '');
              const mediaId = value => {
                const text = String(value || '');
                for (const marker of ['/amplify_video/', '/ext_tw_video/', '/tweet_video/']) {
                  const index = text.toLowerCase().indexOf(marker);
                  if (index >= 0) return text.substring(index + marker.length).split('/')[0];
                }
                return '';
              };
              const boundId = mediaId(bound);
              const candidateId = mediaId(u);
              if (boundId && candidateId !== boundId) continue;
            }

            const ct = (info.contentType || '').toLowerCase();
            const lower = String(u).toLowerCase();
            const isStream = (ct.startsWith('video/') || ct.includes('mpegurl') || ct.includes('m3u8') || ct.includes('dash') || /\\.(mp4|webm|mov|m3u8|m3u|mpd)(\\?|\$)/.test(lower)) && !isApiUrl(u);
            
            if (isStream) {
              // 优先级策略：
              // 1. 如果有当前视频的时长信息，且大于 60s，优先选它（通常广告 < 60s）
              // 2. 否则选时间戳最新的（假设用户正在看的就是最新加载的）
              let score = Number(info.timestamp || 0);
              if (ct.includes('mpegurl') || ct.includes('dash') || lower.includes('.m3u8') || lower.includes('.m3u') || lower.includes('.mpd')) score += 1000000000;
              else if (ct.startsWith('video/') || lower.includes('.mp4') || lower.includes('.webm') || lower.includes('.mov')) score += 500000000;
              if (lower.includes('preview') || lower.includes('trailer') || lower.includes('poster') || lower.includes('thumb')) score -= 1500000000;
              if (lower.includes('.m4s') || lower.includes('/segment') || lower.includes('/chunk')) score -= 1200000000;
              if (score > bestScore) {
                bestScore = score; best = u;
              }
            }
          }
          if (best) interceptedStreamUrl = best;
        }
        function domUrlLooksLikePosterOrThumb(u) {
          if (!u || typeof u !== 'string') return true;
          const s = u.toLowerCase();
          if (s.startsWith('blob:') || s.startsWith('data:')) return false;
          return /\\.(jpg|jpeg|png|gif|webp)(\\?|#|\$)/.test(s) && !/\\.(m3u8|m3u|mp4|webm|ts)(\\?|#|\$)/.test(s);
        }
        const urlSources = [
          () => target.__appPinnedDownloadUrl,
          () => target.__appTikDownloadUrl,
          () => target.currentSrc || target.src,
          () => videoEl && (videoEl.currentSrc || videoEl.src),
          () => videoEl && Array.from(videoEl.querySelectorAll('source')).map(s => s.src || s.getAttribute('src')).find(u => u),
          () => target.getAttribute('data-video-url') || target.getAttribute('data-file') || target.getAttribute('data-source') || target.getAttribute('data-stream'),
          () => target.href,
          () => {
            if (!parentLink || !parentLink.href) return null;
            const h = parentLink.href;
            if (h.includes('imgres') || h.includes('mediaurl=') || h.includes('images/search')) {
              try {
                const u = new URL(h);
                return u.searchParams.get('imgurl') || u.searchParams.get('mediaurl') || u.searchParams.get('surl') || null;
              } catch (e) { return null; }
            }
            return isMediaUrl(h) ? h : null;
          },
          () => target.src,
          () => target.srcset,
          () => target.getAttribute('data-src'),
          () => target.getAttribute('data-original'),
          () => target.getAttribute('data-full-url') || target.getAttribute('data-highres') || target.getAttribute('data-large-src'),
          () => target.getAttribute('data-href'),
          () => target.getAttribute('data-url'),
          () => target.getAttribute('data-lazy-src'),
          () => target.getAttribute('data-srcset'),
          () => target.getAttribute('data-poster'),
          () => target.getAttribute('data-media'),
          () => target.getAttribute('data-video'),
          () => target.getAttribute('data-video-src') || target.getAttribute('data-src'),
          () => target.getAttribute('data-image'),
          () => target.getAttribute('data-zoom-src') || target.getAttribute('data-imgsrc'),
          () => target.getAttribute('content'),
          () => target.getAttribute('value'),
          () => target.getAttribute('title'),
          () => {
            if (target.style && target.style.backgroundImage) {
              const match = target.style.backgroundImage.match(/url\(['"]?([^'")]+)['"]?\)/);
              return match ? match[1] : null;
            }
            return null;
          },
          () => {
            if (target.style && target.style.background) {
              const match = target.style.background.match(/url\(['"]?([^'")]+)['"]?\)/);
              return match ? match[1] : null;
            }
            return null;
          }
        ];
        for (const getUrl of urlSources) {
          try {
            url = getUrl();
            if (url && url.trim()) {
              url = url.trim();
              break;
            }
          } catch (e) { console.log('URL提取失败:', e); }
        }
        if (url && url.includes(',')) {
          const srcsetParts = url.split(',');
          let bestUrl = srcsetParts[0].trim().split(' ')[0];
          let bestWidth = 0;
          for (const part of srcsetParts) {
            const trimmed = part.trim();
            const urlPart = trimmed.split(' ')[0];
            const widthMatch = trimmed.match(/(\d+)w/);
            if (widthMatch) {
              const width = parseInt(widthMatch[1]);
              if (width > bestWidth) { bestWidth = width; bestUrl = urlPart; }
            }
          }
          url = bestUrl;
        }
        if (url && !url.startsWith('http') && !url.startsWith('blob:') && !url.startsWith('data:')) {
          try { url = new URL(url, window.location.href).href; } catch (e) { console.log('URL解析失败:', e); }
        }
        if (url && (url.includes('google.com/imgres') || url.includes('bing.com/images/search') || url.includes('imgres') || url.includes('mediaurl='))) {
          try {
            const u = new URL(url);
            const imgUrl = u.searchParams.get('imgurl') || u.searchParams.get('mediaurl') || u.searchParams.get('surl') || u.searchParams.get('imgrefurl');
            if (imgUrl && isMediaUrl(imgUrl)) { url = imgUrl; }
          } catch (e) { console.log('解析图片搜索URL失败:', e); }
        }
        // TikPORN 的 Blob/MSE URL 与当前 video 元素一一绑定。不能用页面级
        // “最近捕获的 MPD”提前覆盖它，否则列表预加载下一条时会下载错视频。
        let isElementBoundFeedContext = false;
        try {
          const hosts = [location.hostname || ''];
          if (document.referrer) hosts.push(new URL(document.referrer).hostname || '');
          isElementBoundFeedContext = hosts.some(host => {
            const normalized = String(host).toLowerCase();
            return normalized === 'tik.porn' || normalized.endsWith('.tik.porn') ||
                   normalized === 'pin.porn' || normalized.endsWith('.pin.porn') ||
                   normalized === 'x.com' || normalized.endsWith('.x.com') ||
                   normalized === 'twitter.com' || normalized.endsWith('.twitter.com');
          });
        } catch (_) {}
        const preserveBoundBlob = isElementBoundFeedContext && String(url || '').startsWith('blob:');

        // 拦截到的 m3u8/mp4 不要被 DOM 里的海报图、缩略图或占位 src 覆盖（否则原生侧会当图片下载或失败后退化为截屏）
        if (interceptedStreamUrl && videoEl && !preserveBoundBlob) {
          const dom = (url || '').toLowerCase();
          const domHasStream = /\\.(m3u8|m3u|mp4|webm|ts)(\\?|#|\$)/.test(dom) || dom.includes('mpegurl');
          if (!domHasStream || domUrlLooksLikePosterOrThumb(url) || url === videoEl.poster) {
            const i = interceptedStreamUrl.toLowerCase();
            if (i.includes('.m3u8') || i.includes('.m3u') || i.includes('mpegurl') || /\\.(mp4|webm|ts)(\\?|#|\$)/.test(i)) {
              url = interceptedStreamUrl;
            }
          }
        }
        if (isPinPornContext && target.__appPinnedDownloadUrl) {
          // Do not let requests accumulated from previous/adjacent slides
          // participate in this independent long-press session.
          url = target.__appPinnedDownloadUrl;
          interceptedStreamUrl = null;
        }
        if (isTikPornContext && target.__appTikDownloadUrl) {
          // The source belongs to the one player selected for this session.
          // Do not allow globally captured previous/next manifests to replace
          // it or participate as retry candidates.
          url = target.__appTikDownloadUrl;
          interceptedStreamUrl = null;
        }
        if (!url) {
          if (videoEl && videoEl.srcObject) {
            updateFeedbackStatus('该视频为直播流，无法下载', false);
            return;
          }
          const innerV = (target.querySelector && target.querySelector('video')) || videoEl;
          const innerUrl = innerV && (innerV.currentSrc || innerV.src);
          if (innerUrl) url = innerUrl;
          else if (videoEl && window.MediaInterceptor && window.MediaInterceptor.interceptedRequests) {
            const now = Date.now();
            let bestUrl = null, bestTime = 0;
            for (const [u, info] of window.MediaInterceptor.interceptedRequests) {
              if (!u || (now - info.timestamp) > 600000 || isMediaFragmentUrl(u)) continue;
              const ct = (info.contentType || '').toLowerCase();
              const isVideo = ct.startsWith('video/') || ct.includes('mpegurl') || ct.includes('m3u8') || isMediaUrl(u);
              if (isVideo && !isApiUrl(u) && info.timestamp > bestTime) {
                bestTime = info.timestamp; bestUrl = u;
              }
            }
            if (bestUrl) url = bestUrl;
          }
          if (!url) {
            updateFeedbackStatus('未找到下载链接', false);
            return;
          }
        }
        if (isApiUrl(url)) {
          updateFeedbackStatus('该链接不是媒体文件', false);
          return;
        }
        // 多重处理blob/data url
        function tryBlobOrDataUrl(url, mediaType) {
          if (isBlobUrl(url)) {
            if (mediaType === 'video' && isElementBoundFeedContext) {
              let boundFragments = [];
              try {
                if (videoEl && typeof window.__appMediaFragmentsForVideo === 'function') {
                  boundFragments = window.__appMediaFragmentsForVideo(videoEl);
                }
              } catch (_) {}
              // 该站 Blob 只是 MSE 播放入口；不要先读取完整 Blob，直接让原生侧使用已捕获的 MPD。
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: 'video',
                url: url,
                isBase64: false,
                isStreamReference: true,
                isSmartGesture: isSmartGesture,
                action: 'download',
                pageUrl: location.href || '',
                sourcePageUrl: isXPlatformContext
                  ? String(target.__appXStatusUrl || location.href || '')
                  : String(location.href || ''),
                siteMediaId: isXPlatformContext
                  ? String(target.__appXStatusId || '')
                  : '',
                expectedXMediaId: isXPlatformContext
                  ? String(target.__appXMediaId || '')
                  : '',
                title: document.title || '',
                positionSec: videoEl && isFinite(Number(videoEl.currentTime)) ? Number(videoEl.currentTime) : 0,
                durationSec: effectiveVideoDuration(videoEl),
                sessionId: longPressSessionId,
                playbackStartedAtMs: Date.now() - Math.max(0, Number(videoEl && videoEl.currentTime || 0)) * 1000,
                boundFragments: boundFragments,
                candidates: cands
              }));
              updateFeedbackStatus('正在获取下载地址…', null);
              return true;
            }
            updateFeedbackStatus('正在处理blob...', true);
            resolveBlobUrl(url, mediaType).then(resolved => {
              if (resolved) {
                Flutter.postMessage(JSON.stringify({
                  type: 'media',
                  mediaType: resolved.mediaType || mediaType,
                  url: resolved.resolvedUrl,
                  isBase64: resolved.isBase64,
                  isSmartGesture: isSmartGesture,
                  action: 'download',
                  pageUrl: location.href || '',
                  title: document.title || '',
                  positionSec: videoEl && isFinite(Number(videoEl.currentTime)) ? Number(videoEl.currentTime) : 0,
                  durationSec: effectiveVideoDuration(videoEl),
                  sessionId: longPressSessionId,
                  playbackStartedAtMs: Date.now() - Math.max(0, Number(videoEl && videoEl.currentTime || 0)) * 1000,
                  candidates: cands
                }));
                updateFeedbackStatus('正在保存…', null);
              } else {
                const tag = (target.tagName || '').toLowerCase();
                const v = tag === 'video' ? target : (target.querySelector && target.querySelector('video'));
                try {
                  if (tag === 'canvas') {
                    const dataUrl = target.toDataURL('image/png');
                    if (dataUrl && dataUrl.startsWith('data:image/')) {
                      Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: extractBase64FromDataUrl(dataUrl), isBase64: true, isSmartGesture: isSmartGesture, action: 'download' }));
                      updateFeedbackStatus('已截图保存', true);
                      return;
                    }
                  } else if (v && v.readyState >= 2) {
                    tryMediaRecorderCapture(v, function(success) {
                      if (!success) {
                        try {
                          const c = document.createElement('canvas');
                          c.width = v.videoWidth || 640;
                          c.height = v.videoHeight || 360;
                          const ctx = c.getContext('2d');
                          if (ctx) {
                            ctx.drawImage(v, 0, 0);
                            const dataUrl = c.toDataURL('image/png');
                            if (dataUrl && dataUrl.startsWith('data:image/')) {
                              Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: extractBase64FromDataUrl(dataUrl), isBase64: true, isSmartGesture: isSmartGesture, action: 'download' }));
                              updateFeedbackStatus('已保存当前画面为图片', true);
                              return;
                            }
                          }
                        } catch (e) {}
                        updateFeedbackStatus('blob解析失败', false);
                      }
                    });
                    return;
                  }
                } catch (err) { console.log('兜底失败', err); }
                updateFeedbackStatus('blob解析失败', false);
              }
            });
            return true;
          } else if (url.startsWith('data:image/') || url.startsWith('data:video/') || url.startsWith('data:audio/')) {
            // data url直接base64解码，用 extractBase64FromDataUrl 处理 MIME 含逗号的情况
            try {
              const b64 = extractBase64FromDataUrl(url) || '';
              if (!b64 || b64.length < 10) { updateFeedbackStatus('data url无有效数据', false); return false; }
              const mt = url.startsWith('data:image/') ? 'image' : (url.startsWith('data:video/') ? 'video' : 'audio');
              Flutter.postMessage(JSON.stringify({
                type: 'media',
                mediaType: mt,
                url: b64,
                isBase64: true,
                isSmartGesture: isSmartGesture,
                action: 'download'
              }));
              updateFeedbackStatus('已保存data url', true);
              return true;
            } catch (err) { updateFeedbackStatus('data url解析失败', false); }
          }
          return false;
        }
        const urlLower = url.toLowerCase();
        let mediaType = 'video';
        if (tagName === 'img' || tagName === 'image') {
          mediaType = 'image';
        } else if (tagName === 'video') {
          mediaType = 'video';
        } else if (/\\.(jpg|jpeg|png|gif|webp|bmp|svg|ico|tiff|tif|heic|heif)(\\?|#|\\\$)/i.test(urlLower)) {
          mediaType = 'image';
        } else if (/\\.(m3u8|m3u|mp4|webm|mov|avi|mkv|flv|wmv|ts|m4v|3gp|ogv|f4v)(\\?|#|\\\$)/i.test(urlLower)) {
          mediaType = 'video';
        } else if (videoEl && (videoEl.currentSrc || videoEl.src)) {
          mediaType = 'video';
        }
        const className = target.className ? target.className.toLowerCase() : '';
        const id = target.id ? target.id.toLowerCase() : '';

        if (!markMediaUrlProcessing(url)) {
          updateFeedbackStatus('该媒体已在处理中', false);
          e.preventDefault();
          return;
        }
        
        // 收集候选 URL（与收藏逻辑一致）
        const cands = [];
        const seen = new Set();
        const push = (u) => {
          if (!u || typeof u !== 'string') return;
          let s = u.trim();
          if (!s) return;
          if (!s.startsWith('http://') && !s.startsWith('https://')) {
            try { s = new URL(s, location.href).toString(); } catch (_) {}
          }
          s = normalizeMediaCandidateUrl(s) || '';
          if (!s || seen.has(s) || isApiUrl(s) || isAdUrl(s)) return;
          seen.add(s);
          cands.push(s);
        };
        const pushSrcset = (srcset) => {
          if (!srcset || typeof srcset !== 'string') return;
          const parts = srcset.split(',').map(s => s.trim()).filter(Boolean);
          for (const part of parts) {
            const u = part.split(/\s+/)[0];
            push(u);
          }
        };
        const pushAttr = (el, name) => {
          try { push(el && el.getAttribute && el.getAttribute(name)); } catch (_) {}
        };
        push(url);
        if (isTikPornContext && target.__appTikDownloadUrl) {
          // The exact source is intentionally the only TikPORN candidate.
        } else if (isPinPornContext && target.__appPinPlayingFallbackUrl) {
          push(target.__appPinPlayingFallbackUrl);
        } else if (interceptedStreamUrl) {
          push(interceptedStreamUrl);
        }
        if (!(isTikPornContext && target.__appTikDownloadUrl)) try {
          push(target.currentSrc || target.src || target.href);
          pushAttr(target, 'src');
          pushAttr(target, 'href');
          pushAttr(target, 'data-src');
          pushAttr(target, 'data-original');
          pushAttr(target, 'data-url');
          pushAttr(target, 'data-href');
          pushAttr(target, 'data-video-src');
          pushAttr(target, 'data-media');
          pushAttr(target, 'data-full');
          pushAttr(target, 'data-large');
          pushAttr(target, 'data-lazy-src');
          pushAttr(target, 'data-lazy');
          if (!videoEl) pushAttr(target, 'poster');
          pushSrcset(target.srcset || (target.getAttribute && target.getAttribute('srcset')));
          const bg = (target.style && (target.style.backgroundImage || target.style.background)) || '';
          const bgMatches = String(bg).matchAll(/url\(['"]?([^'")]+)['"]?\)/g);
          for (const m of bgMatches) push(m[1]);
        } catch (_) {}
        if (videoEl && !isPinPornContext && !(isTikPornContext && target.__appTikDownloadUrl)) {
          try {
            const srcs = Array.from(videoEl.querySelectorAll('source')).map(s => s.src || s.getAttribute('src'));
            for (const s of srcs) push(s || '');
            push(videoEl.currentSrc || videoEl.src);
          } catch (_) {}
        }
        try {
          const mediaInside = target.querySelectorAll && target.querySelectorAll('img, video, source, a[href]');
          if (mediaInside && !isPinPornContext) {
            Array.from(mediaInside).slice(0, 30).forEach(el => {
              push(el.currentSrc || el.src || el.href);
              pushAttr(el, 'src');
              pushAttr(el, 'href');
              pushAttr(el, 'data-src');
              pushAttr(el, 'data-original');
              pushAttr(el, 'data-video-src');
              if (!videoEl) pushAttr(el, 'poster');
              pushSrcset(el.srcset || (el.getAttribute && el.getAttribute('srcset')));
            });
          }
        } catch (_) {}
        if (tryBlobOrDataUrl(url, mediaType)) {
          e.preventDefault();
          return;
        }
        window._lastMediaTargetForFallback = target;
        Flutter.postMessage(JSON.stringify({
          type: 'media',
          mediaType: mediaType,
          url: url,
          isBase64: false,
          isSmartGesture: isSmartGesture,
          action: 'download',
          pageUrl: location.href || '',
          title: document.title || '',
          sessionId: longPressSessionId,
          siteMediaId: isPinPornContext
            ? String(target.__appPinSlideId || '')
            : (isTikPornContext
              ? String(target.__appTikVideoId || '')
              : (isXPlatformContext ? String(target.__appXStatusId || '') : '')),
          sourcePageUrl: isXPlatformContext
            ? String(target.__appXStatusUrl || location.href || '')
            : String(location.href || ''),
          expectedXMediaId: isXPlatformContext
            ? String(target.__appXMediaId || '')
            : '',
          playbackStartedAtMs: Date.now() - Math.max(0, Number(videoEl && videoEl.currentTime || 0)) * 1000,
          durationSec: effectiveVideoDuration(videoEl),
          candidates: cands
        }));
        updateFeedbackStatus('正在稳健保存…', null);
        e.preventDefault();
      }

      function tryCanvasCaptureFallback() {
        const target = window._lastMediaTargetForFallback;
        window._lastMediaTargetForFallback = null;
        if (!target) return;
        const tag = target.tagName ? target.tagName.toLowerCase() : '';
        let w = target.naturalWidth || target.videoWidth || target.width || target.offsetWidth;
        let h = target.naturalHeight || target.videoHeight || target.height || target.offsetHeight;
        if (w <= 0 || h <= 0) { w = target.offsetWidth || 200; h = target.offsetHeight || 200; }
        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        function postBase64(base64) {
          if (base64) Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: base64, isBase64: true, action: 'download' }));
        }
        function tryFetchImageAsBase64(src, onFail) {
          if (!src) { if (onFail) onFail(); return; }
          fetch(src, { mode: 'cors', credentials: 'omit', cache: 'no-store' })
            .then(function(r) {
              if (!r || !r.ok) throw new Error('fetch not ok');
              return r.blob();
            })
            .then(function(blob) {
              const fr = new FileReader();
              fr.onload = function() {
                const b64 = extractBase64FromDataUrl(fr.result);
                if (b64) postBase64(b64);
                else if (onFail) onFail();
              };
              fr.onerror = function() { if (onFail) onFail(); };
              fr.readAsDataURL(blob);
            })
            .catch(function() {
              fetch(src, { mode: 'cors', credentials: 'include', cache: 'no-store' })
                .then(function(r) { if (!r || !r.ok) throw new Error('fetch2 not ok'); return r.blob(); })
                .then(function(blob) {
                  const fr = new FileReader();
                  fr.onload = function() {
                    const b64 = extractBase64FromDataUrl(fr.result);
                    if (b64) postBase64(b64);
                    else if (onFail) onFail();
                  };
                  fr.onerror = function() { if (onFail) onFail(); };
                  fr.readAsDataURL(blob);
                })
                .catch(function() { if (onFail) onFail(); });
            });
        }
        function postCanvas(srcForFetch) {
          try {
            const dataUrl = canvas.toDataURL('image/png');
            if (dataUrl && dataUrl.startsWith('data:image/')) {
              Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: extractBase64FromDataUrl(dataUrl), isBase64: true, action: 'download' }));
              return;
            }
          } catch (e) { console.log('toDataURL failed:', e); }
          if (srcForFetch) tryFetchImageAsBase64(srcForFetch, null);
        }
        function tryDrawImg(src) {
          const img = new Image();
          img.crossOrigin = 'anonymous';
          img.onload = function() {
            try { ctx.drawImage(img, 0, 0, w, h); postCanvas(src); } catch (e) {
              try { ctx.drawImage(target, 0, 0, w, h); postCanvas(src); } catch (e2) { tryFetchImageAsBase64(src, null); }
            }
          };
          img.onerror = function() {
            try { ctx.drawImage(target, 0, 0, w, h); postCanvas(src); } catch (e) { tryFetchImageAsBase64(src, null); }
          };
          img.src = src;
        }
        if (tag === 'img') {
          const src = target.currentSrc || target.src;
          if (src) {
            tryFetchImageAsBase64(src, function() { tryDrawImg(src); });
          }
        } else if (tag === 'video') {
          try {
            ctx.drawImage(target, 0, 0, w, h);
            postCanvas(null);
          } catch (e) {
            console.log('video canvas fallback failed:', e);
          }
        } else if (tag === 'canvas') {
          try {
            ctx.drawImage(target, 0, 0, w, h);
            postCanvas(null);
          } catch (e) { console.log('canvas fallback failed:', e); }
        } else if (target.style && target.style.backgroundImage) {
          const m = target.style.backgroundImage.match(/url\(['"]?([^'")]+)['"]?\)/);
          if (m && m[1]) {
            const u = m[1];
            tryFetchImageAsBase64(u, function() { tryDrawImg(u); });
          }
        }
      }

      // 启动动态内容监听
      const dynamicObserver = observeDynamicContent();
      
      // 初始扫描页面媒体元素
      setTimeout(() => {
        const initialMediaElements = deepScanForMediaElements();
        initialMediaElements.forEach(element => {
          window.MediaInterceptor.mediaElements.add(element);
        });
        console.log('初始扫描完成，找到', initialMediaElements.length, '个媒体元素');
      }, 1000);
      window.updateFeedbackStatus = updateFeedbackStatus;
      window.tryCanvasCaptureFallback = tryCanvasCaptureFallback;
      window.__appMediaDownloadHandlersVersion = handlerVersion;
      return true;
      })()
    ''',
      );
      final ready = await controller.evaluateJavascript(
        source:
            "window.__appMediaDownloadHandlersVersion === 'media-download-v18'",
      );
      if (ready == true || ready.toString().toLowerCase() == 'true') {
        if (_lastMediaHandlerFailureUrl == injectionUrl) {
          _lastMediaHandlerFailureUrl = '';
          _lastMediaHandlerFailureAt = null;
        }
        return true;
      }
    } catch (e, st) {
      debugPrint('网页媒体长按处理程序安装失败: $e\n$st');
    }
    final currentUrl = (await controller.getUrl())?.toString() ?? _currentUrl;
    if (!_isSameLoadedDocument(injectionUrl, currentUrl)) {
      debugPrint('媒体处理程序注入期间页面已切换，忽略旧页面失败: $injectionUrl -> $currentUrl');
      return false;
    }
    if (allowRetry && mounted && identical(controller, _controller)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return _injectDownloadHandlers(
        allowRetry: false,
        expectedUrl: injectionUrl,
      );
    }
    if (mounted) {
      final now = DateTime.now();
      final recentlyNotified =
          _lastMediaHandlerFailureUrl == injectionUrl &&
          _lastMediaHandlerFailureAt != null &&
          now.difference(_lastMediaHandlerFailureAt!) <
              const Duration(seconds: 30);
      if (!recentlyNotified) {
        _lastMediaHandlerFailureUrl = injectionUrl;
        _lastMediaHandlerFailureAt = now;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('媒体监听初始化失败，已自动改用兼容模式继续尝试'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
    return false;
  }

  Future<void> _handleJavaScriptMessage(String message) async {
    try {
      final data = jsonDecode(message);
      if (data is! Map || !data.containsKey('type')) return;

      final dynamic urlValue = data['url'];
      final bool isBase64 = data['isBase64'] ?? false;
      final bool isStreamReference = data['isStreamReference'] == true;
      final bool isSmartGesture = data['isSmartGesture'] == true;
      final String? action = data['action'];
      final dynamic candidateValue = data['candidates'];
      final String mediaType =
          data['mediaType'] ??
          (_guessMimeType(
                urlValue is String ? urlValue : '',
              ).startsWith('image/')
              ? 'image'
              : (_guessMimeType(
                    urlValue is String ? urlValue : '',
                  ).startsWith('video/')
                  ? 'video'
                  : 'audio'));
      final String sourceMimeType =
          (data['mimeType'] ?? data['mime'] ?? '').toString();
      final messageDurationSeconds =
          (data['durationSec'] as num?)?.toDouble() ?? 0.0;
      final mediaSessionId = (data['sessionId'] ?? '').toString().trim();
      final playbackStartedAtMs =
          (data['playbackStartedAtMs'] as num?)?.toInt() ?? 0;
      final sessionNotBefore =
          playbackStartedAtMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(
                playbackStartedAtMs,
              ).subtract(const Duration(seconds: 2))
              : null;
      final rawDownloadCandidateUrls = <String>[];
      if (candidateValue is List) {
        for (final e in candidateValue) {
          if (e is String && e.trim().isNotEmpty) {
            rawDownloadCandidateUrls.add(_toAbsoluteUrl(e.trim()));
          }
        }
      }
      final messagePageUrl = (data['pageUrl'] ?? _currentUrl).toString().trim();
      // Media events can originate from a cross-origin player iframe/CDN even
      // when the visible top-level page is TikPORN. Check both contexts so all
      // long-press download paths apply the same site-specific policy.
      final isElementBoundFeedDownloadContext =
          _isElementBoundFeedPage(messagePageUrl) ||
          _isElementBoundFeedPage(_currentUrl);
      final requestedMediaType =
          mediaType == 'video'
              ? MediaType.video
              : mediaType == 'audio'
              ? MediaType.audio
              : MediaType.image;
      if (action == 'favorite' && requestedMediaType == MediaType.video) {
        rawDownloadCandidateUrls.addAll(
          _recentCapturedMediaCandidates(
            requestedMediaType,
            pageUrl: messagePageUrl,
          ),
        );
      }
      final downloadCandidateUrls = normalizeMediaCandidateUrls(
        rawDownloadCandidateUrls,
        video: requestedMediaType == MediaType.video,
        maxCandidates: action == 'download' ? 4 : 12,
      );
      for (final candidate in downloadCandidateUrls) {
        _trustMediaCandidate(candidate);
      }
      if (urlValue is String && !isBase64) {
        _trustMediaCandidate(urlValue);
      }

      if (urlValue is! String) return;
      if (action == 'favorite') {
        final pageUrl = (data['pageUrl'] ?? '').toString().trim();
        final title = (data['title'] ?? '').toString().trim();
        final positionSec = (data['positionSec'] as num?)?.toDouble() ?? 0.0;
        final durationSec = (data['durationSec'] as num?)?.toDouble() ?? 0.0;
        final candidateUrls = List<String>.from(downloadCandidateUrls);
        final normalizedVideoUrl = _toAbsoluteUrl(urlValue);
        if (normalizedVideoUrl.isNotEmpty &&
            (_isLikelyAdUrl(normalizedVideoUrl) ||
                _looksLikePreviewClipUrl(normalizedVideoUrl))) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('检测到广告/预览片段，未加入收藏'),
                duration: Duration(milliseconds: 1200),
              ),
            );
          }
          return;
        }
        final pageKey = _normalizeUrlForKey(
          (pageUrl.isNotEmpty ? pageUrl : _currentUrl).trim(),
        );
        final videoKey =
            normalizedVideoUrl.isEmpty
                ? ''
                : _normalizeUrlForKey(normalizedVideoUrl);
        final exists = (await _loadSharedFavoriteVideos()).any((row) {
          final pk =
              (row['pageKey'] ?? '').toString().trim().isNotEmpty
                  ? (row['pageKey'] ?? '').toString().trim()
                  : _normalizeUrlForKey((row['pageUrl'] ?? '').toString());
          final vk =
              (row['videoKey'] ?? '').toString().trim().isNotEmpty
                  ? (row['videoKey'] ?? '').toString().trim()
                  : _normalizeUrlForKey((row['videoUrl'] ?? '').toString());
          if (videoKey.isNotEmpty && vk == videoKey) return true;
          if (pageKey.isNotEmpty && pk == pageKey) return true;
          return false;
        });
        if (exists) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('请勿重复收藏'),
                duration: Duration(milliseconds: 1000),
              ),
            );
          }
          final ctrl = _controller;
          if (ctrl != null) {
            unawaited(
              ctrl.evaluateJavascript(
                source:
                    "typeof updateFeedbackStatus === 'function' && updateFeedbackStatus('请勿重复收藏', false);",
              ),
            );
          }
          return;
        }
        await _addSharedFavoriteFromBrowser(
          pageUrl: pageUrl.isNotEmpty ? pageUrl : _currentUrl,
          videoUrl: normalizedVideoUrl,
          title: title,
          positionSec: positionSec,
          durationSec: durationSec,
          candidateUrls: candidateUrls,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已收藏当前视频'),
              duration: Duration(milliseconds: 1200),
            ),
          );
        }
        return;
      }
      if (action != 'download') return;

      // 如果是视频下载，且不是 Base64（Base64 通常是 Canvas/Recorder 生成的小文件），
      // 则强制使用稳健下载逻辑，以解决 Blob 断流或残缺问题。
      if (mediaType == 'video' && !isBase64 && !isStreamReference) {
        if (_longPressVideoDownloadInProgress) {
          if (isSmartGesture) {
            final task = _smartDownloadTask;
            if (task != null) {
              task['lastGestureFailureType'] = 'already_downloading';
            }
            await _completeSmartGestureDownload(false);
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('当前长按的视频正在保存，请勿重复长按'),
                duration: Duration(milliseconds: 1600),
              ),
            );
          }
          return;
        }
        _longPressVideoDownloadInProgress = true;
        try {
          final pageUrl = (data['pageUrl'] ?? '').toString().trim();
          final sourcePageUrl = (data['sourcePageUrl'] ?? '').toString().trim();
          final title = (data['title'] ?? '').toString().trim();
          var candidateUrls = List<String>.from(downloadCandidateUrls);
          final normalizedPrimary = normalizeMediaCandidateUrls(
            <String>[_toAbsoluteUrl(urlValue)],
            video: true,
            maxCandidates: 1,
          );
          var primaryVideoUrl =
              normalizedPrimary.isEmpty ? '' : normalizedPrimary.first;
          final isXDownload =
              _isXPlatformPage(pageUrl) || _isXPlatformPage(_currentUrl);
          final expectedXMediaId =
              (data['expectedXMediaId'] ?? '').toString().trim();

          final xCandidates = await _resolveXLongPressVideoCandidates(
            primaryUrl: primaryVideoUrl,
            candidates: candidateUrls,
            pageUrl: pageUrl.isNotEmpty ? pageUrl : _currentUrl,
            expectedMediaId: expectedXMediaId,
            notBefore: sessionNotBefore,
          );
          if (isXDownload && xCandidates.isNotEmpty) {
            primaryVideoUrl = xCandidates.first;
            candidateUrls = xCandidates.skip(1).toList();
          } else if (isXDownload && expectedXMediaId.isNotEmpty) {
            primaryVideoUrl = '';
            candidateUrls = <String>[];
          }

          if (primaryVideoUrl.isEmpty && candidateUrls.isEmpty) {
            if (isSmartGesture) {
              final task = _smartDownloadTask;
              if (task != null) {
                task['lastGestureFailureType'] = 'no_direct_url';
              }
              await _completeSmartGestureDownload(false);
            } else if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('当前仅检测到无法单独保存的视频分片，请继续播放后再长按重试'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
            return;
          }

          final itemMap = {
            'pageUrl':
                sourcePageUrl.isNotEmpty
                    ? sourcePageUrl
                    : (pageUrl.isNotEmpty ? pageUrl : _currentUrl),
            'videoUrl': primaryVideoUrl,
            'title': title,
            'candidateUrls': candidateUrls,
            'downloadOrigin': 'long_press',
            'isSmartGesture': isSmartGesture,
            'smartTask': isSmartGesture ? _smartDownloadTask : null,
            'sessionId': mediaSessionId,
            'durationSec': messageDurationSeconds,
          };

          final downloaded = await _downloadMediaRobustly(
            item: itemMap,
            showResultHint: !isSmartGesture,
          );
          if (isSmartGesture) {
            await _completeSmartGestureDownload(downloaded);
          }
          return;
        } finally {
          _longPressVideoDownloadInProgress = false;
          _releaseJsProcessedUrl(urlValue);
        }
      }

      // Base64 不参与去重；HTTP(S) URL 带 TTL，避免 finally 未执行时永久无法重下同一链接。
      var didRegisterMediaUrl = false;
      if (!isBase64 && !isStreamReference) {
        if (!_tryRegisterMediaUrlForProcessing(urlValue)) {
          if (isSmartGesture) {
            final task = _smartDownloadTask;
            if (task != null) {
              task['lastGestureFailureType'] = 'already_downloading';
            }
            await _completeSmartGestureDownload(false);
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('该链接正在保存中，请稍候再试'),
                duration: _kMediaSaveSnackDuration,
              ),
            );
          }
          return;
        }
        didRegisterMediaUrl = true;
      }

      try {
        debugPrint(
          'Received URL from JavaScript with download action: $urlValue, type: $mediaType, isBase64: $isBase64',
        );

        if (isBase64 || isStreamReference) {
          if (isBase64 && _awaitingCanvasFallbackResult) {
            _canvasFallbackSucceeded = true;
            _canvasFallbackCompleter?.complete(true);
          }
          if (mediaType == 'video') {
            final useElementBoundDisambiguation =
                isElementBoundFeedDownloadContext;
            if (isStreamReference &&
                (_isXPlatformPage(messagePageUrl) ||
                    _isXPlatformPage(_currentUrl))) {
              final directXUrls =
                  downloadCandidateUrls
                      .where((url) => _xMediaIdentity(url).isNotEmpty)
                      .toList();
              if (directXUrls.isNotEmpty) {
                final xCandidates = await _resolveXLongPressVideoCandidates(
                  primaryUrl: directXUrls.first,
                  candidates: directXUrls.skip(1).toList(),
                  pageUrl: messagePageUrl,
                  expectedMediaId:
                      (data['expectedXMediaId'] ?? '').toString().trim(),
                  notBefore: sessionNotBefore,
                );
                if (xCandidates.isNotEmpty) {
                  final sourcePageUrl =
                      (data['sourcePageUrl'] ?? messagePageUrl)
                          .toString()
                          .trim();
                  final downloaded = await _downloadMediaRobustly(
                    item: <String, dynamic>{
                      'pageUrl':
                          sourcePageUrl.isNotEmpty
                              ? sourcePageUrl
                              : messagePageUrl,
                      'videoUrl': xCandidates.first,
                      'candidateUrls': xCandidates.skip(1).toList(),
                      'title': (data['title'] ?? '').toString(),
                      'downloadOrigin': 'long_press',
                      'isSmartGesture': isSmartGesture,
                      'smartTask': isSmartGesture ? _smartDownloadTask : null,
                      'sessionId': mediaSessionId,
                      'durationSec': messageDurationSeconds,
                    },
                    showResultHint: !isSmartGesture,
                  );
                  if (isSmartGesture) {
                    await _completeSmartGestureDownload(downloaded);
                  }
                  return;
                }
              }
            }
            final boundFragmentValue = data['boundFragments'];
            final boundFragmentUrls = <String>[];
            if (useElementBoundDisambiguation && boundFragmentValue is List) {
              for (final value in boundFragmentValue) {
                if (value is String && value.trim().isNotEmpty) {
                  boundFragmentUrls.add(value.trim());
                }
              }
            }
            final boundStreamCandidates =
                normalizeMediaCandidateUrls(
                  boundFragmentUrls,
                  video: true,
                  maxCandidates: 8,
                ).where((candidate) {
                  return !_looksLikeMediaFragmentUrl(candidate) &&
                      _isLikelyDirectMediaUrl(candidate);
                }).toList();
            if (boundStreamCandidates.isNotEmpty) {
              // These URLs were consumed by the exact MediaSource attached to
              // the long-pressed video, so they outrank every page-level sniff.
              final selectedManifest = boundStreamCandidates.first;
              final downloaded = await _downloadMediaRobustly(
                item: <String, dynamic>{
                  'pageUrl': _currentUrl,
                  'videoUrl': selectedManifest,
                  'candidateUrls': boundStreamCandidates,
                  'title': (data['title'] ?? '').toString(),
                  'downloadOrigin': 'long_press',
                  'isSmartGesture': isSmartGesture,
                  'smartTask': isSmartGesture ? _smartDownloadTask : null,
                  'sessionId': mediaSessionId,
                  'durationSec': messageDurationSeconds,
                },
                showResultHint: !isSmartGesture,
              );
              if (isSmartGesture) {
                await _completeSmartGestureDownload(downloaded);
              }
              return;
            }
            final boundDashCandidates =
                normalizeMediaCandidateUrls(
                  boundFragmentUrls,
                  video: true,
                  maxCandidates: 8,
                ).where((candidate) {
                  return Uri.tryParse(
                        candidate,
                      )?.path.toLowerCase().endsWith('.mpd') ??
                      false;
                }).toList();
            final activeDashCandidates =
                useElementBoundDisambiguation
                    ? _recentActiveDashManifestCandidates(
                      pageUrl: messagePageUrl,
                      notBefore: sessionNotBefore,
                    )
                    : const <String>[];
            final capturedDashCandidates =
                _recentCapturedMediaCandidates(
                  MediaType.video,
                  pageUrl: messagePageUrl,
                  notBefore: sessionNotBefore,
                ).where((candidate) {
                  final path =
                      Uri.tryParse(candidate)?.path.toLowerCase() ?? '';
                  return path.endsWith('.mpd');
                }).toList();
            final dashCandidates = <String>[
              ...boundDashCandidates,
              ...activeDashCandidates.where(
                (candidate) => !boundDashCandidates.contains(candidate),
              ),
              ...capturedDashCandidates.where(
                (candidate) =>
                    !boundDashCandidates.contains(candidate) &&
                    !activeDashCandidates.contains(candidate),
              ),
            ];
            if (dashCandidates.isNotEmpty) {
              // 当前播放会持续产生分片请求；下一条通常仅预加载 MPD/少量分片。
              final selectedManifest =
                  boundDashCandidates.isNotEmpty
                      ? boundDashCandidates.first
                      : useElementBoundDisambiguation
                      ? await _selectDashManifestForLongPress(
                        dashCandidates,
                        targetDurationSeconds: messageDurationSeconds,
                      )
                      : dashCandidates.first;
              if (selectedManifest == null) {
                if (isSmartGesture) {
                  final task = _smartDownloadTask;
                  if (task != null) {
                    task['lastGestureFailureType'] = 'no_direct_url';
                  }
                  await _completeSmartGestureDownload(false);
                }
                return;
              }
              final downloaded = await _downloadMediaRobustly(
                item: <String, dynamic>{
                  'pageUrl': _currentUrl,
                  'videoUrl': selectedManifest,
                  'candidateUrls': <String>[
                    selectedManifest,
                    ...dashCandidates.where(
                      (candidate) => candidate != selectedManifest,
                    ),
                  ],
                  'title': (data['title'] ?? '').toString(),
                  'downloadOrigin': 'long_press',
                  'isSmartGesture': isSmartGesture,
                  'smartTask': isSmartGesture ? _smartDownloadTask : null,
                  'sessionId': mediaSessionId,
                  'durationSec': messageDurationSeconds,
                },
                showResultHint: !isSmartGesture,
              );
              if (isSmartGesture) {
                await _completeSmartGestureDownload(downloaded);
              }
              return;
            }
          }
          if (isStreamReference) {
            if (isSmartGesture) {
              await _completeSmartGestureDownload(false);
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('尚未捕获当前视频的完整下载地址，请继续播放几秒后重试'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
            return;
          }
          if (isSmartGesture) {
            _mediaDownloadSaveResolved = false;
          }
          await _handleBlobUrl(
            urlValue,
            mediaType,
            sourceMimeType: sourceMimeType,
          );
          if (isSmartGesture) {
            await _completeSmartGestureDownload(_mediaDownloadSaveResolved);
          }
          return;
        }

        _mediaDownloadFailHintTimer?.cancel();
        _mediaDownloadSaveResolved = false;

        final absoluteUrl = _toAbsoluteUrl(urlValue);
        final referer = _getMediaReferer(absoluteUrl);
        final resolvedUrl = await _resolveFinalUrl(
          urlValue,
          headers: {
            'Referer': referer,
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Accept': '*/*',
          },
        );
        _trustMediaCandidate(resolvedUrl);
        final mimeType = _guessMimeType(resolvedUrl);
        MediaType selectedType = _determineMediaType(mimeType);
        if (mimeType == 'application/octet-stream') {
          selectedType = requestedMediaType;
        }
        if (selectedType == MediaType.image &&
            _urlLooksLikeVideoStream(resolvedUrl)) {
          selectedType = MediaType.video;
        }
        if (selectedType == MediaType.video) {
          final existing = await _findExistingVideoBeforeDownload(resolvedUrl);
          if (existing != null) {
            if (isSmartGesture) {
              final task = _smartDownloadTask;
              if (task != null) {
                task['lastGestureFailureType'] = 'already_in_library';
              }
              await _completeSmartGestureDownload(false);
              return;
            }
            if (!await _confirmSourceUrlDuplicateBeforeDownload(existing)) {
              return;
            }
          }
        }
        final canCanvasFallback = selectedType == MediaType.image;
        final attempts = <String>[];
        final seenAttempts = <String>{};
        void pushAttempt(String? candidate) {
          if (candidate == null) return;
          final absolute = _toAbsoluteUrl(candidate.trim());
          if (absolute.isEmpty ||
              seenAttempts.contains(absolute) ||
              (_isApiEndpointUrl(absolute) &&
                  !_isTrustedMediaCandidate(absolute)) ||
              absolute.startsWith('blob:') ||
              absolute.startsWith('data:')) {
            return;
          }
          if (selectedType == MediaType.image &&
              _urlLooksLikeVideoStream(absolute)) {
            return;
          }
          seenAttempts.add(absolute);
          attempts.add(absolute);
        }

        pushAttempt(resolvedUrl);
        for (final candidate in downloadCandidateUrls) {
          pushAttempt(candidate);
        }
        if (attempts.length > 3) {
          attempts.removeRange(3, attempts.length);
        }
        var success = false;
        var lastFailureType = 'unknown';
        for (var i = 0; i < attempts.length; i++) {
          var failureType = 'unknown';
          success = await _performBackgroundDownload(
            attempts[i],
            selectedType,
            skipFailurePrompt: canCanvasFallback || i < attempts.length - 1,
            inactivityTimeout:
                selectedType == MediaType.image
                    ? const Duration(seconds: 45)
                    : const Duration(minutes: 2),
            maxRequestAttempts: 4,
            showSuccessPrompt: !isSmartGesture,
            showDuplicatePrompt: !isSmartGesture,
            validateSmartMedia: isSmartGesture,
            isSmartBatchMedia: isSmartGesture,
            smartTask: isSmartGesture ? _smartDownloadTask : null,
            smartMediaTitle: (data['title'] ?? '').toString(),
            smartPageUrl: messagePageUrl,
            onFailureType: (type) => failureType = type,
          );
          lastFailureType = failureType;
          if (success) break;
          if (failureType == 'library_save_failed' ||
              failureType == 'already_in_library' ||
              failureType == 'cancelled') {
            break;
          }
        }
        if (success) {
          _notifyMediaDownloadSaved();
          if (isSmartGesture) {
            await _completeSmartGestureDownload(true);
          }
        } else if (!success &&
            canCanvasFallback &&
            lastFailureType != 'already_in_library' &&
            lastFailureType != 'cancelled' &&
            mounted) {
          try {
            final ctrl = _controller;
            if (ctrl != null) {
              _awaitingCanvasFallbackResult = true;
              _canvasFallbackSucceeded = false;
              _canvasFallbackCompleter = Completer<bool>();
              await ctrl.evaluateJavascript(
                source:
                    'typeof tryCanvasCaptureFallback === "function" && tryCanvasCaptureFallback();',
              );
              final canvasSucceeded = await _canvasFallbackCompleter!.future
                  .timeout(
                    const Duration(seconds: 5),
                    onTimeout: () {
                      if (!_canvasFallbackCompleter!.isCompleted) {
                        _canvasFallbackCompleter!.complete(false);
                      }
                      return false;
                    },
                  );
              var recovered = canvasSucceeded;
              if (!canvasSucceeded && selectedType == MediaType.image) {
                recovered = await _tryScreenshotFallback(ctrl) || recovered;
              }
              _awaitingCanvasFallbackResult = false;
              _canvasFallbackCompleter = null;
              // canvas 成功仅表示已取得像素/base64，真正落盘在 _handleBlobUrl；此处不 _notify，避免与失败提示打架
              // 极晚到的 base64 仍可能随后触发 _handleBlobUrl 并成功，故用短延迟再提示失败，避免与成功条打架。
              if (!recovered &&
                  canCanvasFallback &&
                  !_mediaDownloadSaveResolved &&
                  mounted) {
                if (!isSmartGesture) {
                  _mediaDownloadFailHintTimer?.cancel();
                  _mediaDownloadFailHintTimer = Timer(
                    const Duration(seconds: 2),
                    () {
                      if (!mounted || _mediaDownloadSaveResolved) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            _downloadErrorForUser(
                              Exception('[下载失败] 无法保存该媒体，请稍后重试或长按图片本身'),
                            ),
                          ),
                          duration: _kMediaSaveSnackDuration,
                        ),
                      );
                    },
                  );
                }
              }
              if (isSmartGesture) {
                final task = _smartDownloadTask;
                if (task != null &&
                    !_mediaDownloadSaveResolved &&
                    (task['lastGestureFailureType'] ?? '').toString().isEmpty) {
                  task['lastGestureFailureType'] =
                      recovered
                          ? 'invalid_smart_media_content'
                          : lastFailureType;
                }
                await _completeSmartGestureDownload(_mediaDownloadSaveResolved);
              }
            }
          } catch (_) {
            _awaitingCanvasFallbackResult = false;
            _canvasFallbackCompleter = null;
            if (canCanvasFallback && !_mediaDownloadSaveResolved && mounted) {
              if (isSmartGesture) {
                final task = _smartDownloadTask;
                if (task != null) {
                  task['lastGestureFailureType'] = lastFailureType;
                }
                await _completeSmartGestureDownload(false);
              } else {
                _mediaDownloadFailHintTimer?.cancel();
                _mediaDownloadFailHintTimer = Timer(
                  const Duration(seconds: 2),
                  () {
                    if (!mounted || _mediaDownloadSaveResolved) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          _downloadErrorForUser(Exception('[下载失败] 无法保存该媒体')),
                        ),
                        duration: _kMediaSaveSnackDuration,
                      ),
                    );
                  },
                );
              }
            }
          }
        } else if (isSmartGesture) {
          final task = _smartDownloadTask;
          if (task != null) {
            task['lastGestureFailureType'] = lastFailureType;
          }
          await _completeSmartGestureDownload(false);
        }
      } finally {
        if (didRegisterMediaUrl || isStreamReference) {
          _processedMediaUrlsSince.remove(urlValue);
          _releaseJsProcessedUrl(urlValue);
        }
      }
    } catch (e, stackTrace) {
      debugPrint('Error handling JavaScript message: $e');
      debugPrint('Trace: $stackTrace');
      final task = _smartDownloadTask;
      if (task != null && task['gestureDownloadPending'] == true) {
        task['lastGestureFailureType'] = 'handler_exception';
        await _completeSmartGestureDownload(false);
      }
    }
  }

  Future<void> _handleBlobUrl(
    String base64Data,
    String mediaType, {
    String? sourceMimeType,
  }) async {
    File? outputFile;
    try {
      debugPrint('处理Base64数据以直接保存: $mediaType');
      String raw = base64Data.trim();
      String dataUrlMime = '';
      if (raw.startsWith('data:')) {
        final base64Idx = raw.indexOf(';base64,');
        if (base64Idx >= 0) {
          dataUrlMime = raw.substring(5, base64Idx).split(';').first.trim();
          raw = raw.substring(base64Idx + 8);
        } else {
          final commaIdx = raw.indexOf(',');
          if (commaIdx < 0 || commaIdx >= raw.length - 1) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Base64数据格式错误：data URL缺少有效内容')),
              );
            return;
          }
          dataUrlMime = raw.substring(5, commaIdx).split(';').first.trim();
          raw = raw.substring(commaIdx + 1);
        }
      }
      raw = raw.replaceAll(RegExp(r'[\s\r\n]'), '');
      if (raw.isEmpty || raw.length < 10) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Base64数据为空或过短')));
        return;
      }
      List<int> bytes;
      try {
        bytes = base64Decode(raw);
      } catch (_) {
        try {
          bytes = base64Url.decode(raw);
        } catch (e2) {
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Base64解码失败: $e2')));
          return;
        }
      }
      final effectiveMime =
          (sourceMimeType != null && sourceMimeType.trim().isNotEmpty)
              ? sourceMimeType.trim()
              : dataUrlMime;
      final normalizedMediaType = mediaType.toLowerCase().trim();
      String? detectedExtension;
      if (normalizedMediaType == 'video') {
        if (bytes.length < _kMinBase64VideoBytes) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('视频数据不完整，未保存到媒体库'),
                duration: _kMediaSaveSnackDuration,
              ),
            );
          }
          return;
        }
        detectedExtension = _detectVideoExtension(bytes);
        if (detectedExtension == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('保存的内容不是有效视频，未保存到媒体库'),
                duration: _kMediaSaveSnackDuration,
              ),
            );
          }
          return;
        }
      } else if (normalizedMediaType == 'image') {
        detectedExtension = _detectImageExtension(bytes);
        if (detectedExtension == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('保存的内容不是有效图片，未保存到媒体库'),
                duration: _kMediaSaveSnackDuration,
              ),
            );
          }
          return;
        }
      }
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      String extension = _extensionForBase64Media(
        normalizedMediaType,
        effectiveMime,
      );
      extension = detectedExtension ?? extension;
      final filePath = '${mediaDir.path}/$uuid$extension';
      final file = File(filePath);
      outputFile = file;
      await file.writeAsBytes(bytes);
      debugPrint('已从Base64保存文件: $filePath');
      if (normalizedMediaType == 'video') {
        final durationMs = await _probeNativeVideoDurationMs(file);
        if (durationMs != null && durationMs <= 0) {
          await file.delete();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('网页录制的视频缺少有效时长，已放弃保存；请播放视频后重新长按下载'),
                duration: Duration(seconds: 3),
              ),
            );
          }
          return;
        }
      }
      await _saveToMediaLibrary(
        file,
        normalizedMediaType == 'image'
            ? MediaType.image
            : (normalizedMediaType == 'audio'
                ? MediaType.audio
                : MediaType.video),
      );
      _notifyMediaDownloadSaved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存到媒体库：${file.path.split('/').last}'),
            duration: _kMediaSaveSnackDuration,
            action: SnackBarAction(
              label: '查看',
              onPressed:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (context) =>
                              const MediaManagerPage(showRouteBackButton: true),
                    ),
                  ),
            ),
          ),
        );
      }
    } on _ExistingMediaDuplicateException catch (e) {
      try {
        if (outputFile != null && await outputFile.exists()) {
          await outputFile.delete();
        }
      } catch (_) {}
      await _showMediaDuplicateDialog(e.existingRow);
    } catch (e, stackTrace) {
      debugPrint('处理Base64数据时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败: $e'),
            duration: _kMediaSaveSnackDuration,
          ),
        );
      }
    }
  }

  void _loadUrl(String url) {
    String processedUrl = url;
    if (!url.startsWith('http://') && !url.startsWith('https://'))
      processedUrl = 'https://$url';
    final uri = Uri.tryParse(processedUrl);
    if (uri != null) {
      _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(processedUrl)));
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无效的URL: $processedUrl')));
      }
      return;
    }
    setState(() {
      _showHomePage = false;
      _currentUrl = processedUrl;
      _urlController.text = processedUrl;
      _isBrowsingWebPage = true;
      _shouldKeepWebPageState = true;
      _lastBrowsedUrl = processedUrl;
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  bool _isWithinSmartDownloadSite(String url) {
    final task = _smartDownloadTask;
    if (task == null) return true;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return true;
    }
    final targetHost = uri.host.toLowerCase().replaceFirst(
      RegExp(r'^www\.'),
      '',
    );
    final siteHost = (task['host'] ?? '').toString().toLowerCase();
    if (targetHost.isEmpty || siteHost.isEmpty) return false;
    return targetHost == siteHost || targetHost.endsWith('.$siteHost');
  }

  Future<void> _goToHomePage() async {
    if (!_showHomePage) {
      await _saveCommonWebsites();
      await _loadBookmarks();

      // 确保常用网站列表被正确加载
      await _loadCommonWebsites();

      // 如果常用网站列表为空，强制加载默认网站
      if (_commonWebsites.isEmpty) {
        debugPrint('常用网站列表为空，加载默认网站');
        setState(() {
          _commonWebsites.addAll([
            {
              'name': 'Google',
              'url': 'https://www.google.com',
              'iconCode': Icons.public.codePoint,
            },
            {
              'name': 'Edge',
              'url': 'https://www.bing.com',
              'iconCode': Icons.public.codePoint,
            },
            {
              'name': 'X',
              'url': 'https://twitter.com',
              'iconCode': Icons.public.codePoint,
            },
            {
              'name': 'Facebook',
              'url': 'https://www.facebook.com',
              'iconCode': Icons.public.codePoint,
            },
            {
              'name': '百度',
              'url': 'https://www.baidu.com',
              'iconCode': Icons.public.codePoint,
            },
          ]);
        });
        await _saveCommonWebsites();
      }

      setState(() => _showHomePage = true);
      widget.onBrowserHomePageChanged?.call(_showHomePage);
    }
  }

  bool _isBlankHistoryUrl(String? u) {
    if (u == null || u.trim().isEmpty) return true;
    final s = u.trim().toLowerCase();
    return s == 'about:blank' ||
        s.startsWith('about:blank#') ||
        s == 'about://blank' ||
        s.startsWith('about:srcdoc');
  }

  Future<void> _performWebGoBack() async {
    final c = _controller;
    if (c == null || _showHomePage) return;
    if (!await c.canGoBack()) {
      await _goToHomePage();
      return;
    }
    await c.goBack();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    for (var i = 0; i < 28; i++) {
      final u = (await c.getUrl())?.toString() ?? '';
      if (!_isBlankHistoryUrl(u)) return;
      if (!await c.canGoBack()) {
        await _goToHomePage();
        return;
      }
      await c.goBack();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    final last = (await c.getUrl())?.toString() ?? '';
    if (_isBlankHistoryUrl(last)) await _goToHomePage();
  }

  Future<void> _performWebGoForward() async {
    final c = _controller;
    if (c == null || _showHomePage) return;
    if (!await c.canGoForward()) return;
    await c.goForward();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    for (var i = 0; i < 28; i++) {
      final u = (await c.getUrl())?.toString() ?? '';
      if (!_isBlankHistoryUrl(u)) return;
      if (!await c.canGoForward()) return;
      await c.goForward();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  void _restoreWebPage() {
    if (_showHomePage && _isBrowsingWebPage && _shouldKeepWebPageState) {
      setState(() => _showHomePage = false);
      widget.onBrowserHomePageChanged?.call(_showHomePage);
    }
  }

  void _exitWebPage() {
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
    setState(() {
      _showHomePage = true;
      _isBrowsingWebPage = false;
      _shouldKeepWebPageState = false;
      _lastBrowsedUrl = null;
      _currentUrl = 'https://www.baidu.com';
      _urlController.text = _currentUrl;
    });
    widget.onBrowserHomePageChanged?.call(_showHomePage);
  }

  Widget _buildHomePage() {
    // 确保_commonWebsites不为空
    if (_commonWebsites.isEmpty) {
      debugPrint('构建主页时发现常用网站列表为空，加载默认网站');
      _loadCommonWebsites();
    }

    final bottomSafeInset = MediaQuery.of(context).padding.bottom;
    return Stack(
      children: [
        Column(
          children: [
            // 移除了顶部工具栏
            Expanded(
              child: ReorderableGridView.builder(
                padding: EdgeInsets.fromLTRB(
                  16.0,
                  16.0,
                  16.0,
                  16.0 + bottomSafeInset + 8.0,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.0,
                  crossAxisSpacing: 16.0,
                  mainAxisSpacing: 16.0,
                ),
                itemCount: _commonWebsites.length + 1, // +1 for the add button
                itemBuilder: (context, index) {
                  if (index == _commonWebsites.length) {
                    // 添加新网站的按钮
                    return InkWell(
                      key: const ValueKey('add_website'),
                      onTap: () => _showAddWebsiteDialog(context),
                      child: Card(
                        elevation: 4.0,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(
                              Icons.add_circle_outline,
                              size: 40,
                              color: Colors.green,
                            ),
                            SizedBox(height: 8),
                            Text(
                              '添加网站',
                              style: TextStyle(fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );
                  } else {
                    return _buildWebsiteCard(_commonWebsites[index], index);
                  }
                },
                onReorder: _reorderWebsites,
                dragStartBehavior: DragStartBehavior.start,
                // 移除 dragEnabled 函数参数，改为在 _reorderWebsites 方法中处理
                // 移除 onReorderStart 参数，因为 ReorderableGridView 不支持此参数
              ),
            ),
          ],
        ),
        // 移除底部浮动按钮，改为在顶部显示
      ],
    );
  }

  void _showAddWebsiteDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    // 设置默认URL（如果在浏览网页，则使用当前URL）
    if (!_showHomePage && _isBrowsingWebPage) {
      urlController.text = _currentUrl;
    }

    // 先显示对话框，然后异步获取标题
    showDialog(
      context: context,
      builder: (dialogContext) {
        // 如果在浏览网页，异步获取网页标题
        if (!_showHomePage && _isBrowsingWebPage) {
          // 显示"获取中..."作为临时标题
          nameController.text = "获取中...";

          // 异步获取网页标题
          _controller
              ?.getTitle()
              .then((title) {
                if (title != null &&
                    title.isNotEmpty &&
                    nameController.text == "获取中...") {
                  // 直接更新文本控制器，而不使用setState
                  nameController.text = title;
                  // 自动选中文本，方便用户编辑
                  nameController.selection = TextSelection(
                    baseOffset: 0,
                    extentOffset: title.length,
                  );
                }
              })
              .catchError((error) {
                debugPrint('获取网页标题出错: $error');
                if (nameController.text == "获取中...") {
                  nameController.text = "";
                }
              });
        }

        return AlertDialog(
          title: const Text('添加网站到标签'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '网站名称',
                  hintText: '输入自定义名称',
                  helperText: '为网站设置一个简短易记的名称',
                ),
                autofocus: true,
              ),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '网站地址',
                  hintText: '例如：https://www.google.com',
                ),
                enabled: !_isBrowsingWebPage, // 如果在浏览网页，则禁用URL输入框
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty &&
                    urlController.text.isNotEmpty &&
                    nameController.text != "获取中...") {
                  // 创建一个变量存储加载对话框的context
                  BuildContext? loadingDialogContext;

                  // 显示加载对话框并保存context
                  showDialog(
                    context: dialogContext,
                    barrierDismissible: false,
                    builder: (context) {
                      loadingDialogContext = context;
                      return const AlertDialog(
                        content: Row(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(width: 20),
                            Text('添加中...'),
                          ],
                        ),
                      );
                    },
                  );

                  await _addWebsite(
                    nameController.text,
                    urlController.text,
                    Icons.web,
                  );
                  await _saveCommonWebsites();

                  // 安全地关闭加载对话框
                  if (loadingDialogContext != null &&
                      Navigator.canPop(loadingDialogContext!)) {
                    Navigator.pop(loadingDialogContext!);
                  }

                  // 关闭主对话框
                  Navigator.of(dialogContext).pop();
                } else if (nameController.text == "获取中...") {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('请等待网页标题获取完成，或输入自定义名称'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('请输入网站名称和地址'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }

  // 移除_buildEditableWebsiteItem方法，因为我们已经移除了编辑模式

  void _showRenameWebsiteDialog(
    BuildContext context,
    Map<String, dynamic> website,
    int index,
  ) {
    final nameController = TextEditingController(text: website['name']);
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('重命名网站'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '网站名称',
                    hintText: '输入新的网站名称',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                Text(
                  '当前URL: ${website['url']}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  if (nameController.text.isNotEmpty &&
                      nameController.text != website['name']) {
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder:
                          (context) => const AlertDialog(
                            content: Row(
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(width: 20),
                                Text('保存中...'),
                              ],
                            ),
                          ),
                    );
                    setState(
                      () =>
                          _commonWebsites[index]['name'] = nameController.text,
                    );
                    await _saveCommonWebsites();
                    Navigator.of(context).pop();
                    Navigator.of(context).pop();
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
    );
  }

  Future<void> _loadSmartKeywordHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final values = prefs.getStringList(_kSmartKeywordHistoryKey) ?? const [];
    _smartKeywordHistory
      ..clear()
      ..addAll(values.where((value) => value.trim().isNotEmpty).take(30));
  }

  Future<void> _rememberSmartKeyword(String keyword) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return;
    _smartKeywordHistory.removeWhere(
      (value) => value.toLowerCase() == normalized.toLowerCase(),
    );
    _smartKeywordHistory.insert(0, normalized);
    if (_smartKeywordHistory.length > 30) {
      _smartKeywordHistory.removeRange(30, _smartKeywordHistory.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSmartKeywordHistoryKey, _smartKeywordHistory);
  }

  Future<void> _removeSmartKeyword(String keyword) async {
    _smartKeywordHistory.removeWhere(
      (value) => value.toLowerCase() == keyword.trim().toLowerCase(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSmartKeywordHistoryKey, _smartKeywordHistory);
  }

  Future<void> _loadSmartDownload24hRegistry() async {
    if (_smartDownload24hRegistryLoaded) return;
    final pending = _smartDownloadRegistryLoadFuture;
    if (pending != null) return pending;
    final future = () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSmartDownload24hRegistryKey);
      final cutoff = DateTime.now().subtract(const Duration(hours: 24));
      final rows = <Map<String, dynamic>>[];
      if (raw != null && raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final value in decoded.whereType<Map>()) {
              final row = Map<String, dynamic>.from(value);
              final savedAt = DateTime.tryParse(
                (row['savedAt'] ?? '').toString(),
              );
              if (savedAt != null && savedAt.isAfter(cutoff)) rows.add(row);
            }
          }
        } catch (e) {
          debugPrint('加载智能下载 24 小时备案失败: $e');
        }
      }
      rows.sort(
        (a, b) => (b['savedAt'] ?? '').toString().compareTo(
          (a['savedAt'] ?? '').toString(),
        ),
      );
      _smartDownload24hRegistry
        ..clear()
        ..addAll(rows.take(3000));
      _smartDownload24hRegistryLoaded = true;
      await prefs.setString(
        _kSmartDownload24hRegistryKey,
        jsonEncode(_smartDownload24hRegistry),
      );
    }();
    _smartDownloadRegistryLoadFuture = future;
    await future;
  }

  Future<void> _recordSmartDownload24h({
    required Map<String, dynamic> task,
    required String mediaUrl,
    required String title,
    required String pageUrl,
    required String fileHash,
    required int fileSize,
  }) async {
    await _loadSmartDownload24hRegistry();
    final siteHost = (task['host'] ?? '').toString().toLowerCase();
    if (siteHost.isEmpty) return;
    final nameKey = _smartMediaNameKey(
      mediaUrl,
      title: title,
      pageUrl: pageUrl,
    );
    final titleKey = _smartMediaTitleKey(title);
    final sourceKey = _normalizeVideoSourceUrl(mediaUrl);
    final pageKey = _smartStablePageKey(pageUrl);
    final allowTitleIdentity = !_isElementBoundFeedPage(pageUrl);
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 24));
    _smartDownload24hRegistry.removeWhere((row) {
      final savedAt = DateTime.tryParse((row['savedAt'] ?? '').toString());
      return savedAt == null || savedAt.isBefore(cutoff);
    });
    _smartDownload24hRegistry.removeWhere(
      (row) =>
          (row['siteHost'] ?? '').toString() == siteHost &&
          ((nameKey.isNotEmpty &&
                  (row['nameKey'] ?? '').toString() == nameKey) ||
              (allowTitleIdentity &&
                  titleKey.isNotEmpty &&
                  (row['titleKey'] ?? '').toString() == titleKey) ||
              (sourceKey.isNotEmpty &&
                  (row['sourceKey'] ?? '').toString() == sourceKey) ||
              (pageKey.isNotEmpty &&
                  (row['pageKey'] ?? '').toString() == pageKey) ||
              (fileHash.isNotEmpty &&
                  (row['fileHash'] ?? '').toString() == fileHash)),
    );
    _smartDownload24hRegistry.insert(0, <String, dynamic>{
      'siteHost': siteHost,
      'nameKey': nameKey,
      'titleKey': titleKey,
      'sourceKey': sourceKey,
      'pageKey': pageKey,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'savedAt': now.toIso8601String(),
    });
    if (_smartDownload24hRegistry.length > 3000) {
      _smartDownload24hRegistry.removeRange(
        3000,
        _smartDownload24hRegistry.length,
      );
    }
    final snapshot = jsonEncode(_smartDownload24hRegistry);
    _smartDownloadRegistryWrite = _smartDownloadRegistryWrite.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSmartDownload24hRegistryKey, snapshot);
    });
    await _smartDownloadRegistryWrite;
  }

  Future<void> _loadSmartStrategyProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSmartStrategyProfilesKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _smartStrategyProfiles
        ..clear()
        ..addAll(
          decoded.map(
            (key, value) => MapEntry(
              key.toString(),
              value is Map
                  ? Map<String, dynamic>.from(value)
                  : <String, dynamic>{},
            ),
          ),
        );
    } catch (e) {
      debugPrint('加载智能下载策略画像失败: $e');
    }
  }

  String _smartStrategyKey(Map<String, dynamic> task, String strategy) {
    return '${(task['host'] ?? '').toString().toLowerCase()}|$strategy';
  }

  bool _smartStrategyCircuitOpen(Map<String, dynamic> task, String strategy) {
    final taskStats = task['strategyStats'] as Map<String, dynamic>;
    final local = taskStats[strategy] as Map<String, dynamic>?;
    final localFailures = (local?['consecutiveFailures'] as int?) ?? 0;
    if (strategy == 'click_media_card') {
      final target = (task['target'] as int?) ?? 1;
      return localFailures >= max(12, target * 3);
    }
    if (strategy == 'exploratory_click') {
      return localFailures >= 8;
    }
    if (localFailures >= 3) return true;
    final global = _smartStrategyProfiles[_smartStrategyKey(task, strategy)];
    if (((global?['consecutiveFailures'] as int?) ?? 0) < 5) return false;
    final failedAt = DateTime.tryParse(
      (global?['lastFailureAt'] ?? '').toString(),
    );
    return failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(hours: 6);
  }

  void _recordSmartStrategyOutcome(
    Map<String, dynamic> task,
    String strategy, {
    required bool success,
    int elapsedMs = 0,
  }) {
    if (!identical(_smartDownloadTask, task)) return;
    final now = DateTime.now().toIso8601String();
    final taskStats = task['strategyStats'] as Map<String, dynamic>;
    final local = Map<String, dynamic>.from(
      taskStats[strategy] as Map? ?? const <String, dynamic>{},
    );
    final globalKey = _smartStrategyKey(task, strategy);
    final global = Map<String, dynamic>.from(
      _smartStrategyProfiles[globalKey] ?? const <String, dynamic>{},
    );
    for (final row in <Map<String, dynamic>>[local, global]) {
      row[success ? 'successes' : 'failures'] =
          ((row[success ? 'successes' : 'failures'] as int?) ?? 0) + 1;
      row['consecutiveFailures'] =
          success ? 0 : ((row['consecutiveFailures'] as int?) ?? 0) + 1;
      row[success ? 'lastSuccessAt' : 'lastFailureAt'] = now;
      if (elapsedMs > 0) {
        final previous = (row['averageElapsedMs'] as num?)?.toDouble() ?? 0;
        row['averageElapsedMs'] =
            previous <= 0
                ? elapsedMs
                : (previous * 0.7 + elapsedMs * 0.3).round();
      }
    }
    taskStats[strategy] = local;
    _smartStrategyProfiles[globalKey] = global;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _kSmartStrategyProfilesKey,
          jsonEncode(_smartStrategyProfiles),
        );
      } catch (e) {
        debugPrint('保存智能下载策略画像失败: $e');
      }
    }());
  }

  Future<void> _showCurrentMediaSmartDownload() async {
    if (_showHomePage || _controller == null) return;
    var mediaType = MediaType.video;
    var currentVideoUrls = <String>[];
    var currentVideoDuration = 0.0;
    var currentMediaPageUrl = _currentUrl;
    try {
      final result = await _controller!.evaluateJavascript(
        source: '''
          (() => {
            const visible = el => {
              const r = el.getBoundingClientRect();
              return r.width > 100 && r.height > 80 && r.bottom > 0 && r.top < innerHeight;
            };
            const videos = Array.from(document.querySelectorAll('video')).filter(visible);
            const images = Array.from(document.querySelectorAll('img')).filter(visible)
              .filter(img => (img.naturalWidth || img.width) >= 200 && (img.naturalHeight || img.height) >= 160);
            const centerDistance = el => {
              const r = el.getBoundingClientRect();
              const dx = (r.left + r.width / 2) - innerWidth / 2;
              const dy = (r.top + r.height / 2) - innerHeight / 2;
              return Math.abs(dy) + Math.abs(dx) * 0.25;
            };
            const nearestCenter = list => list.sort((a,b) =>
              centerDistance(a) - centerDistance(b))[0];
            const playingVideos = videos.filter(v => !v.paused && !v.ended && v.readyState >= 2);
            const rawHost = location.hostname.toLowerCase();
            const host = rawHost.startsWith('www.') ? rawHost.slice(4) : rawHost;
            const isXPlatform = host === 'x.com' || host.endsWith('.x.com') ||
              host === 'twitter.com' || host.endsWith('.twitter.com');
            const media = nearestCenter(playingVideos) ||
              (isXPlatform ? nearestCenter(videos) : nearestCenter(images)) ||
              (isXPlatform ? nearestCenter(images) : nearestCenter(videos));
            document.querySelectorAll(
              '[data-smart-seed-media], [data-smart-seed-scope], '
              + '[data-app-smart-x-active], [data-app-smart-x-visited]'
            )
              .forEach(el => {
                el.removeAttribute('data-smart-seed-media');
                el.removeAttribute('data-smart-seed-scope');
                el.removeAttribute('data-app-smart-x-active');
                el.removeAttribute('data-app-smart-x-visited');
              });
            if (media) {
              media.setAttribute('data-smart-seed-media', '1');
              let scope = isXPlatform
                ? (media.closest('article[data-testid="tweet"], article') || media.parentElement)
                : media.parentElement;
              while (!isXPlatform && scope && scope !== document.body) {
                const count = scope.querySelectorAll('video, img').length;
                const scopeHint = String(scope.id || '') + ' ' + String(scope.className || '');
                if (count >= 2 &&
                    /(user|profile|gallery|album|folder|category|channel|feed|list|grid|items|posts)/i.test(scopeHint)) break;
                scope = scope.parentElement;
              }
              if ((!isXPlatform && !scope) || scope === document.body) {
                scope = media.closest('main, section, article, [role="feed"]') || media.parentElement;
              }
              if (scope) scope.setAttribute('data-smart-seed-scope', '1');
              if (isXPlatform && scope) {
                scope.setAttribute('data-app-smart-x-active', '1');
              }
            }
            const type = media && media.tagName === 'IMG' ? 'image' : 'video';
            const mediaUrls = type === 'video' ? [
              media.currentSrc,
              media.src,
              ...Array.from(media.querySelectorAll('source')).map(source => source.src)
            ].filter(Boolean) : [];
            const nearby = media && media.closest('article, figure, [class*="card"], [class*="item"]');
            const statusUrl = isXPlatform && nearby
              ? (Array.from(nearby.querySelectorAll('a[href*="/status/"]'))
                  .map(link => link.href || '').find(href => String(href).includes('/status/')) || '')
              : '';
            const values = [
              media && (media.getAttribute('alt') || media.getAttribute('title') || media.getAttribute('aria-label')),
              media && media.parentElement && media.parentElement.getAttribute('title'),
              nearby && nearby.querySelector('figcaption, h1, h2, h3, [class*="title"], [class*="caption"], [class*="tag"]')?.textContent,
              nearby && nearby.innerText,
              document.querySelector('meta[property="og:title"]')?.content,
              document.querySelector('meta[property="og:description"]')?.content,
              document.title
            ];
            const stripUrls = value => {
              const parts = [];
              let token = '';
              const flush = () => {
                if (!token) return;
                const lower = token.toLowerCase();
                if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
                  parts.push(token);
                }
                token = '';
              };
              for (const char of String(value || '')) {
                if (char.charCodeAt(0) <= 32) {
                  flush();
                } else {
                  token += char;
                }
              }
              flush();
              return parts.join(' ').trim();
            };
            const cleaned = values.map(stripUrls).filter(v => {
                const rawLower = v.toLowerCase();
                const lower = rawLower.startsWith('www.') ? rawLower.slice(4) : rawLower;
                return v.length >= 2 && lower !== host && lower !== location.hostname.toLowerCase();
              });
            return {
              type,
              keyword: (cleaned[0] || '').slice(0, 80),
              mediaUrls: Array.from(new Set(mediaUrls)),
              sourcePageUrl: statusUrl || location.href,
              duration: type === 'video' && Number.isFinite(media.duration)
                ? media.duration
                : 0
            };
          })()
        ''',
      );
      if (result is Map) {
        mediaType =
            result['type']?.toString() == 'image'
                ? MediaType.image
                : MediaType.video;
        final rawUrls = result['mediaUrls'];
        if (rawUrls is List) {
          currentVideoUrls = rawUrls.map((value) => value.toString()).toList();
        }
        currentVideoDuration = (result['duration'] as num?)?.toDouble() ?? 0.0;
        currentMediaPageUrl =
            (result['sourcePageUrl'] ?? _currentUrl).toString().trim();
      }
    } catch (e) {
      debugPrint('提取当前媒体关键词失败: $e');
    }
    await _showSmartDownloadDialog(
      <String, dynamic>{
        'name': '当前媒体',
        'url':
            currentMediaPageUrl.isNotEmpty ? currentMediaPageUrl : _currentUrl,
      },
      initialKeyword: '',
      initialMediaType: mediaType,
      startFromCurrentPage: true,
      initialVideoUrls: currentVideoUrls,
      initialVideoDuration: currentVideoDuration,
    );
  }

  Future<int?> _estimateSmartSeedVideoBytes(
    List<String> rawUrls,
    String pageUrl,
    double durationSec,
  ) async {
    final networkService = NetworkService();
    await networkService.initialize();
    for (final rawUrl in rawUrls) {
      final url = _toAbsoluteUrl(rawUrl.trim());
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        continue;
      }
      try {
        final cookie = await _browserCookieHeaderForUrl(url);
        final headers = <String, String>{
          'User-Agent': _kBrowserMediaUserAgent,
          'Referer': pageUrl,
          if (cookie.isNotEmpty) 'Cookie': cookie,
        };
        final path = uri.path.toLowerCase();
        if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
          final response = await networkService.dio.get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: true,
              maxRedirects: 5,
              sendTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
              validateStatus:
                  (code) => code != null && code >= 200 && code < 400,
              headers: headers,
            ),
          );
          final manifest = response.data ?? '';
          final bandwidths = RegExp(
            r'''(?:BANDWIDTH|bandwidth)\s*=\s*["']?(\d+)''',
          ).allMatches(manifest).map((match) => int.parse(match.group(1)!));
          final maxBandwidth = bandwidths.fold<int>(0, max);
          var knownDuration = durationSec;
          if (knownDuration <= 0 && path.endsWith('.m3u8')) {
            knownDuration = RegExp(r'#EXTINF:([\d.]+)')
                .allMatches(manifest)
                .fold<double>(
                  0,
                  (sum, match) => sum + (double.tryParse(match.group(1)!) ?? 0),
                );
          }
          if (maxBandwidth > 0 && knownDuration > 0) {
            return (maxBandwidth * knownDuration / 8).round();
          }
          continue;
        }
        final head = await networkService.dio.head<dynamic>(
          url,
          options: Options(
            followRedirects: true,
            maxRedirects: 5,
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            validateStatus: (code) => code != null && code >= 200 && code < 400,
            headers: headers,
          ),
        );
        final contentLength = int.tryParse(
          (head.headers.value('content-length') ?? '').trim(),
        );
        if (contentLength != null && contentLength > 0) return contentLength;

        final range = await networkService.dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
            maxRedirects: 5,
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
            validateStatus: (code) => code == 206,
            headers: {...headers, 'Range': 'bytes=0-0'},
          ),
        );
        final contentRange = range.headers.value('content-range') ?? '';
        final total = int.tryParse(contentRange.split('/').last.trim());
        if (total != null && total > 0) return total;
      } catch (e) {
        debugPrint('当前视频大小自动探测失败（尝试下一地址）: $e');
      }
    }
    return null;
  }

  void _showSmartOperation(
    String label, {
    Offset point = const Offset(0.5, 0.5),
  }) {
    if (!mounted || _smartDownloadTask == null) return;
    final safePoint = Offset(
      point.dx.clamp(0.08, 0.92),
      point.dy.clamp(0.08, 0.92),
    );
    setState(() {
      _smartOperationPoint = safePoint;
      _smartOperationLabel = label;
    });
    _smartDownloadTask!['visibleOperation'] = label;
  }

  Future<void> _refreshMixedSmartMediaType(Map<String, dynamic> task) async {
    if (task['allowMixedMedia'] != true ||
        !identical(_smartDownloadTask, task) ||
        _controller == null) {
      return;
    }
    try {
      final result = await _controller!.evaluateJavascript(
        source: '''
          (() => {
            const visible = el => {
              const r = el.getBoundingClientRect();
              if (r.width < 100 || r.height < 80 ||
                  r.bottom <= 0 || r.top >= innerHeight ||
                  r.right <= 0 || r.left >= innerWidth) return false;
              if (el.tagName !== 'IMG') return true;
              const src = String(el.currentSrc || el.src || '').toLowerCase();
              const width = Math.max(el.naturalWidth || 0, r.width);
              const height = Math.max(el.naturalHeight || 0, r.height);
              return width >= 200 && height >= 160 &&
                !/(avatar|emoji|icon|logo|profile_images|profile_banners)/.test(src);
            };
            const rows = Array.from(document.querySelectorAll('video, img'))
              .filter(visible)
              .map(el => {
                const r = el.getBoundingClientRect();
                const x = r.left + r.width / 2;
                const y = r.top + r.height / 2;
                const distance = Math.abs(y - innerHeight / 2) +
                  Math.abs(x - innerWidth / 2) * 0.25;
                return {el, x, y, distance};
              })
              .sort((a, b) => a.distance - b.distance);
            const selected = rows[0];
            if (!selected) return null;
            return {
              type: selected.el.tagName === 'IMG' ? 'image' : 'video',
              x: innerWidth > 0 ? selected.x / innerWidth : 0.5,
              y: innerHeight > 0 ? selected.y / innerHeight : 0.5
            };
          })()
        ''',
      );
      if (result is! Map || !identical(_smartDownloadTask, task)) return;
      final isImage = result['type']?.toString() == 'image';
      task['mediaType'] = isImage ? MediaType.image : MediaType.video;
      _showSmartOperation(
        isImage ? '已定位中心图片，准备下载' : '已定位中心视频，准备下载',
        point: Offset(
          (result['x'] as num?)?.toDouble() ?? 0.5,
          (result['y'] as num?)?.toDouble() ?? 0.5,
        ),
      );
    } catch (e) {
      debugPrint('智能下载判断中心媒体类型失败: $e');
    }
  }

  bool _isBaiduHost(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    return normalized == 'baidu.com' || normalized.endsWith('.baidu.com');
  }

  String _smartSiteRoot(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final parts =
        normalized.split('.').where((part) => part.isNotEmpty).toList();
    if (parts.length <= 2) return normalized;
    const compoundSuffixes = <String>{
      'com.cn',
      'net.cn',
      'org.cn',
      'com.hk',
      'co.uk',
      'com.au',
      'co.jp',
    };
    final suffix2 = parts.sublist(parts.length - 2).join('.');
    final take = compoundSuffixes.contains(suffix2) ? 3 : 2;
    return parts.sublist(parts.length - take).join('.');
  }

  bool _sameSmartSite(String leftHost, String rightHost) {
    if (leftHost.isEmpty || rightHost.isEmpty) return false;
    return _smartSiteRoot(leftHost) == _smartSiteRoot(rightHost);
  }

  String _smartSiteProfile(String host) {
    final value = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (value == 'x.com' ||
        value.endsWith('.x.com') ||
        value == 'twitter.com' ||
        value.endsWith('.twitter.com')) {
      return 'x';
    }
    if (value == '91cg1.com' || value.endsWith('.91cg1.com')) return '91';
    if (value == 'tik.porn' || value.endsWith('.tik.porn')) return 'tikporn';
    if (value == 'pin.porn' || value.endsWith('.pin.porn')) return 'pinporn';
    if (value.contains('xvideos') ||
        value.contains('xfree') ||
        value.contains('freevideo')) {
      return 'xvideo';
    }
    if (_isBaiduHost(value)) return 'baidu';
    return 'generic';
  }

  String _baiduVideoSearchUrl(String keyword, {int page = 0}) {
    return Uri.https('m.baidu.com', '/s', <String, String>{
      'pd': 'video',
      'sa': 'vs_tab',
      'word': keyword.trim(),
      if (page > 0) 'pn': '${page * 10}',
    }).toString();
  }

  bool _isBaiduVideoResultsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        _isBaiduHost(uri.host) &&
        uri.path == '/s' &&
        uri.queryParameters['pd'] == 'video';
  }

  bool _isUnsafeBaiduSmartPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return true;
    final host = uri.host.toLowerCase();
    final value = url.toLowerCase();
    return !_isBaiduHost(host) ||
        host == 'ufo.baidu.com' ||
        host == 'mysearch.pae.baidu.com' ||
        value.contains('sd_privacy_terms') ||
        value.startsWith('chrome-error://');
  }

  Future<bool> _recoverStrictGesturePage(
    Map<String, dynamic> task,
    String reason, {
    bool nextPage = false,
  }) async {
    if (task['strictBaiduVideoMode'] != true) return false;
    final keyword = (task['keyword'] ?? '').toString().trim();
    if (keyword.isEmpty) return false;

    var page = (task['strictBaiduPage'] as int?) ?? 0;
    if (nextPage) page++;
    task['strictBaiduPage'] = page;
    final searchUrl = _baiduVideoSearchUrl(keyword, page: page);
    task['strictBaiduSearchUrl'] = searchUrl;
    task['gestureMode'] = true;
    task['gestureKeywordSubmitted'] = true;
    task['gestureTypeFilterApplied'] = true;
    task['gestureDetailMode'] = false;
    task['gestureReturnUrl'] = '';
    task['gestureDownloadPending'] = false;
    task['gestureWaitCount'] = 0;
    task['gesturePrepareCount'] = 0;
    task['gestureNoMoveCount'] = 0;
    task['gestureEngineFailures'] = 0;
    task['gestureConsecutiveFailures'] = 0;
    task['phase'] = 'baidu_video_search_loading';
    task['matchStage'] = '百度视频结果页 · $reason';
    debugPrint(
      'Smart Baidu video: recover page=$page reason=$reason url=$searchUrl',
    );
    _showSmartOperation('返回“$keyword”视频结果页，继续按顺序查找');
    _loadUrl(searchUrl);
    return true;
  }

  Future<bool> _recoverVisibleGesturePage(
    Map<String, dynamic> task,
    String reason, {
    bool nextPage = false,
  }) async {
    if (await _recoverStrictGesturePage(task, reason, nextPage: nextPage)) {
      return true;
    }
    if (task['strict91KeywordMode'] == true) {
      final searchUrl = (task['strict91SearchUrl'] ?? '').toString();
      if (searchUrl.isEmpty) return false;
      task['gestureMode'] = false;
      task['gestureDownloadPending'] = false;
      task['gestureEngineFailures'] = 0;
      task['gestureConsecutiveFailures'] = 0;
      task['phase'] = 'collecting_search_results';
      task['matchStage'] = '91 关键词结果页 · 按卡片顺序查找';
      debugPrint(
        'Smart 91 strict: leaving generic gesture recovery '
        'reason=$reason url=$searchUrl',
      );
      _showSmartOperation('识别当前关键词结果卡片，按顺序进入下载');
      if (!_isSame91TaskPage(searchUrl, _currentUrl)) {
        _loadUrl(searchUrl);
      } else {
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
      }
      return true;
    }
    if (task['protectVisibleGestureFlow'] != true) return false;
    if (nextPage && await _returnFromStalledSmartPage(task, reason)) {
      return true;
    }
    if (task['siteProfile'] == 'x' &&
        (task['keyword'] ?? '').toString().trim().isEmpty) {
      task['gestureMode'] = true;
      task['gestureDetailMode'] = false;
      task['gestureReturnUrl'] = '';
      task['gestureDownloadPending'] = false;
      task['gestureEngineFailures'] = 0;
      task['gestureConsecutiveFailures'] = 0;
      task['phase'] = 'scanning_feed';
      task['matchStage'] = 'X 沉浸模式 · 切换下一条媒体';
      debugPrint('Smart X immersive recovery: reason=$reason url=$_currentUrl');
      _continueSmartFeed(task, madeProgress: false);
      return true;
    }

    final taskHost = (task['host'] ?? '').toString();
    final recoveryUrl = <String>[
      (task['gestureReturnUrl'] ?? '').toString(),
      (task['gestureResultUrl'] ?? '').toString(),
      (task['gestureLastSafeUrl'] ?? '').toString(),
      (task['originUrl'] ?? '').toString(),
    ].firstWhere((value) {
      final uri = Uri.tryParse(value);
      return uri != null && uri.hasScheme && _sameSmartSite(uri.host, taskHost);
    }, orElse: () => '');
    if (recoveryUrl.isEmpty) return false;

    final alreadyOnRecoveryPage = _isSameLoadedDocument(
      recoveryUrl,
      _currentUrl,
    );
    if (alreadyOnRecoveryPage && nextPage) return false;
    final recoveryCount = ((task['gestureRecoveryCount'] as int?) ?? 0) + 1;
    if (alreadyOnRecoveryPage && recoveryCount > 3) return false;

    task['gestureRecoveryCount'] = recoveryCount;
    task['gestureMode'] = true;
    task['gestureDetailMode'] = false;
    task['gestureReturnUrl'] = '';
    task['gestureDownloadPending'] = false;
    task['gestureWaitCount'] = 0;
    task['gesturePrepareCount'] = 0;
    task['gestureNoMoveCount'] = 0;
    task['gestureEngineFailures'] = 0;
    task['phase'] = 'gesture_recovering_result';
    task['matchStage'] = '返回媒体结果页 · $reason';
    debugPrint(
      'Smart visible recovery: profile=${task['siteProfile']} '
      'reason=$reason url=$recoveryUrl',
    );
    _showSmartOperation('返回上一层媒体列表，继续查找');
    _loadUrl(recoveryUrl);
    return true;
  }

  Future<String> _readSmartPageMotionSnapshot() async {
    final controller = _controller;
    if (controller == null) return '';
    try {
      final result = await controller.evaluateJavascript(
        source: '''
          (() => {
            const root = document.scrollingElement || document.documentElement;
            const visible = element => {
              const r = element.getBoundingClientRect();
              return r.width > 20 && r.height > 20 &&
                r.bottom > 0 && r.top < innerHeight;
            };
            const scrollables = Array.from(document.querySelectorAll('*'))
              .filter(element => {
                if (!visible(element)) return false;
                const style = getComputedStyle(element);
                return element.scrollHeight > element.clientHeight + 40 &&
                  /(auto|scroll)/.test(style.overflowY);
              })
              .slice(0, 8)
              .map(element => [
                Math.round(element.scrollTop || 0),
                Math.round(element.scrollHeight || 0),
                Math.round(element.clientHeight || 0)
              ].join(':'));
            const media = Array.from(document.querySelectorAll('video, img'))
              .filter(visible)
              .map(element => {
                const r = element.getBoundingClientRect();
                const scope = element.closest(
                  'article, [data-testid="cellInnerDiv"], [role="dialog"]'
                );
                const status = scope?.querySelector('a[href*="/status/"]')?.href || '';
                const source = element.currentSrc || element.src || element.poster || '';
                return [
                  status,
                  String(source).split('?')[0],
                  Math.round(r.top),
                  Math.round(r.height)
                ].join('|');
              })
              .slice(0, 6);
            return JSON.stringify({
              href: location.href,
              rootTop: Math.round(root?.scrollTop || window.scrollY || 0),
              scrollables,
              media
            });
          })()
        ''',
      );
      return result?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<bool> _returnFromStalledSmartPage(
    Map<String, dynamic> task,
    String reason,
  ) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) {
      return false;
    }
    final actualUrl = (await controller.getUrl())?.toString() ?? _currentUrl;
    final taskHost = (task['host'] ?? '').toString();
    final knownReturnUrl = <String>[
      (task['xReturnUrl'] ?? '').toString(),
      (task['gestureReturnUrl'] ?? '').toString(),
      (task['cardListUrl'] ?? '').toString(),
      (task['candidateListUrl'] ?? '').toString(),
      (task['gestureResultUrl'] ?? '').toString(),
      (task['originUrl'] ?? '').toString(),
    ].firstWhere((value) {
      final uri = Uri.tryParse(value);
      return uri != null &&
          uri.hasScheme &&
          _sameSmartSite(uri.host, taskHost) &&
          !_isSameLoadedDocument(value, actualUrl);
    }, orElse: () => '');

    final isXDetail =
        task['siteProfile'] == 'x' &&
        (task['xEnteredDetailFromList'] == true ||
            _isXStatusDetailPage(actualUrl) ||
            _isXMediaViewerPage(actualUrl));
    if (isXDetail && (task['xReturnUrl'] ?? '').toString().startsWith('http')) {
      task['feedStalledCount'] = 0;
      task['gestureNoMoveCount'] = 0;
      task['matchStage'] = '当前详情页无法继续 · 返回原信息流';
      _showSmartOperation('当前页面已经到底，返回上一级继续下载');
      await _returnFromXSmartCard(task);
      return true;
    }

    if (knownReturnUrl.isEmpty && !await controller.canGoBack()) return false;
    task['feedStalledCount'] = 0;
    task['gestureNoMoveCount'] = 0;
    task['phase'] = 'gesture_returning';
    task['matchStage'] = '当前页面无法继续 · 返回上一层';
    _showSmartOperation('连续滑动没有变化，返回上一页继续查找');
    debugPrint(
      'Smart stalled page return: reason=$reason '
      'current=$actualUrl target=$knownReturnUrl',
    );
    if (task['siteProfile'] == 'x' && knownReturnUrl.startsWith('http')) {
      task['phase'] = 'x_search_returning';
      task['xReturnExpectedUrl'] = knownReturnUrl;
      task['xReturnAttempts'] = 0;
      _loadUrl(knownReturnUrl);
      return true;
    }
    if (await controller.canGoBack()) {
      await controller.goBack();
      await Future<void>.delayed(const Duration(milliseconds: 280));
    }
    final afterBack = (await controller.getUrl())?.toString() ?? '';
    final afterHost = Uri.tryParse(afterBack)?.host ?? '';
    if (knownReturnUrl.isNotEmpty &&
        !_isSameLoadedDocument(knownReturnUrl, afterBack)) {
      _loadUrl(knownReturnUrl);
    } else if (afterHost.isNotEmpty && !_sameSmartSite(afterHost, taskHost)) {
      final originUrl = (task['originUrl'] ?? '').toString();
      if (originUrl.startsWith('http')) _loadUrl(originUrl);
    }
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (identical(_smartDownloadTask, task)) {
        unawaited(_advanceSmartDownload(_currentUrl));
      }
    });
    return true;
  }

  Future<bool> _advanceVisibleSmartGesture(Map<String, dynamic> task) async {
    if (!identical(_smartDownloadTask, task) || _controller == null) {
      return false;
    }
    final taskHost = (task['host'] ?? '').toString().toLowerCase();
    final currentHost =
        Uri.tryParse(
          _currentUrl,
        )?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ??
        '';
    final strictBaiduVideoMode = task['strictBaiduVideoMode'] == true;
    if (strictBaiduVideoMode && _isUnsafeBaiduSmartPage(_currentUrl)) {
      return _recoverStrictGesturePage(task, '拦截无关或异常页面');
    }
    final staysOnSite =
        _sameSmartSite(currentHost, taskHost) ||
        (strictBaiduVideoMode && _isBaiduHost(currentHost));
    if (taskHost.isNotEmpty && currentHost.isNotEmpty && !staysOnSite) {
      if (await _recoverVisibleGesturePage(task, '拦截离开当前网站')) {
        return true;
      }
      return false;
    }
    if (!strictBaiduVideoMode || _isBaiduVideoResultsUrl(_currentUrl)) {
      task['gestureLastSafeUrl'] = _currentUrl;
    }
    if (task['gestureDownloadPending'] == true) {
      final hasActiveDownload = _downloadTasks.any(
        (row) =>
            row['isSmartBatchMedia'] == true && row['status'] == 'downloading',
      );
      if (hasActiveDownload) return true;
      final startedAt = task['gestureDownloadStartedAt'] as DateTime?;
      if (startedAt == null ||
          DateTime.now().difference(startedAt) < const Duration(seconds: 20)) {
        return true;
      }
      // A page may swallow synthetic touch events. Release the stalled
      // candidate and continue with the next visible item.
      await _completeSmartGestureDownload(false);
      return true;
    }

    final phase = (task['phase'] ?? '').toString();
    if (task['xInlineActivationPending'] == true) {
      final activatedAt = task['xInlineActivatedAt'] as DateTime?;
      final elapsed =
          activatedAt == null
              ? const Duration(seconds: 3)
              : DateTime.now().difference(activatedAt);
      if (elapsed < const Duration(milliseconds: 2400)) {
        final remaining = const Duration(milliseconds: 2400) - elapsed;
        Future<void>.delayed(remaining, () {
          if (identical(_smartDownloadTask, task) &&
              task['xInlineActivationPending'] == true) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      task['xInlineActivationPending'] = false;
      task['xInlineReadyToLongPress'] = true;
      task['phase'] = 'scanning_feed';
    }
    if (phase == 'gesture_opening_card') {
      final returnUrl = (task['gestureReturnUrl'] ?? '').toString();
      final startedAt = task['gestureActionStartedAt'] as DateTime?;
      final elapsed =
          startedAt == null
              ? const Duration(seconds: 3)
              : DateTime.now().difference(startedAt);
      final navigated =
          returnUrl.startsWith('http') &&
          !_isSameLoadedDocument(returnUrl, _currentUrl);
      if (!navigated && elapsed < const Duration(milliseconds: 2600)) {
        Future<void>.delayed(const Duration(milliseconds: 1300), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'gesture_opening_card') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      // URL changes, same-document modals and SPA route updates are all
      // treated as one detail layer. No second card click is allowed here.
      task['gestureDetailMode'] = true;
      task['phase'] = 'gesture_scanning_detail';
    } else if (phase == 'gesture_returning') {
      task['gestureDetailMode'] = false;
      task['gestureReturnUrl'] = '';
      task['phase'] = 'gesture_scanning_results';
    }
    if (task['gestureDetailMode'] != true &&
        (phase == 'gesture_searching' ||
            phase == 'gesture_filtering_type' ||
            phase == 'gesture_scanning_results' ||
            phase == 'gesture_recovering_result' ||
            phase == 'collecting_search_results' ||
            phase == 'x_search_loading' ||
            phase == 'baidu_video_search_loading') &&
        _currentUrl.startsWith('http')) {
      task['gestureResultUrl'] = _currentUrl;
      task['gestureRecoveryCount'] = 0;
    }

    final keyword = (task['keyword'] ?? '').toString().trim();
    final mediaType = task['mediaType'] as MediaType;
    final allowMixed = task['allowMixedMedia'] == true;
    final attempted = task['gestureAttemptedKeys'] as Set<String>;
    final attemptedJson = jsonEncode(attempted.toList());
    final keywordJson = jsonEncode(keyword.toLowerCase());
    final requestedType =
        allowMixed
            ? 'mixed'
            : mediaType == MediaType.image
            ? 'image'
            : 'video';
    final requestedTypeJson = jsonEncode(requestedType);
    final keywordAlreadySubmitted = task['gestureKeywordSubmitted'] == true;
    final typeFilterApplied = task['gestureTypeFilterApplied'] == true;
    final skipPendingWait = task['gestureSkipPendingWait'] == true;
    final gestureReturnUrl = (task['gestureReturnUrl'] ?? '').toString();
    final hasReturnPage = task['gestureDetailMode'] == true;
    final siteProfileJson = jsonEncode((task['siteProfile'] ?? 'generic'));
    final xInlineFeedMode = task['xInlineFeedMode'] == true;
    final xInlineReadyToLongPress = task['xInlineReadyToLongPress'] == true;

    try {
      final result = await _controller!.evaluateJavascript(
        source: '''
          (() => {
            const keyword = $keywordJson;
            const requestedType = $requestedTypeJson;
            const attempted = new Set($attemptedJson);
            const keywordAlreadySubmitted = $keywordAlreadySubmitted;
            const typeFilterApplied = $typeFilterApplied;
            const skipPendingWait = $skipPendingWait;
            const hasReturnPage = $hasReturnPage;
            const siteProfile = $siteProfileJson;
            const xInlineFeedMode = $xInlineFeedMode;
            const xInlineReadyToLongPress = $xInlineReadyToLongPress;
            const currentSearchInputs = Array.from(document.querySelectorAll(
              'input[type="search"], input[name="q"], input[name="s"], ' +
              'input[name*="search"], input[placeholder*="搜索"], ' +
              'input[placeholder*="关键词"], input[placeholder*="Search" i]'
            ));
            let decodedLocation = String(location.href || '').toLowerCase();
            try { decodedLocation = decodeURIComponent(decodedLocation); } catch (_) {}
            const trustedKeywordResults = !!keyword && (
              keywordAlreadySubmitted ||
              decodedLocation.includes(keyword) ||
              currentSearchInputs.some(input =>
                String(input.value || '').trim().toLowerCase() === keyword
              )
            );
            if (keyword && !keywordAlreadySubmitted) {
              const inputs = currentSearchInputs.filter(input => {
                const r = input.getBoundingClientRect();
                return r.width > 80 && r.height > 20 && r.bottom > 0 &&
                  r.top < innerHeight && !input.disabled;
              });
              const input = inputs[0];
              if (input && String(input.value || '').trim().toLowerCase() !== keyword) {
                input.focus();
                const setter = Object.getOwnPropertyDescriptor(
                  HTMLInputElement.prototype, 'value'
                );
                if (setter && setter.set) setter.set.call(input, keyword);
                else input.value = keyword;
                input.dispatchEvent(new Event('input', {bubbles:true}));
                input.dispatchEvent(new Event('change', {bubbles:true}));
                const form = input.closest('form');
                setTimeout(() => {
                  if (form && typeof form.requestSubmit === 'function') {
                    form.requestSubmit();
                  } else {
                    input.dispatchEvent(new KeyboardEvent('keydown', {
                      key:'Enter', code:'Enter', keyCode:13, which:13,
                      bubbles:true, cancelable:true
                    }));
                    input.dispatchEvent(new KeyboardEvent('keyup', {
                      key:'Enter', code:'Enter', keyCode:13, which:13,
                      bubbles:true, cancelable:true
                    }));
                  }
                }, 120);
                const r = input.getBoundingClientRect();
                return {
                  action:'search', key:'',
                  x:(r.left + r.width / 2) / Math.max(1, innerWidth),
                  y:(r.top + r.height / 2) / Math.max(1, innerHeight)
                };
              }
            }
            const visible = (el) => {
              const r = el.getBoundingClientRect();
              if (r.width < 80 || r.height < 64 ||
                  r.bottom <= 0 || r.top >= innerHeight ||
                  r.right <= 0 || r.left >= innerWidth) return false;
              const style = getComputedStyle(el);
              return style.display !== 'none' && style.visibility !== 'hidden' &&
                Number(style.opacity || 1) > 0.05;
            };
            const mediaKind = (el) => {
              if (el.tagName === 'VIDEO') return 'video';
              if (el.tagName === 'IMG' || el.tagName === 'CANVAS') return 'image';
              const style = String(
                (el.style && el.style.backgroundImage) ||
                getComputedStyle(el).backgroundImage || ''
              );
              const source = String(
                el.getAttribute('data-original') ||
                el.getAttribute('data-src') || ''
              );
              if (style.includes('url(') ||
                  /\\.(jpe?g|png|gif|webp|bmp|avif)(\\?|#|\$)/i.test(source)) {
                return 'image';
              }
              return '';
            };
            const mediaSource = (el) => {
              const direct = String(
                el.getAttribute('data-original') ||
                el.getAttribute('data-src') ||
                el.currentSrc || el.src || el.getAttribute('poster') || ''
              ).trim();
              if (direct) return direct;
              const bg = String(
                (el.style && el.style.backgroundImage) ||
                getComputedStyle(el).backgroundImage || ''
              );
              const match = bg.match(/url\\(['"]?([^'")]+)['"]?\\)/i);
              return match ? match[1] : '';
            };
            const isUsefulMedia = (el) => {
              const kind = mediaKind(el);
              if (!kind) return false;
              const r = el.getBoundingClientRect();
              const source = mediaSource(el).toLowerCase();
              const hint = String(
                (el.className && (el.className.baseVal || el.className)) || ''
              ).toLowerCase() + ' ' +
                String(el.id || '').toLowerCase() + ' ' +
                String(el.alt || '').toLowerCase();
              if (/(avatar|emoji|icon|logo|sprite|badge|qrcode|qr-code|广告|ad[-_])/i
                  .test(source + ' ' + hint)) return false;
              if (kind === 'image') {
                const naturalWidth = Number(el.naturalWidth || el.width || 0);
                const naturalHeight = Number(el.naturalHeight || el.height || 0);
                if (el.tagName === 'IMG' && el.complete &&
                    naturalWidth > 0 && naturalHeight > 0 &&
                    (naturalWidth < 96 || naturalHeight < 72)) return false;
                if (r.width * r.height < 9000) return false;
                if (/^(data:image\\/gif;base64,R0lGODlhAQABA|about:blank)/i.test(source)) {
                  return false;
                }
              }
              return true;
            };
            const bestTouchPoint = (el) => {
              const r = el.getBoundingClientRect();
              const points = [
                [0.5, 0.5], [0.32, 0.5], [0.68, 0.5],
                [0.5, 0.32], [0.5, 0.68]
              ];
              for (const point of points) {
                const x = Math.max(8, Math.min(innerWidth - 8, r.left + r.width * point[0]));
                const y = Math.max(8, Math.min(innerHeight - 8, r.top + r.height * point[1]));
                const stack = document.elementsFromPoint(x, y);
                const hit = stack.find(node =>
                  node === el || el.contains(node) || node.contains(el)
                );
                if (hit) return {x, y, exposed:true};
              }
              return {
                x:Math.max(8, Math.min(innerWidth - 8, r.left + r.width / 2)),
                y:Math.max(8, Math.min(innerHeight - 8, r.top + r.height / 2)),
                exposed:false
              };
            };
            const mediaKey = (el, index) => {
              const src = mediaSource(el);
              if (src) return src;
              const r = el.getBoundingClientRect();
              return location.href + '#smart-' + el.tagName + '-' +
                Math.round(scrollY + r.top) + '-' + Math.round(r.left) + '-' + index;
            };
            const contextText = (el) => {
              const host = el.closest(
                'article, figure, li, [role="article"], [class*="card"], ' +
                '[class*="item"], [class*="post"], [data-testid="tweet"]'
              ) || el.parentElement;
              return String((host && host.innerText) || el.alt || el.title || '')
                .toLowerCase();
            };
            const imageSelector =
              'img, canvas, [style*="background-image"], [data-original], [data-src]';
            const selector = requestedType === 'image' ? imageSelector :
              requestedType === 'video' ? 'video' : 'video, ' + imageSelector;
            const rows = Array.from(document.querySelectorAll(selector))
              .filter(el => visible(el) && isUsefulMedia(el))
              .map((el, index) => {
                const r = el.getBoundingClientRect();
                const key = mediaKey(el, index);
                const point = bestTouchPoint(el);
                const x = point.x;
                const y = point.y;
                const text = contextText(el);
                // Once the site accepted the keyword, every media item on the
                // result page is a candidate. Search engines rarely repeat the
                // query text beside every thumbnail.
                const matches =
                  !keyword || trustedKeywordResults || text.includes(keyword);
                const centerDistance = Math.abs(y - innerHeight / 2) +
                  Math.abs(x - innerWidth / 2) * 0.2;
                const quality =
                  Math.min(r.width * r.height, 1000000) +
                  (point.exposed ? 250000 : -500000) +
                  (el.tagName === 'VIDEO' && !el.paused ? 400000 : 0);
                const activeXSeed = xInlineFeedMode &&
                  (el.matches?.('[data-smart-seed-media="1"]') ||
                   el.closest('[data-app-smart-x-active="1"]') != null);
                return {
                  el, key, x, y, top:r.top, left:r.left, matches,
                  centerDistance, quality, type:mediaKind(el), activeXSeed
                };
              })
              .filter(row => !attempted.has(row.key) && row.matches);
            rows.sort((a, b) => keyword
              ? (a.top - b.top || a.left - b.left || b.quality - a.quality)
              : ((b.activeXSeed ? 1 : 0) - (a.activeXSeed ? 1 : 0) ||
                 a.centerDistance - b.centerDistance || b.quality - a.quality));
            const selected = rows[0];
            if (selected) {
              if (selected.type === 'video') {
                if (xInlineFeedMode && !xInlineReadyToLongPress) {
                  const makeTouchEvent = (name, active) => {
                    const event = new Event(name, {bubbles:true, cancelable:true});
                    const touch = {
                      identifier: Date.now(),
                      target: selected.el,
                      clientX: selected.x,
                      clientY: selected.y,
                      pageX: selected.x + scrollX,
                      pageY: selected.y + scrollY,
                      screenX: selected.x,
                      screenY: selected.y
                    };
                    Object.defineProperty(event, 'touches', {
                      configurable:true, value:active ? [touch] : []
                    });
                    Object.defineProperty(event, 'changedTouches', {
                      configurable:true, value:[touch]
                    });
                    return event;
                  };
                  selected.el.dispatchEvent(makeTouchEvent('touchstart', true));
                  if (typeof PointerEvent === 'function') {
                    selected.el.dispatchEvent(new PointerEvent('pointerdown', {
                      bubbles:true, cancelable:true,
                      clientX:selected.x, clientY:selected.y, pointerType:'touch'
                    }));
                  }
                  setTimeout(() => {
                    selected.el.dispatchEvent(makeTouchEvent('touchend', false));
                    if (typeof PointerEvent === 'function') {
                      selected.el.dispatchEvent(new PointerEvent('pointerup', {
                        bubbles:true, cancelable:true,
                        clientX:selected.x, clientY:selected.y, pointerType:'touch'
                      }));
                    }
                    selected.el.click();
                    try {
                      selected.el.muted = true;
                      selected.el.play().catch(() => {});
                    } catch (_) {}
                  }, 90);
                  return {
                    action:'activate',
                    key:selected.key,
                    type:'video',
                    scrollY:Math.max(0, window.scrollY || 0),
                    x:selected.x / Math.max(1, innerWidth),
                    y:selected.y / Math.max(1, innerHeight)
                  };
                }
                const source = String(
                  selected.el.currentSrc || selected.el.src || ''
                ).trim();
                if (!source && Number(selected.el.readyState || 0) < 2) {
                  try {
                    selected.el.muted = true;
                    selected.el.setAttribute('preload', 'auto');
                    selected.el.load();
                    selected.el.play().catch(() => {});
                  } catch (_) {}
                  return {
                    action:'prepare',
                    key:selected.key,
                    type:'video',
                    x:selected.x / Math.max(1, innerWidth),
                    y:selected.y / Math.max(1, innerHeight)
                  };
                }
              }
              selected.el.setAttribute('data-app-smart-gesture', '1');
              selected.el.setAttribute('data-app-smart-attempted', '1');
              const makeTouchEvent = (name, active) => {
                const event = new Event(name, {bubbles:true, cancelable:true});
                const touch = {
                  identifier: Date.now(),
                  target: selected.el,
                  clientX: selected.x,
                  clientY: selected.y,
                  pageX: selected.x + scrollX,
                  pageY: selected.y + scrollY,
                  screenX: selected.x,
                  screenY: selected.y
                };
                Object.defineProperty(event, 'touches', {
                  configurable:true, value: active ? [touch] : []
                });
                Object.defineProperty(event, 'changedTouches', {
                  configurable:true, value:[touch]
                });
                return event;
              };
              selected.el.dispatchEvent(makeTouchEvent('touchstart', true));
              setTimeout(() => {
                selected.el.dispatchEvent(makeTouchEvent('touchend', false));
                setTimeout(() => selected.el.removeAttribute('data-app-smart-gesture'), 80);
              }, 560);
              return {
                action:'longpress',
                key:selected.key,
                type:selected.type,
                confidence:selected.quality,
                visibleCandidates:rows.length,
                x:selected.x / Math.max(1, innerWidth),
                y:selected.y / Math.max(1, innerHeight)
              };
            }

            // Ordinary sites commonly expose videos as thumbnail cards rather
            // than <video> elements. Allow one card-detail hop even without a
            // keyword, but keep the dedicated X/91 state machines untouched.
            const ordinarySiteCardFlow = siteProfile !== 'x' &&
              siteProfile !== '91';
            if ((keyword || ordinarySiteCardFlow) && hasReturnPage) {
              return {action:'return', key:'', x:0.12, y:0.18};
            }

            if (keyword && requestedType !== 'mixed' && !typeFilterApplied) {
                const wanted = requestedType === 'video'
                  ? /^(视频|video|videos)\$/i
                  : /^(图片|图像|image|images)\$/i;
                const tabs = Array.from(document.querySelectorAll(
                  'a[href], button, [role="tab"], [role="button"]'
                )).map(el => {
                  const text = String(
                    el.innerText || el.getAttribute('aria-label') || ''
                  ).replace(/\\s+/g, ' ').trim();
                  const r = el.getBoundingClientRect();
                  const href = el.href || '';
                  let sameHost = true;
                  if (href) {
                    try {
                      sameHost = new URL(href, location.href).hostname ===
                        location.hostname;
                    } catch (_) { sameHost = false; }
                  }
                  return {el, text, r, sameHost};
                }).filter(row =>
                  row.sameHost && wanted.test(row.text) &&
                  row.r.width > 20 && row.r.height > 16
                );
                const tab = tabs[0];
                if (tab) {
                  const classText = String(tab.el.className || '').toLowerCase();
                  const alreadyActive =
                    tab.el.getAttribute('aria-selected') === 'true' ||
                    tab.el.getAttribute('aria-current') === 'page' ||
                    /\\b(active|current|selected)\\b/.test(classText);
                  if (alreadyActive) {
                    return {action:'typeReady', key:'', x:0.5, y:0.18};
                  }
                  tab.el.scrollIntoView({block:'center', inline:'center'});
                  setTimeout(() => tab.el.click(), 160);
                  return {
                    action:'typeFilter',
                    key:'',
                    x:(tab.r.left + tab.r.width / 2) / Math.max(1, innerWidth),
                    y:(tab.r.top + tab.r.height / 2) / Math.max(1, innerHeight)
                  };
                }
              }

            if (keyword || ordinarySiteCardFlow) {
              const cardSelector = siteProfile === 'x'
                ? 'article[data-testid="tweet"], [data-testid="cellInnerDiv"], a[href*="/status/"]'
                : siteProfile === '91'
                ? 'article, a[href*="/archives/"], [class*="post"], [class*="item"]'
                : siteProfile === 'xvideo'
                ? '.thumb-block, .thumb-inside, a[href*="/video"], a[href*="/prof-video"]'
                : (siteProfile === 'tikporn' || siteProfile === 'pinporn')
                ? 'article, video, [class*="video"], [class*="post"], [role="link"]'
                : 'a[href], article, [role="link"], [class*="card"], [class*="item"]';
              const siteRoot = host => {
                const parts = String(host || '').toLowerCase()
                  .replace(/^www\\./, '').split('.').filter(Boolean);
                if (parts.length <= 2) return parts.join('.');
                const suffix2 = parts.slice(-2).join('.');
                const compound = new Set([
                  'com.cn', 'net.cn', 'org.cn', 'com.hk',
                  'co.uk', 'com.au', 'co.jp'
                ]);
                return parts.slice(-(compound.has(suffix2) ? 3 : 2)).join('.');
              };
              const currentRoot = siteRoot(location.hostname);
              const cards = Array.from(document.querySelectorAll(cardSelector)).filter(el => {
                if (!visible(el)) return false;
                if (el.closest(
                  'header, nav, footer, [role="navigation"], [class*="toolbar"], ' +
                  '[class*="navbar"], [class*="breadcrumb"]'
                )) return false;
                const text = String(el.innerText || el.getAttribute('aria-label') || '')
                  .toLowerCase();
                if (!trustedKeywordResults && !text.includes(keyword)) return false;
                const href = el.href || (el.closest('a[href]') || {}).href || '';
                if (href) {
                  try {
                    const targetUrl = new URL(href, location.href);
                    if (!/^https?:\$/.test(targetUrl.protocol) ||
                        siteRoot(targetUrl.hostname) !== currentRoot) {
                      return false;
                    }
                    const routeText = (targetUrl.pathname + ' ' + targetUrl.search).toLowerCase();
                    if (/(privacy|terms|feedback|history|login|signup|register|javascript:)/.test(
                      routeText
                    )) return false;
                  } catch (_) { return false; }
                }
                const lowerText = text.toLowerCase();
                if (/(隐私|条款|反馈|登录|注册|下载app|打开app|privacy|terms|feedback|sign in)/i
                    .test(lowerText)) return false;
                if (requestedType === 'video') {
                  const mediaHint = String(
                    el.className || el.getAttribute('aria-label') || ''
                  ).toLowerCase();
                  const is91ArchiveCard = siteProfile === '91' &&
                    href.includes('/archives/') &&
                    /[0-9]+/.test(href.split('/archives/')[1] || '');
                  const hasVideoFeature =
                    !!el.querySelector('video') ||
                    /(^|\\D)\\d{1,2}:\\d{2}(\\D|\$)/.test(lowerText) ||
                    /(video|play|播放|视频)/.test(mediaHint + ' ' + lowerText) ||
                    !!el.querySelector(
                      '[class*="play"], [class*="video"], [aria-label*="播放"], [aria-label*="Play" i]'
                    );
                  if (!hasVideoFeature && !is91ArchiveCard) return false;
                } else if (requestedType === 'image' &&
                    !el.querySelector('img, picture, canvas')) {
                  return false;
                } else if (ordinarySiteCardFlow &&
                    requestedType === 'mixed' &&
                    !el.querySelector('img, picture, canvas, video') &&
                    !/(media|video|image|photo|播放|视频|图片)/.test(
                      String(el.className || '') + ' ' + lowerText
                    )) {
                  return false;
                }
                return true;
              }).map((el, index) => {
                const r = el.getBoundingClientRect();
                const link = el.matches('a[href]') ? el : el.querySelector('a[href]');
                const key = String((link && link.href) || '') ||
                  location.href + '#smart-card-' + Math.round(scrollY + r.top) + '-' + index;
                return {el, link, key, top:r.top, left:r.left, r};
              }).filter(row => !attempted.has(row.key))
                .sort((a,b) => a.top - b.top || a.left - b.left);
              const card = cards[0];
              if (card) {
                const target = card.link || card.el;
                target.setAttribute('data-app-smart-attempted', '1');
                target.scrollIntoView({block:'center', inline:'center'});
                setTimeout(() => target.click(), 180);
                return {
                  action:'click',
                  key:card.key,
                  x:(card.r.left + card.r.width / 2) / Math.max(1, innerWidth),
                  y:(card.r.top + card.r.height / 2) / Math.max(1, innerHeight)
                };
              }
            }

            const pendingVisibleMedia = Array.from(
              document.querySelectorAll(selector)
            ).some(el => {
              if (!visible(el)) return false;
              if (el.tagName === 'IMG') {
                return !el.complete || Number(el.naturalWidth || 0) === 0;
              }
              if (el.tagName === 'VIDEO') {
                return Number(el.readyState || 0) < 1;
              }
              return false;
            });
            if (pendingVisibleMedia && !skipPendingWait) {
              return {action:'wait', key:'', x:0.5, y:0.5};
            }
            const page = document.scrollingElement || document.documentElement;
            const atBottom = page.scrollTop + innerHeight >= page.scrollHeight - 80;
            if (atBottom) {
              const nextPattern = /^(下一页|下一頁|下页|更多|加载更多|next|more)\$/i;
              const pager = Array.from(document.querySelectorAll(
                'a[href], button, [role="button"]'
              )).map(el => {
                const text = String(
                  el.innerText || el.getAttribute('aria-label') || el.title || ''
                ).replace(/\\s+/g, ' ').trim();
                const r = el.getBoundingClientRect();
                return {el, text, r};
              }).find(row => {
                if (!nextPattern.test(row.text) || row.r.width < 20 || row.r.height < 16) {
                  return false;
                }
                const href = row.el.href || '';
                if (!href) return true;
                try {
                  return siteRoot(new URL(href, location.href).hostname) === currentRoot;
                } catch (_) { return false; }
              });
              if (pager) {
                const key = 'page:' + String(pager.el.href || pager.text);
                if (!attempted.has(key)) {
                  pager.el.scrollIntoView({block:'center', inline:'center'});
                  setTimeout(() => pager.el.click(), 160);
                  return {
                    action:'paginate', key,
                    x:(pager.r.left + pager.r.width / 2) / Math.max(1, innerWidth),
                    y:(pager.r.top + pager.r.height / 2) / Math.max(1, innerHeight)
                  };
                }
              }
              return {action:'exhausted', key:'', x:0.5, y:0.82};
            }
            const before = scrollY;
            window.scrollBy({top:Math.max(360, innerHeight * 0.78), behavior:'smooth'});
            return {action:'scroll', key:'', x:0.5, y:0.78, before};
          })()
        ''',
      );
      if (result is! Map || !identical(_smartDownloadTask, task)) {
        if (!identical(_smartDownloadTask, task)) return true;
        task['gestureEngineFailures'] =
            ((task['gestureEngineFailures'] as int?) ?? 0) + 1;
        if ((task['gestureEngineFailures'] as int) >= 3 &&
            await _recoverVisibleGesturePage(task, '页面识别连续失败')) {
          return true;
        }
        if ((task['gestureEngineFailures'] as int) >= 3) {
          task['gestureMode'] = false;
          task['phase'] = 'collecting_site_results';
        }
        Future<void>.delayed(const Duration(milliseconds: 180), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      final action = (result['action'] ?? '').toString();
      final key = (result['key'] ?? '').toString();
      debugPrint(
        'Smart visible gesture: action=$action key=$key '
        'phase=${task['phase']} url=$_currentUrl',
      );
      if (key.isNotEmpty && action != 'prepare' && action != 'activate') {
        attempted.add(key);
      }
      final point = Offset(
        (result['x'] as num?)?.toDouble() ?? 0.5,
        (result['y'] as num?)?.toDouble() ?? 0.5,
      );
      if (action == 'longpress') {
        task['xInlineActivationPending'] = false;
        task['xInlineReadyToLongPress'] = false;
        task['gestureSkipPendingWait'] = false;
        task['gestureWaitCount'] = 0;
        task['gesturePrepareCount'] = 0;
        task['gestureDownloadPending'] = true;
        task['gestureDownloadStartedAt'] = DateTime.now();
        task['gestureActiveKey'] = key;
        task['phase'] = 'gesture_waiting_download';
        _showSmartOperation('长按当前媒体，触发下载', point: point);
        _updateSmartDiscoveryProgress(task, 'gesture_waiting_download');
        Future<void>.delayed(const Duration(seconds: 21), () {
          if (identical(_smartDownloadTask, task) &&
              task['gestureDownloadPending'] == true) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'activate') {
        task['xInlineActivationPending'] = true;
        task['xInlineReadyToLongPress'] = false;
        task['xInlineActivatedAt'] = DateTime.now();
        task['gestureReturnUrl'] = _currentUrl;
        task['xReturnUrl'] = _currentUrl;
        task['xReturnScrollY'] = (result['scrollY'] as num?)?.toDouble();
        task['phase'] = 'x_inline_activating';
        task['matchStage'] = 'X 信息流直下模式 · 激活当前视频';
        _showSmartOperation('点击当前视频并等待播放，再长按下载', point: point);
        Future<void>.delayed(const Duration(milliseconds: 2450), () {
          if (identical(_smartDownloadTask, task) &&
              task['xInlineActivationPending'] == true) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'prepare') {
        task['gestureSkipPendingWait'] = false;
        final prepareCount = ((task['gesturePrepareCount'] as int?) ?? 0) + 1;
        task['gesturePrepareCount'] = prepareCount;
        task['phase'] = 'gesture_preparing_media';
        _showSmartOperation('正在播放预热，获取当前视频地址', point: point);
        if (prepareCount >= 4 && key.isNotEmpty) {
          // The next pass will skip this unresolved element and continue,
          // instead of remaining on an unplayable placeholder forever.
          attempted.add(key);
          task['gesturePrepareCount'] = 0;
        }
        Future<void>.delayed(const Duration(milliseconds: 700), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'wait') {
        final waitCount = ((task['gestureWaitCount'] as int?) ?? 0) + 1;
        task['gestureWaitCount'] = waitCount;
        task['phase'] = 'gesture_waiting_dom';
        _showSmartOperation('等待当前页面媒体加载完成', point: point);
        if (waitCount <= 2) {
          Future<void>.delayed(const Duration(milliseconds: 550), () {
            if (identical(_smartDownloadTask, task)) {
              unawaited(_advanceSmartDownload(_currentUrl));
            }
          });
          return true;
        }
        task['gestureWaitCount'] = 0;
        task['gestureSkipPendingWait'] = true;
        // Continue immediately so this pass can scroll or use a fallback.
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'search') {
        task['gestureKeywordSubmitted'] = true;
        task['phase'] = 'gesture_searching';
        _showSmartOperation('输入关键词并提交站内搜索', point: point);
        Future<void>.delayed(const Duration(milliseconds: 1400), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'gesture_searching') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'typeFilter' || action == 'typeReady') {
        task['gestureTypeFilterApplied'] = true;
        task['phase'] = 'gesture_filtering_type';
        _showSmartOperation(
          mediaType == MediaType.video ? '切换到视频搜索结果' : '切换到图片搜索结果',
          point: point,
        );
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'gesture_filtering_type') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'return') {
        task['phase'] = 'gesture_returning';
        _showSmartOperation('当前页面没有目标媒体，返回搜索结果');
        final returnUrl = gestureReturnUrl;
        if (task['siteProfile'] == 'x' && returnUrl.startsWith('http')) {
          task['phase'] = 'x_search_returning';
          task['xReturnUrl'] = returnUrl;
          task['xReturnExpectedUrl'] = returnUrl;
          task['xReturnAttempts'] = 0;
          _loadUrl(returnUrl);
        } else if (await _controller!.canGoBack()) {
          await _controller!.goBack();
        } else if (returnUrl.startsWith('http')) {
          _loadUrl(returnUrl);
        } else {
          task['gestureDetailMode'] = false;
          task['gestureReturnUrl'] = '';
          task['phase'] = 'gesture_scanning_results';
        }
        return true;
      }
      if (action == 'paginate') {
        task['phase'] = 'gesture_opening_next_page';
        task['gestureResultUrl'] = _currentUrl;
        task['gestureNoMoveCount'] = 0;
        _showSmartOperation('打开站内下一页，继续寻找媒体', point: point);
        Future<void>.delayed(const Duration(milliseconds: 1300), () {
          if (identical(_smartDownloadTask, task)) {
            task['phase'] = 'gesture_scanning_results';
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'exhausted') {
        if (await _recoverVisibleGesturePage(task, '当前结果已遍历', nextPage: true)) {
          return true;
        }
        task['gestureMode'] = false;
        task['phase'] = 'collecting_site_results';
        task['matchStage'] = '可视手势已遍历当前结果，启用站内地址兜底';
        _showSmartOperation('当前结果已浏览完，启用站内兜底查找');
        Future<void>.delayed(const Duration(milliseconds: 120), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'click') {
        if (task['xInlineFeedMode'] == true) {
          attempted.add(key);
          task['phase'] = 'scanning_feed';
          task['matchStage'] = 'X 信息流直下模式 · 跳过需要进入详情的卡片';
          _showSmartOperation('当前卡片无法直接长按，留在信息流寻找下一条');
          _continueSmartFeed(task, madeProgress: false);
          return true;
        }
        task['gestureReturnUrl'] = _currentUrl;
        task['gestureActionStartedAt'] = DateTime.now();
        task['gestureDetailMode'] = false;
        task['phase'] = 'gesture_opening_card';
        _showSmartOperation('点击当前媒体卡片，进入下一层', point: point);
        Future<void>.delayed(const Duration(milliseconds: 1400), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'gesture_opening_card') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      if (action == 'scroll') {
        task['gestureSkipPendingWait'] = false;
        final before = (result['before'] as num?)?.toDouble() ?? -1;
        final previous = (task['gestureLastScrollY'] as num?)?.toDouble() ?? -2;
        final noMove = (before - previous).abs() < 3;
        task['gestureLastScrollY'] = before;
        task['gestureNoMoveCount'] =
            noMove ? ((task['gestureNoMoveCount'] as int?) ?? 0) + 1 : 0;
        if ((task['gestureNoMoveCount'] as int) >= 2) {
          if (await _recoverVisibleGesturePage(
            task,
            '当前结果无法继续滚动',
            nextPage: true,
          )) {
            return true;
          }
          task['gestureMode'] = false;
          task['phase'] = 'collecting_site_results';
          task['matchStage'] = '页面无法继续滑动，启用站内地址兜底';
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            if (identical(_smartDownloadTask, task)) {
              unawaited(_advanceSmartDownload(_currentUrl));
            }
          });
          return true;
        }
        task['phase'] = 'gesture_scrolling';
        _showSmartOperation('向上滑动屏幕，寻找下一个媒体', point: point);
        Future<void>.delayed(const Duration(milliseconds: 850), () {
          if (identical(_smartDownloadTask, task)) {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return true;
      }
      task['gestureEngineFailures'] =
          ((task['gestureEngineFailures'] as int?) ?? 0) + 1;
      if ((task['gestureEngineFailures'] as int) >= 3 &&
          await _recoverVisibleGesturePage(task, '未识别到有效操作')) {
        return true;
      }
      if ((task['gestureEngineFailures'] as int) >= 3) {
        task['gestureMode'] = false;
        task['phase'] = 'collecting_site_results';
      }
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (identical(_smartDownloadTask, task)) {
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return true;
    } catch (e) {
      debugPrint('可视手势智能下载失败，转入兼容兜底: $e');
      final failures = ((task['gestureEngineFailures'] as int?) ?? 0) + 1;
      task['gestureEngineFailures'] = failures;
      task['failed'] = (task['failed'] as int) + 1;
      if (failures >= 3 && await _recoverVisibleGesturePage(task, '可视识别发生异常')) {
        return true;
      }
      if (failures >= 3) {
        task['gestureMode'] = false;
        task['phase'] = 'collecting_site_results';
        task['matchStage'] = '可视识别连续异常，启用原有站内下载兜底';
      }
      Future<void>.delayed(const Duration(milliseconds: 180), () {
        if (identical(_smartDownloadTask, task)) {
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return true;
    }
    return false;
  }

  Future<void> _completeSmartGestureDownload(bool success) async {
    final task = _smartDownloadTask;
    if (task == null || task['gestureDownloadPending'] != true) return;
    task['gestureDownloadPending'] = false;
    task['xInlineActivationPending'] = false;
    task['xInlineReadyToLongPress'] = false;
    final failureType =
        (task.remove('lastGestureFailureType') ?? '').toString();
    final skippedDuplicate =
        !success &&
        <String>{
          'already_in_library',
          'already_in_smart_task',
          'duplicate_name_in_smart_task',
          'already_downloading',
        }.contains(failureType);
    final activeKey = (task['gestureActiveKey'] ?? '').toString();
    final actionFailures = task['gestureActionFailures'] as Map<String, int>;
    if (success) {
      task['gestureConsecutiveFailures'] = 0;
      task['gestureEngineFailures'] = 0;
    } else {
      task['gestureConsecutiveFailures'] =
          ((task['gestureConsecutiveFailures'] as int?) ?? 0) + 1;
      if (activeKey.isNotEmpty) {
        actionFailures[activeKey] = (actionFailures[activeKey] ?? 0) + 1;
      }
    }
    task['gestureActiveKey'] = '';
    if (success) {
      task['success'] = (task['success'] as int) + 1;
    } else if (skippedDuplicate) {
      if (failureType != 'already_in_library') {
        task['duplicateSkipped'] =
            ((task['duplicateSkipped'] as int?) ?? 0) + 1;
      }
      task['matchStage'] = '发现重复媒体 · 已自动跳过并切换下一项';
      _showSmartOperation('当前媒体已经处理过，自动跳过');
    } else {
      task['failed'] = (task['failed'] as int) + 1;
    }
    _updateSmartDiscoveryProgress(task, 'gesture_download_completed');
    if (!success && failureType == 'library_save_failed') {
      await _finishSmartDownload('写入媒体库失败，已停止任务；请检查存储空间和数据库状态');
      return;
    }
    if ((task['success'] as int) >= (task['target'] as int)) {
      await _finishSmartDownload();
      return;
    }
    final controller = _controller;
    final actualUrl =
        controller == null
            ? _currentUrl
            : (await controller.getUrl())?.toString() ?? _currentUrl;
    final originUrl = (task['originUrl'] ?? '').toString();
    final xReturnUrl = (task['xReturnUrl'] ?? '').toString();
    final enteredXStatusFromList =
        task['siteProfile'] == 'x' &&
        xReturnUrl.startsWith('http') &&
        (task['xEnteredDetailFromList'] == true ||
            (_isXStatusDetailPage(actualUrl) &&
                !_isSameLoadedDocument(xReturnUrl, actualUrl)));
    if (enteredXStatusFromList) {
      task['gestureDetailMode'] = false;
      task['gestureReturnUrl'] = '';
      task['matchStage'] = 'X 帖子视频已下载 · 返回原信息流';
      _showSmartOperation('当前帖子下载完成，返回原页面继续下一条');
      await _returnFromXSmartCard(task);
      return;
    }
    final enteredXMediaViewer =
        task['siteProfile'] == 'x' &&
        !_isXMediaViewerPage(originUrl) &&
        _isXMediaViewerPage(actualUrl);
    final recordedReturnUrl = (task['gestureReturnUrl'] ?? '').toString();
    final returnUrl =
        recordedReturnUrl.startsWith('http')
            ? recordedReturnUrl
            : enteredXMediaViewer
            ? originUrl
            : '';
    if ((task['gestureDetailMode'] == true || enteredXMediaViewer) &&
        returnUrl.startsWith('http')) {
      task['phase'] = 'gesture_returning';
      task['matchStage'] = 'X 详情媒体已下载 · 返回原列表';
      _showSmartOperation('当前媒体下载完成，返回上一级继续查找');
      var closedXViewer = false;
      if (task['siteProfile'] == 'x') {
        // Never use WebView history for X smart tasks. Its SPA inserts
        // transient about:blank entries that can cause a return loop.
        final xTarget =
            _isSameLoadedDocument(returnUrl, actualUrl) &&
                    originUrl.startsWith('http') &&
                    !_isSameLoadedDocument(originUrl, actualUrl)
                ? originUrl
                : returnUrl;
        task['phase'] = 'x_search_returning';
        task['xReturnUrl'] = xTarget;
        task['xReturnExpectedUrl'] = xTarget;
        task['xReturnAttempts'] = 0;
        _loadUrl(xTarget);
        closedXViewer = true;
      } else if (controller != null && _isXMediaViewerPage(actualUrl)) {
        try {
          final result = await controller.evaluateJavascript(
            source: '''
              (() => {
                const selectors = [
                  '[data-testid="app-bar-back"]',
                  'button[aria-label="Close"]',
                  'button[aria-label="Back"]',
                  '[role="button"][aria-label="Close"]',
                  '[role="button"][aria-label="Back"]'
                ];
                const button = selectors.map(selector =>
                  document.querySelector(selector)
                ).find(element => {
                  if (!element) return false;
                  const rect = element.getBoundingClientRect();
                  return rect.width > 20 && rect.height > 20 &&
                    rect.bottom > 0 && rect.top < innerHeight;
                });
                if (!button) return false;
                button.click();
                return true;
              })()
            ''',
          );
          closedXViewer = result == true || result?.toString() == 'true';
        } catch (_) {}
      }
      if (!closedXViewer &&
          controller != null &&
          await controller.canGoBack()) {
        await controller.goBack();
      } else if (!closedXViewer) {
        _loadUrl(returnUrl);
      }
      Future<void>.delayed(const Duration(milliseconds: 750), () {
        if (identical(_smartDownloadTask, task) &&
            task['phase'] == 'gesture_returning') {
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return;
    }
    if (success &&
        task['siteProfile'] == 'x' &&
        (task['keyword'] ?? '').toString().trim().isEmpty) {
      task['gestureDetailMode'] = false;
      task['gestureReturnUrl'] = '';
      task['phase'] = 'scanning_feed';
      task['matchStage'] = 'X 沉浸模式 · 上滑到下一条视频';
      _continueSmartFeed(task, madeProgress: true);
      return;
    }
    task['gestureDetailMode'] = false;
    task['gestureReturnUrl'] = '';
    if (!success && ((task['gestureConsecutiveFailures'] as int?) ?? 0) >= 6) {
      if (await _recoverVisibleGesturePage(
        task,
        '连续候选无法触发下载',
        nextPage: true,
      )) {
        return;
      }
      task['gestureMode'] = false;
      task['phase'] = 'collecting_site_results';
      task['matchStage'] = '连续多个可见媒体无法下载，启用网络地址兜底';
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        if (identical(_smartDownloadTask, task)) {
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return;
    }
    task['phase'] = 'gesture_scrolling';
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (identical(_smartDownloadTask, task)) {
        unawaited(_advanceSmartDownload(_currentUrl));
      }
    });
  }

  Future<void> _anchorSmartSeedForType(MediaType mediaType) async {
    final controller = _controller;
    if (controller == null) return;
    final imageMode = mediaType == MediaType.image;
    try {
      await controller.evaluateJavascript(
        source: '''
          (() => {
            const imageMode = $imageMode;
            const selector = imageMode ? 'img' : 'video';
            const candidates = Array.from(document.querySelectorAll(selector))
              .filter(media => {
                const r = media.getBoundingClientRect();
                if (r.width < 100 || r.height < 80 || r.bottom <= 0 || r.top >= innerHeight) {
                  return false;
                }
                if (!imageMode) return true;
                const src = String(media.currentSrc || media.src || '').toLowerCase();
                const width = Math.max(media.naturalWidth || 0, r.width);
                const height = Math.max(media.naturalHeight || 0, r.height);
                return width >= 200 && height >= 160 &&
                  !/(profile_images|profile_banners|emoji|avatar|icon)/.test(src);
              });
            const center = candidates.sort((left, right) => {
              const lr = left.getBoundingClientRect();
              const rr = right.getBoundingClientRect();
              const ld = Math.abs(lr.top + lr.height / 2 - innerHeight / 2) +
                Math.abs(lr.left + lr.width / 2 - innerWidth / 2) * 0.25;
              const rd = Math.abs(rr.top + rr.height / 2 - innerHeight / 2) +
                Math.abs(rr.left + rr.width / 2 - innerWidth / 2) * 0.25;
              return ld - rd;
            })[0];
            if (!center) return false;
            document.querySelectorAll(
              '[data-smart-seed-media], [data-smart-seed-scope], '
              + '[data-app-smart-x-active], [data-app-smart-x-visited]'
            ).forEach(el => {
              el.removeAttribute('data-smart-seed-media');
              el.removeAttribute('data-smart-seed-scope');
              el.removeAttribute('data-app-smart-x-active');
              el.removeAttribute('data-app-smart-x-visited');
            });
            center.setAttribute('data-smart-seed-media', '1');
            const host = location.hostname.toLowerCase().replace(/^www\./, '');
            const isX = host === 'x.com' || host.endsWith('.x.com') ||
              host === 'twitter.com' || host.endsWith('.twitter.com');
            const scope = isX
              // Immersive viewers preload adjacent posts inside one dialog.
              // Bind to the current video's smallest stable container instead.
              ? center.closest('article[data-testid="tweet"], article') ||
                center.parentElement
              : center.closest('article, figure, [class*="card"], [class*="item"], section') ||
                center.parentElement;
            if (scope) {
              scope.setAttribute('data-smart-seed-scope', '1');
              if (isX) scope.setAttribute('data-app-smart-x-active', '1');
            }
            if (!imageMode) {
              Array.from(document.querySelectorAll('video')).forEach(video => {
                if (video !== center) {
                  try { video.pause(); } catch (_) {}
                }
              });
              try { center.muted = true; center.play().catch(() => {}); } catch (_) {}
            }
            center.scrollIntoView({behavior: 'auto', block: 'center'});
            return true;
          })()
        ''',
      );
      _showSmartOperation(
        mediaType == MediaType.image ? '定位屏幕中心图片' : '定位屏幕中心视频',
      );
    } catch (e) {
      debugPrint('智能下载定位中心媒体失败: $e');
    }
  }

  Future<void> _showSmartDownloadDialog(
    Map<String, dynamic> website, {
    String initialKeyword = '',
    MediaType initialMediaType = MediaType.video,
    bool startFromCurrentPage = false,
    List<String> initialVideoUrls = const <String>[],
    double initialVideoDuration = 0,
  }) async {
    if (_smartDownloadTask != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已有智能下载任务正在执行')));
      return;
    }
    final keywordController = TextEditingController(text: initialKeyword);
    final countController = TextEditingController();
    final minVideoSizeController = TextEditingController();
    final maxVideoSizeController = TextEditingController();
    MediaType? selectedMediaType;
    var historyExpanded = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: Text(
                    startFromCurrentPage
                        ? '智能下载'
                        : '智能下载 · ${website['name'] ?? '网站'}',
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: keywordController,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: '下载关键词',
                            hintText: '可留空：按屏幕中心媒体由近到远下载',
                            suffixIcon:
                                _smartKeywordHistory.isEmpty
                                    ? null
                                    : IconButton(
                                      tooltip:
                                          historyExpanded
                                              ? '收起历史关键词'
                                              : '展开历史关键词',
                                      onPressed:
                                          () => setDialogState(
                                            () =>
                                                historyExpanded =
                                                    !historyExpanded,
                                          ),
                                      icon: AnimatedRotation(
                                        turns: historyExpanded ? 0.25 : 0,
                                        duration: const Duration(
                                          milliseconds: 160,
                                        ),
                                        child: const Icon(Icons.arrow_right),
                                      ),
                                    ),
                          ),
                        ),
                        if (historyExpanded &&
                            _smartKeywordHistory.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const Text(
                            '历史关键词（点击使用，删除错误词）',
                            style: TextStyle(fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            children:
                                List<String>.from(_smartKeywordHistory)
                                    .map(
                                      (value) => InputChip(
                                        label: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 180,
                                          ),
                                          child: Text(
                                            value,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        onPressed:
                                            () =>
                                                keywordController.text = value,
                                        onDeleted: () async {
                                          await _removeSmartKeyword(value);
                                          if (dialogContext.mounted) {
                                            setDialogState(() {});
                                          }
                                        },
                                      ),
                                    )
                                    .toList(),
                          ),
                        ],
                        const SizedBox(height: 16),
                        const Text(
                          '下载媒体类型（可不选）',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<MediaType>(
                          segments: const [
                            ButtonSegment(
                              value: MediaType.image,
                              icon: Icon(Icons.image_outlined),
                              label: Text('图片'),
                            ),
                            ButtonSegment(
                              value: MediaType.video,
                              icon: Icon(Icons.videocam_outlined),
                              label: Text('视频'),
                            ),
                          ],
                          emptySelectionAllowed: true,
                          selected:
                              selectedMediaType == null
                                  ? const <MediaType>{}
                                  : <MediaType>{selectedMediaType!},
                          onSelectionChanged:
                              (values) => setDialogState(
                                () =>
                                    selectedMediaType =
                                        values.isEmpty ? null : values.first,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          selectedMediaType == null
                              ? '未选择：图片和视频均可，按距离依次下载'
                              : '仅下载${selectedMediaType == MediaType.image ? '图片' : '视频'}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: countController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '下载数量',
                            hintText: '默认 5 个',
                            helperText: '最少 1 个，最多 100 个；留空默认 5 个',
                          ),
                        ),
                        if (selectedMediaType != MediaType.image) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: minVideoSizeController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: '最小大小（MB）',
                                    hintText: '不限',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  controller: maxVideoSizeController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: '最大大小（MB）',
                                    hintText: '不限',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '两项留空时，将以当前视频大小为基准，自动采用约 50%～150%；无法可靠获取时才不限制。',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () {
                        final count =
                            int.tryParse(countController.text.trim()) ?? 5;
                        if (count < 1 || count > 100) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(content: Text('请输入 1～100 的数量')),
                          );
                          return;
                        }
                        final minMb = int.tryParse(minVideoSizeController.text);
                        final maxMb = int.tryParse(maxVideoSizeController.text);
                        if (selectedMediaType != MediaType.image &&
                            minMb != null &&
                            maxMb != null &&
                            minMb > maxMb) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            const SnackBar(content: Text('最小视频大小不能大于最大大小')),
                          );
                          return;
                        }
                        Navigator.pop(dialogContext, true);
                      },
                      child: const Text('开始'),
                    ),
                  ],
                ),
          ),
    );
    final enteredKeyword = keywordController.text.trim();
    final enteredCount = int.tryParse(countController.text.trim()) ?? 5;
    final enteredMinVideoMb = int.tryParse(minVideoSizeController.text);
    final enteredMaxVideoMb = int.tryParse(maxVideoSizeController.text);
    // showDialog completes when pop starts, before the reverse transition has
    // removed every dependent TextField/InheritedWidget from the overlay.
    await Future<void>.delayed(const Duration(milliseconds: 360));
    if (confirmed == true && mounted) {
      int? minVideoBytes =
          selectedMediaType != MediaType.image && enteredMinVideoMb != null
              ? enteredMinVideoMb * 1024 * 1024
              : null;
      int? maxVideoBytes =
          selectedMediaType != MediaType.image && enteredMaxVideoMb != null
              ? enteredMaxVideoMb * 1024 * 1024
              : null;
      var autoVideoSizeRange = false;
      if (selectedMediaType != MediaType.image &&
          enteredMinVideoMb == null &&
          enteredMaxVideoMb == null &&
          startFromCurrentPage) {
        final seedBytes = await _estimateSmartSeedVideoBytes(
          initialVideoUrls,
          _currentUrl,
          initialVideoDuration,
        );
        if (seedBytes != null && seedBytes > 0) {
          minVideoBytes = max(1, (seedBytes * 0.5).floor());
          maxVideoBytes = (seedBytes * 1.5).ceil();
          autoVideoSizeRange = true;
        }
      }
      final keyword =
          enteredKeyword.isNotEmpty
              ? enteredKeyword
              : (startFromCurrentPage
                  ? ''
                  : (website['name'] ?? '').toString().trim());
      if (keyword.isNotEmpty) {
        await _rememberSmartKeyword(keyword);
      }
      await _startSmartDownload(
        website: website,
        keyword: keyword,
        targetCount: enteredCount,
        mediaType: selectedMediaType ?? initialMediaType,
        allowMixedMedia: selectedMediaType == null,
        startFromCurrentPage: startFromCurrentPage,
        minVideoBytes: minVideoBytes,
        maxVideoBytes: maxVideoBytes,
        autoVideoSizeRange: autoVideoSizeRange,
      );
    }
    keywordController.dispose();
    countController.dispose();
    minVideoSizeController.dispose();
    maxVideoSizeController.dispose();
  }

  Future<void> _startSmartDownload({
    required Map<String, dynamic> website,
    required String keyword,
    required int targetCount,
    required MediaType mediaType,
    bool allowMixedMedia = false,
    bool startFromCurrentPage = false,
    int? minVideoBytes,
    int? maxVideoBytes,
    bool autoVideoSizeRange = false,
  }) async {
    final rawUrl = (website['url'] ?? '').toString().trim();
    final normalized =
        rawUrl.startsWith('http://') || rawUrl.startsWith('https://')
            ? rawUrl
            : 'https://$rawUrl';
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return;
    final normalizedHost = uri.host.toLowerCase().replaceFirst(
      RegExp(r'^www\.'),
      '',
    );
    final currentHost =
        Uri.tryParse(
          _currentUrl,
        )?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ??
        '';
    final currentUri = Uri.tryParse(_currentUrl);
    final effectiveHost =
        startFromCurrentPage && currentHost.isNotEmpty
            ? currentHost
            : normalizedHost;
    final effectiveUri =
        startFromCurrentPage && currentUri != null && currentUri.host.isNotEmpty
            ? currentUri
            : uri;
    final keywordFirstOn91 =
        startFromCurrentPage &&
        keyword.trim().isNotEmpty &&
        (effectiveHost == '91cg1.com' || effectiveHost.endsWith('.91cg1.com'));
    final strictXFeedMode =
        startFromCurrentPage &&
        (effectiveHost == 'x.com' ||
            effectiveHost.endsWith('.x.com') ||
            effectiveHost == 'twitter.com' ||
            effectiveHost.endsWith('.twitter.com'));
    final keywordFirstOnX = strictXFeedMode && keyword.trim().isNotEmpty;
    final xInlineFeedMode =
        strictXFeedMode &&
        keyword.trim().isEmpty &&
        !_isXStatusDetailPage(_currentUrl) &&
        !_isXMediaViewerPage(_currentUrl);
    final strictBaiduVideoMode =
        startFromCurrentPage &&
        keyword.trim().isNotEmpty &&
        !allowMixedMedia &&
        mediaType == MediaType.video &&
        _isBaiduHost(effectiveHost);
    final siteProfile = _smartSiteProfile(effectiveHost);
    await _loadSmartDownload24hRegistry();
    await _loadSmartStrategyProfiles();
    final startedAt = DateTime.now();
    final deadlineAt = startedAt.add(const Duration(hours: 5));
    final strict91SearchUrl =
        keywordFirstOn91
            ? '${effectiveUri.origin}/search/${Uri.encodeComponent(keyword.trim())}/'
            : '';
    final strictXSearchUrl =
        keywordFirstOnX
            ? '${effectiveUri.origin}/search?q=${Uri.encodeQueryComponent(keyword.trim())}&src=typed_query&f=media'
            : '';
    final strictBaiduSearchUrl =
        strictBaiduVideoMode ? _baiduVideoSearchUrl(keyword) : '';
    if (startFromCurrentPage && keyword.trim().isEmpty) {
      await _anchorSmartSeedForType(mediaType);
    }
    _smartDownloadTask = <String, dynamic>{
      'phase':
          keywordFirstOn91
              ? 'collecting_search_results'
              : keywordFirstOnX
              ? 'x_search_loading'
              : strictBaiduVideoMode
              ? 'baidu_video_search_loading'
              : startFromCurrentPage
              ? 'visiting_seed'
              : 'opening_site',
      'siteUrl': normalized,
      'host': effectiveHost,
      'siteProfile': siteProfile,
      'keyword': keyword,
      'mediaType': mediaType,
      'allowMixedMedia': allowMixedMedia,
      'target': targetCount,
      'minVideoBytes': minVideoBytes,
      'maxVideoBytes': maxVideoBytes,
      'autoVideoSizeRange': autoVideoSizeRange,
      'effectiveMinVideoBytes': minVideoBytes,
      'effectiveMaxVideoBytes': maxVideoBytes,
      'matchStage':
          keywordFirstOn91
              ? '关键词优先 · 站内搜索'
              : keyword.isEmpty
              ? '无关键词 · 邻近媒体优先'
              : '精确匹配',
      'success': 0,
      'failed': 0,
      'index': 0,
      'candidates': <Map<String, String>>[],
      'seenMediaUrls': <String>{},
      'attemptedVideoContexts': <String>{},
      'duplicateVideoUrlKeys': <String>{},
      'videoMediaStates': <String, String>{},
      'reservedMediaNameKeys': <String>{},
      'reservedMediaTitleKeys': <String>{},
      'clickedSmartCardKeys': <String>{},
      'exploratoryClickedKeys': <String>{},
      'feedScans': 0,
      'feedNoNew': 0,
      'feedDirection': 1,
      'feedMotionSnapshot': '',
      'feedStalledCount': 0,
      'discoveryRound': 0,
      'searchCycle': 0,
      'strategyStats': <String, dynamic>{},
      'startedAt': startedAt,
      'deadlineAt': deadlineAt,
      'lastAdvanceAt': startedAt,
      'visitedPageUrls': <String>{},
      'discoveryPageQueue': <String>[],
      'queuedDiscoveryUrls': <String>{},
      'visitedDiscoveryUrls': <String>{},
      'syntheticRouteFailures': 0,
      'disableSyntheticRoutes': false,
      'preheatedVideoCandidates': <String, List<String>>{},
      'startedFromCurrentPage': startFromCurrentPage,
      // 91 keyword search has a deterministic ordered-card state machine.
      // Do not let the generic visual gesture recovery compete with it.
      'gestureMode': startFromCurrentPage && !keywordFirstOn91,
      'gestureAttemptedKeys': <String>{},
      'gestureDownloadPending': false,
      'gestureKeywordSubmitted':
          keywordFirstOn91 || keywordFirstOnX || strictBaiduVideoMode,
      'gestureTypeFilterApplied': strictBaiduVideoMode,
      'gestureDetailMode': false,
      'gestureConsecutiveFailures': 0,
      'gestureActionFailures': <String, int>{},
      'gestureWaitCount': 0,
      'gesturePrepareCount': 0,
      'gestureNoMoveCount': 0,
      'gestureLastScrollY': -1.0,
      'gestureSkipPendingWait': false,
      'gestureEngineFailures': 0,
      'gestureActiveKey': '',
      'gestureLastSafeUrl': _currentUrl,
      'gestureResultUrl': _currentUrl,
      'gestureRecoveryCount': 0,
      'protectVisibleGestureFlow': startFromCurrentPage && !keywordFirstOn91,
      'originUrl': _currentUrl,
      'strict91KeywordMode': keywordFirstOn91,
      'strict91SearchUrl': strict91SearchUrl,
      'strict91QueueReady': false,
      'strict91ActiveCardUrl': '',
      'strict91ReturnAttempts': 0,
      'strictXFeedMode': strictXFeedMode,
      'xInlineFeedMode': xInlineFeedMode,
      'xInlineActivationPending': false,
      'xInlineReadyToLongPress': false,
      'strictXSearchUrl': strictXSearchUrl,
      'xVisitedStatusIds': <String>{},
      'xEnteredDetailFromList': false,
      'xReturnExpectedUrl': '',
      'xReturnAttempts': 0,
      'strictBaiduVideoMode': strictBaiduVideoMode,
      'strictBaiduSearchUrl': strictBaiduSearchUrl,
      'strictBaiduPage': 0,
    };
    final activeTask = _smartDownloadTask!;
    activeTask['deadlineTimer'] = Timer(
      deadlineAt.difference(DateTime.now()),
      () {
        if (identical(_smartDownloadTask, activeTask)) {
          unawaited(_finishSmartDownload('已达到单次任务 5 小时时间上限'));
        }
      },
    );
    activeTask['watchdogTimer'] = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) {
      if (!identical(_smartDownloadTask, activeTask)) return;
      if (!DateTime.now().isBefore(deadlineAt)) {
        unawaited(_finishSmartDownload('已达到单次任务 5 小时时间上限'));
        return;
      }
      final hasActiveMediaDownload = _downloadTasks.any(
        (row) =>
            row['isSmartBatchMedia'] == true && row['status'] == 'downloading',
      );
      if (hasActiveMediaDownload || _smartDownloadAdvancing) return;
      final lastAdvance = activeTask['lastAdvanceAt'] as DateTime? ?? startedAt;
      if (DateTime.now().difference(lastAdvance) <
          const Duration(seconds: 60)) {
        return;
      }
      activeTask['lastAdvanceAt'] = DateTime.now();
      if (activeTask['phase'] == 'resolving_candidate_background') {
        _visitNextSmartCandidate(activeTask);
      } else {
        unawaited(_advanceSmartDownload(_currentUrl));
      }
    });
    final discoveryQueue =
        _smartDownloadTask!['discoveryPageQueue'] as List<String>;
    final queuedDiscoveryUrls =
        _smartDownloadTask!['queuedDiscoveryUrls'] as Set<String>;
    void enqueueDiscoveryPage(String value) {
      final candidateUri = Uri.tryParse(value);
      if (candidateUri == null ||
          candidateUri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') !=
              uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '') ||
          value == _currentUrl ||
          !queuedDiscoveryUrls.add(value)) {
        return;
      }
      discoveryQueue.add(value);
    }

    final seedUri = Uri.tryParse(
      startFromCurrentPage ? _currentUrl : normalized,
    );
    if (!keywordFirstOn91 && seedUri != null && seedUri.host.isNotEmpty) {
      final segments =
          seedUri.pathSegments.where((part) => part.isNotEmpty).toList();
      while (segments.isNotEmpty) {
        segments.removeLast();
        enqueueDiscoveryPage(
          seedUri
              .replace(pathSegments: segments, query: '', fragment: '')
              .toString(),
        );
      }
    }
    final discoveryTaskId = const Uuid().v4();
    final discoveryCancelToken = CancelToken();
    _smartDownloadTask!['discoveryTaskId'] = discoveryTaskId;
    _smartDownloadTask!['discoveryCancelToken'] = discoveryCancelToken;
    if (mounted) {
      _addDownloadTask(
        discoveryTaskId,
        'smart://${keyword.isEmpty ? 'nearby-media' : keyword}',
        mediaType,
        discoveryCancelToken,
        displayName: '智能采集：${keyword.isEmpty ? '当前媒体附近' : keyword}',
        isSmartDiscovery: true,
      );
      _updateDownloadTask(
        discoveryTaskId,
        progress: 0.02,
        progressDetail: '正在解析当前页面媒体地址...',
      );
    }
    _showSmartOperation(allowMixedMedia ? '正在识别屏幕中心的图片或视频' : '正在定位屏幕中心媒体');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '智能下载已开始：${allowMixedMedia
              ? '图片+视频'
              : mediaType == MediaType.image
              ? '图片'
              : '视频'} · ${keyword.isEmpty ? '按当前媒体从近到远' : keyword} · $targetCount 个',
        ),
      ),
    );
    if (keywordFirstOn91) {
      _smartDownloadTask!['activeDiscoveryStrategy'] = 'site_search';
      _loadUrl(strict91SearchUrl);
    } else if (keywordFirstOnX) {
      _smartDownloadTask!['activeDiscoveryStrategy'] = 'x_media_search';
      _loadUrl(strictXSearchUrl);
    } else if (strictBaiduVideoMode) {
      _smartDownloadTask!['activeDiscoveryStrategy'] = 'baidu_video_search';
      _loadUrl(strictBaiduSearchUrl);
    } else if (startFromCurrentPage) {
      unawaited(_advanceSmartDownload(_currentUrl));
    } else {
      _loadUrl(normalized);
    }
  }

  Future<void> _advanceSmartDownload(String loadedUrl) async {
    final task = _smartDownloadTask;
    final controller = _controller;
    if (task == null || controller == null) return;
    if (_smartDownloadAdvancing) {
      if (task['advanceRetryScheduled'] != true) {
        task['advanceRetryScheduled'] = true;
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          if (!identical(_smartDownloadTask, task)) return;
          task['advanceRetryScheduled'] = false;
          unawaited(_advanceSmartDownload(_currentUrl));
        });
      }
      return;
    }
    task['advanceRetryScheduled'] = false;
    final discoveryToken = task['discoveryCancelToken'] as CancelToken?;
    if (discoveryToken?.isCancelled == true) {
      await _finishSmartDownload('用户已停止任务');
      return;
    }
    final deadlineAt = task['deadlineAt'] as DateTime?;
    if (deadlineAt != null && !DateTime.now().isBefore(deadlineAt)) {
      await _finishSmartDownload('已达到单次任务 5 小时时间上限');
      return;
    }
    _smartDownloadAdvancing = true;
    task['lastAdvanceAt'] = DateTime.now();
    try {
      final phase = task['phase']?.toString() ?? '';
      final taskHost = (task['host'] ?? '').toString();
      final is91KeywordTask =
          (taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com')) &&
          (task['keyword'] ?? '').toString().trim().isNotEmpty;
      final strict91Mode = task['strict91KeywordMode'] == true;
      final strictXFeedMode = task['strictXFeedMode'] == true;
      final xInlineFeedMode = task['xInlineFeedMode'] == true;
      final strictBaiduVideoMode = task['strictBaiduVideoMode'] == true;
      final strictXSearchUrl = (task['strictXSearchUrl'] ?? '').toString();
      final strict91SearchUrl = (task['strict91SearchUrl'] ?? '').toString();
      final strictBaiduSearchUrl =
          (task['strictBaiduSearchUrl'] ?? '').toString();
      final actualLoadedUrl =
          (await controller.getUrl())?.toString() ?? loadedUrl;
      final actualHost = Uri.tryParse(actualLoadedUrl)?.host ?? '';
      if (task['protectVisibleGestureFlow'] == true &&
          actualHost.isNotEmpty &&
          taskHost.isNotEmpty &&
          !_sameSmartSite(actualHost, taskHost) &&
          !_isLikelyDirectMediaUrl(actualLoadedUrl)) {
        if (await _recoverVisibleGesturePage(task, '阻止站内兜底跳到其他网站')) {
          return;
        }
      }

      if (task['gestureMode'] == true && strict91Mode) {
        // Tasks created before a hot restart may still carry the old generic
        // gesture flag. Migrate them into the ordered 91 result-card flow.
        task['gestureMode'] = false;
        task['protectVisibleGestureFlow'] = false;
        task['gestureDownloadPending'] = false;
        task['phase'] = 'collecting_search_results';
        if (strict91SearchUrl.isNotEmpty &&
            !_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
          _loadUrl(strict91SearchUrl);
          return;
        }
      }

      final xReturnInProgress =
          strictXFeedMode &&
          (phase == 'x_search_returning' || phase == 'gesture_returning');
      if (xInlineFeedMode &&
          phase != 'x_search_returning' &&
          task['xInlineActivationPending'] != true &&
          task['xInlineReadyToLongPress'] != true &&
          task['gestureDownloadPending'] != true &&
          (_isXStatusDetailPage(actualLoadedUrl) ||
              _isXMediaViewerPage(actualLoadedUrl))) {
        task['matchStage'] = 'X 信息流直下模式 · 返回原列表';
        _showSmartOperation('已阻止进入详情页，返回信息流继续下载');
        await _returnFromXSmartCard(task);
        return;
      }
      if (task['gestureMode'] == true && !xReturnInProgress) {
        final keyword = (task['keyword'] ?? '').toString().trim();
        final strictSearchStillLoading =
            (strict91Mode &&
                strict91SearchUrl.isNotEmpty &&
                !_isSameLoadedDocument(strict91SearchUrl, actualLoadedUrl)) ||
            (strictXFeedMode &&
                strictXSearchUrl.isNotEmpty &&
                !(Uri.tryParse(actualLoadedUrl)?.path.startsWith('/search') ??
                    false)) ||
            (strictBaiduVideoMode &&
                phase == 'baidu_video_search_loading' &&
                strictBaiduSearchUrl.isNotEmpty &&
                !_isBaiduVideoResultsUrl(actualLoadedUrl));
        if (strictBaiduVideoMode && strictSearchStillLoading) {
          if (_isUnsafeBaiduSmartPage(actualLoadedUrl)) {
            await _recoverStrictGesturePage(task, '搜索页加载异常');
          }
          return;
        }
        if (!strictSearchStillLoading) {
          final handled = await _advanceVisibleSmartGesture(task);
          if (handled) return;
        }
        // If a keyword is not represented on the current page, retain the
        // existing site-search path as a compatibility fallback.
        if (keyword.isEmpty) return;
      }

      if (strictXFeedMode && phase == 'x_search_loading') {
        final actualUri = Uri.tryParse(actualLoadedUrl);
        final onSearchPage =
            actualUri != null &&
            actualUri.pathSegments.isNotEmpty &&
            actualUri.pathSegments.first == 'search';
        if (!onSearchPage) {
          _loadUrl(strictXSearchUrl);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        task['phase'] = 'scanning_feed';
        _continueSmartFeed(task, madeProgress: false);
        return;
      }

      if (strictXFeedMode && phase == 'x_search_returning') {
        if (strictXSearchUrl.isEmpty) {
          final returnUrl =
              (task['xReturnExpectedUrl'] ?? task['xReturnUrl'] ?? '')
                  .toString()
                  .trim();
          if (_isBlankHistoryUrl(actualLoadedUrl) ||
              !_isXPlatformPage(actualLoadedUrl) ||
              (returnUrl.startsWith('http') &&
                  !_isSameXSmartReturnPage(returnUrl, actualLoadedUrl))) {
            if (returnUrl.startsWith('http')) {
              _loadUrl(returnUrl);
            } else {
              _loadUrl((task['siteUrl'] ?? '').toString());
            }
            return;
          }
          final scrollY = (task['xReturnScrollY'] as num?)?.toDouble();
          if (scrollY != null && scrollY > 0) {
            try {
              await controller.evaluateJavascript(
                source:
                    'window.scrollTo({top: $scrollY, left: 0, behavior: "auto"});',
              );
            } catch (_) {}
          }
          task['xReturnExpectedUrl'] = '';
          task['xReturnAttempts'] = 0;
          task['phase'] = 'scanning_feed';
          _continueSmartFeed(task, madeProgress: false);
          return;
        }
        final actualUri = Uri.tryParse(actualLoadedUrl);
        final onSearchPage =
            actualUri != null &&
            actualUri.pathSegments.isNotEmpty &&
            actualUri.pathSegments.first == 'search';
        if (!onSearchPage) {
          _loadUrl(strictXSearchUrl);
          return;
        }
        task['xReturnExpectedUrl'] = '';
        task['xReturnAttempts'] = 0;
        task['phase'] = 'scanning_feed';
        _continueSmartFeed(task, madeProgress: false);
        return;
      }

      if (strict91Mode && phase == 'strict91_returning') {
        if (_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
          task['strict91ReturnAttempts'] = 0;
          task['strict91ActiveCardUrl'] = '';
          task.remove('cardEnteredAt');
          task['phase'] = 'visiting_candidate';
          debugPrint('Smart 91 strict: restored remembered search page');
          _visitNextSmartCandidate(task);
          return;
        }
        final attempts = (task['strict91ReturnAttempts'] as int?) ?? 0;
        task['strict91ReturnAttempts'] = attempts + 1;
        if (attempts < 3 && await controller.canGoBack()) {
          debugPrint(
            'Smart 91 strict: backing through intermediate page $actualLoadedUrl',
          );
          await controller.goBack();
        } else {
          debugPrint('Smart 91 strict: restoring $strict91SearchUrl');
          _loadUrl(strict91SearchUrl);
        }
        return;
      }

      if (strict91Mode && phase == 'visiting_clicked_card') {
        final activeCardUrl = (task['strict91ActiveCardUrl'] ?? '').toString();
        if (activeCardUrl.isNotEmpty &&
            !_isSame91TaskPage(activeCardUrl, actualLoadedUrl)) {
          if (_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
            final clicked = await _clickSmartCandidateLink(activeCardUrl);
            if (!clicked) _loadUrl(activeCardUrl);
          } else {
            _loadUrl(activeCardUrl);
          }
          debugPrint(
            'Smart 91 strict: rejected unrelated page $actualLoadedUrl; expected $activeCardUrl',
          );
          return;
        }
      }
      if (phase == 'returning_candidate_list') {
        task['phase'] = 'visiting_candidate';
        _visitNextSmartCandidate(task);
        return;
      }
      if ((phase == 'scanning_feed' ||
              phase == 'collecting_site_results' ||
              phase == 'collecting_search_results' ||
              phase == 'visiting_candidate') &&
          await _recoverSmartDownloadErrorPage(task, loadedUrl)) {
        return;
      }
      _updateSmartDiscoveryProgress(task, phase);
      if (phase == 'opening_site') {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        if ((task['keyword'] ?? '').toString().trim().isEmpty) {
          task['phase'] = 'scanning_feed';
          Future<void>.delayed(
            const Duration(milliseconds: 120),
            () => unawaited(_advanceSmartDownload(_currentUrl)),
          );
          return;
        }
        task['phase'] = 'collecting_site_results';
        final keywordJson = jsonEncode(task['keyword']);
        final submitted = await controller.evaluateJavascript(
          source: '''
            (() => {
              const keyword = $keywordJson;
              const inputs = Array.from(document.querySelectorAll(
                'input[type="search"], input[name="q"], input[name*="search" i], input[placeholder*="search" i], input[placeholder*="搜索"]'
              ));
              const input = inputs.find(e => e.offsetParent !== null) || inputs[0];
              if (!input) return false;
              input.focus();
              input.value = keyword;
              input.dispatchEvent(new Event('input', {bubbles:true}));
              input.dispatchEvent(new Event('change', {bubbles:true}));
              const form = input.form || input.closest('form');
              if (form) {
                if (form.requestSubmit) form.requestSubmit(); else form.submit();
              } else {
                input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, bubbles:true}));
              }
              return true;
            })()
          ''',
        );
        final didSubmit = submitted == true || submitted.toString() == 'true';
        if (!didSubmit) {
          Future<void>.delayed(
            const Duration(milliseconds: 200),
            () => unawaited(_advanceSmartDownload(_currentUrl)),
          );
        } else {
          Future<void>.delayed(
            const Duration(seconds: 3),
            () => unawaited(_advanceSmartDownload(_currentUrl)),
          );
        }
        return;
      }

      if (phase == 'collecting_site_results' ||
          phase == 'collecting_search_results') {
        if (strict91Mode) {
          if (!_isSame91TaskPage(strict91SearchUrl, actualLoadedUrl)) {
            _loadUrl(strict91SearchUrl);
            return;
          }
          if (task['strict91QueueReady'] == true &&
              (task['candidates'] as List).isNotEmpty) {
            task['phase'] = 'visiting_candidate';
            _visitNextSmartCandidate(task);
            return;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        final hostJson = jsonEncode(task['host']);
        final keywordJson = jsonEncode(task['keyword']);
        final searchCycleDepth = (task['searchCycle'] as int?) ?? 0;
        final exhaustive = searchCycleDepth > 0;
        final limit = ((task['target'] as int) * 30 + searchCycleDepth * 80)
            .clamp(60, 1000);
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const targetHost = $hostJson;
              const keyword = $keywordJson.toLowerCase();
              const exhaustive = $exhaustive;
              // Avoid backslash escapes in injected regular expressions.
              // Dart string processing can otherwise corrupt the JS source.
              const tokens = keyword.split(' ')
                .map(v => v.trim()).filter(v => v.length >= 2).slice(0, 16);
              const seen = new Set();
              return Array.from(document.querySelectorAll('a[href]')).map((a, order) => {
                try {
                  const u = new URL(a.href, location.href);
                  const host = u.hostname.toLowerCase();
                  const normalizedHost = host.replace(/^www\./, '');
                  if (!(normalizedHost === targetHost || normalizedHost.endsWith('.' + targetHost))) return null;
                  u.hash = '';
                  const url = u.href;
                  if (seen.has(url) || u.pathname === '/' || url === location.href) return null;
                  if (!exhaustive && a.closest('header, nav, footer, aside, [role="navigation"]')) return null;
                  const path = u.pathname.toLowerCase();
                  const directMedia = /[.](m3u8|mp4|webm|mov)(?:\$|[?])/i.test(url);
                  const detailPath = /[/](archives?|posts?|videos?|watch|view|detail|movies?)[/]/i.test(path);
                  const taxonomyPath = /[/](category|categories|tags?|authors?|search|feed|page)[/]/i.test(path);
                  const blockedPath = /[/](login|register|account|logout|cart|checkout|user)[/]/i.test(path);
                  const mediaCard = !!a.querySelector('img, video, picture') ||
                    !!a.closest('article, figure, [class*="card"], [class*="post"], [class*="item"]');
                  if (blockedPath) return null;
                  if (!directMedia && !detailPath && !mediaCard && !taxonomyPath && !exhaustive) return null;
                  seen.add(url);
                  const title = (a.innerText || a.title || a.getAttribute('aria-label') ||
                    (a.querySelector('img') && a.querySelector('img').alt) || '').trim();
                  const haystack = (title + ' ' + url).toLowerCase();
                  const tokenHits = tokens.reduce((sum, token) =>
                    sum + (haystack.includes(token) ? 1 : 0), 0);
                  const exact = keyword.length > 0 && haystack.includes(keyword);
                  const tier = exact ? 2 : (tokenHits > 0 ? 1 : 0);
                  const score = (exact ? 100000 : 0) +
                    tokenHits * 5000 +
                    (directMedia ? 80000 : 0) +
                    (detailPath ? 50000 : 0) +
                    (mediaCard ? 20000 : 0) +
                    Math.max(0, 2000 - order);
                  return {url, title: title || document.title || url, score, tier, order,
                    scopeOnly: !directMedia && !detailPath &&
                      (taxonomyPath || (exhaustive && !mediaCard))};
                } catch (_) { return null; }
              }).filter(Boolean).sort((a,b) => b.score - a.score).slice(0, $limit);
            })()
          ''',
        );
        final candidates = <Map<String, String>>[];
        final discoveryQueue = task['discoveryPageQueue'] as List<String>;
        final queuedDiscoveryUrls = task['queuedDiscoveryUrls'] as Set<String>;
        final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
        final hasKeyword = (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final loadedUri = Uri.tryParse(loadedUrl);
        final isSearchResultsPage =
            loadedUri != null &&
            (loadedUri.pathSegments.contains('search') ||
                loadedUri.queryParameters.containsKey('s') ||
                loadedUri.queryParameters.containsKey('q'));
        final taskHost = (task['host'] ?? '').toString();
        final isKeywordFirst91 =
            taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com');
        final requiredTier =
            !hasKeyword || (isSearchResultsPage && !isKeywordFirst91)
                ? 0
                : exhaustiveCycle
                ? 0
                : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
        if (result is List) {
          for (final row in result) {
            if (row is Map && row['url'] != null) {
              final rowUrl = row['url'].toString();
              if (isKeywordFirst91 && !_is91ContentPage(rowUrl)) continue;
              if (row['scopeOnly'] == true) {
                if (isKeywordFirst91) {
                  final rowUri = Uri.tryParse(rowUrl);
                  final segments = rowUri?.pathSegments ?? const <String>[];
                  final isSameKeywordSearch =
                      segments.length >= 2 &&
                      segments.first.toLowerCase() == 'search' &&
                      segments[1].trim().toLowerCase() ==
                          (task['keyword'] ?? '')
                              .toString()
                              .trim()
                              .toLowerCase();
                  if (!isSameKeywordSearch) continue;
                }
                if (discoveryQueue.length < 300 &&
                    queuedDiscoveryUrls.add(rowUrl)) {
                  discoveryQueue.add(rowUrl);
                }
                continue;
              }
              final tier = int.tryParse((row['tier'] ?? '0').toString()) ?? 0;
              if (tier < requiredTier) continue;
              candidates.add({
                'url': rowUrl,
                'title': (row['title'] ?? '').toString(),
                'tier': '$tier',
                'order': (row['order'] ?? '0').toString(),
              });
            }
          }
        }
        if (isKeywordFirst91) {
          // Preserve the visible search-result order. The first 91 result is
          // commonly stale or promoted, so begin with the second card.
          candidates.sort((left, right) {
            final leftOrder = int.tryParse(left['order'] ?? '') ?? 0;
            final rightOrder = int.tryParse(right['order'] ?? '') ?? 0;
            return leftOrder.compareTo(rightOrder);
          });
          if (candidates.isNotEmpty) {
            final skipped = candidates.removeAt(0);
            (task['visitedPageUrls'] as Set<String>).add(skipped['url'] ?? '');
            debugPrint('Smart 91: skipped first search card ${skipped['url']}');
          }
          int searchPageNumber(String value) {
            final segments = Uri.tryParse(value)?.pathSegments ?? const [];
            for (final segment in segments.reversed) {
              final number = int.tryParse(segment);
              if (number != null) return number;
            }
            return 1;
          }

          discoveryQueue.sort(
            (left, right) =>
                searchPageNumber(left).compareTo(searchPageNumber(right)),
          );
        }
        final activeStrategy =
            (task['activeDiscoveryStrategy'] ?? '').toString();
        if (<String>{
          'actual_scope_link',
          'site_search',
          'synthetic_route',
        }.contains(activeStrategy)) {
          _recordSmartStrategyOutcome(
            task,
            activeStrategy,
            success: candidates.isNotEmpty,
          );
        }
        if (candidates.isEmpty) {
          // Some sites render playable cards through CSS/JavaScript and expose
          // no useful detail links to the source scanner. Exhaust real cards
          // on the current productive page before guessing another route.
          if (await _openNearestSmartMediaCard(task, loadedUrl)) return;
          if (_allowSmartExploratoryClick(task) &&
              await _openExploratorySmartTarget(task, loadedUrl)) {
            return;
          }
          _broadenSmartDiscovery(task, '当前搜索路径没有候选');
          return;
        }
        task['candidates'] = candidates;
        task['candidateListUrl'] = strict91Mode ? strict91SearchUrl : loadedUrl;
        if (strict91Mode) task['strict91QueueReady'] = true;
        task['index'] = 0;
        task['phase'] = 'visiting_candidate';
        _visitNextSmartCandidate(task);
        return;
      }

      if (phase == 'visiting_candidate' ||
          phase == 'visiting_seed' ||
          phase == 'visiting_clicked_card' ||
          phase == 'x_viewing_search_card' ||
          phase == 'scanning_feed') {
        await _refreshMixedSmartMediaType(task);
        final candidatePreheated =
            phase == 'visiting_candidate' &&
            task.remove('nextMediaPreheated') == true;
        if (candidatePreheated) task['nextMediaStatus'] = '马上下载';
        await Future<void>.delayed(
          Duration(
            milliseconds:
                phase == 'visiting_seed'
                    ? 250
                    : phase == 'scanning_feed'
                    ? 400
                    : phase == 'visiting_clicked_card' && is91KeywordTask
                    ? 1200
                    : (candidatePreheated ? 180 : 450),
          ),
        );
        final successBefore = task['success'] as int;
        if (!strict91Mode) {
          unawaited(_preheatNextSmartMedia(task, phase));
        }
        if (task['mediaType'] == MediaType.image) {
          await _downloadSmartImagesFromCurrentPage(task);
          if (phase == 'visiting_clicked_card') {
            final strategy = (task['activeDiscoveryStrategy'] ?? '').toString();
            if (strategy == 'click_media_card' ||
                strategy == 'exploratory_click') {
              _recordSmartStrategyOutcome(
                task,
                strategy,
                success: (task['success'] as int) > successBefore,
              );
            }
          }
          if (_smartDownloadTask == null) return;
          if (strictXFeedMode &&
              phase == 'scanning_feed' &&
              (task['strictXSearchUrl'] ?? '').toString().isNotEmpty &&
              (task['success'] as int) == successBefore &&
              await _openActiveXSmartCard(task)) {
            return;
          }
          if ((task['success'] as int) >= (task['target'] as int)) {
            await _finishSmartDownload();
          } else if (phase == 'x_viewing_search_card') {
            await _returnFromXSmartCard(task);
          } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
            _continueSmartFeed(
              task,
              madeProgress: (task['success'] as int) > successBefore,
            );
          } else {
            _visitNextSmartCandidate(task);
          }
          return;
        }
        final scopeDiscoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final scopeHasKeyword =
            (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final preferSeedScope =
            !scopeHasKeyword &&
            task['startedFromCurrentPage'] == true &&
            scopeDiscoveryRound == 0;
        final preferSeedMedia =
            phase == 'visiting_seed' ||
            (strictXFeedMode && phase == 'scanning_feed');
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const preferSeedScope = $preferSeedScope;
              const preferSeedMedia = $preferSeedMedia;
              const allVideos = Array.from(document.querySelectorAll('video'));
              const activeXScope = $strictXFeedMode
                ? document.querySelector('[data-app-smart-x-active="1"]')
                : null;
              const scope = activeXScope || (preferSeedScope
                ? document.querySelector('[data-smart-seed-scope="1"]')
                : null);
              const scopedVideos = scope
                ? Array.from(scope.querySelectorAll('video'))
                : [];
              // In X's immersive viewer adjacent posts are preloaded. Once an
              // active scope exists, never fall back to those page-wide nodes.
              const videos = scope ? scopedVideos : allVideos;
              const visible = videos.filter(v => {
                const r = v.getBoundingClientRect();
                return r.width > 80 && r.height > 60 && r.bottom > 0 && r.top < innerHeight;
              });
              const seed = preferSeedMedia
                ? (scope?.querySelector('video[data-smart-seed-media="1"]') ||
                    document.querySelector('video[data-smart-seed-media="1"]'))
                : null;
              const video = seed || (visible.length ? visible : videos).sort((a,b) => {
                const ar = a.getBoundingClientRect();
                const br = b.getBoundingClientRect();
                const ad = Math.abs(ar.top + ar.height / 2 - innerHeight / 2);
                const bd = Math.abs(br.top + br.height / 2 - innerHeight / 2);
                return ad - bd || (b.clientWidth*b.clientHeight) - (a.clientWidth*a.clientHeight);
              })[0];
              if (!video) return {hasVideo:false, candidates:[]};
              try { video.muted = true; video.play().catch(() => {}); } catch (_) {}
              const urls = [video.currentSrc, video.src,
                ...Array.from(video.querySelectorAll('source')).map(s => s.src)]
                .filter(Boolean);
              const currentTweet = (() => {
                try { return new URL(location.href).searchParams.get('currentTweet') || ''; }
                catch (_) { return ''; }
              })();
              let nearby = video.closest(
                'article, figure, [class*="card"], [class*="item"], [class*="post"], [role="dialog"]'
              );
              if ($strictXFeedMode && currentTweet && !activeXScope) {
                const currentLink = Array.from(document.querySelectorAll('a[href*="/status/"]'))
                  .find(link => String(link.href || '').includes('/status/' + currentTweet));
                nearby = (currentLink && currentLink.closest(
                  'article[data-testid="tweet"], article, [role="dialog"], main'
                )) || nearby;
              }
              const xMediaIdFromScope = scope => {
                if (!scope) return '';
                const values = [];
                const add = value => { if (value) values.push(String(value)); };
                Array.from(scope.querySelectorAll('video, img')).forEach(media => {
                  add(media.poster); add(media.getAttribute && media.getAttribute('poster'));
                  if (String(media.tagName || '').toLowerCase() === 'img') {
                    add(media.currentSrc); add(media.src);
                    add(media.getAttribute && media.getAttribute('src'));
                    add(media.getAttribute && media.getAttribute('srcset'));
                  }
                });
                for (const value of values) {
                  const lower = value.toLowerCase();
                  for (const marker of ['/amplify_video_thumb/', '/ext_tw_video_thumb/',
                    '/tweet_video_thumb/', '/amplify_video/', '/ext_tw_video/', '/tweet_video/']) {
                    const index = lower.indexOf(marker);
                    if (index < 0) continue;
                    const id = value.substring(index + marker.length).split('/')[0];
                    if (id && Array.from(id).every(ch => ch >= '0' && ch <= '9')) return id;
                  }
                }
                return '';
              };
              const expectedXMediaId = $strictXFeedMode
                ? (xMediaIdFromScope(video) || xMediaIdFromScope(scope) ||
                    xMediaIdFromScope(nearby || video.parentElement))
                : '';
              const contextText = [video.title, video.getAttribute('aria-label'),
                nearby && nearby.innerText, document.title].filter(Boolean).join(' ');
              const elementIdentity = [
                video.getAttribute('data-id'), video.getAttribute('data-video-id'),
                video.getAttribute('data-post-id'), nearby && nearby.id,
                nearby && nearby.getAttribute('data-id'),
                nearby && nearby.getAttribute('data-post-id'),
                nearby && nearby.querySelector('a[href]')?.href
              ].filter(Boolean).join('|');
              const adContainers = Array.from(document.querySelectorAll(
                '[class*="video-ad" i], [class*="ad-container" i], [class*="ad-overlay" i], '
                + '[class*="preroll" i], [class*="pre-roll" i], [class*="vast" i], '
                + '[id*="video-ad" i], [id*="ad-container" i], [id*="preroll" i]'
              )).filter(el => {
                const r = el.getBoundingClientRect();
                return r.width > 20 && r.height > 10 && r.bottom > 0 && r.top < innerHeight;
              });
              const skipButton = Array.from(document.querySelectorAll(
                'button, [role="button"], a'
              )).find(el => {
                const r = el.getBoundingClientRect();
                if (r.width < 20 || r.height < 10 || r.bottom <= 0 || r.top >= innerHeight) return false;
                const label = (el.innerText || el.getAttribute('aria-label') || el.title || '').trim();
                return /^(skip|skip ad|跳过|跳过广告|关闭广告)/i.test(label);
              });
              if (skipButton) { try { skipButton.click(); } catch (_) {} }
              const adText = adContainers.map(el =>
                [el.id, el.className, el.innerText].join(' ')).join(' ').toLowerCase();
              const adLikely = adContainers.length > 0 &&
                /(video.?ad|ad.?container|ad.?overlay|preroll|pre.?roll|vast|广告|advertisement)/i.test(adText);
              return {hasVideo:true, url: urls[0] || '', candidates: Array.from(new Set(urls)),
                duration: Number.isFinite(video.duration) ? video.duration : 0,
                currentTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
                title: document.title || location.href, contextText, elementIdentity,
                expectedXMediaId,
                adLikely, skipClicked: !!skipButton};
            })()
          ''',
        );
        var ok = false;
        final pageUrl = loadedUrl.isNotEmpty ? loadedUrl : _currentUrl;
        final urls = <String>[];
        var title = pageUrl;
        var contextText = '';
        var elementIdentity = '';
        var durationSec = 0.0;
        var currentTimeSec = 0.0;
        var adLikely = false;
        var expectedXMediaId = '';
        if (result is Map) {
          final rawCandidates = result['candidates'];
          if (rawCandidates is List) {
            urls.addAll(rawCandidates.map((e) => e.toString()));
          }
          final primary = (result['url'] ?? '').toString();
          if (primary.isNotEmpty) urls.insert(0, primary);
          title = (result['title'] ?? pageUrl).toString();
          contextText = (result['contextText'] ?? '').toString();
          elementIdentity = (result['elementIdentity'] ?? '').toString();
          durationSec = (result['duration'] as num?)?.toDouble() ?? 0.0;
          currentTimeSec = (result['currentTime'] as num?)?.toDouble() ?? 0.0;
          adLikely = result['adLikely'] == true;
          expectedXMediaId =
              (result['expectedXMediaId'] ?? '').toString().trim();
        }
        if (adLikely) {
          final now = DateTime.now();
          final waitStarted = task['adWaitStartedAt'] as DateTime? ?? now;
          task['adWaitStartedAt'] = waitStarted;
          final waited = now.difference(waitStarted);
          if (waited < const Duration(seconds: 60)) {
            final remaining =
                durationSec > currentTimeSec
                    ? max(0, (durationSec - currentTimeSec).ceil())
                    : 0;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '已识别前贴片广告，等待主视频${remaining > 0 ? '（约 $remaining 秒）' : ''}...',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 1500),
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
            return;
          }
          task.remove('adWaitStartedAt');
          task['adSkipped'] = ((task['adSkipped'] as int?) ?? 0) + 1;
          if (phase == 'visiting_clicked_card') {
            await _returnFromSmartMediaCard(task, madeProgress: false);
          } else if (phase == 'visiting_candidate') {
            _visitNextSmartCandidate(task);
          } else {
            _continueSmartFeed(task, madeProgress: false);
          }
          return;
        }
        task.remove('adWaitStartedAt');
        final lastFeedMoveAt = task['lastFeedMoveAt'] as DateTime?;
        final freshCaptured =
            lastFeedMoveAt == null
                ? const <String>[]
                : _recentCapturedMediaCandidates(
                  MediaType.video,
                  pageUrl: pageUrl,
                  notBefore: lastFeedMoveAt,
                );
        final captured = <String>[
          ...(strict91Mode
              ? freshCaptured
              : freshCaptured.isNotEmpty
              ? freshCaptured
              : _recentCapturedMediaCandidates(
                MediaType.video,
                pageUrl: pageUrl,
              )),
        ];
        if (_isXPlatformPage(pageUrl)) {
          var boundMediaIds =
              expectedXMediaId.isNotEmpty
                  ? <String>{expectedXMediaId}
                  : urls
                      .map(_xMediaIdentity)
                      .where((id) => id.isNotEmpty)
                      .toSet();
          if (boundMediaIds.isEmpty && strictXFeedMode) {
            final grouped = <String, List<String>>{};
            for (final url in freshCaptured) {
              final id = _xMediaIdentity(url);
              if (id.isNotEmpty) (grouped[id] ??= <String>[]).add(url);
            }
            if (grouped.isNotEmpty) {
              final ranked =
                  grouped.entries.toList()..sort((left, right) {
                    int score(MapEntry<String, List<String>> entry) {
                      final rows = entry.value;
                      final hasMaster = rows.any(
                        (url) => RegExp(
                          r'/pl/[^/]+\.m3u8(?:\?|$)',
                        ).hasMatch(url.toLowerCase()),
                      );
                      final hasVideo = rows.any(
                        (url) =>
                            url.contains('/avc1/') || url.contains('/vid/'),
                      );
                      final hasAudio = rows.any(
                        (url) =>
                            url.contains('/mp4a/') || url.contains('/aud/'),
                      );
                      return (hasMaster ? 10000 : 0) +
                          (hasVideo ? 3000 : 0) +
                          (hasAudio ? 1000 : 0) +
                          rows.length * 10;
                    }

                    return score(right).compareTo(score(left));
                  });
              boundMediaIds = <String>{ranked.first.key};
            }
          }
          if (expectedXMediaId.isNotEmpty) {
            urls.removeWhere((url) {
              final id = _xMediaIdentity(url);
              return id.isNotEmpty && id != expectedXMediaId;
            });
          }
          if (boundMediaIds.isNotEmpty) {
            captured.retainWhere(
              (url) => boundMediaIds.contains(_xMediaIdentity(url)),
            );
          } else {
            // X preloads adjacent posts. Without an element-bound media ID,
            // page-wide traffic is not safe enough to select a download.
            captured.clear();
          }
          if (strictXFeedMode && expectedXMediaId.isNotEmpty) {
            final resolved = await _resolveXLongPressVideoCandidates(
              primaryUrl: urls.isEmpty ? '' : urls.first,
              candidates: <String>[...urls, ...captured],
              pageUrl: pageUrl,
              expectedMediaId: expectedXMediaId,
              notBefore: lastFeedMoveAt,
            );
            if (resolved.isNotEmpty) {
              urls
                ..clear()
                ..addAll(resolved);
              captured.clear();
            }
          }
        }
        if ((strict91Mode || _isElementBoundFeedPage(pageUrl)) &&
            captured.isNotEmpty) {
          urls.insertAll(0, captured);
        } else {
          urls.addAll(captured);
        }
        urls.removeWhere((url) => url.trim().isEmpty);
        urls.removeWhere(_isLikelyAdUrl);
        final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
        final uniqueUrls =
            urls
                .toSet()
                .where(
                  (url) =>
                      !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
                )
                .toList();
        if (_isXPlatformPage(pageUrl)) {
          uniqueUrls.sort(
            (left, right) => _scoreXVideoCandidate(
              right,
            ).compareTo(_scoreXVideoCandidate(left)),
          );
        }
        if (uniqueUrls.isEmpty &&
            phase == 'visiting_clicked_card' &&
            is91KeywordTask &&
            _is91ContentPage(pageUrl)) {
          final retries = (task['candidateResolveRetries'] as int?) ?? 0;
          final enteredAt =
              task['cardEnteredAt'] as DateTime? ?? DateTime.now();
          task['cardEnteredAt'] = enteredAt;

          // Some 91 players expose the real address only after play/visibility.
          await controller.evaluateJavascript(
            source: '''
              (() => {
                const videos = Array.from(document.querySelectorAll('video'));
                const video = videos.find(v => {
                  const r = v.getBoundingClientRect();
                  return r.width > 80 && r.height > 60;
                }) || videos[0];
                if (video) {
                  video.scrollIntoView({behavior:'auto', block:'center'});
                  video.muted = true;
                  try { video.load(); } catch (_) {}
                  try { video.play().catch(() => {}); } catch (_) {}
                }
                const play = Array.from(document.querySelectorAll(
                  'button, [role="button"], .play, [class*="play"]'
                )).find(el => {
                  const r = el.getBoundingClientRect();
                  const text = (el.innerText || el.title || el.getAttribute('aria-label') || '').trim();
                  return r.width > 20 && r.height > 20 &&
                    /(play|播放|开始)/i.test([text, el.className].join(' '));
                });
                if (play) { try { play.click(); } catch (_) {} }
                return {videos: videos.length, clickedPlay: !!play};
              })()
            ''',
          );

          if (retries == 2 || retries == 6) {
            final sourceUrls = await _resniffFavoriteCandidatesFromSourcePage(
              pageUrl,
            ).timeout(const Duration(seconds: 7), onTimeout: () => <String>[]);
            uniqueUrls.addAll(
              sourceUrls.where(
                (url) =>
                    !_isLikelyAdUrl(url) &&
                    !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
              ),
            );
          }

          final elapsed = DateTime.now().difference(enteredAt);
          if (uniqueUrls.isEmpty &&
              retries < 15 &&
              elapsed < const Duration(seconds: 25)) {
            task['candidateResolveRetries'] = retries + 1;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '正在深入解析当前关键词卡片 ${retries + 1}/15 · 已停留 ${elapsed.inSeconds} 秒',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 1000),
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
            return;
          }
        }
        if (uniqueUrls.isEmpty &&
            strictXFeedMode &&
            (phase == 'visiting_seed' ||
                phase == 'scanning_feed' ||
                phase == 'x_viewing_search_card')) {
          final retries = (task['xCurrentPostResolveRetries'] as int?) ?? 0;
          final retryLimit =
              phase == 'scanning_feed' &&
                      (task['strictXSearchUrl'] ?? '').toString().isNotEmpty
                  ? 3
                  : 12;
          if (retries < retryLimit) {
            task['xCurrentPostResolveRetries'] = retries + 1;
            final id = (task['discoveryTaskId'] ?? '').toString();
            if (id.isNotEmpty) {
              _updateDownloadTask(
                id,
                progressDetail:
                    '正在当前 X 帖子内等待真实视频地址 ${retries + 1}/$retryLimit，不会继续下滑...',
              );
            }
            Future<void>.delayed(
              const Duration(milliseconds: 800),
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
            return;
          }
          task['xCurrentPostResolveRetries'] = 0;
          if (phase == 'scanning_feed' &&
              (task['strictXSearchUrl'] ?? '').toString().isNotEmpty &&
              await _openActiveXSmartCard(task)) {
            return;
          }
          if (phase == 'x_viewing_search_card') {
            await _returnFromXSmartCard(task);
            return;
          }
          _continueSmartFeed(task, madeProgress: false);
          return;
        }
        task['xCurrentPostResolveRetries'] = 0;
        if (uniqueUrls.isEmpty &&
            (phase == 'visiting_seed' || phase == 'scanning_feed')) {
          if (await _openNearestSmartMediaCard(task, pageUrl)) return;
        }
        if (uniqueUrls.isEmpty && phase == 'visiting_candidate') {
          final retries = (task['candidateResolveRetries'] as int?) ?? 0;
          final retryLimit = min(5, 2 + ((task['searchCycle'] as int?) ?? 0));
          if (retries < retryLimit) {
            task['candidateResolveRetries'] = retries + 1;
            Future<void>.delayed(
              const Duration(milliseconds: 650),
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
            return;
          }
        }
        task['candidateResolveRetries'] = 0;
        task.remove('cardEnteredAt');
        final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
        final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
        final hasKeyword = (task['keyword'] ?? '').toString().trim().isNotEmpty;
        final trustedXKeywordResult =
            strictXFeedMode &&
            hasKeyword &&
            strictXSearchUrl.isNotEmpty &&
            (phase == 'scanning_feed' || phase == 'x_viewing_search_card');
        final requiredTier =
            !hasKeyword || trustedXKeywordResult
                ? 0
                : exhaustiveCycle
                ? 0
                : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
        final contextTier = _smartKeywordMatchTier(
          (task['keyword'] ?? '').toString(),
          '$title $contextText $pageUrl',
        );
        if (phase != 'visiting_seed' && contextTier < requiredTier) {
          task['relevanceSkipped'] =
              ((task['relevanceSkipped'] as int?) ?? 0) + 1;
          _updateSmartDiscoveryProgress(task, phase);
          if (phase == 'visiting_clicked_card') {
            await _returnFromSmartMediaCard(task, madeProgress: false);
          } else if (phase == 'scanning_feed') {
            if (!strictXFeedMode &&
                await _openNearestSmartMediaCard(task, pageUrl)) {
              return;
            }
            _continueSmartFeed(task, madeProgress: false);
          } else {
            _visitNextSmartCandidate(task);
          }
          return;
        }
        if (uniqueUrls.isNotEmpty) {
          final chosen = uniqueUrls.first;
          final normalizedChosen = _normalizeVideoSourceUrl(chosen);
          final normalizedContext =
              contextText.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
          final normalizedTitle = title.trim().toLowerCase();
          final meaningfulContext =
              normalizedContext.length >= 8 &&
              normalizedContext != normalizedTitle;
          final pagePath = Uri.tryParse(pageUrl)?.path ?? pageUrl;
          final stableElementIdentity = elementIdentity.trim();
          final contextPart =
              meaningfulContext
                  ? normalizedContext.substring(
                    0,
                    min(180, normalizedContext.length),
                  )
                  : normalizedChosen;
          final mediaContextKey =
              _isElementBoundFeedPage(pageUrl)
                  ? '$pagePath|$stableElementIdentity|${durationSec.round()}|$contextPart'
                  : normalizedChosen;
          final attemptedContexts =
              task['attemptedVideoContexts'] as Set<String>;
          if (!attemptedContexts.add(mediaContextKey)) {
            task['duplicateSkipped'] =
                ((task['duplicateSkipped'] as int?) ?? 0) + 1;
            _updateSmartDiscoveryProgress(task, phase);
            if (phase == 'visiting_seed' || phase == 'scanning_feed') {
              if (!strictXFeedMode &&
                  await _openNearestSmartMediaCard(task, pageUrl)) {
                return;
              }
              _continueSmartFeed(task, madeProgress: false);
            } else if (phase == 'visiting_clicked_card') {
              await _returnFromSmartMediaCard(task, madeProgress: false);
            } else {
              _visitNextSmartCandidate(task);
            }
            return;
          }
          final sizeAllowed = await _smartVideoSizeAllowed(
            task,
            uniqueUrls,
            pageUrl,
            durationSec,
          );
          if (sizeAllowed) {
            final seen = task['seenMediaUrls'] as Set<String>;
            final canTrustUrlIdentity =
                chosen.startsWith('http') && !_isElementBoundFeedPage(pageUrl);
            if (!canTrustUrlIdentity || seen.add(chosen)) {
              var smartFailureType = '';
              _showSmartOperation('模拟长按当前视频，开始下载');
              ok = await _downloadMediaRobustly(
                item: <String, dynamic>{
                  'title': title,
                  'pageUrl': pageUrl,
                  'videoUrl': chosen,
                  'candidateUrls': uniqueUrls,
                  'durationSec': durationSec,
                  'downloadOrigin': 'smart_batch',
                  'allowSourceUrlReuse': _isElementBoundFeedPage(pageUrl),
                  'smartTask': task,
                },
                showModalDialog: false,
                showResultHint: false,
                onFailureType: (type) => smartFailureType = type,
                minFileBytes: task['effectiveMinVideoBytes'] as int?,
                maxFileBytes: task['effectiveMaxVideoBytes'] as int?,
              );
              if (smartFailureType == 'outside_requested_size_range') {
                task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
              } else if (smartFailureType == 'invalid_smart_media_content') {
                task['invalidSkipped'] =
                    ((task['invalidSkipped'] as int?) ?? 0) + 1;
              } else if (smartFailureType == 'already_in_library' ||
                  smartFailureType == 'already_in_smart_task') {
                duplicateUrlKeys.add(normalizedChosen);
                task['duplicateSkipped'] =
                    ((task['duplicateSkipped'] as int?) ?? 0) + 1;
              }
            }
          } else {
            task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
          }
        }
        task[ok ? 'success' : 'failed'] =
            (task[ok ? 'success' : 'failed'] as int) + 1;
        if (phase == 'visiting_clicked_card') {
          final strategy = (task['activeDiscoveryStrategy'] ?? '').toString();
          if (strategy == 'click_media_card' ||
              strategy == 'exploratory_click') {
            _recordSmartStrategyOutcome(task, strategy, success: ok);
          }
        }
        _updateSmartDiscoveryProgress(task, phase);
        if ((task['success'] as int) >= (task['target'] as int)) {
          await _finishSmartDownload();
        } else if (phase == 'x_viewing_search_card') {
          await _returnFromXSmartCard(task);
        } else if (phase == 'visiting_clicked_card') {
          await _returnFromSmartMediaCard(
            task,
            madeProgress: (task['success'] as int) > successBefore,
          );
        } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
          if (!ok &&
              !strictXFeedMode &&
              await _openNearestSmartMediaCard(task, pageUrl)) {
            return;
          }
          _continueSmartFeed(
            task,
            madeProgress: (task['success'] as int) > successBefore,
          );
        } else {
          _visitNextSmartCandidate(task);
        }
      }
    } catch (e, st) {
      debugPrint('智能下载步骤失败: $e\n$st');
      if (_smartDownloadTask != null) {
        task['failed'] = (task['failed'] as int) + 1;
        final phase = task['phase']?.toString();
        if (phase == 'visiting_clicked_card') {
          await _returnFromSmartMediaCard(task, madeProgress: false);
        } else if (phase == 'x_viewing_search_card') {
          await _returnFromXSmartCard(task);
        } else if (phase == 'visiting_seed' || phase == 'scanning_feed') {
          _continueSmartFeed(task, madeProgress: false);
        } else {
          _visitNextSmartCandidate(task);
        }
      }
    } finally {
      _smartDownloadAdvancing = false;
    }
  }

  Future<bool> _recoverSmartDownloadErrorPage(
    Map<String, dynamic> task,
    String loadedUrl,
  ) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) {
      return false;
    }
    try {
      final result = await controller
          .evaluateJavascript(
            source: '''
              (() => {
                const title = (document.title || '').trim();
                const heading = (document.querySelector('h1, h2')?.textContent || '').trim();
                const body = (document.body?.innerText || '').slice(0, 1600);
                const text = [title, heading, body].join(' ').toLowerCase();
                const cards = Array.from(document.querySelectorAll(
                  'a[href], article, figure, [class*="card"], [class*="post"], [class*="item"]'
                )).filter(el => {
                  const media = el.querySelector?.('img, video, picture, [style*="background-image"]');
                  const target = media || el;
                  const r = target.getBoundingClientRect();
                  if (r.width < 100 || r.height < 70) return false;
                  const marker = [el.id, el.className, el.innerText].join(' ').toLowerCase();
                  return !!media || /(video|thumb|cover|poster|card|post|item)/i.test(marker);
                }).length;
                const strongError = /(?:^|\s)(404|403)(?:\s|\$)|not\s+found|page\s+not\s+found|页面不存在|找不到页面|访问的页面不存在|内容不存在/i;
                const errorPage = strongError.test([title, heading].join(' ').toLowerCase()) ||
                  (cards === 0 && strongError.test(text));
                return {errorPage, cards};
              })()
            ''',
          )
          .timeout(const Duration(seconds: 4));
      if (result is! Map) return false;
      final cardCount = (result['cards'] as num?)?.toInt() ?? 0;
      final isErrorPage = result['errorPage'] == true;
      if (!isErrorPage && cardCount > 0 && loadedUrl.startsWith('http')) {
        final previousProductive =
            (task['lastProductiveListUrl'] ?? '').toString();
        task['lastProductiveListUrl'] = loadedUrl;
        if (previousProductive != loadedUrl) {
          final strategy = (task['activeDiscoveryStrategy'] ?? '').toString();
          if (strategy.isNotEmpty) {
            _recordSmartStrategyOutcome(task, strategy, success: true);
          }
        }
      }
      if (!isErrorPage) return false;
      final failures = ((task['syntheticRouteFailures'] as int?) ?? 0) + 1;
      task['syntheticRouteFailures'] = failures;
      _recordSmartStrategyOutcome(task, 'synthetic_route', success: false);
      if (failures >= 2) task['disableSyntheticRoutes'] = true;
      final siteUri = Uri.tryParse((task['siteUrl'] ?? '').toString());
      final fallback =
          (task['lastProductiveListUrl'] ?? siteUri?.origin ?? task['siteUrl'])
              .toString();
      task['phase'] = 'collecting_site_results';
      task['activeDiscoveryStrategy'] = 'actual_scope_link';
      final id = (task['discoveryTaskId'] ?? '').toString();
      if (id.isNotEmpty) {
        _updateDownloadTask(
          id,
          progressDetail: '已识别无效/404 路径，返回有媒体卡片的页面继续挖掘...',
        );
      }
      if (fallback.isNotEmpty && fallback != loadedUrl) {
        _loadUrl(fallback);
      } else if (siteUri != null) {
        _loadUrl(siteUri.origin);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _updateSmartDiscoveryProgress(Map<String, dynamic> task, String phase) {
    final id = (task['discoveryTaskId'] ?? '').toString();
    if (id.isEmpty) return;
    final success = task['success'] as int;
    final target = task['target'] as int;
    final sizeSkipped = (task['sizeSkipped'] as int?) ?? 0;
    final invalidSkipped = (task['invalidSkipped'] as int?) ?? 0;
    final duplicateSkipped = (task['duplicateSkipped'] as int?) ?? 0;
    final recent24hSkipped = (task['recent24hSkipped'] as int?) ?? 0;
    final adSkipped = (task['adSkipped'] as int?) ?? 0;
    final skippedParts = <String>[
      if (sizeSkipped > 0) '大小不符 $sizeSkipped',
      if (invalidSkipped > 0) '无效媒体 $invalidSkipped',
      if (duplicateSkipped > 0)
        '已跳过重复 $duplicateSkipped${recent24hSkipped > 0 ? '（近24小时 $recent24hSkipped）' : ''}',
      if (adSkipped > 0) '广告页 $adSkipped',
    ];
    final skippedText =
        skippedParts.isEmpty ? '' : ' · ${skippedParts.join(' · ')}';
    final matchStage = (task['matchStage'] ?? '精确匹配').toString();
    final progress = (0.02 + (success / max(1, target)) * 0.93).clamp(
      0.02,
      0.95,
    );
    final detail = switch (phase) {
      'visiting_seed' => '$matchStage · 正在解析当前媒体地址...',
      'scanning_feed' =>
        '$matchStage · 正在扫描信息流 ${(task['feedScans'] as int) + 1} · 已保存 $success/$target$skippedText',
      'opening_site' =>
        '$matchStage · 正在定位站内搜索入口 · 已保存 $success/$target$skippedText',
      'collecting_site_results' =>
        '$matchStage · 正在收集站内候选地址 · 已保存 $success/$target$skippedText',
      'collecting_search_results' =>
        '$matchStage · 正在收集站内候选地址 · 已保存 $success/$target$skippedText',
      'visiting_candidate' =>
        '$matchStage · 正在解析候选 ${task['index'] as int}/ ${(task['candidates'] as List).length} · 已保存 $success/$target$skippedText',
      _ => '$matchStage · 正在智能采集 · 已保存 $success/$target$skippedText',
    };
    _updateDownloadTask(id, progress: progress, progressDetail: detail);
  }

  String _smartMediaNameKey(
    String mediaUrl, {
    String title = '',
    String pageUrl = '',
  }) {
    final uri = Uri.tryParse(mediaUrl);
    var name = '';
    if (uri != null) {
      try {
        name = Uri.decodeComponent(p.basename(uri.path));
      } catch (_) {
        name = p.basename(uri.path);
      }
    }
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (name.isEmpty) {
      name = title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    }
    if (name.isEmpty) return '';
    final genericName = RegExp(
      r'^(?:master|index|playlist|manifest|video|full|stream|media)(?:[._-]\d+)?\.(?:m3u8|mpd|mp4|webm|mov)$',
      caseSensitive: false,
    ).hasMatch(name);
    if (!genericName) return name;
    final normalizedTitle =
        title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (normalizedTitle.isNotEmpty &&
        !normalizedTitle.startsWith('http://') &&
        !normalizedTitle.startsWith('https://')) {
      return '$name|$normalizedTitle';
    }
    final pagePath = Uri.tryParse(pageUrl)?.path.toLowerCase() ?? pageUrl;
    return '$name|$pagePath';
  }

  String _smartMediaTitleKey(String title) {
    var value = title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (value.isEmpty ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return '';
    }
    value = value.replaceAll(
      RegExp(r'\s*[|｜_-]\s*(?:91吃瓜网|91cg|首页)\s*$', caseSensitive: false),
      '',
    );
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 4 ||
        RegExp(
          r'^(?:video|media|播放|视频|首页|详情|91吃瓜网|91cg)$',
          caseSensitive: false,
        ).hasMatch(compact)) {
      return '';
    }
    return value;
  }

  bool _reserveSmartMediaName(
    Map<String, dynamic> task,
    String mediaUrl, {
    String title = '',
    String pageUrl = '',
  }) {
    final key = _smartMediaNameKey(mediaUrl, title: title, pageUrl: pageUrl);
    final titleKey = _smartMediaTitleKey(title);
    if (key.isEmpty && titleKey.isEmpty) return true;
    final siteHost = (task['host'] ?? '').toString().toLowerCase();
    final sourceKey = _normalizeVideoSourceUrl(mediaUrl);
    final pageKey = _smartStablePageKey(pageUrl);
    final allowTitleIdentity = !_isElementBoundFeedPage(pageUrl);
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final foundIn24hRegistry = _smartDownload24hRegistry.any((row) {
      if ((row['siteHost'] ?? '').toString() != siteHost) return false;
      final savedAt = DateTime.tryParse((row['savedAt'] ?? '').toString());
      if (savedAt == null || savedAt.isBefore(cutoff)) return false;
      return (key.isNotEmpty && (row['nameKey'] ?? '').toString() == key) ||
          (allowTitleIdentity &&
              titleKey.isNotEmpty &&
              (row['titleKey'] ?? '').toString() == titleKey) ||
          (sourceKey.isNotEmpty &&
              (row['sourceKey'] ?? '').toString() == sourceKey) ||
          (pageKey.isNotEmpty && (row['pageKey'] ?? '').toString() == pageKey);
    });
    if (foundIn24hRegistry) {
      task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
      task['recent24hSkipped'] = ((task['recent24hSkipped'] as int?) ?? 0) + 1;
      return false;
    }
    final reservedNames = task['reservedMediaNameKeys'] as Set<String>;
    final reservedTitles = task['reservedMediaTitleKeys'] as Set<String>;
    final duplicateInTask =
        (key.isNotEmpty && reservedNames.contains(key)) ||
        (allowTitleIdentity &&
            titleKey.isNotEmpty &&
            reservedTitles.contains(titleKey));
    if (!duplicateInTask) {
      if (key.isNotEmpty) reservedNames.add(key);
      if (allowTitleIdentity && titleKey.isNotEmpty) {
        reservedTitles.add(titleKey);
      }
      return true;
    }
    task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
    return false;
  }

  void _releaseSmartMediaName(
    Map<String, dynamic> task,
    String mediaUrl, {
    String title = '',
    String pageUrl = '',
  }) {
    final key = _smartMediaNameKey(mediaUrl, title: title, pageUrl: pageUrl);
    final titleKey = _smartMediaTitleKey(title);
    if (key.isNotEmpty) {
      (task['reservedMediaNameKeys'] as Set<String>).remove(key);
    }
    if (titleKey.isNotEmpty) {
      (task['reservedMediaTitleKeys'] as Set<String>).remove(titleKey);
    }
  }

  Future<void> _preheatNextSmartMedia(
    Map<String, dynamic> task,
    String phase,
  ) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) return;
    try {
      var started = false;
      var nextLabel = '';
      if (phase == 'visiting_candidate') {
        final candidates = task['candidates'] as List<Map<String, String>>;
        final nextIndex = task['index'] as int;
        if (nextIndex >= candidates.length) {
          task.remove('nextMediaLabel');
          task.remove('nextMediaStatus');
          return;
        }
        unawaited(_preheatSmartCandidateAddresses(task, nextIndex));
        nextLabel = (candidates[nextIndex]['title'] ?? '').trim();
        if (nextLabel.isEmpty) nextLabel = '下一个站内候选';
        final nextUrlJson = jsonEncode(candidates[nextIndex]['url'] ?? '');
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const url = $nextUrlJson;
              if (!url) return false;
              try {
                const parsed = new URL(url, location.href);
                if (parsed.origin !== location.origin) return false;
                let link = document.querySelector('link[data-smart-prefetch="next"]');
                if (!link) {
                  link = document.createElement('link');
                  link.rel = 'prefetch';
                  link.dataset.smartPrefetch = 'next';
                  document.head.appendChild(link);
                }
                link.href = parsed.href;
                fetch(parsed.href, {credentials:'include', cache:'force-cache'})
                  .then(response => response.text()).catch(() => {});
                return true;
              } catch (_) { return false; }
            })()
          ''',
        );
        started = result == true || result.toString() == 'true';
      } else {
        final direction = (task['feedDirection'] as int?) ?? 1;
        final keywordEmpty = (task['keyword'] ?? '').toString().trim().isEmpty;
        final preferSeedScope =
            keywordEmpty &&
            task['startedFromCurrentPage'] == true &&
            ((task['discoveryRound'] as int?) ?? 0) == 0;
        final result = await controller.evaluateJavascript(
          source: '''
            (() => {
              const direction = $direction;
              const scope = $preferSeedScope
                ? document.querySelector('[data-smart-seed-scope="1"]')
                : null;
              const scoped = scope
                ? Array.from(scope.querySelectorAll('video, img'))
                    .filter(el => el.clientWidth > 100 && el.clientHeight > 80)
                : [];
              const all = (scoped.length > 1
                ? scoped
                : Array.from(document.querySelectorAll('video, img')))
                .filter(el => el.clientWidth > 100 && el.clientHeight > 80);
              const visible = all.filter(el => {
                const r = el.getBoundingClientRect();
                return r.bottom > 0 && r.top < innerHeight;
              }).sort((a, b) => {
                const ar = a.getBoundingClientRect();
                const br = b.getBoundingClientRect();
                return Math.abs(ar.top + ar.height / 2 - innerHeight / 2) -
                  Math.abs(br.top + br.height / 2 - innerHeight / 2);
              });
              const current = visible[0];
              const index = current ? all.indexOf(current) : -1;
              const next = index >= 0 ? all[index + direction] : null;
              if (!next) return {started:false};
              if (next.tagName === 'VIDEO') {
                next.preload = 'metadata';
                if (next.readyState < 1) { try { next.load(); } catch (_) {} }
              } else {
                next.loading = 'eager';
                next.decoding = 'async';
                const src = next.currentSrc || next.src || next.getAttribute('data-src');
                if (src) { const warm = new Image(); warm.src = src; }
              }
              const nearby = next.closest('article, figure, [class*="card"], [class*="item"], [class*="post"]');
              const label = (next.title || next.getAttribute('aria-label') ||
                (next.tagName === 'IMG' && next.alt) || nearby?.querySelector(
                  'h1, h2, h3, [class*="title"], [class*="caption"]'
                )?.textContent || (next.tagName === 'VIDEO' ? '相邻视频' : '相邻图片')).trim();
              return {started:true, label};
            })()
          ''',
        );
        if (result is Map) {
          started = result['started'] == true;
          nextLabel = (result['label'] ?? '').toString().trim();
        } else {
          started = result == true || result.toString() == 'true';
        }
      }
      if (!identical(_smartDownloadTask, task)) return;
      if (!started) {
        task.remove('nextMediaPreheated');
        task.remove('nextMediaLabel');
        task.remove('nextMediaStatus');
        return;
      }
      if (nextLabel.isEmpty) {
        nextLabel = task['mediaType'] == MediaType.image ? '下一张图片' : '下一个视频';
      }
      task['nextMediaPreheated'] = true;
      task['nextMediaLabel'] = nextLabel;
      task['nextMediaStatus'] = '待下载（已预热）';
      final id = (task['discoveryTaskId'] ?? '').toString();
      if (id.isNotEmpty) {
        _updateDownloadTask(
          id,
          progressDetail:
              '正在下载当前媒体，同时预热下一个 · 已保存 ${task['success']}/${task['target']}',
        );
      }
    } catch (e) {
      debugPrint('智能下载预热失败（不影响当前下载）: $e');
    }
  }

  Future<bool> _openNearestSmartMediaCard(
    Map<String, dynamic> task,
    String pageUrl,
  ) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) {
      return false;
    }
    final visited = task['clickedSmartCardKeys'] as Set<String>;
    final visitedJson = jsonEncode(visited.toList());
    final siteHostJson = jsonEncode((task['host'] ?? '').toString());
    final keyword = (task['keyword'] ?? '').toString().trim().toLowerCase();
    final keywordJson = jsonEncode(keyword);
    final keywordTokens =
        keyword
            .split(RegExp(r'[\s_\-.,/|:;]+'))
            .where((value) => value.length >= 2)
            .take(16)
            .toList();
    final keywordTokensJson = jsonEncode(keywordTokens);
    final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
    final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
    final requiredTier =
        keyword.isEmpty
            ? 0
            : exhaustiveCycle
            ? 0
            : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
    try {
      final result = await controller
          .evaluateJavascript(
            source: '''
          (() => {
            const visited = new Set($visitedJson);
            const siteHost = $siteHostJson;
            const keyword = $keywordJson;
            const keywordTokens = $keywordTokensJson;
            const requiredTier = $requiredTier;
            const visible = el => {
              const r = el.getBoundingClientRect();
              return r.width >= 120 && r.height >= 90 &&
                r.bottom > 0 && r.top < innerHeight &&
                r.right > 0 && r.left < innerWidth;
            };
            const mediaLargeEnough = el => {
              const media = el.matches?.('video, img, picture, [style*="background-image"]')
                ? el
                : el.querySelector?.('video, img, picture, [style*="background-image"]');
              const target = media || el;
              const r = target.getBoundingClientRect();
              if (r.width < 100 || r.height < 70) return false;
              if (media) return true;
              const style = getComputedStyle(target);
              const marker = [target.id, target.className].join(' ').toLowerCase();
              return style.backgroundImage !== 'none' ||
                /(video|thumb|cover|poster|card|post|item)/i.test(marker);
            };
            const candidates = [];
            const seenElements = new Set();
            const add = (el, order) => {
              if (!el || !mediaLargeEnough(el)) return;
              let clickable = el;
              if (clickable.tagName !== 'A' && !clickable.hasAttribute('onclick') &&
                  clickable.getAttribute('role') !== 'link') {
                clickable = clickable.closest?.('a[href]') ||
                  clickable.querySelector?.('a[href]') || clickable;
              }
              if (seenElements.has(clickable)) return;
              seenElements.add(clickable);
              let url = '';
              if (clickable.tagName === 'A' && clickable.href) {
                try {
                  const parsed = new URL(clickable.href, location.href);
                  const host = parsed.hostname.toLowerCase().replace(/^www\./, '');
                  if (!(host === siteHost || host.endsWith('.' + siteHost)) ||
                      parsed.href === location.href) return;
                  url = parsed.href;
                } catch (_) { return; }
              }
              const text = (clickable.getAttribute('aria-label') || clickable.title ||
                clickable.innerText || el.innerText || '').trim();
              const marker = [url, text, clickable.id, clickable.className,
                el.id, el.className].join(' ').toLowerCase();
              if (/(^|[ _/.-])(ads?|advert|banner|promo|sponsor|推广|广告)([ _/.-]|\$)/i.test(marker)) return;
              const key = url || [text.slice(0, 120), order].join('|');
              if (!key || visited.has(key)) return;
              const haystack = [text, url, el.innerText || ''].join(' ').toLowerCase();
              const exact = keyword.length > 0 && haystack.includes(keyword);
              const tokenHits = keywordTokens.reduce((sum, token) =>
                sum + (haystack.includes(token) ? 1 : 0), 0);
              const tier = exact ? 2 : (tokenHits > 0 ? 1 : 0);
              const r = clickable.getBoundingClientRect();
              const inView = visible(clickable);
              const documentTop = Math.max(0, r.top + window.scrollY);
              const detailPath = /[/](archives?|posts?|videos?|watch|view|detail|movies?)[/]/i.test(url);
              candidates.push({el:clickable, key, url, text, inView,
                documentTop, detailPath, order, tier, tokenHits});
            };
            Array.from(document.querySelectorAll('a[href]')).forEach(add);
            Array.from(document.querySelectorAll(
              '[role="link"], article, figure, [class*="card"], [class*="post"], [class*="item"]'
            )).forEach((el, index) => {
              const style = getComputedStyle(el);
              if (el.getAttribute('role') === 'link' || el.hasAttribute('onclick') ||
                  el.tabIndex >= 0 || style.cursor === 'pointer') add(el, 10000 + index);
            });
            // Deterministic top-to-bottom traversal. Prefer actual detail URLs,
            // then the currently visible card, while never revisiting a key.
            candidates.sort((a, b) =>
              b.tier - a.tier || b.tokenHits - a.tokenHits ||
              (b.detailPath ? 1 : 0) - (a.detailPath ? 1 : 0) ||
              (b.inView ? 1 : 0) - (a.inView ? 1 : 0) ||
              a.documentTop - b.documentTop || a.order - b.order);
            const diagnostics = {
              page: location.href,
              anchors: document.querySelectorAll('a[href]').length,
              articles: document.querySelectorAll('article').length,
              candidates: candidates.length,
              eligible: candidates.filter(row => row.tier >= requiredTier).length,
              requiredTier,
              visited: visited.size
            };
            const selected = candidates.find(row => row.tier >= requiredTier);
            if (!selected) return {clicked:false, diagnostics};
            selected.el.removeAttribute('target');
            selected.el.scrollIntoView({behavior:'auto', block:'center', inline:'center'});
            const selectedRect = selected.el.getBoundingClientRect();
            setTimeout(() => selected.el.click(), 180);
            return {
              clicked:true,
              key:selected.key,
              url:selected.url,
              label:selected.text || '最近的媒体卡片',
              x: innerWidth > 0
                ? (selectedRect.left + selectedRect.width / 2) / innerWidth : 0.5,
              y: innerHeight > 0
                ? (selectedRect.top + selectedRect.height / 2) / innerHeight : 0.5,
              diagnostics
            };
          })()
        ''',
          )
          .timeout(const Duration(seconds: 5));
      if (result is! Map || result['clicked'] != true) {
        debugPrint(
          '智能卡片诊断：未选中卡片，${result is Map ? result['diagnostics'] : result}',
        );
        return false;
      }
      final key = (result['key'] ?? '').toString();
      if (key.isEmpty || !visited.add(key)) return false;
      task['lastProductiveListUrl'] = pageUrl;
      task['cardListUrl'] = pageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['activeDiscoveryStrategy'] = 'click_media_card';
      task['lastFeedMoveAt'] = DateTime.now();
      task['nextMediaLabel'] = (result['label'] ?? '媒体详情').toString();
      task['nextMediaStatus'] = '正在进入详情获取地址';
      _showSmartOperation(
        '点击候选媒体：${task['nextMediaLabel']}',
        point: Offset(
          (result['x'] as num?)?.toDouble() ?? 0.5,
          (result['y'] as num?)?.toDouble() ?? 0.5,
        ),
      );
      debugPrint(
        '智能卡片诊断：准备点击 url=${result['url']}，key=$key，${result['diagnostics']}',
      );
      final id = (task['discoveryTaskId'] ?? '').toString();
      if (id.isNotEmpty) {
        _updateDownloadTask(id, progressDetail: '正在打开最近的媒体卡片并解析真实下载地址...');
      }
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (identical(_smartDownloadTask, task) &&
            task['phase'] == 'visiting_clicked_card') {
          if (_currentUrl == pageUrl) {
            debugPrint('智能卡片诊断：点击后尚未导航，page=$pageUrl，target=${result['url']}');
          }
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return true;
    } catch (e) {
      debugPrint('智能下载打开媒体卡片失败（继续扫描）: $e');
      return false;
    }
  }

  Future<bool> _openExploratorySmartTarget(
    Map<String, dynamic> task,
    String pageUrl,
  ) async {
    final controller = _controller;
    if (controller == null ||
        !identical(_smartDownloadTask, task) ||
        _smartStrategyCircuitOpen(task, 'exploratory_click')) {
      return false;
    }
    final visited = task['exploratoryClickedKeys'] as Set<String>;
    final visitedJson = jsonEncode(visited.toList());
    final siteHostJson = jsonEncode((task['host'] ?? '').toString());
    final watch = Stopwatch()..start();
    try {
      final result = await controller
          .evaluateJavascript(
            source: '''
              (() => {
                const visited = new Set($visitedJson);
                const siteHost = $siteHostJson;
                const rows = [];
                const seen = new Set();
                const elements = Array.from(document.querySelectorAll(
                  'a[href], [role="link"], button[onclick], [onclick][tabindex]'
                ));
                elements.forEach((el, order) => {
                  if (!el || seen.has(el) || el.closest('header, nav, footer, aside, [role="navigation"]')) return;
                  seen.add(el);
                  const r = el.getBoundingClientRect();
                  if (r.width < 36 || r.height < 20) return;
                  let url = '';
                  if (el.tagName === 'A' && el.href) {
                    try {
                      const parsed = new URL(el.href, location.href);
                      const host = parsed.hostname.toLowerCase().replace(/^www\./, '');
                      if (!(host === siteHost || host.endsWith('.' + siteHost)) ||
                          parsed.href === location.href) return;
                      url = parsed.href;
                    } catch (_) { return; }
                  }
                  const text = (el.innerText || el.title ||
                    el.getAttribute('aria-label') || '').trim();
                  const marker = [url, text, el.id, el.className].join(' ').toLowerCase();
                  if (/(ads?|advert|banner|promo|sponsor|pop.?up|登录|注册|充值|推广|广告)/i.test(marker)) return;
                  if (/([.](?:jpg|jpeg|png|gif|webp)(?:[?]|\$)|[/](?:images?|photos?|gallery)[/])/i.test(url)) return;
                  if (/(login|register|account|logout|cart|checkout|contact|privacy)/i.test(url)) return;
                  const key = url || [text.slice(0, 100), order].join('|');
                  if (!key || visited.has(key)) return;
                  const visible = r.bottom > 0 && r.top < innerHeight;
                  const likelyVideo = /(video|watch|play|movie|archives?|posts?|detail|视频|播放)/i.test(marker);
                  const documentTop = Math.max(0, r.top + window.scrollY);
                  const score = (likelyVideo ? 1000000 : 0) +
                    (visible ? 100000 : 0) - documentTop - order;
                  rows.push({el, key, url, text, score});
                });
                rows.sort((a, b) => b.score - a.score);
                const selected = rows[0];
                if (!selected) return {clicked:false};
                selected.el.removeAttribute('target');
                selected.el.scrollIntoView({behavior:'auto', block:'center'});
                setTimeout(() => selected.el.click(), 180);
                return {clicked:true, key:selected.key, url:selected.url,
                  label:selected.text || '安全探索链接'};
              })()
            ''',
          )
          .timeout(const Duration(seconds: 5));
      watch.stop();
      if (result is! Map || result['clicked'] != true) {
        _recordSmartStrategyOutcome(
          task,
          'exploratory_click',
          success: false,
          elapsedMs: watch.elapsedMilliseconds,
        );
        return false;
      }
      final key = (result['key'] ?? '').toString();
      if (key.isEmpty || !visited.add(key)) return false;
      task['lastProductiveListUrl'] = pageUrl;
      task['cardListUrl'] = pageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['activeDiscoveryStrategy'] = 'exploratory_click';
      task['lastFeedMoveAt'] = DateTime.now();
      task['nextMediaLabel'] = (result['label'] ?? '安全探索链接').toString();
      task['nextMediaStatus'] = '常规卡片已耗尽，正在安全探索';
      final id = (task['discoveryTaskId'] ?? '').toString();
      if (id.isNotEmpty) {
        _updateDownloadTask(id, progressDetail: '正在尝试站内安全探索链接并监听媒体地址...');
      }
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        if (identical(_smartDownloadTask, task) &&
            task['phase'] == 'visiting_clicked_card') {
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return true;
    } catch (e) {
      watch.stop();
      _recordSmartStrategyOutcome(
        task,
        'exploratory_click',
        success: false,
        elapsedMs: watch.elapsedMilliseconds,
      );
      debugPrint('智能下载安全探索点击失败: $e');
      return false;
    }
  }

  bool _allowSmartExploratoryClick(Map<String, dynamic> task) {
    final host = (task['host'] ?? '').toString();
    final keyword = (task['keyword'] ?? '').toString().trim();
    final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
    final searchCycle = (task['searchCycle'] as int?) ?? 0;
    final is91 = host == '91cg1.com' || host.endsWith('.91cg1.com');
    return !(is91 &&
        keyword.isNotEmpty &&
        searchCycle == 0 &&
        discoveryRound <= 2);
  }

  Future<void> _returnFromSmartMediaCard(
    Map<String, dynamic> task, {
    required bool madeProgress,
  }) async {
    if (!identical(_smartDownloadTask, task)) return;
    if (task['strict91KeywordMode'] == true) {
      final listUrl = (task['strict91SearchUrl'] ?? '').toString();
      task['phase'] = 'strict91_returning';
      task['strict91ReturnAttempts'] = 0;
      task.remove('nextMediaLabel');
      task.remove('nextMediaStatus');
      final controller = _controller;
      if (controller == null || listUrl.isEmpty) return;
      final actualUrl = (await controller.getUrl())?.toString() ?? _currentUrl;
      if (_isSame91TaskPage(listUrl, actualUrl)) {
        task['phase'] = 'visiting_candidate';
        task['strict91ActiveCardUrl'] = '';
        _visitNextSmartCandidate(task);
      } else if (await controller.canGoBack()) {
        await controller.goBack();
      } else {
        _loadUrl(listUrl);
      }
      return;
    }
    final listUrl = (task.remove('cardListUrl') ?? '').toString();
    final resumeCandidateQueue =
        task.remove('resumeCandidateQueueAfterCard') == true;
    task['phase'] =
        resumeCandidateQueue ? 'returning_candidate_list' : 'scanning_feed';
    task.remove('nextMediaLabel');
    task.remove('nextMediaStatus');
    final controller = _controller;
    if (controller == null) return;
    if (listUrl.isNotEmpty && _currentUrl != listUrl) {
      if (await controller.canGoBack()) {
        await controller.goBack();
      } else {
        _loadUrl(listUrl);
      }
      return;
    }
    if (resumeCandidateQueue) {
      task['phase'] = 'visiting_candidate';
      _visitNextSmartCandidate(task);
      return;
    }
    _continueSmartFeed(task, madeProgress: madeProgress);
  }

  Future<bool> _openActiveXSmartCard(Map<String, dynamic> task) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) {
      return false;
    }
    try {
      // Capture the list page before dispatching the click. X updates
      // location.href synchronously for SPA navigation, so reading it after
      // click can accidentally store the detail page as its own return URL.
      final pageBeforeClick =
          (await controller.getUrl())?.toString() ?? _currentUrl;
      final result = await controller.evaluateJavascript(
        source: '''
          (() => {
            const scope = document.querySelector('[data-app-smart-x-active="1"]') ||
              document.querySelector('[data-smart-seed-scope="1"]');
            if (!scope) return {clicked: false, statusId: ''};
            const media = scope.querySelector('[data-smart-seed-media="1"]') ||
              scope.querySelector('video, [data-testid="tweetPhoto"] img, img');
            if (!media) return {clicked: false, statusId: ''};
            const links = [
              ...(scope.matches?.('a[href*="/status/"]') ? [scope] : []),
              ...Array.from(scope.querySelectorAll('a[href*="/status/"]'))
            ];
            const mediaRect = media.getBoundingClientRect();
            const mediaLink = links.find(link => {
              const r = link.getBoundingClientRect();
              return r.width > 40 && r.height > 40 &&
                r.left <= mediaRect.right && r.right >= mediaRect.left &&
                r.top <= mediaRect.bottom && r.bottom >= mediaRect.top;
            });
            const statusLink = mediaLink || links[0] || null;
            const href = String(statusLink?.href || '');
            const statusId = ((href.split('/status/')[1] || '').match(/^[0-9]+/) || [''])[0];
            const clickable = mediaLink || media.closest('a[href*="/status/"]') ||
              statusLink || media.closest('[role="link"], [role="button"]') || media;
            try {
              const returnUrl = location.href;
              const returnScrollY = Math.max(0, window.scrollY || 0);
              document.querySelectorAll(
                '[data-smart-seed-media], [data-smart-seed-scope], [data-app-smart-x-active]'
              ).forEach(el => {
                el.removeAttribute('data-smart-seed-media');
                el.removeAttribute('data-smart-seed-scope');
                el.removeAttribute('data-app-smart-x-active');
              });
              clickable.dispatchEvent(new MouseEvent('pointerdown', {
                bubbles: true, cancelable: true, clientX: mediaRect.left + mediaRect.width / 2,
                clientY: mediaRect.top + mediaRect.height / 2
              }));
              clickable.dispatchEvent(new MouseEvent('pointerup', {
                bubbles: true, cancelable: true, clientX: mediaRect.left + mediaRect.width / 2,
                clientY: mediaRect.top + mediaRect.height / 2
              }));
              clickable.click();
              return {
                clicked: true,
                statusId,
                returnUrl,
                returnScrollY
              };
            } catch (_) {
              return {clicked: false, statusId};
            }
          })()
        ''',
      );
      if (result is! Map || result['clicked'] != true) return false;
      final jsReturnUrl = (result['returnUrl'] ?? '').toString().trim();
      final returnUrl =
          pageBeforeClick.startsWith('http') ? pageBeforeClick : jsReturnUrl;
      if (returnUrl.startsWith('http') && _isXPlatformPage(returnUrl)) {
        task['xReturnUrl'] = returnUrl;
        task['xReturnScrollY'] = (result['returnScrollY'] as num?)?.toDouble();
      }
      final statusId = (result['statusId'] ?? '').toString().trim();
      if (statusId.isNotEmpty) {
        (task['xVisitedStatusIds'] as Set<String>).add(statusId);
      }
      task['xEnteredDetailFromList'] = true;
      task['phase'] = 'x_viewing_search_card';
      task['xCurrentPostResolveRetries'] = 0;
      task['nextMediaStatus'] = '已打开匹配卡片，正在提取真实地址';
      Future<void>.delayed(const Duration(milliseconds: 1200), () async {
        if (identical(_smartDownloadTask, task)) {
          await _anchorSmartSeedForType(task['mediaType'] as MediaType);
          unawaited(_advanceSmartDownload(_currentUrl));
        }
      });
      return true;
    } catch (e) {
      debugPrint('打开 X 智能下载媒体卡片失败: $e');
      return false;
    }
  }

  Future<void> _returnFromXSmartCard(Map<String, dynamic> task) async {
    final controller = _controller;
    if (controller == null || !identical(_smartDownloadTask, task)) return;
    task['phase'] = 'x_search_returning';
    task['xEnteredDetailFromList'] = false;
    task['xCurrentPostResolveRetries'] = 0;
    task['xInlineActivationPending'] = false;
    task['xInlineReadyToLongPress'] = false;
    final current = (await controller.getUrl())?.toString() ?? _currentUrl;
    final recordedReturnUrl = (task['xReturnUrl'] ?? '').toString().trim();
    final originUrl = (task['originUrl'] ?? '').toString().trim();
    final strictSearchUrl = (task['strictXSearchUrl'] ?? '').toString().trim();
    final siteUrl = (task['siteUrl'] ?? '').toString().trim();
    bool isSafeListUrl(String value) =>
        value.startsWith('http') &&
        _isXPlatformPage(value) &&
        !_isXStatusDetailPage(value) &&
        !_isXMediaViewerPage(value);
    final returnUrl = <String>[
      recordedReturnUrl,
      strictSearchUrl,
      originUrl,
      siteUrl,
    ].firstWhere(isSafeListUrl, orElse: () => siteUrl);
    if (!returnUrl.startsWith('http')) return;
    task['xReturnUrl'] = returnUrl;
    task['xReturnExpectedUrl'] = returnUrl;
    task['xReturnAttempts'] = 0;
    // X inserts transient about:blank entries into WebView history. Loading
    // the remembered list URL directly is deterministic and preserves login
    // cookies, while goBack() can oscillate between blank and the detail page.
    if (!_isSameXSmartReturnPage(returnUrl, current)) {
      _loadUrl(returnUrl);
      Future<void>.delayed(const Duration(seconds: 2), () async {
        if (!identical(_smartDownloadTask, task) ||
            task['phase'] != 'x_search_returning') {
          return;
        }
        final actual = (await _controller?.getUrl())?.toString() ?? _currentUrl;
        if (_isBlankHistoryUrl(actual) ||
            !_isSameXSmartReturnPage(returnUrl, actual)) {
          final attempts = ((task['xReturnAttempts'] as int?) ?? 0) + 1;
          task['xReturnAttempts'] = attempts;
          if (attempts <= 3) _loadUrl(returnUrl);
        } else {
          unawaited(_advanceSmartDownload(actual));
        }
      });
      return;
    }
    unawaited(_advanceSmartDownload(current));
  }

  Future<void> _broadenXSmartSearch(Map<String, dynamic> task) async {
    if (!identical(_smartDownloadTask, task) || _controller == null) return;
    final keyword = (task['keyword'] ?? '').toString().trim();
    final cycle = ((task['xSearchCycle'] as int?) ?? 0) + 1;
    task['xSearchCycle'] = cycle;
    task['xCurrentPostResolveRetries'] = 0;
    task['feedNoNew'] = 0;

    if (keyword.isNotEmpty) {
      final siteUri = Uri.tryParse((task['siteUrl'] ?? '').toString());
      if (siteUri == null || siteUri.host.isEmpty) return;
      final mode = cycle % 3;
      final query = <String, String>{
        'q': keyword,
        'src': 'typed_query',
        if (mode == 1) 'f': 'live',
        if (mode == 2) 'f': 'media',
      };
      final nextUrl =
          siteUri
              .replace(path: '/search', queryParameters: query, fragment: '')
              .toString();
      task['strictXSearchUrl'] = nextUrl;
      task['phase'] = 'x_search_loading';
      task['matchStage'] = mode == 1 ? '关键词搜索 · 最新结果' : '关键词搜索 · 扩大结果范围';
      _loadUrl(nextUrl);
      return;
    }

    task['phase'] = 'scanning_feed';
    await _controller!.evaluateJavascript(
      source: '''
        (() => {
          document.querySelectorAll(
            '[data-smart-seed-media], [data-smart-seed-scope], '
            + '[data-app-smart-x-active], [data-app-smart-x-visited]'
          ).forEach(el => {
            el.removeAttribute('data-smart-seed-media');
            el.removeAttribute('data-smart-seed-scope');
            el.removeAttribute('data-app-smart-x-active');
            el.removeAttribute('data-app-smart-x-visited');
          });
          window.scrollTo({top: 0, left: 0, behavior: 'auto'});
          return true;
        })()
      ''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (identical(_smartDownloadTask, task)) {
      _continueSmartFeed(task, madeProgress: false);
    }
  }

  void _continueSmartFeed(
    Map<String, dynamic> task, {
    required bool madeProgress,
  }) {
    final wasPreheated = task.remove('nextMediaPreheated') == true;
    if (wasPreheated) task['nextMediaStatus'] = '马上下载';
    final scans = (task['feedScans'] as int) + 1;
    final noNew = madeProgress ? 0 : (task['feedNoNew'] as int) + 1;
    task['feedScans'] = scans;
    task['feedNoNew'] = noNew;
    final strictXFeedMode = task['strictXFeedMode'] == true;
    final xImageMode = task['mediaType'] == MediaType.image;
    final xKeywordJson = jsonEncode((task['keyword'] ?? '').toString().trim());
    final xSearchResultsMode =
        (task['strictXSearchUrl'] ?? '').toString().isNotEmpty;
    final xVisitedStatusJson = jsonEncode(
      (task['xVisitedStatusIds'] as Set<String>).toList(),
    );
    final maxScans = ((task['target'] as int) * (strictXFeedMode ? 30 : 12))
        .clamp(strictXFeedMode ? 60 : 24, strictXFeedMode ? 600 : 240);
    final noNewLimit = strictXFeedMode ? 24 : 8;
    if (!strictXFeedMode && (noNew >= noNewLimit || scans >= maxScans)) {
      task['phase'] = 'collecting_site_results';
      Future<void>.delayed(
        const Duration(milliseconds: 120),
        () => unawaited(_advanceSmartDownload(_currentUrl)),
      );
      return;
    }
    task['phase'] = 'scanning_feed';
    task['lastFeedMoveAt'] = DateTime.now();
    const directionForScript = 1;
    final keywordEmpty = (task['keyword'] ?? '').toString().trim().isEmpty;
    final preferSeedScope =
        keywordEmpty &&
        task['startedFromCurrentPage'] == true &&
        ((task['discoveryRound'] as int?) ?? 0) == 0;
    final controller = _controller;
    if (controller == null) {
      task['phase'] = 'opening_site';
      return;
    }
    _showSmartOperation(
      madeProgress ? '当前媒体已处理，向下寻找下一项' : '向下浏览，寻找可下载媒体',
      point: const Offset(0.5, 0.78),
    );
    unawaited(
      controller
          .evaluateJavascript(
            source: '''
              (() => {
                const direction = $directionForScript;
                const strictXFeedMode = $strictXFeedMode;
                const xImageMode = $xImageMode;
                const xKeyword = $xKeywordJson.toLowerCase();
                const xSearchResultsMode = $xSearchResultsMode;
                const xVisitedStatusIds = new Set($xVisitedStatusJson);
                const amount = Math.max(420, Math.floor(innerHeight * 0.82)) * direction;
                if (strictXFeedMode) {
                  const seed = document.querySelector('[data-smart-seed-media="1"]');
                  const seedArticle = seed && seed.closest('article[data-testid="tweet"], article');
                  if (seedArticle) seedArticle.setAttribute('data-app-smart-x-visited', '1');
                  const validImage = img => {
                    const r = img.getBoundingClientRect();
                    const src = String(img.currentSrc || img.src || '').toLowerCase();
                    return Math.max(img.naturalWidth || 0, r.width) >= 240 &&
                      Math.max(img.naturalHeight || 0, r.height) >= 180 &&
                      !/(profile_images|profile_banners|emoji|avatar)/.test(src);
                  };
                  const mediaInArticle = article => {
                    if (xImageMode) {
                      return Array.from(article.querySelectorAll('img')).find(validImage);
                    }
                    const video = article.querySelector('video');
                    if (video) return video;
                    // X's media-search grid renders videos as poster images. Use
                    // the poster only as a precise card target, then resolve the
                    // real video after opening its status page.
                    const statusLink = article.matches?.('a[href*="/status/"]')
                      ? article
                      : article.querySelector('a[href*="/status/"]');
                    if (!xSearchResultsMode || !statusLink) return null;
                    return Array.from(article.querySelectorAll('img')).find(validImage);
                  };
                  const keywordTokens = xKeyword.split(' ')
                    .map(value => value.trim()).filter(value => value.length >= 2);
                  const keywordScore = article => {
                    if (!xKeyword) return 1;
                    const text = String(article.innerText || '').toLowerCase();
                    if (text.includes(xKeyword)) return 1000 + xKeyword.length;
                    const tokenScore = keywordTokens.reduce(
                      (score, token) => score + (text.includes(token) ? 10 : 0), 0);
                    // X's own media search already applies the keyword. Many
                    // result cards contain only media and omit searchable text.
                    return tokenScore > 0 ? tokenScore : (xSearchResultsMode ? 1 : 0);
                  };
                  const articleCandidates = Array.from(document.querySelectorAll(
                    'article[data-testid="tweet"], article'
                  ));
                  if (xSearchResultsMode) {
                    document.querySelectorAll('a[href*="/status/"]').forEach(link => {
                      const card = link.closest(
                        'article[data-testid="tweet"], article, [data-testid="cellInnerDiv"]'
                      ) || link;
                      if (!articleCandidates.includes(card)) articleCandidates.push(card);
                    });
                  }
                  const articles = articleCandidates;
                  const seedIndex = seedArticle ? articles.indexOf(seedArticle) : -1;
                  const forwardArticles = seedIndex >= 0
                    ? articles.slice(seedIndex + 1)
                    : articles;
                  const candidates = forwardArticles.filter(article =>
                    article.getAttribute('data-app-smart-x-visited') !== '1' &&
                    ![...(article.matches?.('a[href*="/status/"]') ? [article] : []),
                      ...Array.from(article.querySelectorAll('a[href*="/status/"]'))].some(link => {
                      const tail = String(link.href || '').split('/status/')[1] || '';
                      const id = (tail.match(/^[0-9]+/) || [''])[0];
                      return id && xVisitedStatusIds.has(id);
                    }) &&
                    mediaInArticle(article) && keywordScore(article) > 0);
                  const nextArticle = candidates.sort((left, right) =>
                    keywordScore(right) - keywordScore(left) ||
                    left.getBoundingClientRect().top - right.getBoundingClientRect().top)[0];
                  if (nextArticle) {
                    nextArticle.setAttribute('data-app-smart-x-visited', '1');
                    document.querySelectorAll(
                      '[data-smart-seed-media], [data-smart-seed-scope], [data-app-smart-x-active]'
                    )
                      .forEach(el => {
                        el.removeAttribute('data-smart-seed-media');
                        el.removeAttribute('data-smart-seed-scope');
                        el.removeAttribute('data-app-smart-x-active');
                      });
                    const nextMedia = mediaInArticle(nextArticle);
                    nextMedia.setAttribute('data-smart-seed-media', '1');
                    nextArticle.setAttribute('data-smart-seed-scope', '1');
                    nextArticle.setAttribute('data-app-smart-x-active', '1');
                    nextArticle.scrollIntoView({behavior:'auto', block:'center'});
                    if (!xImageMode) {
                      Array.from(document.querySelectorAll('video')).forEach(video => {
                        if (video !== nextMedia) {
                          try { video.pause(); } catch (_) {}
                        }
                      });
                      try {
                        nextMedia.muted = true;
                        nextMedia.play().catch(() => {});
                      } catch (_) {}
                    }
                    const statusIdFor = article => {
                      if (!article) return '';
                      const link = article.matches?.('a[href*="/status/"]')
                        ? article
                        : article.querySelector('a[href*="/status/"]');
                      const tail = String(link?.href || '').split('/status/')[1] || '';
                      return (tail.match(/^[0-9]+/) || [''])[0];
                    };
                    return {
                      action: 'next_x_post',
                      statusIds: [statusIdFor(seedArticle), statusIdFor(nextArticle)]
                        .filter(Boolean)
                    };
                  }
                  if (!xImageMode) {
                    const videos = Array.from(document.querySelectorAll('video'))
                      .filter(video => {
                        const r = video.getBoundingClientRect();
                        return r.width > 100 && r.height > 80;
                      });
                    const seedVideo = seed && seed.tagName === 'VIDEO' ? seed : null;
                    const seedRect = seedVideo?.getBoundingClientRect();
                    const nextVideo = videos
                      .filter(video => video !== seedVideo)
                      .sort((left, right) => {
                        const lr = left.getBoundingClientRect();
                        const rr = right.getBoundingClientRect();
                        const base = seedRect
                          ? seedRect.top + seedRect.height / 2
                          : innerHeight / 2;
                        const ld = lr.top + lr.height / 2 - base;
                        const rd = rr.top + rr.height / 2 - base;
                        const lf = ld > 20 ? 0 : 1;
                        const rf = rd > 20 ? 0 : 1;
                        return lf - rf || Math.abs(ld) - Math.abs(rd);
                      })[0];
                    if (nextVideo) {
                      document.querySelectorAll(
                        '[data-smart-seed-media], [data-smart-seed-scope], [data-app-smart-x-active]'
                      ).forEach(el => {
                        el.removeAttribute('data-smart-seed-media');
                        el.removeAttribute('data-smart-seed-scope');
                        el.removeAttribute('data-app-smart-x-active');
                      });
                      nextVideo.setAttribute('data-smart-seed-media', '1');
                      const nextScope = nextVideo.closest(
                        'article[data-testid="tweet"], article, [role="dialog"], [data-testid*="video"]'
                      ) || nextVideo.parentElement;
                      if (nextScope) {
                        nextScope.setAttribute('data-smart-seed-scope', '1');
                        nextScope.setAttribute('data-app-smart-x-active', '1');
                      }
                      nextVideo.scrollIntoView({behavior: 'auto', block: 'center'});
                      videos.forEach(video => {
                        if (video !== nextVideo) {
                          try { video.pause(); } catch (_) {}
                        }
                      });
                      try { nextVideo.muted = true; nextVideo.play().catch(() => {}); } catch (_) {}
                      return 'next_x_video_node';
                    }

                    // X's immersive viewer often reuses one <video> element and
                    // switches items through an inner scroll-snap container.
                    let scroller = seedVideo?.parentElement || null;
                    while (scroller && scroller !== document.body) {
                      const style = getComputedStyle(scroller);
                      if (scroller.scrollHeight > scroller.clientHeight + 80 &&
                          /(auto|scroll)/.test(style.overflowY)) break;
                      scroller = scroller.parentElement;
                    }
                    if (!scroller || scroller === document.body) {
                      scroller = Array.from(document.querySelectorAll('div'))
                        .filter(el => {
                          const style = getComputedStyle(el);
                          const r = el.getBoundingClientRect();
                          return r.width > innerWidth * 0.6 && r.height > innerHeight * 0.5 &&
                            el.scrollHeight > el.clientHeight + 80 &&
                            /(auto|scroll)/.test(style.overflowY);
                        })
                        .sort((a, b) => b.clientHeight - a.clientHeight)[0] || null;
                    }
                    const move = Math.max(
                      420,
                      Math.floor((scroller?.clientHeight || innerHeight) * 0.9)
                    );
                    if (scroller) {
                      scroller.scrollBy({top: move, left: 0, behavior: 'auto'});
                      scroller.dispatchEvent(new WheelEvent(
                        'wheel', {deltaY: move, bubbles: true, cancelable: true}
                      ));
                    }
                    (seedVideo || document.body).dispatchEvent(new WheelEvent(
                      'wheel', {deltaY: move, bubbles: true, cancelable: true}
                    ));
                    document.dispatchEvent(new KeyboardEvent(
                      'keydown', {key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, bubbles: true}
                    ));
                    document.dispatchEvent(new KeyboardEvent(
                      'keydown', {key: 'PageDown', code: 'PageDown', keyCode: 34, bubbles: true}
                    ));
                    return 'advance_x_immersive';
                  }
                  const root = document.scrollingElement || document.documentElement;
                  if (root.scrollTop + innerHeight >= root.scrollHeight - 32) {
                    return 'x_page_end';
                  }
                  window.scrollBy({top: amount, left: 0, behavior: 'smooth'});
                  return 'scan_more_x_posts';
                }
                const mediaSelector = xImageMode ? 'img' : 'video';
                const scope = $preferSeedScope
                  ? document.querySelector('[data-smart-seed-scope="1"]')
                  : null;
                const scopedMedia = scope
                  ? Array.from(scope.querySelectorAll(mediaSelector))
                      .filter(el => el.clientWidth > 100 && el.clientHeight > 80)
                  : [];
                const allMedia = (scopedMedia.length > 1
                  ? scopedMedia
                  : Array.from(document.querySelectorAll(mediaSelector)))
                  .filter(el => el.clientWidth > 100 && el.clientHeight > 80);
                const visibleMedia = allMedia.filter(el => {
                  const r = el.getBoundingClientRect();
                  return r.width > 100 && r.height > 80 && r.bottom > 0 && r.top < innerHeight;
                });
                const media = visibleMedia.sort((a, b) => {
                  const ar = a.getBoundingClientRect();
                  const br = b.getBoundingClientRect();
                  return Math.abs(ar.top + ar.height / 2 - innerHeight / 2) -
                    Math.abs(br.top + br.height / 2 - innerHeight / 2);
                })[0];
                const currentIndex = media ? allMedia.indexOf(media) : -1;
                const nextMedia = currentIndex >= 0 ? allMedia[currentIndex + direction] : null;
                if (nextMedia) {
                  document.querySelectorAll('[data-smart-seed-media], [data-smart-seed-scope]')
                    .forEach(el => {
                      el.removeAttribute('data-smart-seed-media');
                      el.removeAttribute('data-smart-seed-scope');
                    });
                  nextMedia.setAttribute('data-smart-seed-media', '1');
                  const nextScope = nextMedia.closest(
                    'article, figure, [class*="card"], [class*="item"], section'
                  ) || nextMedia.parentElement;
                  if (nextScope) nextScope.setAttribute('data-smart-seed-scope', '1');
                  nextMedia.scrollIntoView({behavior:'smooth', block:'center'});
                  return 'next_media';
                }
                const nextButton = Array.from(document.querySelectorAll(
                  'button, [role="button"], a'
                )).find(el => {
                  const label = (el.getAttribute('aria-label') || el.title || el.innerText || '').toLowerCase();
                  const nextLabel = String.fromCharCode(19979, 19968);
                  return el.offsetParent !== null &&
                    (label.includes('next') || label.includes('down') || label.includes(nextLabel));
                });
                if (nextButton) {
                  nextButton.click();
                  return 'next_button';
                }
                const root = document.scrollingElement || document.documentElement;
                if (root.scrollTop + innerHeight >= root.scrollHeight - 24) {
                  return 'page_end';
                }
                let scroller = media && media.parentElement;
                while (scroller && scroller !== document.body) {
                  const style = getComputedStyle(scroller);
                  if (scroller.scrollHeight > scroller.clientHeight + 100 &&
                      /(auto|scroll)/.test(style.overflowY)) break;
                  scroller = scroller.parentElement;
                }
                if (scroller && scroller !== document.body) {
                  scroller.scrollBy({top: amount, left: 0, behavior: 'smooth'});
                  scroller.dispatchEvent(new Event('scroll', {bubbles:true}));
                } else {
                  window.scrollBy({top: amount, left: 0, behavior: 'smooth'});
                  document.scrollingElement?.dispatchEvent(new Event('scroll', {bubbles:true}));
                }
                const target = media || document.activeElement || document.body;
                target.dispatchEvent(new WheelEvent('wheel', {deltaY: amount, bubbles:true, cancelable:true}));
                const key = direction > 0 ? 'PageDown' : 'PageUp';
                const keyCode = direction > 0 ? 34 : 33;
                document.dispatchEvent(new KeyboardEvent('keydown', {key, code:key, keyCode, bubbles:true}));
                return true;
              })()
            ''',
          )
          .timeout(const Duration(seconds: 5))
          .then((result) async {
            if (!identical(_smartDownloadTask, task)) return;
            final action =
                result is Map
                    ? (result['action'] ?? '').toString()
                    : result?.toString() ?? '';
            if (result is Map) {
              final rawStatusIds = result['statusIds'];
              if (rawStatusIds is List) {
                (task['xVisitedStatusIds'] as Set<String>).addAll(
                  rawStatusIds
                      .map((value) => value.toString().trim())
                      .where((value) => value.isNotEmpty),
                );
              }
            }
            if (<String>{
              'advance_x_immersive',
              'next_x_video_node',
              'scan_more_x_posts',
              'true',
            }.contains(action)) {
              await Future<void>.delayed(const Duration(milliseconds: 620));
              if (!identical(_smartDownloadTask, task)) return;
              final snapshot = await _readSmartPageMotionSnapshot();
              final previous = (task['feedMotionSnapshot'] ?? '').toString();
              final stalled =
                  snapshot.isNotEmpty &&
                  previous.isNotEmpty &&
                  snapshot == previous;
              task['feedMotionSnapshot'] = snapshot;
              task['feedStalledCount'] =
                  stalled ? ((task['feedStalledCount'] as int?) ?? 0) + 1 : 0;
              if ((task['feedStalledCount'] as int) >= 2 &&
                  await _returnFromStalledSmartPage(
                    task,
                    '连续三次推进后页面和可见媒体均未变化',
                  )) {
                return;
              }
            } else {
              task['feedStalledCount'] = 0;
              task['feedMotionSnapshot'] = '';
            }
            if (action == 'advance_x_immersive' ||
                action == 'next_x_video_node') {
              await Future<void>.delayed(const Duration(milliseconds: 1100));
              if (!identical(_smartDownloadTask, task)) return;
              await _anchorSmartSeedForType(task['mediaType'] as MediaType);
              await Future<void>.delayed(const Duration(milliseconds: 450));
              if (identical(_smartDownloadTask, task)) {
                await _advanceSmartDownload(_currentUrl);
              }
              return;
            }
            if (action == 'next_x_post' &&
                strictXFeedMode &&
                task['mediaType'] == MediaType.video) {
              await Future<void>.delayed(const Duration(milliseconds: 280));
              if (!identical(_smartDownloadTask, task)) return;
              if ((task['keyword'] ?? '').toString().trim().isNotEmpty) {
                if (await _openActiveXSmartCard(task)) return;
              } else {
                // Normal X feeds already expose a playable video element.
                // Reuse the proven long-press path in place and never enter
                // the post detail page, whose SPA history can contain blanks.
                task['xCurrentPostResolveRetries'] = 0;
                task['phase'] = 'scanning_feed';
                task['matchStage'] = 'X 信息流直下模式 · 长按当前视频';
                _showSmartOperation('已定位下一条视频，直接长按下载');
                await _anchorSmartSeedForType(MediaType.video);
                await Future<void>.delayed(const Duration(milliseconds: 420));
                if (identical(_smartDownloadTask, task)) {
                  await _advanceSmartDownload(_currentUrl);
                }
                return;
              }
            }
            if (result?.toString() == 'x_page_end') {
              await _broadenXSmartSearch(task);
              return;
            }
            if (result?.toString() == 'page_end') {
              task['phase'] = 'collecting_site_results';
              task['feedNoNew'] = noNewLimit;
              await _advanceSmartDownload(_currentUrl);
              return;
            }
            await Future<void>.delayed(
              Duration(
                milliseconds:
                    strictXFeedMode ? 1500 : (wasPreheated ? 350 : 800),
              ),
            );
            await _advanceSmartDownload(_currentUrl);
          })
          .catchError((Object error) {
            debugPrint('智能下载页面推进超时（自动继续）: $error');
            Future<void>.delayed(
              const Duration(milliseconds: 120),
              () => unawaited(_advanceSmartDownload(_currentUrl)),
            );
          }),
    );
  }

  int _smartKeywordMatchTier(String keyword, String candidateText) {
    final normalizedKeyword = keyword.trim().toLowerCase();
    final normalizedText = candidateText.toLowerCase();
    if (normalizedKeyword.isEmpty) return 0;
    if (normalizedText.contains(normalizedKeyword)) return 2;
    final tokens = normalizedKeyword
        .split(RegExp(r'[\s_\-.,/|:;]+'))
        .where((value) => value.length >= 2)
        .take(16);
    return tokens.any(normalizedText.contains) ? 1 : 0;
  }

  Future<bool> _smartVideoSizeAllowed(
    Map<String, dynamic> task,
    List<String> urls,
    String pageUrl,
    double durationSec,
  ) async {
    final minBytes = task['effectiveMinVideoBytes'] as int?;
    final maxBytes = task['effectiveMaxVideoBytes'] as int?;
    if (minBytes == null && maxBytes == null) return true;
    final networkService = NetworkService();
    await networkService.initialize();
    var sawKnownSize = false;
    var sawUnknownSize = false;
    for (final rawUrl in urls) {
      final url = _toAbsoluteUrl(rawUrl);
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        continue;
      }
      final path = uri.path.toLowerCase();
      try {
        final cookie = await _browserCookieHeaderForUrl(url);
        final headers = <String, String>{
          'User-Agent': _kBrowserMediaUserAgent,
          'Referer': pageUrl,
          if (cookie.isNotEmpty) 'Cookie': cookie,
        };
        if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
          final response = await networkService.dio.get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              followRedirects: true,
              maxRedirects: 5,
              sendTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              validateStatus:
                  (code) => code != null && code >= 200 && code < 400,
              headers: headers,
            ),
          );
          final manifest = response.data ?? '';
          final bandwidths = RegExp(
            r'''(?:BANDWIDTH|bandwidth)\s*=\s*["']?(\d+)''',
          ).allMatches(manifest).map((match) => int.parse(match.group(1)!));
          final maxBandwidth = bandwidths.fold<int>(0, max);
          var knownDuration = durationSec;
          if (knownDuration <= 0 && path.endsWith('.m3u8')) {
            knownDuration = RegExp(r'#EXTINF:([\d.]+)')
                .allMatches(manifest)
                .fold<double>(
                  0,
                  (sum, match) => sum + (double.tryParse(match.group(1)!) ?? 0),
                );
          }
          if (maxBandwidth > 0 && knownDuration > 0) {
            final estimatedBytes = (maxBandwidth * knownDuration / 8).round();
            sawKnownSize = true;
            final inRange =
                !((minBytes != null && estimatedBytes < minBytes) ||
                    (maxBytes != null && estimatedBytes > maxBytes));
            if (inRange) return true;
          } else {
            sawUnknownSize = true;
          }
          continue;
        }
        final response = await networkService.dio.head<dynamic>(
          url,
          options: Options(
            followRedirects: true,
            maxRedirects: 5,
            sendTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 6),
            validateStatus: (code) => code != null && code >= 200 && code < 400,
            headers: headers,
          ),
        );
        final value = response.headers.value('content-length');
        final bytes = value == null ? null : int.tryParse(value.trim());
        if (bytes == null || bytes <= 0) {
          sawUnknownSize = true;
          continue;
        }
        sawKnownSize = true;
        final inRange =
            !((minBytes != null && bytes < minBytes) ||
                (maxBytes != null && bytes > maxBytes));
        if (inRange) return true;
      } catch (e) {
        sawUnknownSize = true;
        debugPrint('智能下载大小预检失败（将下载后校验）: $e');
      }
    }
    // 只有所有候选的大小都已知且均越界时才提前跳过；未知候选交给
    // 实际下载过程在获知总大小后立即校验，避免误杀可用清晰度。
    return sawUnknownSize || !sawKnownSize;
  }

  Future<void> _downloadSmartImagesFromCurrentPage(
    Map<String, dynamic> task,
  ) async {
    final controller = _controller;
    if (controller == null) return;
    final keywordJson = jsonEncode(task['keyword']);
    final preferCenter = task['phase'] == 'visiting_seed';
    final discoveryRound = (task['discoveryRound'] as int?) ?? 0;
    final exhaustiveCycle = ((task['searchCycle'] as int?) ?? 0) > 0;
    final hasKeyword = (task['keyword'] ?? '').toString().trim().isNotEmpty;
    final trustedXKeywordResult =
        task['strictXFeedMode'] == true &&
        hasKeyword &&
        (task['strictXSearchUrl'] ?? '').toString().isNotEmpty;
    final preferSeedScope =
        !hasKeyword &&
        task['startedFromCurrentPage'] == true &&
        discoveryRound == 0;
    final requiredTier =
        !hasKeyword || trustedXKeywordResult
            ? 0
            : exhaustiveCycle
            ? 0
            : (discoveryRound <= 1 ? 2 : (discoveryRound == 2 ? 1 : 0));
    final remaining = (task['target'] as int) - (task['success'] as int);
    final limit = remaining.clamp(1, 12);
    final result = await controller.evaluateJavascript(
      source: '''
        (() => {
          const keyword = $keywordJson.toLowerCase();
          const requiredTier = $requiredTier;
          const tokens = keyword.split(' ')
            .map(v => v.trim()).filter(v => v.length >= 2).slice(0, 16);
          const preferCenter = $preferCenter;
          const activeXScope = document.querySelector('[data-app-smart-x-active="1"]');
          const scope = activeXScope || ($preferSeedScope
            ? document.querySelector('[data-smart-seed-scope="1"]')
            : null);
          const scopedImages = scope ? Array.from(scope.querySelectorAll('img')) : [];
          // X preloads adjacent results. An active result remains authoritative
          // even when it contains only one image.
          const images = scope
            ? scopedImages
            : Array.from(document.querySelectorAll('img'));
          const seen = new Set();
          const rows = [];
          for (const img of images) {
            const r = img.getBoundingClientRect();
            const width = Math.max(img.naturalWidth || 0, r.width || 0);
            const height = Math.max(img.naturalHeight || 0, r.height || 0);
            if (width < 200 || height < 160) continue;
            const srcset = (img.getAttribute('srcset') || '').split(',')
              .map(v => v.trim().split(' ')[0]).filter(Boolean);
            const raw = srcset[srcset.length - 1] || img.currentSrc ||
              img.getAttribute('data-original') || img.getAttribute('data-src') || img.src;
            if (!raw || raw.startsWith('data:') || raw.startsWith('blob:')) continue;
            const marker = [raw, img.alt, img.title, img.className, img.id]
              .map(v => String(v || '').toLowerCase()).join(' ');
            if (/(?:placeholder|placehold|spacer|blank|loading|skeleton|transparent)[._ /-]/.test(marker)) continue;
            let url;
            try { url = new URL(raw, location.href).href; } catch (_) { continue; }
            if (seen.has(url)) continue;
            seen.add(url);
            const mediaScope = img.closest(
              'article[data-testid="tweet"], article, figure, [class*="card"], [class*="post"], [class*="item"]'
            );
            const text = (img.alt || img.title || mediaScope?.innerText ||
              img.closest('a')?.innerText || '').trim();
            const visible = r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
            const dx = (r.left + r.width / 2) - innerWidth / 2;
            const dy = (r.top + r.height / 2) - innerHeight / 2;
            const centerDistance = Math.abs(dy) + Math.abs(dx) * 0.25;
            const centerScore = preferCenter && visible
              ? 1000000000000 - centerDistance * 1000000
              : (visible ? Math.max(0, 10000000 - centerDistance * 10000) : 0);
            const lowerText = text.toLowerCase();
            const tokenHits = tokens.reduce((sum, token) =>
              sum + (lowerText.includes(token) ? 1 : 0), 0);
            const exact = keyword.length > 0 && lowerText.includes(keyword);
            const tier = exact ? 2 : (tokenHits > 0 ? 1 : 0);
            const score = centerScore +
              (exact ? 100000000 : 0) +
              tokenHits * 5000000 + width * height;
            rows.push({url, score, tier, visible, centerDistance});
          }
          const sorted = rows.sort((a,b) => b.score - a.score);
          return sorted.filter((row, index) =>
            (preferCenter && index === 0 && row.visible) || row.tier >= requiredTier
          ).slice(0, preferCenter ? 1 : $limit).map(v => v.url);
        })()
      ''',
    );
    if (result is! List || result.isEmpty) {
      task['failed'] = (task['failed'] as int) + 1;
      return;
    }
    final seen = task['seenMediaUrls'] as Set<String>;
    final urls =
        result
            .map((value) => value.toString())
            .where((url) => seen.add(url))
            .toList();
    if (urls.isEmpty) return;
    for (var start = 0; start < urls.length; start += 3) {
      if (_smartDownloadTask == null) return;
      final end = min(start + 3, urls.length);
      final outcomes = await Future.wait(
        urls.sublist(start, end).map((url) async {
          var failureType = '';
          final pageUrl = _currentUrl;
          if (!_reserveSmartMediaName(task, url, pageUrl: pageUrl)) {
            return (ok: false, failureType: 'duplicate_name_in_smart_task');
          }
          _showSmartOperation('模拟长按当前图片，开始下载');
          final ok = await _performBackgroundDownload(
            url,
            MediaType.image,
            skipFailurePrompt: true,
            showSuccessPrompt: false,
            showDuplicatePrompt: false,
            validateSmartMedia: true,
            isSmartBatchMedia: true,
            smartTask: task,
            smartPageUrl: pageUrl,
            onFailureType: (type) => failureType = type,
            maxRequestAttempts: 3,
            inactivityTimeout: const Duration(minutes: 2),
          );
          if (!ok && failureType != 'already_in_library') {
            _releaseSmartMediaName(task, url, pageUrl: pageUrl);
          }
          return (ok: ok, failureType: failureType);
        }),
      );
      for (final outcome in outcomes) {
        task[outcome.ok ? 'success' : 'failed'] =
            (task[outcome.ok ? 'success' : 'failed'] as int) + 1;
        if (outcome.failureType == 'invalid_smart_media_content') {
          task['invalidSkipped'] = ((task['invalidSkipped'] as int?) ?? 0) + 1;
        }
      }
      _updateSmartDiscoveryProgress(
        task,
        task['phase']?.toString() ?? 'scanning_feed',
      );
      if ((task['success'] as int) >= (task['target'] as int)) return;
    }
  }

  void _broadenSmartDiscovery(
    Map<String, dynamic> task,
    String exhaustedReason,
  ) {
    if (!identical(_smartDownloadTask, task)) return;
    task.remove('nextMediaPreheated');
    task.remove('nextMediaLabel');
    task.remove('nextMediaStatus');
    final discoveryQueue = task['discoveryPageQueue'] as List<String>;
    final visitedDiscoveryUrls = task['visitedDiscoveryUrls'] as Set<String>;
    while (discoveryQueue.isNotEmpty) {
      final nextScopeUrl = discoveryQueue.removeAt(0);
      if (!visitedDiscoveryUrls.add(nextScopeUrl)) continue;
      task['phase'] = 'collecting_site_results';
      task['activeDiscoveryStrategy'] = 'actual_scope_link';
      task['candidates'] = <Map<String, String>>[];
      task['index'] = 0;
      final id = (task['discoveryTaskId'] ?? '').toString();
      if (id.isNotEmpty) {
        _updateDownloadTask(
          id,
          progressDetail:
              '正在向上一层/同级页面挖掘媒体地址 · 已保存 ${task['success']}/${task['target']}',
        );
      }
      _loadUrl(nextScopeUrl);
      return;
    }
    var round = ((task['discoveryRound'] as int?) ?? 0) + 1;
    final deadlineAt = task['deadlineAt'] as DateTime?;
    if (deadlineAt != null && !DateTime.now().isBefore(deadlineAt)) {
      unawaited(_finishSmartDownload('已达到单次任务 5 小时时间上限'));
      return;
    }
    var cycleDelay = Duration.zero;
    if (round > 6) {
      final cycle = ((task['searchCycle'] as int?) ?? 0) + 1;
      task['searchCycle'] = cycle;
      round = 1;
      cycleDelay = Duration(seconds: min(30, 2 + cycle * 2));
      (task['preheatedVideoCandidates'] as Map<String, List<String>>).clear();
    }
    task['discoveryRound'] = round;
    task['feedScans'] = 0;
    task['feedNoNew'] = 0;
    task['feedDirection'] = 1;
    task['candidateResolveRetries'] = 0;
    task['candidates'] = <Map<String, String>>[];
    task['index'] = 0;
    final siteUri = Uri.tryParse((task['siteUrl'] ?? '').toString());
    if (siteUri == null || siteUri.host.isEmpty) {
      unawaited(_finishSmartDownload('当前网站地址无效'));
      return;
    }
    final origin = siteUri.origin;
    final keyword = (task['keyword'] ?? '').toString().trim();
    final requestedMin = task['minVideoBytes'] as int?;
    final requestedMax = task['maxVideoBytes'] as int?;
    switch (round) {
      case 1:
        task['matchStage'] = '精确匹配 · 站内入口';
        task['effectiveMinVideoBytes'] = requestedMin;
        task['effectiveMaxVideoBytes'] = requestedMax;
        break;
      case 2:
        task['matchStage'] = '相近关键词 · 大小放宽 25%';
        task['effectiveMinVideoBytes'] =
            requestedMin == null ? null : (requestedMin * 0.75).round();
        task['effectiveMaxVideoBytes'] =
            requestedMax == null ? null : (requestedMax * 1.25).round();
        break;
      case 3:
        task['matchStage'] = '相关内容 · 大小放宽 50%';
        task['effectiveMinVideoBytes'] =
            requestedMin == null ? null : (requestedMin * 0.5).round();
        task['effectiveMaxVideoBytes'] =
            requestedMax == null ? null : (requestedMax * 1.5).round();
        break;
      case 4:
        task['matchStage'] = '站内近似内容 · 大小大幅放宽';
        task['effectiveMinVideoBytes'] =
            requestedMin == null ? null : (requestedMin * 0.25).round();
        task['effectiveMaxVideoBytes'] =
            requestedMax == null ? null : requestedMax * 2;
        break;
      default:
        task['matchStage'] = '数量保底 · 仅限制类型和当前网站';
        task['effectiveMinVideoBytes'] = null;
        task['effectiveMaxVideoBytes'] = null;
    }
    if (keyword.isEmpty) {
      task['matchStage'] = round >= 5 ? '无关键词 · 全站数量保底' : '无关键词 · 从邻近媒体向全站扩展';
    }
    final searchCycle = (task['searchCycle'] as int?) ?? 0;
    if (searchCycle > 0) {
      task['effectiveMinVideoBytes'] = null;
      task['effectiveMaxVideoBytes'] = null;
      task['matchStage'] = '深层穷举第 ${searchCycle + 1} 页 · 只限媒体类型和当前网站';
    }
    final firstToken = keyword
        .split(RegExp(r'\s+'))
        .firstWhere((value) => value.isNotEmpty, orElse: () => keyword);
    late String nextUrl;
    if (keyword.isEmpty) {
      task['phase'] = 'scanning_feed';
      final mediaPath =
          task['mediaType'] == MediaType.image ? 'images' : 'videos';
      nextUrl = switch (round) {
        1 => (task['originUrl'] ?? task['siteUrl']).toString(),
        2 => '$origin/',
        3 => '$origin/$mediaPath',
        4 => '$origin/latest',
        5 => '$origin/popular',
        _ => '$origin/all',
      };
    } else {
      switch (round) {
        case 1:
          task['phase'] = 'opening_site';
          nextUrl =
              task['startedFromCurrentPage'] == true
                  ? (task['originUrl'] ?? task['siteUrl']).toString()
                  : task['siteUrl'].toString();
          break;
        case 2:
          task['phase'] = 'scanning_feed';
          nextUrl =
              Uri.parse(
                '$origin/search',
              ).replace(queryParameters: {'q': keyword}).toString();
          break;
        case 3:
          task['phase'] = 'scanning_feed';
          nextUrl =
              Uri.parse(
                '$origin/',
              ).replace(queryParameters: {'s': keyword}).toString();
          break;
        case 4:
          task['phase'] = 'scanning_feed';
          nextUrl = '$origin/search/${Uri.encodeComponent(keyword)}';
          break;
        case 5:
          task['phase'] = 'scanning_feed';
          nextUrl = '$origin/tag/${Uri.encodeComponent(firstToken)}';
          break;
        default:
          task['phase'] = 'scanning_feed';
          nextUrl = '$origin/';
      }
    }
    final syntheticDisabled =
        task['disableSyntheticRoutes'] == true ||
        _smartStrategyCircuitOpen(task, 'synthetic_route');
    if (round >= 2 && syntheticDisabled) {
      final productive = (task['lastProductiveListUrl'] ?? '').toString();
      nextUrl = productive.isNotEmpty ? productive : '$origin/';
      task['phase'] = 'collecting_site_results';
      task['activeDiscoveryStrategy'] = 'actual_scope_link';
    } else if (searchCycle > 0) {
      task['activeDiscoveryStrategy'] = 'synthetic_route';
    } else if (keyword.isNotEmpty && round >= 2) {
      task['activeDiscoveryStrategy'] = 'site_search';
    } else {
      task['activeDiscoveryStrategy'] = 'actual_scope_link';
    }
    if (searchCycle > 0 && !syntheticDisabled) {
      final pageNumber = searchCycle + 1;
      final mediaPath =
          task['mediaType'] == MediaType.image ? 'images' : 'videos';
      task['phase'] = 'scanning_feed';
      if (keyword.isEmpty) {
        nextUrl = switch (round) {
          1 => '$origin/page/$pageNumber',
          2 => '$origin/$mediaPath/page/$pageNumber',
          3 => '$origin/latest/page/$pageNumber',
          4 => '$origin/popular/page/$pageNumber',
          5 =>
            Uri.parse(
              '$origin/',
            ).replace(queryParameters: {'page': '$pageNumber'}).toString(),
          _ =>
            Uri.parse(
              '$origin/',
            ).replace(queryParameters: {'paged': '$pageNumber'}).toString(),
        };
      } else {
        final encodedKeyword = Uri.encodeComponent(keyword);
        nextUrl = switch (round) {
          1 =>
            Uri.parse(
              '$origin/page/$pageNumber/',
            ).replace(queryParameters: {'s': keyword}).toString(),
          2 =>
            Uri.parse('$origin/search')
                .replace(queryParameters: {'q': keyword, 'page': '$pageNumber'})
                .toString(),
          3 =>
            Uri.parse('$origin/')
                .replace(
                  queryParameters: {'s': keyword, 'paged': '$pageNumber'},
                )
                .toString(),
          4 => '$origin/search/$encodedKeyword/page/$pageNumber',
          5 =>
            '$origin/tag/${Uri.encodeComponent(firstToken)}/page/$pageNumber',
          _ =>
            Uri.parse('$origin/')
                .replace(
                  queryParameters: {
                    'q': keyword,
                    'offset': '${(pageNumber - 1) * (task['target'] as int)}',
                  },
                )
                .toString(),
        };
      }
    }
    final id = (task['discoveryTaskId'] ?? '').toString();
    if (id.isNotEmpty) {
      _updateDownloadTask(
        id,
        progressDetail:
            '正在扩大站内查找范围 ${searchCycle > 0 ? '深层第 ${searchCycle + 1} 页 · ' : ''}$round/6 · 已保存 ${task['success']}/${task['target']}',
      );
    }
    debugPrint('智能下载扩大站内搜索：$exhaustedReason，round=$round, url=$nextUrl');
    if (cycleDelay == Duration.zero) {
      _loadUrl(nextUrl);
    } else {
      Future<void>.delayed(cycleDelay, () {
        if (identical(_smartDownloadTask, task)) _loadUrl(nextUrl);
      });
    }
  }

  void _visitNextSmartCandidate(Map<String, dynamic> task) {
    final candidates = task['candidates'] as List<Map<String, String>>;
    if (task['strict91KeywordMode'] == true) {
      final listUrl = (task['strict91SearchUrl'] ?? '').toString();
      if (listUrl.isNotEmpty && !_isSame91TaskPage(listUrl, _currentUrl)) {
        task['phase'] = 'strict91_returning';
        _loadUrl(listUrl);
        return;
      }
    }
    var index = task['index'] as int;
    final visited = task['visitedPageUrls'] as Set<String>;
    while (index < candidates.length &&
        !visited.add(candidates[index]['url'] ?? '')) {
      index++;
    }
    if (index >= candidates.length) {
      unawaited(() async {
        final listUrl = (task['candidateListUrl'] ?? _currentUrl).toString();
        if (await _openNearestSmartMediaCard(task, listUrl)) return;
        if (_allowSmartExploratoryClick(task) &&
            await _openExploratorySmartTarget(task, listUrl)) {
          return;
        }
        _broadenSmartDiscovery(task, '当前列表的卡片和候选已全部尝试');
      }());
      return;
    }
    task['candidateResolveRetries'] = 0;
    task['index'] = index + 1;
    if (task['mediaType'] != MediaType.video) {
      task['phase'] = 'visiting_candidate';
      _loadUrl(candidates[index]['url']!);
      return;
    }
    task['phase'] = 'resolving_candidate_background';
    unawaited(
      _resolveAndDownloadSmartCandidateInBackground(task, candidates[index]),
    );
  }

  Future<void> _resolveAndDownloadSmartCandidateInBackground(
    Map<String, dynamic> task,
    Map<String, String> candidate,
  ) async {
    if (!identical(_smartDownloadTask, task)) return;
    final candidates = task['candidates'] as List<Map<String, String>>;
    final currentIndex = ((task['index'] as int) - 1).clamp(
      0,
      candidates.length - 1,
    );
    final probeWidth = min(12, 4 + ((task['searchCycle'] as int?) ?? 0) * 2);
    final probeEnd = min(currentIndex + probeWidth, candidates.length);
    final probes = <Map<String, dynamic>>[
      for (var i = currentIndex; i < probeEnd; i++)
        <String, dynamic>{'index': i, 'candidate': candidates[i]},
    ];
    final initialPageUrl = (candidate['url'] ?? '').trim();
    final candidateListUrl = (task['candidateListUrl'] ?? '').toString();
    final taskHost = (task['host'] ?? '').toString();
    final is91 = taskHost == '91cg1.com' || taskHost.endsWith('.91cg1.com');
    final currentlyOnCandidateList =
        candidateListUrl.isNotEmpty &&
        (is91
            ? _isSame91TaskPage(_currentUrl, candidateListUrl)
            : _currentUrl == candidateListUrl);
    if (is91 && currentlyOnCandidateList) {
      task['strict91ActiveCardUrl'] = initialPageUrl;
      task['phase'] = 'visiting_clicked_card';
      task['cardListUrl'] = candidateListUrl;
      task['resumeCandidateQueueAfterCard'] = true;
      task['activeDiscoveryStrategy'] = 'click_media_card';
      task['cardEnteredAt'] = DateTime.now();
      task['nextMediaLabel'] =
          (candidate['title'] ?? '').trim().isEmpty
              ? '下一个关键词视频'
              : (candidate['title'] ?? '').trim();
      task['nextMediaStatus'] = '正在直接进入关键词视频详情';
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      if (!identical(_smartDownloadTask, task)) return;
      if (!clicked) {
        // Fall back only for this card when its DOM click handler is missing.
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
      } else {
        debugPrint(
          'Smart 91: clicked ordered card ${task['index']}/${candidates.length} $initialPageUrl',
        );
      }
      return;
    }
    if (currentlyOnCandidateList &&
        !_smartStrategyCircuitOpen(task, 'click_media_card')) {
      task['phase'] = 'visiting_clicked_card';
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      if (!identical(_smartDownloadTask, task)) return;
      if (clicked) {
        task['cardListUrl'] = candidateListUrl;
        task['resumeCandidateQueueAfterCard'] = true;
        task['activeDiscoveryStrategy'] = 'click_media_card';
        task['nextMediaLabel'] =
            (candidate['title'] ?? '').trim().isEmpty
                ? '下一个视频卡片'
                : (candidate['title'] ?? '').trim();
        task['nextMediaStatus'] = '正在进入卡片深挖地址';
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (identical(_smartDownloadTask, task) &&
              task['phase'] == 'visiting_clicked_card') {
            unawaited(_advanceSmartDownload(_currentUrl));
          }
        });
        return;
      }
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: false,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      task['phase'] = 'resolving_candidate_background';
    }
    if (_smartStrategyCircuitOpen(task, 'source_parallel')) {
      task['phase'] = 'visiting_candidate';
      if (_smartStrategyCircuitOpen(task, 'click_media_card')) {
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
        return;
      }
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: clicked,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      if (clicked) {
        task['activeDiscoveryStrategy'] = 'click_media_card';
      } else {
        _loadUrl(initialPageUrl);
      }
      return;
    }
    final id = (task['discoveryTaskId'] ?? '').toString();
    if (id.isNotEmpty) {
      _updateDownloadTask(
        id,
        progressDetail:
            '正在并行解析候选 ${currentIndex + 1}-$probeEnd/${candidates.length} · 已保存 ${task['success']}/${task['target']}',
      );
    }
    final preheated =
        task['preheatedVideoCandidates'] as Map<String, List<String>>;
    final sourceWatch = Stopwatch()..start();
    final extractedBatch = await Future.wait(
      probes.map((probe) async {
        final row = probe['candidate'] as Map<String, String>;
        final url = (row['url'] ?? '').trim();
        final cached = preheated.remove(url);
        if (cached != null && cached.isNotEmpty) {
          return <String, dynamic>{...probe, 'urls': cached};
        }
        final extracted = await _resniffFavoriteCandidatesFromSourcePage(
          url,
        ).timeout(const Duration(seconds: 7), onTimeout: () => <String>[]);
        return <String, dynamic>{...probe, 'urls': extracted};
      }),
    );
    sourceWatch.stop();
    if (!identical(_smartDownloadTask, task)) return;
    final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
    Map<String, dynamic>? selected;
    List<String> urls = const <String>[];
    for (final probe in extractedBatch) {
      final probeCandidate = probe['candidate'] as Map<String, String>;
      final probePageUrl = (probeCandidate['url'] ?? '').trim();
      final resolved =
          (probe['urls'] as List<String>)
              .where((url) => !_isLikelyAdUrl(url))
              .where(
                (url) =>
                    !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
              )
              .toSet()
              .toList();
      if (resolved.isNotEmpty) preheated[probePageUrl] = resolved;
      if (resolved.isNotEmpty) {
        selected = probe;
        urls = resolved;
        break;
      }
    }
    if (selected == null) {
      _recordSmartStrategyOutcome(
        task,
        'source_parallel',
        success: false,
        elapsedMs: sourceWatch.elapsedMilliseconds,
      );
      // 动态播放器无法从 HTML 解析时，真实点击当前页的媒体卡片。
      task['phase'] = 'visiting_candidate';
      if (_smartStrategyCircuitOpen(task, 'click_media_card')) {
        task['activeDiscoveryStrategy'] = 'direct_candidate_navigation';
        _loadUrl(initialPageUrl);
        return;
      }
      final clickWatch = Stopwatch()..start();
      final clicked = await _clickSmartCandidateLink(initialPageUrl);
      clickWatch.stop();
      _recordSmartStrategyOutcome(
        task,
        'click_media_card',
        success: clicked,
        elapsedMs: clickWatch.elapsedMilliseconds,
      );
      if (!identical(_smartDownloadTask, task)) return;
      if (clicked) {
        task['activeDiscoveryStrategy'] = 'click_media_card';
      } else {
        _loadUrl(initialPageUrl);
      }
      return;
    }
    task['activeDiscoveryStrategy'] = 'source_parallel';

    final selectedIndex = selected['index'] as int;
    final selectedCandidate = selected['candidate'] as Map<String, String>;
    final pageUrl = (selectedCandidate['url'] ?? '').trim();
    final title = (selectedCandidate['title'] ?? pageUrl).trim();
    final visited = task['visitedPageUrls'] as Set<String>;
    for (var i = currentIndex; i <= selectedIndex; i++) {
      visited.add((candidates[i]['url'] ?? '').trim());
    }
    task['index'] = selectedIndex + 1;

    final nextReadyIndex = extractedBatch.indexWhere((probe) {
      final index = probe['index'] as int;
      final row = probe['candidate'] as Map<String, String>;
      return index > selectedIndex &&
          preheated.containsKey((row['url'] ?? '').trim());
    });
    if (nextReadyIndex >= 0) {
      final nextRow =
          extractedBatch[nextReadyIndex]['candidate'] as Map<String, String>;
      task['nextMediaPreheated'] = true;
      task['nextMediaLabel'] =
          (nextRow['title'] ?? '').trim().isEmpty
              ? '下一个站内视频'
              : (nextRow['title'] ?? '').trim();
      task['nextMediaStatus'] = '待下载（地址已解析）';
    } else {
      unawaited(_preheatSmartCandidateAddresses(task, probeEnd));
    }

    final contextKey = _normalizeVideoSourceUrl(urls.first);
    final attemptedContexts = task['attemptedVideoContexts'] as Set<String>;
    if (!attemptedContexts.add(contextKey)) {
      _recordSmartStrategyOutcome(
        task,
        'source_parallel',
        success: false,
        elapsedMs: sourceWatch.elapsedMilliseconds,
      );
      task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
      _visitNextSmartCandidate(task);
      return;
    }

    var ok = false;
    var failureType = '';
    if (await _smartVideoSizeAllowed(task, urls, pageUrl, 0)) {
      ok = await _downloadMediaRobustly(
        item: <String, dynamic>{
          'title': title,
          'pageUrl': pageUrl,
          'videoUrl': urls.first,
          'candidateUrls': urls,
          'downloadOrigin': 'smart_batch',
          'allowSourceUrlReuse': _isElementBoundFeedPage(pageUrl),
          'smartTask': task,
        },
        showModalDialog: false,
        showResultHint: false,
        onFailureType: (type) => failureType = type,
        minFileBytes: task['effectiveMinVideoBytes'] as int?,
        maxFileBytes: task['effectiveMaxVideoBytes'] as int?,
      );
    } else {
      failureType = 'outside_requested_size_range';
    }
    if (!identical(_smartDownloadTask, task)) return;
    _recordSmartStrategyOutcome(
      task,
      'source_parallel',
      success: ok,
      elapsedMs: sourceWatch.elapsedMilliseconds,
    );
    if (failureType == 'already_in_library' ||
        failureType == 'already_in_smart_task') {
      duplicateUrlKeys.add(contextKey);
      task['duplicateSkipped'] = ((task['duplicateSkipped'] as int?) ?? 0) + 1;
    } else if (failureType == 'outside_requested_size_range') {
      task['sizeSkipped'] = ((task['sizeSkipped'] as int?) ?? 0) + 1;
    } else if (failureType == 'invalid_smart_media_content') {
      task['invalidSkipped'] = ((task['invalidSkipped'] as int?) ?? 0) + 1;
    }
    task[ok ? 'success' : 'failed'] =
        (task[ok ? 'success' : 'failed'] as int) + 1;
    _updateSmartDiscoveryProgress(task, 'visiting_candidate');
    if ((task['success'] as int) >= (task['target'] as int)) {
      await _finishSmartDownload();
    } else {
      _visitNextSmartCandidate(task);
    }
  }

  Future<void> _preheatSmartCandidateAddresses(
    Map<String, dynamic> task,
    int startIndex,
  ) async {
    if (!identical(_smartDownloadTask, task) ||
        task['candidateAddressPreheating'] == true) {
      return;
    }
    final candidates = task['candidates'] as List<Map<String, String>>;
    if (startIndex >= candidates.length) return;
    task['candidateAddressPreheating'] = true;
    try {
      final preheatWidth = min(6, 2 + ((task['searchCycle'] as int?) ?? 0));
      final end = min(startIndex + preheatWidth, candidates.length);
      final rows = candidates.sublist(startIndex, end);
      final results = await Future.wait(
        rows.map((row) async {
          final pageUrl = (row['url'] ?? '').trim();
          final urls = await _resniffFavoriteCandidatesFromSourcePage(
            pageUrl,
          ).timeout(const Duration(seconds: 7), onTimeout: () => <String>[]);
          return (row: row, pageUrl: pageUrl, urls: urls);
        }),
      );
      if (!identical(_smartDownloadTask, task)) return;
      final duplicateUrlKeys = task['duplicateVideoUrlKeys'] as Set<String>;
      final preheated =
          task['preheatedVideoCandidates'] as Map<String, List<String>>;
      for (final result in results) {
        final valid =
            result.urls
                .where((url) => !_isLikelyAdUrl(url))
                .where(
                  (url) =>
                      !duplicateUrlKeys.contains(_normalizeVideoSourceUrl(url)),
                )
                .toSet()
                .toList();
        if (valid.isEmpty) continue;
        preheated[result.pageUrl] = valid;
        task['nextMediaPreheated'] = true;
        task['nextMediaLabel'] =
            (result.row['title'] ?? '').trim().isEmpty
                ? '下一个站内视频'
                : (result.row['title'] ?? '').trim();
        task['nextMediaStatus'] = '待下载（地址已解析）';
        break;
      }
    } catch (e) {
      debugPrint('智能下载地址预热失败（不影响当前下载）: $e');
    } finally {
      if (identical(_smartDownloadTask, task)) {
        task['candidateAddressPreheating'] = false;
      }
    }
  }

  Future<bool> _clickSmartCandidateLink(String targetUrl) async {
    if (targetUrl.isEmpty || _controller == null) return false;
    try {
      final targetJson = jsonEncode(targetUrl);
      final result = await _controller!
          .evaluateJavascript(
            source: '''
              (() => {
                const target = $targetJson;
                const normalize = (value) => {
                  try { return new URL(value, location.href).href; }
                  catch (_) { return String(value || ''); }
                };
                const expected = normalize(target);
                const links = Array.from(document.querySelectorAll('a[href]'));
                const link = links.find((item) => normalize(item.href) === expected);
                if (!link) return false;
                link.scrollIntoView({block: 'center', inline: 'center'});
                link.removeAttribute('target');
                setTimeout(() => link.click(), 60);
                return true;
              })()
            ''',
          )
          .timeout(const Duration(seconds: 3));
      final clicked = result == true || result?.toString() == 'true';
      if (clicked) {
        final task = _smartDownloadTask;
        if (task != null) {
          task['lastFeedMoveAt'] = DateTime.now();
          _updateSmartDiscoveryProgress(task, 'visiting_candidate');
        }
      }
      return clicked;
    } catch (_) {
      return false;
    }
  }

  Future<void> _finishSmartDownload([String? reason]) async {
    final task = _smartDownloadTask;
    if (task == null) return;
    final success = task['success'] as int;
    final target = task['target'] as int;
    if (success < target && reason == null) {
      _broadenSmartDiscovery(task, '数量尚未达标，继续扩大站内探索');
      return;
    }
    final failed = task['failed'] as int;
    final originUrl = (task['originUrl'] ?? '').toString();
    final restoreOrigin =
        task['startedFromCurrentPage'] == true &&
        originUrl.startsWith('http') &&
        _currentUrl != originUrl;
    final discoveryTaskId = (task['discoveryTaskId'] ?? '').toString();
    (task['deadlineTimer'] as Timer?)?.cancel();
    (task['watchdogTimer'] as Timer?)?.cancel();
    final discoveryToken = task['discoveryCancelToken'] as CancelToken?;
    if (discoveryToken != null && !discoveryToken.isCancelled) {
      discoveryToken.cancel(reason ?? '智能下载已完成');
    }
    if (discoveryTaskId.isNotEmpty) {
      _removeDownloadTask(discoveryTaskId);
    }
    if (mounted) {
      setState(() {
        _smartDownloadTask = null;
        _smartOperationPoint = null;
        _smartOperationLabel = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '智能下载结束：已完成 $success/$target，失败尝试 $failed${reason == null ? '' : '；$reason'}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      _smartDownloadTask = null;
      _smartOperationPoint = null;
      _smartOperationLabel = '';
    }
    if (restoreOrigin && mounted) {
      _loadUrl(originUrl);
    }
  }

  Widget _buildWebsiteCard(Map<String, dynamic> website, int index) {
    // 根据 iconCode 获取对应的图标
    IconData iconData = _getIconFromCode(website['iconCode']);

    return InkWell(
      key: ValueKey(website['url']),
      onTap: () => _loadUrl((website['url'] ?? '').toString()),
      onDoubleTap: () => _showWebsiteOptionsDialog(context, website, index),
      child: Card(
        elevation: 4.0,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(iconData, size: 40, color: Colors.blue),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Text(
                website['name'],
                style: const TextStyle(fontSize: 14), // 稍微调小字号以适应更多文字
                textAlign: TextAlign.center,
                maxLines: 2, // 最多显示两行
                overflow: TextOverflow.ellipsis, // 超出部分显示省略号
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showWebsiteOptionsDialog(
    BuildContext pageContext,
    Map<String, dynamic> website,
    int index,
  ) {
    showModalBottomSheet(
      context: pageContext,
      isScrollControlled: true,
      builder:
          (sheetContext) => SafeModalSheetScrollable(
            children: [
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.blue),
                title: const Text('重命名'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showRenameWebsiteDialog(pageContext, website, index);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.link, color: Colors.green),
                title: const Text('复制网址'),
                onTap: () {
                  final url = website['url']?.toString() ?? '';
                  if (url.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: url));
                    Navigator.pop(sheetContext);
                    if (pageContext.mounted) {
                      ScaffoldMessenger.of(pageContext).showSnackBar(
                        const SnackBar(
                          content: Text('网址已复制到剪贴板'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  }
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('删除'),
                onTap: () async {
                  // 先显示确认对话框（此时 sheet 仍打开，sheetContext 有效）
                  final shouldDelete =
                      await showDialog<bool>(
                        context: sheetContext,
                        builder:
                            (ctx) => AlertDialog(
                              title: const Text('删除网站'),
                              content: Text('确定要删除 ${website['name']} 吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                      ) ??
                      false;
                  if (!shouldDelete) return;
                  // 关闭底部面板后再执行删除，使用 pageContext 确保有效
                  if (!pageContext.mounted) return;
                  Navigator.pop(sheetContext);
                  // 使用 pageContext 显示加载框并执行删除
                  showDialog(
                    context: pageContext,
                    barrierDismissible: false,
                    builder:
                        (_) => const AlertDialog(
                          content: Row(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(width: 20),
                              Text('删除中...'),
                            ],
                          ),
                        ),
                  );
                  // 若 index 可能失效，则按 url 重新查找
                  int idx = index;
                  if (idx < 0 || idx >= _commonWebsites.length) {
                    idx = _commonWebsites.indexWhere(
                      (s) => s['url'] == website['url'],
                    );
                  }
                  if (idx >= 0) {
                    await _removeWebsite(idx);
                  }
                  if (pageContext.mounted) {
                    Navigator.of(pageContext).pop();
                  }
                },
              ),
            ],
          ),
    );
  }

  Future<void> _loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final bookmarksJsonString = prefs.getString('bookmarks');
      setState(() {
        _bookmarks.clear();
        if (bookmarksJsonString != null && bookmarksJsonString.isNotEmpty) {
          final decoded = jsonDecode(bookmarksJsonString);
          if (decoded.isNotEmpty &&
              decoded[0] is Map<String, dynamic> &&
              decoded[0].containsKey('name') &&
              decoded[0].containsKey('url')) {
            _bookmarks =
                (decoded as List)
                    .map(
                      (item) => {
                        'name': item['name']?.toString() ?? '',
                        'url': item['url']?.toString() ?? '',
                      },
                    )
                    .toList();
          } else if (decoded.isNotEmpty && decoded[0] is String) {
            _bookmarks =
                (decoded as List<String>)
                    .map(
                      (url) => {'name': url, 'url': url} as Map<String, String>,
                    )
                    .toList();
            _saveBookmarks();
          }
        }
        if (_bookmarks.isEmpty) {
          _bookmarks = [
            {'name': '百度', 'url': 'https://www.baidu.com'},
            {'name': 'Bilibili', 'url': 'https://www.bilibili.com'},
          ];
          _saveBookmarks();
        }
      });
    } catch (e) {
      debugPrint('Error loading bookmarks: $e');
    }
  }

  Future<void> _saveCommonWebsites() async {
    try {
      // 确保_commonWebsites不为空
      if (_commonWebsites.isEmpty) {
        debugPrint('警告：尝试保存空的常用网站列表，将加载默认网站');
        _commonWebsites.addAll([
          {
            'name': 'Google',
            'url': 'https://www.google.com',
            'iconCode': Icons.public.codePoint,
          },
          {
            'name': '百度',
            'url': 'https://www.baidu.com',
            'iconCode': Icons.public.codePoint,
          },
        ]);
      }

      final prefs = await SharedPreferences.getInstance();
      final cleanedWebsites =
          _commonWebsites
              .map(
                (site) => {
                  'name': site['name'],
                  'url': site['url'],
                  'iconCode': Icons.public.codePoint,
                },
              )
              .toList();
      final jsonString = jsonEncode(cleanedWebsites);

      // 先获取旧数据作为备份
      final oldJsonString = prefs.getString('common_websites');

      // 直接设置新数据，不先移除
      final success = await prefs.setString('common_websites', jsonString);

      if (success) {
        debugPrint('成功保存了${cleanedWebsites.length}个常用网站');
      } else {
        debugPrint('保存常用网站失败，尝试恢复旧数据');
        if (oldJsonString != null) {
          await prefs.setString('common_websites', oldJsonString);
        }
      }
    } catch (e) {
      debugPrint('Error saving common websites: $e');
    }
  }

  Future<void> _handleDownload(
    String url,
    String contentDisposition,
    String mimeType, {
    MediaType? selectedType,
  }) async {
    try {
      final absoluteUrl = _toAbsoluteUrl(url);
      debugPrint('开始处理下载: $absoluteUrl, MIME类型: $mimeType');
      if (_downloadingUrls.contains(absoluteUrl)) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该文件正在下载中，请稍候...')));
        return;
      }

      String processedUrl = absoluteUrl;
      if (absoluteUrl.contains('youtube.com') ||
          absoluteUrl.contains('youtu.be')) {
        processedUrl = await _resolveYouTubeUrl(absoluteUrl);
      }

      if (selectedType == null) {
        final result = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (context) => _buildDownloadDialog(processedUrl, mimeType),
        );
        if (result != null) {
          final bool shouldDownload = result['download'];
          final MediaType mediaType = result['mediaType'];
          if (shouldDownload && mediaType != MediaType.audio) {
            if (mediaType == MediaType.video) {
              final existing = await _findExistingVideoBeforeDownload(
                processedUrl,
              );
              if (existing != null) {
                final downloadAnyway =
                    await _confirmSourceUrlDuplicateBeforeDownload(existing);
                if (!downloadAnyway) return;
              }
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('开始下载，将在后台进行...'),
                duration: Duration(seconds: 2),
              ),
            );
            _performBackgroundDownload(processedUrl, mediaType);
          } else if (mediaType == MediaType.audio) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('当前仅支持下载图片和视频，不支持音频')));
          }
        }
      } else {
        if (selectedType == MediaType.video) {
          final existing = await _findExistingVideoBeforeDownload(processedUrl);
          if (existing != null) {
            final downloadAnyway =
                await _confirmSourceUrlDuplicateBeforeDownload(existing);
            if (!downloadAnyway) return;
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('开始下载，将在后台进行...'),
            duration: Duration(seconds: 2),
          ),
        );
        _performBackgroundDownload(processedUrl, selectedType);
      }
    } catch (e, stackTrace) {
      debugPrint('处理下载时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载出错: $e')));
    }
  }

  Future<String> _resolveYouTubeUrl(String url) async {
    return url; // 占位符，需集成 youtube_explode_dart
  }

  Widget _buildDownloadDialog(String url, String mimeType) {
    MediaType detected = _determineMediaType(mimeType);
    // 仅支持图片和视频，音频不提供下载
    MediaType selectedType =
        (detected == MediaType.audio) ? MediaType.image : detected;
    return StatefulBuilder(
      builder:
          (context, setState) => AlertDialog(
            title: const Text('下载媒体'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('您想下载这个文件吗？'),
                const SizedBox(height: 8),
                Text(
                  'URL: $url',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                const Text('选择媒体类型:'),
                RadioListTile<MediaType>(
                  title: const Text('图片'),
                  value: MediaType.image,
                  groupValue: selectedType,
                  onChanged: (value) => setState(() => selectedType = value!),
                ),
                RadioListTile<MediaType>(
                  title: const Text('视频'),
                  value: MediaType.video,
                  groupValue: selectedType,
                  onChanged: (value) => setState(() => selectedType = value!),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop({'download': true, 'mediaType': selectedType}),
                child: const Text('下载'),
              ),
            ],
          ),
    );
  }

  MediaType _determineMediaType(String mimeType) {
    if (mimeType.startsWith('image/')) return MediaType.image;
    if (mimeType.startsWith('video/')) return MediaType.video;
    if (mimeType.startsWith('audio/')) return MediaType.audio;
    // HLS 在 _guessMimeType 中为 application/x-mpegURL，必须走视频下载逻辑（超时、重试、M3U8 合并）
    if (mimeType == 'application/x-mpegURL' ||
        mimeType == 'application/vnd.apple.mpegurl' ||
        mimeType.contains('mpegurl')) {
      return MediaType.video;
    }
    return MediaType.image;
  }

  bool _urlLooksLikeVideoStream(String url) {
    final u = url.toLowerCase();
    if (u.contains('.m3u8') || u.contains('.m3u')) return true;
    return RegExp(
      r'\.(mp4|webm|mov|ts)(\?|#|$)',
      caseSensitive: false,
    ).hasMatch(u);
  }

  bool _isDownloadableLink(String url) {
    debugPrint('检查URL是否为可下载链接: $url');
    final fileExtensions = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.svg',
      '.ico',
      '.mp4',
      '.avi',
      '.mov',
      '.wmv',
      '.flv',
      '.mkv',
      '.webm',
      '.m3u8',
      '.ts',
      '.mp3',
      '.wav',
      '.ogg',
      '.aac',
      '.flac',
      '.m4a',
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.ppt',
      '.pptx',
      '.txt',
      '.zip',
      '.rar',
      '.7z',
      '.tar',
      '.gz',
      '.exe',
      '.apk',
      '.dmg',
      '.iso',
    ];
    final lowercaseUrl = url.toLowerCase();
    for (final ext in fileExtensions) {
      if (lowercaseUrl.endsWith(ext)) return true;
    }
    final downloadKeywords = [
      '/download/',
      '/dl/',
      '/attachment/',
      '/file/',
      '/media/download/',
      '/photo/download/',
      '/video/download/',
      '/document/download/',
    ];
    for (final keyword in downloadKeywords) {
      if (lowercaseUrl.contains(keyword)) return true;
    }
    final downloadParams = ['download=true', 'dl=1', 'attachment=1'];
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final queryString = uri.query.toLowerCase();
    for (final param in downloadParams) {
      if (queryString.contains(param)) return true;
    }
    if (url.contains('youtube.com') || url.contains('youtu.be')) return true;
    return false;
  }

  String _guessMimeType(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return 'application/octet-stream';
    final extension = _getFileExtension(uri.path);
    if (extension == '.jpg' || extension == '.jpeg') return 'image/jpeg';
    if (extension == '.png') return 'image/png';
    if (extension == '.gif') return 'image/gif';
    if (extension == '.bmp') return 'image/bmp';
    if (extension == '.webp') return 'image/webp';
    if (extension == '.mp4') return 'video/mp4';
    if (extension == '.avi') return 'video/x-msvideo';
    if (extension == '.mov') return 'video/quicktime';
    if (extension == '.wmv') return 'video/x-ms-wmv';
    if (extension == '.flv') return 'video/x-flv';
    if (extension == '.mkv') return 'video/x-matroska';
    if (extension == '.webm') return 'video/webm';
    if (extension == '.m3u8') return 'application/x-mpegURL';
    if (extension == '.mpd') return 'application/dash+xml';
    if (extension == '.mp3') return 'audio/mpeg';
    if (extension == '.wav') return 'audio/wav';
    if (extension == '.ogg') return 'audio/ogg';
    if (extension == '.aac') return 'audio/aac';
    if (extension == '.flac') return 'audio/flac';
    return 'application/octet-stream';
  }

  /// 清理媒体 URL：移除会导致 400 的图片处理参数，获取原始媒体
  /// 网页中媒体常带 CDN 处理参数用于缩略/懒加载，参数不完整时返回 400
  String _getCleanMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.query.isEmpty) return url;
    const transformParams = <String>[
      'x-bce-process',
      'image/resize',
      'image/format',
      'image/quality',
      'image/crop',
      'image/watermark',
      'imagemogr2',
      'imageview2',
    ];
    final kept = <String, dynamic>{};
    var removedTransform = false;
    for (final entry in uri.queryParametersAll.entries) {
      final lowerKey = entry.key.toLowerCase();
      if (transformParams.any(lowerKey.contains)) {
        removedTransform = true;
        continue;
      }
      kept[entry.key] =
          entry.value.length == 1 ? entry.value.first : entry.value;
    }
    if (!removedTransform) return url;
    if (kept.isEmpty) return uri.replace(query: '').toString();
    return uri.replace(queryParameters: kept).toString();
  }

  String? _safeHttpOrigin(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return null;
    if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return uri.origin;
    }
    return null;
  }

  /// 根据 URL 和当前页面返回合适的 Referer，用于绕过反盗链
  String _getMediaReferer(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('baidu.com') || lower.contains('bdstatic.com'))
      return 'https://www.baidu.com';
    if (lower.contains('gstatic.com') ||
        lower.contains('googleusercontent.com') ||
        lower.contains('google.com'))
      return 'https://www.google.com';
    if (lower.contains('bing.com') || lower.contains('bcbits.com'))
      return 'https://www.bing.com';
    if (lower.contains('twitter.com') || lower.contains('twimg.com'))
      return 'https://twitter.com';
    if (lower.contains('facebook.com') || lower.contains('fbcdn.net'))
      return 'https://www.facebook.com';
    if (lower.contains('instagram.com') || lower.contains('cdninstagram.com'))
      return 'https://www.instagram.com';
    if (lower.contains('zhihu.com')) return 'https://www.zhihu.com';
    if (lower.contains('weibo.com') || lower.contains('sinaimg.cn'))
      return 'https://weibo.com';
    if (lower.contains('xvideos.') ||
        lower.contains('xvideos-cdn') ||
        lower.contains('xv-vod') ||
        lower.contains('xnxx.')) {
      final page =
          _urlController.text.trim().isNotEmpty
              ? _urlController.text.trim()
              : _currentUrl;
      if (page.startsWith('http') && page.toLowerCase().contains('xvideos.')) {
        return page;
      }
      return 'https://www.xvideos.com';
    }
    if (lower.contains('xcdn') ||
        lower.contains('cdn1.') ||
        lower.contains('cdn101')) {
      final page =
          _urlController.text.trim().isNotEmpty
              ? _urlController.text.trim()
              : _currentUrl;
      if (page.startsWith('http')) return page;
    }
    final pageUrl =
        _urlController.text.trim().isNotEmpty
            ? _urlController.text.trim()
            : _currentUrl;
    if (pageUrl.startsWith('http')) return pageUrl;
    return _safeHttpOrigin(pageUrl) ?? 'https://www.google.com';
  }

  /// 403 时尝试的 Referer 列表（按优先级）
  List<String> _getRefererCandidates(String mediaUrl) {
    final page =
        _urlController.text.trim().isNotEmpty
            ? _urlController.text.trim()
            : _currentUrl;
    final candidates = <String>[];
    if (page.startsWith('http')) {
      candidates.add(page);
      try {
        final origin = Uri.parse(page).origin;
        candidates.add(origin);
        candidates.add('$origin/');
      } catch (_) {}
    }
    candidates.add(_getMediaReferer(mediaUrl));
    if (_isXVideoLikeHost(mediaUrl) ||
        page.toLowerCase().contains('xvideos.')) {
      candidates.add('https://www.xvideos.com');
      candidates.add('https://www.xvideos.com/');
      candidates.add('https://www.xvideos.com/video');
    }
    return candidates.toSet().toList();
  }

  bool _isValidVideoBytes(List<int> bytes) {
    if (bytes.length < 8) return false;
    final box = String.fromCharCodes(bytes.sublist(4, 8));
    return box == 'ftyp' ||
        box == 'styp' ||
        box == 'moov' ||
        box == 'moof' ||
        box == 'mdat';
  }

  bool _isValidWebmBytes(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3;
  }

  bool _startsWithAscii(List<int> bytes, String value, [int offset = 0]) {
    if (offset < 0 || bytes.length < offset + value.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  String? _detectImageExtension(List<int> bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes[0] == 0x89 && _startsWithAscii(bytes, 'PNG', 1)) return '.png';
    if (_startsWithAscii(bytes, 'GIF8')) return '.gif';
    if (_startsWithAscii(bytes, 'RIFF') && _startsWithAscii(bytes, 'WEBP', 8)) {
      return '.webp';
    }
    if (_startsWithAscii(bytes, 'BM')) return '.bmp';
    if ((bytes[0] == 0x49 &&
            bytes[1] == 0x49 &&
            bytes[2] == 0x2A &&
            bytes[3] == 0x00) ||
        (bytes[0] == 0x4D &&
            bytes[1] == 0x4D &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x2A)) {
      return '.tiff';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0 &&
        bytes[1] == 0 &&
        bytes[2] == 1 &&
        bytes[3] == 0) {
      return '.ico';
    }
    if (bytes.length >= 12 && _startsWithAscii(bytes, 'ftyp', 4)) {
      final brand =
          String.fromCharCodes(
            bytes.sublist(8, min(64, bytes.length)),
          ).toLowerCase();
      if (brand.contains('avif') || brand.contains('avis')) return '.avif';
      if (brand.contains('heic') ||
          brand.contains('heix') ||
          brand.contains('hevc') ||
          brand.contains('hevx') ||
          brand.contains('mif1') ||
          brand.contains('msf1')) {
        return '.heic';
      }
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x00 &&
        bytes[3] == 0x0C &&
        _startsWithAscii(bytes, 'JXL ', 4)) {
      return '.jxl';
    }
    if (bytes[0] == 0xFF && bytes[1] == 0x0A) return '.jxl';
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    if (text.startsWith('<svg') ||
        (text.startsWith('<?xml') && text.toLowerCase().contains('<svg'))) {
      return '.svg';
    }
    return null;
  }

  String? _detectVideoExtension(List<int> bytes) {
    if (_isValidVideoBytes(bytes)) {
      if (bytes.length >= 12) {
        final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
        if (brand.startsWith('qt')) return '.mov';
      }
      return '.mp4';
    }
    if (_isValidWebmBytes(bytes)) {
      final headerText =
          String.fromCharCodes(
            bytes.sublist(0, min(4096, bytes.length)),
          ).toLowerCase();
      return headerText.contains('matroska') ? '.mkv' : '.webm';
    }
    if (_isLikelyMpegTs(bytes)) return '.ts';
    if (_startsWithAscii(bytes, 'FLV')) return '.flv';
    if (_startsWithAscii(bytes, 'RIFF') && _startsWithAscii(bytes, 'AVI ', 8)) {
      return '.avi';
    }
    if (_startsWithAscii(bytes, 'OggS')) return '.ogv';
    const asfHeader = <int>[
      0x30,
      0x26,
      0xB2,
      0x75,
      0x8E,
      0x66,
      0xCF,
      0x11,
      0xA6,
      0xD9,
      0x00,
      0xAA,
      0x00,
      0x62,
      0xCE,
      0x6C,
    ];
    if (bytes.length >= asfHeader.length) {
      var isAsf = true;
      for (var i = 0; i < asfHeader.length; i++) {
        if (bytes[i] != asfHeader[i]) {
          isAsf = false;
          break;
        }
      }
      if (isAsf) return '.wmv';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x01 &&
        (bytes[3] == 0xBA || bytes[3] == 0xB3)) {
      return '.mpeg';
    }
    return null;
  }

  bool _isSupportedExtensionForType(String extension, MediaType mediaType) {
    final ext = extension.toLowerCase();
    if (mediaType == MediaType.image) {
      return const <String>{
        '.jpg',
        '.jpeg',
        '.png',
        '.gif',
        '.webp',
        '.bmp',
        '.tif',
        '.tiff',
        '.ico',
        '.svg',
        '.avif',
        '.heic',
        '.heif',
        '.jxl',
      }.contains(ext);
    }
    if (mediaType == MediaType.video) {
      return const <String>{
        '.mp4',
        '.webm',
        '.mov',
        '.mkv',
        '.avi',
        '.flv',
        '.wmv',
        '.ts',
        '.mts',
        '.mpeg',
        '.mpg',
        '.m4v',
        '.3gp',
        '.ogv',
        '.m3u8',
        '.m3u',
        '.mpd',
      }.contains(ext);
    }
    return true;
  }

  Future<File> _normalizeDownloadedMediaFile(
    File file,
    MediaType mediaType,
  ) async {
    final length = await file.length();
    final probeLength = min(length, 4096);
    final bytes = await file
        .openRead(0, probeLength)
        .fold<List<int>>([], (previous, chunk) => previous..addAll(chunk));
    final detectedExtension =
        mediaType == MediaType.image
            ? _detectImageExtension(bytes)
            : mediaType == MediaType.video
            ? _detectVideoExtension(bytes)
            : null;
    if (detectedExtension == null) {
      final sample = utf8.decode(
        bytes.take(256).toList(),
        allowMalformed: true,
      );
      final lower = sample.trimLeft().toLowerCase();
      final looksLikeErrorDocument =
          lower.startsWith('<!doctype') ||
          lower.startsWith('<html') ||
          lower.startsWith('{') ||
          lower.startsWith('[');
      throw Exception(
        looksLikeErrorDocument
            ? '[下载失败] 服务器返回了网页/JSON而不是媒体，登录态或防盗链校验可能已失效'
            : '[下载失败] 下载内容不是受支持的有效媒体文件',
      );
    }
    final currentExtension = p.extension(file.path).toLowerCase();
    if (currentExtension == detectedExtension ||
        (currentExtension == '.jpeg' && detectedExtension == '.jpg') ||
        (currentExtension == '.tif' && detectedExtension == '.tiff') ||
        (currentExtension == '.heif' && detectedExtension == '.heic')) {
      return file;
    }
    final corrected = File(p.setExtension(file.path, detectedExtension));
    if (await corrected.exists()) await corrected.delete();
    return file.rename(corrected.path);
  }

  String _extensionForBase64Media(String mediaType, String mimeType) {
    final mime = mimeType.toLowerCase();
    if (mediaType == 'image') {
      if (mime.contains('png')) {
        return '.png';
      }
      if (mime.contains('gif')) {
        return '.gif';
      }
      if (mime.contains('webp')) {
        return '.webp';
      }
      return '.jpg';
    }
    if (mediaType == 'audio') {
      if (mime.contains('mpeg') || mime.contains('mp3')) {
        return '.mp3';
      }
      if (mime.contains('wav')) {
        return '.wav';
      }
      if (mime.contains('ogg')) {
        return '.ogg';
      }
      return '.webm';
    }
    if (mime.contains('webm')) {
      return '.webm';
    }
    if (mime.contains('quicktime')) {
      return '.mov';
    }
    if (mime.contains('x-matroska')) {
      return '.mkv';
    }
    return '.mp4';
  }

  Future<int?> _probeNativeVideoDurationMs(File file) async {
    try {
      return await const MethodChannel('media_muxer').invokeMethod<int>(
        'probeDurationMs',
        <String, String>{'path': file.path},
      );
    } catch (e) {
      debugPrint('读取视频时长失败: $e');
      return null;
    }
  }

  Future<File?> _remuxNativeVideoToMp4(File source) async {
    final output = File(p.setExtension(source.path, '.seekable.mp4'));
    try {
      if (await output.exists()) await output.delete();
      final ok =
          await const MethodChannel('media_muxer').invokeMethod<bool>(
            'remuxMp4',
            <String, String>{
              'inputPath': source.path,
              'outputPath': output.path,
            },
          ) ==
          true;
      if (!ok || !await output.exists() || await output.length() == 0) {
        return null;
      }
      final finalFile = File(p.setExtension(source.path, '.mp4'));
      if (await finalFile.exists()) await finalFile.delete();
      final renamed = await output.rename(finalFile.path);
      try {
        if (await source.exists()) await source.delete();
      } catch (_) {}
      return renamed;
    } catch (e) {
      debugPrint('HLS MP4 remux failed, keeping original stream: $e');
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<bool> _isUsefulSmartDownloadedMedia(
    File file,
    MediaType mediaType,
  ) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (mediaType == MediaType.image) {
      if (length < 1024) return false;
      final bytes = await file.readAsBytes();
      return Isolate.run(() => _hasUsefulRasterContent(bytes));
    }
    if (mediaType != MediaType.video || length < 64 * 1024) return false;
    final durationMs = await _probeNativeVideoDurationMs(file);
    // Some valid HLS/TS containers are playable by ExoPlayer but Android's
    // metadata retriever reports 0. Treat 0 as unknown, not as a zero-length
    // video, otherwise smart download repeatedly fetches other renditions.
    if (durationMs != null && durationMs > 0 && durationMs < 500) return false;

    // If frame extraction is unsupported for this container/codec, retain the
    // already format-validated video instead of creating a false negative.
    final sampleTimes =
        durationMs != null && durationMs > 3000
            ? <int>[durationMs ~/ 5, durationMs ~/ 2, durationMs * 4 ~/ 5]
            : const <int>[0];
    var decodedFrames = 0;
    for (final timeMs in sampleTimes) {
      try {
        final bytes = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 192,
          quality: 60,
          timeMs: timeMs,
        );
        if (bytes == null || bytes.isEmpty) continue;
        decodedFrames++;
        if (await Isolate.run(() => _hasUsefulRasterContent(bytes))) {
          return true;
        }
      } catch (_) {}
    }
    return decodedFrames == 0;
  }

  /// HLS 分片拼接后为 MPEG-TS，与 MP4 头不同；Android ExoPlayer 可播放 `.ts`。
  bool _isLikelyMpegTs(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final scanLimit = min(bytes.length, 188);
    for (var offset = 0; offset < scanLimit; offset++) {
      if (bytes[offset] != 0x47) continue;
      if (offset + 188 >= bytes.length || bytes[offset + 188] == 0x47) {
        return true;
      }
    }
    return false;
  }

  bool _bytesLookLikeHlsPlaylistText(List<int> bytes) {
    if (bytes.length < 7) return false;
    final s =
        utf8
            .decode(bytes.take(64).toList(), allowMalformed: true)
            .replaceFirst('\uFEFF', '')
            .trimLeft();
    return s.startsWith('#EXTM3U') ||
        s.startsWith('#EXTINF') ||
        s.startsWith('#EXT-X-VERSION');
  }

  Dio _createDownloadDio({
    Duration? connectTimeout,
    Duration? receiveTimeout,
    bool forVideoDownload = false,
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: connectTimeout ?? const Duration(seconds: 15),
        receiveTimeout:
            receiveTimeout ??
            (forVideoDownload
                ? const Duration(seconds: 60)
                : const Duration(seconds: 30)),
        sendTimeout: const Duration(seconds: 15),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );
    (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
      final client = HttpClient();
      client.badCertificateCallback = (_, __, ___) => true;
      if (forVideoDownload) {
        // 与 HLS 多路并行拉分片配合，避免同一 CDN 主机上连接数不足导致请求在本地排队
        client.maxConnectionsPerHost = _kHlsMaxConnectionsPerHost;
        client.idleTimeout = const Duration(seconds: 90);
      }
      return client;
    };
    return dio;
  }

  bool _videoExtensionSupportsParallelRange(String ext) {
    switch (ext.toLowerCase()) {
      case '.mp4':
      case '.webm':
      case '.mov':
      case '.mkv':
      case '.m4v':
      case '.avi':
      case '.flv':
      case '.wmv':
      case '.ts':
      case '.mpeg':
      case '.mpg':
      case '.3gp':
      case '.ogv':
        return true;
      default:
        return false;
    }
  }

  /// 探测是否可按字节范围分段下载；返回资源总字节数，否则 null。
  Future<int?> _probeVideoTotalBytesForRangeDownload(
    Dio dio,
    String url,
    Map<String, String> headers,
  ) async {
    try {
      final headResp = await dio.head<dynamic>(
        url,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (c) => c != null && c >= 200 && c < 400,
          headers: headers,
        ),
      );
      final code = headResp.statusCode ?? 0;
      if (code >= 200 && code < 300) {
        final cl = headResp.headers.value('content-length');
        final ar = headResp.headers.value('accept-ranges')?.toLowerCase();
        if (cl != null) {
          final len = int.tryParse(cl.trim());
          if (len != null &&
              len >= _kParallelRangeVideoMinBytes &&
              (ar == null || ar.contains('bytes'))) {
            return len;
          }
        }
      }
    } catch (e) {
      debugPrint('Range 探测 HEAD 失败（可忽略）: $e');
    }
    try {
      final r = await dio.get<dynamic>(
        url,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (c) => c == 206,
          headers: {...headers, 'Range': 'bytes=0-0'},
          responseType: ResponseType.bytes,
        ),
      );
      if (r.statusCode != 206) return null;
      final cr = r.headers.value('content-range');
      if (cr == null) return null;
      final m = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(cr);
      if (m != null) {
        final total = int.tryParse(m.group(1)!);
        if (total != null && total >= _kParallelRangeVideoMinBytes)
          return total;
      }
    } catch (e) {
      debugPrint('Range 探测 GET 失败（可忽略）: $e');
    }
    return null;
  }

  int _parallelRangePartsForTotalSize(int totalBytes) {
    if (totalBytes < _kParallelRangeVideoMinBytes) return 1;
    if (totalBytes < 32 * 1024 * 1024)
      return min(4, _kParallelRangeVideoConnections);
    if (totalBytes < 128 * 1024 * 1024)
      return min(6, _kParallelRangeVideoConnections);
    return _kParallelRangeVideoConnections;
  }

  List<(int start, int end)> _splitByteRanges(int totalBytes, int parts) {
    final n = max(1, parts);
    if (totalBytes <= 0) return [];
    final chunk = (totalBytes / n).ceil();
    final out = <(int, int)>[];
    for (var i = 0; i < n; i++) {
      final start = i * chunk;
      if (start >= totalBytes) break;
      final end = min(start + chunk - 1, totalBytes - 1);
      out.add((start, end));
    }
    return out;
  }

  /// 使用 Range 多连接并行下载单文件视频；失败返回 null，由调用方回退单连接 [dio.download]。
  Future<File?> _tryParallelRangeVideoDownload({
    required Dio downloadDio,
    required String url,
    required String filePath,
    required Map<String, String> requestHeaders,
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
    ValueChanged<int>? onTotalBytesKnown,
  }) async {
    final headers = requestHeaders;

    int? totalBytes;
    try {
      totalBytes = await _probeVideoTotalBytesForRangeDownload(
        downloadDio,
        url,
        headers,
      );
    } catch (_) {
      return null;
    }
    if (totalBytes == null) return null;
    final byteTotal = totalBytes;
    onTotalBytesKnown?.call(byteTotal);
    if (cancelToken?.isCancelled == true) return null;

    final parts = _parallelRangePartsForTotalSize(byteTotal);
    if (parts < 2) return null;

    final ranges = _splitByteRanges(byteTotal, parts);
    if (ranges.length < 2) return null;

    if (kDebugMode) {
      debugPrint(
        '视频下载：已启用 Range 多连接（${_formatBytes(byteTotal)}，${ranges.length} 路并行；非 NetworkService 的 HEAD 日志）',
      );
    }

    final partPaths = List<String>.generate(
      ranges.length,
      (i) => '$filePath.part$i',
    );
    final perPart = List<int>.filled(ranges.length, 0);

    Future<void> downloadOneRange(int ri) async {
      final (start, end) = ranges[ri];
      final expectLen = end - start + 1;
      final partPath = partPaths[ri];
      final r = await downloadDio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (code) => code == 206,
          headers: {...headers, 'Range': 'bytes=$start-$end'},
          responseType: ResponseType.stream,
        ),
      );
      if (r.statusCode != 206 || r.data == null) {
        throw DioException(
          requestOptions: r.requestOptions,
          message: 'Range 分片 HTTP ${r.statusCode}',
        );
      }
      final sink = File(partPath).openWrite();
      try {
        await for (final chunk in r.data!.stream) {
          perPart[ri] += chunk.length;
          final sum = perPart.fold<int>(0, (a, b) => a + b);
          onProgress?.call(
            sum / byteTotal,
            detail: '多连接 ${_formatBytes(sum)} / ${_formatBytes(byteTotal)}',
          );
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final got = await File(partPath).length();
      if (got != expectLen) {
        throw StateError('分片 $ri 大小不符: 期望 $expectLen 实际 $got');
      }
    }

    try {
      onProgress?.call(0, detail: '多连接并行 (${ranges.length} 路)…');
      await Future.wait(List.generate(ranges.length, downloadOneRange));

      final outSink = File(filePath).openWrite();
      try {
        for (final pp in partPaths) {
          await outSink.addStream(File(pp).openRead());
        }
      } finally {
        await outSink.close();
      }

      for (final pp in partPaths) {
        try {
          final f = File(pp);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      final len = await File(filePath).length();
      if (len != byteTotal) {
        try {
          await File(filePath).delete();
        } catch (_) {}
        return null;
      }
      return File(filePath);
    } catch (e, st) {
      if (cancelToken?.isCancelled == true) rethrow;
      debugPrint('Range 多连接下载失败，将回退单连接: $e\n$st');
      for (final pp in partPaths) {
        try {
          final f = File(pp);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      try {
        if (await File(filePath).exists()) await File(filePath).delete();
      } catch (_) {}
      return null;
    }
  }

  Future<File> _finalizeDirectMediaDownload({
    required File file,
    required MediaType mediaType,
    required String sourceUrl,
    required Dio downloadDio,
    required Map<String, String> requestHeaders,
    DownloadProgressCallback? onProgress,
  }) async {
    if (!await file.exists()) {
      throw Exception('[下载失败] 文件未创建，可能被服务器拒绝访问');
    }
    final size = await file.length();
    if (size == 0) {
      await file.delete();
      throw Exception('[下载失败] 文件大小为0，服务器可能返回了空内容或需要特殊鉴权');
    }
    if (mediaType == MediaType.video && size < 2 * 1024 * 1024) {
      final peek = await file
          .openRead(0, min(size, 4096))
          .fold<List<int>>([], (previous, chunk) => previous..addAll(chunk));
      if (_bytesLookLikeHlsPlaylistText(peek)) {
        final merged = await _handleM3u8Download(
          file.path,
          sourceUrl,
          downloadDio,
          requestHeaders: requestHeaders,
          onMergeProgress: (completed, totalSegments, mergedBytes) {
            final fraction =
                totalSegments > 0
                    ? 0.02 + (completed / totalSegments) * 0.98
                    : 0.5;
            onProgress?.call(
              fraction.clamp(0.0, 1.0),
              detail:
                  'HLS 分片 $completed/$totalSegments · 已合并 ${_formatBytes(mergedBytes)}',
            );
          },
        );
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        if (merged == null ||
            !await merged.exists() ||
            await merged.length() == 0) {
          throw Exception('[下载失败] M3U8 解析或合并失败');
        }
        return merged;
      }
    }
    return _normalizeDownloadedMediaFile(file, mediaType);
  }

  Future<File?> _downloadFile(
    String url,
    MediaType mediaType, {
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
    int? maxRequestAttempts,
    ValueChanged<int>? onTotalBytesKnown,
  }) async {
    try {
      final absoluteUrl = _toAbsoluteUrl(url);
      final downloadUrl = absoluteUrl;
      debugPrint('开始下载文件，URL: $downloadUrl');
      final downloadDio =
          mediaType == MediaType.image
              ? _createDownloadDio(
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 10),
              )
              : _createDownloadDio(forVideoDownload: true);

      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      final uuid = const Uuid().v4();
      final uri = Uri.tryParse(absoluteUrl);
      if (uri == null) throw Exception('Invalid URL: $absoluteUrl');
      if (mediaType == MediaType.video &&
          p.extension(uri.path).toLowerCase() == '.mpd') {
        final headers = await _browserLikeMediaHeaders(
          absoluteUrl,
          referer: _getMediaReferer(absoluteUrl),
          includeOrigin: true,
          accept: 'application/dash+xml,application/xml,text/xml,*/*',
        );
        return await _downloadDashManifest(
          manifestUrl: absoluteUrl,
          downloadDio: downloadDio,
          mediaDir: mediaDir,
          outputId: uuid,
          requestHeaders: headers,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
      }
      String extension = _getFileExtension(uri.path);

      if (extension.isEmpty ||
          !_isSupportedExtensionForType(extension, mediaType)) {
        final mimeType = _guessMimeType(absoluteUrl);
        if (mimeType.startsWith('image/')) {
          extension =
              mimeType == 'image/png'
                  ? '.png'
                  : mimeType == 'image/gif'
                  ? '.gif'
                  : mimeType == 'image/webp'
                  ? '.webp'
                  : '.jpg';
        } else if (mimeType.startsWith('video/') ||
            mimeType == 'application/x-mpegURL') {
          extension = '.mp4';
        } else if (mimeType.startsWith('audio/')) {
          extension = '.mp3';
        } else {
          extension =
              mediaType == MediaType.image
                  ? '.jpg'
                  : mediaType == MediaType.video
                  ? '.mp4'
                  : mediaType == MediaType.audio
                  ? '.mp3'
                  : '.bin';
        }
      }

      final filePath = '${mediaDir.path}/$uuid$extension';
      debugPrint('将下载到文件路径: $filePath');

      final refererCandidates = _getRefererCandidates(absoluteUrl);
      final urlCandidates = <String>[absoluteUrl];
      final cleanedUrl = _getCleanMediaUrl(absoluteUrl);
      if (cleanedUrl != absoluteUrl) urlCandidates.add(cleanedUrl);
      final requestAttempts =
          <({String url, String referer, bool includeOrigin})>[];
      final attemptKeys = <String>{};
      void addAttempt(String candidate, String referer, bool includeOrigin) {
        final key = '$candidate\n$referer\n$includeOrigin';
        if (attemptKeys.add(key)) {
          requestAttempts.add((
            url: candidate,
            referer: referer,
            includeOrigin: includeOrigin,
          ));
        }
      }

      for (final candidate in urlCandidates) {
        for (final referer in refererCandidates) {
          addAttempt(candidate, referer, false);
        }
        for (final referer in refererCandidates.take(2)) {
          addAttempt(candidate, referer, true);
        }
      }
      final maxAttempts =
          maxRequestAttempts ?? (mediaType == MediaType.image ? 8 : 12);
      if (requestAttempts.length > maxAttempts) {
        requestAttempts.removeRange(maxAttempts, requestAttempts.length);
      }

      var attemptIndex = 0;
      while (attemptIndex < requestAttempts.length) {
        final attempt = requestAttempts[attemptIndex];
        final urlToTry = attempt.url;
        final referer = attempt.referer;
        try {
          debugPrint(
            '下载尝试 ${attemptIndex + 1}/${requestAttempts.length}, '
            'Referer: $referer, Origin: ${attempt.includeOrigin}',
          );

          final requestHeaders = await _browserLikeMediaHeaders(
            urlToTry,
            referer: referer,
            includeOrigin: attempt.includeOrigin,
            accept:
                mediaType == MediaType.image
                    ? 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8'
                    : '*/*',
          );

          if (mediaType == MediaType.video &&
              _videoExtensionSupportsParallelRange(extension) &&
              extension != '.m3u8' &&
              extension != '.m3u') {
            final parallelOk = await _tryParallelRangeVideoDownload(
              downloadDio: downloadDio,
              url: urlToTry,
              filePath: filePath,
              requestHeaders: requestHeaders,
              cancelToken: cancelToken,
              onProgress: onProgress,
              onTotalBytesKnown: onTotalBytesKnown,
            );
            if (parallelOk != null) {
              return await _finalizeDirectMediaDownload(
                file: parallelOk,
                mediaType: mediaType,
                sourceUrl: urlToTry,
                downloadDio: downloadDio,
                requestHeaders: requestHeaders,
                onProgress: onProgress,
              );
            }
          }

          final response = await downloadDio.download(
            urlToTry,
            filePath,
            deleteOnError: true,
            cancelToken: cancelToken,
            options: Options(
              followRedirects: true,
              maxRedirects: 5,
              validateStatus:
                  (status) => status != null && status >= 200 && status < 300,
              responseType: ResponseType.bytes,
              headers: requestHeaders,
            ),
            onReceiveProgress: (received, total) {
              if (total > 0) onTotalBytesKnown?.call(total);
              if (cancelToken?.isCancelled == true) return;
              if (onProgress == null) return;
              final isPlaylist = extension == '.m3u8' || extension == '.m3u';
              if (isPlaylist) {
                if (total > 0) {
                  onProgress(
                    (received / total) * 0.02,
                    detail:
                        '播放列表 ${_formatBytes(received)} / ${_formatBytes(total)}',
                  );
                } else {
                  onProgress(
                    0.01,
                    detail: '正在获取播放列表 ${_formatBytes(received)}…',
                  );
                }
              } else if (total > 0) {
                onProgress(
                  received / total,
                  detail: '${_formatBytes(received)} / ${_formatBytes(total)}',
                );
              } else {
                onProgress(0.0, detail: '已下载 ${_formatBytes(received)}（总大小未知）');
              }
            },
          );
          final successfulUrl =
              response.realUri.toString().isNotEmpty
                  ? response.realUri.toString()
                  : urlToTry;
          if (extension == '.m3u8' || extension == '.m3u') {
            final merged = await _handleM3u8Download(
              filePath,
              successfulUrl,
              downloadDio,
              requestHeaders: requestHeaders,
              onMergeProgress: (completed, totalSegs, mergedBytes) {
                final frac =
                    totalSegs > 0 ? 0.02 + (completed / totalSegs) * 0.98 : 0.5;
                onProgress?.call(
                  frac.clamp(0.0, 1.0),
                  detail:
                      'HLS 分片 $completed/$totalSegs · 已合并 ${_formatBytes(mergedBytes)}',
                );
              },
            );
            try {
              final pl = File(filePath);
              if (await pl.exists()) await pl.delete();
            } catch (_) {}
            if (merged == null || !await merged.exists()) {
              throw Exception('[下载失败] M3U8 无法解析或分片下载失败');
            }
            if (await merged.length() == 0) {
              try {
                await merged.delete();
              } catch (_) {}
              throw Exception('[下载失败] 合并后的视频为空');
            }
            final head = await merged
                .openRead(0, 512)
                .fold<List<int>>([], (prev, chunk) => [...prev, ...chunk]);
            if (!_isValidVideoBytes(head) && !_isLikelyMpegTs(head)) {
              try {
                await merged.delete();
              } catch (_) {}
              throw Exception('[下载失败] 合并结果不是可播放的视频数据');
            }
            return merged;
          }
          return await _finalizeDirectMediaDownload(
            file: File(filePath),
            mediaType: mediaType,
            sourceUrl: successfulUrl,
            downloadDio: downloadDio,
            requestHeaders: requestHeaders,
            onProgress: onProgress,
          );
        } catch (e, stackTrace) {
          try {
            final failedFile = File(filePath);
            if (await failedFile.exists()) await failedFile.delete();
          } catch (_) {}
          if (cancelToken?.isCancelled == true) rethrow;
          attemptIndex++;
          debugPrint(
            '下载失败 (尝试 $attemptIndex/${requestAttempts.length}): '
            '$e\n$stackTrace',
          );
          if (attemptIndex >= requestAttempts.length) rethrow;
          final retryDelayMs =
              mediaType == MediaType.image
                  ? (attemptIndex * 150).clamp(150, 500)
                  : (attemptIndex * 500).clamp(500, 2500);
          await Future.delayed(Duration(milliseconds: retryDelayMs));
        }
      }
      throw Exception('[下载失败] 所有请求方式均未能获得有效媒体内容');
    } on DioException catch (e, st) {
      String reason = '未知网络错误';
      if (e.type == DioExceptionType.connectionTimeout)
        reason = '连接超时，请检查网络';
      else if (e.type == DioExceptionType.receiveTimeout)
        reason = '接收超时，文件可能过大或网络慢';
      else if (e.type == DioExceptionType.sendTimeout)
        reason = '发送超时';
      else if (e.type == DioExceptionType.badResponse) {
        final code = e.response?.statusCode ?? 0;
        reason =
            '服务器返回 $code: ${code == 403
                ? "禁止访问(可能需Referer/登录)"
                : code == 404
                ? "文件不存在"
                : code == 400
                ? "请求错误"
                : "请检查URL"}';
      } else if (e.type == DioExceptionType.connectionError)
        reason = '连接失败: ${e.message ?? "无法连接服务器"}';
      else if (e.type == DioExceptionType.unknown)
        reason = '网络异常: ${e.message ?? e.error?.toString() ?? "未知"}';
      debugPrint('下载Dio错误: $e\n$st');
      throw Exception('[下载失败] $reason');
    } catch (e, stackTrace) {
      debugPrint('下载文件时出错: $e');
      debugPrint('错误堆栈: $stackTrace');
      if (e is Exception) rethrow;
      throw Exception('[下载失败] $e');
    }
  }

  Map<String, String> _dashAttributes(String source) {
    final out = <String, String>{};
    final pattern = RegExp(
      r'''([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*["']([^"']*)["']''',
    );
    for (final match in pattern.allMatches(source)) {
      out[match.group(1)!] = match.group(2)!;
    }
    return out;
  }

  double? _parseDashDurationSeconds(String value) {
    final match = RegExp(
      r'^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final hours = double.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = double.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(3) ?? '') ?? 0;
    return hours * 3600 + minutes * 60 + seconds;
  }

  String _expandDashTemplate(
    String template,
    String representationId, {
    int? number,
  }) {
    var value = template.replaceAll(r'$RepresentationID$', representationId);
    if (number != null) {
      value = value.replaceAllMapped(RegExp(r'\$Number(?:%0(\d+)d)?\$'), (
        match,
      ) {
        final width = int.tryParse(match.group(1) ?? '') ?? 0;
        return width > 0 ? number.toString().padLeft(width, '0') : '$number';
      });
    }
    return value;
  }

  List<_DashTrackPlan> _parseDashTrackPlans(String xml, String manifestUrl) {
    final manifestUri = Uri.parse(manifestUrl);
    final mpdMatch = RegExp(
      r'<MPD\b([^>]*)>',
      caseSensitive: false,
    ).firstMatch(xml);
    final mpdAttrs = _dashAttributes(mpdMatch?.group(1) ?? '');
    final presentationSeconds =
        _parseDashDurationSeconds(
          mpdAttrs['mediaPresentationDuration'] ?? '',
        ) ??
        _extractDashManifestDurationSeconds(xml);
    final plans = <_DashTrackPlan>[];
    final adaptationPattern = RegExp(
      r'<AdaptationSet\b([^>]*)>([\s\S]*?)</AdaptationSet>',
      caseSensitive: false,
    );
    for (final adaptation in adaptationPattern.allMatches(xml)) {
      final adaptationAttrs = _dashAttributes(adaptation.group(1) ?? '');
      final body = adaptation.group(2) ?? '';
      final nestedTemplateMatch = RegExp(
        r'<SegmentTemplate\b([^>]*)>([\s\S]*?)</SegmentTemplate>',
        caseSensitive: false,
      ).firstMatch(body);
      final selfClosingTemplateMatch = RegExp(
        r'<SegmentTemplate\b([^>]*)/>',
        caseSensitive: false,
      ).firstMatch(body);
      final templateMatch = nestedTemplateMatch ?? selfClosingTemplateMatch;
      if (templateMatch == null) continue;
      final templateAttrs = _dashAttributes(templateMatch.group(1) ?? '');
      final mediaTemplate = templateAttrs['media'] ?? '';
      final initializationTemplate = templateAttrs['initialization'] ?? '';
      if (mediaTemplate.isEmpty || initializationTemplate.isEmpty) continue;

      var segmentCount = 0;
      var timelineUnits = 0;
      final timescale = int.tryParse(templateAttrs['timescale'] ?? '') ?? 1;
      final timeline =
          nestedTemplateMatch == null ? '' : nestedTemplateMatch.group(2) ?? '';
      for (final segment in RegExp(
        r'<S\b([^>]*)/?>',
        caseSensitive: false,
      ).allMatches(timeline)) {
        final attrs = _dashAttributes(segment.group(1) ?? '');
        var repeat = int.tryParse(attrs['r'] ?? '') ?? 0;
        final durationUnits = int.tryParse(attrs['d'] ?? '') ?? 0;
        if (repeat < 0) {
          if (presentationSeconds == null ||
              presentationSeconds <= 0 ||
              durationUnits <= 0 ||
              timescale <= 0) {
            throw Exception('[下载失败] 无法确定动态 DASH 时间线长度');
          }
          final remainingUnits =
              (presentationSeconds * timescale).ceil() - timelineUnits;
          repeat = max(0, (remainingUnits / durationUnits).ceil() - 1);
        }
        segmentCount += repeat + 1;
        if (durationUnits > 0) timelineUnits += durationUnits * (repeat + 1);
      }
      if (segmentCount == 0) {
        final duration = int.tryParse(templateAttrs['duration'] ?? '');
        if (duration != null && duration > 0 && presentationSeconds != null) {
          segmentCount = (presentationSeconds * timescale / duration).ceil();
        }
      }
      if (segmentCount <= 0) continue;
      final startNumber = int.tryParse(templateAttrs['startNumber'] ?? '') ?? 1;
      final baseMatch = RegExp(
        r'<BaseURL[^>]*>([^<]+)</BaseURL>',
        caseSensitive: false,
      ).firstMatch(body);
      final baseUri =
          baseMatch == null
              ? manifestUri
              : manifestUri.resolve(baseMatch.group(1)!.trim());

      final representationPattern = RegExp(
        r'<Representation\b([^>]*)>',
        caseSensitive: false,
      );
      for (final representation in representationPattern.allMatches(body)) {
        final attrs = _dashAttributes(representation.group(1) ?? '');
        final id = attrs['id'] ?? '';
        if (id.isEmpty) continue;
        final mimeType = attrs['mimeType'] ?? adaptationAttrs['mimeType'] ?? '';
        if (!mimeType.startsWith('video/') && !mimeType.startsWith('audio/')) {
          continue;
        }
        final initialization = _expandDashTemplate(initializationTemplate, id);
        final segments = List<String>.generate(segmentCount, (index) {
          final relative = _expandDashTemplate(
            mediaTemplate,
            id,
            number: startNumber + index,
          );
          return baseUri.resolve(relative).toString();
        });
        plans.add(
          _DashTrackPlan(
            mimeType: mimeType,
            codecs: attrs['codecs'] ?? adaptationAttrs['codecs'] ?? '',
            bandwidth: int.tryParse(attrs['bandwidth'] ?? '') ?? 0,
            initializationUrl: baseUri.resolve(initialization).toString(),
            segmentUrls: segments,
          ),
        );
      }
    }
    return plans;
  }

  Future<void> _cleanupStaleDashResumeDirs(Directory root) async {
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        var newest = (await entity.stat()).modified;
        await for (final child in entity.list(followLinks: false)) {
          final modified = (await child.stat()).modified;
          if (modified.isAfter(newest)) newest = modified;
        }
        if (newest.isBefore(cutoff)) await entity.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _downloadDashTrack({
    required _DashTrackPlan plan,
    required File output,
    required Dio downloadDio,
    required Map<String, String> requestHeaders,
    required void Function(int bytes) onPartComplete,
    int parallelFetches = 4,
    CancelToken? cancelToken,
  }) async {
    final urls = <String>[plan.initializationUrl, ...plan.segmentUrls];
    final parallel = parallelFetches.clamp(1, _kDashParallelSegmentFetches);
    final resumeRoot = Directory(p.join(output.parent.path, '.dash_resume'));
    await resumeRoot.create(recursive: true);
    await _cleanupStaleDashResumeDirs(resumeRoot);
    final resumeSource =
        '${_normalizeVideoSourceUrl(plan.initializationUrl)}|${urls.length}|${plan.codecs}|${plan.bandwidth}';
    final resumeKey = sha1.convert(utf8.encode(resumeSource)).toString();
    final resumeDir = Directory(p.join(resumeRoot.path, resumeKey));
    await resumeDir.create(recursive: true);
    final partFiles = List<File>.generate(
      urls.length,
      (index) => File(p.join(resumeDir.path, '$index.part')),
    );
    var nextIndex = 0;
    Object? firstError;

    Future<void> worker() async {
      while (firstError == null) {
        final index = nextIndex++;
        if (index >= urls.length) return;
        try {
          final existingPart = partFiles[index];
          if (await existingPart.exists()) {
            final existingLength = await existingPart.length();
            if (existingLength > 0) {
              onPartComplete(existingLength);
              continue;
            }
          }
          List<int>? bytes;
          var currentHeaders = Map<String, String>.from(requestHeaders);
          for (var attempt = 0; attempt < 3; attempt++) {
            try {
              final response = await downloadDio.get<List<int>>(
                urls[index],
                cancelToken: cancelToken,
                options: Options(
                  responseType: ResponseType.bytes,
                  followRedirects: true,
                  maxRedirects: 5,
                  headers: currentHeaders,
                  validateStatus:
                      (status) =>
                          status != null && status >= 200 && status < 300,
                ),
              );
              bytes = response.data;
              if (bytes == null || bytes.isEmpty) {
                throw Exception('[下载失败] DASH 分片为空');
              }
              break;
            } on DioException catch (error) {
              if (attempt == 2) rethrow;
              final statusCode = error.response?.statusCode ?? 0;
              if (statusCode == 401 || statusCode == 403) {
                currentHeaders = await _browserLikeMediaHeaders(
                  urls[index],
                  referer:
                      currentHeaders['Referer'] ??
                      currentHeaders['referer'] ??
                      _currentUrl,
                  accept: '*/*',
                );
              }
              await Future<void>.delayed(
                Duration(milliseconds: 250 * (attempt + 1)),
              );
            } catch (_) {
              if (attempt == 2) rethrow;
              await Future<void>.delayed(
                Duration(milliseconds: 250 * (attempt + 1)),
              );
            }
          }
          final temporaryPart = File('${partFiles[index].path}.tmp');
          await temporaryPart.writeAsBytes(bytes!, flush: false);
          if (await partFiles[index].exists()) await partFiles[index].delete();
          await temporaryPart.rename(partFiles[index].path);
          onPartComplete(bytes.length);
        } catch (error) {
          firstError ??= error;
          return;
        }
      }
    }

    final sink = output.openWrite();
    var completed = false;
    try {
      await Future.wait<void>(
        List<Future<void>>.generate(
          min(parallel, urls.length),
          (_) => worker(),
        ),
      );
      if (firstError != null) throw firstError!;
      for (final part in partFiles) {
        if (!await part.exists() || await part.length() == 0) {
          throw Exception('[下载失败] DASH 临时分片缺失');
        }
        await sink.addStream(part.openRead());
      }
      completed = true;
    } finally {
      await sink.close();
      if (completed) {
        try {
          if (await resumeDir.exists()) await resumeDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<File> _downloadDashManifest({
    required String manifestUrl,
    required Dio downloadDio,
    required Directory mediaDir,
    required String outputId,
    required Map<String, String> requestHeaders,
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
  }) async {
    final manifestResponse = await downloadDio.get<String>(
      manifestUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: requestHeaders,
        validateStatus:
            (status) => status != null && status >= 200 && status < 300,
      ),
    );
    final xml = manifestResponse.data ?? '';
    if (!xml.contains('<MPD')) {
      throw Exception('[下载失败] 服务器返回的不是有效 DASH 清单');
    }
    final plans = _parseDashTrackPlans(xml, manifestUrl);
    final videoPlans =
        plans.where((plan) => plan.mimeType.startsWith('video/')).toList();
    if (videoPlans.isEmpty) throw Exception('[下载失败] DASH 清单中没有视频轨');
    videoPlans.sort((a, b) {
      int score(_DashTrackPlan plan) {
        final codec = plan.codecs.toLowerCase();
        final compatible = codec.contains('avc1') ? 2000000000 : 0;
        final mp4 = plan.mimeType == 'video/mp4' ? 1000000000 : 0;
        return compatible + mp4 + plan.bandwidth;
      }

      return score(b).compareTo(score(a));
    });
    final video = videoPlans.first;
    final audioPlans =
        plans.where((plan) => plan.mimeType.startsWith('audio/')).toList()
          ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
    final audio = audioPlans.isEmpty ? null : audioPlans.first;
    final useAcceleratedDash =
        _isTikPornPage(_currentUrl) ||
        _isTikPornPage(requestHeaders['Referer']);
    final dashHost = Uri.tryParse(manifestUrl)?.host.toLowerCase() ?? '';
    // Generic DASH also benefits from parallel tracks. Start conservatively
    // below the TikPORN fast path and retain the per-host failure backoff.
    final baseConcurrency = useAcceleratedDash ? 10 : 6;
    final maxConcurrency = useAcceleratedDash ? 10 : 8;
    final adaptiveConcurrency = (_dashConcurrencyByHost[dashHost] ??
            baseConcurrency)
        .clamp(2, maxConcurrency);

    final videoFile = File(p.join(mediaDir.path, '$outputId.video.mp4'));
    final audioFile = File(p.join(mediaDir.path, '$outputId.audio.m4a'));
    final finalFile = File(p.join(mediaDir.path, '$outputId.mp4'));
    final totalParts =
        video.segmentUrls.length +
        1 +
        (audio == null ? 0 : audio.segmentUrls.length + 1);
    var completedParts = 0;
    var downloadedBytes = 0;
    void onPart(int bytes) {
      completedParts++;
      downloadedBytes += bytes;
      onProgress?.call(
        completedParts / totalParts,
        detail:
            'DASH 分片 $completedParts/$totalParts · 已下载 ${_formatBytes(downloadedBytes)}',
      );
    }

    try {
      Future<void> downloadTrack(_DashTrackPlan plan, File output) {
        return _downloadDashTrack(
          plan: plan,
          output: output,
          downloadDio: downloadDio,
          requestHeaders: requestHeaders,
          cancelToken: cancelToken,
          onPartComplete: onPart,
          parallelFetches: adaptiveConcurrency,
        );
      }

      try {
        if (audio != null) {
          await Future.wait<void>([
            downloadTrack(video, videoFile),
            downloadTrack(audio, audioFile),
          ]);
        } else {
          await downloadTrack(video, videoFile);
        }
        if (dashHost.isNotEmpty && adaptiveConcurrency < maxConcurrency) {
          _dashConcurrencyByHost[dashHost] = adaptiveConcurrency + 1;
        }
      } catch (_) {
        if (dashHost.isNotEmpty) {
          _dashConcurrencyByHost[dashHost] = max(2, adaptiveConcurrency ~/ 2);
        }
        rethrow;
      }

      var muxed = false;
      if (audio != null && await audioFile.exists()) {
        try {
          muxed =
              await const MethodChannel(
                'media_muxer',
              ).invokeMethod<bool>('muxMp4', <String, String>{
                'videoPath': videoFile.path,
                'audioPath': audioFile.path,
                'outputPath': finalFile.path,
              }) ==
              true;
        } catch (e) {
          debugPrint('DASH 音视频封装失败，将保留视频轨: $e');
        }
      }
      if (!muxed) {
        if (await finalFile.exists()) await finalFile.delete();
        await videoFile.rename(finalFile.path);
      }
      if (!await finalFile.exists() || await finalFile.length() == 0) {
        throw Exception('[下载失败] DASH 合并结果为空');
      }
      final durationMs = await _probeNativeVideoDurationMs(finalFile);
      if (durationMs != null && durationMs <= 0) {
        await finalFile.delete();
        throw Exception('[下载失败] DASH 合并结果缺少有效时长，未保存损坏视频');
      }
      return _normalizeDownloadedMediaFile(finalFile, MediaType.video);
    } finally {
      for (final temporary in <File>[videoFile, audioFile]) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }
  }

  /// 下载 HLS 分片并合并为 MPEG-TS（`.ts`）。支持 AES-128-CBC + PKCS7（[#EXT-X-KEY]）。
  /// SAMPLE-AES / FairPlay 等仍不支持。
  /// [onMergeProgress]：`completed` 已写入分片数，`totalSegments` 总分片数，`mergedBytes` 已合并字节数。
  String? _pickBestHlsVariantUrl(List<String> lines, Uri baseUri) {
    String? bestUrl;
    var bestScore = -1;
    for (var i = 0; i < lines.length - 1; i++) {
      final line = lines[i];
      if (!line.contains('EXT-X-STREAM-INF')) continue;
      var nextIndex = i + 1;
      while (nextIndex < lines.length && lines[nextIndex].startsWith('#')) {
        nextIndex++;
      }
      if (nextIndex >= lines.length) continue;
      final next = lines[nextIndex];
      var score = 0;
      final bandwidth = RegExp(
        r'BANDWIDTH=(\d+)',
        caseSensitive: false,
      ).firstMatch(line);
      if (bandwidth != null) {
        score += int.tryParse(bandwidth.group(1) ?? '') ?? 0;
      }
      final resolution = RegExp(
        r'RESOLUTION=(\d+)x(\d+)',
        caseSensitive: false,
      ).firstMatch(line);
      if (resolution != null) {
        final w = int.tryParse(resolution.group(1) ?? '') ?? 0;
        final h = int.tryParse(resolution.group(2) ?? '') ?? 0;
        score += w * h;
      }
      final lower = next.toLowerCase();
      if (_looksLikePreviewClipUrl(lower)) score -= 1000000000;
      if (lower.contains('audio')) score -= 500000000;
      final candidate =
          next.startsWith('http://') || next.startsWith('https://')
              ? next
              : baseUri.resolve(next).toString();
      if (bestUrl == null || score > bestScore) {
        bestScore = score;
        bestUrl = candidate;
      }
    }
    return bestUrl;
  }

  String? _pickHlsAudioUrlForVariant(
    List<String> lines,
    Uri baseUri,
    String videoUrl,
  ) {
    String? audioGroup;
    for (var i = 0; i < lines.length - 1; i++) {
      final line = lines[i];
      if (!line.contains('EXT-X-STREAM-INF')) continue;
      var nextIndex = i + 1;
      while (nextIndex < lines.length && lines[nextIndex].startsWith('#')) {
        nextIndex++;
      }
      if (nextIndex >= lines.length) continue;
      final resolved = baseUri.resolve(lines[nextIndex]).toString();
      if (resolved != videoUrl) continue;
      audioGroup = RegExp(
        r'AUDIO="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(line)?.group(1);
      break;
    }
    if (audioGroup == null || audioGroup.isEmpty) return null;
    for (final line in lines) {
      if (!line.contains('EXT-X-MEDIA') ||
          !line.toUpperCase().contains('TYPE=AUDIO')) {
        continue;
      }
      final group = RegExp(
        r'GROUP-ID="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(line)?.group(1);
      if (group != audioGroup) continue;
      final uri = RegExp(
        r'URI="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(line)?.group(1);
      if (uri != null && uri.isNotEmpty) return baseUri.resolve(uri).toString();
    }
    return null;
  }

  String? _hlsUrlWithInheritedQuery(Uri baseUri, String resolvedUrl) {
    if (baseUri.query.isEmpty) return null;
    final resolved = Uri.tryParse(resolvedUrl);
    if (resolved == null || resolved.query.isNotEmpty) return null;
    return resolved.replace(query: baseUri.query).toString();
  }

  Future<Map<String, String>> _headersForHlsUrl(
    String url,
    Map<String, String> baseHeaders,
    Map<String, String> cookieCache,
  ) async {
    final headers = Map<String, String>.from(baseHeaders)..remove('Cookie');
    final uri = Uri.tryParse(url);
    if (uri == null) return headers;
    final cookieKey = uri.origin;
    var cookie = cookieCache[cookieKey];
    if (cookie == null) {
      cookie = await _browserCookieHeaderForUrl(url);
      cookieCache[cookieKey] = cookie;
    }
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return headers;
  }

  void _rememberHlsResponseCookies(
    Response<dynamic> response,
    String requestUrl,
    Map<String, String> cookieCache,
  ) {
    final setCookieHeaders = response.headers['set-cookie'];
    if (setCookieHeaders == null || setCookieHeaders.isEmpty) return;
    final responseUri = response.realUri;
    final requestUri = Uri.tryParse(requestUrl);
    final origin =
        responseUri.host.isNotEmpty ? responseUri.origin : requestUri?.origin;
    if (origin == null || origin.isEmpty) return;
    final values = <String, String>{};
    final existing = cookieCache[origin] ?? '';
    for (final pair in existing.split(';')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      values[pair.substring(0, separator).trim()] =
          pair.substring(separator + 1).trim();
    }
    for (final header in setCookieHeaders) {
      final pair = header.split(';').first.trim();
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      values[pair.substring(0, separator).trim()] =
          pair.substring(separator + 1).trim();
    }
    cookieCache[origin] = values.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<File?> _handleM3u8Download(
    String m3u8Path,
    String pageUrl,
    Dio? dio, {
    Map<String, String>? requestHeaders,
    void Function(int completed, int totalSegments, int mergedBytes)?
    onMergeProgress,
  }) async {
    final Dio client;
    if (dio != null) {
      client = dio;
    } else {
      final ns = NetworkService();
      await ns.initialize();
      client = ns.dio;
    }
    final initialHeaders =
        requestHeaders ??
        await _browserLikeMediaHeaders(
          pageUrl,
          referer: _getMediaReferer(pageUrl),
        );
    final hlsCookieCache = <String, String>{};
    Future<String> fetchPlaylistText(String playlistUrl) async {
      final headers = await _headersForHlsUrl(
        playlistUrl,
        initialHeaders,
        hlsCookieCache,
      );
      final response = await client.get<String>(
        playlistUrl,
        options: Options(responseType: ResponseType.plain, headers: headers),
      );
      _rememberHlsResponseCookies(response, playlistUrl, hlsCookieCache);
      return response.data ?? '';
    }

    String content = '';
    try {
      content = await File(m3u8Path).readAsString();
    } catch (_) {}
    if (!content.contains('#EXTM3U')) {
      content = await fetchPlaylistText(pageUrl);
    }
    Uri baseUri = Uri.parse(pageUrl);
    var effectivePageUrl = pageUrl;
    final initialLines =
        content
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList();
    final isXMaster =
        baseUri.host.toLowerCase() == 'video.twimg.com' &&
        initialLines.any((line) => line.contains('EXT-X-STREAM-INF')) &&
        initialLines.any(
          (line) =>
              line.contains('EXT-X-MEDIA') &&
              line.toUpperCase().contains('TYPE=AUDIO'),
        );
    if (isXMaster) {
      final videoUrl = _pickBestHlsVariantUrl(initialLines, baseUri);
      final audioUrl =
          videoUrl == null
              ? null
              : _pickHlsAudioUrlForVariant(initialLines, baseUri, videoUrl);
      if (videoUrl != null && audioUrl != null) {
        final videoPlaylistPath = '$m3u8Path.x-video.m3u8';
        final audioPlaylistPath = '$m3u8Path.x-audio.m3u8';
        var videoProgress = 0.0;
        var audioProgress = 0.0;
        void reportProgress() {
          final combined = videoProgress * 0.85 + audioProgress * 0.15;
          onMergeProgress?.call((combined * 1000).round(), 1000, 0);
        }

        File? videoFile;
        File? audioFile;
        try {
          final results = await Future.wait<File?>([
            _handleM3u8Download(
              videoPlaylistPath,
              videoUrl,
              client,
              requestHeaders: initialHeaders,
              onMergeProgress: (completed, total, _) {
                videoProgress = total > 0 ? completed / total : 0;
                reportProgress();
              },
            ),
            _handleM3u8Download(
              audioPlaylistPath,
              audioUrl,
              client,
              requestHeaders: initialHeaders,
              onMergeProgress: (completed, total, _) {
                audioProgress = total > 0 ? completed / total : 0;
                reportProgress();
              },
            ),
          ]);
          videoFile = results[0];
          audioFile = results[1];
          if (videoFile != null && audioFile != null) {
            final finalFile = File(p.setExtension(m3u8Path, '.mp4'));
            if (await finalFile.exists()) await finalFile.delete();
            final muxed =
                await const MethodChannel(
                  'media_muxer',
                ).invokeMethod<bool>('muxMp4', <String, String>{
                  'videoPath': videoFile.path,
                  'audioPath': audioFile.path,
                  'outputPath': finalFile.path,
                }) ==
                true;
            if (muxed &&
                await finalFile.exists() &&
                await finalFile.length() > 0) {
              try {
                if (await videoFile.exists()) await videoFile.delete();
              } catch (_) {}
              reportProgress();
              return finalFile;
            }
          }
          if (videoFile != null && await videoFile.exists()) return videoFile;
        } catch (e) {
          debugPrint('X HLS 音视频合并失败，将保留已下载的视频轨: $e');
          if (videoFile != null &&
              await videoFile.exists() &&
              await videoFile.length() > 0) {
            return videoFile;
          }
        } finally {
          for (final temporary in <File?>[audioFile]) {
            try {
              if (temporary != null && await temporary.exists()) {
                await temporary.delete();
              }
            } catch (_) {}
          }
        }
      }
    }
    for (var depth = 0; depth < 4; depth++) {
      final lines =
          content
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
      final isMaster =
          lines.any((line) => line.contains('EXT-X-STREAM-INF')) &&
          !lines.any((line) => line.contains('EXTINF'));
      if (!isMaster) break;
      final mediaUrl = _pickBestHlsVariantUrl(lines, baseUri);
      if (mediaUrl == null) break;
      var loadedMediaUrl = mediaUrl;
      try {
        content = await fetchPlaylistText(mediaUrl);
      } catch (_) {
        final inherited = _hlsUrlWithInheritedQuery(baseUri, mediaUrl);
        if (inherited == null) rethrow;
        content = await fetchPlaylistText(inherited);
        loadedMediaUrl = inherited;
      }
      baseUri = Uri.parse(loadedMediaUrl);
      effectivePageUrl = loadedMediaUrl;
    }

    final outputPath = p.setExtension(m3u8Path, '.ts');
    final outFile = File(outputPath);
    if (await outFile.exists()) {
      try {
        await outFile.delete();
      } catch (_) {}
    }
    await outFile.create(recursive: true);
    final sink = outFile.openWrite();
    final referer = _getMediaReferer(effectivePageUrl);
    final headers = <String, String>{
      'Referer': referer,
      'User-Agent': _kBrowserMediaUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      if (referer.startsWith('http'))
        'Origin': Uri.tryParse(referer)?.origin ?? referer,
      ...?requestHeaders,
    };
    if (!headers.containsKey('Cookie')) {
      final cookie = await _browserCookieHeaderForUrl(effectivePageUrl);
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    }

    final segLines =
        content
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
    final tasks = await _parseHlsSegmentTasks(
      segLines,
      baseUri,
      client,
      headers,
      hlsCookieCache,
    );
    if (tasks == null) {
      await sink.close();
      try {
        await outFile.delete();
      } catch (_) {}
      return null;
    }

    var segmentsWritten = 0;
    if (tasks.isNotEmpty) {
      final ok = await _writeHlsSegmentTasksParallel(
        tasks,
        client,
        headers,
        hlsCookieCache,
        sink,
        onProgress: onMergeProgress,
      );
      if (!ok) {
        await sink.close();
        try {
          await outFile.delete();
        } catch (_) {}
        return null;
      }
      segmentsWritten = tasks.length;
    }

    if (segmentsWritten == 0 && !content.contains('METHOD=AES-128')) {
      final plain = _collectHlsPlaintextSegmentUrls(segLines, baseUri);
      final plainCount = await _downloadPlainHlsUrlsParallel(
        client,
        headers,
        hlsCookieCache,
        sink,
        plain,
        onProgress: onMergeProgress,
      );
      if (plainCount == null) {
        await sink.close();
        try {
          await outFile.delete();
        } catch (_) {}
        return null;
      }
      segmentsWritten = plainCount;
    }

    await sink.close();

    if (segmentsWritten == 0) {
      try {
        await outFile.delete();
      } catch (_) {}
      return null;
    }
    try {
      final length = await outFile.length();
      if (length == 0) {
        await outFile.delete();
        return null;
      }
      final head = await outFile
          .openRead(0, min(length, 4096))
          .fold<List<int>>([], (previous, chunk) => previous..addAll(chunk));
      final detectedExtension = _detectVideoExtension(head);
      if (detectedExtension == null) {
        await outFile.delete();
        return null;
      }
      if (detectedExtension != '.ts') {
        final corrected = File(p.setExtension(outFile.path, detectedExtension));
        if (await corrected.exists()) await corrected.delete();
        return outFile.rename(corrected.path);
      }
    } catch (e) {
      debugPrint('HLS 合并文件校验失败: $e');
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      return null;
    }

    final seekableMp4 = await _remuxNativeVideoToMp4(outFile);
    if (seekableMp4 != null) return seekableMp4;

    return outFile;
  }

  /// 解析媒体 playlist 得到分片列表；`null` 表示 SAMPLE-AES / 密钥错误等致命问题。
  Future<List<_HlsSegTask>?> _parseHlsSegmentTasks(
    List<String> segLines,
    Uri baseUri,
    Dio client,
    Map<String, String> headers,
    Map<String, String> cookieCache,
  ) async {
    final keyCache = <String, Uint8List>{};
    Uint8List? aesKey;
    Uint8List? explicitIvFromKey;
    var useAes128 = false;
    var sequenceForNextSegment = 0;
    final tasks = <_HlsSegTask>[];
    final initSegments = <String>{};
    int? pendingRangeStart;
    int? pendingRangeEnd;
    var nextImplicitRangeStart = 0;
    var awaitingSegmentUri = false;
    var skipNextSegment = false;
    final hasFullSegments = segLines.any((line) => line.startsWith('#EXTINF'));

    var lineIdx = 0;
    while (lineIdx < segLines.length) {
      final line = segLines[lineIdx];
      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final v = line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim();
        sequenceForNextSegment = int.tryParse(v) ?? 0;
        lineIdx++;
        continue;
      }
      if (line.startsWith('#EXT-X-KEY')) {
        if (line.contains('METHOD=NONE')) {
          useAes128 = false;
          aesKey = null;
          explicitIvFromKey = null;
          lineIdx++;
          continue;
        }
        if (line.contains('SAMPLE-AES')) {
          debugPrint('M3U8: SAMPLE-AES 暂不支持');
          return null;
        }
        if (line.contains('METHOD=AES-128')) {
          final uriStr = _parseHlsKeyUri(line);
          if (uriStr == null || uriStr.isEmpty) {
            debugPrint('M3U8: EXT-X-KEY 缺少 URI');
            return null;
          }
          final keyAbs =
              uriStr.startsWith('http')
                  ? uriStr
                  : baseUri.resolve(uriStr).toString();
          final keyFallback = _hlsUrlWithInheritedQuery(baseUri, keyAbs);
          aesKey = keyCache[keyAbs];
          aesKey ??= await _fetchHlsKeyBytes(
            client,
            keyAbs,
            headers,
            cookieCache,
            fallbackUrl: keyFallback,
          );
          if (aesKey == null || aesKey.length != 16) {
            debugPrint('M3U8: 密钥无效 (len=${aesKey?.length})');
            return null;
          }
          keyCache[keyAbs] = aesKey;
          explicitIvFromKey = _parseHlsIvFromKeyLine(line);
          useAes128 = true;
          lineIdx++;
          continue;
        }
        lineIdx++;
        continue;
      }
      if (!hasFullSegments && line.startsWith('#EXT-X-PART:')) {
        final uriStr = _parseHlsKeyUri(line);
        if (uriStr != null && uriStr.isNotEmpty && !line.contains('GAP=YES')) {
          final partUrl =
              uriStr.startsWith('http://') || uriStr.startsWith('https://')
                  ? uriStr
                  : baseUri.resolve(uriStr).toString();
          int? partStart;
          int? partEnd;
          final range = RegExp(
            r'BYTERANGE="(\d+)(?:@(\d+))?"',
            caseSensitive: false,
          ).firstMatch(line);
          if (range != null) {
            final length = int.tryParse(range.group(1) ?? '');
            final offset = int.tryParse(range.group(2) ?? '') ?? 0;
            if (length != null && length > 0) {
              partStart = offset;
              partEnd = offset + length - 1;
            }
          }
          tasks.add(
            _HlsSegTask(
              url: partUrl,
              fallbackUrl: _hlsUrlWithInheritedQuery(baseUri, partUrl),
              mediaSeq: sequenceForNextSegment,
              useAes128: useAes128,
              aesKey: useAes128 ? aesKey : null,
              explicitIv: useAes128 ? explicitIvFromKey : null,
              rangeStart: partStart,
              rangeEnd: partEnd,
            ),
          );
        }
        lineIdx++;
        continue;
      }
      if (line.startsWith('#EXT-X-MAP')) {
        final uriStr = _parseHlsKeyUri(line);
        if (uriStr == null || uriStr.isEmpty) {
          debugPrint('M3U8: EXT-X-MAP 缺少 URI');
          return null;
        }
        final initUrl =
            uriStr.startsWith('http://') || uriStr.startsWith('https://')
                ? uriStr
                : baseUri.resolve(uriStr).toString();
        int? mapStart;
        int? mapEnd;
        final mapRange = RegExp(
          r'BYTERANGE="(\d+)(?:@(\d+))?"',
          caseSensitive: false,
        ).firstMatch(line);
        if (mapRange != null) {
          final length = int.tryParse(mapRange.group(1) ?? '');
          final offset = int.tryParse(mapRange.group(2) ?? '') ?? 0;
          if (length != null && length > 0) {
            mapStart = offset;
            mapEnd = offset + length - 1;
          }
        }
        final initKey = '$initUrl:${mapStart ?? -1}-${mapEnd ?? -1}';
        if (initSegments.add(initKey)) {
          tasks.add(
            _HlsSegTask(
              url: initUrl,
              fallbackUrl: _hlsUrlWithInheritedQuery(baseUri, initUrl),
              mediaSeq: sequenceForNextSegment,
              useAes128: useAes128,
              aesKey: useAes128 ? aesKey : null,
              explicitIv: useAes128 ? explicitIvFromKey : null,
              rangeStart: mapStart,
              rangeEnd: mapEnd,
            ),
          );
        }
        lineIdx++;
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final spec = line.substring('#EXT-X-BYTERANGE:'.length).trim();
        final match = RegExp(r'^(\d+)(?:@(\d+))?').firstMatch(spec);
        final length = int.tryParse(match?.group(1) ?? '');
        final explicitStart = int.tryParse(match?.group(2) ?? '');
        if (length != null && length > 0) {
          pendingRangeStart = explicitStart ?? nextImplicitRangeStart;
          pendingRangeEnd = pendingRangeStart + length - 1;
        }
        lineIdx++;
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        awaitingSegmentUri = true;
        lineIdx++;
        continue;
      }
      if (line.startsWith('#EXT-X-GAP')) {
        skipNextSegment = true;
        lineIdx++;
        continue;
      }
      if (awaitingSegmentUri && !line.startsWith('#')) {
        if (skipNextSegment) {
          skipNextSegment = false;
          awaitingSegmentUri = false;
          pendingRangeStart = null;
          pendingRangeEnd = null;
          lineIdx++;
          continue;
        }
        final segmentUrl =
            line.startsWith('http://') || line.startsWith('https://')
                ? line
                : baseUri.resolve(line).toString();
        final seq = sequenceForNextSegment;
        sequenceForNextSegment++;
        tasks.add(
          _HlsSegTask(
            url: segmentUrl,
            fallbackUrl: _hlsUrlWithInheritedQuery(baseUri, segmentUrl),
            mediaSeq: seq,
            useAes128: useAes128,
            aesKey: useAes128 ? aesKey : null,
            explicitIv: useAes128 ? explicitIvFromKey : null,
            rangeStart: pendingRangeStart,
            rangeEnd: pendingRangeEnd,
          ),
        );
        if (pendingRangeEnd != null) {
          nextImplicitRangeStart = pendingRangeEnd + 1;
        } else {
          nextImplicitRangeStart = 0;
        }
        pendingRangeStart = null;
        pendingRangeEnd = null;
        awaitingSegmentUri = false;
        lineIdx++;
        continue;
      }
      lineIdx++;
    }
    return tasks;
  }

  Future<Uint8List?> _downloadHlsSegmentRaw(
    Dio client,
    _HlsSegTask task,
    Map<String, String> headers,
    Map<String, String> cookieCache,
  ) async {
    final urls = <String>[task.url];
    if (task.fallbackUrl != null && task.fallbackUrl != task.url) {
      urls.add(task.fallbackUrl!);
    }
    Object? lastError;
    for (final candidate in urls) {
      for (var retry = 0; retry < 3; retry++) {
        try {
          final requestHeaders = await _headersForHlsUrl(
            candidate,
            headers,
            cookieCache,
          );
          if (task.rangeStart != null && task.rangeEnd != null) {
            requestHeaders['Range'] =
                'bytes=${task.rangeStart}-${task.rangeEnd}';
          }
          final r = await client.get<List<int>>(
            candidate,
            options: Options(
              responseType: ResponseType.bytes,
              headers: requestHeaders,
              validateStatus:
                  (code) => code != null && code >= 200 && code < 300,
            ),
          );
          _rememberHlsResponseCookies(r, candidate, cookieCache);
          final d = r.data;
          if (d == null || d.isEmpty) throw StateError('空分片');
          var bytes = d is Uint8List ? d : Uint8List.fromList(d);
          if (task.rangeStart != null && task.rangeEnd != null) {
            final expectedLength = task.rangeEnd! - task.rangeStart! + 1;
            if (r.statusCode == 200 && bytes.length > task.rangeEnd!) {
              bytes = Uint8List.fromList(
                bytes.sublist(task.rangeStart!, task.rangeEnd! + 1),
              );
            }
            if (bytes.length != expectedLength) {
              throw StateError(
                'Range 分片长度不符: 期望 $expectedLength 实际 ${bytes.length}',
              );
            }
          }
          return bytes;
        } catch (e) {
          lastError = e;
          if (retry < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 250 * (retry + 1)),
            );
          }
        }
      }
    }
    debugPrint('HLS 分片下载失败: ${task.url} -> $lastError');
    return null;
  }

  Future<bool> _writeHlsSegmentTasksParallel(
    List<_HlsSegTask> tasks,
    Dio client,
    Map<String, String> headers,
    Map<String, String> cookieCache,
    IOSink sink, {
    void Function(int completed, int totalSegments, int mergedBytes)?
    onProgress,
  }) async {
    final total = tasks.length;
    var mergedBytes = 0;
    var completed = 0;
    onProgress?.call(0, total, 0);
    for (var i = 0; i < tasks.length; i += _kHlsParallelSegmentFetches) {
      final end = min(i + _kHlsParallelSegmentFetches, tasks.length);
      final batch = tasks.sublist(i, end);
      final raws = await Future.wait(
        batch.map(
          (task) => _downloadHlsSegmentRaw(client, task, headers, cookieCache),
        ),
      );
      for (var j = 0; j < batch.length; j++) {
        final raw = raws[j];
        if (raw == null || raw.isEmpty) return false;
        final t = batch[j];
        List<int> toWrite = raw;
        if (t.useAes128 && t.aesKey != null) {
          final iv = t.explicitIv ?? _hlsIvFromMediaSequence(t.mediaSeq);
          try {
            toWrite = _decryptHlsAes128Cbc(t.aesKey!, iv, raw);
          } catch (e, st) {
            debugPrint('M3U8 AES 解密失败 seq=${t.mediaSeq}: $e\n$st');
            return false;
          }
        }
        sink.add(toWrite);
        completed++;
        mergedBytes += toWrite.length;
        onProgress?.call(completed, total, mergedBytes);
      }
    }
    return true;
  }

  /// 成功返回写入的分片数；任一分片失败返回 `null`（不写入残缺合并文件）。
  Future<int?> _downloadPlainHlsUrlsParallel(
    Dio client,
    Map<String, String> headers,
    Map<String, String> cookieCache,
    IOSink sink,
    List<String> urls, {
    void Function(int completed, int totalSegments, int mergedBytes)?
    onProgress,
  }) async {
    final total = urls.length;
    var mergedBytes = 0;
    var n = 0;
    onProgress?.call(0, total, 0);
    for (var i = 0; i < urls.length; i += _kHlsParallelSegmentFetches) {
      final end = min(i + _kHlsParallelSegmentFetches, urls.length);
      final batch = urls.sublist(i, end);
      final raws = await Future.wait(
        batch.map(
          (url) => _downloadHlsSegmentRaw(
            client,
            _HlsSegTask(url: url, mediaSeq: 0, useAes128: false),
            headers,
            cookieCache,
          ),
        ),
      );
      for (final raw in raws) {
        if (raw == null || raw.isEmpty) return null;
        sink.add(raw);
        n++;
        mergedBytes += raw.length;
        onProgress?.call(n, total, mergedBytes);
      }
    }
    return n;
  }

  /// 无 #EXTINF 时的兜底：收集非 # 行中的分片 URL（仅用于未加密的媒体 playlist）。
  List<String> _collectHlsPlaintextSegmentUrls(
    List<String> lines,
    Uri baseUri,
  ) {
    final out = <String>[];
    for (final line in lines) {
      if (line.startsWith('#')) continue;
      if (line.startsWith('http://') || line.startsWith('https://')) {
        out.add(line);
      } else if (line.isNotEmpty) {
        try {
          out.add(baseUri.resolve(line).toString());
        } catch (_) {}
      }
    }
    return out;
  }

  String? _parseHlsKeyUri(String line) {
    final m = RegExp(r'URI="([^"]+)"').firstMatch(line);
    if (m != null) return m.group(1);
    final m2 = RegExp(r"URI='([^']+)'").firstMatch(line);
    if (m2 != null) return m2.group(1);
    final m3 = RegExp(r'URI=([^,\s]+)').firstMatch(line);
    return m3?.group(1);
  }

  Uint8List? _parseHlsIvFromKeyLine(String line) {
    final m = RegExp(r'IV=0x([0-9a-fA-F]+)').firstMatch(line);
    if (m == null) return null;
    final hex = m.group(1)!;
    if (hex.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// RFC 8216：无 IV 属性时，使用该 Media Segment 的序号（128 位大端）作为 IV。
  Uint8List _hlsIvFromMediaSequence(int sequence) {
    final out = Uint8List(16);
    var s = sequence;
    for (var i = 0; i < 16; i++) {
      out[15 - i] = s & 0xff;
      s >>= 8;
    }
    return out;
  }

  Future<Uint8List?> _fetchHlsKeyBytes(
    Dio client,
    String url,
    Map<String, String> headers,
    Map<String, String> cookieCache, {
    String? fallbackUrl,
  }) async {
    final candidates = <String>[url];
    if (fallbackUrl != null && fallbackUrl != url) candidates.add(fallbackUrl);
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final requestHeaders = await _headersForHlsUrl(
          candidate,
          headers,
          cookieCache,
        );
        final r = await client.get<List<int>>(
          candidate,
          options: Options(
            responseType: ResponseType.bytes,
            headers: requestHeaders,
          ),
        );
        _rememberHlsResponseCookies(r, candidate, cookieCache);
        final data = r.data;
        if (data != null && data.isNotEmpty) return Uint8List.fromList(data);
      } catch (e) {
        lastError = e;
      }
    }
    debugPrint('M3U8 拉取密钥失败: $lastError');
    return null;
  }

  Uint8List _decryptHlsAes128Cbc(
    Uint8List key,
    Uint8List iv,
    Uint8List ciphertext,
  ) {
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(key), mode: enc.AESMode.cbc),
    );
    final decrypted = encrypter.decryptBytes(
      enc.Encrypted(ciphertext),
      iv: enc.IV(iv),
    );
    return Uint8List.fromList(decrypted);
  }

  String _getFileExtension(String input) {
    var value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri != null && uri.path.isNotEmpty) {
      value = uri.path;
    }
    final segments =
        value.split('/').where((segment) => segment.trim().isNotEmpty).toList();
    if (segments.isNotEmpty) {
      value = segments.last;
    }
    value = value.split('?').first.split('#').first;
    final extension = p.extension(value).toLowerCase();
    if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)) return '';
    return extension;
  }

  Future<Map<String, dynamic>> _saveToMediaLibrary(
    File file,
    MediaType mediaType,
  ) async {
    try {
      if (!await file.exists()) {
        throw const FileSystemException('下载完成后的媒体文件不存在');
      }
      final fileLength = await file.length();
      if (fileLength <= 0) {
        throw const FileSystemException('下载完成后的媒体文件为空');
      }
      final fileName = p.basename(file.path);
      if (mediaType == MediaType.video &&
          p.extension(fileName).toLowerCase() == '.webm' &&
          fileLength < _kMinBase64VideoBytes) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception('视频数据不完整，未保存到媒体库');
      }
      final fileHash = await _calculateFileHash(file);
      if (fileHash.isEmpty) {
        throw const FileSystemException('无法计算媒体内容哈希，已停止入库以避免产生重复文件');
      }
      final uuid = const Uuid().v4();
      final mediaItem = MediaItem(
        id: uuid,
        name: fileName,
        path: file.path,
        type: mediaType,
        directory: 'root',
        dateAdded: DateTime.now(),
      );
      final mediaItemMap = mediaItem.toMap();
      mediaItemMap['file_hash'] = fileHash;

      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final duplicate = await _databaseService
              .insertMediaItemIfContentUnique(mediaItemMap);
          if (duplicate != null) {
            throw _ExistingMediaDuplicateException(duplicate);
          }
          return mediaItemMap;
        } on _ExistingMediaDuplicateException {
          rethrow;
        } catch (e) {
          final message = e.toString().toLowerCase();
          final temporarilyBusy =
              message.contains('database is locked') ||
              message.contains('database is busy') ||
              message.contains('sqlite_busy') ||
              message.contains('sqlite_locked');
          if (!temporarilyBusy || attempt == 2) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: 200 * (attempt + 1)),
          );
        }
      }
      throw StateError('媒体入库重试结束但未返回结果');
    } catch (e, stackTrace) {
      debugPrint('保存到媒体库时出错: $e\n$stackTrace');
      rethrow;
    }
  }

  Future<bool> _tryScreenshotFallback(InAppWebViewController ctrl) async {
    File? screenshotFile;
    try {
      await Future.delayed(const Duration(milliseconds: 80));
      final screenshot = await ctrl.takeScreenshot();
      if (screenshot == null || screenshot.isEmpty || !mounted) return false;
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      final file = File('${mediaDir.path}/$uuid.png');
      screenshotFile = file;
      await file.writeAsBytes(screenshot);
      await _saveToMediaLibrary(file, MediaType.image);
      _notifyMediaDownloadSaved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已截屏保存'),
            duration: _kMediaSaveSnackDuration,
            action: SnackBarAction(
              label: '查看',
              onPressed:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (context) =>
                              const MediaManagerPage(showRouteBackButton: true),
                    ),
                  ),
            ),
          ),
        );
      }
      return true;
    } on _ExistingMediaDuplicateException catch (e) {
      try {
        if (screenshotFile != null && await screenshotFile.exists()) {
          await screenshotFile.delete();
        }
      } catch (_) {}
      await _showMediaDuplicateDialog(e.existingRow);
      return true;
    } catch (e) {
      debugPrint('截屏兜底失败: $e');
      return false;
    }
  }

  Future<String> _calculateFileHash(File file) async {
    try {
      final path = file.path;
      final len = await file.length();
      if (len >= _kMd5IsolateThresholdBytes) {
        return await Isolate.run(() async {
          final digest = await md5.bind(File(path).openRead()).first;
          return digest.toString();
        });
      }
      final digest = await md5.bind(file.openRead()).first;
      return digest.toString();
    } catch (e) {
      debugPrint('计算文件哈希值时出错: $e');
      return '';
    }
  }

  void _addBookmark(String url) {
    // 检查是否已存在相同URL的书签
    if (_bookmarks.any((bookmark) => bookmark['url'] == url)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('书签已存在')));
      return;
    }

    // 创建一个文本控制器，初始值设为当前网页的标题或URL
    final nameController = TextEditingController();

    // 如果在浏览网页，尝试获取网页标题
    if (!_showHomePage && _isBrowsingWebPage) {
      nameController.text = "获取中...";
      final c = _controller;
      if (c != null)
        c
            .getTitle()
            .then((title) {
              if (title != null &&
                  title.isNotEmpty &&
                  nameController.text == "获取中...") {
                nameController.text = title;
                // 自动选中文本，方便用户编辑
                nameController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: title.length,
                );
              }
            })
            .catchError((error) {
              debugPrint('获取网页标题出错: $error');
              if (nameController.text == "获取中...") {
                nameController.text = "";
              }
            });
    }

    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('添加书签'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '书签名称',
                    hintText: '输入自定义名称',
                    helperText: '为书签设置一个简短易记的名称',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                Text(
                  'URL: $url',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  if (nameController.text.isNotEmpty &&
                      nameController.text != "获取中...") {
                    // 创建一个变量存储加载对话框的context
                    BuildContext? loadingDialogContext;

                    // 显示加载对话框并保存context
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (context) {
                        loadingDialogContext = context;
                        return const AlertDialog(
                          content: Row(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(width: 20),
                              Text('添加中...'),
                            ],
                          ),
                        );
                      },
                    );

                    setState(
                      () => _bookmarks.insert(0, {
                        'name': nameController.text,
                        'url': url,
                      }),
                    );
                    await _saveBookmarks();

                    // 安全地关闭加载对话框
                    if (loadingDialogContext != null &&
                        Navigator.canPop(loadingDialogContext!)) {
                      Navigator.pop(loadingDialogContext!);
                    }

                    // 关闭主对话框
                    Navigator.of(context).pop();
                  } else if (nameController.text == "获取中...") {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('请等待网页标题获取完成，或输入自定义名称'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('请输入书签名称'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
                child: const Text('添加'),
              ),
            ],
          ),
    );
  }

  void _showBookmarks() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      enableDrag: true,
      showDragHandle: true,
      builder:
          (context) => StatefulBuilder(
            builder: (BuildContext context, StateSetter modalSetState) {
              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.55,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '书签',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                            tooltip: '关闭',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ReorderableListView.builder(
                        itemCount: _bookmarks.length,
                        onReorder: (oldIndex, newIndex) async {
                          if (oldIndex < newIndex) newIndex -= 1;
                          final item = _bookmarks.removeAt(oldIndex);
                          _bookmarks.insert(newIndex, item);
                          modalSetState(() {});
                          await _saveBookmarks();
                        },
                        buildDefaultDragHandles: true,
                        itemBuilder: (context, index) {
                          final bookmark = _bookmarks[index];
                          final url = bookmark['url']?.toString() ?? '';
                          final name = bookmark['name'] ?? url;
                          return ListTile(
                            key: ValueKey('bookmark_$url$index'),
                            title: Text(name),
                            onTap: () {
                              _loadUrl(url);
                              Navigator.pop(context);
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit,
                                    color: Colors.blue,
                                  ),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    _showRenameBookmarkDialog(context, index);
                                  },
                                  tooltip: '重命名',
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                  ),
                                  onPressed: () async {
                                    final shouldDelete =
                                        await showDialog<bool>(
                                          context: context,
                                          builder:
                                              (context) => AlertDialog(
                                                title: const Text('删除书签'),
                                                content: Text(
                                                  '确定要删除书签 "$name" 吗？',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed:
                                                        () => Navigator.pop(
                                                          context,
                                                          false,
                                                        ),
                                                    child: const Text('取消'),
                                                  ),
                                                  TextButton(
                                                    onPressed:
                                                        () => Navigator.pop(
                                                          context,
                                                          true,
                                                        ),
                                                    child: const Text('删除'),
                                                  ),
                                                ],
                                              ),
                                        ) ??
                                        false;
                                    if (shouldDelete) {
                                      modalSetState(() {
                                        _bookmarks.removeAt(index);
                                      });
                                      await _saveBookmarks();
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.content_copy,
                                    color: Colors.green,
                                  ),
                                  onPressed: () {
                                    if (url.isNotEmpty) {
                                      Clipboard.setData(
                                        ClipboardData(text: url),
                                      );
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('书签网址已复制到剪贴板'),
                                            duration: Duration(seconds: 1),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  tooltip: '复制网址',
                                ),
                              ],
                            ),
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
  }

  void _showRenameBookmarkDialog(BuildContext context, int index) {
    final bookmark = _bookmarks[index];
    final nameController = TextEditingController(text: bookmark['name']);
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('重命名书签'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '书签名称',
                    hintText: '输入新的书签名称',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                Text(
                  'URL: ${bookmark['url']}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  if (nameController.text.isNotEmpty &&
                      nameController.text != bookmark['name']) {
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder:
                          (context) => const AlertDialog(
                            content: Row(
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(width: 20),
                                Text('保存中...'),
                              ],
                            ),
                          ),
                    );
                    setState(
                      () => _bookmarks[index]['name'] = nameController.text,
                    );
                    await _saveBookmarks();
                    Navigator.of(context).pop();
                    Navigator.of(context).pop();
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
    );
  }

  Future<void> _saveBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(_bookmarks);
      await prefs.setString('bookmarks', jsonString);
    } catch (e) {
      debugPrint('Error saving bookmarks: $e');
    }
  }

  Future<void> _loadCommonWebsites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final commonWebsitesJson = prefs.getString('common_websites');
      if (commonWebsitesJson != null && commonWebsitesJson.isNotEmpty) {
        final decoded = jsonDecode(commonWebsitesJson);
        final List<dynamic> websitesList = decoded is List ? decoded : [];

        if (websitesList.isNotEmpty) {
          setState(() {
            _commonWebsites.clear();
            final mapped =
                websitesList
                    .map(
                      (item) => {
                        'name': item['name'],
                        'url': item['url'],
                        'iconCode': Icons.public.codePoint,
                      },
                    )
                    .toList();
            _commonWebsites.addAll(mapped);
          });
          debugPrint('从SharedPreferences加载了${_commonWebsites.length}个常用网站');
          return;
        }
      }

      // 如果没有从SharedPreferences加载到数据，或者加载的数据为空，则加载默认网站
      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {
            'name': 'Google',
            'url': 'https://www.google.com',
            'iconCode': Icons.public.codePoint,
          },
          {
            'name': '百度',
            'url': 'https://www.baidu.com',
            'iconCode': Icons.public.codePoint,
          },
        ]);
      });
      debugPrint('加载了默认常用网站');
      await _saveCommonWebsites();
    } catch (e) {
      debugPrint('Error loading common websites: $e');
      // 出错时加载默认网站
      setState(() {
        _commonWebsites.clear();
        _commonWebsites.addAll([
          {
            'name': 'Google',
            'url': 'https://www.google.com',
            'iconCode': Icons.public.codePoint,
          },
          {
            'name': '百度',
            'url': 'https://www.baidu.com',
            'iconCode': Icons.public.codePoint,
          },
        ]);
      });
      debugPrint('加载出错，使用默认常用网站');
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('common_websites');
    }
  }

  // 2. 加载历史记录
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final historyString = prefs.getString('browser_history');
    if (historyString != null) {
      _history = List<Map<String, dynamic>>.from(json.decode(historyString));
    }
  }

  // 3. 保存历史记录
  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('browser_history', json.encode(_history));
  }

  // 4. 添加历史记录（在网页加载成功时调用）
  Future<void> _addHistory(String title, String url) async {
    if (url.isEmpty) return;
    // 去重：如果已存在则先移除
    _history.removeWhere((item) => item['url'] == url);
    _history.insert(0, {
      'title': title,
      'url': url,
      'datetime': DateTime.now().toIso8601String(),
    });
    // 限制最大条数
    if (_history.length > 200) _history = _history.sublist(0, 200);
    await _saveHistory();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '[_BrowserPage.build] _showHomePage: $_showHomePage, _isBrowsingWebPage: $_isBrowsingWebPage, _shouldKeepWebPageState: $_shouldKeepWebPageState',
    );
    super.build(context);
    return WillPopScope(
      onWillPop: () async {
        if (_showHomePage || _controller == null) return true;
        await _performWebGoBack();
        return false;
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          titleSpacing: 0,
          title: _showHomePage ? const Text('浏览器') : const SizedBox.shrink(),
          leadingWidth: _showHomePage ? 56 : null,
          leading:
              _showHomePage
                  ? IconButton(
                    icon: const Icon(Icons.favorite_border),
                    onPressed: _showSharedFavoriteVideosSheet,
                    tooltip: '收藏视频',
                  )
                  : IconButton(
                    icon: const Icon(Icons.home),
                    onPressed: _goToHomePage,
                    tooltip: '回到主页',
                  ),
          centerTitle: true,
          actions: [
            // 添加媒体库按钮到actions列表的第一个位置
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.photo_library),
                onPressed: () {
                  Logger.log('[BrowserPage] 媒体库按钮被点击');
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (context) =>
                              const MediaManagerPage(showRouteBackButton: true),
                    ),
                  );
                },
                tooltip: '媒体库',
              ),
            if (_isBrowsingWebPage && _shouldKeepWebPageState && _showHomePage)
              IconButton(
                icon: const Icon(Icons.arrow_right_alt),
                onPressed: _restoreWebPage,
                tooltip: '返回上次浏览的网页',
              ),
            if (_showHomePage)
              IconButton(
                icon: const Icon(Icons.bookmark),
                onPressed: _showBookmarks,
                tooltip: '显示书签',
              )
            else
              Semantics(
                button: true,
                label: '书签；长按智能下载当前媒体',
                child: InkResponse(
                  onTap: _showBookmarks,
                  onLongPress: _showCurrentMediaSmartDownload,
                  radius: 24,
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.bookmark),
                  ),
                ),
              ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.content_copy),
                onPressed: () async {
                  // 优先从 WebView 控制器获取最实时的 URL，以应对单页面应用或复杂跳转
                  String? realTimeUrl;
                  if (_controller != null) {
                    final uri = await _controller!.getUrl();
                    realTimeUrl = uri?.toString();
                  }

                  final url =
                      (realTimeUrl != null && realTimeUrl.isNotEmpty)
                          ? realTimeUrl
                          : (_urlController.text.trim().isNotEmpty
                              ? _urlController.text.trim()
                              : _currentUrl);

                  if (url.isNotEmpty) {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('当前网址已复制到剪贴板'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  }
                },
                tooltip: '复制当前网址',
              ),
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.bookmark_add),
                onPressed: () => _addBookmark(_currentUrl),
                tooltip: '添加书签',
              ),
            if (_showHomePage) ...[
              IconButton(
                icon: const Icon(Icons.import_export),
                onPressed: _showExportImportMenu,
                tooltip: '导入/导出数据',
              ),
            ],
            if (!_showHomePage)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: _exitWebPage,
                tooltip: '退出网页',
              ),
            IconButton(
              icon: const Icon(Icons.history),
              onPressed: _showHistory,
              tooltip: '历史记录',
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final bodyW = constraints.maxWidth;
            final bodyH = constraints.maxHeight;
            return Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => unawaited(_performWebGoBack()),
                            tooltip: '后退',
                          ),
                          IconButton(
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: () => unawaited(_performWebGoForward()),
                            tooltip: '前进',
                          ),
                          IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: () => _controller?.reload(),
                            tooltip: '刷新',
                          ),
                          Expanded(
                            child: TextField(
                              controller: _urlController,
                              decoration: const InputDecoration(
                                hintText: '输入网址',
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.url,
                              onSubmitted: _loadUrl,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.search),
                            onPressed: () => _loadUrl(_urlController.text),
                            tooltip: '前往',
                          ),
                        ],
                      ),
                    ),
                    if (_isLoading)
                      LinearProgressIndicator(value: _loadingProgress),
                    Expanded(
                      child: Stack(
                        children: [
                          InAppWebView(
                            initialUrlRequest: URLRequest(
                              url: WebUri('about:blank'),
                            ),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              useHybridComposition: true,
                              useOnLoadResource: true,
                              allowFileAccess: true,
                              domStorageEnabled: true,
                              databaseEnabled: true,
                              cacheEnabled: true,
                              thirdPartyCookiesEnabled: true,
                              javaScriptCanOpenWindowsAutomatically: true,
                              supportMultipleWindows: true,
                              mixedContentMode:
                                  MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                            ),
                            initialUserScripts: UnmodifiableListView([
                              UserScript(
                                source: _kEarlyMediaSnifferScript,
                                injectionTime:
                                    UserScriptInjectionTime.AT_DOCUMENT_START,
                              ),
                            ]),
                            onWebViewCreated:
                                (ctrl) => _setupWebViewController(ctrl),
                            shouldAllowDeprecatedTLS: (ctrl, challenge) async {
                              return ShouldAllowDeprecatedTLSAction.ALLOW;
                            },
                            // 注意：PROCEED 会跳过证书校验，存在中间人攻击风险。
                            // 若需更高安全性，可改为 DENY 或实现白名单校验。
                            onReceivedServerTrustAuthRequest: (
                              ctrl,
                              challenge,
                            ) async {
                              return ServerTrustAuthResponse(
                                action: ServerTrustAuthResponseAction.PROCEED,
                              );
                            },
                            onLoadStart: (ctrl, url) {
                              setState(() {
                                _isLoading = true;
                                if (url != null) {
                                  final urlStr = url.toString();
                                  _currentUrl = urlStr;
                                  _urlController.text = _currentUrl;
                                  // 仅当加载真实网页时切换到 WebView，about:blank 不切换（保持主界面）
                                  if (urlStr.startsWith('http://') ||
                                      urlStr.startsWith('https://')) {
                                    _showHomePage = false;
                                    widget.onBrowserHomePageChanged?.call(
                                      false,
                                    );
                                  }
                                }
                              });
                            },
                            onProgressChanged: (ctrl, progress) {
                              setState(() {
                                _loadingProgress = progress / 100;
                                _isLoading = _loadingProgress < 1.0;
                              });
                            },
                            onLoadStop: (ctrl, url) {
                              if (url != null) _onPageFinished(url.toString());
                            },
                            onLoadResource: (ctrl, resource) {
                              _recordLoadedWebResource(resource);
                            },
                            onCreateWindow: (ctrl, action) async {
                              final popupUrl = action.request.url?.toString();
                              if (popupUrl == null || popupUrl.isEmpty) {
                                debugPrint('网页请求打开新窗口，但没有提供目标地址');
                                return false;
                              }
                              debugPrint('接管网页新窗口并在当前页打开: $popupUrl');
                              await ctrl.loadUrl(
                                urlRequest: URLRequest(url: WebUri(popupUrl)),
                              );
                              return false;
                            },
                            onReceivedError:
                                (ctrl, req, err) => debugPrint(
                                  'WebView错误: ${err?.description}',
                                ),
                            shouldOverrideUrlLoading: (ctrl, nav) async {
                              final url = nav.request.url?.toString() ?? '';
                              debugPrint('导航请求: $url');
                              if (_isDownloadableLink(url) ||
                                  _isYouTubeLink(url)) {
                                debugPrint('检测到可能的下载链接: $url');
                                _handleDownload(url, '', _guessMimeType(url));
                                return NavigationActionPolicy.CANCEL;
                              }
                              if (!url.startsWith('http://') &&
                                  !url.startsWith('https://')) {
                                if (url.startsWith('data:') ||
                                    url.startsWith('blob:')) {
                                  return NavigationActionPolicy.ALLOW;
                                }
                                final lower = url.toLowerCase();
                                if (_isNoisyExternalAppScheme(lower)) {
                                  return NavigationActionPolicy.CANCEL;
                                }
                                debugPrint('检测到自定义URL协议: $url');
                                _launchExternalApp(url);
                                return NavigationActionPolicy.CANCEL;
                              }
                              if (_smartDownloadTask != null &&
                                  !_isWithinSmartDownloadSite(url)) {
                                debugPrint('智能下载已阻止跳出当前网站: $url');
                                final task = _smartDownloadTask!;
                                final id =
                                    (task['discoveryTaskId'] ?? '').toString();
                                if (id.isNotEmpty) {
                                  _updateDownloadTask(
                                    id,
                                    progressDetail:
                                        '已阻止外部网站跳转，继续在当前网站内寻找 · 已保存 ${task['success']}/${task['target']}',
                                  );
                                }
                                return NavigationActionPolicy.CANCEL;
                              }
                              return NavigationActionPolicy.ALLOW;
                            },
                          ),
                          if (_smartDownloadTask != null &&
                              _smartOperationPoint != null)
                            _buildSmartOperationOverlay(),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_showHomePage)
                  Positioned.fill(
                    child: Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: _buildHomePage(),
                    ),
                  ),
                // 下载任务面板：可拖动，打开网站时常驻；主页面仅在有下载任务时显示（Positioned 必须是 Stack 的直接子项）
                ValueListenableBuilder<List<Map<String, dynamic>>>(
                  valueListenable: _downloadTasksNotifier,
                  builder: (context, tasks, child) {
                    final activeTasks =
                        tasks
                            .where((t) => t['status'] == 'downloading')
                            .toList();
                    final shouldShow = !_showHomePage || activeTasks.isNotEmpty;
                    if (!shouldShow) return const SizedBox.shrink();
                    final panelW = _downloadPanelExpanded ? 320.0 : 60.0;
                    final panelH =
                        _downloadPanelExpanded
                            ? (_smartDownloadTask == null ? 280.0 : 350.0)
                            : 60.0;
                    final defaultLeft = bodyW - 16 - panelW;
                    final defaultTop = bodyH * 0.75 - panelH / 2;
                    final left = (_downloadPanelPosition?.dx ?? defaultLeft)
                        .clamp(0.0, bodyW - panelW);
                    final top = (_downloadPanelPosition?.dy ?? defaultTop)
                        .clamp(0.0, bodyH - panelH);
                    return Positioned(
                      left: left,
                      top: top,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) {
                          setState(() {
                            final dx = (left + details.delta.dx).clamp(
                              0.0,
                              bodyW - panelW,
                            );
                            final dy = (top + details.delta.dy).clamp(
                              0.0,
                              bodyH - panelH,
                            );
                            _downloadPanelPosition = Offset(dx, dy);
                          });
                        },
                        child: _buildDownloadTasksPanel(tasks, activeTasks),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSmartDownloadSummary(Map<String, dynamic> task) {
    final keyword = (task['keyword'] ?? '').toString().trim();
    final mediaType = task['mediaType'] as MediaType?;
    final allowMixedMedia = task['allowMixedMedia'] == true;
    final target = (task['target'] as int?) ?? 0;
    final completed = ((task['success'] as int?) ?? 0).clamp(0, target);
    final remaining = max(0, target - completed);
    final minBytes = task['minVideoBytes'] as int?;
    final maxBytes = task['maxVideoBytes'] as int?;
    final autoSizeRange = task['autoVideoSizeRange'] == true;
    final nextLabel = (task['nextMediaLabel'] ?? '').toString().trim();
    final nextStatus = (task['nextMediaStatus'] ?? '').toString().trim();
    String sizeLabel;
    if (mediaType != MediaType.video) {
      sizeLabel = '不限制';
    } else if (minBytes != null && maxBytes != null) {
      sizeLabel =
          '${(minBytes / 1024 / 1024).round()}～${(maxBytes / 1024 / 1024).round()} MB';
    } else if (minBytes != null) {
      sizeLabel = '≥ ${(minBytes / 1024 / 1024).round()} MB';
    } else if (maxBytes != null) {
      sizeLabel = '≤ ${(maxBytes / 1024 / 1024).round()} MB';
    } else {
      sizeLabel = '不限制';
    }
    if (autoSizeRange && sizeLabel != '不限制') {
      sizeLabel = '自动 $sizeLabel';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '智能${allowMixedMedia
                ? '图片+视频'
                : mediaType == MediaType.image
                ? '图片'
                : '视频'} · 关键词：${keyword.isEmpty ? '无（按当前媒体距离）' : keyword}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '大小：$sizeLabel · 数量：$completed/$target · 待下载：$remaining',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          if (nextStatus.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              '下一项：${nextLabel.isEmpty ? '已找到候选媒体' : nextLabel} · $nextStatus',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSmartOperationOverlay() {
    final point = _smartOperationPoint ?? const Offset(0.5, 0.5);
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final left =
                (point.dx * constraints.maxWidth - 22)
                    .clamp(4.0, max(4.0, constraints.maxWidth - 48))
                    .toDouble();
            final top =
                (point.dy * constraints.maxHeight - 22)
                    .clamp(4.0, max(4.0, constraints.maxHeight - 94))
                    .toDouble();
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  left: left,
                  top: top,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.82),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.greenAccent,
                            width: 2.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.touch_app,
                          color: Colors.greenAccent,
                          size: 27,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 230),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: Text(
                              _smartOperationLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildDownloadTasksPanel(
    List<Map<String, dynamic>> tasks,
    List<Map<String, dynamic>> activeTasks,
  ) {
    final smartTask = _smartDownloadTask;
    return GestureDetector(
      onTap:
          () =>
              setState(() => _downloadPanelExpanded = !_downloadPanelExpanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          maxWidth: _downloadPanelExpanded ? 320 : 60,
          maxHeight:
              _downloadPanelExpanded ? (smartTask == null ? 280 : 350) : 60,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.75),
          borderRadius: BorderRadius.circular(_downloadPanelExpanded ? 12 : 30),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child:
            _downloadPanelExpanded
                ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.downloading,
                            color: Colors.green,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '下载任务 (${tasks.length})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (smartTask != null) ...[
                        const SizedBox(height: 8),
                        _buildSmartDownloadSummary(smartTask),
                      ],
                      const SizedBox(height: 8),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: tasks.length,
                          itemBuilder: (context, i) {
                            final t = tasks[i];
                            final status = t['status'] as String? ?? '';
                            final progress =
                                (t['progress'] as num?)?.toDouble() ?? 0.0;
                            final name = t['displayName'] as String? ?? '未知';
                            final progressDetail =
                                (t['progressDetail'] as String?)?.trim() ?? '';
                            final transferStatus =
                                (t['transferStatus'] as String?)?.trim() ?? '';
                            final isDownloading = status == 'downloading';
                            final isPaused = status == 'paused';
                            final isSmartBatchMedia =
                                t['isSmartBatchMedia'] == true;
                            final canRetry =
                                status == 'cancelled' || status == 'failed';
                            final canStopOrResume =
                                isDownloading || isPaused || canRetry;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (isDownloading) ...[
                                          LinearProgressIndicator(
                                            value: progress,
                                            backgroundColor: Colors.grey,
                                            valueColor:
                                                const AlwaysStoppedAnimation<
                                                  Color
                                                >(Colors.green),
                                          ),
                                          if (progressDetail.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                progressDetail,
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 10,
                                                  height: 1.2,
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          if (transferStatus.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 2,
                                              ),
                                              child: Text(
                                                transferStatus,
                                                style: const TextStyle(
                                                  color: Colors.greenAccent,
                                                  fontSize: 10,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                        ] else
                                          Text(
                                            status == 'completed'
                                                ? '已完成'
                                                : status == 'paused'
                                                ? '已暂停'
                                                : status == 'cancelled'
                                                ? '已取消'
                                                : '失败',
                                            style: TextStyle(
                                              color:
                                                  status == 'completed'
                                                      ? Colors.green
                                                      : Colors.grey,
                                              fontSize: 10,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (canStopOrResume)
                                    IconButton(
                                      icon: Icon(
                                        isDownloading
                                            ? Icons.stop
                                            : Icons.play_arrow,
                                        color:
                                            isDownloading
                                                ? Colors.red
                                                : Colors.green,
                                        size: 22,
                                      ),
                                      onPressed:
                                          () => _togglePauseResume(
                                            t['id'] as String,
                                          ),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                      tooltip:
                                          isDownloading
                                              ? (isSmartBatchMedia
                                                  ? '跳过当前媒体并下载下一个'
                                                  : '停止')
                                              : (isPaused ? '继续下载' : '重新下载'),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                )
                : Stack(
                  alignment: Alignment.center,
                  children: [
                    if (activeTasks.isNotEmpty)
                      SizedBox(
                        width: 50,
                        height: 50,
                        child: CircularProgressIndicator(
                          value: activeTasks.first['progress'] as double?,
                          backgroundColor: Colors.grey.withOpacity(0.5),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.green,
                          ),
                          strokeWidth: 4,
                        ),
                      )
                    else
                      Icon(
                        tasks.isEmpty ? Icons.download : Icons.download_done,
                        color: Colors.green,
                        size: 28,
                      ),
                  ],
                ),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _downloadTasksNotifier.dispose();
    _favoriteProgressSyncTimer?.cancel();
    // Fire-and-forget saves to avoid awaiting in dispose
    Future.microtask(() async {
      try {
        await _saveBookmarks();
        debugPrint('书签保存完成');
      } catch (e) {
        debugPrint('保存书签时出错: $e');
      }
      try {
        await _saveCommonWebsites();
        debugPrint('常用网站保存完成');
      } catch (e) {
        debugPrint('保存常用网站时出错: $e');
      }
    });
    widget.onBrowserHomePageChanged?.call(true);
    _mediaDownloadFailHintTimer?.cancel();
    super.dispose();
  }

  Future<bool> _performBackgroundDownload(
    String url,
    MediaType mediaType, {
    bool skipFailurePrompt = false,
    void Function(String failureType)? onFailureType,
    Duration? inactivityTimeout,
    DownloadProgressCallback? onProgress,
    int? maxRequestAttempts,
    bool showSuccessPrompt = true,
    bool showDuplicatePrompt = true,
    bool validateSmartMedia = false,
    bool isSmartBatchMedia = false,
    Map<String, dynamic>? smartTask,
    String smartMediaTitle = '',
    String smartPageUrl = '',
    int? minFileBytes,
    int? maxFileBytes,
  }) async {
    // 仅下载图片和视频，不下载语音/音频
    if (mediaType == MediaType.audio) {
      onFailureType?.call('unsupported_audio');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前仅支持下载图片和视频，不支持音频文件')));
      }
      return false;
    }
    final absoluteUrl = _toAbsoluteUrl(url);
    if (_downloadingUrls.contains(absoluteUrl)) {
      onFailureType?.call('already_downloading');
      onProgress?.call(0.0, detail: '同一链接已在下载中');
      return true;
    }
    if (_isApiEndpointUrl(absoluteUrl) &&
        !_isTrustedMediaCandidate(absoluteUrl)) {
      onFailureType?.call('api_endpoint_filtered');
      debugPrint('跳过 API 接口 URL（非媒体文件）: ');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该链接不是媒体文件，请长按图片或视频本身进行下载'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return false;
    }
    _downloadingUrls.add(absoluteUrl);
    final taskId = const Uuid().v4();
    final cancelToken = CancelToken();
    var timedOut = false;
    var sizeRangeExceeded = false;
    Timer? timeoutTimer;
    void resetInactivityTimeout() {
      if (inactivityTimeout == null || cancelToken.isCancelled) return;
      timeoutTimer?.cancel();
      timeoutTimer = Timer(inactivityTimeout, () {
        timedOut = true;
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('inactivity_timeout');
        }
      });
    }

    resetInactivityTimeout();
    if (mounted) {
      _addDownloadTask(
        taskId,
        absoluteUrl,
        mediaType,
        cancelToken,
        isSmartBatchMedia: isSmartBatchMedia,
      );
    }

    File? downloadedFile;
    try {
      debugPrint('开始后台下载: , 媒体类型: ');

      downloadedFile = await _downloadFile(
        absoluteUrl,
        mediaType,
        cancelToken: cancelToken,
        maxRequestAttempts: maxRequestAttempts,
        onTotalBytesKnown: (totalBytes) {
          if (sizeRangeExceeded || cancelToken.isCancelled) return;
          final outsideRange =
              (minFileBytes != null && totalBytes < minFileBytes) ||
              (maxFileBytes != null && totalBytes > maxFileBytes);
          if (!outsideRange) return;
          sizeRangeExceeded = true;
          onProgress?.call(
            0,
            detail: '总大小 ${_formatBytes(totalBytes)} 超出设定范围，正在换下一个',
          );
          cancelToken.cancel('outside_requested_size_range');
        },
        onProgress: (p, {detail}) {
          resetInactivityTimeout();
          onProgress?.call(p, detail: detail);
          if (mounted)
            _updateDownloadTask(
              taskId,
              progress: p,
              progressDetail: detail ?? '',
            );
        },
      );

      if (downloadedFile != null) {
        debugPrint('文件下载成功: ');
        final downloadedBytes = await downloadedFile.length();
        if ((minFileBytes != null && downloadedBytes < minFileBytes) ||
            (maxFileBytes != null && downloadedBytes > maxFileBytes)) {
          await downloadedFile.delete();
          downloadedFile = null;
          onFailureType?.call('outside_requested_size_range');
          if (mounted) _removeDownloadTask(taskId);
          return false;
        }
        if (validateSmartMedia &&
            !await _isUsefulSmartDownloadedMedia(downloadedFile, mediaType)) {
          await downloadedFile.delete();
          downloadedFile = null;
          onFailureType?.call('invalid_smart_media_content');
          if (mounted) _removeDownloadTask(taskId);
          return false;
        }
        final Map<String, dynamic> mediaMap;
        try {
          mediaMap = await _saveToMediaLibrary(downloadedFile!, mediaType);
        } on _ExistingMediaDuplicateException {
          rethrow;
        } catch (e) {
          throw _MediaLibrarySaveException(e);
        }
        if (mediaType == MediaType.video) {
          final norm = _normalizeVideoSourceUrl(absoluteUrl);
          final mediaId = mediaMap['id']?.toString();
          if (mediaId != null && mediaId.isNotEmpty) {
            _videoSourceUrlToMediaId[norm] = mediaId;
            final stablePageKey = _smartStablePageKey(smartPageUrl);
            if (stablePageKey.isNotEmpty) {
              _videoSourceUrlToMediaId[_normalizeVideoSourceUrl(smartPageUrl)] =
                  mediaId;
            }
            await _saveVideoSourceUrlMap();
          }
        }
        if (smartTask != null) {
          try {
            await _recordSmartDownload24h(
              task: smartTask,
              mediaUrl: absoluteUrl,
              title: smartMediaTitle,
              pageUrl: smartPageUrl,
              fileHash: (mediaMap['file_hash'] ?? '').toString(),
              fileSize: downloadedBytes,
            );
          } catch (e) {
            debugPrint('写入智能下载 24 小时备案失败（不影响入库）: $e');
          }
        }
        if (mounted) {
          _updateDownloadTask(taskId, status: 'completed', progressDetail: '');
          if (showSuccessPrompt) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('已保存到媒体库'),
                duration: _kMediaSaveSnackDuration,
                action: SnackBarAction(
                  label: '查看',
                  onPressed:
                      () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder:
                              (context) => const MediaManagerPage(
                                showRouteBackButton: true,
                              ),
                        ),
                      ),
                ),
              ),
            );
          }
        }
        return true;
      } else {
        onFailureType?.call('empty_download_result');
        if (mounted && !skipFailurePrompt) {
          _updateDownloadTask(taskId, status: 'failed', progressDetail: '');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _downloadErrorForUser(
                  Exception('未能生成有效文件，链接可能失效或内容不是可保存的媒体格式'),
                ),
              ),
              duration: _kMediaSaveSnackDuration,
            ),
          );
        } else if (mounted && skipFailurePrompt) {
          _removeDownloadTask(taskId);
        }
        return false;
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (sizeRangeExceeded) {
          onFailureType?.call('outside_requested_size_range');
          if (mounted) _removeDownloadTask(taskId);
        } else if (timedOut) {
          onFailureType?.call('timeout');
          debugPrint('长时间无下载进度，已取消: $absoluteUrl');
          if (mounted && skipFailurePrompt) {
            _removeDownloadTask(taskId);
          } else if (mounted) {
            _updateDownloadTask(
              taskId,
              status: 'failed',
              progressDetail: '长时间无下载进度，已取消',
            );
            if (!skipFailurePrompt) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('连续较长时间没有下载进度，已自动停止并可重试'),
                  duration: Duration(milliseconds: 1800),
                ),
              );
            }
          }
        } else {
          onFailureType?.call('cancelled');
          debugPrint('用户暂停下载: ');
        }
        return false;
      }
      var type = 'dio_error';
      final code = e.response?.statusCode ?? 0;
      if (code == 403) {
        type = 'http_403';
      } else if (code == 401) {
        type = 'http_401';
      } else if (code == 404) {
        type = 'http_404';
      } else if (code >= 500 && code < 600) {
        type = 'http_5xx';
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        type = 'timeout';
      } else if (e.type == DioExceptionType.connectionError) {
        type = 'connection_error';
      }
      onFailureType?.call(type);
      debugPrint('后台下载出错: , 错误: ');
      if (mounted && !skipFailurePrompt) {
        _updateDownloadTask(taskId, status: 'failed', progressDetail: '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_downloadErrorForUser(e)),
            duration: _kMediaSaveSnackDuration,
          ),
        );
      } else if (mounted && skipFailurePrompt) {
        _removeDownloadTask(taskId);
      }
      return false;
    } catch (e, st) {
      var type = 'exception';
      if (sizeRangeExceeded) {
        onFailureType?.call('outside_requested_size_range');
        if (mounted) _removeDownloadTask(taskId);
        return false;
      }
      final msg = e.toString().toLowerCase();
      if (msg.contains('m3u8')) {
        type = 'm3u8_parse_or_download';
      } else if (msg.contains('origin is only applicable')) {
        type = 'invalid_origin';
      } else if (msg.contains('bad state')) {
        type = 'bad_state';
      }
      debugPrint('后台下载出错: , 错误: \n');
      final duplicateRow =
          e is _ExistingMediaDuplicateException ? e.existingRow : null;
      final isLibraryDuplicate = duplicateRow != null;
      if (e is _MediaLibrarySaveException) {
        type = 'library_save_failed';
      } else if (isLibraryDuplicate) {
        type = 'already_in_library';
      }
      onFailureType?.call(type);
      if (isLibraryDuplicate) {
        if (smartTask != null) {
          final duplicateSize =
              downloadedFile != null && await downloadedFile.exists()
                  ? await downloadedFile.length()
                  : ((duplicateRow['file_size'] as num?)?.toInt() ?? 0);
          await _recordSmartDownload24h(
            task: smartTask,
            mediaUrl: absoluteUrl,
            title: smartMediaTitle,
            pageUrl: smartPageUrl,
            fileHash: (duplicateRow['file_hash'] ?? '').toString(),
            fileSize: duplicateSize,
          );
        }
        if (mediaType == MediaType.video) {
          final existingMediaId = duplicateRow['id']?.toString() ?? '';
          if (existingMediaId.isNotEmpty) {
            _videoSourceUrlToMediaId[_normalizeVideoSourceUrl(absoluteUrl)] =
                existingMediaId;
            if (_smartStablePageKey(smartPageUrl).isNotEmpty) {
              _videoSourceUrlToMediaId[_normalizeVideoSourceUrl(smartPageUrl)] =
                  existingMediaId;
            }
            await _saveVideoSourceUrlMap();
          }
        }
        try {
          if (downloadedFile != null && await downloadedFile.exists()) {
            await downloadedFile.delete();
          }
        } catch (_) {}
      }
      if (mounted) {
        if (isLibraryDuplicate) {
          _removeDownloadTask(taskId);
          if (showDuplicatePrompt) {
            await _showMediaDuplicateDialog(duplicateRow!);
          }
        } else if (!skipFailurePrompt || e is _MediaLibrarySaveException) {
          _updateDownloadTask(taskId, status: 'failed', progressDetail: '');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_downloadErrorForUser(e)),
              duration: _kMediaSaveSnackDuration,
            ),
          );
        } else {
          _removeDownloadTask(taskId);
        }
      }
      return false;
    } finally {
      timeoutTimer?.cancel();
      _downloadingUrls.remove(absoluteUrl);
    }
  }

  void _addDownloadTask(
    String id,
    String url,
    MediaType mediaType,
    CancelToken cancelToken, {
    String? displayName,
    bool isSmartDiscovery = false,
    bool isSmartBatchMedia = false,
    bool isFavoriteBatch = false,
  }) {
    final resolvedDisplayName = displayName ?? _getShortDisplayName(url);
    _downloadTasks.insert(0, {
      'id': id,
      'url': url,
      'displayName': resolvedDisplayName,
      'progress': 0.0,
      'progressDetail': '',
      'transferStatus': '',
      'lastSampleBytes': 0,
      'lastSampleAtMs': DateTime.now().millisecondsSinceEpoch,
      'smoothedBytesPerSecond': 0.0,
      'status': 'downloading',
      'cancelToken': cancelToken,
      'mediaType': mediaType,
      'isSmartDiscovery': isSmartDiscovery,
      'isSmartBatchMedia': isSmartBatchMedia,
      'isFavoriteBatch': isFavoriteBatch,
    });
    if (_downloadTasks.length > _maxDisplayTasks) _downloadTasks.removeLast();
    _downloadTasksNotifier.value = List.from(_downloadTasks);
  }

  void _updateDownloadTask(
    String id, {
    double? progress,
    String? status,
    String? progressDetail,
  }) {
    final idx = _downloadTasks.indexWhere((t) => t['id'] == id);
    if (idx < 0) return;
    if (progress != null) _downloadTasks[idx]['progress'] = progress;
    if (status != null) _downloadTasks[idx]['status'] = status;
    if (progressDetail != null) {
      _downloadTasks[idx]['progressDetail'] = progressDetail;
      final downloadedBytes = _extractDownloadedBytes(progressDetail);
      if (downloadedBytes != null) {
        _updateTransferEstimate(
          _downloadTasks[idx],
          downloadedBytes,
          progress ??
              (_downloadTasks[idx]['progress'] as num?)?.toDouble() ??
              0.0,
        );
      }
    }
    if (status != null && status != 'downloading') {
      _downloadTasks[idx]['transferStatus'] = '';
    }
    _downloadTasksNotifier.value = List.from(_downloadTasks);
  }

  int? _extractDownloadedBytes(String detail) {
    final match = RegExp(
      r'(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)\b',
      caseSensitive: false,
    ).firstMatch(detail);
    if (match == null) return null;
    final value = double.tryParse(match.group(1) ?? '');
    if (value == null) return null;
    final unit = (match.group(2) ?? 'B').toUpperCase();
    final multiplier = switch (unit) {
      'KB' => 1024,
      'MB' => 1024 * 1024,
      'GB' => 1024 * 1024 * 1024,
      _ => 1,
    };
    return (value * multiplier).round();
  }

  void _updateTransferEstimate(
    Map<String, dynamic> task,
    int downloadedBytes,
    double progress,
  ) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final previousMs = (task['lastSampleAtMs'] as num?)?.toInt() ?? nowMs;
    final previousBytes = (task['lastSampleBytes'] as num?)?.toInt() ?? 0;
    final elapsedMs = nowMs - previousMs;
    final deltaBytes = downloadedBytes - previousBytes;
    if (elapsedMs < 300 || deltaBytes <= 0) return;
    final instantSpeed = deltaBytes * 1000 / elapsedMs;
    final previousSpeed =
        (task['smoothedBytesPerSecond'] as num?)?.toDouble() ?? 0.0;
    final smoothedSpeed =
        previousSpeed <= 0
            ? instantSpeed
            : previousSpeed * 0.7 + instantSpeed * 0.3;
    task['lastSampleAtMs'] = nowMs;
    task['lastSampleBytes'] = downloadedBytes;
    task['smoothedBytesPerSecond'] = smoothedSpeed;

    var status = '${_formatBytes(smoothedSpeed.round())}/s';
    if (progress > 0.01 && progress < 0.995 && smoothedSpeed > 0) {
      final estimatedTotal = downloadedBytes / progress;
      final remainingSeconds =
          ((estimatedTotal - downloadedBytes) / smoothedSpeed).round();
      if (remainingSeconds > 0) {
        status = '$status · 预计剩余 ${_formatRemainingTime(remainingSeconds)}';
      }
    }
    task['transferStatus'] = status;
  }

  String _formatRemainingTime(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    final remainSeconds = seconds % 60;
    if (minutes < 60) return '$minutes 分 $remainSeconds 秒';
    final hours = minutes ~/ 60;
    return '$hours 小时 ${minutes % 60} 分';
  }

  String _getShortDisplayName(String url) {
    try {
      final uri = Uri.parse(url);
      final path = uri.path;
      final name = path
          .split('/')
          .lastWhere((s) => s.isNotEmpty, orElse: () => 'media');
      return name.length > 20 ? '${name.substring(0, 17)}...' : name;
    } catch (_) {
      return url.length > 25 ? '${url.substring(0, 22)}...' : url;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 将异常与内部文案转换为用户可读的下载失败说明。
  String _downloadErrorForUser(Object e) {
    if (e is _MediaLibrarySaveException) {
      return '文件已经下载完成，但写入媒体库失败；已停止重复下载，请检查存储空间或数据库状态后重试';
    }
    if (e is DioException) return '下载失败：${_getDioErrorReason(e)}';
    var s = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
    s = s.replaceAll('[下载失败]', '').trim();
    if (s.contains('SAMPLE-AES') || (s.contains('加密') && s.contains('不支持'))) {
      return '下载失败：该视频为不支持的加密格式（如 SAMPLE-AES），无法合并保存';
    }
    if (s.contains('解密失败') || (s.contains('AES') && s.contains('失败'))) {
      return '下载失败：视频分片解密失败，请稍后重试或更换播放源';
    }
    if (s.contains('密钥') && (s.contains('无效') || s.contains('缺少'))) {
      return '下载失败：无法获取解密密钥，可能被服务器限制或需要登录';
    }
    if (s.contains('M3U8') && (s.contains('解析') || s.contains('分片'))) {
      return '下载失败：流媒体列表解析或分片拉取失败，请检查网络后重试';
    }
    if (s.contains('合并') && s.contains('空')) {
      return '下载失败：合并后的文件为空，链接可能已失效';
    }
    if (s.contains('不是可播放') || s.contains('不是有效')) {
      return '下载失败：保存的内容不是有效视频/图片，可能被拦截或需登录后重试';
    }
    if (s.contains('超时')) {
      return '下载失败：$s';
    }
    if (s.contains('403') || s.contains('禁止访问')) {
      return '下载失败：服务器拒绝访问，可尝试登录站点或更换网络';
    }
    if (s.contains('404') || s.contains('不存在')) {
      return '下载失败：文件不存在或链接已失效';
    }
    if (s.contains('未能生成有效文件')) {
      return s;
    }
    if (s.contains('已存在') && s.contains('媒体库')) {
      return '该文件已在媒体库中，未重复保存';
    }
    if (s.length > 160) return '下载失败：${s.substring(0, 157)}…';
    return '下载失败：$s';
  }

  String _getDioErrorReason(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout) return '连接超时，请检查网络';
    if (e.type == DioExceptionType.receiveTimeout) return '接收超时，文件可能过大或网络慢';
    if (e.type == DioExceptionType.sendTimeout) return '发送超时';
    if (e.type == DioExceptionType.badResponse) {
      final code = e.response?.statusCode ?? 0;
      return '服务器返回$code: ${code == 403
          ? "禁止访问(可能需Referer/登录)"
          : code == 404
          ? "文件不存在"
          : code == 400
          ? "请求错误"
          : "请检查URL"}';
    }
    if (e.type == DioExceptionType.connectionError)
      return '连接失败: ${e.message ?? "无法连接服务器"}';
    if (e.type == DioExceptionType.unknown)
      return '网络异常: ${e.message ?? e.error?.toString() ?? "未知"}';
    return e.message ?? '网络错误';
  }

  void _togglePauseResume(String taskId) {
    final idx = _downloadTasks.indexWhere((t) => t['id'] == taskId);
    if (idx < 0) return;
    final task = _downloadTasks[idx];
    final status = task['status'] as String? ?? '';
    if (task['isFavoriteBatch'] == true) {
      final token = task['cancelToken'] as CancelToken?;
      if (status == 'downloading' && !(token?.isCancelled ?? true)) {
        token!.cancel('用户停止收藏批量下载');
        _updateDownloadTask(
          taskId,
          status: 'cancelled',
          progressDetail: '已停止继续添加下载，当前文件完成后结束',
        );
      }
      return;
    }
    if (task['isSmartDiscovery'] == true) {
      final token = task['cancelToken'] as CancelToken?;
      if (status == 'downloading' && !(token?.isCancelled ?? true)) {
        token!.cancel('用户停止智能下载');
        unawaited(_finishSmartDownload('用户已停止任务'));
      }
      return;
    }
    if (task['isSmartBatchMedia'] == true && status == 'downloading') {
      final token = task['cancelToken'] as CancelToken?;
      token?.cancel('skip_smart_media');
      _removeDownloadTask(taskId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已跳过当前媒体，正在寻找下一个'),
            duration: Duration(milliseconds: 1200),
          ),
        );
      }
      return;
    }
    if (status == 'downloading') {
      final token = task['cancelToken'] as CancelToken?;
      token?.cancel('用户暂停');
      _updateDownloadTask(taskId, status: 'paused');
    } else if (status == 'paused' ||
        status == 'cancelled' ||
        status == 'failed') {
      final url = task['url'] as String?;
      final mediaType = task['mediaType'] as MediaType?;
      if (url != null && mediaType != null) {
        _removeDownloadTask(taskId);
        _performBackgroundDownload(url, mediaType);
      }
    }
  }

  void _removeDownloadTask(String taskId) {
    _downloadTasks.removeWhere((t) => t['id'] == taskId);
    _downloadTasksNotifier.value = List.from(_downloadTasks);
  }

  /// 显示导入导出菜单
  void _showExportImportMenu() {
    showModalBottomSheet(
      context: context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('导出浏览器数据'),
                  subtitle: const Text('导出书签、常用网站和收藏视频'),
                  onTap: () {
                    Navigator.pop(context);
                    _exportBrowserData();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('导入浏览器数据'),
                  subtitle: const Text('导入书签、常用网站和收藏视频'),
                  onTap: () {
                    Navigator.pop(context);
                    _importBrowserData();
                  },
                ),
              ],
            ),
          ),
    );
  }

  /// 导出浏览器数据
  Future<void> _exportBrowserData() async {
    String currentPhase = '准备';
    try {
      // 创建进度通知器
      final ValueNotifier<String> progressNotifier = ValueNotifier<String>(
        '准备导出浏览器数据...',
      );

      // 显示进度对话框
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (context) => AlertDialog(
              content: ValueListenableBuilder<String>(
                valueListenable: progressNotifier,
                builder: (context, progress, child) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      Text(
                        progress,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  );
                },
              ),
            ),
      );

      // 获取导出目录
      final Directory? externalDir = await getExternalStorageDirectory();
      if (externalDir == null) {
        throw Exception('无法访问外部存储目录');
      }

      final String exportDir = '${externalDir.path}/browser_backups';
      final Directory backupDir = Directory(exportDir);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      currentPhase = '收集数据';
      progressNotifier.value = '收集浏览器数据...';

      // 收集浏览器数据
      final Map<String, dynamic> browserData = {
        'bookmarks': _bookmarks,
        'common_websites': _commonWebsites,
        'favorite_videos': await _loadSharedFavoriteVideos(), // 包含收藏视频数据
        'export_time': DateTime.now().toIso8601String(),
        'version': '1.1',
      };

      currentPhase = '创建数据文件';
      progressNotifier.value = '创建数据文件...';

      // 创建JSON文件
      final String jsonPath = '$exportDir/browser_data.json';
      final File jsonFile = File(jsonPath);
      await jsonFile.writeAsString(jsonEncode(browserData));

      currentPhase = '创建ZIP文件';
      progressNotifier.value = '创建ZIP文件...';

      // 创建ZIP文件
      final String zipPath =
          '$exportDir/browser_backup_${DateTime.now().millisecondsSinceEpoch}.zip';
      final Archive archive = Archive();
      final bytes = await jsonFile.readAsBytes();
      archive.addFile(ArchiveFile('browser_data.json', bytes.length, bytes));
      final List<int>? zipData = await compute(encodeArchive, archive);

      if (zipData == null) {
        throw Exception('创建ZIP文件失败');
      }

      final File zipFile = File(zipPath);
      await zipFile.writeAsBytes(zipData);

      // 删除临时JSON文件
      await jsonFile.delete();

      progressNotifier.value = '导出完成！';

      // 关闭进度对话框
      if (mounted) {
        Navigator.pop(context);
      }

      // 分享文件
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: '浏览器数据备份',
        text: '浏览器数据备份文件，包含书签和常用网站数据。',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('浏览器数据导出成功！文件已保存到: ${zipPath.split('/').last}'),
            action: SnackBarAction(
              label: '打开文件',
              onPressed: () async {
                // 打开文件管理器到导出目录
                final result = await FilePicker.platform.clearTemporaryFiles();
                debugPrint('清理临时文件结果: $result');
              },
            ),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('导出浏览器数据时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        final userMsg = formatExportImportError(e, '导出失败');
        showExportImportErrorDialog(
          context,
          '浏览器数据导出失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    }
  }

  /// 导入浏览器数据
  Future<void> _importBrowserData() async {
    String currentPhase = '准备';
    try {
      // 显示警告对话框
      bool? confirm = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('警告'),
              content: const Text('导入浏览器数据将会覆盖当前的书签和常用网站，确定要继续吗？'),
              actions: [
                TextButton(
                  child: const Text('取消'),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: const Text('确定'),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
      );

      if (confirm != true) return;

      // 选择ZIP文件
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      final zipPath = result?.files.single.path;
      if (result != null && zipPath != null && zipPath.isNotEmpty) {
        // 创建进度通知器
        final ValueNotifier<String> progressNotifier = ValueNotifier<String>(
          '准备导入...',
        );

        // 显示进度对话框
        showDialog(
          context: context,
          barrierDismissible: false,
          builder:
              (context) => AlertDialog(
                content: ValueListenableBuilder<String>(
                  valueListenable: progressNotifier,
                  builder: (context, progress, child) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        Text(
                          progress,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    );
                  },
                ),
              ),
        );

        currentPhase = '解压文件';
        progressNotifier.value = '解压文件...';

        // 读取ZIP文件（限制 100MB 避免 OOM）
        const int kMaxZipSizeBytes = 100 * 1024 * 1024;
        final File zipFile = File(zipPath);
        final fileSize = await zipFile.length();
        if (fileSize > kMaxZipSizeBytes) {
          throw Exception(
            'ZIP 文件过大 (${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)，超过 100MB 限制，请选择较小的备份文件',
          );
        }
        final List<int> zipBytes = await zipFile.readAsBytes();
        final Archive? archive = ZipDecoder().decodeBytes(zipBytes);

        if (archive == null) {
          throw Exception('无法解析ZIP文件');
        }

        currentPhase = '解析数据';
        progressNotifier.value = '解析数据...';

        // 查找并解析JSON文件
        ArchiveFile? jsonFile;
        for (final file in archive) {
          if (file.name == 'browser_data.json') {
            jsonFile = file;
            break;
          }
        }

        if (jsonFile == null) {
          throw Exception('ZIP文件中未找到浏览器数据文件');
        }

        // 解析JSON数据
        final String jsonContent = utf8.decode(jsonFile.content as List<int>);
        final Map<String, dynamic> browserData = jsonDecode(jsonContent);

        currentPhase = '导入数据';
        progressNotifier.value = '导入数据...';

        // 验证数据格式
        if (browserData['version'] == null) {
          throw Exception('数据格式不支持，缺少版本信息');
        }

        // 导入书签
        if (browserData['bookmarks'] != null) {
          final List<dynamic> bookmarksData = browserData['bookmarks'];
          setState(() {
            _bookmarks =
                bookmarksData
                    .map((item) => Map<String, String>.from(item))
                    .toList();
          });
          await _saveBookmarks();
        }

        // 导入常用网站
        if (browserData['common_websites'] != null) {
          final List<dynamic> websitesData = browserData['common_websites'];
          setState(() {
            _commonWebsites.clear();
            for (final item in websitesData) {
              final Map<String, dynamic> website = Map<String, dynamic>.from(
                item,
              );
              // 只保存 iconCode，不动态创建 IconData 实例
              if (website['iconCode'] == null) {
                website['iconCode'] = Icons.public.codePoint;
              }
              _commonWebsites.add(website);
            }
          });
          await _saveCommonWebsites();
        }

        // 导入收藏视频
        if (browserData['favorite_videos'] != null) {
          final List<dynamic> favData = browserData['favorite_videos'];
          final List<Map<String, dynamic>> favList =
              favData.map((item) => Map<String, dynamic>.from(item)).toList();
          await _saveSharedFavoriteVideos(favList);
        }

        progressNotifier.value = '导入完成！';

        // 关闭进度对话框
        if (mounted) {
          Navigator.pop(context);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('浏览器数据导入成功！'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e, stack) {
      debugPrint('导入浏览器数据时出错 [$currentPhase]: $e\n$stack');
      if (mounted) {
        Navigator.pop(context); // 关闭进度对话框
        final userMsg = formatExportImportError(e, '导入失败');
        showExportImportErrorDialog(
          context,
          '浏览器数据导入失败',
          '出错阶段：$currentPhase\n\n$userMsg',
        );
      }
    }
  }

  /// 将长 URL 缩短为简洁显示（域名 + 路径摘要，单行友好）
  String _shortenUrlForDisplay(String url) {
    if (url.isEmpty) return '';
    try {
      final uri = Uri.tryParse(url);
      if (uri == null)
        return url.length > 45 ? '${url.substring(0, 42)}...' : url;
      final host = uri.host.isNotEmpty ? uri.host : url;
      final path = uri.path;
      if (path.isEmpty || path == '/') return host;
      // 路径过长时只保留前一段
      final pathDisplay =
          path.length > 25 ? '${path.substring(0, 22)}...' : path;
      return '$host$pathDisplay';
    } catch (_) {
      return url.length > 45 ? '${url.substring(0, 42)}...' : url;
    }
  }

  // 8. 历史记录弹窗
  void _showHistory() {
    showModalBottomSheet(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setState) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.delete_forever),
                        title: const Text('清空全部历史记录'),
                        onTap: () async {
                          Navigator.pop(context);
                          _history.clear();
                          await _saveHistory();
                          setState(() {});
                        },
                      ),
                      const Divider(),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _history.length,
                          itemBuilder: (context, index) {
                            final item = _history[index];
                            final title = item['title'] as String?;
                            final url = item['url'] as String? ?? '';
                            final timeStr =
                                (item['datetime'] as String?)
                                    ?.substring(0, 19)
                                    .replaceAll('T', ' ') ??
                                '';
                            // 优先用标题，若标题过长或与 URL 相同则用缩短的 URL
                            final displayText =
                                (title != null &&
                                        title != url &&
                                        title.length <= 50)
                                    ? title
                                    : _shortenUrlForDisplay(url);
                            return SizedBox(
                              height: 32,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    Navigator.pop(context);
                                    _loadUrl(url);
                                  },
                                  onLongPress: () async {
                                    _history.removeAt(index);
                                    await _saveHistory();
                                    setState(() {});
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            displayText,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          timeStr,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey[600],
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
          ),
    );
  }

  // 根据 iconCode 获取对应的图标（使用常量映射避免动态创建）
  IconData _getIconFromCode(int? iconCode) {
    if (iconCode == null) return Icons.public;

    // 使用常量图标映射，避免动态创建 IconData
    switch (iconCode) {
      case 0xe3c3:
        return Icons.public; // public
      case 0xe3c4:
        return Icons.public_off; // public_off
      case 0xe3c5:
        return Icons.publish; // publish
      case 0xe3c6:
        return Icons.query_builder; // query_builder
      case 0xe3c7:
        return Icons.question_answer; // question_answer
      case 0xe3c8:
        return Icons.queue; // queue
      case 0xe3c9:
        return Icons.queue_music; // queue_music
      case 0xe3ca:
        return Icons.queue_play_next; // queue_play_next
      case 0xe3cb:
        return Icons.radio; // radio
      case 0xe3cc:
        return Icons.radio_button_checked; // radio_button_checked
      case 0xe3cd:
        return Icons.radio_button_unchecked; // radio_button_unchecked
      case 0xe3ce:
        return Icons.rate_review; // rate_review
      case 0xe3cf:
        return Icons.receipt; // receipt
      case 0xe3d0:
        return Icons.recent_actors; // recent_actors
      case 0xe3d1:
        return Icons.record_voice_over; // record_voice_over
      case 0xe3d2:
        return Icons.redeem; // redeem
      case 0xe3d3:
        return Icons.redo; // redo
      case 0xe3d4:
        return Icons.refresh; // refresh
      case 0xe3d5:
        return Icons.remove; // remove
      case 0xe3d6:
        return Icons.remove_circle; // remove_circle
      case 0xe3d7:
        return Icons.remove_circle_outline; // remove_circle_outline
      case 0xe3d8:
        return Icons.remove_from_queue; // remove_from_queue
      case 0xe3d9:
        return Icons.visibility; // visibility
      case 0xe3da:
        return Icons.visibility_off; // visibility_off
      case 0xe3db:
        return Icons.voice_chat; // voice_chat
      case 0xe3dc:
        return Icons.voicemail; // voicemail
      case 0xe3dd:
        return Icons.volume_down; // volume_down
      case 0xe3de:
        return Icons.volume_mute; // volume_mute
      case 0xe3df:
        return Icons.volume_off; // volume_off
      case 0xe3e0:
        return Icons.volume_up; // volume_up
      case 0xe3e1:
        return Icons.vpn_key; // vpn_key
      case 0xe3e2:
        return Icons.vpn_lock; // vpn_lock
      case 0xe3e3:
        return Icons.wallpaper; // wallpaper
      case 0xe3e4:
        return Icons.warning; // warning
      case 0xe3e5:
        return Icons.watch; // watch
      case 0xe3e6:
        return Icons.watch_later; // watch_later
      case 0xe3e7:
        return Icons.wb_auto; // wb_auto
      case 0xe3e8:
        return Icons.wb_incandescent; // wb_incandescent
      case 0xe3e9:
        return Icons.wb_iridescent; // wb_iridescent
      case 0xe3ea:
        return Icons.wb_sunny; // wb_sunny
      case 0xe3eb:
        return Icons.wc; // wc
      case 0xe3ec:
        return Icons.web; // web
      case 0xe3ed:
        return Icons.web_asset; // web_asset
      case 0xe3ee:
        return Icons.weekend; // weekend
      case 0xe3ef:
        return Icons.whatshot; // whatshot
      case 0xe3f0:
        return Icons.widgets; // widgets
      case 0xe3f1:
        return Icons.wifi; // wifi
      case 0xe3f2:
        return Icons.wifi_lock; // wifi_lock
      case 0xe3f3:
        return Icons.wifi_tethering; // wifi_tethering
      case 0xe3f4:
        return Icons.work; // work
      case 0xe3f5:
        return Icons.wrap_text; // wrap_text
      case 0xe3f6:
        return Icons.youtube_searched_for; // youtube_searched_for
      case 0xe3f7:
        return Icons.zoom_in; // zoom_in
      case 0xe3f8:
        return Icons.zoom_out; // zoom_out
      case 0xe3f9:
        return Icons.zoom_out_map; // zoom_out_map
      default:
        return Icons.public; // 默认图标
    }
  }

  // 页面加载完成后的处理
  void _onPageFinished(String url) async {
    try {
      // about:blank 为 WebView 初始空白页，不切换主界面、不加入历史
      final isBlankPage =
          url.isEmpty ||
          url.toLowerCase().startsWith('about:blank') ||
          url.toLowerCase().startsWith('about://blank');
      if (isBlankPage) {
        setState(() {
          _isLoading = false;
          _loadingProgress = 0.0;
        });
        debugPrint('页面加载完成(about:blank): 保持主界面');
        final task = _smartDownloadTask;
        if (task != null && task['siteProfile'] == 'x') {
          final expected =
              (task['xReturnExpectedUrl'] ?? task['xReturnUrl'] ?? '')
                  .toString()
                  .trim();
          if (expected.startsWith('http') && _isXPlatformPage(expected)) {
            final attempts = ((task['xReturnAttempts'] as int?) ?? 0) + 1;
            task['xReturnAttempts'] = attempts;
            if (attempts <= 3) {
              task['phase'] = 'x_search_returning';
              Future<void>.delayed(const Duration(milliseconds: 80), () {
                if (identical(_smartDownloadTask, task)) {
                  _loadUrl(expected);
                }
              });
            }
          }
        }
        return;
      }

      // 注入媒体下载处理程序。快速重定向时，旧页面的完成回调不能
      // 再推进智能下载，否则会在列表页、主页和错误页之间反复跳转。
      final mediaHandlersReady = await _injectDownloadHandlers(
        expectedUrl: url,
      );

      // 添加历史记录（仅真实网页）
      final ctrl = _controller;
      final actualUrl = (await ctrl?.getUrl())?.toString() ?? _currentUrl;
      if (!_isSameLoadedDocument(url, actualUrl)) {
        debugPrint('忽略已失效的页面完成回调: $url -> $actualUrl');
        return;
      }
      if (_isXPlatformPage(actualUrl)) {
        unawaited(_flushBrowserCookies());
      }
      if (!mediaHandlersReady && _smartDownloadTask != null) {
        final task = _smartDownloadTask!;
        final id = (task['discoveryTaskId'] ?? '').toString();
        if (id.isNotEmpty) {
          _updateDownloadTask(
            id,
            progressDetail: '完整媒体监听暂不可用，正在使用页面资源与卡片点击兼容模式...',
          );
        }
      }
      String title = ctrl != null ? (await ctrl.getTitle() ?? url) : url;
      await _addHistory(title, url);

      // 更新状态：仅当加载真实网页时切换到 WebView
      setState(() {
        _isLoading = false;
        _currentUrl = url;
        _urlController.text = url;
        _showHomePage = false;
      });

      // 通知父组件浏览器状态变化
      widget.onBrowserHomePageChanged?.call(_showHomePage);

      debugPrint('页面加载完成: $url, 标题: $title');
      unawaited(_advanceSmartDownload(url));
    } catch (e) {
      debugPrint('页面加载完成处理时出错: $e');
    }
  }
}
