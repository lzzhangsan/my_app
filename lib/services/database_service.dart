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
import '../models/diary_entry.dart';

/// 数据库服务 - 统一管理所有数据库操作
class DatabaseService {
  static const String _databaseName = 'change_app.db';
  static const int _databaseVersion = 12; // 强制升级版本号
  
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
      
      // 主动检查diary_entries表
      final tables = await _database!.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='diary_entries'");
      if (tables.isEmpty) {
        await _database!.execute('''
          CREATE TABLE IF NOT EXISTS diary_entries(
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL,
            content TEXT,
            image_paths TEXT,
            audio_paths TEXT,
            video_paths TEXT,
            weather TEXT,
            mood TEXT,
            location TEXT,
            is_favorite INTEGER DEFAULT 0
          )
        ''');
      }
      
      // 检查document_settings表是否存在position_locked字段
      await _ensurePositionLockedColumn();
      
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
                    text_segments TEXT,
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
          telegram_file_id TEXT,
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
          position_locked INTEGER DEFAULT 1,
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

      // 日记本表
      await txn.execute('''
        CREATE TABLE diary_entries(
          id TEXT PRIMARY KEY,
          date TEXT NOT NULL,
          content TEXT,
          image_paths TEXT,
          audio_paths TEXT,
          video_paths TEXT,
          weather TEXT,
          mood TEXT,
          location TEXT,
          is_favorite INTEGER DEFAULT 0
        )
      ''');

