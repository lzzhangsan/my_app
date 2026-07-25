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
