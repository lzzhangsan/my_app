  String _smartStablePageKey(String pageUrl) {
    if (!_is91ContentPage(pageUrl)) return '';
    final uri = Uri.tryParse(pageUrl.trim());
    if (uri == null) return '';
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    return '$host/archives/${segments[1]}';
  }
