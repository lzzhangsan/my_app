import 'dart:convert';

import 'package:change_copy/services/browser_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('normalizeCommonWebsiteUrl', () {
    test('routes only the Telegram root shortcut to official Web K', () {
      expect(
        BrowserService.normalizeCommonWebsiteUrl('https://web.telegram.org'),
        BrowserService.kTelegramWebKUrl,
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('web.telegram.org/'),
        BrowserService.kTelegramWebKUrl,
      );
      expect(
        BrowserService.prepareUrlForLoad('web.telegram.org'),
        BrowserService.kTelegramWebKUrl,
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('https://web.telegram.org/a/'),
        'https://web.telegram.org/a/',
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('https://web.telegram.org/k/'),
        'https://web.telegram.org/k/',
      );
    });

    test('rewrites dead /m homes', () {
      expect(
        BrowserService.normalizeCommonWebsiteUrl('http://www.google.com/m'),
        BrowserService.kGoogleHomeUrl,
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('http://www.google.cn/m'),
        BrowserService.kGoogleHomeUrl,
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl(
          'https://www.google.com.hk/m/',
        ),
        'https://www.google.com.hk/',
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('www.google.com/m'),
        BrowserService.kGoogleHomeUrl,
      );
    });

    test('keeps good https google.hk bookmark with query', () {
      const good =
          'https://www.google.com.hk/?sa=X&ved=2ahUKEwiC7eKmr_CVAxUsXesIHW7zMJAQO3oECAUQAA';
      expect(BrowserService.normalizeCommonWebsiteUrl(good), good);
      expect(BrowserService.maybeForceGoogleShortcutUrl('Google', good), good);
      expect(BrowserService.maybeForceGoogleShortcutUrl('Google2', good), good);
      expect(BrowserService.prepareUrlForLoad(good), good);
    });

    test('does not force http google.hk query to google.com', () {
      const hkHttp = 'http://www.google.com.hk/?sa=X&ved=abc';
      expect(BrowserService.normalizeCommonWebsiteUrl(hkHttp), hkHttp);
      expect(
        BrowserService.maybeForceGoogleShortcutUrl('Google', hkHttp),
        hkHttp,
      );
      expect(BrowserService.prepareUrlForLoad(hkHttp), hkHttp);
    });

    test('does not destroy maps', () {
      const maps = 'https://www.google.com/maps';
      expect(BrowserService.normalizeCommonWebsiteUrl(maps), maps);
      expect(BrowserService.isDeadGoogleMobileUrl(maps), isFalse);
    });

    test('does not rewrite bare google.cn / http google homes', () {
      expect(
        BrowserService.normalizeCommonWebsiteUrl('http://www.google.com'),
        'http://www.google.com',
      );
      expect(
        BrowserService.normalizeCommonWebsiteUrl('http://www.google.cn/'),
        'http://www.google.cn/',
      );
      expect(
        BrowserService.maybeForceGoogleShortcutUrl(
          'Google',
          'http://www.google.com',
        ),
        'http://www.google.com',
      );
    });

    test('adds https only when scheme missing', () {
      expect(
        BrowserService.normalizeCommonWebsiteUrl('www.example.com/path?q=1'),
        'https://www.example.com/path?q=1',
      );
      expect(
        BrowserService.prepareUrlForLoad('www.baidu.com'),
        'https://www.baidu.com',
      );
    });

    test('force-updates named Google only for dead /m', () {
      expect(
        BrowserService.maybeForceGoogleShortcutUrl(
          'Google',
          'http://www.google.cn/m',
        ),
        BrowserService.kGoogleHomeUrl,
      );
    });

    test('detects dead mobile urls for navigation bounce', () {
      expect(
        BrowserService.isDeadGoogleMobileUrl('http://www.google.com/m'),
        isTrue,
      );
      expect(
        BrowserService.isDeadGoogleMobileUrl('https://www.google.com.hk/?sa=X'),
        isFalse,
      );
      expect(
        BrowserService.isDeadGoogleMobileUrl('https://www.google.com.hk/'),
        isFalse,
      );
    });
  });

  group('loadCommonWebsites / loadBookmarks migration', () {
    const hkGood =
        'https://www.google.com.hk/?sa=X&ved=2ahUKEwiC7eKmr_CVAxUsXesIHW7zMJAQO3oECAUQAA';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'loadCommonWebsites keeps .hk?sa=X&ved=… unchanged and does not rewrite',
      () async {
        SharedPreferences.setMockInitialValues({
          'common_websites': jsonEncode([
            {'name': 'Google', 'url': hkGood, 'iconCode': 0xe0c8},
            {'name': '百度', 'url': 'https://www.baidu.com', 'iconCode': 0xe0c8},
          ]),
        });

        final service = BrowserService();
        final list = await service.loadCommonWebsites();
        expect(list.length, 2);
        expect(list[0]['url'], hkGood);
        expect(list[0]['name'], 'Google');

        // Second load must still be exact (no silent write-back to google.com).
        final again = await service.loadCommonWebsites();
        expect(again[0]['url'], hkGood);

        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('common_websites')!;
        expect(raw.contains(hkGood), isTrue);
        expect(raw.contains('"url":"https://www.google.com"'), isFalse);
        expect(raw.contains('"url":"https://www.google.com/"'), isFalse);
      },
    );

    test(
      'loadCommonWebsites migrates only exact /m and leaves .hk alone',
      () async {
        SharedPreferences.setMockInitialValues({
          'common_websites': jsonEncode([
            {
              'name': 'Google',
              'url': 'http://www.google.cn/m',
              'iconCode': 0xe0c8,
            },
            {'name': 'Google登录', 'url': hkGood, 'iconCode': 0xe0c8},
          ]),
        });

        final list = await BrowserService().loadCommonWebsites();
        expect(list[0]['url'], BrowserService.kGoogleHomeUrl);
        expect(list[1]['url'], hkGood);
      },
    );

    test('loadBookmarks keeps .hk query bookmark unchanged', () async {
      SharedPreferences.setMockInitialValues({
        'bookmarks': jsonEncode([
          {'name': 'Google2', 'url': hkGood},
        ]),
      });

      final list = await BrowserService().loadBookmarks();
      expect(list.single['url'], hkGood);
      expect(list.single['name'], 'Google2');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bookmarks')!.contains(hkGood), isTrue);
    });
  });
}
