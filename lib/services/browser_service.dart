import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BrowserService {
  static final BrowserService _instance = BrowserService._internal();
  factory BrowserService() => _instance;
  BrowserService._internal();

  static const String _kBookmarksKey = 'bookmarks';
  static const String _kHistoryKey = 'history';
  static const String _kCommonWebsitesKey = 'common_websites';
  static const String _kVideoSourceUrlMapKey =
      'browser_video_source_url_map_v1';
  static const String _kSharedFavoriteVideosKey = 'doc_web_video_favorites_v1';

  static const String kGoogleHomeUrl = 'https://www.google.com/';
  static const String kTelegramWebKUrl = 'https://web.telegram.org/k/';

  /// Hosts that historically shipped broken 常用网站 / bookmark shortcuts.
  static bool isGoogleShortcutHost(String host) {
    final h = host.toLowerCase();
    if (h == 'google.com' ||
        h == 'www.google.com' ||
        h == 'm.google.com' ||
        h == 'google.cn' ||
        h == 'www.google.cn' ||
        h == 'm.google.cn' ||
        h == 'google.com.hk' ||
        h == 'www.google.com.hk' ||
        h == 'm.google.com.hk') {
      return true;
    }
    // Any google.<tld> / www.google.<tld> / m.google.<tld>
    return RegExp(r'^(www\.|m\.)?google\.(com|cn|com\.[a-z]{2})$').hasMatch(h);
  }

  /// True when URL is the dead Google mobile home (`…/m` or `…/m/…`).
  /// Does **not** match `/maps`, and never flags good `.hk` / query bookmarks.
  static bool isDeadGoogleMobileUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return false;
    final uri = _tryParseHttpish(trimmed);
    if (uri != null && isGoogleShortcutHost(uri.host)) {
      final path = uri.path;
      // Path-only: `/m` or `/m/...` — never query/fragment false positives.
      return path == '/m' || path.startsWith('/m/');
    }
    // Unparseable fallback: only exact dead legacy patterns.
    final lower = trimmed.toLowerCase();
    return RegExp(
      r'^(https?:\/\/)?(www\.|m\.)?google\.(cn|com(\.[a-z]{2})?)/m([/?#]|$)',
    ).hasMatch(lower);
  }

  static Uri? _tryParseHttpish(String trimmed) {
    var uri = Uri.tryParse(trimmed);
    if (uri != null && !uri.hasScheme && uri.host.isEmpty) {
      uri = Uri.tryParse('http://$trimmed');
    }
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  static String _httpsGoogleHomeForHost(String host) {
    final h = host.toLowerCase();
    // google.cn and m.* mobile hosts are unreliable / redirect to dead /m.
    if (h.contains('google.cn') || h.startsWith('m.')) {
      return kGoogleHomeUrl;
    }
    final www = h.startsWith('www.') ? h : 'www.$h';
    return 'https://$www/';
  }

  static bool _hasUrlScheme(String trimmed) {
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(trimmed);
  }

  /// Preserve user-saved URLs; only rewrite known dead Google `/m` shortcuts.
  ///
  /// Rules:
  /// - `http(s)://(www.|m.)google.(com|cn|com.hk)/m` → https home (prefer same
  ///   host for .com / .com.hk; force google.com for .cn / m.*)
  /// - Complete URLs (with scheme): keep host/path/query exactly (trim only)
  /// - Scheme-less input: add `https://` (still no host/path/query rewrite)
  /// - Valid `https://www.google.com.hk/?sa=…` stays as-is
  /// - Never rewrite a good URL *into* `/m`, and never force `.hk` → `.com`
  static String normalizeCommonWebsiteUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    if (isDeadGoogleMobileUrl(trimmed)) {
      final uri = _tryParseHttpish(trimmed);
      if (uri != null && isGoogleShortcutHost(uri.host)) {
        return _httpsGoogleHomeForHost(uri.host);
      }
      return kGoogleHomeUrl;
    }

    final uri = _tryParseHttpish(trimmed);
    if (uri == null) {
      return trimmed;
    }

    // Telegram ships two independent official web clients. Web A has had
    // login sessions where the UI keeps only five digits even though the
    // delivered code contains six, and that screen exposes no submit control.
    // Route only the ambiguous root shortcut to Web K. Explicit /a/ and /k/
    // URLs are user choices and must remain untouched.
    final telegramHost = uri.host.toLowerCase();
    if ((telegramHost == 'web.telegram.org' ||
            telegramHost == 'www.web.telegram.org') &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment) {
      return kTelegramWebKUrl;
    }

    // User / complete URLs: do not mutate host, path, or query.
    if (_hasUrlScheme(trimmed)) {
      return trimmed;
    }
    // Scheme missing only: prefix https, keep the rest of the parsed URL.
    return uri.replace(scheme: 'https').toString();
  }

  /// One-time migration helper for stored shortcuts.
  /// Only rewrites dead Google `/m` URLs; never forces `.hk` / query URLs to
  /// `google.com`. [name] kept for call-site compatibility (ignored).
  static String maybeForceGoogleShortcutUrl(String name, String url) {
    return normalizeCommonWebsiteUrl(url);
  }

  /// Prepare a stored URL for WebView load without mutating good bookmarks.
  static String prepareUrlForLoad(String rawUrl) {
    final normalized = normalizeCommonWebsiteUrl(rawUrl);
    if (normalized.isEmpty) return normalized;
    if (_hasUrlScheme(normalized)) return normalized;
    return 'https://$normalized';
  }

  Future<List<Map<String, String>>> loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kBookmarksKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [
        {'name': '百度', 'url': 'https://www.baidu.com'},
        {'name': 'Bilibili', 'url': 'https://www.bilibili.com'},
      ];
    }
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        var migrated = false;
        final list =
            decoded.map((item) {
              if (item is String) {
                migrated = true;
                final url = normalizeCommonWebsiteUrl(item);
                return {'name': url, 'url': url};
              }
              final map = Map<String, String>.from(
                (item as Map).map(
                  (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
                ),
              );
              final rawUrl = map['url'] ?? '';
              // Only migrate known dead Google /m shortcuts; keep user URLs intact.
              if (isDeadGoogleMobileUrl(rawUrl)) {
                final url = normalizeCommonWebsiteUrl(rawUrl);
                if (url != rawUrl) {
                  map['url'] = url;
                  migrated = true;
                }
              }
              return map;
            }).toList();
        if (migrated) {
          await saveBookmarks(list);
        }
        return list;
      }
    } catch (e) {
      debugPrint('Error loading bookmarks: $e');
    }
    return [];
  }

  Future<void> saveBookmarks(List<Map<String, String>> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBookmarksKey, jsonEncode(bookmarks));
  }

  Future<List<Map<String, dynamic>>> loadCommonWebsites() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kCommonWebsitesKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [
        {
          'name': 'Google',
          'url': kGoogleHomeUrl,
          'iconCode': Icons.public.codePoint,
        },
        {
          'name': '百度',
          'url': 'https://www.baidu.com',
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
      ];
    }
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        var migrated = false;
        final list =
            decoded.map((item) {
              final map = Map<String, dynamic>.from(item as Map);
              final rawUrl = (map['url'] ?? '').toString();
              // Only migrate known dead Google /m shortcuts; keep user URLs intact.
              if (isDeadGoogleMobileUrl(rawUrl)) {
                final url = normalizeCommonWebsiteUrl(rawUrl);
                if (url != rawUrl) {
                  map['url'] = url;
                  migrated = true;
                }
              }
              return map;
            }).toList();
        if (migrated) {
          await saveCommonWebsites(list);
        }
        return list;
      }
    } catch (e) {
      debugPrint('Error loading common websites: $e');
    }
    return [];
  }

  Future<void> saveCommonWebsites(List<Map<String, dynamic>> websites) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCommonWebsitesKey, jsonEncode(websites));
  }

  Future<Map<String, String>> loadVideoSourceUrlMap() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kVideoSourceUrlMapKey);
    if (jsonString == null || jsonString.isEmpty) return {};
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e) {
      debugPrint('Error loading video source url map: $e');
    }
    return {};
  }

  Future<void> saveVideoSourceUrlMap(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kVideoSourceUrlMapKey, jsonEncode(map));
  }

  Future<List<Map<String, dynamic>>> loadSharedFavoriteVideos() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_kSharedFavoriteVideosKey);
    if (jsonString == null || jsonString.isEmpty) return [];
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
      }
    } catch (e) {
      debugPrint('Error loading shared favorite videos: $e');
    }
    return [];
  }

  Future<void> saveSharedFavoriteVideos(
    List<Map<String, dynamic>> items,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSharedFavoriteVideosKey, jsonEncode(items));
  }
}
