// lib/services/test_data_generator_service.dart
// 测试数据生成服务 - 使用真实格式的图片/音频，便于验证导出导入及缩略图

import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'database_service.dart';
import '../core/service_locator.dart';

/// 测试数据规模：count = totalMB，每份 1MB，标注体积与实际生成一致
enum TestDataScale {
  // count(=份数=MB数), totalMB, label, isPeak
  small(20, 20, '小量', false),
  medium(500, 500, '中量', false),
  large(2000, 2000, '大量', false),
  extra(5000, 5000, '超量', false),
  peakDir10g(10240, 10240, '超大量', true),
  peakMedia15g(15360, 15360, '媒体峰值 15GB', true),
  peakDiary10g(10240, 10240, '日记峰值 10GB', true);

  const TestDataScale(
      this.count, this.totalMB, this.label, this.isPeakTarget);
  final int count;
  final int totalMB;
  final String label;
  final bool isPeakTarget;

  /// 目录：每文档 1MB（0.5MB 图 + 0.5MB 音），补偿 BMP 实际略小于目标使总量接近 totalMB
  int get dirImageBytes => 586 * 1024;   // 约 0.57MB，补偿后 20 份≈20MB
  int get dirAudioBytes => 586 * 1024;   // 约 0.57MB

  /// 媒体：每项 1MB，补偿 BMP 实际略小于目标，使 totalMB 更接近标注
  /// 经验值：小量 20 条实际约 17.2MB，对应每条约 0.86MB
  /// 调整后：targetBytes ≈ 1.33MB，使实际≈1MB/条
  int get mediaFileBytes => 1365 * 1024; // 约 1.33MB

  /// 日记：半数带图，每张 2MB，补偿 BMP 实际略小于目标使总量接近 totalMB
  /// 经验值：小量 20 篇实际约 17.2MB（10 张图），调整后使实际≈20MB
  int get diaryImageBytes => 2735 * 1024; // 约 2.67MB

  static List<TestDataScale> get directoryScales =>
      [small, medium, large, extra, peakDir10g];
  static List<TestDataScale> get mediaScales =>
      [small, medium, large, extra, peakMedia15g];
  static List<TestDataScale> get diaryScales =>
      [small, medium, large, extra, peakDiary10g];

  String _fmtMB(int mb) =>
      mb >= 1024 ? '约 ${(mb / 1024).toStringAsFixed(0)} GB' : '约$mb MB';

  /// 目录页公式文案
  String get formulaDir =>
      '$label（${_fmtMB(totalMB)}）=$count 份文档×1MB/份';

  /// 媒体页公式文案
  String get formulaMedia =>
      '$label（${_fmtMB(totalMB)}）=$count 条×1MB/条';

  /// 日记页公式文案（半数带图）
  String get formulaDiary =>
      '$label（${_fmtMB(totalMB)}）=$count 篇（半数带图×2MB）';
}

class TestDataGeneratorService {
  static final TestDataGeneratorService _instance =
      TestDataGeneratorService._internal();
  factory TestDataGeneratorService() => _instance;
  TestDataGeneratorService._internal();

  final _db = getService<DatabaseService>();
  final _uuid = const Uuid();

