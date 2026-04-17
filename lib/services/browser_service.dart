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
  static const String _kVideoSourceUrlMapKey = 'browser_video_source_url_map_v1';
  static const String _kSharedFavoriteVideosKey = 'doc_web_video_favorites_v1';

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
        return decoded.map((item) => Map<String, String>.from(item)).toList();
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
        {'name': 'Google', 'url': 'https://www.google.com', 'iconCode': Icons.public.codePoint},
        {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': Icons.public.codePoint},
        {'name': 'Edge', 'url': 'https://www.bing.com', 'iconCode': Icons.public.codePoint},
        {'name': 'X', 'url': 'https://twitter.com', 'iconCode': Icons.public.codePoint},
        {'name': 'Facebook', 'url': 'https://www.facebook.com', 'iconCode': Icons.public.codePoint},
      ];
    }
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
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

  Future<void> saveSharedFavoriteVideos(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSharedFavoriteVideosKey, jsonEncode(items));
  }
}
