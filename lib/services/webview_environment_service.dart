import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/system_proxy.dart';

/// Windows WebView2 环境（需在首个 [InAppWebView] 创建前初始化）。
class WebViewEnvironmentService {
  WebViewEnvironmentService._();

  static WebViewEnvironment? _environment;
  static String? _proxyUrl;

  static WebViewEnvironment? get environment => _environment;
  static String? get proxyUrl => _proxyUrl;

  static Future<void> initialize() async {
    if (_environment != null) return;
    if (kIsWeb || !Platform.isWindows) return;

    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    if (availableVersion == null) {
      debugPrint('WebView2 运行时不可用，跳过 WebView 环境初始化');
      return;
    }

    _proxyUrl = resolveSystemHttpProxyUrl();
    final browserArgs = <String>[
      // 部分代理 / 网络环境下 QUIC 会被中途 reset，表现为 ERR_CONNECTION_CLOSED。
      '--disable-quic',
    ];
    if (_proxyUrl != null) {
      browserArgs.add('--proxy-server=$_proxyUrl');
      debugPrint('WebView2 将使用代理: $_proxyUrl');
    } else {
      debugPrint('WebView2 未检测到 HTTP_PROXY/HTTPS_PROXY，使用系统代理设置');
    }

    final supportDir = await getApplicationSupportDirectory();
    _environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: p.join(supportDir.path, 'webview2_profile'),
        additionalBrowserArguments: browserArgs.join(' '),
      ),
    );
    debugPrint('WebView2 环境已创建 (runtime $availableVersion)');
  }
}
