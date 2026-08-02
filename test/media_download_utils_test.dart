import 'dart:convert';

import 'package:change_copy/utils/media_download_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isMediaFragmentUrl', () {
    test('keeps complete media URLs', () {
      expect(
        isMediaFragmentUrl('https://cdn.example/video.mp4?token=abc'),
        isFalse,
      );
      expect(
        isMediaFragmentUrl('https://cdn.example/master.m3u8?token=abc'),
        isFalse,
      );
    });

    test('detects DASH, CMAF, and range fragments', () {
      expect(
        isMediaFragmentUrl('https://cdn.example/dash-segment-1-f1.mp4'),
        isTrue,
      );
      expect(
        isMediaFragmentUrl('https://cdn.example/dash-init-f4-v1.webm'),
        isTrue,
      );
      expect(isMediaFragmentUrl('https://cdn.example/video/12.m4s'), isTrue);
      expect(
        isMediaFragmentUrl('https://cdn.example/videoplayback?range=0-999'),
        isTrue,
      );
      expect(
        isMediaFragmentUrl(
          'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
          '?_nc_cat=1&oe=ABC&oh=DEF&bytestart=0&byteend=1023',
        ),
        isTrue,
      );
    });
  });

  test('recovers Facebook progressive MP4 from bytestart/byteend', () {
    expect(
      recoverWholeMediaUrlFromFragment(
        'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
        '?_nc_cat=1&oe=ABC&oh=DEF&bytestart=0&byteend=1023',
      ),
      'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
      '?_nc_cat=1&oe=ABC&oh=DEF',
    );
  });

  test('normalizes Facebook bytestart into whole progressive candidate', () {
    expect(
      normalizeMediaCandidateUrls(
        const [
          'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
              '?_nc_cat=1&oe=ABC&oh=DEF&bytestart=0&byteend=1023',
          'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
              '?_nc_cat=1&oe=ABC&oh=DEF',
        ],
        video: true,
        maxCandidates: 4,
      ),
      const [
        'https://video.xx.fbcdn.net/v/t42.1790-2/123_n.mp4'
            '?_nc_cat=1&oe=ABC&oh=DEF',
      ],
    );
  });

  test('recovers a whole URL without removing signatures', () {
    expect(
      recoverWholeMediaUrlFromFragment(
        'https://cdn.example/videoplayback?token=abc&range=0-999&rn=3',
      ),
      'https://cdn.example/videoplayback?token=abc',
    );
    expect(
      recoverWholeMediaUrlFromFragment(
        'https://cdn.example/dash-segment-1-f1.mp4?token=abc',
      ),
      'https://cdn.example/master.mpd?token=abc',
    );
    expect(
      recoverWholeMediaUrlFromFragment(
        'https://cdn.example/path/dash-init-f4-v1.webm?token=abc',
      ),
      'https://cdn.example/path/master.mpd?token=abc',
    );
  });

  test('normalizes, deduplicates, and caps target candidates', () {
    expect(
      normalizeMediaCandidateUrls(
        const [
          'https://cdn.example/video.mp4?token=abc',
          'https://cdn.example/video.mp4?token=abc',
          'https://cdn.example/dash-segment-1-f1.mp4',
          'https://cdn.example/videoplayback?token=x&range=0-999',
          'https://cdn.example/other.mp4',
        ],
        video: true,
        maxCandidates: 3,
      ),
      const [
        'https://cdn.example/video.mp4?token=abc',
        'https://cdn.example/master.mpd',
        'https://cdn.example/videoplayback?token=x',
      ],
    );
  });

  test('extracts Facebook CDN and reel identities', () {
    expect(
      facebookMediaIdentity(
        'https://video.xx.fbcdn.net/v/t42.1790-2/123_456_789_n.mp4'
        '?_nc_cat=1&oe=ABC&oh=DEF',
      ),
      '123_456_789_n',
    );
    expect(
      facebookMediaIdentity('https://www.facebook.com/reel/9876543210/?s=ig'),
      'reel:9876543210',
    );
    expect(facebookIdentitiesMatch('123_456_789_n', '123_456_789_hd'), isTrue);
    expect(facebookIdentitiesMatch('123_456_789_n', '999_888_777_n'), isFalse);
    expect(isFacebookReelsPageUrl('https://m.facebook.com/reel/1'), isTrue);
    expect(
      isFacebookReelsPageUrl('https://m.facebook.com/watch/?v=1'),
      isFalse,
    );
  });

  test('detects init-only MP4 stubs and keeps playable containers', () {
    // ftyp + moov only (typical FB init / tens-of-KB black stub).
    final initOnly = <int>[
      0x00, 0x00, 0x00, 0x14, // size 20
      ...'ftyp'.codeUnits,
      ...'isom'.codeUnits,
      0x00, 0x00, 0x00, 0x01,
      ...'isom'.codeUnits,
      0x00, 0x00, 0x00, 0x08, // size 8
      ...'moov'.codeUnits,
    ];
    expect(
      looksLikeIncompleteMp4Stub(initOnly, totalLength: initOnly.length),
      isTrue,
    );
    expect(kFacebookMinVideoBytes, 2 * 1024 * 1024);

    // ftyp + mdat → playable progressive.
    final withMdat = <int>[
      0x00, 0x00, 0x00, 0x14, // size 20
      ...'ftyp'.codeUnits,
      ...'isom'.codeUnits,
      0x00, 0x00, 0x00, 0x01,
      ...'isom'.codeUnits,
      0x00, 0x00, 0x00, 0x10, // size 16
      ...'mdat'.codeUnits,
      0x00, 0x01, 0x02, 0x03,
      0x04, 0x05, 0x06, 0x07,
    ];
    expect(
      looksLikeIncompleteMp4Stub(withMdat, totalLength: withMdat.length),
      isFalse,
    );
  });

  test('detects audio-only MP4 tracks and keeps real video tracks', () {
    List<int> fakeMp4WithHandler(String handler, String sampleEntry) => <int>[
      0,
      0,
      0,
      24,
      ...'ftyp'.codeUnits,
      ...'mp41'.codeUnits,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      28,
      ...'hdlr'.codeUnits,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...handler.codeUnits,
      ...sampleEntry.codeUnits,
    ];

    expect(isClearlyAudioOnlyMp4(fakeMp4WithHandler('soun', 'mp4a')), isTrue);
    expect(isClearlyAudioOnlyMp4(fakeMp4WithHandler('vide', 'avc1')), isFalse);
    expect(isClearlyAudioOnlyMp4('not an mp4 soun mp4a'.codeUnits), isFalse);
  });

  test('facebookMediaIdentity extracts reel and CDN stems', () {
    expect(
      facebookMediaIdentity('https://www.facebook.com/reel/1234567890/'),
      'reel:1234567890',
    );
    expect(
      facebookMediaIdentity(
        'https://video.xx.fbcdn.net/v/t42.1790-2/111_222_333_n.mp4?oe=ABC&oh=DEF',
      ),
      '111_222_333_n',
    );
  });

  test('Facebook efg groups DASH tracks and rejects audio-only candidates', () {
    String candidate(Map<String, Object> metadata) {
      final efg = base64Url.encode(utf8.encode(jsonEncode(metadata)));
      return 'https://video.xx.fbcdn.net/v/t42/test.mp4?efg=$efg&oh=x';
    }

    final videoUrl = candidate(<String, Object>{
      'video_id': '123456789012345',
      'vencode_tag': 'dash_h264-basic-gen2_720p',
      'video_duration': 6,
      'bitrate': 1252832,
    });
    final audioUrl = candidate(<String, Object>{
      'video_id': '123456789012345',
      'vencode_tag': 'dash_ln_heaac_vbr3_audio',
      'video_duration': 6,
      'bitrate': 63936,
    });

    expect(facebookMediaIdentity(videoUrl), 'fbvideo:123456789012345');
    expect(facebookMediaIdentity(audioUrl), facebookMediaIdentity(videoUrl));
    expect(facebookMediaMetadata(videoUrl)?.isVideoTrack, isTrue);
    expect(facebookMediaMetadata(videoUrl)?.resolutionHeight, 720);
    expect(
      facebookMediaMetadata(videoUrl)!.qualityScore,
      greaterThan(
        const FacebookMediaMetadata(
          videoId: '123456789012345',
          encodeTag: 'dash_h264_360p',
          bitrate: 500000,
        ).qualityScore,
      ),
    );
    expect(facebookMediaMetadata(audioUrl)?.isAudioOnly, isTrue);
    expect(
      facebookVideoMinimumBytes(videoUrl),
      inInclusiveRange(kFacebookVerifiedTrackMinBytes, 1024 * 1024),
    );
    expect(facebookVideoMinimumBytes(audioUrl), kFacebookMinVideoBytes);
  });

  test('Instagram efg groups video and audio DASH tracks by asset id', () {
    String candidate(Map<String, Object> metadata) {
      final efg = base64Url.encode(utf8.encode(jsonEncode(metadata)));
      return 'https://scontent.cdninstagram.com/o1/test.mp4?efg=$efg&oh=x';
    }

    final videoUrl = candidate(<String, Object>{
      'xpv_asset_id': 4534214333564544,
      'vencode_tag': 'ig-xpvds.clips.c2-C3.dash_baseline_1_v1',
      'duration_s': 33,
      'bitrate': 1232388,
    });
    final audioUrl = candidate(<String, Object>{
      'xpv_asset_id': 4534214333564544,
      'vencode_tag': 'ig-xpvds.clips.c2-C3.dash_ln_heaac_vbr3_audio',
      'duration_s': 33,
      'bitrate': 65566,
    });

    expect(facebookMediaIdentity(videoUrl), 'fbvideo:4534214333564544');
    expect(facebookMediaIdentity(audioUrl), facebookMediaIdentity(videoUrl));
    expect(facebookMediaMetadata(videoUrl)?.isVideoTrack, isTrue);
    expect(facebookMediaMetadata(audioUrl)?.isAudioOnly, isTrue);
    expect(
      facebookMediaMetadata(videoUrl)?.expectedBytes,
      greaterThan(facebookMediaMetadata(audioUrl)!.expectedBytes!),
    );
    final shortLowBitrateVideo = candidate(<String, Object>{
      'xpv_asset_id': 18111588757781907,
      'vencode_tag': 'ig-xpvds.clips.c2-C3.dash_baseline_1_v1',
      'duration_s': 9,
      'bitrate': 214566,
    });
    expect(
      instagramVideoMinimumBytes(shortLowBitrateVideo),
      lessThan(kFacebookVerifiedTrackMinBytes),
    );
    expect(
      instagramVideoMinimumBytes(shortLowBitrateVideo),
      lessThan(facebookMediaMetadata(shortLowBitrateVideo)!.expectedBytes!),
    );
  });

  test('facebookIdentitiesMatch treats quality suffixes as same reel', () {
    expect(facebookIdentitiesMatch('111_222_333_n', '111_222_333_hd'), isTrue);
    expect(facebookIdentitiesMatch('111_222_333_n', '999_888_777_n'), isFalse);
    // reel:id never equals a CDN stem — callers must upgrade to CDN identity.
    expect(
      facebookIdentitiesMatch('reel:1234567890', '111_222_333_n'),
      isFalse,
    );
  });
}
