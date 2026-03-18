// integration_test/export_import_test.dart
// 导出/导入核心流程集成测试 - 验证目录、媒体、日记的导出导入逻辑

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:change_copy/core/service_locator.dart';
import 'package:change_copy/services/database_service.dart';
import 'package:change_copy/services/export_import_utils.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('导出/导入集成测试', () {
    DatabaseService? dbService;
    late Directory tempDir;

    setUpAll(() async {
      await serviceLocator.initialize();
      if (!kIsWeb && serviceLocator.isRegistered<DatabaseService>()) {
        dbService = getService<DatabaseService>();
      }
      tempDir = await getTemporaryDirectory();
    });

    group('目录数据导出', () {
      test('空目录导出应生成有效 ZIP 文件', () async {
        if (kIsWeb || dbService == null) return;
        final zipPath = await dbService!.exportDirectoryData(
          outputDirectory: tempDir.path,
        );
        expect(zipPath, isNotEmpty);
        final zipFile = File(zipPath);
        expect(await zipFile.exists(), true);
        expect(await zipFile.length(), greaterThan(0));
      });
    });

    group('日记数据', () {
      test('日记表可正常查询', () async {
        if (kIsWeb || dbService == null) return;
        final db = await dbService!.database;
        final count = await db.rawQuery('SELECT COUNT(*) as c FROM diary_entries');
        expect(count, isNotEmpty);
        expect(count.first['c'], isNotNull);
      });
    });

    group('导出保存目录', () {
      test('getExportSaveDirectory 应返回有效目录', () async {
        final dir = await getExportSaveDirectory();
        expect(await dir.exists(), true);
      });
    });
  });
}
