import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/main.dart';
import 'package:change_copy/core/service_locator.dart';

void main() {
  testWidgets('MainScreen 应用可加载', (WidgetTester tester) async {
    await serviceLocator.initialize();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.byType(MyApp), findsOneWidget);
  });

  testWidgets('主界面包含封面页或加载指示器', (WidgetTester tester) async {
    await serviceLocator.initialize();
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    final progressIndicator = find.byType(CircularProgressIndicator);
    final settingsIcon = find.byIcon(Icons.settings);
    final hintText = find.textContaining('设置');
    expect(
      progressIndicator.evaluate().isNotEmpty ||
          settingsIcon.evaluate().isNotEmpty ||
          hintText.evaluate().isNotEmpty,
      true,
    );
  });
}