  /// 创建 BMP 图片（无压缩，文件大小精确可控，与标注一致）
  /// BMP 32位：54 字节头 + width*height*4
  Future<void> _createExactSizeBmp(
      String path, int targetSizeBytes, int seed) async {
    final dataBytes = (targetSizeBytes - 54).clamp(1024, 0x7fffffff);
    final pixels = (dataBytes ~/ 4).clamp(256, 1920 * 1080);
    final w = (pixels / 256).clamp(16, 1920).toInt();
    final h = (pixels / w).clamp(16, 1080).toInt();
    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = (seed + x * 7919 + y * 7829) & 0x7FFFFFFF;
        image.setPixelRgba(
            x, y, v % 256, (v ~/ 256) % 256, (v ~/ 65536) % 256, 255);
      }
    }
    final bmp = img.encodeBmp(image);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bmp);
  }

  /// 创建真实 WAV 音频（每段内容不同，hash 唯一）
  Future<void> _createRealAudioFile(
      String path, int targetSizeBytes, int seed) async {
    const sampleRate = 44100;
    const channels = 1;
    const bitsPerSample = 16;
    final dataSize =
        (targetSizeBytes - 44).clamp(0, 0x7fffffff); // WAV 头 44 字节
    final numSamples = dataSize ~/ 2;
    final buffer = ByteData(44 + numSamples * 2);
    int offset = 0;
    // RIFF header
    buffer.setUint8(offset++, 0x52);
    buffer.setUint8(offset++, 0x49);
    buffer.setUint8(offset++, 0x46);
    buffer.setUint8(offset++, 0x46);
    buffer.setUint32(offset, 36 + dataSize, Endian.little);
    offset += 4;
    buffer.setUint8(offset++, 0x57);
    buffer.setUint8(offset++, 0x41);
    buffer.setUint8(offset++, 0x56);
    buffer.setUint8(offset++, 0x45);
    buffer.setUint8(offset++, 0x66);
    buffer.setUint8(offset++, 0x6d);
    buffer.setUint8(offset++, 0x74);
    buffer.setUint8(offset++, 0x20);
    buffer.setUint32(offset, 16, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little);
    offset += 2;
    buffer.setUint16(offset, channels, Endian.little);
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    buffer.setUint32(offset, sampleRate * channels * 2, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 2, Endian.little);
    offset += 2;
    buffer.setUint16(offset, bitsPerSample, Endian.little);
    offset += 2;
    buffer.setUint8(offset++, 0x64);
    buffer.setUint8(offset++, 0x61);
    buffer.setUint8(offset++, 0x74);
    buffer.setUint8(offset++, 0x61);
    buffer.setUint32(offset, dataSize, Endian.little);
    offset += 4;
    for (var i = 0; i < numSamples; i++) {
      final v =
          ((seed + i) * 7919).abs() % 65536 - 32768;
      buffer.setInt16(offset, v, Endian.little);
      offset += 2;
    }
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(buffer.buffer.asUint8List());
  }

  /// 计算文件 MD5（流式处理，避免大文件 OOM）
  Future<String> _fileHash(File f) async {
    final digest = await md5.bind(f.openRead()).first;
    return digest.toString();
  }

  /// 生成目录测试数据（真实 PNG 图片 + 真实 WAV 音频）
  Future<Map<String, dynamic>> generateDirectoryTestData(
    TestDataScale scale, {
    ValueNotifier<String>? progress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, 'images'));
    final audiosDir = Directory(p.join(appDir.path, 'audios'));
    await imagesDir.create(recursive: true);
    await audiosDir.create(recursive: true);

    final count = scale.count;
    final imgBytes = scale.dirImageBytes;
    final audioBytes = scale.dirAudioBytes;
    int foldersCreated = 0, docsCreated = 0, textBoxesCreated = 0;
    int imageBoxesCreated = 0, audioBoxesCreated = 0;

    progress?.value = '正在创建测试文件夹...';
    final db = await _db.database;
    final rootFolderId = _uuid.v4();
    await db.insert('folders', {
      'id': rootFolderId,
      'parent_folder': null,
      'name': '测试文件夹_${DateTime.now().millisecondsSinceEpoch}',
      'order_index': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    foldersCreated++;

    for (int i = 0; i < count; i++) {
      if (i % 50 == 0) progress?.value = '正在创建文档: $i/$count';
      final docId = _uuid.v4();
      await db.insert('documents', {
        'id': docId,
        'parent_folder': rootFolderId,
        'name': '测试文档_$i',
        'order_index': i,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      docsCreated++;

      final textBoxId = _uuid.v4();
      final longText = '测试文本内容_' * 500;
      await db.insert('text_boxes', {
        'id': textBoxId,
        'document_id': docId,
        'position_x': 10.0,
        'position_y': 10.0,
        'width': 200.0,
        'height': 100.0,
        'content': longText,
        'font_size': 16,
        'font_color': 4278190080,
        'font_weight': 0,
        'is_italic': 0,
        'text_align': 0,
        'text_segments': '[]',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      textBoxesCreated++;

      final imgId = _uuid.v4();
      final imgPath = p.join(imagesDir.path, 'test_img_$i.bmp');
      await _createExactSizeBmp(imgPath, imgBytes, i);

      await db.insert('image_boxes', {
        'id': imgId,
        'document_id': docId,
        'position_x': 50.0,
        'position_y': 50.0,
        'width': 100.0,
        'height': 100.0,
        'image_path': imgPath,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      imageBoxesCreated++;

      final audioId = _uuid.v4();
      final audioPath = p.join(audiosDir.path, 'test_audio_$i.wav');
      await _createRealAudioFile(audioPath, audioBytes, i);

      await db.insert('audio_boxes', {
        'id': audioId,
        'document_id': docId,
        'position_x': 150.0,
        'position_y': 50.0,
        'audio_path': audioPath,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      audioBoxesCreated++;

      await db.insert('document_settings', {
        'document_id': docId,
        'background_image_path': null,
        'background_color': null,
        'text_enhance_mode': 0,
        'position_locked': 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    // 统计实际生成文件的真实大小（遍历磁盘文件，确保与导出/存储占用一致）
    progress?.value = '正在统计实际大小...';
    int actualBytes = 0;
    for (int i = 0; i < count; i++) {
      actualBytes += await File(p.join(imagesDir.path, 'test_img_$i.bmp')).length();
      actualBytes += await File(p.join(audiosDir.path, 'test_audio_$i.wav')).length();
    }

    progress?.value = '完成';
    return {
      'folders': foldersCreated,
      'documents': docsCreated,
      'textBoxes': textBoxesCreated,
      'imageBoxes': imageBoxesCreated,
      'audioBoxes': audioBoxesCreated,
      'actualSizeMB': (actualBytes / 1024 / 1024).toStringAsFixed(1),
    };
  }

  /// 生成媒体测试数据（仅真实图片，每张唯一 hash，可正常缩略图且不被查重删除）
  Future<Map<String, dynamic>> generateMediaTestData(
    TestDataScale scale, {
    ValueNotifier<String>? progress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory(p.join(appDir.path, 'media'));
    await mediaDir.create(recursive: true);

    final count = scale.count;
    final fileBytes = scale.mediaFileBytes;
    int created = 0;
    int actualBytes = 0;
    final db = await _db.database;

    for (int i = 0; i < count; i++) {
      if (i % 50 == 0) progress?.value = '正在创建媒体文件: $i/$count';
      final id = _uuid.v4();
      final path = p.join(mediaDir.path, 'test_media_$i.bmp');
      await _createExactSizeBmp(path, fileBytes, i);

      final f = File(path);
      final fileHash = await _fileHash(f);
      final fileSizeActual = await f.length();
      actualBytes += fileSizeActual;

      await db.insert('media_items', {
        'id': id,
        'name': 'test_media_$i.bmp',
        'path': path,
        'type': 0, // 仅图片，保证可生成缩略图
        'directory': 'root',
        'date_added': DateTime.now().toIso8601String(),
        'file_size': fileSizeActual,
        'duration': 0,
        'thumbnail_path': null,
        'file_hash': fileHash,
        'telegram_file_id': null,
        'is_favorite': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      created++;
    }

    progress?.value = '完成';
    return {
      'count': created,
      'actualSizeMB': (actualBytes / 1024 / 1024).toStringAsFixed(1),
    };
  }

  /// 生成日记测试数据（真实 PNG 图片，每张唯一）
  Future<Map<String, dynamic>> generateDiaryTestData(
    TestDataScale scale, {
    ValueNotifier<String>? progress,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final diaryMediaDir = Directory(p.join(appDir.path, 'diary_media'));
    await diaryMediaDir.create(recursive: true);

    final count = scale.count;
    final imgBytes = scale.diaryImageBytes;
    int created = 0;
    final db = await _db.database;

    for (int i = 0; i < count; i++) {
      if (i % 50 == 0) progress?.value = '正在创建日记: $i/$count';
      final id = _uuid.v4();
      final date = DateTime.now().subtract(Duration(days: i));
      final content = '测试日记内容_$i ' * 100;

      List<String> imagePaths = [];
      if (i % 2 == 0) {
        final imgPath =
            p.join(diaryMediaDir.path, 'test_diary_img_$i.bmp');
        await _createExactSizeBmp(imgPath, imgBytes, i);
        imagePaths.add(imgPath);
      }

      await db.insert('diary_entries', {
        'id': id,
        'date': date.toIso8601String(),
        'content': content,
        'image_paths': jsonEncode(imagePaths),
        'audio_paths': '[]',
        'video_paths': '[]',
        'weather': null,
        'mood': null,
        'location': null,
        'is_favorite': 0,
      });
      created++;
    }

    // 统计实际生成图片的真实大小
    progress?.value = '正在统计实际大小...';
    int actualBytes = 0;
    for (int i = 0; i < count; i += 2) {
      final fp = p.join(diaryMediaDir.path, 'test_diary_img_$i.bmp');
      if (await File(fp).exists()) {
        actualBytes += await File(fp).length();
      }
    }

    progress?.value = '完成';
    return {
      'count': created,
      'actualSizeMB': (actualBytes / 1024 / 1024).toStringAsFixed(1),
    };
  }
}
