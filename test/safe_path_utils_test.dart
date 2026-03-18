// test/safe_path_utils_test.dart
// 安全路径工具单元测试 - 防止 Zip Slip 路径遍历

import 'package:flutter_test/flutter_test.dart';
import 'package:change_copy/utils/safe_path_utils.dart';

void main() {
  group('resolveSafeExtractPath', () {
    test('正常路径应返回正确解析路径', () {
      final base = '/tmp/extract';
      expect(
        resolveSafeExtractPath(base, 'file.txt'),
        endsWith('file.txt'),
      );
      expect(
        resolveSafeExtractPath(base, 'subdir/file.txt'),
        endsWith('file.txt'),
      );
    });

    test('Zip Slip 攻击 - 路径穿越应抛出 ArgumentError', () {
      expect(
        () => resolveSafeExtractPath('/tmp/extract', '../etc/passwd'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => resolveSafeExtractPath('/tmp/extract', '..\\windows\\system32'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => resolveSafeExtractPath('C:\\temp\\extract', '..\\..\\sensitive'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('正常子目录路径应通过', () {
      final result = resolveSafeExtractPath('/tmp/extract', 'directory/sub/file.json');
      expect(result, contains('directory'));
      expect(result, contains('sub'));
      expect(result, contains('file.json'));
    });

    test('空条目名应返回 baseDir 下的路径', () {
      final result = resolveSafeExtractPath('/tmp/extract', '');
      expect(result, isNotEmpty);
    });
  });
}
