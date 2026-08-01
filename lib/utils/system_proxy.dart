import 'dart:io';

/// 读取当前进程可用的 HTTP(S) 代理（环境变量）。
String? resolveSystemHttpProxyUrl() {
  for (final key in ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy']) {
    final parsed = normalizeProxyUrl(Platform.environment[key]);
    if (parsed != null) return parsed;
  }
  return null;
}

String? normalizeProxyUrl(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  return 'http://$trimmed';
}
