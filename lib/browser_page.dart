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
import 'package:path/path.dart' as p;
import 'package:encrypt/encrypt.dart' as enc;

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

/// TikPORN 的 DASH 音频和视频会并行下载，每轨 10 路，合计低于单主机连接上限。
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
  const isTikPornPage = location.hostname === 'tik.porn' || location.hostname.endsWith('.tik.porn');
  const mediaBufferUrls = new WeakMap();
  const sourceBufferOwners = new WeakMap();
  const mediaSourceByBlobUrl = new Map();
  const mediaSourceActivity = new WeakMap();
  let latestMediaBuffer = null;

  const rememberMediaBuffer = (buffer, rawUrl) => {
    if (!isTikPornPage || !buffer || !rawUrl || typeof buffer !== 'object') return;
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

  if (isTikPornPage) {
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
        const activity = mediaSource && mediaSourceActivity.get(mediaSource);
        if (!activity) return [];
        return Array.from(activity.entries())
          .sort((a, b) => (b[1].count - a[1].count) || (b[1].latest - a[1].latest))
          .slice(0, 12)
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
        if (isTikPornPage && response && typeof response.arrayBuffer === 'function') {
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
  static const int _maxDisplayTasks = 8;
  bool _downloadPanelExpanded = false;
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
    // 长按候选可能来自同一页面中其他预加载视频，不能据此判断当前视频重复。
    if (item['downloadOrigin'] != 'long_press') {
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
                              TextButton.icon(
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
                                label: const Text(
                                  '一键清空',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
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
                                label: const Text('一键下载全部'),
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

  List<String> _buildFavoriteAttempts(String primary, List<String> candidates) {
    final merged = <String>[];
    final seen = <String>{};
    void push(String? u) {
      if (u == null) return;
      final s = u.trim();
      if (s.isEmpty) return;
      final abs = _toAbsoluteUrl(s);
      if (abs.isEmpty ||
          seen.contains(abs) ||
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
    merged.sort((a, b) {
      final scoreOrder = _scoreFavoriteVideoUrl(
        b,
      ).compareTo(_scoreFavoriteVideoUrl(a));
      if (scoreOrder != 0) return scoreOrder;
      return insertionOrder[a]!.compareTo(insertionOrder[b]!);
    });
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
  }) async {
    final isLongPress = item['downloadOrigin'] == 'long_press';
    final allowDurationMismatch = item['allowDurationMismatch'] == true;
    final expectedDurationSeconds =
        (item['durationSec'] as num?)?.toDouble() ?? 0.0;
    final existingMedia = await _findExistingMediaForItem(item);
    if (existingMedia != null) {
      await _markFavoriteDownloaded(item, downloaded: true);
      onFailureType?.call('already_in_library');
      if (showResultHint && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('该媒体已在媒体库中，已为你标记为已下载'),
            duration: const Duration(seconds: 3),
            action: SnackBarAction(label: '查看', onPressed: _openMediaLibrary),
          ),
        );
      }
      return true;
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
    );
    if (isLongPress && attempts.length > 3) {
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
      ok = await _performBackgroundDownload(
        attempts[i],
        MediaType.video,
        skipFailurePrompt: i < attempts.length - 1,
        onFailureType: (t) => failureType = t,
        inactivityTimeout:
            isLongPress
                ? const Duration(minutes: 2)
                : const Duration(minutes: 3),
        maxRequestAttempts: isLongPress ? 4 : null,
        expectedDurationSeconds:
            isLongPress && expectedDurationSeconds > 0
                ? expectedDurationSeconds
                : null,
        allowDurationMismatch: allowDurationMismatch,
        showSuccessPrompt: false,
        onProgress: (fraction, {String? detail}) {
          progress.value = fraction.clamp(0.0, 1.0);
          if (detail != null && detail.trim().isNotEmpty) {
            detailNotifier.value = '候选 ${i + 1}/${attempts.length}：$detail';
          }
        },
      );
      sw.stop();
      lastFailureType = failureType;
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
          failureType == 'cancelled') {
        break;
      }
    }
    if (!ok &&
        !isLongPress &&
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
            expectedDurationSeconds:
                expectedDurationSeconds > 0 ? expectedDurationSeconds : null,
            showSuccessPrompt: false,
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
      onFailureType?.call(lastFailureType);
    }
    if (ok && lastFailureType != 'already_downloading') {
      await _markFavoriteDownloaded(item, downloaded: true);
    }
    if (showResultHint && mounted) {
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

  Future<void> _downloadFavoritesBatch(List<Map<String, dynamic>> items) async {
    if (items.isEmpty || !mounted) return;
    final progress = ValueNotifier<double>(0.0);
    final progressText = ValueNotifier<String>('0 / ${items.length}');
    var success = 0;
    var failed = 0;
    var skipped = 0;
    var retried = 0;
    final retryQueue = <Map<String, dynamic>>[];
    if (mounted) {
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'batch_download_favorites',
        barrierColor: Colors.black.withValues(alpha: 0.16),
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder:
            (_, __, ___) => Center(
              child: Container(
                width: 250,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.74),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '正在批量下载收藏视频',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ValueListenableBuilder<double>(
                      valueListenable: progress,
                      builder:
                          (_, p, __) => LinearProgressIndicator(
                            value: p.clamp(0.0, 1.0),
                            minHeight: 6,
                            color: Colors.greenAccent,
                            backgroundColor: Colors.white24,
                          ),
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<String>(
                      valueListenable: progressText,
                      builder:
                          (_, txt, __) => Text(
                            txt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ),
      );
    }
    try {
      for (int i = 0; i < items.length; i++) {
        final currentItem = items[i];
        final currentName =
            currentItem['title'] ?? currentItem['name'] ?? '未知媒体';
        progressText.value = '正在下载(${i + 1}/${items.length})：$currentName';

        if (_isFavoriteLikelyDownloaded(currentItem)) {
          skipped++;
          progress.value = ((i + 1) / items.length) * 0.75;
          continue;
        }
        var failureType = 'unknown';
        final ok = await _downloadOneFavorite(
          item: currentItem,
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
        progress.value = ((i + 1) / items.length) * 0.75;
      }
      if (retryQueue.isNotEmpty) {
        for (int j = 0; j < retryQueue.length; j++) {
          final currentItem = retryQueue[j];
          final currentName =
              currentItem['title'] ?? currentItem['name'] ?? '未知媒体';
          progressText.value = '重试(${j + 1}/${retryQueue.length})：$currentName';

          retried++;
          await Future<void>.delayed(const Duration(milliseconds: 320));
          final ok = await _downloadOneFavorite(
            item: currentItem,
            showResultHint: false,
            showModalDialog: false, // 重试时同样不显示单个文件弹窗
          );
          if (ok) {
            success++;
            failed--;
          }
          progress.value = 0.75 + ((j + 1) / retryQueue.length) * 0.25;
        }
      }
    } finally {
      progress.value = 1.0;
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      progress.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('批量下载完成：成功 $success 条，失败 $failed 条，跳过 $skipped 条'),
            duration: const Duration(milliseconds: 1500),
          ),
        );
        if (retried > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('二轮重试已执行：$retried 条（仅超时/网络类失败）'),
              duration: const Duration(milliseconds: 1300),
            ),
          );
        }
      }
      progressText.dispose();
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

  Future<void> _showVideoDuplicateSnackBar(
    Map<String, dynamic> existingRow,
  ) async {
    if (!mounted) return;
    final location = await _resolveMediaLocationLabel(existingRow);
    final title = existingRow['name']?.toString() ?? '该视频';
    final mediaItem = MediaItem.fromMap(Map<String, dynamic>.from(existingRow));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('视频已存在'),
          content: Text('媒体库中已经有这个视频了。\n\n文件名：$title\n位置：$location'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (context) =>
                            const MediaManagerPage(showRouteBackButton: true),
                  ),
                );
              },
              child: const Text('打开媒体库'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (context) => MediaPreviewPage(
                          mediaItems: [mediaItem],
                          initialIndex: 0,
                        ),
                  ),
                );
              },
              child: const Text('直接查看'),
            ),
          ],
        );
      },
    );
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

  Future<bool> _injectDownloadHandlers({bool allowRetry = true}) async {
    final controller = _controller;
    if (controller == null) return false;
    debugPrint('正在安装网页媒体长按处理程序');
    try {
      await controller.evaluateJavascript(
        source: '''
      (() => {
      const handlerVersion = 'media-download-v9';
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
        
        observer.observe(document.body, {
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
      function handleMediaDownload(target, e) {
        if (!target) {
          updateFeedbackStatus('未找到媒体元素', false);
          return;
        }
        const longPressSessionId = 'lp-' + Date.now() + '-' + Math.random().toString(36).slice(2, 10);
        
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
          const currentVideo = pickCurrentVideo(window._lastTouchX, window._lastTouchY);
          const atPoint = document.elementsFromPoint(window._lastTouchX, window._lastTouchY);
          for (const el of atPoint) {
            const tag = (el.tagName || '').toLowerCase();
            if (tag === 'video' && (el.currentSrc || el.src)) {
              bestTarget = el;
              break;
            }
            if (tag === 'img' && (el.currentSrc || el.src)) {
              bestTarget = el;
              break;
            }
          }
          const selectedTag = (bestTarget.tagName || '').toLowerCase();
          if (currentVideo && selectedTag !== 'img' && selectedTag !== 'image') bestTarget = currentVideo;
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
        if (videoEl && window.MediaInterceptor && window.MediaInterceptor.interceptedRequests) {
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
        // 拦截到的 m3u8/mp4 不要被 DOM 里的海报图、缩略图或占位 src 覆盖（否则原生侧会当图片下载或失败后退化为截屏）
        if (interceptedStreamUrl && videoEl) {
          const dom = (url || '').toLowerCase();
          const domHasStream = /\\.(m3u8|m3u|mp4|webm|ts)(\\?|#|\$)/.test(dom) || dom.includes('mpegurl');
          if (!domHasStream || domUrlLooksLikePosterOrThumb(url) || url === videoEl.poster) {
            const i = interceptedStreamUrl.toLowerCase();
            if (i.includes('.m3u8') || i.includes('.m3u') || i.includes('mpegurl') || /\\.(mp4|webm|ts)(\\?|#|\$)/.test(i)) {
              url = interceptedStreamUrl;
            }
          }
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
            const pageHost = String(location.hostname || '').toLowerCase();
            const isTikPornPage = pageHost === 'tik.porn' || pageHost.endsWith('.tik.porn');
            if (mediaType === 'video' && isTikPornPage) {
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
                action: 'download',
                pageUrl: location.href || '',
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
                      Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: extractBase64FromDataUrl(dataUrl), isBase64: true, action: 'download' }));
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
                              Flutter.postMessage(JSON.stringify({ type: 'media', mediaType: 'image', url: extractBase64FromDataUrl(dataUrl), isBase64: true, action: 'download' }));
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
        if (interceptedStreamUrl) push(interceptedStreamUrl);
        try {
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
        if (videoEl) {
          try {
            const srcs = Array.from(videoEl.querySelectorAll('source')).map(s => s.src || s.getAttribute('src'));
            for (const s of srcs) push(s || '');
            push(videoEl.currentSrc || videoEl.src);
          } catch (_) {}
        }
        try {
          const mediaInside = target.querySelectorAll && target.querySelectorAll('img, video, source, a[href]');
          if (mediaInside) {
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
          action: 'download',
          pageUrl: location.href || '',
          title: document.title || '',
          sessionId: longPressSessionId,
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
            "window.__appMediaDownloadHandlersVersion === 'media-download-v9'",
      );
      if (ready == true || ready.toString().toLowerCase() == 'true')
        return true;
    } catch (e, st) {
      debugPrint('网页媒体长按处理程序安装失败: $e\n$st');
    }
    if (allowRetry && mounted && identical(controller, _controller)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return _injectDownloadHandlers(allowRetry: false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('媒体长按功能初始化失败，请刷新当前网页后重试'),
          duration: Duration(seconds: 2),
        ),
      );
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
          if (mounted) {
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
          final title = (data['title'] ?? '').toString().trim();
          final candidateUrls = List<String>.from(downloadCandidateUrls);
          final normalizedPrimary = normalizeMediaCandidateUrls(
            <String>[_toAbsoluteUrl(urlValue)],
            video: true,
            maxCandidates: 1,
          );
          final primaryVideoUrl =
              normalizedPrimary.isEmpty ? '' : normalizedPrimary.first;

          if (primaryVideoUrl.isEmpty && candidateUrls.isEmpty) {
            if (mounted) {
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
            'pageUrl': pageUrl.isNotEmpty ? pageUrl : _currentUrl,
            'videoUrl': primaryVideoUrl,
            'title': title,
            'candidateUrls': candidateUrls,
            'downloadOrigin': 'long_press',
            'sessionId': mediaSessionId,
            'durationSec': messageDurationSeconds,
          };

          // 查重：如果媒体库已存在，则弹出提示并终止下载
          final existing = await _findExistingMediaForItem(itemMap);
          if (existing != null) {
            await _showVideoDuplicateSnackBar(existing);
            return;
          }

          await _downloadMediaRobustly(item: itemMap, showResultHint: true);
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
          if (mounted) {
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
            final useTikPornDisambiguation = _isTikPornPage(messagePageUrl);
            final boundFragmentValue = data['boundFragments'];
            final boundFragmentUrls = <String>[];
            if (useTikPornDisambiguation && boundFragmentValue is List) {
              for (final value in boundFragmentValue) {
                if (value is String && value.trim().isNotEmpty) {
                  boundFragmentUrls.add(value.trim());
                }
              }
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
                useTikPornDisambiguation
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
                      : useTikPornDisambiguation
                      ? await _selectDashManifestForLongPress(
                        dashCandidates,
                        targetDurationSeconds: messageDurationSeconds,
                      )
                      : dashCandidates.first;
              if (selectedManifest == null) return;
              await _downloadMediaRobustly(
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
                  'sessionId': mediaSessionId,
                  'durationSec': messageDurationSeconds,
                  // TikPORN's player and MPD can report different timelines.
                  // Keep a valid downloaded video instead of deleting it only
                  // because their reported durations differ.
                  'allowDurationMismatch': true,
                },
                showResultHint: true,
              );
              return;
            }
          }
          if (isStreamReference) {
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
          await _handleBlobUrl(
            urlValue,
            mediaType,
            sourceMimeType: sourceMimeType,
          );
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
            await _showVideoDuplicateSnackBar(existing);
            return;
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
            onFailureType: (type) => failureType = type,
          );
          if (success) break;
          if (failureType == 'library_save_failed' ||
              failureType == 'already_in_library' ||
              failureType == 'cancelled') {
            break;
          }
        }
        if (success) {
          _notifyMediaDownloadSaved();
        } else if (!success && canCanvasFallback && mounted) {
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
          } catch (_) {
            _awaitingCanvasFallbackResult = false;
            _canvasFallbackCompleter = null;
            if (canCanvasFallback && !_mediaDownloadSaveResolved && mounted) {
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
      } finally {
        if (didRegisterMediaUrl || isStreamReference) {
          _processedMediaUrlsSince.remove(urlValue);
          _releaseJsProcessedUrl(urlValue);
        }
      }
    } catch (e, stackTrace) {
      debugPrint('Error handling JavaScript message: $e');
      debugPrint('Trace: $stackTrace');
    }
  }

  Future<void> _handleBlobUrl(
    String base64Data,
    String mediaType, {
    String? sourceMimeType,
  }) async {
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
    _controller?.clearCache();
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

  Widget _buildWebsiteCard(Map<String, dynamic> website, int index) {
    // 根据 iconCode 获取对应的图标
    IconData iconData = _getIconFromCode(website['iconCode']);

    return InkWell(
      key: ValueKey(website['url']),
      onTap: () => _loadUrl(website['url']),
      onDoubleTap:
          () => _showWebsiteOptionsDialog(
            context,
            website,
            _commonWebsites.indexWhere((site) => site['url'] == website['url']),
          ),
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
                await _showVideoDuplicateSnackBar(existing);
                return;
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
            await _showVideoDuplicateSnackBar(existing);
            return;
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
    final baseConcurrency = useAcceleratedDash ? 10 : 4;
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
        if (useAcceleratedDash && audio != null) {
          await Future.wait<void>([
            downloadTrack(video, videoFile),
            downloadTrack(audio, audioFile),
          ]);
        } else {
          await downloadTrack(video, videoFile);
          if (audio != null) await downloadTrack(audio, audioFile);
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
          final duplicate = await _databaseService.findDuplicateMediaItem(
            fileHash,
            fileName,
          );
          if (duplicate != null) {
            throw _ExistingMediaDuplicateException(duplicate);
          }
          await _databaseService.insertMediaItem(mediaItemMap);
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
    try {
      await Future.delayed(const Duration(milliseconds: 80));
      final screenshot = await ctrl.takeScreenshot();
      if (screenshot == null || screenshot.isEmpty || !mounted) return false;
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final uuid = const Uuid().v4();
      final file = File('${mediaDir.path}/$uuid.png');
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
      builder:
          (context) => StatefulBuilder(
            builder: (BuildContext context, StateSetter modalSetState) {
              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.5,
                child: Column(
                  children: [
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
            IconButton(
              icon: const Icon(Icons.bookmark),
              onPressed: _showBookmarks,
              tooltip: '显示书签',
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
                              mixedContentMode:
                                  MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                              userAgent:
                                  'Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
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
                              return NavigationActionPolicy.ALLOW;
                            },
                          ),
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
                    final panelH = _downloadPanelExpanded ? 280.0 : 60.0;
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

  Widget _buildDownloadTasksPanel(
    List<Map<String, dynamic>> tasks,
    List<Map<String, dynamic>> activeTasks,
  ) {
    return GestureDetector(
      onTap:
          () =>
              setState(() => _downloadPanelExpanded = !_downloadPanelExpanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          maxWidth: _downloadPanelExpanded ? 320 : 60,
          maxHeight: _downloadPanelExpanded ? 280 : 60,
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
                                              ? '停止'
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
    double? expectedDurationSeconds,
    bool allowDurationMismatch = false,
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
    if (mounted) _addDownloadTask(taskId, absoluteUrl, mediaType, cancelToken);

    File? downloadedFile;
    try {
      debugPrint('开始后台下载: , 媒体类型: ');

      downloadedFile = await _downloadFile(
        absoluteUrl,
        mediaType,
        cancelToken: cancelToken,
        maxRequestAttempts: maxRequestAttempts,
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
        if (mediaType == MediaType.video &&
            expectedDurationSeconds != null &&
            expectedDurationSeconds > 0) {
          final actualDurationMs = await _probeNativeVideoDurationMs(
            downloadedFile,
          );
          if (actualDurationMs != null && actualDurationMs > 0) {
            final actualSeconds = actualDurationMs / 1000.0;
            final tolerance = max(3.0, expectedDurationSeconds * 0.12);
            if ((actualSeconds - expectedDurationSeconds).abs() > tolerance) {
              if (allowDurationMismatch) {
                Logger.log(
                  '[稳健下载诊断] 下载结果时长与长按媒体不一致，按降级策略保留：'
                  'expected=${expectedDurationSeconds.toStringAsFixed(2)}s, '
                  'actual=${actualSeconds.toStringAsFixed(2)}s, url=$absoluteUrl',
                );
              } else {
                await downloadedFile.delete();
                downloadedFile = null;
                throw Exception('[下载失败] 下载结果时长与当前长按视频不一致，已丢弃错误文件');
              }
            }
          }
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
            await _saveVideoSourceUrlMap();
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
        if (timedOut) {
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
      final msg = e.toString().toLowerCase();
      if (msg.contains('m3u8')) {
        type = 'm3u8_parse_or_download';
      } else if (msg.contains('时长与当前长按视频不一致')) {
        type = 'wrong_media_duration';
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
        try {
          if (downloadedFile != null && await downloadedFile.exists()) {
            await downloadedFile.delete();
          }
        } catch (_) {}
      }
      if (mounted) {
        if (isLibraryDuplicate) {
          _removeDownloadTask(taskId);
          await _showVideoDuplicateSnackBar(duplicateRow!);
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
    CancelToken cancelToken,
  ) {
    final displayName = _getShortDisplayName(url);
    _downloadTasks.insert(0, {
      'id': id,
      'url': url,
      'displayName': displayName,
      'progress': 0.0,
      'progressDetail': '',
      'transferStatus': '',
      'lastSampleBytes': 0,
      'lastSampleAtMs': DateTime.now().millisecondsSinceEpoch,
      'smoothedBytesPerSecond': 0.0,
      'status': 'downloading',
      'cancelToken': cancelToken,
      'mediaType': mediaType,
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
        return;
      }

      // 注入媒体下载处理程序
      await _injectDownloadHandlers();

      // 添加历史记录（仅真实网页）
      final ctrl = _controller;
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
    } catch (e) {
      debugPrint('页面加载完成处理时出错: $e');
    }
  }
}
