bool isMediaFragmentUrl(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.isEmpty) return false;
  if (RegExp(r'\.(?:m4s|cmfv|cmfa)(\?|#|$)').hasMatch(lower)) return true;
  const fragmentHints = <String>[
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
        'dash-chunk',
        'dash_chunk',
        '/init.mp4',
        '/init.m4s',
      ].any(uri.path.toLowerCase().contains)) {
    return null;
  }
  final query = Map<String, List<String>>.from(uri.queryParametersAll);
  var changed = false;
  for (final key in const <String>['range', 'sq', 'rn', 'rbuf']) {
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
