import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Media source id for the live BrowserPage WebView session (not a DB folder).
const String kMediaSourceBrowserLive = 'browser_live';

typedef BrowserLiveWebViewBuilder = Widget Function();

/// Bridge so DocumentEditor / MediaPlayerContainer can host the keep-alive
/// BrowserPage [InAppWebView] (GlobalKey reparent / loan) and read download tasks.
class BrowserSessionPreview {
  BrowserSessionPreview._();
  static final BrowserSessionPreview instance = BrowserSessionPreview._();

  static final ValueNotifier<List<Map<String, dynamic>>> _emptyTasks =
      ValueNotifier<List<Map<String, dynamic>>>(const []);

  Object? _owner;
  InAppWebViewController? _controller;
  ValueNotifier<List<Map<String, dynamic>>>? _downloadTasksNotifier;
  String? _pageUrl;
  bool _isBrowsingWebPage = false;
  bool _showHomePage = true;
  BrowserLiveWebViewBuilder? _webViewBuilder;

  /// Stable key for the session [InAppWebView] so it can move between parents.
  final GlobalKey webViewKey = GlobalKey(
    debugLabel: 'browserSessionInAppWebView',
  );

  /// True when the real WebView is hosted in the document bottom player panel.
  final ValueNotifier<bool> loanedNotifier = ValueNotifier<bool>(false);

  /// Fired when [isAvailable] may have changed.
  final ValueNotifier<bool> availabilityNotifier = ValueNotifier<bool>(false);

  /// Current page URL for the live preview chrome (listenable, cheap).
  final ValueNotifier<String?> pageUrlNotifier = ValueNotifier<String?>(null);

  bool get isLoaned => loanedNotifier.value;

  bool get isRegistered => _owner != null && _controller != null;

  /// True when BrowserPage has an active browsed page (WebView under the stack).
  /// Homepage overlay does not clear availability while the WebView session remains.
  bool get isAvailable => _controller != null && _isBrowsingWebPage;

  /// Whether BrowserPage is currently showing its home overlay (WebView may still be alive).
  bool get isHomeOverlayVisible => _showHomePage;

  String? get pageUrl => _pageUrl;

  ValueListenable<List<Map<String, dynamic>>> get downloadTasks =>
      _downloadTasksNotifier ?? _emptyTasks;

  void attachWebViewBuilder(BrowserLiveWebViewBuilder builder) {
    _webViewBuilder = builder;
  }

  void detachWebViewBuilder([BrowserLiveWebViewBuilder? builder]) {
    if (builder != null && !identical(_webViewBuilder, builder)) return;
    _webViewBuilder = null;
  }

  /// Build the live session WebView for whichever parent currently hosts it.
  /// Exactly one place in the tree may call this per frame.
  Widget? buildLoanedWebView() {
    final builder = _webViewBuilder;
    if (builder == null) return null;
    return builder();
  }

  /// Loan the WebView to the document panel (`true`) or return it to BrowserPage.
  void setLoaned(bool loaned) {
    if (loanedNotifier.value == loaned) return;
    loanedNotifier.value = loaned;
  }

  void register({
    required Object owner,
    required InAppWebViewController controller,
    required ValueNotifier<List<Map<String, dynamic>>> downloadTasks,
    String? pageUrl,
    bool isBrowsingWebPage = false,
    bool showHomePage = true,
  }) {
    _owner = owner;
    _controller = controller;
    _downloadTasksNotifier = downloadTasks;
    _pageUrl = pageUrl;
    _isBrowsingWebPage = isBrowsingWebPage;
    _showHomePage = showHomePage;
    _syncPageUrlNotifier();
    _notifyAvailability();
  }

  void updateSession({
    Object? owner,
    InAppWebViewController? controller,
    String? pageUrl,
    bool? isBrowsingWebPage,
    bool? showHomePage,
  }) {
    if (_owner == null) return;
    if (owner != null && !identical(owner, _owner)) return;
    if (controller != null) _controller = controller;
    if (pageUrl != null) _pageUrl = pageUrl;
    if (isBrowsingWebPage != null) _isBrowsingWebPage = isBrowsingWebPage;
    if (showHomePage != null) _showHomePage = showHomePage;
    _syncPageUrlNotifier();
    _notifyAvailability();
  }

  /// Re-bind current session before pushing Directory / Document routes.
  void bindForDirectoryEntry({
    required Object owner,
    InAppWebViewController? controller,
    required ValueNotifier<List<Map<String, dynamic>>> downloadTasks,
    String? pageUrl,
    required bool isBrowsingWebPage,
    required bool showHomePage,
  }) {
    if (controller == null) return;
    register(
      owner: owner,
      controller: controller,
      downloadTasks: downloadTasks,
      pageUrl: pageUrl,
      isBrowsingWebPage: isBrowsingWebPage,
      showHomePage: showHomePage,
    );
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    setLoaned(false);
    _owner = null;
    _controller = null;
    _downloadTasksNotifier = null;
    _pageUrl = null;
    _isBrowsingWebPage = false;
    _showHomePage = true;
    _syncPageUrlNotifier();
    _notifyAvailability();
  }

  void _syncPageUrlNotifier() {
    if (pageUrlNotifier.value != _pageUrl) {
      pageUrlNotifier.value = _pageUrl;
    }
  }

  void _notifyAvailability() {
    final next = isAvailable;
    if (availabilityNotifier.value != next) {
      availabilityNotifier.value = next;
    }
  }
}