      // 日记本设置表
      await txn.execute('''
        CREATE TABLE diary_settings(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          background_image_path TEXT,
          background_color INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
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
    await db.execute('CREATE INDEX idx_media_items_telegram_file_id ON media_items(telegram_file_id)');
  }

  /// 数据库升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diary_entries(
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        content TEXT,
        image_paths TEXT,
        audio_paths TEXT,
        video_paths TEXT,
        weather TEXT,
        mood TEXT,
        location TEXT,
        is_favorite INTEGER DEFAULT 0
      )
    ''');
    // 新增：确保 diary_settings 表升级时自动创建
    await db.execute('''
      CREATE TABLE IF NOT EXISTS diary_settings(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        background_image_path TEXT,
        background_color INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
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
      case 9:
        // 添加Telegram文件ID字段
        try {
          await db.execute('ALTER TABLE media_items ADD COLUMN telegram_file_id TEXT');
          await db.execute('CREATE INDEX idx_media_items_telegram_file_id ON media_items(telegram_file_id)');
          if (kDebugMode) {
            print('已添加telegram_file_id列到media_items表');
          }
        } catch (e) {
          if (kDebugMode) {
            print('添加telegram_file_id列失败: $e');
          }
        }
        break;
      case 10:
        // 为document_settings表添加position_locked字段
        try {
          await db.execute('ALTER TABLE document_settings ADD COLUMN position_locked INTEGER DEFAULT 1');
          if (kDebugMode) {
            print('已添加position_locked列到document_settings表');
          }
        } catch (e) {
          if (kDebugMode) {
            print('添加position_locked列失败: $e');
          }
        }
        break;
    }
  }

  /// 确保document_settings表存在position_locked字段
  Future<void> _ensurePositionLockedColumn() async {
    try {
      // 检查position_locked字段是否存在
      final columns = await _database!.rawQuery("PRAGMA table_info(document_settings)");
      bool hasPositionLocked = false;
      
      for (final column in columns) {
        if (column['name'] == 'position_locked') {
          hasPositionLocked = true;
          break;
        }
      }
      
      if (!hasPositionLocked) {
        if (kDebugMode) {
          print('🔧 [DB] document_settings表缺少position_locked字段，正在添加...');
        }
        await _database!.execute('ALTER TABLE document_settings ADD COLUMN position_locked INTEGER DEFAULT 1');
        if (kDebugMode) {
          print('✅ [DB] 已成功添加position_locked字段到document_settings表');
        }
      } else {
        if (kDebugMode) {
          print('✅ [DB] document_settings表已存在position_locked字段');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DB] 检查或添加position_locked字段失败: $e');
      }
      // 不抛出异常，避免影响数据库初始化
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
    
    // 生产环境不输出调试日志
    // 可集成到远程错误报告系统
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
      // 使用自定义排序逻辑：
      // 1. 回收站和收藏夹固定在最前面
      // 2. 其他文件夹
      // 3. 视频
      // 4. 图片
      // 所有项按添加时间倒序排列（最新添加的在前）
      final folderTypeIndex = 3; // MediaType.folder.index
      final imageTypeIndex = 0; // MediaType.image.index
      final videoTypeIndex = 1; // MediaType.video.index
      return await db.rawQuery('''
        SELECT * FROM media_items 
        WHERE directory = ? 
        ORDER BY 
          CASE 
            WHEN id = 'recycle_bin' THEN 0 
            WHEN id = 'favorites' THEN 1 
            WHEN type = $folderTypeIndex THEN 2 
            WHEN type = $videoTypeIndex THEN 3 
            WHEN type = $imageTypeIndex THEN 4 
            ELSE 5 
          END ASC, 
          CASE 
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0 
            ELSE datetime(date_added) 
          END DESC
      ''', [directory]);
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
  Future<Map<String, dynamic>?> findDuplicateMediaItem(String fileHash, String fileName, {String? telegramFileId}) async {
    try {
      final db = await database;
      
      // 首先通过Telegram文件ID查找（如果提供了）
      if (telegramFileId != null && telegramFileId.isNotEmpty) {
        final List<Map<String, dynamic>> telegramMatches = await db.query(
          'media_items',
          where: 'telegram_file_id = ?',
          whereArgs: [telegramFileId],
        );
        if (telegramMatches.isNotEmpty) {
          return telegramMatches.first;
        }
      }
      
      // 然后通过文件哈希查找
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
  
  /// 根据Telegram文件ID查找媒体项
  Future<Map<String, dynamic>?> findMediaItemByTelegramFileId(String telegramFileId) async {
    try {
      if (telegramFileId.isEmpty) return null;
      
      final db = await database;
      final List<Map<String, dynamic>> matches = await db.query(
        'media_items',
        where: 'telegram_file_id = ?',
        whereArgs: [telegramFileId],
      );
      
      if (matches.isNotEmpty) {
        return matches.first;
      }
      return null;
    } catch (e, stackTrace) {
      _handleError('根据Telegram文件ID查找媒体项失败', e, stackTrace);
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
  Future<void> updateFolderParentFolder(String folderName, String? newParentFolderName) async {
    try {
      final db = await database;
      final currentFolder = await getFolderByName(folderName);
      if (currentFolder == null) {
        throw Exception('文件夹不存在');
      }
      String? newParentFolderId;
      if (newParentFolderName != null && newParentFolderName.isNotEmpty) {
        final newParentFolder = await getFolderByName(newParentFolderName);
        if (newParentFolder == null) {
          throw Exception('目标文件夹不存在');
        }
        newParentFolderId = newParentFolder['id'];
        if (await _wouldCreateCircularReference(currentFolder['id'], newParentFolderId)) {
          throw Exception('不能将文件夹移动到其子文件夹中');
        }
      }
      // 文件夹移动到同类末尾
      final List<Map<String, dynamic>> result = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM folders 
        WHERE parent_folder ${newParentFolderId == null ? 'IS NULL' : '= ?'}
      ''', newParentFolderId != null ? [newParentFolderId] : []);
      int newOrder = (result.first['maxOrder'] ?? -1) + 1;
      await db.update(
        'folders',
        {
          'parent_folder': newParentFolderId,
          'order_index': newOrder,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [currentFolder['id']],
      );
    } catch (e, stackTrace) {
      _handleError('更新文件夹父文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// 检查是否会导致循环引用
  Future<bool> _wouldCreateCircularReference(String folderId, String? newParentId) async {
    if (newParentId == null) return false;
    if (folderId == newParentId) return true;
    
    final db = await database;
    String? currentParentId = newParentId;
    
    while (currentParentId != null) {
      final result = await db.query(
        'folders',
        columns: ['parent_folder'],
        where: 'id = ?',
        whereArgs: [currentParentId],
      );
      
      if (result.isEmpty) break;
      
      currentParentId = result.first['parent_folder'] as String?;
      if (currentParentId == folderId) return true;
    }
    
    return false;
  }

  /// 更新文档的父文件夹
  Future<void> updateDocumentParentFolder(String documentName, String? newParentFolderName) async {
    try {
      final db = await database;
      final currentDocument = await getDocumentByName(documentName);
      if (currentDocument == null) {
        throw Exception('文档不存在');
      }
      String? newParentFolderId;
      if (newParentFolderName != null && newParentFolderName.isNotEmpty) {
        final newParentFolder = await getFolderByName(newParentFolderName);
        if (newParentFolder == null) {
          throw Exception('目标文件夹不存在');
        }
        newParentFolderId = newParentFolder['id'];
      }
      // 文档移动到同类末尾（所有文档的最大order_index+1，且order_index大于同目录下所有文件夹的最大order_index）
      final List<Map<String, dynamic>> folderResult = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM folders 
        WHERE parent_folder ${newParentFolderId == null ? 'IS NULL' : '= ?'}
      ''', newParentFolderId != null ? [newParentFolderId] : []);
      final List<Map<String, dynamic>> docResult = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM documents 
        WHERE parent_folder ${newParentFolderId == null ? 'IS NULL' : '= ?'}
      ''', newParentFolderId != null ? [newParentFolderId] : []);
      int folderMax = (folderResult.first['maxOrder'] ?? -1) + 1;
      int docOrder = (docResult.first['maxOrder'] ?? -1) + 1;
      int newOrder = folderMax > docOrder ? folderMax : docOrder;
      await db.update(
        'documents',
        {
          'parent_folder': newParentFolderId,
          'order_index': newOrder,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [currentDocument['id']],
      );
    } catch (e, stackTrace) {
      _handleError('更新文档父文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// 检查目录所有音频框音频文件完整性，返回丢失文件路径列表
  Future<List<String>> checkDirectoryAudioFilesIntegrity() async {
    final db = await database;
    final List<Map<String, dynamic>> audioBoxes = await db.query('audio_boxes');
    List<String> missingFiles = [];
    for (final audioBox in audioBoxes) {
      String? audioPath = audioBox['audio_path'];
      if (audioPath != null && audioPath.isNotEmpty) {
        if (!await File(audioPath).exists()) {
          missingFiles.add(audioPath);
        }
      }
    }
    return missingFiles;
  }

  /// 导出目录数据 - 优化版，支持超大数据处理
  Future<String> exportDirectoryData({ValueNotifier<String>? progressNotifier}) async {
    // 导出前先检测音频完整性
    final missingAudioFiles = await checkDirectoryAudioFilesIntegrity();
    if (missingAudioFiles.isNotEmpty) {
      throw Exception('导出失败：有音频文件丢失，需补齐后再导出。丢失文件如下：\n${missingAudioFiles.join('\n')}');
    }
    try {
      print('开始导出目录数据...');
      progressNotifier?.value = "准备导出...";
      
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

      final db = await database;
      final Map<String, List<Map<String, dynamic>>> tableData = {};
      
      // 分批导出数据库表，避免一次性加载全部数据
      final List<String> tables = ['folders', 'documents', 'text_boxes', 'image_boxes', 'audio_boxes'];
      
      for (String tableName in tables) {
        progressNotifier?.value = "正在导出$tableName表数据...";
        
        // 分页查询，每次处理500条记录
        const int batchSize = 500;
        int offset = 0;
        List<Map<String, dynamic>> allRows = [];
        
        while (true) {
          final batch = await db.query(
            tableName,
            limit: batchSize,
            offset: offset,
          );
          
          if (batch.isEmpty) break;
          
          allRows.addAll(batch);
          offset += batch.length;
          
          progressNotifier?.value = "正在导出$tableName表数据: ${allRows.length}条";
        }
        
        tableData[tableName] = allRows;
        print('已导出表 $tableName: ${allRows.length} 条记录');
      }

      // 文件名安全化函数
      String safeFileName(String base, String ext) {
        String name = base.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
        if (name.length > 40) name = name.substring(0, 40);
        return name + ext;
      }

      // 处理图片框数据和图片文件 - 分批处理优化
      List<Map<String, dynamic>> imageBoxes = tableData['image_boxes'] ?? [];
      List<Map<String, dynamic>> imageBoxesToExport = [];
      progressNotifier?.value = "正在处理图片文件...";
      const int imageBatchSize = 20;
      for (int i = 0; i < imageBoxes.length; i += imageBatchSize) {
        final int end = (i + imageBatchSize < imageBoxes.length) ? i + imageBatchSize : imageBoxes.length;
        final batch = imageBoxes.sublist(i, end);
        await Future.wait(batch.map((imageBox) async {
          Map<String, dynamic> imageBoxCopy = Map<String, dynamic>.from(imageBox);
          String? imagePath = imageBox['image_path'];
          String? imageBoxId = imageBox['id']?.toString();
          if (imagePath != null && imagePath.isNotEmpty && imageBoxId != null && imageBoxId.isNotEmpty) {
            String ext = p.extension(imagePath);
            String originalFileName = p.basenameWithoutExtension(imagePath);
            String fileName = safeFileName('${imageBoxId}_$originalFileName', ext);
            imageBoxCopy['imageFileName'] = fileName;
            File imageFile = File(imagePath);
            if (await imageFile.exists()) {
              String relativePath = 'images/$fileName';
              await Directory('$tempDirPath/images').create(recursive: true);
              final fileSize = await imageFile.length();
              if (fileSize > 10 * 1024 * 1024) {
                final sourceStream = imageFile.openRead();
                final targetSink = File('$tempDirPath/$relativePath').openWrite();
                await sourceStream.pipe(targetSink);
                await targetSink.close();
              } else {
                await imageFile.copy('$tempDirPath/$relativePath');
              }
              print('已导出图片框图片: $relativePath');
            } else {
              print('警告：图片文件不存在: $imagePath');
            }
          }
          imageBoxesToExport.add(imageBoxCopy);
        }));
        progressNotifier?.value = "正在处理图片文件: ${i + batch.length}/${imageBoxes.length}";
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

      // 处理音频框数据和音频文件 - 分批处理优化
      List<Map<String, dynamic>> audioBoxes = tableData['audio_boxes'] ?? [];
      List<Map<String, dynamic>> audioBoxesToExport = [];
      List<String> missingAudioFiles = [];
      progressNotifier?.value = "正在处理音频文件...";
      const int audioBatchSize = 10;
      for (int i = 0; i < audioBoxes.length; i += audioBatchSize) {
        final int end = (i + audioBatchSize < audioBoxes.length) ? i + audioBatchSize : audioBoxes.length;
        final batch = audioBoxes.sublist(i, end);
        await Future.wait(batch.map((audioBox) async {
          Map<String, dynamic> audioBoxCopy = Map<String, dynamic>.from(audioBox);
          String? audioPath = audioBox['audio_path'];
          String? audioBoxId = audioBox['id']?.toString();
          if (audioPath != null && audioPath.isNotEmpty && audioBoxId != null && audioBoxId.isNotEmpty) {
            String ext = p.extension(audioPath);
            String originalFileName = p.basenameWithoutExtension(audioPath);
            String fileName = safeFileName('${audioBoxId}_$originalFileName', ext);
            audioBoxCopy['audioFileName'] = fileName;
            File audioFile = File(audioPath);
            if (await audioFile.exists()) {
              String relativePath = 'audios/$fileName';
              await Directory('$tempDirPath/audios').create(recursive: true);
              final fileSize = await audioFile.length();
              if (fileSize > 5 * 1024 * 1024) {
                final sourceStream = audioFile.openRead();
                final targetSink = File('$tempDirPath/$relativePath').openWrite();
                await sourceStream.pipe(targetSink);
                await targetSink.close();
              } else {
                await audioFile.copy('$tempDirPath/$relativePath');
              }
              print('已导出音频文件: $relativePath');
            } else {
              print('警告：音频文件不存在: $audioPath');
              missingAudioFiles.add(audioPath);
            }
          }
          audioBoxesToExport.add(audioBoxCopy);
        }));
        progressNotifier?.value = "正在处理音频文件: ${i + batch.length}/${audioBoxes.length}";
      }
      tableData['audio_boxes'] = audioBoxesToExport;

      // 写入丢失音频文件列表到missing_audio_files.txt
      if (missingAudioFiles.isNotEmpty) {
        final File missingFile = File('$tempDirPath/missing_audio_files.txt');
        await missingFile.writeAsString(missingAudioFiles.join('\n'));
        print('[导出] 丢失音频文件数量: ${missingAudioFiles.length}');
        print('[导出] 丢失音频文件列表:');
        for (final f in missingAudioFiles) {
          print('  - $f');
        }
      }

      // 将数据库表数据保存为JSON文件 - 分批序列化优化
      progressNotifier?.value = "正在生成数据文件...";
      
      final File dbDataFile = File('$tempDirPath/directory_data.json');
      print('[导出] 即将写入数据文件: \'${dbDataFile.path}\'');
      final IOSink sink = dbDataFile.openWrite();
      
      // 分批序列化大数据，避免内存溢出
      sink.write('{');
      bool isFirst = true;
      for (String tableName in tableData.keys) {
        if (!isFirst) sink.write(',');
        isFirst = false;
        
        sink.write('"$tableName":');
        
        final List<Map<String, dynamic>> tableRows = tableData[tableName]!;
        if (tableRows.length > 1000) {
          // 大表分批序列化
          sink.write('[');
          for (int i = 0; i < tableRows.length; i++) {
            if (i > 0) sink.write(',');
            sink.write(jsonEncode(tableRows[i]));
            
            // 每100条记录刷新一次
            if (i % 100 == 0) {
              await sink.flush();
              progressNotifier?.value = "正在生成数据文件: $tableName ${i + 1}/${tableRows.length}";
            }
          }
          sink.write(']');
        } else {
          // 小表直接序列化
          sink.write(jsonEncode(tableRows));
        }
      }
      sink.write('}');
      await sink.close();
      print('[导出] 数据文件写入完成: \'${dbDataFile.path}\'');
      // 新增：写入后确认文件存在且大小大于0
      int retry = 0;
      while ((!await dbDataFile.exists() || await dbDataFile.length() == 0) && retry < 10) {
        print('[导出] 等待数据文件写入完成...');
        await Future.delayed(Duration(milliseconds: 100));
        retry++;
      }
      if (!await dbDataFile.exists() || await dbDataFile.length() == 0) {
        throw Exception('导出失败：未生成有效的directory_data.json数据文件');
      }
      print('[导出] 数据文件存在且有效，准备压缩...');
      // 压缩前打印临时目录下所有文件
      final allFilesPreZip = await Directory(tempDirPath).list(recursive: true).toList();
      print('[导出] 临时目录下文件:');
      for (final f in allFilesPreZip) {
        print('  - ${f.path}');
      }
      progressNotifier?.value = "正在创建压缩文件...";
      
      // 创建ZIP文件 - 使用流式ZipEncoder递归打包所有文件，彻底解决嵌套目录丢失问题
      final String timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '');
      final String zipPath = '$backupPath/directory_backup_$timestamp.zip';
      final tempDirEntity = Directory(tempDirPath);
      
      // 使用流式ZipEncoder避免内存溢出
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      
      await for (final entity in tempDirEntity.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: tempDirPath);
          print('[导出] 添加到ZIP: $relativePath');
          // addFile会以流的方式处理文件，避免读入内存
          await encoder.addFile(entity, relativePath);
        }
      }
      encoder.close();

      print('[导出] ZIP文件写入完成: $zipPath');

      // 压缩后校验ZIP包内容和音频/图片文件数量 - 使用流式解码避免内存溢出
      final inputStream = InputFileStream(zipPath);
      final archiveCheck = ZipDecoder().decodeStream(inputStream);

      try {
        // 校验图片文件数量
        int imageBoxCount = imageBoxesToExport.length;
        int zipImageCount = archiveCheck.where((file) => file.name.startsWith('images/') && !file.isDirectory).length;
        if (imageBoxCount != zipImageCount) {
          throw Exception('导出失败：图片文件数量不一致，数据库图片框$imageBoxCount个，ZIP包内$zipImageCount个，请联系开发者排查。');
        }
        // 校验音频文件数量
        int audioBoxCount = audioBoxesToExport.length;
        int zipAudioCount = archiveCheck.where((file) => file.name.startsWith('audios/') && !file.isDirectory).length;
        if (audioBoxCount != zipAudioCount) {
          throw Exception('导出失败：音频文件数量不一致，数据库音频框$audioBoxCount个，ZIP包内$zipAudioCount个，请联系开发者排查。');
        }
      } finally {
        await inputStream.close();
      }

      // 清理临时目录
      progressNotifier?.value = "正在清理临时文件...";
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        print('警告：清理临时目录失败: $e');
      }
      progressNotifier?.value = "导出完成";
      print('目录数据导出完成，ZIP文件路径: $zipPath');
      return zipPath;
    } catch (e, stackTrace) {
      _handleError('导出目录数据失败', e, stackTrace);
      rethrow;
    }
  }
  
  /// 导入目录数据 - 优化版，支持超大数据处理
  Future<void> importDirectoryData(String zipPath, {ValueNotifier<String>? progressNotifier}) async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String tempDirPath = '${appDocDir.path}/temp_import';
    final Directory tempDir = Directory(tempDirPath);
    try {
      print('开始导入目录数据...');
      progressNotifier?.value = "准备导入...";
      
      // 清理临时目录
      progressNotifier?.value = "正在清理临时目录...";
      if (await Directory(tempDirPath).exists()) {
        await Directory(tempDirPath).delete(recursive: true);
      }
      await Directory(tempDirPath).create(recursive: true);

      // 用流式InputFileStream解压ZIP文件 - 优化版
      progressNotifier?.value = "正在解压文件...";
      
      final inputStream = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(inputStream);
      
      int processedFiles = 0;
      final totalFiles = archive.length;
      
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File('$tempDirPath/$filename');
          await outFile.create(recursive: true);
          final outputStream = OutputFileStream(outFile.path);
          file.writeContent(outputStream);
          await outputStream.close();
        } else {
          await Directory('$tempDirPath/$filename').create(recursive: true);
        }
        processedFiles++;
        progressNotifier?.value = "正在解压: $processedFiles/$totalFiles";
      }
      await inputStream.close();

      // 读取目录数据 - 流式读取优化
      progressNotifier?.value = "正在读取数据文件...";
      
      File dbDataFile = File('$tempDirPath/directory_data.json');
      if (!await dbDataFile.exists()) {
        // 递归查找所有子目录
        List<FileSystemEntity> allFiles = await Directory(tempDirPath).list(recursive: true).toList();
        List<String> foundFiles = [];
        for (final f in allFiles) {
          if (f is File && f.path.endsWith('directory_data.json')) {
            dbDataFile = File(f.path);
            foundFiles.add(f.path);
          }
        }
        if (foundFiles.isEmpty) {
          throw Exception('备份中未找到directory_data.json数据文件。请确认导出的ZIP包结构正确。');
        } else if (foundFiles.length == 1) {
          // 找到唯一文件，继续
        } else {
          throw Exception('在多个位置找到directory_data.json文件，请检查备份包结构：\n${foundFiles.join('\n')}');
        }
      }

      final Map<String, dynamic> tableData = jsonDecode(await dbDataFile.readAsString());
      final db = await database;

      // 准备背景图片目录
      final String backgroundImagesPath = '${appDocDir.path}/background_images';
      await Directory(backgroundImagesPath).create(recursive: true);
      
      // 准备图片目录
      final String imagesDirPath = '${appDocDir.path}/images';
      await Directory(imagesDirPath).create(recursive: true);
      
      // 准备音频目录
      final String audiosDirPath = '${appDocDir.path}/audios';
      await Directory(audiosDirPath).create(recursive: true);

      progressNotifier?.value = "正在导入数据库...";
      
      await db.transaction((txn) async {
        // 定义所有相关表的列表
        const List<String> tableNames = [
          'folders', 'documents', 'text_boxes', 'image_boxes', 'audio_boxes', 
          'document_settings', 'directory_settings'
        ];
        
        // 为每个表创建临时表
        for (final tableName in tableNames) {

        // 确保目标表结构包含 text_segments 列（如缺）
        try {
          final cols = await txn.rawQuery("PRAGMA table_info(text_boxes)");
          final has = cols.any((c) => (c['name'] as String).toLowerCase() == 'text_segments');
          if (!has) {
            await txn.execute('ALTER TABLE text_boxes ADD COLUMN text_segments TEXT');
          }
        } catch (e) {
          if (kDebugMode) {
            print('检查/添加text_segments列失败: $e');
          }
        }

          await txn.execute('DROP TABLE IF EXISTS ${tableName}_temp');
          await txn.execute('CREATE TABLE ${tableName}_temp AS SELECT * FROM $tableName WHERE 0');
        }

        

        // === 读取每个临时表的列集合（白名单） ===
        final Map<String, Set<String>> allowedCols = {};
        for (final t in tableNames) {
          final cols = await txn.rawQuery('PRAGMA table_info(' + t + '_temp)');
          allowedCols[t] = { for (final r in cols) r['name'] as String };
        }

// 导入新数据到临时表
        final int batchSize = 100;
        for (var entry in tableData.entries) {
          final String tableName = entry.key;
          final List<dynamic> rows = entry.value;

          if (tableNames.contains(tableName)) {
            int processedRows = 0;
            for (int i = 0; i < rows.length; i += batchSize) {
              final end = (i + batchSize < rows.length) ? i + batchSize : rows.length;
              final batch = rows.sublist(i, end);
              
              for (var row in batch) {
                 if (tableName == 'media_items') continue;
                 Map<String, dynamic> newRow = Map<String, dynamic>.from(row);

                 // --- 开始路径修正逻辑 ---
                 if (tableName == 'image_boxes' && newRow.containsKey('imageFileName')) {
                   String newPath = p.join(imagesDirPath, newRow['imageFileName']);
                   String tempPath = p.join(tempDirPath, 'images', newRow['imageFileName']);
                   if(await File(tempPath).exists()) {
                     await File(tempPath).copy(newPath);
                     newRow['image_path'] = newPath;
                     print('[导入] 已导入图片框图片: $newPath');
                   } else {
                     print('[导入] 警告：未找到图片框图片文件: $tempPath');
                     newRow['image_path'] = null;
                   }
                   newRow.remove('imageFileName');
                 } else if (tableName == 'audio_boxes' && newRow.containsKey('audioFileName')) {
                   String newPath = p.join(audiosDirPath, newRow['audioFileName']);
                   String tempAudioPath = p.join(tempDirPath, 'audios', newRow['audioFileName']);
                   if (await File(tempAudioPath).exists()) {
                     await Directory(p.dirname(newPath)).create(recursive: true);
                     await File(tempAudioPath).copy(newPath);
                     newRow['audio_path'] = newPath;
                     print('[导入] 已导入音频文件: $newPath');
                   } else {
                     print('[导入] 警告：未找到音频文件: $tempAudioPath');
                     newRow['audio_path'] = null;
                   }
                   newRow.remove('audioFileName');
                 } else if ((tableName == 'directory_settings' || tableName == 'document_settings') && newRow.containsKey('backgroundImageFileName')) {
                   String newPath = p.join(backgroundImagesPath, newRow['backgroundImageFileName']);
                   String tempPath = p.join(tempDirPath, 'background_images', newRow['backgroundImageFileName']);
                   if(await File(tempPath).exists()) {
                     await File(tempPath).copy(newPath);
                     newRow['background_image_path'] = newPath;
                     print('[导入] 已导入背景图片: $newPath');
                   } else {
                     print('[导入] 警告：未找到背景图片文件: $tempPath');
                     newRow['background_image_path'] = null;
                   }
                   newRow.remove('backgroundImageFileName');
                 }
                 // --- 结束路径修正逻辑 ---

                 // === textBoxes 兼容旧字段名：textSegments -> text_segments，并统一为 JSON 字符串 ===
                 if (tableName == 'text_boxes') {
                   if (newRow.containsKey('textSegments') && !newRow.containsKey('text_segments')) {
                     newRow['text_segments'] = newRow['textSegments'];
                   }
                   if (newRow.containsKey('text_segments') && newRow['text_segments'] != null && newRow['text_segments'] is! String) {
                     try { newRow['text_segments'] = jsonEncode(newRow['text_segments']); } catch (_) {}
                   }
                   // 无论如何移除旧字段名，避免插入不存在的列
                   newRow.remove('textSegments');
                 }

                 // === 白名单过滤：仅保留目标表真实存在的列，杜绝 no column named ... ===
                 final allowed = allowedCols[tableName] ?? const <String>{};
                 final clean = <String, dynamic>{};
                 for (final k in newRow.keys) {
                   if (allowed.contains(k)) clean[k] = newRow[k];
                 }

                 await txn.insert('${tableName}_temp', clean);

                 processedRows++;
              }
              progressNotifier?.value = "正在导入$tableName表: $processedRows/${rows.length}";
            }
          }
        }
        
        // 所有数据成功导入临时表后，替换旧表
        for (final tableName in tableNames) {
          await txn.execute('DROP TABLE $tableName');
          await txn.execute('ALTER TABLE ${tableName}_temp RENAME TO $tableName');
        }
      });

      // 清理临时目录
      progressNotifier?.value = "正在清理临时文件...";
      try {
        await Directory(tempDirPath).delete(recursive: true);
      } catch (e) {
        print('警告：清理临时目录失败: $e');
        // 不影响主要功能，继续执行
      }

      progressNotifier?.value = "导入完成";
      print('目录数据导入完成');
    } catch (e, stackTrace) {
      _handleError('导入数据失败', e, stackTrace);
      rethrow;
    } finally {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {
          print('清理导入临时目录失败: $e');
        }
      }
    }
  }
  
  // 保留原来的方法名称，但内部调用新方法，以保持兼容性
  Future<String> exportAllData() async {
    return exportDirectoryData();
  }
  
  Future<void> importAllData(String zipPath, {ValueNotifier<String>? progressNotifier}) async {
    try {
      final file = File(zipPath);
      if (!await file.exists()) {
        progressNotifier?.value = '备份文件不存在: $zipPath';
        return;
      }
      await importDirectoryData(zipPath, progressNotifier: progressNotifier);
    } catch (e) {
      progressNotifier?.value = '导入失败: $e';
    }
  }

  // ==================== 文档和文件夹管理方法 ====================

  Future<void> deleteDocument(String documentName, {String? parentFolder}) async {
    final db = await database;
    
    try {
      await db.transaction((txn) async {
        // 首先获取文档ID
        List<Map<String, dynamic>> documents = await txn.query(
          'documents',
          columns: ['id'],
          where: 'name = ?',
          whereArgs: [documentName],
        );
        
        if (documents.isNotEmpty) {
          String documentId = documents.first['id'] as String;
          
          // 删除文档相关的所有数据
          await txn.delete(
            'text_boxes',
            where: 'document_id = ?',
            whereArgs: [documentId],
          );
          await txn.delete(
            'image_boxes',
            where: 'document_id = ?',
            whereArgs: [documentId],
          );
          await txn.delete(
            'audio_boxes',
            where: 'document_id = ?',
            whereArgs: [documentId],
          );
          await txn.delete(
            'document_settings',
            where: 'document_id = ?',
            whereArgs: [documentId],
          );
          
          // 删除文档本身
          await txn.delete(
            'documents',
            where: 'id = ?',
            whereArgs: [documentId],
          );
        }

        // 重新排序剩余文档
        String? parentFolderId;
        if (parentFolder != null) {
          final parentFolderData = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [parentFolder],
          );
          parentFolderId = parentFolderData.isNotEmpty ? parentFolderData.first['id'] as String? : null;
        }
        
        List<Map<String, dynamic>> remainingDocuments = await txn.query(
          'documents',
          where: parentFolderId == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
          whereArgs: parentFolderId == null ? null : [parentFolderId],
          orderBy: 'order_index ASC',
        );
        
        for (int i = 0; i < remainingDocuments.length; i++) {
          await txn.update(
            'documents',
            {'order_index': i},
            where: 'id = ?',
            whereArgs: [remainingDocuments[i]['id']],
          );
        }
      });
      
      if (kDebugMode) {
        print('成功删除文档: $documentName');
      }
    } catch (e, stackTrace) {
      _handleError('删除文档失败: $documentName', e, stackTrace);
      rethrow;
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
    
    try {
      // 使用事务确保数据一致性
      await db.transaction((txn) async {
        // 首先获取要删除的文件夹信息
        final folderToDelete = await txn.query(
          'folders',
          where: 'name = ?',
          whereArgs: [folderName],
        );
        
        if (folderToDelete.isEmpty) {
          throw Exception('文件夹不存在: $folderName');
        }
        
        final folderId = folderToDelete.first['id'] as String;
        
        // 递归删除文件夹及其所有子内容
        await _deleteFolderRecursive(txn, folderId, folderName);

        // 重新排序剩余文件夹
        String? parentFolderId;
        if (parentFolder != null) {
          final parentFolderData = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [parentFolder],
          );
          parentFolderId = parentFolderData.isNotEmpty ? parentFolderData.first['id'] as String? : null;
        }
        
        List<Map<String, dynamic>> remainingFolders = await txn.query(
          'folders',
          where: parentFolderId == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
          whereArgs: parentFolderId == null ? null : [parentFolderId],
          orderBy: 'order_index ASC',
        );
        
        for (int i = 0; i < remainingFolders.length; i++) {
          await txn.update(
            'folders',
            {'order_index': i},
            where: 'id = ?',
            whereArgs: [remainingFolders[i]['id']],
          );
        }
      });
      
      if (kDebugMode) {
        print('成功删除文件夹: $folderName');
      }
    } catch (e, stackTrace) {
      _handleError('删除文件夹失败: $folderName', e, stackTrace);
      rethrow;
    }
  }

  /// 在事务内部递归删除文件夹
  Future<void> _deleteFolderRecursive(Transaction txn, String folderId, String folderName) async {
    if (kDebugMode) {
      print('开始递归删除文件夹: $folderName (ID: $folderId)');
    }
    
    // 获取子文档
    List<Map<String, dynamic>> documents = await txn.query(
      'documents',
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );
    
    if (kDebugMode) {
      print('文件夹 $folderName 包含 ${documents.length} 个文档');
    }
    
    // 删除子文档
    for (var doc in documents) {
      final docId = doc['id'] as String;
      final docName = doc['name'] as String;
      if (kDebugMode) {
        print('删除文档: $docName (ID: $docId)');
      }
      await txn.delete('text_boxes', where: 'document_id = ?', whereArgs: [docId]);
      await txn.delete('image_boxes', where: 'document_id = ?', whereArgs: [docId]);
      await txn.delete('audio_boxes', where: 'document_id = ?', whereArgs: [docId]);
      await txn.delete('document_settings', where: 'document_id = ?', whereArgs: [docId]);
      await txn.delete('documents', where: 'id = ?', whereArgs: [docId]);
    }

    // 获取子文件夹
    List<Map<String, dynamic>> subFolders = await txn.query(
      'folders',
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );
    
    if (kDebugMode) {
      print('文件夹 $folderName 包含 ${subFolders.length} 个子文件夹');
    }
    
    // 递归删除子文件夹
    for (var subFolder in subFolders) {
      final subFolderId = subFolder['id'] as String;
      final subFolderName = subFolder['name'] as String;
      if (kDebugMode) {
        print('递归删除子文件夹: $subFolderName (ID: $subFolderId)');
      }
      await _deleteFolderRecursive(txn, subFolderId, subFolderName);
    }

    // 删除当前文件夹
    if (kDebugMode) {
      print('删除文件夹本身: $folderName (ID: $folderId)');
    }
    await txn.delete('folders', where: 'id = ?', whereArgs: [folderId]);
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
      
      // 数据验证和清理
      List<Map<String, dynamic>> validResults = [];
      for (var folder in result) {
        if (folder['name'] != null && folder['name'].toString().isNotEmpty) {
          validResults.add(Map<String, dynamic>.from(folder));
        } else {
          if (kDebugMode) {
            print('警告：发现无效文件夹数据，已跳过: $folder');
          }
        }
      }
      
      if (kDebugMode) {
        print('获取文件夹成功: ${validResults.length} 个有效文件夹');
      }
      
      return validResults;
    } catch (e, stackTrace) {
      _handleError('获取文件夹时出错', e, stackTrace);
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
      
      List<Map<String, dynamic>> result = await db.query(
        'documents',
        where: parentFolderId == null ? 'parent_folder IS NULL' : 'parent_folder = ?',
        whereArgs: parentFolderId == null ? null : [parentFolderId],
        orderBy: 'order_index ASC',
      );
      
      // 数据验证和清理
      List<Map<String, dynamic>> validResults = [];
      for (var document in result) {
        if (document['name'] != null && document['name'].toString().isNotEmpty) {
          validResults.add(Map<String, dynamic>.from(document));
        } else {
          if (kDebugMode) {
            print('警告：发现无效文档数据，已跳过: $document');
          }
        }
      }
      
      if (kDebugMode) {
        print('获取文档成功: ${validResults.length} 个有效文档');
      }
      
      return validResults;
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
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(Directory(tempDirPath), includeDirName: false);
      encoder.close();
      
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
      
      // 用流式InputFileStream解压ZIP文件
      final inputStream = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(inputStream);
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          File('$tempDirPath/$filename')
            ..createSync(recursive: true)
            ..writeAsBytesSync(data);
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
        for (var textBox in List.from(textBoxes)) {
          final data = Map<String, dynamic>.from(textBox);
          // 字段名转换：数据库风格 => 驼峰风格
          if (data.containsKey('position_x')) {
            data['positionX'] = data.remove('position_x');
          }
          if (data.containsKey('position_y')) {
            data['positionY'] = data.remove('position_y');
          }
          if (data.containsKey('content')) {
            data['text'] = data.remove('content');
          }
          if (data.containsKey('font_size')) {
            data['fontSize'] = data.remove('font_size');
          }
          if (data.containsKey('font_color')) {
            data['fontColor'] = data.remove('font_color');
          }
          if (data.containsKey('font_family')) {
            data['fontFamily'] = data.remove('font_family');
          }
          if (data.containsKey('font_weight')) {
            data['fontWeight'] = data.remove('font_weight');
          }
          if (data.containsKey('is_italic')) {
            data['isItalic'] = data.remove('is_italic');
          }
          if (data.containsKey('is_underlined')) {
            data['isUnderlined'] = data.remove('is_underlined');
          }
          if (data.containsKey('is_strike_through')) {
            data['isStrikeThrough'] = data.remove('is_strike_through');
          }
          if (data.containsKey('background_color')) {
            data['backgroundColor'] = data.remove('background_color');
          }
          if (data.containsKey('text_align')) {
            data['textAlign'] = data.remove('text_align');
          }
          // 先转换字段名再校验
          if (validateTextBoxData(data)) {
            data.remove('documentName');
            data['document_id'] = newDocumentId;
            data['created_at'] = DateTime.now().millisecondsSinceEpoch;
            data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
            // 再转为数据库字段名
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
            // Check if text box exists
            final existing = await txn.query(
              'text_boxes',
              where: 'document_id = ? AND id = ?',
              whereArgs: [newDocumentId, data['id']],
            );
            
            if (existing.isNotEmpty) {
              // Update existing text box
              data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
              await txn.update(
                'text_boxes',
                data,
                where: 'document_id = ? AND id = ?',
                whereArgs: [newDocumentId, data['id']],
              );
            } else {
              // Insert new text box
              await txn.insert(
                'text_boxes',
                data,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
          }
        }
        print('已导入 ${textBoxes.length} 个文本框');
        
        // 处理图片框和图片文件
        List<dynamic> imageBoxes = importData['image_boxes'] ?? [];
        for (var imageBox in List.from(imageBoxes)) {
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
              String targetPath = '${appDocDir.path}/audios/$audioFileName';
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
              String targetPath = '${appDocDir.path}/background_images/${newDocumentId}_$backgroundImageFileName';
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
      
      for (var textBox in List.from(textBoxes)) {
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
      
      for (var imageBox in List.from(imageBoxes)) {
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
      rethrow;
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
      }
      
      // 查询当前目录下的最大order_index（无论是根目录还是子文件夹）
      List<Map<String, dynamic>> docs = await db.query(
        'documents',
        where: 'parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}',
        whereArgs: parentFolderId != null ? [parentFolderId] : [],
        orderBy: 'order_index DESC',
        limit: 1
      );
      if (docs.isNotEmpty) {
        maxOrder = docs.first['order_index'] ?? 0;
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
      
      for (var textBox in List.from(textBoxes)) {
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

  Future<void> importDirectoryDataImpl(String zipPath) async {
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

      // 用流式InputFileStream解压ZIP文件
      final inputStream = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(inputStream);
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
      
      // 准备图片目录
      final String imagesDirPath = '${appDocDir.path}/images';
      await Directory(imagesDirPath).create(recursive: true);
      
      // 准备音频目录
      final String audiosDirPath = '${appDocDir.path}/audios';
      await Directory(audiosDirPath).create(recursive: true);

      await db.transaction((txn) async {
        // 清除现有数据
        await txn.delete('folders');
        await txn.delete('documents');
        await txn.delete('text_boxes');
        await txn.delete('image_boxes');
        await txn.delete('audio_boxes');
        await txn.delete('document_settings');
        await txn.delete('directory_settings');
        // await txn.delete('media_items'); // 修复：目录数据导入时不再清空媒体表

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
                String newPath = p.join(imagesDirPath, imageFileName);
                String tempPath = p.join(tempDirPath, 'images', imageFileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  imageBox['image_path'] = newPath; // 修正字段名称为image_path
                  print('已导入图片框图片: $newPath');
                }
              }
              await txn.insert(tableName, imageBox);
            }
          } else if (tableName == 'audio_boxes') {
            print('[导入调试] 正在导入audio_boxes, 行数: '+rows.length.toString());
            for (var row in rows) {
              Map<String, dynamic> audioBox = Map<String, dynamic>.from(row);
              String? audioFileName = audioBox.remove('audioFileName');
              print('[导入调试] audioBox: '+audioBox.toString()+', audioFileName: '+(audioFileName??'null'));
              if (audioFileName != null) {
                String audiosDirPath = p.join(appDocDir.path, 'audios');
                await Directory(audiosDirPath).create(recursive: true);
                String newPath = p.join(audiosDirPath, audioFileName);
                String tempPath = p.join(tempDirPath, 'audios', audioFileName);
                print('[导入音频] audioFileName: $audioFileName');
                print('[导入音频] tempPath: $tempPath');
                print('[导入音频] tempPath文件是否存在: ${await File(tempPath).exists()}');
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  print('[导入音频] 已复制音频文件: $tempPath -> $newPath');
                  audioBox['audio_path'] = newPath;
                } else {
                  print('[导入音频] 警告：未找到音频文件: $tempPath');
                  audioBox['audio_path'] = null;
                }
              } else {
                print('[导入音频] audioFileName字段为null');
              }
              audioBox.remove('audioPath');
              await txn.insert(tableName, audioBox);
            }
          } else {
            // 其他表正常导入（folders, documents, text_boxes）
            for (var row in rows) {
              // 修复：目录数据导入时不再导入media_items表
              if (tableName == 'media_items') continue;
              await txn.insert(tableName, Map<String, dynamic>.from(row));
            }
          }
        }
      });

      // 导入完成后再次校验所有音频文件存在性
      final db2 = await database;
      final List<Map<String, dynamic>> audioBoxes = await db2.query('audio_boxes');
      for (final audioBox in audioBoxes) {
        String? audioPath = audioBox['audio_path'];
        if (audioPath != null && audioPath.isNotEmpty) {
          if (!await File(audioPath).exists()) {
            print('[导入后校验] 音频文件不存在，清空路径: $audioPath');
            await db2.update('audio_boxes', {'audio_path': null}, where: 'id = ?', whereArgs: [audioBox['id']]);
          } else {
            print('[导入后校验] 音频文件存在: $audioPath');
          }
        }
      }

      // 清理临时目录
      await Directory(tempDirPath).delete(recursive: true);

      print('目录数据导入完成');
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
    if (data['position_x'] == null || data['position_y'] == null) {
      return false;
    }
    if (data['width'] == null || data['height'] == null) {
      return false;
    }
    if (data['image_path'] == null || data['image_path'].toString().isEmpty) {
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
    bool? clearImagePath, // 新增参数，明确指示是否要清除背景图片
  }) async {
    try {
      final db = await database;
      
      Map<String, dynamic> data = {
        'folder_name': folderName,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };
      
      // 只有在明确传递imagePath参数或clearImagePath为true时才更新背景图片字段
      if (clearImagePath == true) {
        data['background_image_path'] = null;
      } else if (imagePath != null) {
        data['background_image_path'] = imagePath;
      }
      // 如果imagePath为null且clearImagePath不为true，则不更新background_image_path字段
      
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
      // 使用新的insertOrUpdateDirectorySettings方法，明确指示清除背景图片
      await insertOrUpdateDirectorySettings(
        folderName: folderName,
        clearImagePath: true,
      );
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
      // 文档插入到同类末尾（所有文档的最大order_index+1，且order_index大于同目录下所有文件夹的最大order_index）
      final List<Map<String, dynamic>> folderResult = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM folders 
        WHERE parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}
      ''', parentFolderId != null ? [parentFolderId] : []);
      final List<Map<String, dynamic>> docResult = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM documents 
        WHERE parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}
      ''', parentFolderId != null ? [parentFolderId] : []);
      int folderMax = (folderResult.first['maxOrder'] ?? -1) + 1;
      int docOrder = (docResult.first['maxOrder'] ?? -1) + 1;
      int order = folderMax > docOrder ? folderMax : docOrder;
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
      // 获取父文件夹ID
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        if (folder == null) {
          throw Exception('父文件夹不存在');
        }
        parentFolderId = folder['id'];
      }
      // 文件夹插入到同类末尾
      final List<Map<String, dynamic>> result = await db.rawQuery('''
        SELECT MAX(`order_index`) as maxOrder FROM folders 
        WHERE parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}
      ''', parentFolderId != null ? [parentFolderId] : []);
      int order = (result.first['maxOrder'] ?? -1) + 1;
      await db.insert(
        'folders',
        {
          'id': const Uuid().v4(),
          'name': name,
          'parent_folder': parentFolderId,
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
        // Map text_segments (DB) -> textSegments (UI List)
        if (convertedMap.containsKey('text_segments')) {
          try {
            final raw = convertedMap.remove('text_segments');
            convertedMap['textSegments'] = (raw == null || raw == '') ? [] : jsonDecode(raw as String);
          } catch (_) {
            convertedMap['textSegments'] = [];
          }
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
        
        // Get existing text boxes for comparison
        final existingBoxes = await txn.query(
          'text_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        final existingIds = existingBoxes.map((box) => box['id'] as String).toSet();
        final newIds = textBoxes.map((box) => box['id'] as String).toSet();
        
        // Delete removed text boxes
        final idsToDelete = existingIds.difference(newIds);
        for (final id in idsToDelete) {
          await txn.delete(
            'text_boxes',
            where: 'document_id = ? AND id = ?',
            whereArgs: [documentId, id],
          );
        }
        
        // Insert or update text boxes
        for (var textBox in List.from(textBoxes)) {
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
            // Map textSegments (UI) -> text_segments (DB JSON string)
            if (data.containsKey('textSegments')) {
              try {
                final seg = data.remove('textSegments');
                data['text_segments'] = jsonEncode(seg);
              } catch (_) {
                data['text_segments'] = '[]';
              }
            }

            
            // Check if text box exists
            final existing = await txn.query(
              'text_boxes',
              where: 'document_id = ? AND id = ?',
              whereArgs: [documentId, data['id']],
            );
            
            if (existing.isNotEmpty) {
              // Update existing text box
              data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
              await txn.update(
                'text_boxes',
                data,
                where: 'document_id = ? AND id = ?',
                whereArgs: [documentId, data['id']],
              );
            } else {
              // Insert new text box
              await txn.insert(
                'text_boxes',
                data,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
            }
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
        
        // Get existing image boxes for comparison
        final existingBoxes = await txn.query(
          'image_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        final existingIds = existingBoxes.map((box) => box['id'] as String).toSet();
        final newIds = imageBoxes.map((box) => box['id'] as String).toSet();
        
        // Delete removed image boxes
        final idsToDelete = existingIds.difference(newIds);
        for (final id in idsToDelete) {
          await txn.delete(
            'image_boxes',
            where: 'document_id = ? AND id = ?',
            whereArgs: [documentId, id],
          );
        }
        
        // Insert or update image boxes
        for (var imageBox in List.from(imageBoxes)) {
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
          
          // Check if image box exists
          final existing = await txn.query(
            'image_boxes',
            where: 'document_id = ? AND id = ?',
            whereArgs: [documentId, data['id']],
          );
          
          if (existing.isNotEmpty) {
            // Update existing image box
            data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
            await txn.update(
              'image_boxes',
              data,
              where: 'document_id = ? AND id = ?',
              whereArgs: [documentId, data['id']],
            );
          } else {
            // Insert new image box
            await txn.insert(
              'image_boxes',
              data,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
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
        
        // Get existing audio boxes for comparison
        final existingBoxes = await txn.query(
          'audio_boxes',
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        
        final existingIds = existingBoxes.map((box) => box['id'] as String).toSet();
        final newIds = audioBoxes.map((box) => box['id'] as String).toSet();
        
        // Delete removed audio boxes
        final idsToDelete = existingIds.difference(newIds);
        for (final id in idsToDelete) {
          await txn.delete(
            'audio_boxes',
            where: 'document_id = ? AND id = ?',
            whereArgs: [documentId, id],
          );
        }
        
        // Insert or update audio boxes
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
          
          // Check if audio box exists
          final existing = await txn.query(
            'audio_boxes',
            where: 'document_id = ? AND id = ?',
            whereArgs: [documentId, data['id']],
          );
          
          if (existing.isNotEmpty) {
            // Update existing audio box
            data['updated_at'] = DateTime.now().millisecondsSinceEpoch;
            await txn.update(
              'audio_boxes',
              data,
              where: 'document_id = ? AND id = ?',
              whereArgs: [documentId, data['id']],
            );
          } else {
            // Insert new audio box
            await txn.insert(
              'audio_boxes',
              data,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
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
    bool? positionLocked,
  }) async {
    try {
      print('🔧 [DB] 开始插入或更新文档设置，文档名: $documentName');
      print('🔧 [DB] 传入参数 - imagePath: $imagePath, colorValue: $colorValue, textEnhanceMode: $textEnhanceMode, positionLocked: $positionLocked');
      
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
      print('🔧 [DB] 找到文档ID: $documentId');
      
      // Check if settings exist
      List<Map<String, dynamic>> existingSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      
      print('🔧 [DB] 现有设置数量: ${existingSettings.length}');
      if (existingSettings.isNotEmpty) {
        print('🔧 [DB] 现有设置: ${existingSettings.first}');
      }
      
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
        settingsData['position_locked'] = positionLocked != null
            ? (positionLocked ? 1 : 0)
            : existing['position_locked'];
        // 保留原有的created_at字段
        settingsData['created_at'] = existing['created_at'];
        print('🔧 [DB] 更新现有设置 - text_enhance_mode: ${settingsData['text_enhance_mode']}, position_locked: ${settingsData['position_locked']}');
      } else {
        settingsData['background_image_path'] = imagePath;
        settingsData['background_color'] = colorValue;
        settingsData['text_enhance_mode'] = textEnhanceMode != null ? (textEnhanceMode ? 1 : 0) : 1;
        settingsData['position_locked'] = positionLocked != null ? (positionLocked ? 1 : 0) : 1;
        settingsData['created_at'] = DateTime.now().millisecondsSinceEpoch;
        print('🔧 [DB] 创建新设置 - text_enhance_mode: ${settingsData['text_enhance_mode']}, position_locked: ${settingsData['position_locked']}');
      }
      
      print('🔧 [DB] 最终写入数据: $settingsData');
      
      if (existingSettings.isNotEmpty) {
        // 使用UPDATE操作更新现有记录
        await db.update(
          'document_settings',
          settingsData,
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        print('🔧 [DB] UPDATE操作完成');
      } else {
        // 使用INSERT操作创建新记录
        await db.insert('document_settings', settingsData);
        print('🔧 [DB] INSERT操作完成');
      }
      
      print('🔧 [DB] 数据库写入完成');
      
      // 验证写入结果
      List<Map<String, dynamic>> verifySettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      if (verifySettings.isNotEmpty) {
        print('🔧 [DB] 验证写入结果: ${verifySettings.first}');
      }
      
    } catch (e, stackTrace) {
      print('❌ [DB] 插入或更新文档设置失败: $e');
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
                  imageBox['image_path'] = newPath;
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
                String audiosDirPath = p.join(appDocDir.path, 'audios');
                await Directory(audiosDirPath).create(recursive: true);
                String newPath = p.join(audiosDirPath, audioFileName);
                String tempPath = p.join(tempDirPath, 'audios', audioFileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  print('[导入音频] 已复制音频文件: $tempPath -> $newPath');
                  audioBox['audio_path'] = newPath;
                } else {
                  print('[导入音频] 警告：未找到音频文件: $tempPath');
                  audioBox['audio_path'] = null;
                }
              } else if (audioBox['audio_path'] != null && !(await File(audioBox['audio_path']).exists())) {
                print('[导入音频] 警告：音频路径无效: ${audioBox['audio_path']}');
                audioBox['audio_path'] = null;
              }
              audioBox.remove('audioPath');
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
      
      // 导入完成后再次校验所有音频文件存在性
      final db2 = await database;
      final List<Map<String, dynamic>> audioBoxes = await db2.query('audio_boxes');
      for (final audioBox in audioBoxes) {
        String? audioPath = audioBox['audio_path'];
        if (audioPath != null && audioPath.isNotEmpty) {
          if (!await File(audioPath).exists()) {
            print('[导入后校验] 音频文件不存在，清空路径: $audioPath');
            await db2.update('audio_boxes', {'audio_path': null}, where: 'id = ?', whereArgs: [audioBox['id']]);
          } else {
            print('[导入后校验] 音频文件存在: $audioPath');
          }
        }
      }
      
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

  /// 物理备份整个数据库文件（带备注和meta，自动清理只保留10个）
  /// 物理备份整个数据库文件和媒体文件（带备注和meta，自动清理只保留10个）
  Future<void> backupDatabaseFileWithMeta({String? remark, bool isAuto = false, bool includeMediaFiles = true}) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDirectory.path, _databaseName);
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      print('数据库文件不存在，无需备份');
      return;
    }
    final backupDirPath = p.join(documentsDirectory.path, 'backups');
    final backupDir = Directory(backupDirPath);
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    final now = DateTime.now();
    final timeStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
    final safeRemark = (remark ?? (isAuto ? '自动备份' : '手动备份')).replaceAll(RegExp(r'[^\u4e00-\u9fa5A-Za-z0-9_-]'), '');
    
    // 创建备份目录
    final backupFolderName = '${_databaseName}_backup_${timeStr}_${safeRemark.isNotEmpty ? safeRemark : (isAuto ? 'auto' : 'manual')}';
    final backupFolderPath = p.join(backupDirPath, backupFolderName);
    await Directory(backupFolderPath).create(recursive: true);
    
    // 备份数据库文件
    final backupDbPath = p.join(backupFolderPath, _databaseName);
    await dbFile.copy(backupDbPath);
    
    // 如果需要包含媒体文件
    if (includeMediaFiles) {
      // 备份媒体文件
      final mediaDir = Directory(p.join(documentsDirectory.path, 'media'));
      if (await mediaDir.exists()) {
        final backupMediaDir = Directory(p.join(backupFolderPath, 'media'));
        await backupMediaDir.create(recursive: true);
        
        // 复制所有媒体文件
        await for (final entity in mediaDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = p.relative(entity.path, from: mediaDir.path);
            final targetPath = p.join(backupMediaDir.path, relativePath);
            await Directory(p.dirname(targetPath)).create(recursive: true);
            await entity.copy(targetPath);
          }
        }
      }
      
      // 备份图片文件
      final imagesDir = Directory(p.join(documentsDirectory.path, 'images'));
      if (await imagesDir.exists()) {
        final backupImagesDir = Directory(p.join(backupFolderPath, 'images'));
        await backupImagesDir.create(recursive: true);
        
        await for (final entity in imagesDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = p.relative(entity.path, from: imagesDir.path);
            final targetPath = p.join(backupImagesDir.path, relativePath);
            await Directory(p.dirname(targetPath)).create(recursive: true);
            await entity.copy(targetPath);
          }
        }
      }
      
      // 备份音频文件
      final audiosDir = Directory(p.join(documentsDirectory.path, 'audios'));
      if (await audiosDir.exists()) {
        final backupAudiosDir = Directory(p.join(backupFolderPath, 'audios'));
        await backupAudiosDir.create(recursive: true);
        
        await for (final entity in audiosDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = p.relative(entity.path, from: audiosDir.path);
            final targetPath = p.join(backupAudiosDir.path, relativePath);
            await Directory(p.dirname(targetPath)).create(recursive: true);
            await entity.copy(targetPath);
          }
        }
      }
      
      // 备份背景图片
      final backgroundImagesDir = Directory(p.join(documentsDirectory.path, 'background_images'));
      if (await backgroundImagesDir.exists()) {
        final backupBackgroundImagesDir = Directory(p.join(backupFolderPath, 'background_images'));
        await backupBackgroundImagesDir.create(recursive: true);
        
        await for (final entity in backgroundImagesDir.list(recursive: true)) {
          if (entity is File) {
            final relativePath = p.relative(entity.path, from: backgroundImagesDir.path);
            final targetPath = p.join(backupBackgroundImagesDir.path, relativePath);
            await Directory(p.dirname(targetPath)).create(recursive: true);
            await entity.copy(targetPath);
          }
        }
      }
    }
    
    // 压缩备份文件夹
    final backupZipPath = p.join(backupDirPath, '$backupFolderName.zip');
    final encoder = ZipFileEncoder();
    encoder.create(backupZipPath);
    await encoder.addDirectory(Directory(backupFolderPath));
    encoder.close();
    
    // 删除临时备份文件夹
    await Directory(backupFolderPath).delete(recursive: true);
    
    // 写入meta
    final metaFile = File(p.join(backupDirPath, 'backup_meta.json'));
    List<dynamic> metaList = [];
    if (await metaFile.exists()) {
      try {
        metaList = jsonDecode(await metaFile.readAsString());
      } catch (_) {}
    }
    metaList.insert(0, {
      'file': '$backupFolderName.zip',
      'remark': remark ?? (isAuto ? '自动备份' : '手动备份'),
      'type': isAuto ? 'auto' : 'manual',
      'time': now.toIso8601String(),
      'size': await File(backupZipPath).length(),
      'includeMediaFiles': includeMediaFiles,
    });
    // 只保留10个
    if (metaList.length > 10) {
      for (var i = 10; i < metaList.length; i++) {
        final old = metaList[i];
        final oldFile = File(p.join(backupDirPath, old['file']));
        if (await oldFile.exists()) await oldFile.delete();
      }
      metaList = metaList.sublist(0, 10);
    }
    await metaFile.writeAsString(jsonEncode(metaList));
    print('数据库${includeMediaFiles ? "和媒体文件" : ""}已物理备份到: $backupZipPath');
  }

  /// 物理恢复数据库文件（带meta）
  Future<void> restoreDatabaseFileWithMeta(String backupFileName) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDirectory.path, _databaseName);
    final backupDirPath = p.join(documentsDirectory.path, 'backups');
    final backupPath = p.join(backupDirPath, backupFileName);
    final backupFile = File(backupPath);
    if (!await backupFile.exists()) {
      print('备份文件不存在: $backupPath');
      throw Exception('备份文件不存在');
    }
    // 关闭数据库连接
    if (_database != null) {
      await _database!.close();
      _database = null;
      _isInitialized = false;
    }
    // 用备份覆盖
    await backupFile.copy(dbPath);
    // 重新初始化数据库
    await initialize();
    print('数据库已从备份恢复: $backupPath');
  }

  /// 应用启动时自动检测并执行24小时自动备份
  Future<void> autoBackupIfNeeded() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final backupDirPath = p.join(documentsDirectory.path, 'backups');
    final metaFile = File(p.join(backupDirPath, 'backup_meta.json'));
    List<dynamic> metaList = [];
    if (await metaFile.exists()) {
      try {
        metaList = jsonDecode(await metaFile.readAsString());
      } catch (_) {}
    }
    DateTime? lastAuto;
    int autoCount = 0;
    for (var meta in metaList) {
      if (meta['type'] == 'auto') {
        autoCount++;
        final t = DateTime.tryParse(meta['time'] ?? '');
        if (lastAuto == null || (t != null && t.isAfter(lastAuto))) lastAuto = t;
      }
    }
    final now = DateTime.now();
    if (lastAuto == null || now.difference(lastAuto).inHours >= 24) {
      final n = autoCount + 1;
      sizeMB() async {
        final dbPath = p.join(documentsDirectory.path, _databaseName);
        final dbFile = File(dbPath);
        if (await dbFile.exists()) {
          return (await dbFile.length() / 1024 / 1024).toStringAsFixed(2);
        }
        return '0.00';
      }
      final size = await sizeMB();
      final remark = '自动备份-第$n版-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} ${size}MB';
      await backupDatabaseFileWithMeta(remark: remark, isAuto: true);
    }
  }

  Future<void> clearAllData() async {
    final db = await database;
    // 关闭外键约束，防止级联删除冲突
    await db.execute('PRAGMA foreign_keys = OFF');
    await db.delete('folders');
    await db.delete('documents');
    await db.delete('text_boxes');
    await db.delete('image_boxes');
    await db.delete('audio_boxes');
    await db.delete('document_settings');
    await db.delete('directory_settings');
    await db.delete('cover_settings');
    await db.delete('cover_image');
    // ...如有其他表可补充
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// 获取所有媒体项（递归所有目录）
  Future<List<Map<String, dynamic>>> getAllMediaItems() async {
    final db = await database;
    return await db.query('media_items');
  }

  /// 替换所有媒体项（清空并批量插入）- 使用临时表保证事务安全
  Future<void> replaceAllMediaItems(List<dynamic> items) async {
    final db = await database;
    const tempTable = 'media_items_temp';

    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS $tempTable');
      await txn.execute('''
        CREATE TABLE $tempTable (
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
          telegram_file_id TEXT,
          is_favorite INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      final batch = txn.batch();
      for (var item in items) {
        batch.insert(tempTable, Map<String, dynamic>.from(item), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      await txn.execute('DROP TABLE IF EXISTS media_items');
      await txn.execute('ALTER TABLE $tempTable RENAME TO media_items');
    });
  }

  /// 替换所有日记条目（清空并批量插入）- 使用临时表保证事务安全
  Future<void> replaceAllDiaryEntries(List<DiaryEntry> entries) async {
    final db = await database;
    const tempTable = 'diary_entries_temp';

    await db.transaction((txn) async {
      // 0. 如果上次操作意外中断，先删除可能存在的旧临时表
      await txn.execute('DROP TABLE IF EXISTS $tempTable');

      // 1. 创建一个与原表结构相同的临时表
      await txn.execute('''
        CREATE TABLE $tempTable (
          id TEXT PRIMARY KEY,
          date TEXT NOT NULL,
          content TEXT,
          image_paths TEXT,
          audio_paths TEXT,
          video_paths TEXT,
          weather TEXT,
          mood TEXT,
          location TEXT,
          is_favorite INTEGER DEFAULT 0
        )
      ''');
      
      // 2. 将所有新数据批量插入临时表
      final batch = txn.batch();
      for (var entry in entries) {
        batch.insert(tempTable, entry.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      // 3. (可选) 在这里可以增加数据校验步骤，确保临时表数据正确无误

      // 4. 删除旧表
      await txn.execute('DROP TABLE IF EXISTS diary_entries');

      // 5. 将临时表重命名为正式表
      await txn.execute('ALTER TABLE $tempTable RENAME TO diary_entries');
    });
  }

  /// 获取日记本设置
  Future<Map<String, dynamic>?> getDiarySettings() async {
    try {
      final db = await database;
      final result = await db.query('diary_settings');
      if (result.isNotEmpty) {
        return result.first;
      }
      return null;
    } catch (e, stackTrace) {
      _handleError('获取日记本设置失败', e, stackTrace);
      return null;
    }
  }

  /// 插入或更新日记本设置
  Future<void> insertOrUpdateDiarySettings({String? imagePath, int? colorValue}) async {
    try {
      final db = await database;
      Map<String, dynamic> data = {
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
      // 查询是否已有设置
      final existing = await db.query('diary_settings');
      if (existing.isEmpty) {
        data['created_at'] = DateTime.now().millisecondsSinceEpoch;
        await db.insert('diary_settings', data);
      } else {
        data['created_at'] = existing.first['created_at'];
        await db.update('diary_settings', data);
      }
    } catch (e, stackTrace) {
      _handleError('插入或更新日记本设置失败', e, stackTrace);
      rethrow;
    }
  }

  /// 删除日记本背景图片
  Future<void> deleteDiaryBackgroundImage() async {
    try {
      final db = await database;
      await db.update('diary_settings', {'background_image_path': null});
    } catch (e, stackTrace) {
      _handleError('删除日记本背景图片失败', e, stackTrace);
      rethrow;
    }
  }

  /// 检查数据完整性
  Future<Map<String, dynamic>> checkDataIntegrity() async {
    final db = await database;
    Map<String, dynamic> report = {
      'isValid': true,
      'issues': [],
      'folderCount': 0,
      'documentCount': 0,
    };
    
    try {
      // 检查文件夹数据完整性
      final folders = await db.query('folders');
      report['folderCount'] = folders.length;
      
      for (var folder in folders) {
        if (folder['name'] == null || folder['name'].toString().isEmpty) {
          report['isValid'] = false;
          report['issues'].add('发现无效文件夹名称: ${folder['id']}');
        }
        
        // 检查父文件夹引用
        if (folder['parent_folder'] != null) {
          final parentExists = await db.query(
            'folders',
            where: 'id = ?',
            whereArgs: [folder['parent_folder']],
          );
          if (parentExists.isEmpty) {
            report['isValid'] = false;
            report['issues'].add('文件夹 ${folder['name']} 的父文件夹引用无效');
          }
        }
      }
      
      // 检查文档数据完整性
      final documents = await db.query('documents');
      report['documentCount'] = documents.length;
      
      for (var document in documents) {
        if (document['name'] == null || document['name'].toString().isEmpty) {
          report['isValid'] = false;
          report['issues'].add('发现无效文档名称: ${document['id']}');
        }
        
        // 检查父文件夹引用
        if (document['parent_folder'] != null) {
          final parentExists = await db.query(
            'folders',
            where: 'id = ?',
            whereArgs: [document['parent_folder']],
          );
          if (parentExists.isEmpty) {
            report['isValid'] = false;
            report['issues'].add('文档 ${document['name']} 的父文件夹引用无效');
          }
        }
      }
      
      if (kDebugMode) {
        print('数据完整性检查完成: ${report['isValid'] ? '通过' : '发现问题'}');
        if (report['issues'].isNotEmpty) {
          print('发现的问题:');
          for (var issue in report['issues']) {
            print('  - $issue');
          }
        }
      }
      
    } catch (e, stackTrace) {
      _handleError('数据完整性检查失败', e, stackTrace);
      report['isValid'] = false;
      report['issues'].add('检查过程出错: $e');
    }
    
    return report;
  }

  /// 修复数据完整性问题
  Future<void> repairDataIntegrity() async {
    final db = await database;
    
    try {
      await db.transaction((txn) async {
        // 修复无效的文件夹名称
        await txn.update(
          'folders',
          {'name': '未命名文件夹_${DateTime.now().millisecondsSinceEpoch}'},
          where: 'name IS NULL OR name = ""',
        );
        
        // 修复无效的文档名称
        await txn.update(
          'documents',
          {'name': '未命名文档_${DateTime.now().millisecondsSinceEpoch}'},
          where: 'name IS NULL OR name = ""',
        );
        
        // 清理无效的父文件夹引用
        await txn.update(
          'folders',
          {'parent_folder': null},
          where: 'parent_folder NOT IN (SELECT id FROM folders)',
        );
        
        await txn.update(
          'documents',
          {'parent_folder': null},
          where: 'parent_folder NOT IN (SELECT id FROM folders)',
        );
      });
      
      if (kDebugMode) {
        print('数据完整性修复完成');
      }
    } catch (e, stackTrace) {
      _handleError('数据完整性修复失败', e, stackTrace);
      rethrow;
    }
  }

  /// 复制文件夹（包含其子文件夹与文档）
  /// - sourceFolderName: 要复制的源文件夹名称
  /// - targetParentFolder: 复制后的新文件夹应放到的父文件夹名称；若为空，则与源文件夹同级
  Future<String> copyFolder(String sourceFolderName, {String? targetParentFolder}) async {
    final db = await database;

    // 1) 获取源文件夹信息
    final Map<String, dynamic>? sourceFolder = await getFolderByName(sourceFolderName);
    if (sourceFolder == null) {
      throw Exception('源文件夹不存在: $sourceFolderName');
    }

    // 2) 计算新文件夹的父级（名称）
    String? newParentFolderName = targetParentFolder;
    if (newParentFolderName == null) {
      final String? parentFolderId = sourceFolder['parent_folder'] as String?;
      if (parentFolderId != null) {
        final List<Map<String, dynamic>> parentRows = await db.query(
          'folders',
          where: 'id = ?',
          whereArgs: [parentFolderId],
          limit: 1,
        );
        if (parentRows.isNotEmpty) {
          newParentFolderName = parentRows.first['name'] as String?;
        }
      }
    }

    // 3) 生成唯一的新文件夹名称（如 名称-副本, 名称-副本(2) ...）
    String baseName = '$sourceFolderName-副本';
    String finalNewFolderName = baseName;
    int attempt = 0;
    while (await doesNameExist(finalNewFolderName)) {
      attempt++;
      finalNewFolderName = attempt > 1 ? '$baseName($attempt)' : baseName;
      if (attempt > 100) {
        throw Exception('无法为文件夹复制生成唯一名称');
      }
    }

    // 4) 创建新文件夹
    await insertFolder(finalNewFolderName, parentFolder: newParentFolderName);

    // 5) 复制目录设置（如背景图与颜色）
    try {
      final Map<String, dynamic>? settings = await getDirectorySettings(sourceFolderName);
      if (settings != null) {
        await insertOrUpdateDirectorySettings(
          folderName: finalNewFolderName,
          imagePath: settings['background_image_path'] as String?,
          colorValue: settings['background_color'] as int?,
        );
      }
    } catch (_) {
      // 忽略目录设置复制失败，不影响主体复制
    }

    // 6) 复制该文件夹下的文档
    final List<Map<String, dynamic>> docs = await getDocuments(parentFolder: sourceFolderName);
    for (final doc in docs) {
      final String docName = doc['name'] as String;
      await copyDocument(docName, parentFolder: finalNewFolderName);
    }

    // 7) 递归复制子文件夹
    final List<Map<String, dynamic>> subFolders = await getFolders(parentFolder: sourceFolderName);
    for (final folder in subFolders) {
      final String childFolderName = folder['name'] as String;
      await copyFolder(childFolderName, targetParentFolder: finalNewFolderName);
    }

    return finalNewFolderName;
  }
}
