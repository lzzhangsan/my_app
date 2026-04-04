import 'dart:io';

import 'package:change_copy/core/service_locator.dart';
import 'package:change_copy/services/database_service.dart';
import 'package:change_copy/services/export_import_utils.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('export/import integration smoke', () {
    DatabaseService? dbService;
    late Directory tempDir;

    setUpAll(() async {
      await serviceLocator.initialize();
      if (!kIsWeb && serviceLocator.isRegistered<DatabaseService>()) {
        dbService = getService<DatabaseService>();
      }
      tempDir = await getTemporaryDirectory();
    });

    testWidgets('directory export creates a readable zip', (_) async {
      if (kIsWeb || dbService == null) return;

      final zipPath = await dbService!.exportDirectoryData(
        outputDirectory: tempDir.path,
      );

      final zipFile = File(zipPath);
      expect(await zipFile.exists(), true);
      expect(await zipFile.length(), greaterThan(0));
    });

    testWidgets('getExportSaveDirectory returns an existing directory', (_) async {
      final dir = await getExportSaveDirectory();
      expect(await dir.exists(), true);
    });
  });
}
