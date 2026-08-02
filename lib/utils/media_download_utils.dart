import 'dart:convert';

const int kFacebookVerifiedTrackMinBytes = 256 * 1024;

class FacebookMediaMetadata {
  const FacebookMediaMetadata({
    required this.videoId,
    required this.encodeTag,
    this.durationSeconds,
    this.bitrate,
  });

  final String videoId;
  final String encodeTag;
  final int? durationSeconds;
  final int? bitrate;

  bool get isAudioOnly {
    final tag = encodeTag.toLowerCase();
    return tag.contains('audio') ||
        tag.contains('heaac') ||
        tag.contains('aac_') ||
        tag.endsWith('_aac');
  }

  bool get isVideoTrack {
    if (isAudioOnly) return false;
    final tag = encodeTag.toLowerCase();
    return tag.contains('h264') ||
        tag.contains('avc') ||
        tag.contains('video') ||
        tag.contains('dash_baseline') ||
        RegExp(r'(?:^|_)\d{3,4}p(?:_|$)').hasMatch(tag);
  }

  int? get expectedBytes {
    final seconds = durationSeconds;
    final bitsPerSecond = bitrate;
    if (seconds == null ||
        seconds <= 0 ||
        bitsPerSecond == null ||
        bitsPerSecond <= 0) {
      return null;
    }
    return (seconds * bitsPerSecond / 8).round();
  }

  int get resolutionHeight {
    final match = RegExp(
      r'(?:^|_)(\d{3,4})p(?:_|$)',
      caseSensitive: false,
    ).firstMatch(encodeTag);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// Compare renditions belonging to the same Facebook video. Resolution is
  /// the primary signal; bitrate breaks ties within one resolution.
  int get qualityScore {
    if (!isVideoTrack) return isAudioOnly ? -1 : 0;
    return resolutionHeight * 1000000 + (bitrate ?? 0);
  }
}

FacebookMediaMetadata? facebookMediaMetadata(String url) {
  final uri = Uri.tryParse(url.trim());
  final encoded = uri?.queryParameters['efg'];
  if (encoded == null || encoded.trim().isEmpty) return null;
  try {
    final json = jsonDecode(
      utf8.decode(base64Decode(base64.normalize(encoded.trim()))),
    );
    if (json is! Map) return null;
    int? asInt(Object? value) =>
        value is num ? value.round() : int.tryParse('$value');
    return FacebookMediaMetadata(
      // Instagram uses the same signed `efg` envelope but calls the stable
      // media identity xpv_asset_id instead of video_id.
      videoId:
          (json['video_id'] ?? json['xpv_asset_id'] ?? '').toString().trim(),
      encodeTag: (json['vencode_tag'] ?? '').toString().trim(),
      durationSeconds: asInt(json['video_duration'] ?? json['duration_s']),
      bitrate: asInt(json['bitrate']),
    );
  } catch (_) {
    return null;
  }
}

int facebookVideoMinimumBytes(String url) {
  final metadata = facebookMediaMetadata(url);
  if (metadata?.isVideoTrack != true) return kFacebookMinVideoBytes;
  final expected = metadata!.expectedBytes;
  if (expected == null) return kFacebookVerifiedTrackMinBytes;
  final completenessFloor = (expected * 0.55).round();
  return completenessFloor.clamp(
    kFacebookVerifiedTrackMinBytes,
    kFacebookMinVideoBytes,
  );
}

/// Instagram can legitimately serve very short/low-bitrate DASH video tracks
/// below Facebook's 256 KiB safety floor. Use the signed duration/bitrate
/// estimate when available, while retaining a small absolute floor that still
/// rejects init-only placeholders. Container validation remains the final gate.
int instagramVideoMinimumBytes(String url) {
  final metadata = facebookMediaMetadata(url);
  if (metadata?.isVideoTrack != true) return 64 * 1024;
  final expected = metadata!.expectedBytes;
  if (expected == null) return 64 * 1024;
  return (expected * 0.40).round().clamp(64 * 1024, 512 * 1024);
}

/// Facebook Reels stubs (init-only / incomplete progressive) often land around
/// tens of KB. Real short videos are typically several MB+. Reject below this
/// before inserting into the media library; callers should retry the next URL.
// Facebook 视频硬性最低大小：小于 2MB 的候选一律视为分片、低质量轨或
// 黑色视频占位。下载器会继续尝试同一媒体身份下的其它候选。
const int kFacebookMinVideoBytes = 2 * 1024 * 1024;

/// Walk ISO-BMFF boxes in [bytes] and detect init-only / incomplete MP4 stubs
/// (ftyp+moov without mdat/moof). When [totalLength] is larger than the probe,
/// only treat as stub if the file itself is small enough that media data would
/// normally already appear in the probe window.
bool looksLikeIncompleteMp4Stub(List<int> bytes, {int? totalLength}) {
  final fileLen = totalLength ?? bytes.length;
  if (fileLen < 8) return true;
  final limit = bytes.length;
  if (limit < 8) return fileLen < kFacebookMinVideoBytes;

  var offset = 0;
  var sawFtyp = false;
  var sawMoov = false;
  var sawMdat = false;
  var sawMoof = false;
  while (offset + 8 <= limit) {
    final size =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'ftyp' || type == 'styp') sawFtyp = true;
    if (type == 'moov') sawMoov = true;
    if (type == 'mdat') sawMdat = true;
    if (type == 'moof') sawMoof = true;
    if (sawMdat || sawMoof) return false;

    var advance = size;
    if (size == 1 && offset + 16 <= limit) {
      // 64-bit largesize — treat as end of safe walk.
      break;
    }
    if (size == 0) {
      // Box extends to EOF.
      break;
    }
    if (advance < 8) break;
    if (offset + advance > limit) {
      // Box claims to continue past the probe; if the whole file is tiny and
      // we never saw media data, it is still an incomplete stub.
      break;
    }
    offset += advance;
  }

