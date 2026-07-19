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
      expect(isMediaFragmentUrl('https://cdn.example/video/12.m4s'), isTrue);
      expect(
        isMediaFragmentUrl('https://cdn.example/videoplayback?range=0-999'),
        isTrue,
      );
    });
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
      isNull,
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
        'https://cdn.example/videoplayback?token=x',
        'https://cdn.example/other.mp4',
      ],
    );
  });
}
