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

// 添加全局导航键，以便可以在应用的任何地方访问Navigator
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // 确保Flutter绑定初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化服务架构
  try {
    await serviceLocator.initialize();
    print('服务架构初始化成功');
    
    // 启动后台媒体服务
    final backgroundService = getService<BackgroundMediaService>();
    if (backgroundService.isInitialized) {
      print('后台媒体服务已启动');
    }
  } catch (e) {
    print('服务架构初始化失败: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  static const String _title = 'Change';

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
      navigatorKey: navigatorKey, // 添加导航键
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
  final PageController _pageController = PageController(initialPage: 0); // 设置初始页为封面页
  int _currentPage = 0; // 设置初始页索引为0（封面页）
  
  // Track if BrowserPage is showing its home page
  bool _isBrowserHomePage = true;

  // Callback method to update _isBrowserHomePage and trigger rebuild
  void _handleBrowserHomePageChanged(bool isHomePage) {
    if (_isBrowserHomePage != isHomePage) {
      setState(() {
        _isBrowserHomePage = isHomePage;
        debugPrint('[_MainScreenState] _isBrowserHomePage updated to: $_isBrowserHomePage');
      });
    } else {
       debugPrint('[_MainScreenState] _isBrowserHomePage state is already $isHomePage');
    }
  }

  // Method for page switching
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
    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // 移除生命周期观察者
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 当应用从后台恢复时，刷新当前页面
      _refreshCurrentPage();
    }
  }

  // 刷新当前页面的方法
  void _refreshCurrentPage() {
    if (_currentPage == 1) {
      // 如果当前是目录页面，调用 DirectoryPage 的刷新方法（需确保 DirectoryPage 有此方法）
      DirectoryPage.refresh();
    } else if (_currentPage == 2) {
      // 如果当前是媒体管理页面，添加刷新逻辑
      // 假设 MediaManagerPage 有一个静态刷新方法（需在 MediaManagerPage 中实现）
      // MediaManagerPage.refresh(); // 未实现，需根据实际情况添加
    }
  }

  // 获取页面名称
  String _getPageName(int pageIndex) {
    switch (pageIndex) {
      case 0:
        return '封面页';
      case 1:
        return '目录页';
      case 2:
        return '媒体管理';
      case 3:
        return '浏览器';
      case 4:
        return '日记本';
      default:
        return '未知页面';
    }
  }

  void _onDocumentOpen(String documentName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DocumentEditorPage(
          documentName: documentName,
          onSave: (updatedTextBoxes) {
            // 不需要额外处理，因为自动保存
          },
        ),
      ),
    ).then((_) {
      // 从文档编辑器返回后刷新目录页面
      DirectoryPage.refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[_MainScreenState.build] _currentPage: $_currentPage, _isBrowserHomePage: $_isBrowserHomePage, Calculated PageView Physics: ${_currentPage == 3 ? (_isBrowserHomePage ? 'ClampingScrollPhysics' : 'NeverScrollableScrollPhysics') : 'ClampingScrollPhysics'}');

    return Scaffold(
      // 移除这里的key，因为GlobalKey应该应用于StatefulWidget（MainScreen），而不是Scaffold
      body: RawKeyboardListener(
        focusNode: FocusNode(),
        autofocus: true,
        onKey: (RawKeyEvent event) {
          // Handle keyboard navigation (left/right arrow keys)
          if (event is RawKeyDownEvent) {
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
            // Use PageView for page swiping
            Listener(
              // This listener handles mouse wheel scrolling horizontally
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  // Only handle horizontal mouse wheel events if it's not the BrowserPage web view
                  // The condition means: if current page is 3 (BrowserPage) AND it's NOT the home page (!isBrowserHomePage), then DO NOT handle the event.
                  // Otherwise (current page is not 3 OR it is BrowserPage home page), handle the event.
                   debugPrint('[_MainScreenState] PointerScrollEvent dx: ${pointerSignal.scrollDelta.dx}, current page: $_currentPage, isBrowserHomePage: $_isBrowserHomePage');

                  if (!(_currentPage == 3 && !_isBrowserHomePage)) {
                    // Handle mouse wheel events for page switching
                    if (pointerSignal.scrollDelta.dx > 0 && _currentPage < 3) {
                      // Swipe right
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    } else if (pointerSignal.scrollDelta.dx < 0 && _currentPage > 0) {
                      // Swipe left
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
                    debugPrint('[_MainScreenState] Page changed to: $index');
                  });
                  // When switching to Directory page, refresh it
                  if (index == 1) {
                    DirectoryPage.refresh();
                  }
                  // When switching to BrowserPage (index 3), its build method will update _isBrowserHomePage via callback
                },
                // Dynamically set physics based on current page and BrowserPage's internal state
                // ClampingScrollPhysics allows horizontal swipe
                // NeverScrollableScrollPhysics disables all scrolling
                physics: _currentPage == 3
                    ? (_isBrowserHomePage
                        ? const ClampingScrollPhysics() // BrowserPage home allows horizontal swipe to MediaManager
                        : const NeverScrollableScrollPhysics()) // BrowserPage web view disables all horizontal swipe
                    : const ClampingScrollPhysics(), // Other pages allow normal horizontal swipe
                children: [
                  const CoverPage(),
                  DirectoryPage(onDocumentOpen: _onDocumentOpen),
                  const MediaManagerPage(),
                  BrowserPage(onBrowserHomePageChanged: _handleBrowserHomePageChanged), // Pass the callback
                  const DiaryPage(),
                ],
              ),
            ),

          // Add simple page indicator (commented out)
          /*
          Padding(
            padding: const EdgeInsets.only(bottom: 20.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (index) {
                  return GestureDetector(
                    onTap: () {
                      _pageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      );
                    },
                    child: Container(
                      width: 4.0,
                      height: 4.0,
                      margin: const EdgeInsets.symmetric(horizontal: 4.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _currentPage == index
                            ? Colors.white
                            : Colors.white.withOpacity(0.5),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          */
         ],
        ),
      ),
    );
  }
}