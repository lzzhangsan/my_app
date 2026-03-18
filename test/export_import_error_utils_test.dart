// test/export_import_error_utils_test.dart
// 导出/导入错误格式化单元测试

import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/utils/export_import_error_utils.dart';

void main() {
  group('formatExportImportError', () {
    test('内存不足错误应返回友好提示', () {
      final result = formatExportImportError(Exception('Out of memory'), '导出');
      expect(result, contains('内存'));
      expect(result, contains('导出'));
    });

    test('存储空间不足应返回友好提示', () {
      final result = formatExportImportError(Exception('No space left on device'), '导入');
      expect(result, contains('存储'));
      expect(result, contains('导入'));
    });

    test('权限错误应返回友好提示', () {
      final result = formatExportImportError(Exception('Permission denied'), '导出');
      expect(result, contains('权限'));
    });

    test('格式错误应返回友好提示', () {
      final result = formatExportImportError(Exception('Invalid format'), '导入');
      expect(result, contains('格式'));
    });

    test('文件未找到应返回友好提示', () {
      final result = formatExportImportError(Exception('File not found'), '导出');
      expect(result, contains('找不到'));
    });
  });

  group('formatFileSize', () {
    test('字节格式化', () {
      expect(formatFileSize(500), '500B');
      expect(formatFileSize(1024), '1.0KB');
      expect(formatFileSize(1536), '1.5KB');
      expect(formatFileSize(1024 * 1024), '1.0MB');
      expect(formatFileSize(1024 * 1024 * 1024), '1.0GB');
    });
  });
}