  final probedWholeFile = limit >= fileLen;
  final looksInitOnly = (sawFtyp || sawMoov) && !sawMdat && !sawMoof;
  if (!looksInitOnly) return false;
  if (probedWholeFile) return true;
  // Partial probe of a large progressive file: do not false-positive.
  if (fileLen >= kFacebookMinVideoBytes) return false;
  return true;
}

/// Returns true only when an ISO-BMFF/MP4 probe conclusively contains one or
/// more audio track handlers but no video track handler.
///
/// Instagram (and other DASH sites) often exposes an `mp4a` audio rendition
/// before the matching video rendition. Saving that response with an `.mp4`
/// extension produces a black player with a working duration/progress bar.
/// Inconclusive probes deliberately return false so a valid MP4 whose `moov`
/// box was not sampled is never discarded.
bool isClearlyAudioOnlyMp4(List<int> bytes) {
  if (bytes.length < 20) return false;

  bool containsAscii(String value) {
    final needle = value.codeUnits;
    for (var i = 0; i <= bytes.length - needle.length; i++) {
      var matches = true;
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  if (!containsAscii('ftyp') && !containsAscii('styp')) return false;

  var sawAudioHandler = false;
  var sawVideoHandler = false;
  final hdlr = 'hdlr'.codeUnits;
  for (var i = 0; i <= bytes.length - 20; i++) {
    if (bytes[i] != hdlr[0] ||
        bytes[i + 1] != hdlr[1] ||
        bytes[i + 2] != hdlr[2] ||
        bytes[i + 3] != hdlr[3]) {
      continue;
    }
    // `i` points to the hdlr box type. Handler type follows version/flags and
    // pre_defined, at i+12 in regular ISO-BMFF hdlr boxes.
    final handler = String.fromCharCodes(bytes.sublist(i + 12, i + 16));
    if (handler == 'soun') sawAudioHandler = true;
    if (handler == 'vide') sawVideoHandler = true;
  }

  // Some generated files have unusual handler layouts. Sample-entry markers
  // provide a safe fallback, while an explicit video marker always wins.
  final sawVideoSample =
      containsAscii('avc1') ||
      containsAscii('avc3') ||
      containsAscii('hvc1') ||
      containsAscii('hev1') ||
      containsAscii('av01') ||
      containsAscii('vp09');
  final sawAudioSample =
      containsAscii('mp4a') ||
      containsAscii('Opus') ||
      containsAscii('ac-3') ||
      containsAscii('ec-3');

  if (sawVideoHandler || sawVideoSample) return false;
  return sawAudioHandler || sawAudioSample;
}

bool isMediaFragmentUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  if (RegExp(r'\.(?:m4s|cmfv|cmfa)(\?|#|$)').hasMatch(lower)) return true;
  const fragmentHints = <String>[
    'dash-init',
    'dash_init',
    '/segment/',
    '/segments/',
    '/chunk/',
    '/chunks/',
    '/fragment/',
    '/fragments/',
    'dash-segment',
    'dash_segment',
    'dash-chunk',
    'dash_chunk',
    '/init.mp4',
    '/init.m4s',
  ];
  if (fragmentHints.any(lower.contains)) return true;
  if (RegExp(
    r'(?:^|[/_.-])(?:seg|segment|chunk|fragment|frag|part)[-_]?\d+(?:[_.-]|/|\?|#|$)',
  ).hasMatch(lower)) {
    return true;
  }
  final uri = Uri.tryParse(lower);
  if (uri == null) return false;
  final query = uri.queryParameters;
  // Facebook CDN often serves byte-range fragments via bytestart/byteend.
  // Callers should recover the whole progressive URL with
  // [recoverWholeMediaUrlFromFragment] instead of saving these stubs.
  if (query.containsKey('bytestart') && query.containsKey('byteend')) {
    return true;
  }
  return RegExp(r'^\d+-\d+$').hasMatch(query['range'] ?? '') ||
      (query.containsKey('sq') && RegExp(r'^\d+$').hasMatch(query['sq'] ?? ''));
}

/// Range-based requests often point to the same progressive media URL with
/// transport-only query parameters. Path-based DASH/CMAF segments cannot be
/// safely reconstructed without parsing and muxing the manifest.
String? recoverWholeMediaUrlFromFragment(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  final lowerPath = uri.path.toLowerCase();
  if (lowerPath.contains('dash-init') ||
      lowerPath.contains('dash_init') ||
      lowerPath.contains('dash-segment') ||
      lowerPath.contains('dash_segment')) {
    final slash = uri.path.lastIndexOf('/');
    if (slash >= 0) {
      return uri
          .replace(path: '${uri.path.substring(0, slash + 1)}master.mpd')
          .toString();
    }
  }
  if (RegExp(
        r'\.(?:m4s|cmfv|cmfa)(?:$|[?#])',
        caseSensitive: false,
      ).hasMatch(uri.path) ||
      const <String>[
        '/segment/',
        '/segments/',
        '/chunk/',
        '/chunks/',
        '/fragment/',
        '/fragments/',
        'dash-segment',
        'dash_segment',
        'dash-init',
        'dash_init',
        'dash-chunk',
        'dash_chunk',
        '/init.mp4',
        '/init.m4s',
      ].any(uri.path.toLowerCase().contains)) {
    return null;
  }
  final query = Map<String, List<String>>.from(uri.queryParametersAll);
  var changed = false;
  for (final key in const <String>[
    'range',
    'sq',
    'rn',
    'rbuf',
    'bytestart',
    'byteend',
  ]) {
    changed = query.remove(key) != null || changed;
  }
  if (!changed) return null;
  return uri.replace(queryParameters: query.isEmpty ? null : query).toString();
}

List<String> normalizeMediaCandidateUrls(
  Iterable<String> urls, {
  required bool video,
  int maxCandidates = 4,
}) {
  final output = <String>[];
  final seen = <String>{};
  for (final raw in urls) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    var candidate = value;
    if (video && isMediaFragmentUrl(candidate)) {
      final recovered = recoverWholeMediaUrlFromFragment(candidate);
      if (recovered == null) continue;
      candidate = recovered;
    }
    if (seen.add(candidate)) output.add(candidate);
    if (output.length >= maxCandidates) break;
  }
  return output;
}

