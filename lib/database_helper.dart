import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:io';
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:ui' show Offset;
import 'package:archive/archive_io.dart';

// 媒体类型枚举定义
enum MediaType {
  image,   // 图片
  video,   // 视频
  audio,   // 音频
  folder,  // 文件夹
}

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;

  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = p.join(documentsDirectory.path, 'directory_app.db');
    Database db = await openDatabase(
      path,
      version: 7,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE folders(
            name TEXT PRIMARY KEY,
            parentFolder TEXT,
            `order` INTEGER,
            position TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE documents(
            name TEXT PRIMARY KEY,
            parentFolder TEXT,
            `order` INTEGER,
            isTemplate INTEGER DEFAULT 0,
            position TEXT
          )
        ''');

        await db.execute('''
  CREATE TABLE text_boxes(
    id TEXT PRIMARY KEY,
    document_id TEXT,
    position_x REAL,
    position_y REAL,
    width REAL,
    height REAL,
    content TEXT,
    font_size REAL,
    font_color INTEGER,
    font_family TEXT,
    font_weight INTEGER,
    is_italic INTEGER,
    is_underlined INTEGER,
    is_strike_through INTEGER,
    background_color INTEGER,
    text_align INTEGER,
    created_at INTEGER,
    updated_at INTEGER
  )
''');

        await db.execute('''
          CREATE TABLE image_boxes(
            id TEXT PRIMARY KEY,
            documentName TEXT,
            positionX REAL,
            positionY REAL,
            width REAL,
            height REAL,
            imagePath TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE audio_boxes(
            id TEXT PRIMARY KEY,
            documentName TEXT,
            positionX REAL,
            positionY REAL,
            audioPath TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE document_settings(
            document_name TEXT PRIMARY KEY,
            background_image_path TEXT,
            background_color INTEGER,
            text_enhance_mode INTEGER DEFAULT 0
          )
        ''');

        await db.execute('''
          CREATE TABLE directory_settings(
            id INTEGER PRIMARY KEY CHECK (id = 1),
            background_image_path TEXT,
            background_color INTEGER,
            is_free_sort_mode INTEGER DEFAULT 1
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await db.execute('''
            ALTER TABLE directory_settings
            ADD COLUMN is_free_sort_mode INTEGER DEFAULT 1
          ''');
        }

        if (oldVersion < 4) {
          var folderInfo = await db.rawQuery('PRAGMA table_info(folders)');
          bool hasPositionColumn = folderInfo.any((column) => column['name'] == 'position');

          if (!hasPositionColumn) {
            await db.execute('ALTER TABLE folders ADD COLUMN position TEXT');
          }

          var documentInfo = await db.rawQuery('PRAGMA table_info(documents)');
          bool hasDocPositionColumn = documentInfo.any((column) => column['name'] == 'position');

          if (!hasDocPositionColumn) {
            await db.execute('ALTER TABLE documents ADD COLUMN position TEXT');
          }

          print('数据库已升级到版本4，添加了位置字段');
        }

        if (oldVersion < 5) {
          print('开始升级数据库到版本5，修复表结构...');
          await _fixDatabaseStructure(db);
          print('数据库已升级到版本5，修复了表结构');
        }

        if (oldVersion < 7) {
          print('开始升级数据库到版本7，添加音频框表...');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS audio_boxes(
              id TEXT PRIMARY KEY,
              documentName TEXT,
              positionX REAL,
              positionY REAL,
              audioPath TEXT
            )
          ''');
          print('数据库已升级到版本7，添加了音频框表');
        }
      },
    );
    return db;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
  CREATE TABLE text_boxes(
    id TEXT PRIMARY KEY,
    documentName TEXT,
    positionX REAL,
    positionY REAL,
    width REAL,
    height REAL,
    text TEXT,
    fontSize REAL,
    fontColor INTEGER,
    fontFamily TEXT,
    fontWeight INTEGER,
    isItalic INTEGER,
    isUnderlined INTEGER,
    isStrikeThrough INTEGER,
    backgroundColor INTEGER,
    textAlign INTEGER
  )
''');

      await db.execute("ALTER TABLE documents ADD COLUMN parentFolder TEXT");
      await db.execute("ALTER TABLE folders ADD COLUMN parentFolder TEXT");
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE image_boxes (
          id TEXT PRIMARY KEY,
          documentName TEXT,
          positionX REAL,
          positionY REAL,
          width REAL,
          height REAL,
          imagePath TEXT
        )
      ''');
    }
    if (oldVersion < 4) {
      await db.execute("ALTER TABLE folders ADD COLUMN `order` INTEGER");
      List<Map<String, dynamic>> existingFolders = await db.query('folders');
      for (int i = 0; i < existingFolders.length; i++) {
        await db.update(
          'folders',
          {'order': i},
          where: 'name = ?',
          whereArgs: [existingFolders[i]['name']],
        );
      }

      await db.execute("ALTER TABLE documents ADD COLUMN `order` INTEGER");
      List<Map<String, dynamic>> existingDocuments = await db.query('documents');
      for (int i = 0; i < existingDocuments.length; i++) {
        await db.update(
          'documents',
          {'order': i},
          where: 'name = ?',
          whereArgs: [existingDocuments[i]['name']],
        );
      }
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE directory_settings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          background_image_path TEXT,
          background_color INTEGER,
          is_free_sort_mode INTEGER DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE document_settings (
          document_name TEXT PRIMARY KEY,
          background_image_path TEXT,
          background_color INTEGER,
          text_enhance_mode INTEGER DEFAULT 0
        )
      ''');
    }
    if (oldVersion < 7) {
      await _checkAndCreateTables(db);
    }
    if (oldVersion < 8) {
      try {
        await db.rawQuery('SELECT is_free_sort_mode FROM directory_settings LIMIT 1');
      } catch (e) {
        await db.execute('ALTER TABLE directory_settings ADD COLUMN is_free_sort_mode INTEGER DEFAULT 0');
        print('已添加is_free_sort_mode列到directory_settings表');
      }
    }
  }

  Future<void> _createTables(Database db) async {
    List<String> tables = await _getExistingTables(db);

    if (!tables.contains('text_boxes')) {
      await db.execute('''
  CREATE TABLE text_boxes(
    id TEXT PRIMARY KEY,
    documentName TEXT,
    positionX REAL,
    positionY REAL,
    width REAL,
    height REAL,
    text TEXT,
    fontSize REAL,
    fontColor INTEGER,
    fontFamily TEXT,
    fontWeight INTEGER,
    isItalic INTEGER,
    isUnderlined INTEGER,
    isStrikeThrough INTEGER,
    backgroundColor INTEGER,
    textAlign INTEGER
  )
''');
    }

    if (!tables.contains('image_boxes')) {
      await db.execute('''
        CREATE TABLE image_boxes (
          id TEXT PRIMARY KEY,
          documentName TEXT,
          positionX REAL,
          positionY REAL,
          width REAL,
          height REAL,
          imagePath TEXT
        )
      ''');
    }

    if (!tables.contains('documents')) {
      await db.execute('''
        CREATE TABLE documents (
          name TEXT PRIMARY KEY,
          parentFolder TEXT,
          `order` INTEGER,
          isTemplate INTEGER DEFAULT 0
        )
      ''');
    } else {
      try {
        await db.rawQuery('SELECT isTemplate FROM documents LIMIT 1');
      } catch (e) {
        await db.execute('ALTER TABLE documents ADD COLUMN isTemplate INTEGER DEFAULT 0');
        print('已添加isTemplate列到documents表');
      }
    }

    if (!tables.contains('folders')) {
      await db.execute('''
        CREATE TABLE folders (
          name TEXT PRIMARY KEY,
          parentFolder TEXT,
          `order` INTEGER
        )
      ''');
    }

    if (!tables.contains('cover_image')) {
      await db.execute('''
        CREATE TABLE cover_image (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT
        )
      ''');
    }

    if (!tables.contains('directory_settings')) {
      await db.execute('''
        CREATE TABLE directory_settings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          background_image_path TEXT,
          background_color INTEGER,
          is_free_sort_mode INTEGER DEFAULT 0
        )
      ''');
    }

    if (!tables.contains('document_settings')) {
      await db.execute('''
        CREATE TABLE document_settings (
          document_name TEXT PRIMARY KEY,
          background_image_path TEXT,
          background_color INTEGER,
          text_enhance_mode INTEGER DEFAULT 0
        )
      ''');
    }

    if (!tables.contains('video_boxes')) {
      await db.execute('''
        CREATE TABLE video_boxes (
          id TEXT PRIMARY KEY,
          documentName TEXT,
          positionX REAL,
          positionY REAL,
          width REAL,
          height REAL,
          videoPath TEXT
        )
      ''');
    }

    if (!tables.contains('media_items')) {
      await db.execute('''
        CREATE TABLE media_items (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          type INTEGER NOT NULL,
          directory TEXT NOT NULL,
          date_added TEXT NOT NULL,
          file_hash TEXT
        )
      ''');
      print('在_createTables中创建了media_items表');
    }
  }

  Future<List<String>> _getExistingTables(Database db) async {
    List<Map<String, dynamic>> result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table';"
    );
    return result.map((table) => table['name'] as String).toList();
  }

  Future<void> _checkAndCreateTables(Database db) async {
    List<String> requiredTables = [
      'text_boxes',
      'image_boxes',
      'documents',
      'folders',
      'cover_image',
      'directory_settings',
      'document_settings',
      'video_boxes',
      'media_items',
    ];

    for (String tableName in requiredTables) {
      List<Map<String, dynamic>> result = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='$tableName';",
      );
      if (result.isEmpty) {
        switch (tableName) {
          case 'text_boxes':
            await db.execute('''
  CREATE TABLE text_boxes(
    id TEXT PRIMARY KEY,
    document_id TEXT,
    position_x REAL,
    position_y REAL,
    width REAL,
    height REAL,
    content TEXT,
    font_size REAL,
    font_color INTEGER,
    font_family TEXT,
    font_weight INTEGER,
    is_italic INTEGER,
    is_underlined INTEGER,
    is_strike_through INTEGER,
    background_color INTEGER,
    text_align INTEGER,
    created_at INTEGER,
    updated_at INTEGER
  )
''');
            break;
          case 'image_boxes':
            await db.execute('''
              CREATE TABLE image_boxes (
                id TEXT PRIMARY KEY,
                documentName TEXT,
                positionX REAL,
                positionY REAL,
                width REAL,
                height REAL,
                imagePath TEXT
              )
            ''');
            break;
          case 'documents':
            await db.execute('''
              CREATE TABLE documents (
                name TEXT PRIMARY KEY,
                parentFolder TEXT,
                `order` INTEGER,
                isTemplate INTEGER DEFAULT 0
              )
            ''');
            break;
          case 'folders':
            await db.execute('''
              CREATE TABLE folders (
                name TEXT PRIMARY KEY,
                parentFolder TEXT,
                `order` INTEGER
              )
            ''');
            break;
          case 'cover_image':
            await db.execute('''
              CREATE TABLE cover_image (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT
              )
            ''');
            break;
          case 'directory_settings':
            await db.execute('''
              CREATE TABLE directory_settings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                background_image_path TEXT,
                background_color INTEGER,
                is_free_sort_mode INTEGER DEFAULT 0
              )
            ''');
            break;
          case 'document_settings':
            await db.execute('''
              CREATE TABLE document_settings (
                document_name TEXT PRIMARY KEY,
                background_image_path TEXT,
                background_color INTEGER,
                text_enhance_mode INTEGER DEFAULT 0
              )
            ''');
            break;
          case 'video_boxes':
            await db.execute('''
              CREATE TABLE video_boxes (
                id TEXT PRIMARY KEY,
                documentName TEXT,
                positionX REAL,
                positionY REAL,
                width REAL,
                height REAL,
                videoPath TEXT
              )
            ''');
            break;
          case 'media_items':
            await db.execute('''
              CREATE TABLE media_items (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                type INTEGER NOT NULL,
                directory TEXT NOT NULL,
                date_added TEXT NOT NULL,
                file_hash TEXT
              )
            ''');
            break;
        }
      }
    }

    await _checkAndAddIsTemplateColumn(db);
  }

  Future<void> _checkAndAddIsTemplateColumn(Database db) async {
    try {
      await db.rawQuery('SELECT isTemplate FROM documents LIMIT 1');
    } catch (e) {
      try {
        await db.execute('ALTER TABLE documents ADD COLUMN isTemplate INTEGER DEFAULT 0');
        print('添加了isTemplate列到documents表');
      } catch (altError) {
        print('添加isTemplate列时出错: $altError');
      }
    }
  }

  bool validateTextBoxData(Map<String, dynamic> data) {
    if (data['id'] == null || data['documentName'] == null) {
      return false;
    }
    if (data['width'] == null ||
        data['width'] <= 0 ||
        data['height'] == null ||
        data['height'] <= 0) {
      return false;
    }
    if (data['fontSize'] == null || data['fontSize'] <= 0) {
      return false;
    }
    if (data['fontColor'] == null) {
      return false;
    }

    if (!data.containsKey('fontWeight')) {
      data['fontWeight'] = 0;
    }
    if (!data.containsKey('isItalic')) {
      data['isItalic'] = 0;
    }
    if (!data.containsKey('textAlign')) {
      data['textAlign'] = 0;
    }

    if (data['isItalic'] is bool) {
      data['isItalic'] = data['isItalic'] ? 1 : 0;
    }

    if (!data.containsKey('backgroundColor')) {
      data['backgroundColor'] = null;
    }

    return true;
  }

  bool validateImageBoxData(Map<String, dynamic> data) {
    if (data['id'] == null || data['documentName'] == null) {
      return false;
    }
    if (data['width'] == null ||
        data['width'] <= 0 ||
        data['height'] == null ||
        data['height'] <= 0) {
      return false;
    }
    return true;
  }

  Future<void> insertOrUpdateTextBox(Map<String, dynamic> textBox) async {
    final db = await database;
    if (!validateTextBoxData(textBox)) {
      throw Exception('Invalid text box data');
    }
    try {
      await db.insert(
        'text_boxes',
        textBox,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      print('Error inserting or updating text box: $e');
      throw e;
    }
  }

  Future<List<Map<String, dynamic>>> getTextBoxesByDocument(
      String documentName) async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.query(
      'text_boxes',
      where: 'documentName = ?',
      whereArgs: [documentName],
    );
    return result.map((map) => Map<String, dynamic>.from(map)).toList();
  }

  Future<void> deleteTextBox(String id) async {
    final db = await database;
    await db.delete(
      'text_boxes',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveTextBoxes(List<Map<String, dynamic>> textBoxes, String documentName) async {
    // Work on a snapshot to avoid concurrent modifications
    final List<Map<String, dynamic>> snapshot = List<Map<String, dynamic>>.from(textBoxes);
    final db = await database;

    await db.transaction((txn) async {
      try {
        await txn.delete(
          'text_boxes',
          where: 'documentName = ?',
          whereArgs: [documentName],
        );

        for (var textBox in snapshot) {
          if (validateTextBoxData(textBox)) {
            await txn.insert(
              'text_boxes',
              textBox,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } else {
            print('跳过无效的文本框数据: $textBox');
          }
        }
      } catch (e) {
        print('保存文本框时出错: $e');
        throw e;
      }
    });

    print('成功保存了 ${snapshot.length} 个文本框到文档 $documentName');
  }

  Future<void> insertOrUpdateImageBox(Map<String, dynamic> imageBox) async {
    final db = await database;
    if (!validateImageBoxData(imageBox)) {
      throw Exception('Invalid image box data');
    }
    try {
      await db.insert(
        'image_boxes',
        imageBox,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      print('Error inserting or updating image box: $e');
      throw e;
    }
  }

  Future<List<Map<String, dynamic>>> getImageBoxesByDocument(
      String documentName) async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.query(
      'image_boxes',
      where: 'documentName = ?',
      whereArgs: [documentName],
    );
    return result.map((map) => Map<String, dynamic>.from(map)).toList();
  }

  Future<void> deleteImageBox(String id) async {
    final db = await database;
    await db.delete(
      'image_boxes',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertOrUpdateDocumentSettings(
      String documentName, {
        String? imagePath,
        int? colorValue,
        bool? textEnhanceMode,
      }) async {
    try {
      final db = await database;

      List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='document_settings';"
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE document_settings (
            document_name TEXT PRIMARY KEY,
            background_image_path TEXT,
            background_color INTEGER,
            text_enhance_mode INTEGER DEFAULT 0
          )
        ''');
        print('创建了document_settings表');
      } else {
        try {
          await db.rawQuery('SELECT text_enhance_mode FROM document_settings LIMIT 1');
        } catch (e) {
          try {
            await db.execute('ALTER TABLE document_settings ADD COLUMN text_enhance_mode INTEGER DEFAULT 0');
            print('添加了text_enhance_mode列到document_settings表');
          } catch (altError) {
            print('添加text_enhance_mode列时出错: $altError');
          }
        }
      }

      List<Map<String, dynamic>> existingSettings = await db.query(
        'document_settings',
        where: 'document_name = ?',
        whereArgs: [documentName],
      );

      Map<String, dynamic> settingsData = {
        'document_name': documentName,
      };

      if (existingSettings.isNotEmpty) {
        var existing = existingSettings.first;
        settingsData['background_image_path'] = imagePath ?? existing['background_image_path'] ?? '';
        settingsData['background_color'] = colorValue ?? existing['background_color'];
        settingsData['text_enhance_mode'] = textEnhanceMode != null
            ? (textEnhanceMode ? 1 : 0)
            : existing['text_enhance_mode'];
      } else {
        settingsData['background_image_path'] = imagePath ?? '';
        settingsData['background_color'] = colorValue;
        settingsData['text_enhance_mode'] = textEnhanceMode != null ? (textEnhanceMode ? 1 : 0) : 0;
      }

      await db.insert(
        'document_settings',
        settingsData,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      print('更新文档设置 - 文档名: $documentName, 背景图片: ${imagePath ?? '无'}, 背景颜色: $colorValue, 文字增强: ${textEnhanceMode ?? '不变'}');
    } catch (e) {
      print('保存文档设置时出错: $e');
      throw e;
    }
  }

  Future<Map<String, dynamic>?> getDocumentSettings(String documentName) async {
    final db = await database;
    try {
      List<Map<String, dynamic>> result = await db.query(
        'document_settings',
        where: 'document_name = ?',
        whereArgs: [documentName],
      );
      if (result.isNotEmpty) {
        print('从数据库加载设置 - 图片路径: ${result.first['background_image_path'] ?? "空"}, 颜色值: ${result.first['background_color']}');
        return result.first;
      }
      print('未找到文档设置: $documentName');
      return null;
    } catch (e) {
      print('加载背景设置时出错: $e');
      await _checkAndFixDocumentSettingsTable();
      return _retryGetDocumentSettings(documentName);
    }
  }

  Future<Map<String, dynamic>?> _retryGetDocumentSettings(String documentName) async {
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'document_settings',
        where: 'document_name = ?',
        whereArgs: [documentName],
      );

      if (result.isNotEmpty) {
        return result.first;
      }
      return null;
    } catch (e) {
      print('重试获取文档设置时出错: $e');
      return null;
    }
  }

  Future<void> deleteDocumentBackgroundImage(String documentName) async {
    final db = await database;
    await db.update(
      'document_settings',
      {'background_image_path': ''},
      where: 'document_name = ?',
      whereArgs: [documentName],
    );
    print('已清除文档 $documentName 的背景图片路径');
  }

  Future<void> insertCoverImage(String imagePath) async {
    final db = await database;
    try {
      List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';"
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        print('在insertCoverImage中创建了cover_image表');
      }

      await db.delete('cover_image');
      await db.insert(
        'cover_image',
        {'path': imagePath, 'timestamp': DateTime.now().millisecondsSinceEpoch},
      );
      print('成功插入封面图片路径: $imagePath');
    } catch (e) {
      print('插入封面图片路径时出错: $e');
      throw e;
    }
  }

  Future<List<Map<String, dynamic>>> getCoverImage() async {
    final db = await database;
    try {
      List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';"
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        print('在getCoverImage中创建了cover_image表');
        return [];
      }

      return await db.query(
        'cover_image',
        orderBy: 'id DESC',
        limit: 1,
      );
    } catch (e) {
      print('获取封面图片时出错: $e');
      return [];
    }
  }

  Future<void> deleteCoverImage() async {
    final db = await database;
    try {
      List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';"
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        print('在deleteCoverImage中创建了cover_image表');
        return;
      }

      await db.delete('cover_image');
      print('成功删除所有封面图片记录');
    } catch (e) {
      print('删除封面图片时出错: $e');
    }
  }

  Future<void> insertOrUpdateDirectorySettings({
    String? imagePath,
    int? colorValue,
    int? isFreeSortMode,
  }) async {
    final db = await database;

    Map<String, dynamic> data = {};

    if (imagePath == null) {
      data['background_image_path'] = null;
    } else {
      data['background_image_path'] = imagePath;
    }

    if (colorValue != null) {
      data['background_color'] = colorValue;
    }

    if (isFreeSortMode != null) {
      data['is_free_sort_mode'] = isFreeSortMode;
    }

    List<Map<String, dynamic>> existing = await db.query('directory_settings');
    if (existing.isEmpty) {
      await db.insert('directory_settings', data);
      print('创建新的目录设置，自由排序模式: ${isFreeSortMode ?? "未设置"}');
    } else {
      await db.update('directory_settings', data);
      String bgStatus = imagePath == null ? "已清除背景图片" : (imagePath.isEmpty ? "未更改" : "已设置");
      String colorStatus = colorValue != null ? "已设置" : "未更改";
      print('更新目录设置 - 背景图片: $bgStatus, 背景颜色: $colorStatus, 自由排序模式: ${isFreeSortMode ?? "未更改"}');
    }
  }

  Future<Map<String, dynamic>?> getDirectorySettings() async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.query('directory_settings');
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<void> deleteDirectoryBackgroundImage() async {
    final db = await database;
    await db.update(
      'directory_settings',
      {'background_image_path': null},
      where: 'id IS NOT NULL',
    );
    print('已清除目录背景图片路径');
  }

  Future<bool> doesNameExist(String name) async {
    final db = await database;
    List<Map<String, dynamic>> folders = await db.query(
      'folders',
      where: 'name = ?',
      whereArgs: [name],
    );
    List<Map<String, dynamic>> documents = await db.query(
      'documents',
      where: 'name = ?',
      whereArgs: [name],
    );
    return folders.isNotEmpty || documents.isNotEmpty;
  }

  Future<void> insertDocument(String name, {String? parentFolder, String? position}) async {
    final db = await database;

    final List<Map<String, dynamic>> result = await db.rawQuery('''
      SELECT MAX(`order`) as maxOrder FROM documents 
      WHERE parentFolder ${parentFolder == null ? 'IS NULL' : '= ?'}
    ''', parentFolder != null ? [parentFolder] : []);

    int order = (result.first['maxOrder'] ?? -1) + 1;

    await db.insert(
      'documents',
      {
        'name': name,
        'parentFolder': parentFolder,
        'order': order,
        'isTemplate': 0,
        'position': position,
      },
    );
  }

  Future<List<Map<String, dynamic>>> getDocuments({String? parentFolder}) async {
    final db = await database;
    return await db.query(
      'documents',
      where: 'parentFolder ' + (parentFolder == null ? 'IS NULL' : '= ?'),
      whereArgs: parentFolder != null ? [parentFolder] : [],
      orderBy: '`order` ASC',
    );
  }

  Future<void> deleteDocument(String documentName,
      {String? parentFolder}) async {
    final db = await database;
    await db.delete(
      'documents',
      where: 'name = ?',
      whereArgs: [documentName],
    );
    await db.delete(
      'text_boxes',
      where: 'documentName = ?',
      whereArgs: [documentName],
    );
    await db.delete(
      'image_boxes',
      where: 'documentName = ?',
      whereArgs: [documentName],
    );
    await db.delete(
      'audio_boxes',
      where: 'documentName = ?',
      whereArgs: [documentName],
    );

    await db.delete(
      'document_settings',
      where: 'document_name = ?',
      whereArgs: [documentName],
    );

    List<Map<String, dynamic>> remainingDocuments = await db.query(
      'documents',
      where: parentFolder == null ? 'parentFolder IS NULL' : 'parentFolder = ?',
      whereArgs: parentFolder == null ? null : [parentFolder],
      orderBy: '`order` ASC',
    );
    for (int i = 0; i < remainingDocuments.length; i++) {
      await db.update(
        'documents',
        {'order': i},
        where: 'name = ?',
        whereArgs: [remainingDocuments[i]['name']],
      );
    }
  }

  Future<void> renameDocument(String oldName, String newName) async {
    final db = await database;
    if (await doesNameExist(newName)) {
      throw Exception('Document name already exists');
    }
    await db.update(
      'documents',
      {'name': newName},
      where: 'name = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'text_boxes',
      {'documentName': newName},
      where: 'documentName = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'image_boxes',
      {'documentName': newName},
      where: 'documentName = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'audio_boxes',
      {'documentName': newName},
      where: 'documentName = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'document_settings',
      {'document_name': newName},
      where: 'document_name = ?',
      whereArgs: [oldName],
    );
  }

  Future<void> insertFolder(String name, {String? parentFolder, String? position}) async {
    final db = await database;

    final List<Map<String, dynamic>> result = await db.rawQuery('''
      SELECT MAX(`order`) as maxOrder FROM folders 
      WHERE parentFolder ${parentFolder == null ? 'IS NULL' : '= ?'}
    ''', parentFolder != null ? [parentFolder] : []);

    int order = (result.first['maxOrder'] ?? -1) + 1;

    await db.insert(
      'folders',
      {
        'name': name,
        'parentFolder': parentFolder,
        'order': order,
        'position': position,
      },
    );
  }

  Future<List<Map<String, dynamic>>> getFolders({String? parentFolder}) async {
    final db = await database;
    return await db.query(
      'folders',
      where: 'parentFolder ' + (parentFolder == null ? 'IS NULL' : '= ?'),
      whereArgs: parentFolder != null ? [parentFolder] : [],
      orderBy: '`order` ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getFolderByName(String folderName) async {
    final db = await database;
    return await db.query(
      'folders',
      where: 'name = ?',
      whereArgs: [folderName],
    );
  }

  Future<void> deleteFolder(String folderName, {String? parentFolder}) async {
    final db = await database;
    await db.delete(
      'folders',
      where: 'name = ?',
      whereArgs: [folderName],
    );

    List<Map<String, dynamic>> documents =
    await getDocuments(parentFolder: folderName);
    for (var doc in documents) {
      await deleteDocument(doc['name'], parentFolder: folderName);
    }

    List<Map<String, dynamic>> subFolders =
    await getFolders(parentFolder: folderName);
    for (var subFolder in subFolders) {
      await deleteFolder(subFolder['name'], parentFolder: folderName);
    }

    List<Map<String, dynamic>> remainingFolders =
    await getFolders(parentFolder: parentFolder);
    for (int i = 0; i < remainingFolders.length; i++) {
      await db.update(
        'folders',
        {'order': i},
        where: 'name = ?',
        whereArgs: [remainingFolders[i]['name']],
      );
    }
  }

  Future<void> renameFolder(String oldName, String newName) async {
    final db = await database;
    if (await doesNameExist(newName)) {
      throw Exception('Folder name already exists');
    }
    await db.update(
      'folders',
      {'name': newName},
      where: 'name = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'documents',
      {'parentFolder': newName},
      where: 'parentFolder = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'folders',
      {'parentFolder': newName},
      where: 'parentFolder = ?',
      whereArgs: [oldName],
    );
  }

  Future<void> updateDocumentParentFolder(
      String documentName, String? newParentFolder) async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT MAX(`order`) as maxOrder FROM documents WHERE parentFolder ${newParentFolder == null ? 'IS NULL' : '= ?'}',
      newParentFolder == null ? null : [newParentFolder],
    );
    int maxOrder =
    result.first['maxOrder'] != null ? result.first['maxOrder'] as int : 0;

    await db.update(
      'documents',
      {
        'parentFolder': newParentFolder,
        'order': maxOrder + 1,
      },
      where: 'name = ?',
      whereArgs: [documentName],
    );
  }

  Future<void> updateFolderParentFolder(
      String folderName, String? newParentFolder) async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT MAX(`order`) as maxOrder FROM folders WHERE parentFolder ${newParentFolder == null ? 'IS NULL' : '= ?'}',
      newParentFolder == null ? null : [newParentFolder],
    );
    int maxOrder =
    result.first['maxOrder'] != null ? result.first['maxOrder'] as int : 0;

    await db.update(
      'folders',
      {
        'parentFolder': newParentFolder,
        'order': maxOrder + 1,
      },
      where: 'name = ?',
      whereArgs: [folderName],
    );
  }

  Future<void> updateFolderOrder(String folderName, int newOrder) async {
    final db = await database;
    await db.update(
      'folders',
      {'order': newOrder},
      where: 'name = ?',
      whereArgs: [folderName],
    );
    print('更新文件夹 $folderName 的顺序为 $newOrder');
  }

  Future<void> updateDocumentOrder(String documentName, int newOrder) async {
    final db = await database;
    await db.update(
      'documents',
      {'order': newOrder},
      where: 'name = ?',
      whereArgs: [documentName],
    );
    print('更新文档 $documentName 的顺序为 $newOrder');
  }

  Future<List<Map<String, dynamic>>> getAllFolders() async {
    final db = await database;
    return await db.query(
      'media_items',
      where: 'type = ?',
      whereArgs: [MediaType.folder.index],
      orderBy: 'name ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getAllDirectoryFolders() async {
    final db = await database;
    return await db.query(
      'folders',
      orderBy: 'name ASC',
    );
  }

  Future<String> getFolderPath(String folderName) async {
    final db = await database;
    String path = folderName;
    String? parentFolder = await _getParentFolderName(db, folderName);

    while (parentFolder != null) {
      path = '$parentFolder/$path';
      parentFolder = await _getParentFolderName(db, parentFolder);
    }

    return path;
  }

  Future<String?> _getParentFolderName(Database db, String? folderName) async {
    if (folderName == null) {
      return null;
    }
    List<Map<String, dynamic>> result = await db.query(
      'folders',
      columns: ['parentFolder'],
      where: 'name = ?',
      whereArgs: [folderName],
    );
    if (result.isNotEmpty) {
      return result.first['parentFolder'] as String?;
    }
    return null;
  }

  Future<void> _checkStoragePermission() async {
    if (Platform.isAndroid) {
      var androidInfo = await DeviceInfoPlugin().androidInfo;
      int sdkInt = androidInfo.version.sdkInt ?? 0;

      if (sdkInt >= 30) {
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            throw Exception('Storage permission not granted');
          }
        }
      } else {
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
          if (!status.isGranted) {
            throw Exception('Storage permission not granted');
          }
        }
      }
    }
  }

  Future<String> _getExportPath(String fileName) async {
    Directory? directory;
    if (Platform.isAndroid) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationDocumentsDirectory();
    }
    return p.join(directory!.path, fileName);
  }

  String formatDateTime(DateTime dateTime) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String year = dateTime.year.toString();
    String month = twoDigits(dateTime.month);
    String day = twoDigits(dateTime.day);
    String hour = twoDigits(dateTime.hour);
    String minute = twoDigits(dateTime.minute);
    return '$year$month$day$hour$minute';
  }

  Future<String> exportDocument(String documentName,
      {String? exportFileName}) async {
    try {
      await _checkStoragePermission();

      String formattedTime = formatDateTime(DateTime.now());
      String fileName = exportFileName ?? '$documentName$formattedTime.zip';
      String exportPath = await _getExportPath(fileName);

      final archive = Archive();

      Map<String, dynamic>? documentData = await _getDocumentData(documentName);
      if (documentData == null) throw Exception('Document not found');

      String documentJson = jsonEncode({
        'type': 'document',
        'name': documentData['name'],
        'parentFolder': documentData['parentFolder'],
        'order': documentData['order'],
      });
      archive.addFile(ArchiveFile('document.json', documentJson.length, utf8.encode(documentJson)));

      List<Map<String, dynamic>> textBoxes = await getTextBoxesByDocument(documentName);
      String textBoxesJson = jsonEncode(textBoxes);
      archive.addFile(ArchiveFile('text_boxes.json', textBoxesJson.length, utf8.encode(textBoxesJson)));

      List<Map<String, dynamic>> imageBoxes = await getImageBoxesByDocument(documentName);
      List<Map<String, dynamic>> imageBoxesToExport = [];
      for (var imageBox in imageBoxes) {
        Map<String, dynamic> imageBoxCopy = Map<String, dynamic>.from(imageBox);
        imageBoxCopy['imageFileName'] = p.basename(imageBox['imagePath']);
        imageBoxesToExport.add(imageBoxCopy);
      }
      String imageBoxesJson = jsonEncode(imageBoxesToExport);
      archive.addFile(ArchiveFile('image_boxes.json', imageBoxesJson.length, utf8.encode(imageBoxesJson)));

      for (var imageBox in imageBoxes) {
        String imagePath = imageBox['imagePath'];
        if (imagePath.isNotEmpty) {
          File imageFile = File(imagePath);
          if (await imageFile.exists()) {
            String relativePath = 'images/${p.basename(imagePath)}';
            List<int> fileBytes = await imageFile.readAsBytes();
            archive.addFile(ArchiveFile(relativePath, fileBytes.length, fileBytes));
          }
        }
      }

      Map<String, dynamic>? settings = await getDocumentSettings(documentName);
      if (settings != null) {
        // 处理背景图片
        String? backgroundImagePath = settings['background_image_path'];
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String fileName = p.basename(backgroundImagePath);
            String relativePath = 'background_images/$fileName';
            List<int> fileBytes = await imageFile.readAsBytes();
            archive.addFile(ArchiveFile(relativePath, fileBytes.length, fileBytes));
            print('已导出文档背景图片: $relativePath');
          } else {
            print('警告：文档背景图片不存在: $backgroundImagePath');
          }
        }
        String settingsJson = jsonEncode(settings);
        archive.addFile(ArchiveFile('document_settings.json', settingsJson.length, utf8.encode(settingsJson)));
      }

      List<Map<String, dynamic>> audioBoxes = await getAudioBoxesByDocument(documentName);
      List<Map<String, dynamic>> audioBoxesToExport = [];
      for (var audioBox in audioBoxes) {
        Map<String, dynamic> audioBoxCopy = Map<String, dynamic>.from(audioBox);
        audioBoxCopy['audioFileName'] = p.basename(audioBox['audioPath']);
        audioBoxesToExport.add(audioBoxCopy);
      }
      String audioBoxesJson = jsonEncode(audioBoxesToExport);
      archive.addFile(ArchiveFile('audio_boxes.json', audioBoxesJson.length, utf8.encode(audioBoxesJson)));

      for (var audioBox in audioBoxes) {
        String audioPath = audioBox['audioPath'];
        if (audioPath.isNotEmpty) {
          File audioFile = File(audioPath);
          if (await audioFile.exists()) {
            String relativePath = 'audios/${p.basename(audioPath)}';
            List<int> fileBytes = await audioFile.readAsBytes();
            archive.addFile(ArchiveFile(relativePath, fileBytes.length, fileBytes));
          }
        }
      }

      final zipFile = File(exportPath);
      final encoder = ZipEncoder();
      await zipFile.writeAsBytes(encoder.encode(archive)!);

      print('Document "$documentName" exported to $exportPath');
      return exportPath;
    } catch (e) {
      print('Error exporting document: $e');
      throw e;
    }
  }

  Future<void> importDocument(String zipFilePath,
      {String? targetDocumentName, String? targetParentFolder, String? position}) async {
    try {
      await _checkStoragePermission();

      final zipFile = File(zipFilePath);
      if (!await zipFile.exists()) throw Exception('Backup file does not exist');

      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      Map<String, String> imagePathMap = {};
      Map<String, String> audioPathMap = {};

      for (var file in archive) {
        if (file.isFile && file.name.startsWith('images/')) {
          String imageName = p.basename(file.name);
          String imagesDirPath = p.join(await getApplicationDocumentsDirectory().then((dir) => dir.path), 'images');
          await Directory(imagesDirPath).create(recursive: true);
          String imagePathToSave = p.join(imagesDirPath, imageName);
          File imageFile = File(imagePathToSave);
          await imageFile.writeAsBytes(file.content, flush: true);
          imagePathMap[imageName] = imagePathToSave;
        }
        if (file.isFile && file.name.startsWith('audios/')) {
          String audioName = p.basename(file.name);
          String audiosDirPath = p.join(await getApplicationDocumentsDirectory().then((dir) => dir.path), 'audios');
          await Directory(audiosDirPath).create(recursive: true);
          String audioPathToSave = p.join(audiosDirPath, audioName);
          File audioFile = File(audioPathToSave);
          await audioFile.writeAsBytes(file.content, flush: true);
          audioPathMap[audioName] = audioPathToSave;
        }
      }

      Map<String, dynamic>? documentData;
      String? oldDocumentName;
      for (var file in archive) {
        if (file.isFile && file.name == 'document.json') {
          String jsonString = utf8.decode(file.content);
          documentData = jsonDecode(jsonString);
          oldDocumentName = documentData?['name'];
          break;
        }
      }

      if (documentData == null || oldDocumentName == null) throw Exception('Document data not found in backup');

      String newDocumentName = targetDocumentName ?? oldDocumentName;
      if (await doesNameExist(newDocumentName)) {
        throw Exception('Document name already exists: $newDocumentName');
      }

      String? parentFolder = targetParentFolder ?? documentData['parentFolder'];
      await insertDocument(newDocumentName, parentFolder: parentFolder, position: position);
      int newOrder = documentData['order'] != null ? documentData['order'] as int : 0;
      await updateDocumentOrder(newDocumentName, newOrder);

      for (var file in archive) {
        if (file.isFile && file.name == 'text_boxes.json') {
          String jsonString = utf8.decode(file.content);
          dynamic decodedData = jsonDecode(jsonString);
          List<dynamic> textBoxes = decodedData is List ? decodedData : [decodedData];
          for (var textBox in textBoxes) {
            Map<String, dynamic> box = Map<String, dynamic>.from(textBox);
            box['id'] = Uuid().v4();
            box['documentName'] = newDocumentName;
            await insertOrUpdateTextBox(box);
          }
          break;
        }
      }

      for (var file in archive) {
        if (file.isFile && file.name == 'image_boxes.json') {
          String jsonString = utf8.decode(file.content);
          dynamic decodedData = jsonDecode(jsonString);
          List<dynamic> imageBoxes = decodedData is List ? decodedData : [decodedData];
          for (var imageBox in imageBoxes) {
            Map<String, dynamic> box = Map<String, dynamic>.from(imageBox);
            box['id'] = Uuid().v4();
            box['documentName'] = newDocumentName;
            String? imageFileName = box['imageFileName'];
            if (imageFileName != null && imagePathMap.containsKey(imageFileName)) {
              box['imagePath'] = imagePathMap[imageFileName]!;
            } else {
              box['imagePath'] = '';
            }
            box.remove('imageFileName');
            await insertOrUpdateImageBox(box);
          }
          break;
        }
      }

      for (var file in archive) {
        if (file.isFile && file.name == 'document_settings.json') {
          String jsonString = utf8.decode(file.content);
          Map<String, dynamic> settings = jsonDecode(jsonString);
          
          // 处理背景图片
          String? backgroundImagePath = settings['background_image_path'];
          if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
            String fileName = p.basename(backgroundImagePath);
            Directory appDocDir = await getApplicationDocumentsDirectory();
            String backgroundImagesDirPath = p.join(appDocDir.path, 'background_images');
            await Directory(backgroundImagesDirPath).create(recursive: true);
            String newBackgroundImagePath = p.join(backgroundImagesDirPath, fileName);
            settings['background_image_path'] = newBackgroundImagePath;
            print('更新文档背景图片路径: $newBackgroundImagePath');
          }
          
          await insertOrUpdateDocumentSettings(
            newDocumentName,
            imagePath: settings['background_image_path'],
            colorValue: settings['background_color'],
            textEnhanceMode: settings['text_enhance_mode'] == 1,
          );
          break;
        }
      }

      // 导入背景图片文件
      for (var file in archive) {
        if (file.isFile && file.name.startsWith('background_images/')) {
          String fileName = p.basename(file.name);
          Directory appDocDir = await getApplicationDocumentsDirectory();
          String backgroundImagesDirPath = p.join(appDocDir.path, 'background_images');
          await Directory(backgroundImagesDirPath).create(recursive: true);
          String imagePathToSave = p.join(backgroundImagesDirPath, fileName);
          
          File imageFile = File(imagePathToSave);
          await imageFile.writeAsBytes(file.content as List<int>, flush: true);
          print('已导入背景图片: $imagePathToSave');
        }
      }

      for (var file in archive) {
        if (file.isFile && file.name == 'audio_boxes.json') {
          String jsonString = utf8.decode(file.content);
          dynamic decodedData = jsonDecode(jsonString);
          List<dynamic> audioBoxes = decodedData is List ? decodedData : [decodedData];
          for (var audioBox in audioBoxes) {
            Map<String, dynamic> box = Map<String, dynamic>.from(audioBox);
            box['id'] = Uuid().v4();
            box['documentName'] = newDocumentName;
            String? audioFileName = box['audioFileName'];
            if (audioFileName != null && audioPathMap.containsKey(audioFileName)) {
              box['audioPath'] = audioPathMap[audioFileName]!;
            } else {
              box['audioPath'] = '';
            }
            box.remove('audioFileName');
            await insertOrUpdateAudioBox(box);
          }
          break;
        }
      }

      print('Document data imported from $zipFilePath with name $newDocumentName');
    } catch (e) {
      print('Error importing document: $e');
      throw e;
    }
  }

  Future<void> backupDatabase() async {
    try {
      String dbPath = await getDatabasesPath();
      String path = p.join(dbPath, 'text_boxes.db');
      File dbFile = File(path);

      if (!await dbFile.exists()) {
        print('数据库文件不存在，无需备份');
        return;
      }

      Directory appDir = await getApplicationDocumentsDirectory();
      String backupDirPath = p.join(appDir.path, 'backups');

      Directory backupDir = Directory(backupDirPath);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      String backupPath = p.join(backupDirPath, 'text_boxes_backup.db');
      await dbFile.copy(backupPath);

      print('数据库已备份到: $backupPath');
    } catch (e) {
      print('备份数据库时出错: $e');
    }
  }

  Future<void> restoreDatabase() async {
    try {
      await _checkStoragePermission();

      String dbPath = await getDatabasesPath();
      String path = p.join(dbPath, 'text_boxes.db');

      String backupPath = await _getExportPath('text_boxes_backup.db');

      await _database?.close();
      _database = null;

      await File(backupPath).copy(path);

      _database = await _initDB();

      print('Database restored from $backupPath');
    } catch (e) {
      print('Error restoring database: $e');
      throw e;
    }
  }

  Future<Map<String, dynamic>?> _getDocumentData(String documentName) async {
    final db = await database;
    List<Map<String, dynamic>> result = await db.query(
      'documents',
      where: 'name = ?',
      whereArgs: [documentName],
    );
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getMediaItems(String directory) async {
    print('正在获取目录 $directory 中的项目...');
    final db = await database;

    print('检查系统文件夹状态:');
    final recycleBin = await getMediaItemById('recycle_bin');
    final favorites = await getMediaItemById('favorites');
    print('- 回收站: ${recycleBin != null ? "存在" : "不存在"}');
    print('- 收藏夹: ${favorites != null ? "存在" : "不存在"}');

    if (recycleBin != null) {
      print('回收站文件夹详情:');
      print('- ID: ${recycleBin['id']}');
      print('- 名称: ${recycleBin['name']}');
      print('- 目录: ${recycleBin['directory']}');
      print('- 类型: ${recycleBin['type']}');
    }

    // 获取文件夹
    final List<Map<String, dynamic>> folders = await db.query(
      'media_items',
      where: 'directory = ? AND type = ?',
      whereArgs: [directory, MediaType.folder.index],
      orderBy: 'CASE id WHEN \'recycle_bin\' THEN 0 WHEN \'favorites\' THEN 1 ELSE 2 END, name ASC'
    );

    print('查询到的所有文件夹:');
    for (var folder in folders) {
      print('- 文件夹名称: ${folder['name']}, ID: ${folder['id']}, 目录: ${folder['directory']}, 类型: ${folder['type']}');
    }

    // 获取媒体文件
    final List<Map<String, dynamic>> mediaFiles = await db.query(
      'media_items',
      where: 'directory = ? AND type IN (?, ?)',
      whereArgs: [directory, MediaType.image.index, MediaType.video.index],
      orderBy: 'date_added DESC'
    );

    print('查询到的所有媒体文件:');
    for (var file in mediaFiles) {
      print('- 文件名称: ${file['name']}, ID: ${file['id']}, 目录: ${file['directory']}');
    }

    // 合并结果
    final results = [...folders, ...mediaFiles];
    print('总共返回 ${results.length} 个项目');
    print('从目录 $directory 加载了 ${results.length} 个项目');

    return results;
  }

  Future<int> updateMediaItem(Map<String, dynamic> item) async {
    final db = await database;
    return await db.update(
      'media_items',
      item,
      where: 'id = ?',
      whereArgs: [item['id']],
    );
  }

  Future<int> deleteMediaItem(String id) async {
    final db = await database;
    return await db.delete('media_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateMediaItemDirectory(String id, String directory) async {
    final db = await database;
    return await db.update(
      'media_items', 
      {'directory': directory},
      where: 'id = ?',
      whereArgs: [id]
    );
  }

  Future<Map<String, dynamic>?> getMediaItemById(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'media_items',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return maps.first;
    }
    return null;
  }

  Future<String?> getMediaItemParentDirectory(String mediaItemId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'media_items',
      columns: ['directory'],
      where: 'id = ?',
      whereArgs: [mediaItemId],
    );
    if (maps.isNotEmpty) {
      return maps.first['directory'] as String?;
    }
    return null;
  }

  Future<void> ensureMediaItemsTableExists() async {
    final db = await database;

    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';"
    );

    if (tables.isEmpty) {
      await db.execute('''
        CREATE TABLE media_items (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          type INTEGER NOT NULL,
          directory TEXT NOT NULL,
          date_added TEXT NOT NULL,
          file_hash TEXT
        )
      ''');
      print('已创建media_items表');
    } else {
      // 检查file_hash列是否存在
      final columns = await db.rawQuery("PRAGMA table_info(media_items);");
      bool hasFileHash = columns.any((column) => column['name'] == 'file_hash');
      
      if (!hasFileHash) {
        // 添加file_hash列
        await db.execute('ALTER TABLE media_items ADD COLUMN file_hash TEXT;');
        print('已添加file_hash列到media_items表');
      }
      print('media_items表已存在');
    }
  }

  Future<void> setDocumentAsTemplate(String documentName, bool isTemplate) async {
    final db = await database;
    await db.update(
      'documents',
      {'isTemplate': isTemplate ? 1 : 0},
      where: 'name = ?',
      whereArgs: [documentName],
    );
  }

  Future<List<Map<String, dynamic>>> getTemplateDocuments() async {
    final db = await database;
    return await db.query(
      'documents',
      where: 'isTemplate = ?',
      whereArgs: [1],
      orderBy: '`order` ASC',
    );
  }

  Future<String> createDocumentFromTemplate(String templateName, {String? parentFolder, String? position}) async {
    final db = await database;

    try {
      String newDocName = "$templateName - 副本";
      int copyNumber = 1;

      while (await doesNameExist(newDocName)) {
        copyNumber++;
        newDocName = "$templateName - 副本($copyNumber)";
      }

      final List<Map<String, dynamic>> result = await db.rawQuery('''
        SELECT MAX(`order`) as maxOrder FROM documents 
        WHERE parentFolder ${parentFolder == null ? 'IS NULL' : '= ?'}
      ''', parentFolder != null ? [parentFolder] : []);

      int order = (result.first['maxOrder'] ?? -1) + 1;

      await db.insert(
        'documents',
        {
          'name': newDocName,
          'parentFolder': parentFolder,
          'order': order,
          'isTemplate': 0,
          'position': position,
        },
      );

      List<Map<String, dynamic>> textBoxes = await getTextBoxesByDocument(templateName);
      for (var textBox in textBoxes) {
        var newTextBox = Map<String, dynamic>.from(textBox);
        newTextBox['id'] = Uuid().v4();
        newTextBox['documentName'] = newDocName;
        await insertOrUpdateTextBox(newTextBox);
      }

      List<Map<String, dynamic>> imageBoxes = await getImageBoxesByDocument(templateName);
      for (var imageBox in imageBoxes) {
        var newImageBox = Map<String, dynamic>.from(imageBox);
        newImageBox['id'] = Uuid().v4();
        newImageBox['documentName'] = newDocName;
        await insertOrUpdateImageBox(newImageBox);
      }

      List<Map<String, dynamic>> audioBoxes = await getAudioBoxesByDocument(templateName);
      for (var audioBox in audioBoxes) {
        var newAudioBox = Map<String, dynamic>.from(audioBox);
        newAudioBox['id'] = Uuid().v4();
        newAudioBox['documentName'] = newDocName;
        await insertOrUpdateAudioBox(newAudioBox);
      }

      Map<String, dynamic>? documentSettings = await getDocumentSettings(templateName);
      if (documentSettings != null) {
        await insertOrUpdateDocumentSettings(
          newDocName,
          imagePath: documentSettings['background_image_path'],
          colorValue: documentSettings['background_color'],
        );
      }

      return newDocName;
    } catch (e) {
      print('Error creating document from template: $e');
      throw Exception('Failed to create document from template: $e');
    }
  }

  Future<void> resetSortMode() async {
    final db = await database;
    Map<String, dynamic> data = {'is_free_sort_mode': 1};

    List<Map<String, dynamic>> existing = await db.query('directory_settings');
    if (existing.isEmpty) {
      await db.insert('directory_settings', data);
    } else {
      await db.update('directory_settings', data);
    }
    print('已重置为自由排序模式');
  }

  Future<void> updateItemPosition(String name, String position, bool isFolder) async {
    final db = await database;

    if (isFolder) {
      await db.update(
        'folders',
        {'position': position},
        where: 'name = ?',
        whereArgs: [name],
      );
    } else {
      await db.update(
        'documents',
        {'position': position},
        where: 'name = ?',
        whereArgs: [name],
      );
    }
  }

  Future<void> _fixDatabaseStructure(Database db) async {
    try {
      List<Map<String, dynamic>> tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='text_boxes';"
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE text_boxes(
            id TEXT PRIMARY KEY,
            document_id TEXT,
            position_x REAL,
            position_y REAL,
            width REAL,
            height REAL,
            content TEXT,
            font_size REAL,
            font_color INTEGER,
            font_family TEXT,
            font_weight INTEGER,
            is_italic INTEGER,
            is_underlined INTEGER,
            is_strike_through INTEGER,
            background_color INTEGER,
            text_align INTEGER,
            created_at INTEGER,
            updated_at INTEGER
          )
        ''');
        print('创建了text_boxes表');
        return;
      }

      List<Map<String, dynamic>> columns = await db.rawQuery('PRAGMA table_info(text_boxes)');
      List<String> columnNames = columns.map((col) => col['name'] as String).toList();

      Map<String, String> requiredColumns = {
        'fontFamily': 'TEXT',
        'fontWeight': 'INTEGER',
        'isItalic': 'INTEGER',
        'isUnderlined': 'INTEGER',
        'isStrikeThrough': 'INTEGER',
        'backgroundColor': 'INTEGER',
        'textAlign': 'INTEGER'
      };

      for (var entry in requiredColumns.entries) {
        if (!columnNames.contains(entry.key)) {
          try {
            await db.execute('ALTER TABLE text_boxes ADD COLUMN ${entry.key} ${entry.value}');
            print('添加了列: ${entry.key}');
          } catch (e) {
            print('添加列 ${entry.key} 时出错: $e');
          }
        }
      }

      List<Map<String, dynamic>> textBoxes = await db.query('text_boxes');
      for (var textBox in textBoxes) {
        Map<String, dynamic> updates = {};

        if (!textBox.containsKey('fontFamily') || textBox['fontFamily'] == null) {
          updates['fontFamily'] = 'Arial';
        }
        if (!textBox.containsKey('fontWeight') || textBox['fontWeight'] == null) {
          updates['fontWeight'] = 0;
        }
        if (!textBox.containsKey('isItalic') || textBox['isItalic'] == null) {
          updates['isItalic'] = 0;
        }
        if (!textBox.containsKey('isUnderlined') || textBox['isUnderlined'] == null) {
          updates['isUnderlined'] = 0;
        }
        if (!textBox.containsKey('isStrikeThrough') || textBox['isStrikeThrough'] == null) {
          updates['isStrikeThrough'] = 0;
        }
        if (!textBox.containsKey('textAlign') || textBox['textAlign'] == null) {
          updates['textAlign'] = 0;
        }

        if (textBox['isItalic'] is bool) {
          updates['isItalic'] = textBox['isItalic'] ? 1 : 0;
        }
        if (textBox['isUnderlined'] is bool) {
          updates['isUnderlined'] = textBox['isUnderlined'] ? 1 : 0;
        }
        if (textBox['isStrikeThrough'] is bool) {
          updates['isStrikeThrough'] = textBox['isStrikeThrough'] ? 1 : 0;
        }

        if (updates.isNotEmpty) {
          await db.update(
            'text_boxes',
            updates,
            where: 'id = ?',
            whereArgs: [textBox['id']],
          );
        }
      }

      print('数据库结构检查和修复完成');
    } catch (e) {
      print('修复数据库结构时出错: $e');
    }
  }

  Future<void> updateDocumentParentFolderWithPosition(String documentName, String? parentFolder, String position) async {
    final db = await database;
    await db.update(
      'documents',
      {
        'parentFolder': parentFolder,
        'position': position,
      },
      where: 'name = ?',
      whereArgs: [documentName],
    );
  }

  Future<void> updateFolderParentFolderWithPosition(String folderName, String? parentFolder, String position) async {
    final db = await database;
    await db.update(
      'folders',
      {
        'parentFolder': parentFolder,
        'position': position,
      },
      where: 'name = ?',
      whereArgs: [folderName],
    );
  }

  Future<void> updateDocumentPosition(String documentName, String position) async {
    return updateItemPosition(documentName, position, false);
  }

  Future<void> updateFolderPosition(String folderName, String position) async {
    return updateItemPosition(folderName, position, true);
  }

  Future<void> checkAndUpgradeDatabase() async {
    try {
      final db = await database;

      List<Map<String, dynamic>> result = await db.rawQuery('PRAGMA user_version');
      int currentVersion = result.first['user_version'] as int;
      print('当前数据库版本: $currentVersion');

      if (currentVersion < 6) {
        print('开始升级数据库结构...');
        await _fixDatabaseStructure(db);
        await db.setVersion(6);
        print('数据库已手动升级到版本6');
      } else {
        print('数据库版本已是最新，无需升级');
      }
    } catch (e) {
      print('检查和升级数据库时出错: $e');
    }
  }

  Future<void> _checkAndFixDocumentSettingsTable() async {
    final db = await database;
    try {
      List<Map<String, dynamic>> tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='document_settings';"
      );

      if (tableExists.isEmpty) {
        await db.execute('''
          CREATE TABLE document_settings(
            document_name TEXT PRIMARY KEY,
            background_image_path TEXT,
            background_color INTEGER,
            text_enhance_mode INTEGER DEFAULT 0
          )
        ''');
        print('创建了document_settings表');
        return;
      }

      var columnInfo = await db.rawQuery('PRAGMA table_info(document_settings)');
      bool hasDocumentName = columnInfo.any((column) => column['name'] == 'document_name');

      if (!hasDocumentName) {
        List<Map<String, dynamic>> existingData = await db.query('document_settings');
        await db.execute('ALTER TABLE document_settings RENAME TO document_settings_old');
        await db.execute('''
          CREATE TABLE document_settings(
            document_name TEXT PRIMARY KEY,
            background_image_path TEXT,
            background_color INTEGER,
            text_enhance_mode INTEGER DEFAULT 0
          )
        ''');

        for (var row in existingData) {
          try {
            String? docName = row['documentName'];
            if (docName != null) {
              await db.insert(
                'document_settings',
                {
                  'document_name': docName,
                  'background_image_path': row['background_image_path'],
                  'background_color': row['background_color'],
                  'text_enhance_mode': row['text_enhance_mode'] ?? 0,
                },
              );
            }
          } catch (e) {
            print('迁移document_settings数据时出错: $e');
          }
        }

        await db.execute('DROP TABLE IF EXISTS document_settings_old');
        print('修复了document_settings表结构');
      }

      bool hasTextEnhanceMode = columnInfo.any((column) => column['name'] == 'text_enhance_mode');
      if (!hasTextEnhanceMode) {
        try {
          await db.execute('ALTER TABLE document_settings ADD COLUMN text_enhance_mode INTEGER DEFAULT 0');
          print('添加了text_enhance_mode列到document_settings表');
        } catch (e) {
          print('添加text_enhance_mode列时出错: $e');
        }
      }
    } catch (e) {
      print('检查document_settings表时出错: $e');
    }
  }

  Future<void> saveImageBoxes(
      List<Map<String, dynamic>> imageBoxes, String documentName) async {
    final db = await database;

    try {
      await db.transaction((txn) async {
        await txn.delete(
          'image_boxes',
          where: 'documentName = ?',
          whereArgs: [documentName],
        );

        for (var imageBox in imageBoxes) {
          await txn.insert(
            'image_boxes',
            imageBox,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      print('成功保存了 ${imageBoxes.length} 个图片框到文档 $documentName');
    } catch (e) {
      print('保存图片框时出错: $e');
      throw e;
    }
  }

  bool validateAudioBoxData(Map<String, dynamic> data) {
    if (data['id'] == null || data['documentName'] == null) {
      return false;
    }
    if (data['positionX'] == null || data['positionY'] == null) {
      return false;
    }
    return true;
  }

  Future<void> insertOrUpdateAudioBox(Map<String, dynamic> audioBox) async {
    final db = await database;
    if (!validateAudioBoxData(audioBox)) {
      throw Exception('无效的音频框数据');
    }
    try {
      await db.insert(
        'audio_boxes',
        audioBox,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      print('添加或更新音频框时出错: $e');
      throw e;
    }
  }

  Future<List<Map<String, dynamic>>> getAudioBoxesByDocument(
      String documentName) async {
    final db = await database;
    try {
      List<Map<String, dynamic>> result = await db.query(
        'audio_boxes',
        where: 'documentName = ?',
        whereArgs: [documentName],
      );
      return result.map((map) => Map<String, dynamic>.from(map)).toList();
    } catch (e) {
      print('获取音频框时出错: $e');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS audio_boxes(
          id TEXT PRIMARY KEY,
          documentName TEXT,
          positionX REAL,
          positionY REAL,
          audioPath TEXT
        )
      ''');
      return [];
    }
  }

  Future<void> deleteAudioBox(String id) async {
    final db = await database;
    await db.delete(
      'audio_boxes',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveAudioBoxes(
      List<Map<String, dynamic>> audioBoxes, String documentName) async {
    final db = await database;

    try {
      await db.transaction((txn) async {
        await txn.delete(
          'audio_boxes',
          where: 'documentName = ?',
          whereArgs: [documentName],
        );

        for (var audioBox in audioBoxes) {
          if (validateAudioBoxData(audioBox)) {
            await txn.insert(
              'audio_boxes',
              audioBox,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } else {
            print('跳过无效的音频框数据: $audioBox');
          }
        }
      });

      print('成功保存�� ${audioBoxes.length} 个音频框到文档 $documentName');
    } catch (e) {
      print('保存音频框时出错: $e');
      throw e;
    }
  }

  Future<void> updateAudioBoxPosition(String id, Offset position) async {
    final db = await database;
    try {
      await db.update(
        'audio_boxes',
        {
          'positionX': position.dx,
          'positionY': position.dy,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      print('更新音频框位置时出错: $e');
      throw e;
    }
  }

  Future<void> updateAudioPath(String id, String audioPath) async {
    final db = await database;
    try {
      await db.update(
        'audio_boxes',
        {'audioPath': audioPath},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      print('更新音频路径时出错: $e');
      throw e;
    }
  }

  Future<void> ensureAudioBoxesTableExists() async {
    final db = await database;

    List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='audio_boxes';"
    );

    if (tables.isEmpty) {
      await db.execute('''
        CREATE TABLE audio_boxes(
          id TEXT PRIMARY KEY,
          documentName TEXT,
          positionX REAL,
          positionY REAL,
          audioPath TEXT
        )
      ''');
      print('创建了audio_boxes表');
    }
  }

  // 新增的 copyDocument 方法，用于完整复制文档及其相关数据
  Future<String> copyDocument(String oldName, {String? parentFolder, String? position}) async {
    final db = await database;

    try {
      // 检查原文档是否存在
      List<Map<String, dynamic>> docs = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [oldName],
      );

      if (docs.isEmpty) {
        throw Exception('Document not found: $oldName');
      }

      // 生成新文档名称，确保不重复
      String baseName = "$oldName - 副本";
      String newName = baseName;
      int copyNumber = 1;
      while (await doesNameExist(newName)) {
        copyNumber++;
        newName = "$baseName($copyNumber)";
      }

      // 1. 复制 documents 表中的记录
      var doc = Map<String, dynamic>.from(docs.first);
      doc['name'] = newName;
      doc['parentFolder'] = parentFolder ?? doc['parentFolder'];
      doc['position'] = position ?? doc['position'];

      // 获取目标文件夹的最大 order 值
      final List<Map<String, dynamic>> orderResult = await db.rawQuery('''
        SELECT MAX(`order`) as maxOrder FROM documents 
        WHERE parentFolder ${parentFolder == null ? 'IS NULL' : '= ?'}
      ''', parentFolder != null ? [parentFolder] : []);

      int order = (orderResult.first['maxOrder'] ?? -1) + 1;
      doc['order'] = order;

      await db.insert('documents', doc);

      // 2. 复制 text_boxes 表中的记录
      List<Map<String, dynamic>> textBoxes = await getTextBoxesByDocument(oldName);
      for (var textBox in textBoxes) {
        var newTextBox = Map<String, dynamic>.from(textBox);
        newTextBox['id'] = Uuid().v4(); // 生成新的 ID
        newTextBox['documentName'] = newName;
        await insertOrUpdateTextBox(newTextBox);
      }

      // 3. 复制 image_boxes 表中的记录
      List<Map<String, dynamic>> imageBoxes = await getImageBoxesByDocument(oldName);
      for (var imageBox in imageBoxes) {
        var newImageBox = Map<String, dynamic>.from(imageBox);
        newImageBox['id'] = Uuid().v4();
        newImageBox['documentName'] = newName;
        await insertOrUpdateImageBox(newImageBox);
      }

      // 4. 复制 audio_boxes 表中的记录
      List<Map<String, dynamic>> audioBoxes = await getAudioBoxesByDocument(oldName);
      for (var audioBox in audioBoxes) {
        var newAudioBox = Map<String, dynamic>.from(audioBox);
        newAudioBox['id'] = Uuid().v4();
        newAudioBox['documentName'] = newName;
        await insertOrUpdateAudioBox(newAudioBox);
      }

      // 5. 复制 document_settings 表中的记录
      Map<String, dynamic>? settings = await getDocumentSettings(oldName);
      if (settings != null) {
        await insertOrUpdateDocumentSettings(
          newName,
          imagePath: settings['background_image_path'],
          colorValue: settings['background_color'],
          textEnhanceMode: settings['text_enhance_mode'] == 1,
        );
      }

      print('成功复制文档: $oldName -> $newName');
      return newName; // 返回新文档的名称
    } catch (e) {
      print('复制文档时出错: $e');
      throw Exception('Failed to copy document: $e');
    }
  }

  Future<int> insertMediaItem(Map<String, dynamic> item) async {
    final db = await database;
    debugPrint('正在插入媒体项: ${item['name']}');
    
    try {
      // Ensure required fields are present
      final data = Map<String, dynamic>.from(item);
      final now = DateTime.now().millisecondsSinceEpoch;
      data['created_at'] ??= now;
      data['updated_at'] ??= now;
      
      final result = await db.insert(
        'media_items',
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      debugPrint('插入结果: $result');
      return result;
    } catch (e) {
      debugPrint('插入媒体项时出错: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> findDuplicateMediaItem(String fileHash, String fileName) async {
    final db = await database;
    
    // 首先通过文件哈希查找
    if (fileHash.isNotEmpty) {
      final List<Map<String, dynamic>> hashMatches = await db.query(
        'media_items',
        where: 'file_hash = ?',
        whereArgs: [fileHash],
      );
      if (hashMatches.isNotEmpty) {
        return hashMatches.first;
      }
    }
    
    // 如果没有找到哈希匹配，则通过文件名查找
    final List<Map<String, dynamic>> nameMatches = await db.query(
      'media_items',
      where: 'name = ?',
      whereArgs: [fileName],
    );
    if (nameMatches.isNotEmpty) {
      return nameMatches.first;
    }
    
    return null;
  }

  // 更新现有文件的哈希值
  Future<void> updateMediaItemHash(String id, String fileHash) async {
    final db = await database;
    await db.update(
      'media_items',
      {'file_hash': fileHash},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String?> getDocumentPath(String documentName, {String? parentFolder}) async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> result = await db.query(
        'documents',
        where: 'name = ? AND parentFolder ${parentFolder == null ? 'IS NULL' : '= ?'}',
        whereArgs: parentFolder == null ? [documentName] : [documentName, parentFolder],
      );

      if (result.isEmpty) {
        return null;
      }

      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String documentsPath = '${appDocDir.path}/documents';
      final String documentPath = '$documentsPath/$documentName.zip';

      if (await File(documentPath).exists()) {
        return documentPath;
      }
      return null;
    } catch (e) {
      print('获取文档路径时出错: $e');
      return null;
    }
  }

  Future<String> exportAllData() async {
    try {
      print('开始导出所有数据...');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String backupPath = '${appDocDir.path}/backups';
      print('备份路径: $backupPath');

      // 创建临时目录
      final String tempDirPath = '${backupPath}/temp_backup';
      final Directory tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      // 导出目录相关的数据库表
      final db = await database;
      final Map<String, List<Map<String, dynamic>>> tableData = {
        'folders': await db.query('folders'),
        'documents': await db.query('documents'),
        'text_boxes': await db.query('text_boxes'),
        'image_boxes': await db.query('image_boxes'),
        'audio_boxes': await db.query('audio_boxes'),
      };

      // 处理图片框数据和图片文件
      List<Map<String, dynamic>> imageBoxes = await db.query('image_boxes');
      List<Map<String, dynamic>> imageBoxesToExport = [];
      for (var imageBox in imageBoxes) {
        Map<String, dynamic> imageBoxCopy = Map<String, dynamic>.from(imageBox);
        String imagePath = imageBox['imagePath'];
        if (imagePath.isNotEmpty) {
          String fileName = p.basename(imagePath);
          imageBoxCopy['imageFileName'] = fileName;
          
          // 复制图片文件
          File imageFile = File(imagePath);
          if (await imageFile.exists()) {
            String relativePath = 'images/$fileName';
            await Directory('$tempDirPath/images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            print('已导出图片框图片: $relativePath');
          } else {
            print('警告：图片文件不存在: $imagePath');
          }
        }
        imageBoxesToExport.add(imageBoxCopy);
      }
      tableData['image_boxes'] = imageBoxesToExport;

      // 处理目录设置和背景图片
      List<Map<String, dynamic>> directorySettings = await db.query('directory_settings');
      List<Map<String, dynamic>> directorySettingsToExport = [];
      for (var settings in directorySettings) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        String? backgroundImagePath = settings['background_image_path'];
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          String fileName = p.basename(backgroundImagePath);
          settingsCopy['backgroundImageFileName'] = fileName;
          
          // 复制目录背景图片
          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory('$tempDirPath/background_images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            print('已导出目录背景图片: $relativePath');
          } else {
            print('警告：目录��景图片不存在: $backgroundImagePath');
          }
        }
        directorySettingsToExport.add(settingsCopy);
      }
      tableData['directory_settings'] = directorySettingsToExport;

      // 处理文档设置和背景图片
      List<Map<String, dynamic>> documentSettings = await db.query('document_settings');
      List<Map<String, dynamic>> documentSettingsToExport = [];
      for (var settings in documentSettings) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        String? backgroundImagePath = settings['background_image_path'];
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          String fileName = p.basename(backgroundImagePath);
          settingsCopy['backgroundImageFileName'] = fileName;
          
          // 复制文档背景图片
          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory('$tempDirPath/background_images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            print('已导出文档背景图片: $relativePath');
          } else {
            print('警告：文档背景图片不存在: $backgroundImagePath');
          }
        }
        documentSettingsToExport.add(settingsCopy);
      }
      tableData['document_settings'] = documentSettingsToExport;

      // 处理音频框数据和音频文件
      List<Map<String, dynamic>> audioBoxes = await db.query('audio_boxes');
      List<Map<String, dynamic>> audioBoxesToExport = [];
      for (var audioBox in audioBoxes) {
        Map<String, dynamic> audioBoxCopy = Map<String, dynamic>.from(audioBox);
        String audioPath = audioBox['audioPath'];
        if (audioPath.isNotEmpty) {
          String fileName = p.basename(audioPath);
          audioBoxCopy['audioFileName'] = fileName;
          
          // 复制音频文件
          File audioFile = File(audioPath);
          if (await audioFile.exists()) {
            String relativePath = 'audios/$fileName';
            await Directory('$tempDirPath/audios').create(recursive: true);
            await audioFile.copy('$tempDirPath/$relativePath');
            print('已导出音频文件: $relativePath');
          } else {
            print('警告：音频文件不存在: $audioPath');
          }
        }
        audioBoxesToExport.add(audioBoxCopy);
      }
      tableData['audio_boxes'] = audioBoxesToExport;

      // 将数据库表数据保存为JSON文件
      final File dbDataFile = File('$tempDirPath/directory_data.json');
      await dbDataFile.writeAsString(jsonEncode(tableData));

      // 创建ZIP文件
      final String timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '');
      final String zipPath = '$backupPath/directory_backup_$timestamp.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(Directory(tempDirPath), includeDirName: false);
      encoder.close();

      // 清理临时目录
      await tempDir.delete(recursive: true);

      print('所有数据导出完成，ZIP文件路径: $zipPath');
      return zipPath;
    } catch (e) {
      print('导出目录数据时出错: $e');
      print('错误堆栈: ${StackTrace.current}');
      rethrow;
    }
  }

  Future<void> importAllData(String zipPath) async {
    try {
      print('开始导入所有数据...');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String tempDirPath = '${appDocDir.path}/temp_import';
      print('临时目录路径: $tempDirPath');

      // 清理临时目录
      if (await Directory(tempDirPath).exists()) {
        await Directory(tempDirPath).delete(recursive: true);
      }
      await Directory(tempDirPath).create(recursive: true);

      // 解压ZIP文件
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (var file in archive) {
        final String filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          File('$tempDirPath/$filename')
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
        }
      }

      // 读取目录数据
      final File dbDataFile = File('$tempDirPath/directory_data.json');
      if (!await dbDataFile.exists()) {
        throw Exception('备份中未找到目录数据文件');
      }

      final Map<String, dynamic> tableData = jsonDecode(await dbDataFile.readAsString());
      final db = await database;

      // 准备背景图片目录
      final String backgroundImagesPath = '${appDocDir.path}/background_images';
      await Directory(backgroundImagesPath).create(recursive: true);

      await db.transaction((txn) async {
        // 清除现有数据
        await txn.delete('folders');
        await txn.delete('documents');
        await txn.delete('text_boxes');
        await txn.delete('image_boxes');
        await txn.delete('audio_boxes');
        await txn.delete('document_settings');
        await txn.delete('directory_settings');

        // 导入新数据
        for (var entry in tableData.entries) {
          final String tableName = entry.key;
          final List<dynamic> rows = entry.value;
          print('处理表: $tableName, 行数: ${rows.length}');

          if (tableName == 'directory_settings') {
            for (var row in rows) {
              Map<String, dynamic> settings = Map<String, dynamic>.from(row);
              String? fileName = settings.remove('backgroundImageFileName');
              if (fileName != null) {
                // 复制背景图片到新位置
                String newPath = p.join(backgroundImagesPath, fileName);
                String tempPath = p.join(tempDirPath, 'background_images', fileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  settings['background_image_path'] = newPath;
                  print('已导入目录背景图片: $newPath');
                }
              }
              await txn.insert(tableName, settings);
            }
          } else if (tableName == 'document_settings') {
            for (var row in rows) {
              Map<String, dynamic> settings = Map<String, dynamic>.from(row);
              String? fileName = settings.remove('backgroundImageFileName');
              if (fileName != null) {
                // 复制背景图片到新位置
                String newPath = p.join(backgroundImagesPath, fileName);
                String tempPath = p.join(tempDirPath, 'background_images', fileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  settings['background_image_path'] = newPath;
                  print('已导入文档背景图片: $newPath');
                }
              }
              await txn.insert(tableName, settings);
            }
          } else if (tableName == 'image_boxes') {
            for (var row in rows) {
              Map<String, dynamic> imageBox = Map<String, dynamic>.from(row);
              String? imageFileName = imageBox.remove('imageFileName');
              if (imageFileName != null) {
                // 复制图片文件到新位置
                String imagesDirPath = p.join(appDocDir.path, 'images');
                await Directory(imagesDirPath).create(recursive: true);
                String newPath = p.join(imagesDirPath, imageFileName);
                String tempPath = p.join(tempDirPath, 'images', imageFileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  imageBox['imagePath'] = newPath;
                  print('已导入图片框图片: $newPath');
                }
              }
              await txn.insert(tableName, imageBox);
            }
          } else if (tableName == 'audio_boxes') {
            for (var row in rows) {
              Map<String, dynamic> audioBox = Map<String, dynamic>.from(row);
              String? audioFileName = audioBox.remove('audioFileName');
              if (audioFileName != null) {
                // 复制音频文件到新位置
                String audiosDirPath = p.join(appDocDir.path, 'audios');
                await Directory(audiosDirPath).create(recursive: true);
                String newPath = p.join(audiosDirPath, audioFileName);
                String tempPath = p.join(tempDirPath, 'audios', audioFileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  audioBox['audioPath'] = newPath;
                  print('已导入音频文件: $newPath');
                }
              }
              await txn.insert(tableName, audioBox);
            }
          } else {
            // 其他表正常导入（folders, documents, text_boxes）
            for (var row in rows) {
              await txn.insert(tableName, Map<String, dynamic>.from(row));
            }
          }
        }
      });

      // 清理临时目录
      await Directory(tempDirPath).delete(recursive: true);
      print('所有数据导入完成');
    } catch (e) {
      print('导入目录数据时出错: $e');
      print('错误堆��: ${StackTrace.current}');
      rethrow;
    }
  }
}

