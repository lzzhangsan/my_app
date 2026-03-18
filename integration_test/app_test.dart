// integration_test/app_test.dart
// 应用启动与基础导航集成测试

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:change_copy/main.dart';
import 'package:change_copy/core/service_locator.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('应用启动测试', () {
    testWidgets('应用能够成功加载并显示主界面', (WidgetTester tester) async {
      await serviceLocator.initialize();
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.byType(MyApp), findsOneWidget);
    });

    testWidgets('封面页加载后显示设置按钮或提示文字', (WidgetTester tester) async {
      await serviceLocator.initialize();
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final settingsIcon = find.byIcon(Icons.settings);
      final hintText = find.textContaining('设置');
      expect(settingsIcon.evaluate().isNotEmpty || hintText.evaluate().isNotEmpty, true);
    });
  });
}
