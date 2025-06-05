import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'document_editor_page.dart';
import 'directory_page.dart';
import 'cover_page.dart';
import 'media_manager_page.dart';
import 'browser_page.dart';
import 'core/service_locator.dart';
import 'package:flutter/services.dart';

// 添加全局导航键，以便可以在应用的任何地方访问Navigator
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // 确保Flutter绑定初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化服务架构
  try {
    await serviceLocator.initialize();
    print('服务架构初始化成功');
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
        appBarTheme: AppBarTheme(
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
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  final PageController _pageController = PageController(initialPage: 1); // 设置初始页为目录页
  int _currentPage = 1; // 设置初始页索引为1（目录页）

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
    return Scaffold(
      body: RawKeyboardListener(
        focusNode: FocusNode(),
        autofocus: true,
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft && _currentPage > 0) {
              _pageController.previousPage(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight && _currentPage < 3) {
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
            // 使用PageView实现页面滑动
            Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  // 处理鼠标滚轮事件进行页面切换
                  if (pointerSignal.scrollDelta.dx > 0 && _currentPage < 3) {
                    // 向右滑动
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  } else if (pointerSignal.scrollDelta.dx < 0 && _currentPage > 0) {
                    // 向左滑动
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                }
              },
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                  });
                  // 当页面切换到目录页面时，刷新它
                  if (index == 1) {
                    DirectoryPage.refresh();
                  }
                  // 如果切换到媒体管理页面，可以触发刷新逻辑（如果需要）
                  if (index == 2) {
                    // 建议在 MediaManagerPage 中添加静态 refresh 方法
                    // MediaManagerPage.refresh(); // 未实现，需根据实际情况添加
                  }
                },
                physics: const ClampingScrollPhysics(), // 确保滑动物理效果正常
                children: [
                  CoverPage(),
                  DirectoryPage(onDocumentOpen: _onDocumentOpen),
                  MediaManagerPage(),
                  BrowserPage(),
                ],
              ),
            ),

          // 添加简洁的页面指示器
          // 页面指示器 - 已注释掉，以备后用
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