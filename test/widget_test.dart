import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/main.dart';

void main() {
  testWidgets('MainScreen displays CoverPage', (WidgetTester tester) async {
    // Build the app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that CoverPage is displayed (assuming it contains some text).
    expect(find.text('Cover Page'), findsOneWidget); // 替换为CoverPage中的实际文本

    // Optionally, test page switching to DirectoryPage.
    await tester.pumpAndSettle(); // 等待页面切换动画
    expect(find.text('Directory Page'), findsOneWidget); // 替换为DirectoryPage中的实际文本
  });
}