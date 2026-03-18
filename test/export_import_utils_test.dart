// test/export_import_utils_test.dart
// 导出/导入工具单元测试

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/services/export_import_utils.dart';

void main() {
  group('copyFileWithStreaming', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('export_import_test_');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('小文件应正确复制', () async {
      final sourceFile = File('${tempDir.path}/source_small.txt');
      await sourceFile.writeAsString('Hello, export import test!');
      final targetPath = '${tempDir.path}/target_small.txt';

      final bytes = await copyFileWithStreaming(sourceFile, targetPath);
      expect(bytes, sourceFile.lengthSync());

      final targetFile = File(targetPath);
      expect(await targetFile.exists(), true);
      expect(await targetFile.readAsString(), 'Hello, export import test!');
    });

    test('不存在的源文件应返回 0', () async {
      final sourceFile = File('${tempDir.path}/nonexistent.txt');
      final targetPath = '${tempDir.path}/target.txt';

      final bytes = await copyFileWithStreaming(sourceFile, targetPath);
      expect(bytes, 0);
    });

    test('大文件应使用流式复制', () async {
      final sourceFile = File('${tempDir.path}/source_large.bin');
      const size = 3 * 1024 * 1024; // 3MB，超过 2MB 阈值
      final data = List<int>.generate(size, (i) => i % 256);
      await sourceFile.writeAsBytes(data);

      final targetPath = '${tempDir.path}/target_large.bin';
      final bytes = await copyFileWithStreaming(sourceFile, targetPath);

      expect(bytes, size);
      final targetFile = File(targetPath);
      expect(await targetFile.exists(), true);
      expect(await targetFile.length(), size);
    });
  });

  group('常量校验', () {
    test('kStreamingThresholdBytes 应为 2MB', () {
      expect(kStreamingThresholdBytes, 2 * 1024 * 1024);
    });

    test('kExportChunkSize 应为 5000', () {
      expect(kExportChunkSize, 5000);
    });

    test('kShareSizeLimitBytes 应为 500MB', () {
      expect(kShareSizeLimitBytes, 500 * 1024 * 1024);
    });
  });
}