/// Stable Facebook CDN / reel identity used to bind long-press to the
/// currently playing item instead of a prefetched neighbor.
///
/// Examples:
/// - `.../v/t42.1790-2/123_456_789_n.mp4?...` → `123_456_789_n`
/// - `https://www.facebook.com/reel/1234567890/` → `reel:1234567890`
String facebookMediaIdentity(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';
  final metadata = facebookMediaMetadata(trimmed);
  if (metadata != null && metadata.videoId.isNotEmpty) {
    return 'fbvideo:${metadata.videoId.toLowerCase()}';
  }
  final lower = trimmed.toLowerCase();
  final reelMatch = RegExp(
    r'(?:facebook\.com|fb\.watch)/(?:reel|reels|videos?)/(\d{6,})',
    caseSensitive: false,
  ).firstMatch(lower);
  if (reelMatch != null) return 'reel:${reelMatch.group(1)}';
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return '';
  final path = uri.path;
  final fileMatch = RegExp(
    r'/(\d+(?:_\d+){1,6}_[a-z0-9]+)\.(?:mp4|webm|mov)(?:$|/)',
    caseSensitive: false,
  ).firstMatch(path);
  if (fileMatch != null) return fileMatch.group(1)!.toLowerCase();
  final stemMatch = RegExp(
    r'/(\d{6,}(?:_\d+)*)\.(?:mp4|webm|mov)(?:$|/)',
    caseSensitive: false,
  ).firstMatch(path);
  if (stemMatch != null) return stemMatch.group(1)!.toLowerCase();
  // Newer FBCDN paths often use opaque stems; keep the final path segment.
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  final segment = segments.isEmpty ? '' : segments.last;
  final opaque = RegExp(
    r'^([A-Za-z0-9_-]{12,})\.(?:mp4|webm|mov)$',
    caseSensitive: false,
  ).firstMatch(segment);
  if (opaque != null) return opaque.group(1)!.toLowerCase();
  return '';
}

