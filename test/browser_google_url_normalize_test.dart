import 'package:change_copy/services/browser_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeCommonWebsiteUrl', () {
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
        BrowserService.normalizeCommonWebsiteUrl('https://www.google.com.hk/m/'),
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
      expect(
        BrowserService.maybeForceGoogleShortcutUrl('Google', good),
        good,
      );
      expect(
        BrowserService.maybeForceGoogleShortcutUrl('Google2', good),
        good,
      );
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
        BrowserService.isDeadGoogleMobileUrl(
          'https://www.google.com.hk/?sa=X',
        ),
        isFalse,
      );
      expect(
        BrowserService.isDeadGoogleMobileUrl(
          'https://www.google.com.hk/',
        ),
        isFalse,
      );
    });
  });
}
