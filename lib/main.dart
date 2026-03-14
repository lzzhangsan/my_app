import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'document_editor_page.dart';
import 'directory_page.dart';
import 'cover_page.dart';
import 'media_manager_page.dart';
import 'browser_page.dart';
import 'core/app_state.dart';
import 'core/service_locator.dart';
import 'services/background_media_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'diary_page.dart';
import 'services/error_service.dart';
import 'services/logger.dart';

// 添加全局 navigatorKey
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 捕获未处理的异步异常，防止静默崩溃
  runZonedGuarded(() async {
    try {
      await serviceLocator.initialize();
      Logger.i('服务架构初始化成功');

      final backgroundService = getService<BackgroundMediaService>();
      if (backgroundService.isInitialized) {
        Logger.i('后台媒体服务已启动');
      }
    } catch (e) {
      Logger.e('服务架构初始化失败', e);
    }

    runApp(const MyApp());
  }, (error, stack) {
    Logger.e('未捕获的异步异常', error, stack);
    if (kDebugMode) {
      debugPrint('runZonedGuarded 捕获: $error\n$stack');
    }
    try {
      final errorService = getService<ErrorService>();
      errorService.recordError(error, stack, context: 'runZonedGuarded', severity: ErrorSeverity.critical);
    } catch (recordErr, recordStack) {
      if (kDebugMode) {
        debugPrint('记录错误时失败: $recordErr\n$recordStack');
      }
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '变化',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  static const String routeName = '/main';

  const MainScreen({super.key});

  @override
  MainScreenState createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final PageController _pageController = PageController(initialPage: 0);
  int _currentPage = 0;
  bool _isBrowserHomePage = true;
  bool _isMediaMultiSelectMode = false;

  void _handleBrowserHomePageChanged(bool isHomePage) {
    if (_isBrowserHomePage != isHomePage) {
      setState(() {
        _isBrowserHomePage = isHomePage;
        Logger.d('[_MainScreenState] _isBrowserHomePage updated to: $_isBrowserHomePage');
      });
    } else {
       Logger.d('[_MainScreenState] _isBrowserHomePage state is already $isHomePage');
    }
  }

  void goToPage(int index) {
     _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshCurrentPage();
    }
  }

  void _refreshCurrentPage() {
    // 应用从后台恢复时可在此添加页面刷新逻辑
  }

  void _onDocumentOpen(String documentName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DocumentEditorPage(
          documentName: documentName,
          onSave: (updatedTextBoxes) {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Logger.d('[_MainScreenState.build] _currentPage: $_currentPage, _isBrowserHomePage: $_isBrowserHomePage, Calculated PageView Physics: ${_currentPage == 3 ? (_isBrowserHomePage ? 'ClampingScrollPhysics' : 'NeverScrollableScrollPhysics') : 'ClampingScrollPhysics'}');

    return Scaffold(
      // 使用 KeyboardListener 替换已弃用的 RawKeyboardListener
      body: KeyboardListener(
        focusNode: FocusNode(),
        autofocus: true,
        onKeyEvent: (KeyEvent event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _currentPage > 0) {
              _pageController.previousPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight && _currentPage < 4) {
              _pageController.nextPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          }
        },
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  Logger.d('[_MainScreenState] PointerScrollEvent dx: ${pointerSignal.scrollDelta.dx}, current page: $_currentPage, isBrowserHomePage: $_isBrowserHomePage');

                  if (!(_currentPage == 3 && !_isBrowserHomePage)) {
                    if (pointerSignal.scrollDelta.dx > 0 && _currentPage < 3) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    } else if (pointerSignal.scrollDelta.dx < 0 && _currentPage > 0) {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    }
                  }
                }
              },
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                    Logger.d('[_MainScreenState] Page changed to: $index');
                  });
                },
                physics: _currentPage == 2 && _isMediaMultiSelectMode
                    ? const NeverScrollableScrollPhysics()
                    : _currentPage == 3
                        ? (_isBrowserHomePage
                            ? const ClampingScrollPhysics()
                            : const NeverScrollableScrollPhysics())
                        : const ClampingScrollPhysics(),
                children: [
                  const CoverPage(),
                  DirectoryPage(onDocumentOpen: _onDocumentOpen),
                  MediaManagerPage(
                    onMultiSelectModeChanged: (v) {
                      if (_isMediaMultiSelectMode != v) {
                        setState(() => _isMediaMultiSelectMode = v);
                      }
                    },
                  ),
                  BrowserPage(
                    onBrowserHomePageChanged: _handleBrowserHomePageChanged,
                    currentMainPageIndex: _currentPage,
                  ),
                  const DiaryPage(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}