bool facebookIdentitiesMatch(String left, String right) {
  final a = left.trim().toLowerCase();
  final b = right.trim().toLowerCase();
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  // fbvideo:123 ↔ 123 (exact numeric id only)
  if (a.startsWith('fbvideo:') && !b.startsWith('fbvideo:')) {
    if (a.substring('fbvideo:'.length) == b) return true;
  }
  if (b.startsWith('fbvideo:') && !a.startsWith('fbvideo:')) {
    if (b.substring('fbvideo:'.length) == a) return true;
  }
  // Facebook Reels often reuse the same numeric id for reel URL and efg.video_id.
  // Logs: softReel=reel:157927… + post-prime fbvideo:157927… (same digits).
  String reelBare(String v) =>
      v.startsWith('reel:') ? v.substring('reel:'.length) : '';
  String fbBare(String v) =>
      v.startsWith('fbvideo:') ? v.substring('fbvideo:'.length) : '';
  final ra = reelBare(a);
  final rb = reelBare(b);
  final fa = fbBare(a);
  final fb = fbBare(b);
  if (ra.isNotEmpty && fb.isNotEmpty && ra == fb) return true;
  if (rb.isNotEmpty && fa.isNotEmpty && rb == fa) return true;
  // Other reel: forms never fuzzy-match CDN stems.
  if (a.startsWith('reel:') || b.startsWith('reel:')) return false;
  // Same numeric core with different quality suffix (_n / _hd / …) only.
  String core(String value) {
    var v = value;
    if (v.startsWith('fbvideo:')) v = v.substring('fbvideo:'.length);
    final stripped = v.replaceFirst(RegExp(r'_[a-z]\d*$'), '');
    return stripped.replaceFirst(RegExp(r'_[a-z]+$'), '');
  }

  final ca = core(a);
  final cb = core(b);
  // Require substantial shared core — never substring/contains (false dups).
  if (ca.length >= 10 && ca == cb) return true;
  return false;
}

bool isFacebookReelsPageUrl(String? url) {
  final lower = (url ?? '').trim().toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('/reel/') ||
      lower.contains('/reels/') ||
      lower.contains('/reels?') ||
      RegExp(r'/reels(?:$|[?#])').hasMatch(lower);
}
