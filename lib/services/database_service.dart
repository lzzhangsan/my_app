// lib/services/database_service.dart
// 重构后的数据库服务 - 提供更好的性能和错误处理

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';
import '../core/app_state.dart';
import '../core/service_locator.dart';

/// 数据库服务 - 统一管理所有数据库操作
class DatabaseService {
  static const String _databaseName = 'change_app.db';
  static const int _databaseVersion = 8;
  
  Database? _database;
  final Completer<Database> _initCompleter = Completer<Database>();
  bool _isInitialized = false;
  
  /// 数据库连接池
  final Map<String, Database> _connectionPool = {};
  
  /// 事务队列
  final List<Future<void> Function(Transaction)> _transactionQueue = [];
  final bool _isProcessingTransactions = false;

  /// 初始化数据库服务
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      final documentsDirectory = await getApplicationDocumentsDirectory();
      final dbPath = p.join(documentsDirectory.path, _databaseName);
      
      _database = await openDatabase(
        dbPath,
        version: _databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: _onConfigure,
      );
      
      _initCompleter.complete(_database!);
      _isInitialized = true;
      
      // 启动性能监控
      _startPerformanceMonitoring();
      
      if (kDebugMode) {
        print('DatabaseService: 数据库初始化完成');
      }
    } catch (e, stackTrace) {
      _handleError('数据库初始化失败', e, stackTrace);
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  /// 获取数据库实例
  Future<Database> get database async {
    if (!_isInitialized) {
      return _initCompleter.future;
    }
    return _database!;
  }

  /// 配置数据库连接
  Future<void> _onConfigure(Database db) async {
    try {
      // 启用外键约束
      await db.execute('PRAGMA foreign_keys = ON');
      // 设置同步模式 - 使用NORMAL而不是FULL以提高性能
      await db.execute('PRAGMA synchronous = NORMAL');
      // 设置缓存大小 - 增加缓存以提高性能
      await db.execute('PRAGMA cache_size = 10000');
      // 设置临时存储在内存中
      await db.execute('PRAGMA temp_store = MEMORY');
      // 设置页面大小
      await db.execute('PRAGMA page_size = 4096');
      // 设置自动清理
      await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
      
      if (kDebugMode) {
        print('数据库配置成功应用');
      }
    } catch (e, stackTrace) {
      _handleError('配置数据库连接失败', e, stackTrace);
      if (kDebugMode) {
        print('配置数据库连接失败: $e');
      }
      rethrow;
    }
  }

  /// 创建数据库表
  Future<void> _onCreate(Database db, int version) async {
    await db.transaction((txn) async {
      // 文件夹表
      await txn.execute('''
        CREATE TABLE folders(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          parent_folder TEXT,
          order_index INTEGER DEFAULT 0,
          position TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (parent_folder) REFERENCES folders (id) ON DELETE CASCADE
        )
      ''');

      // 文档表
      await txn.execute('''
        CREATE TABLE documents(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          parent_folder TEXT,
          order_index INTEGER DEFAULT 0,
          is_template INTEGER DEFAULT 0,
          position TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (parent_folder) REFERENCES folders (id) ON DELETE CASCADE
        )
      ''');

      // 文本框表
      await txn.execute('''
        CREATE TABLE text_boxes(
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL,
          position_x REAL NOT NULL,
          position_y REAL NOT NULL,
          width REAL NOT NULL,
          height REAL NOT NULL,
          content TEXT NOT NULL,
          font_size REAL DEFAULT 14.0,
          font_color INTEGER DEFAULT 4278190080,
          font_family TEXT DEFAULT 'Roboto',
          font_weight INTEGER DEFAULT 0,
          is_italic INTEGER DEFAULT 0,
          is_underlined INTEGER DEFAULT 0,
          is_strike_through INTEGER DEFAULT 0,
          background_color INTEGER,
          text_align INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
        )
      ''');

      // 图片框表
      await txn.execute('''
        CREATE TABLE image_boxes(
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL,
          position_x REAL NOT NULL,
          position_y REAL NOT NULL,
          width REAL NOT NULL,
          height REAL NOT NULL,
          image_path TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
        )
      ''');

      // 音频框表
      await txn.execute('''
        CREATE TABLE audio_boxes(
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL,
          position_x REAL NOT NULL,
          position_y REAL NOT NULL,
          audio_path TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
        )
      ''');

      // 媒体项表
      await txn.execute('''
        CREATE TABLE media_items(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          type INTEGER NOT NULL,
          directory TEXT NOT NULL,
          date_added TEXT NOT NULL,
          file_size INTEGER DEFAULT 0,
          duration INTEGER DEFAULT 0,
          thumbnail_path TEXT,
          file_hash TEXT,
          is_favorite INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      // 文档设置表
      await txn.execute('''
        CREATE TABLE document_settings(
          document_id TEXT PRIMARY KEY,
          background_image_path TEXT,
          background_color INTEGER,
          text_enhance_mode INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
        )
      ''');

      // 应用设置表
      await txn.execute('''
        CREATE TABLE app_settings(
          key TEXT PRIMARY KEY,
          value TEXT,
          type TEXT DEFAULT 'string',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      // 目录设置表
      await txn.execute('''
        CREATE TABLE directory_settings(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          folder_name TEXT,
          background_image_path TEXT,
          background_color INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      // 封面图片表
      await txn.execute('''
        CREATE TABLE cover_image(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT,
          timestamp INTEGER
        )
      ''');

      // 创建索引以提高查询性能
      await _createIndexes(txn);
    });
  }

  /// 创建数据库索引
  Future<void> _createIndexes(DatabaseExecutor db) async {
    await db.execute('CREATE INDEX idx_folders_parent ON folders(parent_folder)');
    await db.execute('CREATE INDEX idx_documents_parent ON documents(parent_folder)');
    await db.execute('CREATE INDEX idx_text_boxes_document ON text_boxes(document_id)');
    await db.execute('CREATE INDEX idx_image_boxes_document ON image_boxes(document_id)');
    await db.execute('CREATE INDEX idx_audio_boxes_document ON audio_boxes(document_id)');
    await db.execute('CREATE INDEX idx_media_items_directory ON media_items(directory)');
    await db.execute('CREATE INDEX idx_media_items_type ON media_items(type)');
    await db.execute('CREATE INDEX idx_media_items_hash ON media_items(file_hash)');
  }

  /// 数据库升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (kDebugMode) {
      print('DatabaseService: 升级数据库从版本 $oldVersion 到 $newVersion');
    }
    
    await db.transaction((txn) async {
      // 根据版本进行增量升级
      for (int version = oldVersion + 1; version <= newVersion; version++) {
        await _upgradeToVersion(txn, version);
      }
    });
  }

  /// 升级到指定版本
  Future<void> _upgradeToVersion(DatabaseExecutor db, int version) async {
    switch (version) {
      case 8:
        // 添加新的字段和索引
        await db.execute('ALTER TABLE media_items ADD COLUMN file_size INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE media_items ADD COLUMN duration INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE media_items ADD COLUMN thumbnail_path TEXT');
        await db.execute('ALTER TABLE media_items ADD COLUMN file_hash TEXT');
        await db.execute('ALTER TABLE media_items ADD COLUMN is_favorite INTEGER DEFAULT 0');
        await _createIndexes(db);
        break;
    }
  }

  /// 启动性能监控
  void _startPerformanceMonitoring() {
    if (kDebugMode) {
      Timer.periodic(const Duration(minutes: 5), (timer) {
        _analyzePerformance();
      });
    }
  }

  /// 分析数据库性能
  Future<void> _analyzePerformance() async {
    try {
      final db = await database;
      final result = await db.rawQuery('PRAGMA quick_check');
      
      if (result.isNotEmpty && result.first['quick_check'] != 'ok') {
        _handleError('数据库完整性检查失败', Exception('Database integrity check failed'), null);
      }
      
      // 检查数据库大小
      final sizeResult = await db.rawQuery('PRAGMA page_count');
      final pageSize = await db.rawQuery('PRAGMA page_size');
      
      if (sizeResult.isNotEmpty && pageSize.isNotEmpty) {
        final dbSize = (sizeResult.first['page_count'] as int) * (pageSize.first['page_size'] as int);
        getService<AppPerformanceState>().addPerformanceLog('数据库大小: ${(dbSize / 1024 / 1024).toStringAsFixed(2)} MB');
      }
    } catch (e) {
      if (kDebugMode) {
        print('DatabaseService: 性能分析失败 - $e');
      }
    }
  }

  /// 处理错误
  void _handleError(String title, dynamic error, StackTrace? stackTrace) {
    final appError = AppError(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      message: error.toString(),
      timestamp: DateTime.now(),
      severity: ErrorSeverity.high,
      stackTrace: stackTrace,
    );
    
    if (serviceLocator.isRegistered<AppErrorState>()) {
      getService<AppErrorState>().addError(appError);
    }
    
    if (kDebugMode) {
      print('DatabaseService Error: $title - $error');
      if (stackTrace != null) {
        print('StackTrace: $stackTrace');
      }
    }
  }

  /// 清理资源
  Future<void> dispose() async {
    try {
      if (_database != null) {
        await _database!.close();
        _database = null;
      }
      
      // 清理连接池
      for (final db in _connectionPool.values) {
        await db.close();
      }
      _connectionPool.clear();
      
      _isInitialized = false;
      
      if (kDebugMode) {
        print('DatabaseService: 资源清理完成');
      }
    } catch (e) {
      if (kDebugMode) {
        print('DatabaseService dispose error: $e');
      }
    }
  }

  /// 执行事务
  Future<T> transaction<T>(Future<T> Function(Transaction) action) async {
    final db = await database;
    return await db.transaction(action);
  }

  /// 批量执行操作
  Future<void> batch(void Function(Batch) operations) async {
    final db = await database;
    final batch = db.batch();
    operations(batch);
    await batch.commit(noResult: true);
  }

  /// 确保媒体��表存在
  Future<void> ensureMediaItemsTableExists() async {
    try {
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
    } catch (e, stackTrace) {
      _handleError('确保媒体项表存在失败', e, stackTrace);
      rethrow;
    }
  }

  /// 获取媒体项的父目录
  Future<String?> getMediaItemParentDirectory(String mediaItemId) async {
    try {
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
    } catch (e, stackTrace) {
      _handleError('获取媒体项父目录失败', e, stackTrace);
      rethrow;
    }
  }

  /// 获取媒体项
  Future<List<Map<String, dynamic>>> getMediaItems(String directory) async {
    try {
      final db = await database;
      return await db.query(
        'media_items',
        where: 'directory = ?',
        whereArgs: [directory],
        orderBy: 'name ASC',
      );
    } catch (e, stackTrace) {
      _handleError('获取媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 插入媒体项目
  Future<int> insertMediaItem(Map<String, dynamic> item) async {
    try {
      final db = await database;
      if (kDebugMode) {
        print('正在插入媒体项: ${item['name']}');
      }
      
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
      
      if (kDebugMode) {
        print('插入结果: $result');
      }
      return result;
    } catch (e, stackTrace) {
      _handleError('插入媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 查找重复的媒体项目
  Future<Map<String, dynamic>?> findDuplicateMediaItem(String fileHash, String fileName) async {
    try {
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
    } catch (e, stackTrace) {
      _handleError('查找重复媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 根据ID获取媒体项目
  Future<Map<String, dynamic>?> getMediaItemById(String id) async {
    try {
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
    } catch (e, stackTrace) {
      _handleError('根据ID获取媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 删除媒体项
  Future<int> deleteMediaItem(String id) async {
    try {
      final db = await database;
      return await db.delete('media_items', where: 'id = ?', whereArgs: [id]);
    } catch (e, stackTrace) {
      _handleError('删除媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 更新媒体项
  Future<int> updateMediaItem(Map<String, dynamic> item) async {
    try {
      final db = await database;
      return await db.update(
        'media_items',
        item,
        where: 'id = ?',
        whereArgs: [item['id']],
      );
    } catch (e, stackTrace) {
      _handleError('更新媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 更新媒体项目录
  Future<int> updateMediaItemDirectory(String id, String directory) async {
    try {
      final db = await database;
      return await db.update(
        'media_items', 
        {'directory': directory},
        where: 'id = ?',
        whereArgs: [id]
      );
    } catch (e, stackTrace) {
      _handleError('更新媒体项目录失败', e, stackTrace);
      rethrow;
    }
  }

  /// 更新媒体项哈希值
  Future<void> updateMediaItemHash(String id, String fileHash) async {
    try {
      final db = await database;
      await db.update(
        'media_items',
        {'file_hash': fileHash},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stackTrace) {
      _handleError('更新媒体项哈希值失败', e, stackTrace);
      rethrow;
    }
  }

  /// 验证文本框数据
  bool validateTextBoxData(Map<String, dynamic> data) {
    if (data['id'] == null) {
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

  /// 备份数据库
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

  /// 更新文件夹的父文件夹
  Future<void> updateFolderParentFolder(
      String folderName, String? newParentFolder) async {
    try {
      // 获取目标文件夹的ID
      String? targetFolderId;
      if (newParentFolder != null) {
        Map<String, dynamic>? targetFolder = await getFolderByName(newParentFolder);
        if (targetFolder == null) {
          throw Exception('目标文件夹不存在: $newParentFolder');
        }
        targetFolderId = targetFolder['id'];
      }
      
      // 检查源文件夹是否存在
      Map<String, dynamic>? sourceFolder = await getFolderByName(folderName);
      if (sourceFolder == null) {
        throw Exception('源文件夹不存在: $folderName');
      }
      
      final db = await database;
      
      // 使用事务确保操作的原子性
      await db.transaction((txn) async {
        List<Map<String, dynamic>> result = await txn.rawQuery(
          'SELECT MAX(`order_index`) as maxOrder FROM folders WHERE parent_folder ${targetFolderId == null ? 'IS NULL' : '= ?'}',
          targetFolderId == null ? null : [targetFolderId],
        );
        int maxOrder =
        result.first['maxOrder'] != null ? result.first['maxOrder'] as int : 0;

        int updatedRows = await txn.update(
          'folders',
          {
            'parent_folder': targetFolderId,
            'order_index': maxOrder + 1,
          },
          where: 'name = ?',
          whereArgs: [folderName],
        );
        
        if (updatedRows == 0) {
          throw Exception('未能更新文件夹: $folderName');
        }
      });
    } catch (e, stackTrace) {
      _handleError('更新文件夹父文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// 更新文档的父文件夹
  Future<void> updateDocumentParentFolder(
      String documentName, String? newParentFolder) async {
    try {
      String? targetFolderId;
      if (newParentFolder != null) {
        final folder = await getFolderByName(newParentFolder);
        targetFolderId = folder?['id'];
      }
      final db = await database;
      await db.transaction((txn) async {
        List<Map<String, dynamic>> result = await txn.rawQuery(
          'SELECT MAX(`order_index`) as maxOrder FROM documents WHERE parent_folder ${targetFolderId == null ? 'IS NULL' : '= ?'}',
          targetFolderId == null ? null : [targetFolderId],
        );
        int maxOrder = result.first['maxOrder'] != null ? result.first['maxOrder'] as int : 0;
        int updatedRows = await txn.update(
          'documents',
          {
            'parent_folder': targetFolderId,
            'order_index': maxOrder + 1,
          },
          where: 'name = ?',
          whereArgs: [documentName],
        );
        if (updatedRows == 0) {
          throw Exception('未能更新文档: $documentName');
        }
      });
    } catch (e, stackTrace) {
      _handleError('更新文档父文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// 导出目录数据
  Future<String> exportDirectoryData() async {
    try {
      print('开始导出目录数据...');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String backupPath = '${appDocDir.path}/backups';
      print('备份路径: $backupPath');

      // 创建临时目录
      final String tempDirPath = '$backupPath/temp_backup';
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
        String? imagePath = imageBox['imagePath'];
        if (imagePath != null && imagePath.isNotEmpty) {
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
            print('警告：目录背景图片不存在: $backgroundImagePath');
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
        String? audioPath = audioBox['audioPath'];
        if (audioPath != null && audioPath.isNotEmpty) {
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
      await ZipFileEncoder().zipDirectory(Directory(tempDirPath), filename: zipPath);

      // 清理临时目录
      await tempDir.delete(recursive: true);

      print('目录数据导出完成，ZIP文件路径: $zipPath');
      return zipPath;
    } catch (e, stackTrace) {
      _handleError('导出目录数据失败', e, stackTrace);
      rethrow;
    }
  }
  
  /// 导入目录数据
  Future<void> importDirectoryData(String zipPath) async {
    try {
      print('开始导入目录数据...');
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
            // 其他表直接插入
            for (var row in rows) {
              await txn.insert(tableName, Map<String, dynamic>.from(row));
            }
          }
        }
      });

      // 清理临时目录
      await Directory(tempDirPath).delete(recursive: true);

      print('目录数据导入完成');
    } catch (e, stackTrace) {
      print('导入目录数据时出错: $e');
      print('错误堆栈: $stackTrace');
      _handleError('导入目录数据失败', e, stackTrace);
      rethrow;
    }
  }
  
  // 保留原来的方法名称，但内部调用新方法，以保持兼容性
  Future<String> exportAllData() async {
    return exportDirectoryData();
  }
  
  Future<void> importAllData(String zipPath) async {
    return importDirectoryDataImpl(zipPath);
  }

  // ==================== 文档和文件夹管理方法 ====================

  Future<void> deleteDocument(String documentName, {String? parentFolder}) async {
    final db = await database;
    await db.delete(
      'documents',
      where: 'name = ?',
      whereArgs: [documentName],
    );
    // 首先获取文档ID
    List<Map<String, dynamic>> documents = await db.query(
      'documents',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [documentName],
    );
    
    if (documents.isNotEmpty) {
      String documentId = documents.first['id'];
      
      await db.delete(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      await db.delete(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      await db.delete(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );

      await db.delete(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
    }

    List<Map<String, dynamic>> remainingDocuments = await db.query(
      'documents',
      where: parentFolder == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
      whereArgs: parentFolder == null ? null : [parentFolder],
      orderBy: 'order_index ASC',
    );
    for (int i = 0; i < remainingDocuments.length; i++) {
      await db.update(
        'documents',
        {'order_index': i},
        where: 'name = ?',
        whereArgs: [remainingDocuments[i]['name']],
      );
    }
  }

  Future<void> deleteDocumentBackgroundImage(String documentName) async {
    final db = await database;
    try {
      // 首先获取文档ID
      final List<Map<String, dynamic>> docs = await db.query(
        'documents',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [documentName],
      );
      
      if (docs.isNotEmpty) {
        String documentId = docs.first['id'];
        await db.update(
          'document_settings',
          {'background_image_path': null},
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        print('Background image path deleted for document: $documentName');
      } else {
        print('Document not found: $documentName');
      }
    } catch (e, stackTrace) {
      _handleError('Failed to delete document background image for $documentName', e, stackTrace);
      rethrow;
    }
  }

  Future<void> deleteFolder(String folderName, {String? parentFolder}) async {
    final db = await database;
    await db.delete(
      'folders',
      where: 'name = ?',
      whereArgs: [folderName],
    );

    List<Map<String, dynamic>> documents = await getDocuments(parentFolder: folderName);
    for (var doc in documents) {
      await deleteDocument(doc['name'], parentFolder: folderName);
    }

    List<Map<String, dynamic>> subFolders = await getFolders(parentFolder: folderName);
    for (var subFolder in subFolders) {
      await deleteFolder(subFolder['name'], parentFolder: folderName);
    }

    List<Map<String, dynamic>> remainingFolders = await getFolders(parentFolder: parentFolder);
    for (int i = 0; i < remainingFolders.length; i++) {
      await db.update(
        'folders',
        {'order_index': i},
        where: 'name = ?',
        whereArgs: [remainingFolders[i]['name']],
      );
    }
  }



  Future<List<Map<String, dynamic>>> getFolders({String? parentFolder}) async {
    final db = await database;
    try {
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
      }
      List<Map<String, dynamic>> result = await db.query(
        'folders',
        where: parentFolderId == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
        whereArgs: parentFolderId == null ? null : [parentFolderId],
        orderBy: 'order_index ASC',
      );
      return result.map((map) => Map<String, dynamic>.from(map)).toList();
    } catch (e) {
      print('获取文件夹时出错: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getDocuments({String? parentFolder}) async {
    final db = await database;
    try {
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
      }
      return await db.query(
        'documents',
        where: parentFolderId == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
        whereArgs: parentFolderId == null ? null : [parentFolderId],
        orderBy: 'order_index ASC',
      );
    } catch (e, stackTrace) {
      _handleError('获取文档时出错', e, stackTrace);
      print('获取文档时出错: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getFolderByName(String folderName) async {
    final db = await database;
    try {
      List<Map<String, dynamic>> result = await db.query(
        'folders',
        where: 'name = ?',
        whereArgs: [folderName],
      );
      if (result.isNotEmpty) {
        return result.first;
      }
      return null;
    } catch (e) {
      print('根据名称获取文件夹时出错: $e');
      return null;
    }
  }
  
  Future<Map<String, dynamic>?> getDocumentByName(String documentName) async {
    final db = await database;
    try {
      List<Map<String, dynamic>> result = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [documentName],
      );
      if (result.isNotEmpty) {
        return result.first;
      }
      return null;
    } catch (e) {
      print('根据名称获取文档时出错: $e');
      return null;
    }
  }

  Future<String> exportDocument(String documentName) async {
    try {
      print('开始导出文档: $documentName');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String backupPath = '${appDocDir.path}/backups';
      
      // 创建备份目录
      await Directory(backupPath).create(recursive: true);
      
      // 创建临时目录
      final String tempDirPath = '$backupPath/temp_document_export';
      final Directory tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);
      
      final db = await database;
      
      // 获取文档信息
      List<Map<String, dynamic>> documents = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [documentName],
      );
      
      if (documents.isEmpty) {
        throw Exception('文档不存在: $documentName');
      }
      
      String documentId = documents.first['id'];
      
      // 导出文档相关的数据
      final Map<String, List<Map<String, dynamic>>> documentData = {
        'documents': documents,
        'text_boxes': await db.query(
          'text_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        ),
        'image_boxes': await db.query(
          'image_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        ),
        'audio_boxes': await db.query(
          'audio_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        ),
        'document_settings': await db.query(
          'document_settings',
          where: 'document_id = ?',
          whereArgs: [documentId],
        ),
      };
      
      // 处理图片框数据和图片文件
      List<Map<String, dynamic>> imageBoxesToExport = [];
      for (var imageBox in documentData['image_boxes']!) {
        Map<String, dynamic> imageBoxCopy = Map<String, dynamic>.from(imageBox);
        String imagePath = imageBox['imagePath'] ?? imageBox['image_path'] ?? '';
        if (imagePath.isNotEmpty) {
          String fileName = p.basename(imagePath);
          imageBoxCopy['imageFileName'] = fileName;
          
          // 复制图片文件
          File imageFile = File(imagePath);
          if (await imageFile.exists()) {
            String relativePath = 'images/$fileName';
            await Directory('$tempDirPath/images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            print('已导出图片: $relativePath');
          } else {
            print('警告：图片文件不存在: $imagePath');
          }
        }
        imageBoxesToExport.add(imageBoxCopy);
      }
      documentData['image_boxes'] = imageBoxesToExport;
      
      // 处理音频框数据和音频文件
      List<Map<String, dynamic>> audioBoxesToExport = [];
      for (var audioBox in documentData['audio_boxes']!) {
        Map<String, dynamic> audioBoxCopy = Map<String, dynamic>.from(audioBox);
        String audioPath = audioBox['audioPath'] ?? audioBox['audio_path'] ?? '';
        if (audioPath.isNotEmpty) {
          String fileName = p.basename(audioPath);
          audioBoxCopy['audioFileName'] = fileName;
          
          // 复制音频文件
          File audioFile = File(audioPath);
          if (await audioFile.exists()) {
            String relativePath = 'audios/$fileName';
            await Directory('$tempDirPath/audios').create(recursive: true);
            await audioFile.copy('$tempDirPath/$relativePath');
            print('已导出音频: $relativePath');
          } else {
            print('警告：音频文件不存在: $audioPath');
          }
        }
        audioBoxesToExport.add(audioBoxCopy);
      }
      documentData['audio_boxes'] = audioBoxesToExport;
      
      // 处理文档设置和背景图片
      List<Map<String, dynamic>> documentSettingsToExport = [];
      for (var settings in documentData['document_settings']!) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        String? backgroundImagePath = settings['background_image_path'];
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          String fileName = p.basename(backgroundImagePath);
          settingsCopy['backgroundImageFileName'] = fileName;
          
          // 复制背景图片
          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory('$tempDirPath/background_images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            print('已导出背景图片: $relativePath');
          } else {
            print('警告：背景图片不存在: $backgroundImagePath');
          }
        }
        documentSettingsToExport.add(settingsCopy);
      }
      documentData['document_settings'] = documentSettingsToExport;
      
      // 将数据保存为JSON文件
      final File dataFile = File('$tempDirPath/document_data.json');
      await dataFile.writeAsString(jsonEncode(documentData));
      
      // 创建ZIP文件 - 使用人性化的时间格式
      final DateTime now = DateTime.now();
      final String formattedTime = '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final String zipPath = '$backupPath/$documentName-$formattedTime.zip';
      await ZipFileEncoder().zipDirectory(Directory(tempDirPath), filename: zipPath);
      
      // 清理临时目录
      await tempDir.delete(recursive: true);
      
      print('文档导出完成: $zipPath');
      return zipPath;
    } catch (e, stackTrace) {
      _handleError('导出文档失败', e, stackTrace);
      rethrow;
    }
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

  Future<void> importDocument(String zipPath, {String? targetDocumentName, String? targetParentFolder}) async {
    try {
      print('开始导入文档: $zipPath');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String tempDirPath = '${appDocDir.path}/temp_import';
      final Directory tempDir = Directory(tempDirPath);
      
      // 清理并创建临时目录
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);
      
      // 解压ZIP文件
      final Archive archive = ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          File('$tempDirPath/$filename')
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
        } else {
          Directory('$tempDirPath/$filename').create(recursive: true);
        }
      }
      
      // 读取文档数据
      final File dataFile = File('$tempDirPath/document_data.json');
      if (!await dataFile.exists()) {
        throw Exception('导入文件格式错误：缺少document_data.json');
      }
      
      final String jsonContent = await dataFile.readAsString();
      final Map<String, dynamic> importData = jsonDecode(jsonContent);
      
      final db = await database;
      
      await db.transaction((txn) async {
        // 处理文档数据
        List<dynamic> documents = importData['documents'] ?? [];
        if (documents.isEmpty) {
          throw Exception('导入文件中没有找到文档数据');
        }
        
        Map<String, dynamic> documentData = Map<String, dynamic>.from(documents.first);
        String originalDocumentId = documentData['id'];
        String newDocumentId = const Uuid().v4();
        
        // 设置文档名称
        String finalDocumentName = targetDocumentName ?? documentData['name'] ?? p.basenameWithoutExtension(zipPath);
        
        // 检查名称冲突并生成唯一名称 - 使用人性化的副本格式
        String uniqueName = finalDocumentName;
        int attempt = 0;
        String baseName = '$finalDocumentName-副本';
        while (true) {
          // 在事务内部检查名称是否存在
          List<Map<String, dynamic>> folders = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [uniqueName],
          );
          List<Map<String, dynamic>> documents = await txn.query(
            'documents',
            where: 'name = ?',
            whereArgs: [uniqueName],
          );
          if (folders.isEmpty && documents.isEmpty) {
            break;
          }
          // 如果原名已存在，使用"原名-副本"格式
          if (attempt == 0) {
            uniqueName = baseName;
          } else {
            // 如果"原名-副本"也存在，使用"原名-副本(序号)"格式
            uniqueName = '$baseName($attempt)';
          }
          attempt++;
          if (attempt > 100) {
            throw Exception('无法生成唯一的文档名称');
          }
        }
        
        // 设置父文件夹
        String? parentFolderId;
        if (targetParentFolder != null) {
          List<Map<String, dynamic>> folders = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [targetParentFolder],
          );
          if (folders.isNotEmpty) {
            parentFolderId = folders.first['id'];
          }
        }
        
        // 插入文档
        documentData['id'] = newDocumentId;
        documentData['name'] = uniqueName;
        documentData['parent_folder'] = parentFolderId;
        documentData['created_at'] = DateTime.now().toIso8601String();
        documentData['updated_at'] = DateTime.now().toIso8601String();
        
        // 移除可能存在的错误字段名
        documentData.remove('parent_folder_id');
        
        await txn.insert('documents', documentData);
        print('已导入文档: $uniqueName');
        
        // 处理文本框
        List<dynamic> textBoxes = importData['text_boxes'] ?? [];
        for (var textBox in textBoxes) {
          Map<String, dynamic> textBoxData = Map<String, dynamic>.from(textBox);
          textBoxData['id'] = const Uuid().v4();
          textBoxData['document_id'] = newDocumentId;
          await txn.insert('text_boxes', textBoxData);
        }
        print('已导入 ${textBoxes.length} 个文本框');
        
        // 处理图片框和图片文件
        List<dynamic> imageBoxes = importData['image_boxes'] ?? [];
        for (var imageBox in imageBoxes) {
          Map<String, dynamic> imageBoxData = Map<String, dynamic>.from(imageBox);
          String newImageBoxId = const Uuid().v4();
          imageBoxData['id'] = newImageBoxId;
          imageBoxData['document_id'] = newDocumentId;
          
          // 处理图片文件
          String? imageFileName = imageBoxData['imageFileName'];
          if (imageFileName != null && imageFileName.isNotEmpty) {
            String sourcePath = '$tempDirPath/images/$imageFileName';
            File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              String targetPath = '${appDocDir.path}/images/$newImageBoxId.${p.extension(imageFileName).substring(1)}';
              await Directory(p.dirname(targetPath)).create(recursive: true);
              await sourceFile.copy(targetPath);
              imageBoxData['image_path'] = targetPath;
              print('已导入图片: $imageFileName -> $targetPath');
            }
          }
          
          // 移除临时字段和错误字段名
          imageBoxData.remove('imageFileName');
          imageBoxData.remove('imagePath');
          await txn.insert('image_boxes', imageBoxData);
        }
        print('已导入 ${imageBoxes.length} 个图片框');
        
        // 处理音频框和音频文件
        List<dynamic> audioBoxes = importData['audio_boxes'] ?? [];
        for (var audioBox in audioBoxes) {
          Map<String, dynamic> audioBoxData = Map<String, dynamic>.from(audioBox);
          String newAudioBoxId = const Uuid().v4();
          audioBoxData['id'] = newAudioBoxId;
          audioBoxData['document_id'] = newDocumentId;
          
          // 处理音频文件
          String? audioFileName = audioBoxData['audioFileName'];
          if (audioFileName != null && audioFileName.isNotEmpty) {
            String sourcePath = '$tempDirPath/audios/$audioFileName';
            File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              String targetPath = '${appDocDir.path}/audios/$newAudioBoxId.${p.extension(audioFileName).substring(1)}';
              await Directory(p.dirname(targetPath)).create(recursive: true);
              await sourceFile.copy(targetPath);
              audioBoxData['audio_path'] = targetPath;
              print('已导入音频: $audioFileName -> $targetPath');
            }
          }
          
          // 移除临时字段和错误字段名
          audioBoxData.remove('audioFileName');
          audioBoxData.remove('audioPath');
          await txn.insert('audio_boxes', audioBoxData);
        }
        print('已导入 ${audioBoxes.length} 个音频框');
        
        // 处理文档设置和背景图片
        List<dynamic> documentSettings = importData['document_settings'] ?? [];
        for (var settings in documentSettings) {
          Map<String, dynamic> settingsData = Map<String, dynamic>.from(settings);
          settingsData['document_id'] = newDocumentId;
          // 移除错误的id字段
          settingsData.remove('id');
          
          // 处理背景图片
          String? backgroundImageFileName = settingsData['backgroundImageFileName'];
          if (backgroundImageFileName != null && backgroundImageFileName.isNotEmpty) {
            String sourcePath = '$tempDirPath/background_images/$backgroundImageFileName';
            File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              String targetPath = '${appDocDir.path}/background_images/${newDocumentId}_${backgroundImageFileName}';
              await Directory(p.dirname(targetPath)).create(recursive: true);
              await sourceFile.copy(targetPath);
              settingsData['background_image_path'] = targetPath;
              print('已导入背景图片: $backgroundImageFileName -> $targetPath');
            }
          }
          
          // 移除临时字段
          settingsData.remove('backgroundImageFileName');
          await txn.insert('document_settings', settingsData);
        }
        print('已导入 ${documentSettings.length} 个文档设置');
      });
      
      // 清理临时目录
      await tempDir.delete(recursive: true);
      
      print('文档导入完成');
    } catch (e, stackTrace) {
      _handleError('导入文档失败', e, stackTrace);
      rethrow;
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
    // 获取旧文档的ID
    final List<Map<String, dynamic>> oldDocuments = await db.query(
      'documents',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [oldName],
    );
    
    if (oldDocuments.isNotEmpty) {
      final String documentId = oldDocuments.first['id'];
      // text_boxes表使用document_id而不是documentName
      // 不需要更新text_boxes表，因为它与documents表通过document_id关联
    }
    // image_boxes和audio_boxes表也使用document_id关联
    // 不需要更新这些表，因为它们与documents表通过document_id关联
    // 获取文档ID
    final List<Map<String, dynamic>> docs = await db.query(
      'documents',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [newName], // 使用新名称查询，因为documents表已经更新
    );
    
    if (docs.isNotEmpty) {
      String documentId = docs.first['id'];
      // document_settings表没有document_name字段，只有document_id字段
      // 不需要更新document_settings表，因为它使用document_id作为外键，而document_id没有变化
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
      {'parent_folder': newName},
      where: 'parent_folder = ?',
      whereArgs: [oldName],
    );
    await db.update(
      'folders',
      {'parent_folder': newName},
      where: 'parent_folder = ?',
      whereArgs: [oldName],
    );
  }

  Future<List<Map<String, dynamic>>> getAllDirectoryFolders() async {
    final db = await database;
    try {
      List<Map<String, dynamic>> result = await db.query('folders');
      return result.map((map) => Map<String, dynamic>.from(map)).toList();
    } catch (e) {
      print('获取所有目录文件夹时出错: $e');
      return [];
    }
  }

  Future<void> updateFolderOrder(String folderName, int newOrder) async {
    final db = await database;
    await db.update(
      'folders',
      {'order_index': newOrder},
      where: 'name = ?',
      whereArgs: [folderName],
    );
  }

  Future<void> updateDocumentOrder(String documentName, int newOrder) async {
    final db = await database;
    await db.update(
      'documents',
      {'order_index': newOrder},
      where: 'name = ?',
      whereArgs: [documentName],
    );
  }

  // Future<void> copyDocument(String sourceName, String targetName) async { // OLD SIGNATURE
  Future<String> copyDocument(String sourceDocumentName, {String? parentFolder}) async { // NEW SIGNATURE
    print('copyDocument called for $sourceDocumentName, parentFolder: $parentFolder');
    final db = await database;
    
    // 1. 生成唯一的文档名称，使用更简洁的格式
    String newName = '$sourceDocumentName-副本';
    String finalNewDocumentName = newName;
    int attempt = 0;
    String baseName = newName;
    while (await doesNameExist(finalNewDocumentName)) {
      attempt++;
      // 如果已存在同名文档，则使用"源文档名称-副本(序号)"的格式
      finalNewDocumentName = attempt > 1 ? '$baseName($attempt)' : baseName;
      if (attempt > 100) {
        print('Failed to generate a unique name for document copy after 100 attempts.');
        throw Exception('Failed to generate a unique name for document copy.');
      }
    }
    print('Final new document name for copy: $finalNewDocumentName');
    
    try {
      // 2. 获取源文档信息
      List<Map<String, dynamic>> sourceDocs = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [sourceDocumentName]
      );
      
      if (sourceDocs.isEmpty) {
        throw Exception('Source document not found: $sourceDocumentName');
      }
      
      Map<String, dynamic> sourceDoc = sourceDocs.first;
      // 使用字符串类型的ID，因为数据库中id字段是TEXT类型
      String sourceId = sourceDoc['id'].toString();
      
      // 3. 创建新文档记录
      int maxOrder = 0;
      String? parentFolderId; // 新增：用于存储父文件夹ID
      if (parentFolder != null) {
        // 查找父文件夹ID
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
        // Optional: Add error handling if folder not found, though getFolderByName handles some cases

        List<Map<String, dynamic>> docs = await db.query(
          'documents',
          where: 'parent_folder = ?',
          whereArgs: [parentFolderId], // 使用ID查询
          orderBy: 'order_index DESC',
          limit: 1
        );
        if (docs.isNotEmpty) {
          maxOrder = docs.first['order_index'] ?? 0;
        }
      }
      
      // 4. 插入新文档
      // 生成UUID作为文档ID
      String newDocId = const Uuid().v4();
      await db.insert('documents', {
        'id': newDocId, // 显式设置ID为UUID
        'name': finalNewDocumentName,
        'parent_folder': parentFolderId, // 使用ID插入
        'is_template': 0, // 确保新文档不是模板
        'order_index': maxOrder + 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      
      // 5. 复制源文档的内容
      // 复制文本框
      List<Map<String, dynamic>> textBoxes = await db.query(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId]
      );
      
      for (var textBox in textBoxes) {
        Map<String, dynamic> newTextBox = Map<String, dynamic>.from(textBox);
        newTextBox.remove('id');
        newTextBox['document_id'] = newDocId;
        // 为文本框生成新的唯一ID
        newTextBox['id'] = const Uuid().v4();
        await db.insert('text_boxes', newTextBox);
      }
      
      // 复制图片框
      List<Map<String, dynamic>> imageBoxes = await db.query(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId]
      );
      
      for (var imageBox in imageBoxes) {
        Map<String, dynamic> newImageBox = Map<String, dynamic>.from(imageBox);
        newImageBox.remove('id');
        newImageBox['document_id'] = newDocId;
        // 为图片框生成新的唯一ID
        newImageBox['id'] = const Uuid().v4();
        await db.insert('image_boxes', newImageBox);
      }
      
      // 复制音频框
      List<Map<String, dynamic>> audioBoxes = await db.query(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId]
      );
      
      for (var audioBox in audioBoxes) {
        Map<String, dynamic> newAudioBox = Map<String, dynamic>.from(audioBox);
        newAudioBox.remove('id');
        newAudioBox['document_id'] = newDocId;
        // 为音频框生成新的唯一ID
        newAudioBox['id'] = const Uuid().v4();
        await db.insert('audio_boxes', newAudioBox);
      }
      
      // 复制文档设置
      List<Map<String, dynamic>> docSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [sourceId]
      );
      
      if (docSettings.isNotEmpty) {
        Map<String, dynamic> newSettings = Map<String, dynamic>.from(docSettings.first);
        newSettings.remove('id');
        newSettings['document_id'] = newDocId;
        // 移除document_name字段，因为document_settings表中没有这个列
        newSettings.remove('document_name');
        
        // 复制背景图片文件（如果存在）
        String? originalBackgroundPath = newSettings['background_image_path'];
        if (originalBackgroundPath != null && originalBackgroundPath.isNotEmpty) {
          try {
            File originalFile = File(originalBackgroundPath);
            if (await originalFile.exists()) {
              // 获取应用私有目录
              final appDir = await getApplicationDocumentsDirectory();
              final backgroundDir = Directory('${appDir.path}/backgrounds');
              if (!await backgroundDir.exists()) {
                await backgroundDir.create(recursive: true);
              }
              
              // 生成新的唯一文件名
              final uuid = const Uuid().v4();
              final extension = p.extension(originalBackgroundPath);
              final newFileName = '$uuid$extension';
              final newBackgroundPath = '${backgroundDir.path}/$newFileName';
              
              // 复制背景图片文件
              await originalFile.copy(newBackgroundPath);
              newSettings['background_image_path'] = newBackgroundPath;
              print('复制背景图片: $originalBackgroundPath -> $newBackgroundPath');
            } else {
              // 原背景图片文件不存在，清除路径
              newSettings['background_image_path'] = null;
              print('原背景图片文件不存在，已清除路径: $originalBackgroundPath');
            }
          } catch (e) {
            print('复制背景图片时出错: $e');
            // 出错时清除背景图片路径，避免指向无效文件
            newSettings['background_image_path'] = null;
          }
        }
        
        await db.insert('document_settings', newSettings);
      }
      
      print('Successfully copied document: $finalNewDocumentName');
      return finalNewDocumentName;
    } catch (e, stackTrace) {
      _handleError('复制文档时出错', e, stackTrace);
      print('复制文档时出错: $e');
      throw e;
    }
  }

  Future<String> createDocumentFromTemplate(String templateName, String newDocumentName, {String? parentFolder}) async {
    print('createDocumentFromTemplate called for template $templateName, newName: $newDocumentName, parentFolder: $parentFolder');
    final db = await database;
    
    // 1. 生成唯一的文档名称，使用更简洁的格式
    String finalNewDocumentName = newDocumentName;
    int attempt = 0;
    String baseName = newDocumentName;
    while (await doesNameExist(finalNewDocumentName)) {
      attempt++;
      // 如果已存在同名文档，则使用"模板名称-副本(序号)"的格式
      finalNewDocumentName = attempt > 1 ? '$baseName($attempt)' : baseName;
      if (attempt > 100) {
        print('Failed to generate a unique name for document from template after 100 attempts.');
        throw Exception('Failed to generate a unique name for document from template.');
      }
    }
    print('Final new document name from template: $finalNewDocumentName');
    
    try {
      // 2. 获取模板文档信息
      List<Map<String, dynamic>> templateDocs = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [templateName]
      );
      
      if (templateDocs.isEmpty) {
        throw Exception('Template document not found: $templateName');
      }
      
      Map<String, dynamic> templateDoc = templateDocs.first;
      // 使用字符串类型的ID，因为数据库中id字段是TEXT类型
      String templateId = templateDoc['id'].toString();
      
      // 3. 创建新文档记录
      int maxOrder = 0;
      String? parentFolderId; // 新增：用于存储父文件夹ID
      if (parentFolder != null) {
        // 查找父文件夹ID
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
         // Optional: Add error handling if folder not found

        List<Map<String, dynamic>> docs = await db.query(
          'documents',
          where: 'parent_folder = ?',
          whereArgs: [parentFolderId], // 使用ID查询
          orderBy: 'order_index DESC',
          limit: 1
        );
        if (docs.isNotEmpty) {
          maxOrder = docs.first['order_index'] ?? 0;
        }
      }
      
      // 4. 插入新文档
      // 生成UUID作为文档ID
      String newDocId = const Uuid().v4();
      await db.insert('documents', {
        'id': newDocId, // 显式设置ID为UUID
        'name': finalNewDocumentName,
        'parent_folder': parentFolderId, // 使用ID插入
        'is_template': 0, // 确保新文档不是模板
        'order_index': maxOrder + 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      
      // 5. 复制模板文档的内容
      // 复制文本框
      List<Map<String, dynamic>> textBoxes = await db.query(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId]
      );
      
      for (var textBox in textBoxes) {
        Map<String, dynamic> newTextBox = Map<String, dynamic>.from(textBox);
        newTextBox.remove('id');
        newTextBox['document_id'] = newDocId;
        // 为文本框生成新的唯一ID
        newTextBox['id'] = const Uuid().v4();
        await db.insert('text_boxes', newTextBox);
      }
      
      // 复制图片框
      List<Map<String, dynamic>> imageBoxes = await db.query(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId]
      );
      
      for (var imageBox in imageBoxes) {
        Map<String, dynamic> newImageBox = Map<String, dynamic>.from(imageBox);
        newImageBox.remove('id');
        newImageBox['document_id'] = newDocId;
        // 为图片框生成新的唯一ID
        newImageBox['id'] = const Uuid().v4();
        await db.insert('image_boxes', newImageBox);
      }
      
      // 复制音频框
      List<Map<String, dynamic>> audioBoxes = await db.query(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId]
      );
      
      for (var audioBox in audioBoxes) {
        Map<String, dynamic> newAudioBox = Map<String, dynamic>.from(audioBox);
        newAudioBox.remove('id');
        newAudioBox['document_id'] = newDocId;
        // 为音频框生成新的唯一ID
        newAudioBox['id'] = const Uuid().v4();
        await db.insert('audio_boxes', newAudioBox);
      }
      
      // 复制文档设置
      List<Map<String, dynamic>> docSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [templateId]
      );
      
      if (docSettings.isNotEmpty) {
        Map<String, dynamic> newSettings = Map<String, dynamic>.from(docSettings.first);
        newSettings.remove('id');
        newSettings['document_id'] = newDocId;
        // 移除document_name字段，因为document_settings表中没有这个列
        newSettings.remove('document_name');
        
        // 处理背景图片复制
        String? originalBackgroundPath = newSettings['background_image_path'];
        if (originalBackgroundPath != null && originalBackgroundPath.isNotEmpty) {
          try {
            // 获取应用私有目录
            Directory appDir = await getApplicationDocumentsDirectory();
            Directory backgroundsDir = Directory(p.join(appDir.path, 'backgrounds'));
            if (!await backgroundsDir.exists()) {
              await backgroundsDir.create(recursive: true);
            }
            
            // 检查原背景图片文件是否存在
            File originalFile = File(originalBackgroundPath);
            if (await originalFile.exists()) {
              // 生成新的唯一文件名
              String extension = p.extension(originalBackgroundPath);
              String newFileName = '${const Uuid().v4()}$extension';
              String newBackgroundPath = p.join(backgroundsDir.path, newFileName);
              
              // 复制背景图片文件
              await originalFile.copy(newBackgroundPath);
              
              // 更新新文档设置中的背景图片路径
              newSettings['background_image_path'] = newBackgroundPath;
              print('从模板复制背景图片: $originalBackgroundPath -> $newBackgroundPath');
            } else {
              // 如果原文件不存在，清空背景图片路径
              newSettings['background_image_path'] = null;
              print('模板背景图片文件不存在，已清空新文档的背景图片路径');
            }
          } catch (e) {
            print('复制模板背景图片时出错: $e');
            // 出错时清空背景图片路径，避免指向不存在的文件
            newSettings['background_image_path'] = null;
          }
        }
        
        await db.insert('document_settings', newSettings);
      }
      
      print('Successfully created document from template: $finalNewDocumentName');
      return finalNewDocumentName;
    } catch (e, stackTrace) {
      _handleError('从模板创建文档时出错', e, stackTrace);
      print('从模板创建文档时出错: $e');
      rethrow;
    }
  }

  Future<void> importDirectoryDataImpl(String filePath) async {
    try {
      final db = await database;
      
      // 读取导入文件
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('导入文件不存在: $filePath');
      }
      
      final jsonString = await file.readAsString();
      final Map<String, dynamic> data = json.decode(jsonString);
      
      await db.transaction((txn) async {
        // 清空现有数据
        await txn.delete('text_boxes');
        await txn.delete('image_boxes');
        await txn.delete('audio_boxes');
        await txn.delete('document_settings');
        await txn.delete('media_items');
        await txn.delete('documents');
        await txn.delete('folders');
        
        // 导入文件夹数据
        if (data['folders'] != null) {
          for (var folder in data['folders']) {
            await txn.insert('folders', {
              'id': folder['id'],
              'name': folder['name'],
              'parent_folder': folder['parent_folder'],
              'order_index': folder['order_index'] ?? 0,
              'position': folder['position'],
              'created_at': folder['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': folder['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入文档数据
        if (data['documents'] != null) {
          for (var document in data['documents']) {
            await txn.insert('documents', {
              'id': document['id'],
              'name': document['name'],
              'parent_folder': document['parent_folder'],
              'order_index': document['order_index'] ?? 0,
              'is_template': document['is_template'] ?? 0,
              'position': document['position'],
              'created_at': document['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': document['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入文本框数据
        if (data['text_boxes'] != null) {
          for (var textBox in data['text_boxes']) {
            await txn.insert('text_boxes', {
              'id': textBox['id'],
              'document_id': textBox['document_id'],
              'position_x': textBox['position_x'],
              'position_y': textBox['position_y'],
              'width': textBox['width'],
              'height': textBox['height'],
              'content': textBox['content'],
              'font_size': textBox['font_size'] ?? 14.0,
              'font_color': textBox['font_color'] ?? 4278190080,
              'font_family': textBox['font_family'] ?? 'Roboto',
              'font_weight': textBox['font_weight'] ?? 0,
              'is_italic': textBox['is_italic'] ?? 0,
              'is_underlined': textBox['is_underlined'] ?? 0,
              'is_strike_through': textBox['is_strike_through'] ?? 0,
              'background_color': textBox['background_color'],
              'text_align': textBox['text_align'] ?? 0,
              'created_at': textBox['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': textBox['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入图片框数据
        if (data['image_boxes'] != null) {
          for (var imageBox in data['image_boxes']) {
            await txn.insert('image_boxes', {
              'id': imageBox['id'],
              'document_id': imageBox['document_id'],
              'position_x': imageBox['position_x'],
              'position_y': imageBox['position_y'],
              'width': imageBox['width'],
              'height': imageBox['height'],
              'image_path': imageBox['image_path'],
              'created_at': imageBox['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': imageBox['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入音频框数据
        if (data['audio_boxes'] != null) {
          for (var audioBox in data['audio_boxes']) {
            await txn.insert('audio_boxes', {
              'id': audioBox['id'],
              'document_id': audioBox['document_id'],
              'position_x': audioBox['position_x'],
              'position_y': audioBox['position_y'],
              'audio_path': audioBox['audio_path'],
              'created_at': audioBox['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': audioBox['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入媒体项数据
        if (data['media_items'] != null) {
          for (var mediaItem in data['media_items']) {
            await txn.insert('media_items', {
              'id': mediaItem['id'],
              'name': mediaItem['name'],
              'path': mediaItem['path'],
              'type': mediaItem['type'],
              'directory': mediaItem['directory'],
              'date_added': mediaItem['date_added'] ?? DateTime.now().toIso8601String(),
              'file_size': mediaItem['file_size'] ?? 0,
              'duration': mediaItem['duration'] ?? 0,
              'thumbnail_path': mediaItem['thumbnail_path'],
              'file_hash': mediaItem['file_hash'],
              'is_favorite': mediaItem['is_favorite'] ?? 0,
              'created_at': mediaItem['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': mediaItem['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
        
        // 导入文档设置数据
        if (data['document_settings'] != null) {
          for (var setting in data['document_settings']) {
            await txn.insert('document_settings', {
              'document_id': setting['document_id'],
              'background_image_path': setting['background_image_path'],
              'background_color': setting['background_color'],
              'text_enhance_mode': setting['text_enhance_mode'] ?? 0,
              'created_at': setting['created_at'] ?? DateTime.now().millisecondsSinceEpoch,
              'updated_at': setting['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
            });
          }
        }
      });
      
      if (kDebugMode) {
        print('数据导入成功: $filePath');
      }
    } catch (e, stackTrace) {
      _handleError('导入数据失败', e, stackTrace);
      rethrow;
    }
  }

  Future<void> ensureAudioBoxesTableExists() async {
    final db = await database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audio_boxes(
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL,
        position_x REAL NOT NULL,
        position_y REAL NOT NULL,
        audio_path TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
      )
    ''');
  }

  bool validateImageBoxData(Map<String, dynamic> data) {
    if (data['id'] == null || data['document_id'] == null) {
      return false;
    }
    if (data['positionX'] == null || data['positionY'] == null) {
      return false;
    }
    if (data['width'] == null || data['height'] == null) {
      return false;
    }
    if (data['imagePath'] == null || data['imagePath'].toString().isEmpty) {
      return false;
    }
    return true;
  }

  // ==================== Missing Methods from DatabaseHelper ====================

  /// Get directory settings with optional folder name parameter
  Future<Map<String, dynamic>?> getDirectorySettings([String? folderName]) async {
    try {
      final db = await database;
      List<Map<String, dynamic>> result;
      
      if (folderName != null) {
        result = await db.query(
          'directory_settings',
          where: 'folder_name = ?',
          whereArgs: [folderName],
        );
      } else {
        // 当folderName为null时，查询folder_name为null的记录，而不是所有记录
        result = await db.query(
          'directory_settings',
          where: 'folder_name IS NULL',
        );
      }
      
      if (result.isNotEmpty) {
        return result.first;
      }
      return null;
    } catch (e, stackTrace) {
      _handleError('获取目录设置失败', e, stackTrace);
      return null;
    }
  }

  /// Insert or update directory settings
  Future<void> insertOrUpdateDirectorySettings({
    String? folderName,
    String? imagePath,
    int? colorValue,
    int? isFreeSortMode,
  }) async {
    try {
      final db = await database;
      
      Map<String, dynamic> data = {
        'folder_name': folderName,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
      
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
      
      // 查询特定文件夹的设置
      List<Map<String, dynamic>> existing;
      if (folderName != null) {
        existing = await db.query(
          'directory_settings',
          where: 'folder_name = ?',
          whereArgs: [folderName],
        );
      } else {
        existing = await db.query(
          'directory_settings',
          where: 'folder_name IS NULL',
        );
      }
      
      if (existing.isEmpty) {
        // 如果不存在，则插入新记录
        data['created_at'] = DateTime.now().millisecondsSinceEpoch;
        await db.insert('directory_settings', data);
      } else {
        // 如果存在，则更新记录
        if (folderName != null) {
          await db.update(
            'directory_settings',
            data,
            where: 'folder_name = ?',
            whereArgs: [folderName],
          );
        } else {
          await db.update(
            'directory_settings',
            data,
            where: 'folder_name IS NULL',
          );
        }
      }
    } catch (e, stackTrace) {
      _handleError('插入或更新目录设置失败', e, stackTrace);
      rethrow;
    }
  }

  /// Delete directory background image
  Future<void> deleteDirectoryBackgroundImage([String? folderName]) async {
    try {
      final db = await database;
      if (folderName != null) {
        await db.update(
          'directory_settings',
          {'background_image_path': null},
          where: 'folder_name = ?',
          whereArgs: [folderName],
        );
      } else {
        await db.update(
          'directory_settings',
          {'background_image_path': null},
          where: 'folder_name IS NULL',
        );
      }
    } catch (e, stackTrace) {
      _handleError('删除目录背景图片失败', e, stackTrace);
      rethrow;
    }
  }

  /// Insert document
  Future<void> insertDocument(String name, {String? parentFolder, String? position}) async {
    try {
      final db = await database;
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
      }
      final List<Map<String, dynamic>> result = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM documents 
        WHERE parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}
      ''', parentFolderId != null ? [parentFolderId] : []);
      int order = (result.first['maxOrder'] ?? -1) + 1;
      await db.insert(
        'documents',
        {
          'id': const Uuid().v4(),
          'name': name,
          'parent_folder': parentFolderId,
          'order_index': order,
          'is_template': 0,
          'position': position,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (e, stackTrace) {
      _handleError('插入文档失败', e, stackTrace);
      rethrow;
    }
  }

  /// Get template documents
  Future<List<Map<String, dynamic>>> getTemplateDocuments() async {
    try {
      final db = await database;
      return await db.query(
        'documents',
        where: 'is_template = ?',
        whereArgs: [1],
        orderBy: 'order_index ASC',
      );
    } catch (e, stackTrace) {
      _handleError('获取模板文档失败', e, stackTrace);
      return [];
    }
  }

  /// Insert folder
  Future<void> insertFolder(String name, {String? parentFolder, String? position}) async {
    try {
      final db = await database;
      
      final List<Map<String, dynamic>> result = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM folders 
        WHERE parent_folder ${parentFolder == null ? 'IS NULL' : '= ?'}
      ''', parentFolder != null ? [parentFolder] : []);
      
      int order = (result.first['maxOrder'] ?? -1) + 1;
      
      await db.insert(
        'folders',
        {
          'id': const Uuid().v4(),
          'name': name,
          'parent_folder': parentFolder,
          'order_index': order,
          'position': position,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (e, stackTrace) {
      _handleError('插入文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// Get text boxes by document
  Future<List<Map<String, dynamic>>> getTextBoxesByDocument(String documentName) async {
    print('🔍 [DB] 开始查询文本框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'text_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      print('✅ [DB] 文本框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        print('📋 [DB] 第一条文本框数据字段: ${result.first.keys.toList()}');
        print('📋 [DB] 第一条文本框数据值: ${result.first}');
      }
      
      // 转换字段名
      return result.map((map) {
        Map<String, dynamic> convertedMap = Map<String, dynamic>.from(map);
        // 将数据库字段名转换为应用中使用的字段名
        if (convertedMap.containsKey('position_x')) {
          convertedMap['positionX'] = convertedMap.remove('position_x');
        }
        if (convertedMap.containsKey('position_y')) {
          convertedMap['positionY'] = convertedMap.remove('position_y');
        }
        if (convertedMap.containsKey('content')) {
          convertedMap['text'] = convertedMap.remove('content');
        }
        if (convertedMap.containsKey('font_size')) {
          convertedMap['fontSize'] = convertedMap.remove('font_size');
        }
        if (convertedMap.containsKey('font_color')) {
          convertedMap['fontColor'] = convertedMap.remove('font_color');
        }
        if (convertedMap.containsKey('font_family')) {
          convertedMap['fontFamily'] = convertedMap.remove('font_family');
        }
        if (convertedMap.containsKey('font_weight')) {
          convertedMap['fontWeight'] = convertedMap.remove('font_weight');
        }
        if (convertedMap.containsKey('is_italic')) {
          convertedMap['isItalic'] = convertedMap.remove('is_italic');
        }
        if (convertedMap.containsKey('is_underlined')) {
          convertedMap['isUnderlined'] = convertedMap.remove('is_underlined');
        }
        if (convertedMap.containsKey('is_strike_through')) {
          convertedMap['isStrikeThrough'] = convertedMap.remove('is_strike_through');
        }
        if (convertedMap.containsKey('background_color')) {
          convertedMap['backgroundColor'] = convertedMap.remove('background_color');
        }
        if (convertedMap.containsKey('text_align')) {
          convertedMap['textAlign'] = convertedMap.remove('text_align');
        }
        return convertedMap;
      }).toList();
    } catch (e, stackTrace) {
      print('❌ [DB] 获取文档文本框失败: $e');
      _handleError('获取文档文本框失败', e, stackTrace);
      return [];
    }
  }

  /// Get image boxes by document
  Future<List<Map<String, dynamic>>> getImageBoxesByDocument(String documentName) async {
    print('🔍 [DB] 开始查询图片框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'image_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      print('✅ [DB] 图片框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        print('📋 [DB] 第一条图片框数据字段: ${result.first.keys.toList()}');
        print('📋 [DB] 第一条图片框数据值: ${result.first}');
      }
      
      // 转换字段名
      return result.map((map) {
        Map<String, dynamic> convertedMap = Map<String, dynamic>.from(map);
        // 将数据库字段名转换为应用中使用的字段名
        if (convertedMap.containsKey('position_x')) {
          convertedMap['positionX'] = convertedMap.remove('position_x');
        }
        if (convertedMap.containsKey('position_y')) {
          convertedMap['positionY'] = convertedMap.remove('position_y');
        }
        if (convertedMap.containsKey('image_path')) {
          convertedMap['imagePath'] = convertedMap.remove('image_path');
        }
        return convertedMap;
      }).toList();
    } catch (e, stackTrace) {
      print('❌ [DB] 获取文档图片框失败: $e');
      _handleError('获取文档图片框失败', e, stackTrace);
      return [];
    }
  }

  /// Get audio boxes by document
  Future<List<Map<String, dynamic>>> getAudioBoxesByDocument(String documentName) async {
    print('🔍 [DB] 开始查询音频框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'audio_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      print('✅ [DB] 音频框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        print('📋 [DB] 第一条音频框数据字段: ${result.first.keys.toList()}');
        print('📋 [DB] 第一条音频框数据值: ${result.first}');
      }
      
      // 转换字段名
      return result.map((map) {
        Map<String, dynamic> convertedMap = Map<String, dynamic>.from(map);
        // 将数据库字段名转换为应用中使用的字段名
        if (convertedMap.containsKey('position_x')) {
          convertedMap['positionX'] = convertedMap.remove('position_x');
        }
        if (convertedMap.containsKey('position_y')) {
          convertedMap['positionY'] = convertedMap.remove('position_y');
        }
        if (convertedMap.containsKey('audio_path')) {
          convertedMap['audioPath'] = convertedMap.remove('audio_path');
        }
        return convertedMap;
      }).toList();
    } catch (e, stackTrace) {
      print('❌ [DB] 获取文档音频框失败: $e');
      _handleError('获取文档音频框失败', e, stackTrace);
      return [];
    }
  }

  /// Set document as template
  Future<void> setDocumentAsTemplate(String documentName, bool isTemplate) async {
    try {
      final db = await database;
      await db.update(
        'documents',
        {'is_template': isTemplate ? 1 : 0},
        where: 'name = ?',
        whereArgs: [documentName],
      );
    } catch (e, stackTrace) {
      _handleError('设置文档模板状态失败', e, stackTrace);
      rethrow;
    }
  }

  /// Save text boxes
  Future<void> saveTextBoxes(List<Map<String, dynamic>> textBoxes, String documentName) async {
    try {
      final db = await database;
      
      await db.transaction((txn) async {
        // Get document ID
        final docResult = await txn.query(
          'documents',
          columns: ['id'],
          where: 'name = ?',
          whereArgs: [documentName],
        );
        
        if (docResult.isEmpty) {
          throw Exception('Document not found: $documentName');
        }
        
        final documentId = docResult.first['id'] as String;
        
        // Delete existing text boxes
        await txn.delete(
          'text_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        // Insert new text boxes
        for (var textBox in textBoxes) {
          if (validateTextBoxData(textBox)) {
            final data = Map<String, dynamic>.from(textBox);
            // Remove old field if exists
            data.remove('documentName');
            data['document_id'] = documentId;
            data['created_at'] = DateTime.now().millisecondsSinceEpoch;
            data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
            
            // Convert field names to match database schema
            if (data.containsKey('positionX')) {
              data['position_x'] = data.remove('positionX');
            }
            if (data.containsKey('positionY')) {
              data['position_y'] = data.remove('positionY');
            }
            if (data.containsKey('text')) {
              data['content'] = data.remove('text');
            }
            if (data.containsKey('fontSize')) {
              data['font_size'] = data.remove('fontSize');
            }
            if (data.containsKey('fontColor')) {
              data['font_color'] = data.remove('fontColor');
            }
            if (data.containsKey('fontFamily')) {
              data['font_family'] = data.remove('fontFamily');
            }
            if (data.containsKey('fontWeight')) {
              data['font_weight'] = data.remove('fontWeight');
            }
            if (data.containsKey('isItalic')) {
              data['is_italic'] = data.remove('isItalic');
            }
            if (data.containsKey('isUnderlined')) {
              data['is_underlined'] = data.remove('isUnderlined');
            }
            if (data.containsKey('isStrikeThrough')) {
              data['is_strike_through'] = data.remove('isStrikeThrough');
            }
            if (data.containsKey('backgroundColor')) {
              data['background_color'] = data.remove('backgroundColor');
            }
            if (data.containsKey('textAlign')) {
              data['text_align'] = data.remove('textAlign');
            }
            
            await txn.insert(
              'text_boxes',
              data,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      });
    } catch (e, stackTrace) {
      _handleError('保存文本框失败', e, stackTrace);
      rethrow;
    }
  }

  /// Save image boxes
  Future<void> saveImageBoxes(List<Map<String, dynamic>> imageBoxes, String documentName) async {
    try {
      final db = await database;
      
      await db.transaction((txn) async {
        // Get document ID
        final docResult = await txn.query(
          'documents',
          columns: ['id'],
          where: 'name = ?',
          whereArgs: [documentName],
        );
        
        if (docResult.isEmpty) {
          throw Exception('Document not found: $documentName');
        }
        
        final documentId = docResult.first['id'] as String;
        
        // Delete existing image boxes
        await txn.delete(
          'image_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        // Insert new image boxes
        for (var imageBox in imageBoxes) {
          final data = Map<String, dynamic>.from(imageBox);
          // Remove old field if exists
          data.remove('documentName');
          data['document_id'] = documentId;
          data['created_at'] = DateTime.now().millisecondsSinceEpoch;
          data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
          
          // Convert field names to match database schema
          if (data.containsKey('positionX')) {
            data['position_x'] = data.remove('positionX');
          }
          if (data.containsKey('positionY')) {
            data['position_y'] = data.remove('positionY');
          }
          if (data.containsKey('imagePath')) {
            data['image_path'] = data.remove('imagePath');
          }
          
          await txn.insert(
            'image_boxes',
            data,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e, stackTrace) {
      _handleError('保存图片框失败', e, stackTrace);
      rethrow;
    }
  }

  /// Save audio boxes
  Future<void> saveAudioBoxes(List<Map<String, dynamic>> audioBoxes, String documentName) async {
    try {
      final db = await database;
      
      await db.transaction((txn) async {
        // Get document ID
        final docResult = await txn.query(
          'documents',
          columns: ['id'],
          where: 'name = ?',
          whereArgs: [documentName],
        );
        
        if (docResult.isEmpty) {
          throw Exception('Document not found: $documentName');
        }
        
        final documentId = docResult.first['id'] as String;
        
        // Delete existing audio boxes
        await txn.delete(
          'audio_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        // Insert new audio boxes
        for (var audioBox in audioBoxes) {
          final data = Map<String, dynamic>.from(audioBox);
          // Remove old field if exists
          data.remove('documentName');
          data['document_id'] = documentId;
          data['created_at'] = DateTime.now().millisecondsSinceEpoch;
          data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
          
          // Convert field names to match database schema
          if (data.containsKey('positionX')) {
            data['position_x'] = data.remove('positionX');
          }
          if (data.containsKey('positionY')) {
            data['position_y'] = data.remove('positionY');
          }
          if (data.containsKey('audioPath')) {
            data['audio_path'] = data.remove('audioPath');
          }
          
          await txn.insert(
            'audio_boxes',
            data,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (e, stackTrace) {
      _handleError('保存音频框失败', e, stackTrace);
      rethrow;
    }
  }

  /// Get document settings
  Future<Map<String, dynamic>?> getDocumentSettings(String documentName) async {
    print('🔍 [DB] 开始查询文档设置，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'document_settings',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      print('✅ [DB] 文档设置查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        print('📋 [DB] 文档设置数据字段: ${result.first.keys.toList()}');
        print('📋 [DB] 文档设置数据值: ${result.first}');
        return result.first;
      }
      print('ℹ️ [DB] 未找到文档设置数据');
      return null;
    } catch (e, stackTrace) {
      print('❌ [DB] 获取文档设置失败: $e');
      _handleError('获取文档设置失败', e, stackTrace);
      return null;
    }
  }

  /// Insert or update document settings
  Future<void> insertOrUpdateDocumentSettings(
    String documentName, {
    String? imagePath,
    int? colorValue,
    bool? textEnhanceMode,
  }) async {
    try {
      final db = await database;
      
      // Get document ID
      final docResult = await db.query(
        'documents',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [documentName],
      );
      
      if (docResult.isEmpty) {
        throw Exception('Document not found: $documentName');
      }
      
      final documentId = docResult.first['id'] as String;
      
      // Check if settings exist
      List<Map<String, dynamic>> existingSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      
      Map<String, dynamic> settingsData = {
        'document_id': documentId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
      
      if (existingSettings.isNotEmpty) {
        var existing = existingSettings.first;
        settingsData['background_image_path'] = imagePath ?? existing['background_image_path'];
        settingsData['background_color'] = colorValue ?? existing['background_color'];
        settingsData['text_enhance_mode'] = textEnhanceMode != null
            ? (textEnhanceMode ? 1 : 0)
            : existing['text_enhance_mode'];
        // 保留原有的created_at字段
        settingsData['created_at'] = existing['created_at'];
      } else {
        settingsData['background_image_path'] = imagePath;
        settingsData['background_color'] = colorValue;
        settingsData['text_enhance_mode'] = textEnhanceMode != null ? (textEnhanceMode ? 1 : 0) : 0;
        settingsData['created_at'] = DateTime.now().millisecondsSinceEpoch;
      }
      
      await db.insert(
        'document_settings',
        settingsData,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e, stackTrace) {
      _handleError('插入或更新文档设置失败', e, stackTrace);
      rethrow;
    }
  }

  /// Validate audio box data
  bool validateAudioBoxData(Map<String, dynamic> data) {
    if (data['id'] == null) {
      return false;
    }
    if (data['position_x'] == null || data['position_y'] == null) {
      return false;
    }
    return true;
  }

  // ==================== Cover Image Methods ====================

  /// Insert cover image
  Future<void> insertCoverImage(String imagePath) async {
    try {
      final db = await database;
      
      // Ensure cover_image table exists
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

      // Delete existing records and insert new one
      await db.delete('cover_image');
      await db.insert(
        'cover_image',
        {'path': imagePath, 'timestamp': DateTime.now().millisecondsSinceEpoch},
      );
      print('成功插入封面图片路径: $imagePath');
    } catch (e, stackTrace) {
      _handleError('插入封面图片路径失败', e, stackTrace);
      print('插入封面图片路径时出错: $e');
      rethrow;
    }
  }

  /// Get cover image
  Future<List<Map<String, dynamic>>> getCoverImage() async {
    try {
      final db = await database;
      
      // Ensure cover_image table exists
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
    } catch (e, stackTrace) {
      _handleError('获取封面图片失败', e, stackTrace);
      print('获取封面图片时出错: $e');
      return [];
    }
  }

  /// Delete cover image
  Future<void> deleteCoverImage() async {
    try {
      final db = await database;
      
      // Ensure cover_image table exists
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
    } catch (e, stackTrace) {
      _handleError('删除封面图片失败', e, stackTrace);
      print('删除封面图片时出错: $e');
    }
  }

  /// Restore database from backup
  Future<void> restoreDatabase(String filePath) async {
    try {
      print('开始从备份恢复数据库: $filePath');
      
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String tempDirPath = '${appDocDir.path}/temp_restore';
      
      // 清理并创建临时目录
      if (await Directory(tempDirPath).exists()) {
        await Directory(tempDirPath).delete(recursive: true);
      }
      await Directory(tempDirPath).create(recursive: true);
      
      // 解压备份文件
      final bytes = File(filePath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      
      for (final file in archive) {
        final filename = file.name;
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
    } catch (e, stackTrace) {
      _handleError('导入目录数据失败', e, stackTrace);
      print('导入目录数据时出错: $e');
      print('错误堆栈: $stackTrace');
      rethrow;
    }
  }
}
