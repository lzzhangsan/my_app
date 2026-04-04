import 'package:change_copy/utils/export_import_error_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatExportImportError', () {
    test('memory errors return a friendly message', () {
      final result = formatExportImportError(Exception('Out of memory'), '导出');
      expect(result, contains('内存'));
      expect(result, contains('导出'));
    });

    test('disk space errors return a friendly message', () {
      final result = formatExportImportError(Exception('No space left on device'), '导入');
      expect(result, contains('存储'));
      expect(result, contains('导入'));
    });

    test('permission errors return a friendly message', () {
      final result = formatExportImportError(Exception('Permission denied'), '导出');
      expect(result, contains('权限'));
    });

    test('format errors return a friendly message', () {
      final result = formatExportImportError(Exception('Invalid format'), '导入');
      expect(result, contains('格式'));
    });

    test('missing files return a friendly message', () {
      final result = formatExportImportError(Exception('File not found'), '导出');
      expect(result, contains('找不到'));
    });
  });

  group('formatFileSize', () {
    test('formats byte counts consistently', () {
      expect(formatFileSize(500), '500B');
      expect(formatFileSize(1024), '1.0KB');
      expect(formatFileSize(1536), '1.5KB');
      expect(formatFileSize(1024 * 1024), '1.0MB');
      expect(formatFileSize(1024 * 1024 * 1024), '1.0GB');
    });
  });
}
