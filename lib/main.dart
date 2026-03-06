import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'document_editor_page.dart';
import 'directory_page.dart';
import 'cover_page.dart';
import 'media_manager_page.dart';
import 'browser_page.dart';
import 'core/service_locator.dart';
import 'services/background_media_service.dart';
import 'package:flutter/services.dart';
import 'diary_page.dart';
import 'services/logger.dart';

// 添加全局 navigatorKey
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
    if (_currentPage == 1) {
      DirectoryPage.refresh();
    } else if (_currentPage == 2) {
      // MediaManagerPage.refresh();
    }
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
    ).then((_) {
      DirectoryPage.refresh();
    });
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
                  if (index == 1) {
                    DirectoryPage.refresh();
                  }
                },
                physics: _currentPage == 3
                    ? (_isBrowserHomePage
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics())
                    : const ClampingScrollPhysics(),
                children: [
                  const CoverPage(),
                  DirectoryPage(onDocumentOpen: _onDocumentOpen),
                  const MediaManagerPage(),
                  BrowserPage(onBrowserHomePageChanged: _handleBrowserHomePageChanged),
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