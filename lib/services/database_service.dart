// lib/services/database_service.dart
// 重构后的数据库服务 - 提供更好的性能和错误处理

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Size;
import 'logger.dart';
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
import 'file_cleanup_service.dart';
import 'export_import_utils.dart';
import '../models/diary_entry.dart';
import '../utils/safe_path_utils.dart';
import '../utils/app_storage_paths.dart';
import '../utils/background_physical_file.dart';
import '../utils/background_video_volume_prefs.dart';
import '../models/background_media_origin.dart';
import '../models/video_view_params.dart';
import '../media_player_settings.dart';
import '../video_sequential_resume_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

/// 数据库服务 - 统一管理所有数据库操作
class DatabaseService {
  static const String _databaseName = 'change_app.db';
  static const int _databaseVersion =
      19; // 19: background_image_origin / background_video_origin

  Database? _database;
  final Completer<Database> _initCompleter = Completer<Database>();
  bool _isInitialized = false;

  /// 数据库连接池
  final Map<String, Database> _connectionPool = {};

  /// 性能监控Timer
  Timer? _performanceMonitoringTimer;

  /// 媒体预览取景（缩放/平移/旋转）的最新快照。
  ///
  /// [_persistMediaViewParams] 里 `await updateMediaItem` 未完成时用户若直接划掉应用，SQLite 可能仍是旧值；
  /// 进程内切换页面时列表内存已更新故看起来正常，冷启动从库读就会偏。此处先同步写入快照，在 [flushStagedVideoViewParamsToDisk]（如进入后台）时再保证落盘。
  final Map<String, VideoViewParams> _stagedVideoViewParamsByMediaId = {};

  /// 应用文档目录，用于取景参数 JSON 同步暂存（杀进程前 SQLite 可能未写完）。
  String? _appDocumentsDirectoryPath;

  static const String _videoViewStagingJsonFileName =
      'media_view_params_staging.json';
  static const String _backgroundFileViewParamsTable =
      'background_file_view_params';

  /// 初始化数据库服务
  Future<void> initialize() async {
    if (_isInitialized) {
      // 热重载等场景下已初始化但磁盘库可能未补全新列：再跑一遍补全。
      if (_database != null) {
        await _ensureMediaItemsInsertColumns(_database!);
        await _ensureMediaItemsKenBurnsColumns(_database!);
        await _ensureMediaItemsVideoViewColumns(_database!);
        await _ensureMediaItemsRecycleColumns(_database!);
        await _ensureMediaItemsIndexes(_database!);
        try {
          final d = await getApplicationDocumentsDirectory();
          _appDocumentsDirectoryPath = d.path;
          await _mergeVideoViewStagingJsonIfNeeded();
        } catch (_) {}
        try {
          await _ensureBackgroundVideoPathColumns(_database!);
        } catch (_) {}
        try {
          await _ensureBackgroundMediaOriginColumns(_database!);
        } catch (_) {}
      }
      return;
    }

    try {
      final documentsDirectory = await getApplicationDocumentsDirectory();
      _appDocumentsDirectoryPath = documentsDirectory.path;
      final dbPath = p.join(documentsDirectory.path, _databaseName);

      _database = await openDatabase(
        dbPath,
        version: _databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: _onConfigure,
      );

      // 主动检查diary_entries表
      final tables = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='diary_entries'",
      );
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
      await _ensureLastScrollOffsetColumn();

      // 部分环境未走 onUpgrade 或旧表缺少列：补全渐进放大中心点字段
      await _ensureMediaItemsInsertColumns(_database!);
      await _ensureMediaItemsKenBurnsColumns(_database!);
      await _ensureMediaItemsVideoViewColumns(_database!);
      await _ensureMediaItemsRecycleColumns(_database!);
      await _ensureMediaItemsIndexes(_database!);
      await _ensureBackgroundFileViewParamsTable(_database!);
      await _ensureBackgroundVideoPathColumns(_database!);
      await _ensureBackgroundMediaOriginColumns(_database!);
      try {
        await _recoverMediaImportSwapIfNeededOnDb(_database!);
      } catch (e, stack) {
        _handleError('媒体导入恢复检查失败（已忽略）', e, stack);
      }

      _initCompleter.complete(_database!);
      _isInitialized = true;

      await _mergeVideoViewStagingJsonIfNeeded();

      // 启动性能监控
      _startPerformanceMonitoring();

      if (kDebugMode) {
        Logger.log('DatabaseService: 数据库初始化完成');
      }
    } catch (e, stackTrace) {
      _handleError('数据库初始化失败', e, stackTrace);
      _initCompleter.completeError(e);
      rethrow;
    }
  }

  Future<void> replaceMediaItemsPathPrefix({
    required String oldPrefix,
    required String newPrefix,
  }) async {
    final db = await database;
    await _replaceMediaItemsPathPrefixOnDb(
      db,
      oldPrefix: oldPrefix,
      newPrefix: newPrefix,
    );
  }

  Future<void> _replaceMediaItemsPathPrefixOnDb(
    Database db, {
    required String oldPrefix,
    required String newPrefix,
  }) async {
    if (oldPrefix.isEmpty || newPrefix.isEmpty || oldPrefix == newPrefix)
      return;
    final oldNorm = p.normalize(oldPrefix);
    final newNorm = p.normalize(newPrefix);
    final oldWithSep =
        oldNorm.endsWith(p.separator) ? oldNorm : '$oldNorm${p.separator}';
    final newWithSep =
        newNorm.endsWith(p.separator) ? newNorm : '$newNorm${p.separator}';
    final likeArg = '$oldWithSep%';
    final startIndex = oldWithSep.length + 1;
    await db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE media_items SET path = ? || substr(path, ?) WHERE path LIKE ?',
        [newWithSep, startIndex, likeArg],
      );
    });
  }

  Future<void> _recoverMediaImportSwapIfNeededOnDb(Database db) async {
    final root = _appDocumentsDirectoryPath;
    if (root == null || root.isEmpty) return;
    final mediaDirPath = p.join(root, 'media');
    final mediaNewPath = p.join(root, 'media_new_import');
    final countNew =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(1) as c FROM media_items WHERE path LIKE ?',
            ['$mediaNewPath%'],
          ),
        ) ??
        0;
    if (countNew <= 0) return;

    final mediaDir = Directory(mediaDirPath);
    final mediaNewDir = Directory(mediaNewPath);
    final existsMedia = await mediaDir.exists();
    final existsNew = await mediaNewDir.exists();

    if (existsMedia && !existsNew) {
      await _replaceMediaItemsPathPrefixOnDb(
        db,
        oldPrefix: mediaNewPath,
        newPrefix: mediaDirPath,
      );
      return;
    }

    final backupDir = Directory(
      p.join(
        root,
        'media_backup_recover_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    try {
      if (existsMedia && existsNew) {
        await mediaDir.rename(backupDir.path);
        await mediaNewDir.rename(mediaDirPath);
        await _replaceMediaItemsPathPrefixOnDb(
          db,
          oldPrefix: mediaNewPath,
          newPrefix: mediaDirPath,
        );
        try {
          if (await backupDir.exists()) {
            await backupDir.delete(recursive: true);
          }
        } catch (_) {}
        return;
      }
      if (!existsMedia && existsNew) {
        await mediaNewDir.rename(mediaDirPath);
        await _replaceMediaItemsPathPrefixOnDb(
          db,
          oldPrefix: mediaNewPath,
          newPrefix: mediaDirPath,
        );
      }
    } catch (e) {
      try {
        if (!await mediaDir.exists() && await backupDir.exists()) {
          await backupDir.rename(mediaDirPath);
        }
      } catch (_) {}
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
      // 注意：部分 Android 设备上 PRAGMA 需用 rawQuery，且 busy_timeout 可能不兼容，已移除
      await db.rawQuery('PRAGMA foreign_keys = ON');
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.rawQuery('PRAGMA synchronous = FULL');
      await db.rawQuery('PRAGMA cache_size = 10000');
      await db.rawQuery('PRAGMA temp_store = FILE');
      await db.rawQuery('PRAGMA page_size = 4096');
      await db.rawQuery('PRAGMA auto_vacuum = INCREMENTAL');

      if (kDebugMode) {
        Logger.log('数据库配置成功应用');
      }
    } catch (e, stackTrace) {
      _handleError('配置数据库连接失败', e, stackTrace);
      if (kDebugMode) {
        Logger.log('配置数据库连接失败: $e');
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

      // 可翻转画布表（正反面内容ID使用逗号分隔存储）
      await txn.execute('''
        CREATE TABLE canvases(
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL,
          position_x REAL NOT NULL,
          position_y REAL NOT NULL,
          width REAL NOT NULL,
          height REAL NOT NULL,
          is_flipped INTEGER DEFAULT 0,
          front_text_box_ids TEXT,
          front_image_box_ids TEXT,
          front_audio_box_ids TEXT,
          back_text_box_ids TEXT,
          back_image_box_ids TEXT,
          back_audio_box_ids TEXT,
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
          sort_order INTEGER,
          ken_burns_center_x REAL,
          ken_burns_center_y REAL,
          video_view_scale REAL DEFAULT 1,
          video_view_tx REAL DEFAULT 0,
          video_view_ty REAL DEFAULT 0,
          video_view_rot INTEGER DEFAULT 0,
          video_view_basis_w REAL,
          video_view_basis_h REAL,
          video_view_anchor_x REAL,
          video_view_anchor_y REAL,
          deleted_from_directory TEXT,
          deleted_at INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      // 文档设置表
      await txn.execute('''
        CREATE TABLE document_settings(
          document_id TEXT PRIMARY KEY,
          background_image_path TEXT,
          background_video_path TEXT,
          background_image_origin INTEGER,
          background_video_origin INTEGER,
          background_color INTEGER,
          text_enhance_mode INTEGER DEFAULT 0,
          position_locked INTEGER DEFAULT 1,
          last_scroll_offset REAL DEFAULT 0,
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
          background_video_path TEXT,
          background_image_origin INTEGER,
          background_video_origin INTEGER,
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
          background_video_path TEXT,
          background_image_origin INTEGER,
          background_video_origin INTEGER,
          background_color INTEGER,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');

      // 创建索引以提高查询性能
      await _createIndexes(txn);
      await _ensureBackgroundFileViewParamsTable(txn);
    });
  }

  /// 创建数据库索引
  Future<void> _createIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX idx_folders_parent ON folders(parent_folder)',
    );
    await db.execute(
      'CREATE INDEX idx_documents_parent ON documents(parent_folder)',
    );
    await db.execute(
      'CREATE INDEX idx_text_boxes_document ON text_boxes(document_id)',
    );
    await db.execute(
      'CREATE INDEX idx_image_boxes_document ON image_boxes(document_id)',
    );
    await db.execute(
      'CREATE INDEX idx_audio_boxes_document ON audio_boxes(document_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_canvases_document ON canvases(document_id)',
    );
    await db.execute(
      'CREATE INDEX idx_media_items_directory ON media_items(directory)',
    );
    await db.execute('CREATE INDEX idx_media_items_type ON media_items(type)');
    await db.execute(
      'CREATE INDEX idx_media_items_hash ON media_items(file_hash)',
    );
    await db.execute(
      'CREATE INDEX idx_media_items_telegram_file_id ON media_items(telegram_file_id)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS imported_asset_ids(
        asset_id TEXT PRIMARY KEY
      )
    ''');
  }

  Future<void> _ensureMediaItemsIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_directory ON media_items(directory)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_type ON media_items(type)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_hash ON media_items(file_hash)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_media_items_telegram_file_id '
      'ON media_items(telegram_file_id)',
    );
  }

  Future<void> _ensureBackgroundFileViewParamsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_backgroundFileViewParamsTable(
        path TEXT PRIMARY KEY,
        normalized_path TEXT,
        slash_path TEXT,
        file_hash TEXT,
        video_view_scale REAL DEFAULT 1,
        video_view_tx REAL DEFAULT 0,
        video_view_ty REAL DEFAULT 0,
        video_view_rot INTEGER DEFAULT 0,
        video_view_basis_w REAL,
        video_view_basis_h REAL,
        video_view_anchor_x REAL,
        video_view_anchor_y REAL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_background_file_view_params_norm
      ON $_backgroundFileViewParamsTable(normalized_path)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_background_file_view_params_slash
      ON $_backgroundFileViewParamsTable(slash_path)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_background_file_view_params_hash
      ON $_backgroundFileViewParamsTable(file_hash)
    ''');
  }

  /// 热重载或旧库补列：各页背景视频路径。
  Future<void> _ensureBackgroundVideoPathColumns(Database db) async {
    const column = 'background_video_path';
    for (final table in [
      'directory_settings',
      'document_settings',
      'diary_settings',
      'cover_settings',
    ]) {
      try {
        final rows = await db.rawQuery('PRAGMA table_info($table)');
        if (rows.any((r) => r['name'] == column)) continue;
      } catch (_) {
        continue;
      }
      try {
        await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
      } catch (_) {}
    }
  }

  /// 背景图/视频来源（拍照可删副本，相册与媒体库不删文件）。
  Future<void> _ensureBackgroundMediaOriginColumns(DatabaseExecutor db) async {
    const pairs = [
      ('background_image_origin', 'INTEGER'),
      ('background_video_origin', 'INTEGER'),
    ];
    for (final table in [
      'directory_settings',
      'document_settings',
      'diary_settings',
      'cover_settings',
    ]) {
      for (final pair in pairs) {
        final column = pair.$1;
        try {
          final rows = await db.rawQuery('PRAGMA table_info($table)');
          if (rows.any((r) => r['name'] == column)) continue;
        } catch (_) {
          continue;
        }
        try {
          await db.execute(
            'ALTER TABLE $table ADD COLUMN ${pair.$1} ${pair.$2}',
          );
        } catch (_) {}
      }
    }
  }

  Future<String?> _computeFileHashIfExists(String pathStr) async {
    final file = File(pathStr);
    if (!await file.exists()) return null;
    final digest = await md5.bind(file.openRead()).first;
    final hash = digest.toString();
    return hash.isEmpty ? null : hash;
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
      Logger.log('DatabaseService: 升级数据库从版本 $oldVersion 到 $newVersion');
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
      case 11:
      case 12:
        // 版本 11/12 无 schema 变更，仅用于强制升级或兼容性
        break;
      case 13:
        // 静默导入去重：记录已导入的 asset_id，防止重复导入
        await db.execute('''
          CREATE TABLE IF NOT EXISTS imported_asset_ids(
            asset_id TEXT PRIMARY KEY
          )
        ''');
        if (kDebugMode) Logger.log('已创建 imported_asset_ids 表');
        break;
      case 14:
        // 渐进放大（Ken Burns）自定义缩放中心，归一化坐标 0～1（与导出 JSON 一并备份）
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN ken_burns_center_x REAL',
          );
        } catch (_) {}
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN ken_burns_center_y REAL',
          );
        } catch (_) {}
        if (kDebugMode) {
          Logger.log('已添加 ken_burns_center_x/y 列到 media_items');
        }
        break;
      case 15:
        // 视频播放：缩放/平移（归一化）、顺时针四分之一圈数 0～3
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_scale REAL DEFAULT 1',
          );
        } catch (_) {}
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_tx REAL DEFAULT 0',
          );
        } catch (_) {}
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_ty REAL DEFAULT 0',
          );
        } catch (_) {}
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_rot INTEGER DEFAULT 0',
          );
        } catch (_) {}
        if (kDebugMode) {
          Logger.log('已添加 video_view_scale/tx/ty/rot 列到 media_items');
        }
        break;
      case 16:
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_basis_w REAL',
          );
        } catch (_) {}
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN video_view_basis_h REAL',
          );
        } catch (_) {}
        if (kDebugMode) {
          Logger.log('已添加 video_view_basis_w/h 列到 media_items');
        }
        break;
      case 18:
        for (final table in [
          'directory_settings',
          'document_settings',
          'diary_settings',
          'cover_settings',
        ]) {
          try {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN background_video_path TEXT',
            );
          } catch (_) {}
        }
        if (kDebugMode) {
          Logger.log('已添加 background_video_path 列（目录/文档/日记/封面）');
        }
        break;
      case 19:
        await _ensureBackgroundMediaOriginColumns(db);
        if (kDebugMode) {
          Logger.log('已添加背景媒体来源列（目录/文档/日记/封面）');
        }
        break;
      case 8:
        // 添加新的字段和索引
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN file_size INTEGER DEFAULT 0',
        );
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN duration INTEGER DEFAULT 0',
        );
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN thumbnail_path TEXT',
        );
        await db.execute('ALTER TABLE media_items ADD COLUMN file_hash TEXT');
        await db.execute(
          'ALTER TABLE media_items ADD COLUMN is_favorite INTEGER DEFAULT 0',
        );
        await _createIndexes(db);
        break;
      case 9:
        // 历史迁移：telegram_file_id 列（已废弃，保留以兼容旧数据）
        try {
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN telegram_file_id TEXT',
          );
          await db.execute(
            'CREATE INDEX idx_media_items_telegram_file_id ON media_items(telegram_file_id)',
          );
          if (kDebugMode) {
            Logger.log('已添加telegram_file_id列到media_items表');
          }
        } catch (e) {
          if (kDebugMode) {
            Logger.log('添加telegram_file_id列失败: $e');
          }
        }
        break;
      case 10:
        // 为document_settings表添加position_locked字段
        try {
          await db.execute(
            'ALTER TABLE document_settings ADD COLUMN position_locked INTEGER DEFAULT 1',
          );
          if (kDebugMode) {
            Logger.log('已添加position_locked列到document_settings表');
          }
        } catch (e) {
          if (kDebugMode) {
            Logger.log('添加position_locked列失败: $e');
          }
        }
        break;
    }
  }

  /// 确保document_settings表存在position_locked字段
  Future<void> _ensurePositionLockedColumn() async {
    try {
      // 检查position_locked字段是否存在
      final columns = await _database!.rawQuery(
        "PRAGMA table_info(document_settings)",
      );
      bool hasPositionLocked = false;

      for (final column in columns) {
        if (column['name'] == 'position_locked') {
          hasPositionLocked = true;
          break;
        }
      }

      if (!hasPositionLocked) {
        if (kDebugMode) {
          Logger.log('🔧 [DB] document_settings表缺少position_locked字段，正在添加...');
        }
        await _database!.execute(
          'ALTER TABLE document_settings ADD COLUMN position_locked INTEGER DEFAULT 1',
        );
        if (kDebugMode) {
          Logger.log('✅ [DB] 已成功添加position_locked字段到document_settings表');
        }
      } else {
        if (kDebugMode) {
          Logger.log('✅ [DB] document_settings表已存在position_locked字段');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('❌ [DB] 检查或添加position_locked字段失败: $e');
      }
      // 不抛出异常，避免影响数据库初始化
    }
  }

  Future<void> _ensureLastScrollOffsetColumn() async {
    try {
      final columns = await _database!.rawQuery(
        "PRAGMA table_info(document_settings)",
      );
      var hasLastScrollOffset = false;
      for (final column in columns) {
        if (column['name'] == 'last_scroll_offset') {
          hasLastScrollOffset = true;
          break;
        }
      }

      if (!hasLastScrollOffset) {
        if (kDebugMode) {
          Logger.log(
            '🔧 [DB] document_settings表缺少last_scroll_offset字段，正在添加...',
          );
        }
        await _database!.execute(
          'ALTER TABLE document_settings ADD COLUMN last_scroll_offset REAL DEFAULT 0',
        );
        if (kDebugMode) {
          Logger.log('✅ [DB] 已成功添加last_scroll_offset字段到document_settings表');
        }
      } else {
        if (kDebugMode) {
          Logger.log('✅ [DB] document_settings表已存在last_scroll_offset字段');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('❌ [DB] 检查或添加last_scroll_offset字段失败: $e');
      }
    }
  }

  /// 确保canvases表存在（兼容旧版本数据库）
  Future<void> _ensureCanvasesTableExists() async {
    try {
      final tables = await _database!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='canvases'",
      );
      if (tables.isEmpty) {
        if (kDebugMode) {
          Logger.log('🔧 [DB] canvases表不存在，正在创建...');
        }
        await _database!.execute('''
          CREATE TABLE IF NOT EXISTS canvases(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            position_x REAL NOT NULL,
            position_y REAL NOT NULL,
            width REAL NOT NULL,
            height REAL NOT NULL,
            is_flipped INTEGER DEFAULT 0,
            front_text_box_ids TEXT,
            front_image_box_ids TEXT,
            front_audio_box_ids TEXT,
            back_text_box_ids TEXT,
            back_image_box_ids TEXT,
            back_audio_box_ids TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            FOREIGN KEY (document_id) REFERENCES documents (id) ON DELETE CASCADE
          )
        ''');
        if (kDebugMode) {
          Logger.log('✅ [DB] canvases表创建完成');
        }
        // 创建索引（如果未创建）
        try {
          await _database!.execute(
            'CREATE INDEX IF NOT EXISTS idx_canvases_document ON canvases(document_id)',
          );
        } catch (_) {}
      } else {
        if (kDebugMode) {
          Logger.log('✅ [DB] canvases表已存在');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('❌ [DB] 检查或创建canvases表失败: $e');
      }
    }
  }

  /// 启动性能监控
  void _startPerformanceMonitoring() {
    if (kDebugMode) {
      _performanceMonitoringTimer = Timer.periodic(const Duration(minutes: 5), (
        timer,
      ) {
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
        _handleError(
          '数据库完整性检查失败',
          Exception('Database integrity check failed'),
          null,
        );
      }

      // 检查数据库大小
      final sizeResult = await db.rawQuery('PRAGMA page_count');
      final pageSize = await db.rawQuery('PRAGMA page_size');

      if (sizeResult.isNotEmpty && pageSize.isNotEmpty) {
        final dbSize =
            (sizeResult.first['page_count'] as int) *
            (pageSize.first['page_size'] as int);
        getService<AppPerformanceState>().addPerformanceLog(
          '数据库大小: ${(dbSize / 1024 / 1024).toStringAsFixed(2)} MB',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('DatabaseService: 性能分析失败 - $e');
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
      // 取消性能监控Timer
      _performanceMonitoringTimer?.cancel();
      _performanceMonitoringTimer = null;

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
        Logger.log('DatabaseService: 资源清理完成');
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('DatabaseService dispose error: $e');
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

  /// 若 `media_items` 缺少渐进放大中心列则补全（与版本迁移互补，避免旧库/旁路建表漏列）。
  Future<void> _ensureMediaItemsKenBurnsColumns(DatabaseExecutor db) async {
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';",
      );
      if (tables.isEmpty) return;

      Future<void> addIfMissing(String columnName, String alterSql) async {
        final columns = await db.rawQuery('PRAGMA table_info(media_items);');
        final names = columns.map((c) => c['name'] as String).toSet();
        if (!names.contains(columnName)) {
          await db.execute(alterSql);
          if (kDebugMode) {
            Logger.log('已补全 media_items.$columnName');
          }
        }
      }

      await addIfMissing(
        'ken_burns_center_x',
        'ALTER TABLE media_items ADD COLUMN ken_burns_center_x REAL',
      );
      await addIfMissing(
        'ken_burns_center_y',
        'ALTER TABLE media_items ADD COLUMN ken_burns_center_y REAL',
      );
    } catch (e, stackTrace) {
      _handleError('补全 ken_burns 列失败', e, stackTrace);
      rethrow;
    }
  }

  /// 若 `media_items` 缺少视频视窗变换列则补全。
  Future<void> _ensureMediaItemsVideoViewColumns(DatabaseExecutor db) async {
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';",
      );
      if (tables.isEmpty) return;

      Future<void> addIfMissing(String columnName, String alterSql) async {
        final columns = await db.rawQuery('PRAGMA table_info(media_items);');
        final names = columns.map((c) => c['name'] as String).toSet();
        if (!names.contains(columnName)) {
          await db.execute(alterSql);
          if (kDebugMode) {
            Logger.log('已补全 media_items.$columnName');
          }
        }
      }

      await addIfMissing(
        'video_view_scale',
        'ALTER TABLE media_items ADD COLUMN video_view_scale REAL DEFAULT 1',
      );
      await addIfMissing(
        'video_view_tx',
        'ALTER TABLE media_items ADD COLUMN video_view_tx REAL DEFAULT 0',
      );
      await addIfMissing(
        'video_view_ty',
        'ALTER TABLE media_items ADD COLUMN video_view_ty REAL DEFAULT 0',
      );
      await addIfMissing(
        'video_view_rot',
        'ALTER TABLE media_items ADD COLUMN video_view_rot INTEGER DEFAULT 0',
      );
      await addIfMissing(
        'video_view_basis_w',
        'ALTER TABLE media_items ADD COLUMN video_view_basis_w REAL',
      );
      await addIfMissing(
        'video_view_basis_h',
        'ALTER TABLE media_items ADD COLUMN video_view_basis_h REAL',
      );
      await addIfMissing(
        'video_view_anchor_x',
        'ALTER TABLE media_items ADD COLUMN video_view_anchor_x REAL',
      );
      await addIfMissing(
        'video_view_anchor_y',
        'ALTER TABLE media_items ADD COLUMN video_view_anchor_y REAL',
      );
    } catch (e, stackTrace) {
      _handleError('补全 video_view 列失败', e, stackTrace);
      rethrow;
    }
  }

  /// Ensure soft-delete metadata exists for media recycle-bin restore.
  Future<void> _ensureMediaItemsRecycleColumns(DatabaseExecutor db) async {
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';",
      );
      if (tables.isEmpty) return;

      Future<void> addIfMissing(String columnName, String alterSql) async {
        final columns = await db.rawQuery('PRAGMA table_info(media_items);');
        final names = columns.map((c) => c['name'] as String).toSet();
        if (!names.contains(columnName)) {
          await db.execute(alterSql);
          if (kDebugMode) {
            Logger.log('已补全 media_items.$columnName');
          }
        }
      }

      await addIfMissing(
        'deleted_from_directory',
        'ALTER TABLE media_items ADD COLUMN deleted_from_directory TEXT',
      );
      await addIfMissing(
        'deleted_at',
        'ALTER TABLE media_items ADD COLUMN deleted_at INTEGER',
      );
    } catch (e, stackTrace) {
      _handleError('补全回收站还原列失败', e, stackTrace);
      rethrow;
    }
  }

  /// 补全媒体入库会使用的基础可选列。
  ///
  /// 极旧数据库或旁路创建的精简表可能只有必填列。此时常规媒体仍能查询，
  /// 但下载完成后会因 `created_at`、`is_favorite` 等列不存在而无法写入。
  Future<void> _ensureMediaItemsInsertColumns(DatabaseExecutor db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';",
    );
    if (tables.isEmpty) return;

    final columns = await db.rawQuery('PRAGMA table_info(media_items);');
    final names = columns.map((c) => c['name']?.toString() ?? '').toSet();
    const definitions = <String, String>{
      'file_size': 'INTEGER DEFAULT 0',
      'duration': 'INTEGER DEFAULT 0',
      'thumbnail_path': 'TEXT',
      'file_hash': 'TEXT',
      'telegram_file_id': 'TEXT',
      'is_favorite': 'INTEGER DEFAULT 0',
      'sort_order': 'INTEGER',
      'created_at': 'INTEGER DEFAULT 0',
      'updated_at': 'INTEGER DEFAULT 0',
    };
    for (final entry in definitions.entries) {
      if (names.contains(entry.key)) continue;
      await db.execute(
        'ALTER TABLE media_items ADD COLUMN ${entry.key} ${entry.value}',
      );
      if (kDebugMode) Logger.log('已补全 media_items.${entry.key}');
    }
  }

  /// 确保媒体项表存在
  Future<void> ensureMediaItemsTableExists() async {
    try {
      final db = await database;

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_items';",
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
        await _ensureMediaItemsKenBurnsColumns(db);
        await _ensureMediaItemsVideoViewColumns(db);
        await _ensureMediaItemsRecycleColumns(db);
        await _ensureMediaItemsInsertColumns(db);
        Logger.log('已创建media_items表');
      } else {
        // 检查file_hash列是否存在
        final columns = await db.rawQuery("PRAGMA table_info(media_items);");
        bool hasFileHash = columns.any(
          (column) => column['name'] == 'file_hash',
        );

        if (!hasFileHash) {
          // 添加file_hash列
          await db.execute(
            'ALTER TABLE media_items ADD COLUMN file_hash TEXT;',
          );
          Logger.log('已添加file_hash列到media_items表');
        }
        await _ensureMediaItemsKenBurnsColumns(db);
        await _ensureMediaItemsVideoViewColumns(db);
        await _ensureMediaItemsRecycleColumns(db);
        await _ensureMediaItemsInsertColumns(db);
        Logger.log('media_items表已存在');
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
  /// [limit] 和 [offset] 用于分页，避免大目录一次性加载导致内存压力
  Future<List<Map<String, dynamic>>> getMediaItems(
    String directory, {
    int? limit,
    int? offset,
  }) async {
    try {
      final db = await database;
      final folderTypeIndex = 3;
      final imageTypeIndex = 0;
      final videoTypeIndex = 1;
      // Always: system folders → folders → videos → images → other.
      // Within a type: starred first (by sort_order / newest star), then
      // unstarred (manual sort_order if dragged, else newest date_added).
      final orderBy = '''
        ORDER BY
          CASE
            WHEN id = 'recycle_bin' THEN 0
            WHEN id = 'favorites' THEN 1
            ELSE 2
          END ASC,
          CASE
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0
            WHEN type = $folderTypeIndex THEN 1
            WHEN type = $videoTypeIndex THEN 2
            WHEN type = $imageTypeIndex THEN 3
            ELSE 4
          END ASC,
          CASE
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0
            WHEN type = $imageTypeIndex OR type = $videoTypeIndex
              THEN COALESCE(is_favorite, 0)
            ELSE 0
          END DESC,
          CASE
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0
            WHEN sort_order IS NULL THEN 1
            ELSE 0
          END ASC,
          CASE
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0
            ELSE sort_order
          END ASC,
          CASE
            WHEN id = 'recycle_bin' OR id = 'favorites' THEN 0
            ELSE datetime(date_added)
          END DESC
      ''';
      final limitClause =
          (limit != null && offset != null)
              ? ' LIMIT $limit OFFSET $offset'
              : '';
      return await db.rawQuery(
        '''
        SELECT * FROM media_items 
        WHERE directory = ? 
        $orderBy
        $limitClause
      ''',
        [directory],
      );
    } catch (e, stackTrace) {
      _handleError('获取媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// Push existing same-type rows down and return `0` for a new/moved item
  /// at the front of a scope inside [directory].
  ///
  /// [favoriteOnly]: `true` = starred only, `false` = unstarred only,
  /// `null` = whole type.
  Future<int> _allocateFrontSortOrder(
    DatabaseExecutor txn, {
    required String directory,
    required int typeIndex,
    int? nowMs,
    bool? favoriteOnly,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final favoriteClause =
        favoriteOnly == null
            ? ''
            : favoriteOnly
            ? 'AND COALESCE(is_favorite, 0) = 1'
            : 'AND COALESCE(is_favorite, 0) = 0';
    await txn.rawUpdate(
      '''
      UPDATE media_items
      SET sort_order = sort_order + 1, updated_at = ?
      WHERE directory = ?
        AND type = ?
        AND id NOT IN ('recycle_bin', 'favorites')
        AND sort_order IS NOT NULL
        $favoriteClause
      ''',
      [now, directory, typeIndex],
    );
    return 0;
  }

  Future<bool> _hasOrderedPeers(
    DatabaseExecutor txn, {
    required String directory,
    required int typeIndex,
    required bool favoriteOnly,
  }) async {
    final rows = await txn.rawQuery(
      '''
      SELECT COUNT(*) AS c
      FROM media_items
      WHERE directory = ?
        AND type = ?
        AND id NOT IN ('recycle_bin', 'favorites')
        AND sort_order IS NOT NULL
        AND COALESCE(is_favorite, 0) = ?
      ''',
      [directory, typeIndex, favoriteOnly ? 1 : 0],
    );
    return ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
  }

  /// Front of unstarred zone: custom order if peers were dragged, else null
  /// (list uses newest [date_added]).
  Future<int?> _allocateUnfavoritedFrontSortOrder(
    DatabaseExecutor txn, {
    required String directory,
    required int typeIndex,
    int? nowMs,
  }) async {
    final hasOrdered = await _hasOrderedPeers(
      txn,
      directory: directory,
      typeIndex: typeIndex,
      favoriteOnly: false,
    );
    if (!hasOrdered) return null;
    return _allocateFrontSortOrder(
      txn,
      directory: directory,
      typeIndex: typeIndex,
      nowMs: nowMs,
      favoriteOnly: false,
    );
  }

  /// 与 [getMediaItems] 返回行中的 [type] 解析一致（SQLite 可能为 int / num）。
  static int mediaTypeIndex(Map<String, dynamic> row) {
    final t = row['type'];
    if (t is int) return t;
    if (t is num) return t.toInt();
    return int.tryParse('$t') ?? -1;
  }

  /// 若记录路径在磁盘上不存在，尝试在应用 `media/` 目录下按文件名查找（与 [media_manager_page] 一致），
  /// 找到则 [updateMediaItemPath] 并写回 [item]['path']。
  Future<String?> tryRepairMediaItemPath(Map<String, dynamic> item) async {
    try {
      final String pathStr = item['path']?.toString() ?? '';
      if (pathStr.isEmpty) return null;
      if (await File(pathStr).exists()) return pathStr;
      final id = item['id']?.toString();
      if (id == null || id == 'recycle_bin' || id == 'favorites') {
        return null;
      }
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDirPath = p.join(appDir.path, 'media');
      final fileName = p.basename(pathStr);
      final candidatePath = p.join(mediaDirPath, fileName);
      if (await File(candidatePath).exists()) {
        await updateMediaItemPath(id, candidatePath);
        item['path'] = candidatePath;
        return candidatePath;
      }
      return null;
    } catch (e, stackTrace) {
      _handleError('尝试修复媒体路径失败', e, stackTrace);
      return null;
    }
  }

  /// 仅图片/视频，顺序与 [getMediaItems] 在媒体管理页网格中一致（从左到右、从上到下即列表下标顺序）。
  /// - 单目录：该目录下直接子项中跳过文件夹，保留图片/视频的出现顺序。
  /// - [directoryId] 为 `root`：自根目录起深度优先，每一层子项顺序与 [getMediaItems] 一致。
  Future<List<Map<String, dynamic>>> getMediaFilesInGridOrder(
    String directoryId,
  ) async {
    if (directoryId == 'root') {
      return _collectMediaFilesInGridOrderRecursive('root');
    }
    final items = await getMediaItems(directoryId);
    return items.where((row) {
      final t = mediaTypeIndex(row);
      return t == 0 || t == 1;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _collectMediaFilesInGridOrderRecursive(
    String dirId,
  ) async {
    final items = await getMediaItems(dirId);
    final List<Map<String, dynamic>> out = [];
    for (final row in items) {
      final t = mediaTypeIndex(row);
      if (t == 3) {
        final fid = row['id']?.toString();
        if (fid == null) continue;
        out.addAll(await _collectMediaFilesInGridOrderRecursive(fid));
      } else if (t == 0 || t == 1) {
        out.add(row);
      }
    }
    return out;
  }

  /// 获取指定目录下的媒体项总数（不含 limit/offset）
  Future<int> getMediaItemCount(String directory) async {
    try {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) as c FROM media_items WHERE directory = ?',
        [directory],
      );
      return (result.first['c'] as int?) ?? 0;
    } catch (e, stackTrace) {
      _handleError('获取媒体项数量失败', e, stackTrace);
      rethrow;
    }
  }

  /// 插入媒体项目
  Future<int> insertMediaItem(Map<String, dynamic> item) async {
    final db = await database;
    if (kDebugMode) Logger.log('正在插入媒体项: ${item['name']}');

    final data = Map<String, dynamic>.from(item);
    final now = DateTime.now().millisecondsSinceEpoch;
    data['created_at'] ??= now;
    data['updated_at'] ??= now;

    var repairedSchema = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await db.transaction((txn) async {
          final id = data['id']?.toString() ?? '';
          if (id != 'recycle_bin' &&
              id != 'favorites' &&
              data['sort_order'] == null) {
            final typeIndex = mediaTypeIndex(data);
            final directory = (data['directory']?.toString() ?? 'root').trim();
            if (directory.isNotEmpty && typeIndex >= 0) {
              final favRaw = data['is_favorite'];
              final isFav =
                  favRaw == true ||
                  favRaw == 1 ||
                  (favRaw is num && favRaw != 0);
              if (isFav) {
                data['sort_order'] = await _allocateFrontSortOrder(
                  txn,
                  directory: directory,
                  typeIndex: typeIndex,
                  nowMs: now,
                  favoriteOnly: true,
                );
              } else {
                final order = await _allocateUnfavoritedFrontSortOrder(
                  txn,
                  directory: directory,
                  typeIndex: typeIndex,
                  nowMs: now,
                );
                if (order != null) data['sort_order'] = order;
                // else null → unfavorited zone sorts by newest date_added
              }
            }
          }
          final result = await txn.insert(
            'media_items',
            data,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          if (kDebugMode) Logger.log('插入结果: $result');
          return result;
        });
      } on DatabaseException catch (e, stackTrace) {
        final message = e.toString().toLowerCase();
        final missingColumn =
            message.contains('no column') ||
            message.contains('has no column') ||
            message.contains('no such column');
        if (missingColumn && !repairedSchema) {
          repairedSchema = true;
          await _ensureMediaItemsInsertColumns(db);
          await _ensureMediaItemsKenBurnsColumns(db);
          await _ensureMediaItemsVideoViewColumns(db);
          await _ensureMediaItemsRecycleColumns(db);
          continue;
        }

        final temporarilyBusy =
            message.contains('database is locked') ||
            message.contains('database is busy') ||
            message.contains('sqlite_busy') ||
            message.contains('sqlite_locked');
        if (temporarilyBusy && attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 150 * (attempt + 1)),
          );
          continue;
        }
        _handleError('插入媒体项失败', e, stackTrace);
        rethrow;
      } catch (e, stackTrace) {
        _handleError('插入媒体项失败', e, stackTrace);
        rethrow;
      }
    }
    throw StateError('媒体项写入重试结束但未返回结果');
  }

  /// 查找重复的媒体项目（仅视为「当前有效库」中的重复：不含回收站；文件已丢失的孤儿记录会删除并视为未占用）
  Future<Map<String, dynamic>?> findDuplicateMediaItem(
    String fileHash,
    String fileName,
  ) async {
    try {
      final db = await database;
      const String notInRecycle = 'directory != ?';
      const List<Object> recycleArg = ['recycle_bin'];

      Future<Map<String, dynamic>?> firstDuplicateWithExistingFile(
        List<Map<String, dynamic>> rows,
      ) async {
        for (final row in rows) {
          final path = row['path'] as String?;
          final id = row['id'] as String?;
          if (path != null && path.isNotEmpty) {
            try {
              if (await File(path).exists()) {
                return row;
              }
            } catch (_) {}
          }
          if (id != null) {
            try {
              await db.delete('media_items', where: 'id = ?', whereArgs: [id]);
              if (kDebugMode) {
                Logger.log('已移除孤儿媒体记录（文件已不存在）: $id');
              }
            } catch (_) {}
          }
        }
        return null;
      }

      // 通过文件哈希查找（回收站内条目不参与「已入库」判定，删到回收站后可再次下载）
      if (fileHash.isNotEmpty) {
        final List<Map<String, dynamic>> hashMatches = await db.query(
          'media_items',
          where: 'file_hash = ? AND $notInRecycle',
          whereArgs: [fileHash, ...recycleArg],
        );
        final hit = await firstDuplicateWithExistingFile(hashMatches);
        if (hit != null) return hit;
      }

      // 有可靠内容哈希时只能按哈希判断。不同文件可能同名，继续按名称
      // 查询会把内容不同的媒体误判为重复。
      if (fileHash.isNotEmpty) return null;

      // 仅在调用方确实无法提供哈希时才以文件名作为弱兜底。
      final List<Map<String, dynamic>> nameMatches = await db.query(
        'media_items',
        where: 'name = ? AND $notInRecycle',
        whereArgs: [fileName, ...recycleArg],
      );
      return await firstDuplicateWithExistingFile(nameMatches);
    } catch (e, stackTrace) {
      _handleError('查找重复媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 在同一 SQLite 事务内完成内容哈希查重和插入，避免并发任务同时
  /// 通过“先查询、后插入”而写入两份相同媒体。
  /// 返回已存在的有效媒体；返回 null 表示新记录已成功插入。
  Future<Map<String, dynamic>?> insertMediaItemIfContentUnique(
    Map<String, dynamic> item,
  ) async {
    final fileHash = item['file_hash']?.toString().trim() ?? '';
    if (fileHash.isEmpty) {
      throw ArgumentError('内容哈希为空，不能执行可靠查重入库');
    }
    final db = await database;
    final data = Map<String, dynamic>.from(item);
    final now = DateTime.now().millisecondsSinceEpoch;
    data['created_at'] ??= now;
    data['updated_at'] ??= now;

    return db.transaction((txn) async {
      final matches = await txn.query(
        'media_items',
        where: 'file_hash = ? AND directory <> ?',
        whereArgs: [fileHash, 'recycle_bin'],
      );
      for (final raw in matches) {
        final row = Map<String, dynamic>.from(raw);
        final path = row['path']?.toString() ?? '';
        if (path.isNotEmpty && await File(path).exists()) return row;
        final id = row['id']?.toString() ?? '';
        if (id.isNotEmpty) {
          await txn.delete('media_items', where: 'id = ?', whereArgs: [id]);
        }
      }
      final id = data['id']?.toString() ?? '';
      if (id != 'recycle_bin' &&
          id != 'favorites' &&
          data['sort_order'] == null) {
        final typeIndex = mediaTypeIndex(data);
        final directory = (data['directory']?.toString() ?? 'root').trim();
        if (directory.isNotEmpty && typeIndex >= 0) {
          final favRaw = data['is_favorite'];
          final isFav =
              favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);
          if (isFav) {
            data['sort_order'] = await _allocateFrontSortOrder(
              txn,
              directory: directory,
              typeIndex: typeIndex,
              nowMs: now,
              favoriteOnly: true,
            );
          } else {
            final order = await _allocateUnfavoritedFrontSortOrder(
              txn,
              directory: directory,
              typeIndex: typeIndex,
              nowMs: now,
            );
            if (order != null) data['sort_order'] = order;
          }
        }
      }
      await txn.insert(
        'media_items',
        data,
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return null;
    });
  }

  /// 返回所有不在回收站中的真实媒体记录，不依赖文件夹树是否完整。
  /// 用于全库查重，避免父文件夹记录缺失或目录循环造成漏扫。
  Future<List<Map<String, dynamic>>> getAllActiveMediaFilesForDedup() async {
    final db = await database;
    final rows = await db.query(
      'media_items',
      where: 'type <> ? AND directory <> ? AND id NOT IN (?, ?, ?)',
      whereArgs: [
        3, // MediaType.folder.index
        'recycle_bin',
        'root',
        'recycle_bin',
        'favorites',
      ],
      orderBy: 'datetime(date_added) ASC, id ASC',
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  /// 检查 asset_id 是否已导入（静默导入去重，防止重复导入）
  Future<bool> isAssetImported(String assetId) async {
    try {
      final db = await database;
      final rows = await db.query(
        'imported_asset_ids',
        where: 'asset_id = ?',
        whereArgs: [assetId],
      );
      return rows.isNotEmpty;
    } catch (e, stackTrace) {
      _handleError('检查asset是否已导入失败', e, stackTrace);
      return false; // 出错时保守处理，允许导入
    }
  }

  /// 标记 asset_id 已导入
  Future<void> markAssetImported(String assetId) async {
    try {
      final db = await database;
      await db.insert('imported_asset_ids', {
        'asset_id': assetId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } catch (e, stackTrace) {
      _handleError('标记asset已导入失败', e, stackTrace);
    }
  }

  /// 按文件路径查询图片/视频在媒体库中保存的顺时针四分之一圈数（`video_view_rot`），用于文档内图片框等展示。
  Future<int> getImageQuarterTurnsForMediaPath(String path) async {
    if (path.isEmpty) return 0;
    try {
      final db = await database;
      final rows = await db.query(
        'media_items',
        columns: ['video_view_rot'],
        where: 'path = ?',
        whereArgs: [path],
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      final r = rows.first['video_view_rot'];
      if (r is int) {
        var v = r % 4;
        if (v < 0) v += 4;
        return v;
      }
      if (r is num) {
        var v = r.toInt() % 4;
        if (v < 0) v += 4;
        return v;
      }
      return 0;
    } catch (e) {
      if (kDebugMode) {
        Logger.log('getImageQuarterTurnsForMediaPath: $e');
      }
      return 0;
    }
  }

  /// 按路径或文件内容（MD5 与导入媒体库时一致）查询 [media_items] 中保存的视窗参数，
  /// 用于文档/目录/日记等背景图与图片框复用媒体页中的缩放、平移、旋转。
  Future<VideoViewParams> getVideoViewParamsForMediaFilePath(
    String pathStr,
  ) async {
    if (pathStr.isEmpty) return const VideoViewParams();
    try {
      final db = await database;
      await _ensureBackgroundFileViewParamsTable(db);
      final normPath = p.normalize(pathStr);
      final slashPath = normPath.replaceAll('\\', '/');
      final byPath = await db.rawQuery(
        '''
        SELECT video_view_scale, video_view_tx, video_view_ty, video_view_rot,
               video_view_basis_w, video_view_basis_h,
               video_view_anchor_x, video_view_anchor_y
        FROM media_items
        WHERE path = ?
           OR path = ?
           OR REPLACE(path, '\\\\', '/') = ?
        ORDER BY
          CASE
            WHEN path = ? THEN 0
            WHEN path = ? THEN 1
            ELSE 2
          END,
          COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [pathStr, normPath, slashPath, pathStr, normPath],
      );
      if (byPath.isNotEmpty) {
        return VideoViewParams.fromMediaMap(byPath.first);
      }
      final standaloneByPath = await db.rawQuery(
        '''
        SELECT video_view_scale, video_view_tx, video_view_ty, video_view_rot,
               video_view_basis_w, video_view_basis_h,
               video_view_anchor_x, video_view_anchor_y
        FROM $_backgroundFileViewParamsTable
        WHERE path = ?
           OR normalized_path = ?
           OR slash_path = ?
        ORDER BY COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [normPath, normPath, slashPath],
      );
      if (standaloneByPath.isNotEmpty) {
        return VideoViewParams.fromMediaMap(standaloneByPath.first);
      }
      final hash = await _computeFileHashIfExists(pathStr);
      if (hash == null) return const VideoViewParams();
      final byHash = await db.rawQuery(
        '''
        SELECT video_view_scale, video_view_tx, video_view_ty, video_view_rot,
               video_view_basis_w, video_view_basis_h,
               video_view_anchor_x, video_view_anchor_y
        FROM media_items
        WHERE file_hash = ?
        ORDER BY
          CASE
            WHEN ABS(COALESCE(video_view_scale, 1) - 1.0) > 0.0001
              OR ABS(COALESCE(video_view_tx, 0)) > 0.0001
              OR ABS(COALESCE(video_view_ty, 0)) > 0.0001
              OR COALESCE(video_view_rot, 0) != 0
            THEN 0
            ELSE 1
          END,
          COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [hash],
      );
      if (byHash.isNotEmpty) {
        return VideoViewParams.fromMediaMap(byHash.first);
      }
      final standaloneByHash = await db.rawQuery(
        '''
        SELECT video_view_scale, video_view_tx, video_view_ty, video_view_rot,
               video_view_basis_w, video_view_basis_h,
               video_view_anchor_x, video_view_anchor_y
        FROM $_backgroundFileViewParamsTable
        WHERE file_hash = ?
        ORDER BY COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [hash],
      );
      if (standaloneByHash.isNotEmpty) {
        return VideoViewParams.fromMediaMap(standaloneByHash.first);
      }
    } catch (e) {
      if (kDebugMode) {
        Logger.log('getVideoViewParamsForMediaFilePath: $e');
      }
    }
    return const VideoViewParams();
  }

  Future<void> migrateLegacyVideoViewParamsIfNeeded(Size legacyViewport) async {
    if (legacyViewport.width <= 1 || legacyViewport.height <= 1) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      const migrationKey = 'media_view_params_pan_relative_v1_done';
      if (prefs.getBool(migrationKey) == true) return;

      final db = await database;
      final rows = await db.rawQuery('''
        SELECT id, video_view_scale, video_view_tx, video_view_ty, video_view_rot
        FROM media_items
        WHERE ABS(COALESCE(video_view_scale, 1) - 1.0) > 0.0001
           OR ABS(COALESCE(video_view_tx, 0)) > 0.0001
           OR ABS(COALESCE(video_view_ty, 0)) > 0.0001
           OR COALESCE(video_view_rot, 0) != 0
        ''');
      if (rows.isEmpty) {
        await prefs.setBool(migrationKey, true);
        return;
      }

      double clampUnit(num? value) {
        final v = (value ?? 0).toDouble();
        if (v.isNaN || v.isInfinite) return 0.0;
        return v.clamp(-1.0, 1.0);
      }

      ({double maxX, double maxY}) extentsFor({
        required double scale,
        required int quarterTurns,
      }) {
        final sideways = quarterTurns % 2 == 1;
        final childW = sideways ? legacyViewport.height : legacyViewport.width;
        final childH = sideways ? legacyViewport.width : legacyViewport.height;
        return (
          maxX: (((childW * scale) - legacyViewport.width) / 2).clamp(
            0.0,
            double.infinity,
          ),
          maxY: (((childH * scale) - legacyViewport.height) / 2).clamp(
            0.0,
            double.infinity,
          ),
        );
      }

      await db.transaction((txn) async {
        for (final row in rows) {
          final id = row['id']?.toString();
          if (id == null || id.isEmpty) continue;
          final scale = ((row['video_view_scale'] as num?) ?? 1.0)
              .toDouble()
              .clamp(1.0, 6.0);
          int rot = ((row['video_view_rot'] as num?) ?? 0).toInt() % 4;
          if (rot < 0) rot += 4;
          final oldTx = ((row['video_view_tx'] as num?) ?? 0.0).toDouble();
          final oldTy = ((row['video_view_ty'] as num?) ?? 0.0).toDouble();
          final extents = extentsFor(scale: scale, quarterTurns: rot);
          final legacyTxPx = oldTx * legacyViewport.width;
          final legacyTyPx = oldTy * legacyViewport.height;
          final newTx =
              extents.maxX > 1e-6 ? clampUnit(legacyTxPx / extents.maxX) : 0.0;
          final newTy =
              extents.maxY > 1e-6 ? clampUnit(legacyTyPx / extents.maxY) : 0.0;
          await txn.update(
            'media_items',
            {'video_view_tx': newTx, 'video_view_ty': newTy},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      });

      await prefs.setBool(migrationKey, true);
    } catch (e) {
      if (kDebugMode) {
        Logger.log('migrateLegacyVideoViewParamsIfNeeded failed: $e');
      }
    }
  }

  /// 根据ID获取媒体项目
  /// 切换图/视频的星标：不改动 [directory]。
  /// 标星后放到本目录同类收藏区最前；取消标星后放到未收藏区最前。
  /// 返回切换后的星标状态（true=已标星）。
  Future<bool> toggleMediaItemFavorite(String id) async {
    final row = await getMediaItemById(id);
    if (row == null) {
      throw Exception('媒体不存在');
    }
    final t = mediaTypeIndex(row);
    if (t != 0 && t != 1) {
      throw Exception('仅支持图片或视频');
    }
    final dir = row['directory']?.toString() ?? '';
    if (dir == 'recycle_bin') {
      throw Exception('回收站中无法标星');
    }
    final db = await database;
    final wasFav = ((row['is_favorite'] as int?) ?? 0) == 1;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (wasFav) {
      // Unstar → front of the unfavorited zone (still "preferred" vs older files).
      await db.transaction((txn) async {
        await txn.update(
          'media_items',
          {'sort_order': null, 'updated_at': nowMs},
          where: 'id = ?',
          whereArgs: [id],
        );
        final frontOrder = await _allocateFrontSortOrder(
          txn,
          directory: dir.isEmpty ? 'root' : dir,
          typeIndex: t,
          nowMs: nowMs,
          favoriteOnly: false,
        );
        await txn.update(
          'media_items',
          {
            'is_favorite': 0,
            'sort_order': frontOrder,
            'updated_at': nowMs,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      });
      return false;
    }
    await db.transaction((txn) async {
      await txn.update(
        'media_items',
        {'sort_order': null, 'updated_at': nowMs},
        where: 'id = ?',
        whereArgs: [id],
      );
      final frontOrder = await _allocateFrontSortOrder(
        txn,
        directory: dir.isEmpty ? 'root' : dir,
        typeIndex: t,
        nowMs: nowMs,
        favoriteOnly: true,
      );
      await txn.update(
        'media_items',
        {
          'is_favorite': 1,
          'sort_order': frontOrder,
          'date_added': DateTime.now().toIso8601String(),
          'updated_at': nowMs,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
    return true;
  }

  /// 仅标星、不取消：已标星则 no-op（用于文档编辑等无法看到收藏态的入口）。
  /// 校验规则与 [toggleMediaItemFavorite] 一致；标星后置顶同类收藏区。
  Future<void> ensureMediaItemFavorite(String id) async {
    final row = await getMediaItemById(id);
    if (row == null) {
      throw Exception('媒体不存在');
    }
    final t = mediaTypeIndex(row);
    if (t != 0 && t != 1) {
      throw Exception('仅支持图片或视频');
    }
    final dir = row['directory']?.toString() ?? '';
    if (dir == 'recycle_bin') {
      throw Exception('回收站中无法标星');
    }
    final wasFav = ((row['is_favorite'] as int?) ?? 0) == 1;
    if (wasFav) return;

    final db = await database;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'media_items',
        {'sort_order': null, 'updated_at': nowMs},
        where: 'id = ?',
        whereArgs: [id],
      );
      final frontOrder = await _allocateFrontSortOrder(
        txn,
        directory: dir.isEmpty ? 'root' : dir,
        typeIndex: t,
        nowMs: nowMs,
        favoriteOnly: true,
      );
      await txn.update(
        'media_items',
        {
          'is_favorite': 1,
          'sort_order': frontOrder,
          'date_added': DateTime.now().toIso8601String(),
          'updated_at': nowMs,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

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

  Future<Map<String, dynamic>?> getMediaItemByFilePath(String pathStr) async {
    if (pathStr.isEmpty) return null;
    try {
      final db = await database;
      final normPath = p.normalize(pathStr);
      final slashPath = normPath.replaceAll('\\', '/');
      final byPath = await db.rawQuery(
        '''
        SELECT *
        FROM media_items
        WHERE path = ?
           OR path = ?
           OR REPLACE(path, '\\\\', '/') = ?
        ORDER BY
          CASE
            WHEN path = ? THEN 0
            WHEN path = ? THEN 1
            ELSE 2
          END,
          COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [pathStr, normPath, slashPath, pathStr, normPath],
      );
      if (byPath.isNotEmpty) {
        return byPath.first;
      }

      final file = File(pathStr);
      if (!await file.exists()) return null;
      final digest = await md5.bind(file.openRead()).first;
      final hash = digest.toString();
      if (hash.isEmpty) return null;
      final byHash = await db.rawQuery(
        '''
        SELECT *
        FROM media_items
        WHERE file_hash = ?
        ORDER BY
          CASE
            WHEN ABS(COALESCE(video_view_scale, 1) - 1.0) > 0.0001
              OR ABS(COALESCE(video_view_tx, 0)) > 0.0001
              OR ABS(COALESCE(video_view_ty, 0)) > 0.0001
              OR COALESCE(video_view_rot, 0) != 0
            THEN 0
            ELSE 1
          END,
          COALESCE(updated_at, 0) DESC
        LIMIT 1
        ''',
        [hash],
      );
      if (byHash.isNotEmpty) {
        return byHash.first;
      }
      return null;
    } catch (e, stackTrace) {
      _handleError('根据文件路径获取媒体项失败', e, stackTrace);
      return null;
    }
  }

  Future<bool> moveMediaItemToRecycleBin(String id) async {
    final row = await getMediaItemById(id);
    if (row == null) return false;
    final itemId = id.trim();
    if (itemId.isEmpty ||
        itemId == 'root' ||
        itemId == 'recycle_bin' ||
        itemId == 'favorites') {
      throw Exception('系统目录不允许移入回收站');
    }
    final currentDirectory = row['directory']?.toString() ?? 'root';
    if (currentDirectory == 'recycle_bin') return true;

    final db = await database;
    await _ensureMediaItemsRecycleColumns(db);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final typeIndex = mediaTypeIndex(row);
    final updated = await db.transaction((txn) async {
      final frontOrder = await _allocateFrontSortOrder(
        txn,
        directory: 'recycle_bin',
        typeIndex: typeIndex,
        nowMs: nowMs,
      );
      return txn.update(
        'media_items',
        {
          'directory': 'recycle_bin',
          'deleted_from_directory':
              currentDirectory.isEmpty ? 'root' : currentDirectory,
          'deleted_at': nowMs,
          'sort_order': frontOrder,
          'updated_at': nowMs,
        },
        where: 'id = ?',
        whereArgs: [itemId],
      );
    });
    return updated > 0;
  }

  Future<bool> restoreMediaItemFromRecycleBin(
    String id, {
    String fallbackDirectory = 'root',
  }) async {
    final row = await getMediaItemById(id);
    if (row == null) return false;
    final itemId = id.trim();
    if (itemId.isEmpty ||
        itemId == 'root' ||
        itemId == 'recycle_bin' ||
        itemId == 'favorites') {
      throw Exception('系统目录不允许还原');
    }
    final currentDirectory = row['directory']?.toString() ?? '';
    if (currentDirectory != 'recycle_bin') return true;

    var targetDirectory =
        (row['deleted_from_directory']?.toString() ?? '').trim();
    if (targetDirectory.isEmpty || targetDirectory == 'recycle_bin') {
      targetDirectory = fallbackDirectory;
    }
    if (targetDirectory.isEmpty || targetDirectory == 'recycle_bin') {
      targetDirectory = 'root';
    }
    if (targetDirectory != 'root' && targetDirectory != 'favorites') {
      final parent = await getMediaItemById(targetDirectory);
      final parentType = parent == null ? -1 : mediaTypeIndex(parent);
      final parentDir = parent?['directory']?.toString() ?? '';
      if (parent == null || parentType != 3 || parentDir == 'recycle_bin') {
        targetDirectory = 'root';
      }
    }

    final db = await database;
    await _ensureMediaItemsRecycleColumns(db);
    final typeIndex = mediaTypeIndex(row);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final favRaw = row['is_favorite'];
    final isFav =
        favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);
    final updated = await db.transaction((txn) async {
      final int? frontOrder;
      if (isFav) {
        frontOrder = await _allocateFrontSortOrder(
          txn,
          directory: targetDirectory,
          typeIndex: typeIndex,
          nowMs: nowMs,
          favoriteOnly: true,
        );
      } else {
        frontOrder = await _allocateUnfavoritedFrontSortOrder(
          txn,
          directory: targetDirectory,
          typeIndex: typeIndex,
          nowMs: nowMs,
        );
      }
      return txn.update(
        'media_items',
        {
          'directory': targetDirectory,
          'deleted_from_directory': null,
          'deleted_at': null,
          'sort_order': frontOrder,
          if (!isFav && frontOrder == null)
            'date_added': DateTime.now().toIso8601String(),
          'updated_at': nowMs,
        },
        where: 'id = ?',
        whereArgs: [itemId],
      );
    });
    return updated > 0;
  }

  Future<void> upsertVideoViewParamsForFilePath(
    String pathStr,
    VideoViewParams params,
  ) async {
    if (pathStr.isEmpty) return;
    try {
      final db = await database;
      await _ensureBackgroundFileViewParamsTable(db);
      final normPath = p.normalize(pathStr);
      final slashPath = normPath.replaceAll('\\', '/');
      final hash = await _computeFileHashIfExists(pathStr);
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.delete(
        _backgroundFileViewParamsTable,
        where: 'path = ? OR normalized_path = ? OR slash_path = ?',
        whereArgs: [normPath, normPath, slashPath],
      );
      await db.insert(
        _backgroundFileViewParamsTable,
        {
          'path': normPath,
          'normalized_path': normPath,
          'slash_path': slashPath,
          'file_hash': hash,
          ...params.toDbUpdateMap(),
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e, stackTrace) {
      _handleError('按背景图路径保存显示参数失败', e, stackTrace);
      rethrow;
    }
  }

  Future<void> clearVideoViewParamsForFilePath(String pathStr) async {
    if (pathStr.isEmpty) return;
    try {
      final db = await database;
      await _ensureBackgroundFileViewParamsTable(db);
      final normPath = p.normalize(pathStr);
      final slashPath = normPath.replaceAll('\\', '/');
      final hash = await _computeFileHashIfExists(pathStr);
      await db.delete(
        _backgroundFileViewParamsTable,
        where:
            'path = ? OR normalized_path = ? OR slash_path = ?'
            '${hash == null ? '' : ' OR file_hash = ?'}',
        whereArgs: [normPath, normPath, slashPath, if (hash != null) hash],
      );
    } catch (e, stackTrace) {
      _handleError('按背景图路径清除显示参数失败', e, stackTrace);
      rethrow;
    }
  }

  /// 删除媒体项
  Future<int> deleteMediaItem(String id) async {
    try {
      _stagedVideoViewParamsByMediaId.remove(id);
      _syncVideoViewStagingJsonToDiskSync();
      final db = await database;
      final n = await db.delete(
        'media_items',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (n > 0 && id.isNotEmpty) {
        unawaited(() async {
          try {
            final prefs = await SharedPreferences.getInstance();
            await clearVideoResumePositionMs(prefs, id);
          } catch (_) {}
        }());
      }
      return n;
    } catch (e, stackTrace) {
      _handleError('删除媒体项失败', e, stackTrace);
      rethrow;
    }
  }

  /// 先删除数据库记录，再清理磁盘文件。
  ///
  /// 这样在文件删除失败时，最多残留可回收的孤儿文件，不会留下指向失效路径的坏记录。
  Future<Map<String, dynamic>> deleteMediaItemCompletely(String id) async {
    final row = await getMediaItemById(id);
    if (row != null) {
      final t = row['type'];
      final typeIndex =
          t is int ? t : (t is num ? t.toInt() : int.tryParse('$t') ?? -1);
      if (typeIndex == 3) {
        return deleteMediaFolderCompletely(id);
      }
    }
    final filePath = row?['path']?.toString() ?? '';

    final dbDeleted = await deleteMediaItem(id);
    bool fileDeleteAttempted = false;
    bool fileDeleted = true;

    if (dbDeleted > 0 && filePath.isNotEmpty) {
      fileDeleteAttempted = true;
      final fileCleanupService = getService<FileCleanupService>();
      if (fileCleanupService.isInitialized) {
        fileDeleted = await fileCleanupService.deleteMediaFileCompletely(
          filePath,
        );
      } else {
        try {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {
          fileDeleted = false;
        }
      }
    }

    return {
      'dbDeleted': dbDeleted > 0,
      'fileDeleteAttempted': fileDeleteAttempted,
      'fileDeleted': fileDeleted,
      'filePath': filePath,
    };
  }

  Future<Set<String>> _collectMediaFolderSubtreeIds(String rootFolderId) async {
    final db = await database;
    final root = rootFolderId.trim();
    if (root.isEmpty) return <String>{};
    final seen = <String>{root};
    final queue = <String>[root];
    const chunk = 800;

    while (queue.isNotEmpty) {
      final part =
          queue.length <= chunk
              ? List<String>.from(queue)
              : queue.sublist(0, chunk);
      queue.removeRange(0, part.length);
      final qs = List.filled(part.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT id FROM media_items WHERE type = 3 AND directory IN ($qs)',
        part,
      );
      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (seen.add(id)) queue.add(id);
      }
    }
    return seen;
  }

  Future<Map<String, dynamic>> deleteMediaFolderCompletely(
    String folderId,
  ) async {
    final rootId = folderId.trim();
    if (rootId.isEmpty) {
      return {
        'dbDeleted': false,
        'folderCount': 0,
        'mediaCount': 0,
        'fileDeleteAttempted': 0,
        'fileDeleted': 0,
        'fileDeleteFailed': 0,
      };
    }
    if (rootId == 'root' || rootId == 'recycle_bin' || rootId == 'favorites') {
      throw Exception('系统目录不允许删除');
    }

    final db = await database;
    final fileCleanupService = getService<FileCleanupService>();
    final folderIds = await _collectMediaFolderSubtreeIds(rootId);
    if (folderIds.isEmpty) {
      return {
        'dbDeleted': false,
        'folderCount': 0,
        'mediaCount': 0,
        'fileDeleteAttempted': 0,
        'fileDeleted': 0,
        'fileDeleteFailed': 0,
      };
    }

    final allRowIds = <String>{};
    final filePaths = <String>{};
    const chunk = 800;

    final folderIdList = folderIds.toList();
    for (int i = 0; i < folderIdList.length; i += chunk) {
      final part = folderIdList.sublist(
        i,
        (i + chunk).clamp(0, folderIdList.length),
      );
      final qs = List.filled(part.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT id, type, path FROM media_items WHERE directory IN ($qs)',
        part,
      );
      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        allRowIds.add(id);
        final t = r['type'];
        final typeIndex =
            t is int ? t : (t is num ? t.toInt() : int.tryParse('$t') ?? -1);
        final p0 = r['path']?.toString() ?? '';
        if (typeIndex != 3 && p0.trim().isNotEmpty) filePaths.add(p0);
      }
    }

    allRowIds.addAll(folderIds);
    final deleteIds = allRowIds.toList();

    for (final id in deleteIds) {
      _stagedVideoViewParamsByMediaId.remove(id);
    }
    _syncVideoViewStagingJsonToDiskSync();

    int dbDeletedCount = 0;
    await db.transaction((txn) async {
      for (int i = 0; i < deleteIds.length; i += chunk) {
        final part = deleteIds.sublist(
          i,
          (i + chunk).clamp(0, deleteIds.length),
        );
        final qs = List.filled(part.length, '?').join(',');
        final n = await txn.delete(
          'media_items',
          where: 'id IN ($qs)',
          whereArgs: part,
        );
        dbDeletedCount += n;
      }
    });

    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        for (final id in deleteIds) {
          try {
            await clearVideoResumePositionMs(prefs, id);
          } catch (_) {}
        }
      } catch (_) {}
    }());

    int attempted = 0;
    int deleted = 0;
    int failed = 0;
    if (filePaths.isNotEmpty) {
      for (final fp in filePaths) {
        attempted++;
        bool ok = true;
        if (fileCleanupService.isInitialized) {
          ok = await fileCleanupService.deleteMediaFileCompletely(fp);
        } else {
          try {
            final f = File(fp);
            if (await f.exists()) await f.delete();
          } catch (_) {
            ok = false;
          }
        }
        if (ok) {
          deleted++;
        } else {
          failed++;
        }
      }
    }

    return {
      'dbDeleted': dbDeletedCount > 0,
      'folderCount': folderIds.length,
      'mediaCount': filePaths.length,
      'fileDeleteAttempted': attempted,
      'fileDeleted': deleted,
      'fileDeleteFailed': failed,
    };
  }

  Future<int> countOrphanMediaDirectoryItems() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS c
      FROM media_items
      WHERE directory NOT IN ('root', 'recycle_bin', 'favorites')
        AND (directory = '' OR directory NOT IN (SELECT id FROM media_items WHERE type = 3))
    ''');
    return rows.isNotEmpty ? (rows.first['c'] as int? ?? 0) : 0;
  }

  Future<List<Map<String, dynamic>>> getOrphanMediaDirectoryItems({
    int limit = 20,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT id, name, type, directory, path
      FROM media_items
      WHERE directory NOT IN ('root', 'recycle_bin', 'favorites')
        AND (directory = '' OR directory NOT IN (SELECT id FROM media_items WHERE type = 3))
      ORDER BY datetime(date_added) DESC
      LIMIT ?
    ''',
      [limit],
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>>
  moveOrphanMediaDirectoryItemsToRecycleBin() async {
    final db = await database;
    int moved = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _ensureMediaItemsRecycleColumns(db);
    await db.transaction((txn) async {
      moved = await txn.rawUpdate(
        '''
        UPDATE media_items
        SET deleted_from_directory = directory,
            deleted_at = ?,
            directory = 'recycle_bin',
            updated_at = ?
        WHERE directory NOT IN ('root','recycle_bin','favorites')
          AND (directory = '' OR directory NOT IN (SELECT id FROM media_items WHERE type = 3))
        ''',
        [now, now],
      );
    });
    return {'moved': moved};
  }

  Future<Map<String, dynamic>>
  deleteOrphanMediaDirectoryItemsCompletely() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT id, name, type, directory, path
      FROM media_items
      WHERE directory NOT IN ('root', 'recycle_bin', 'favorites')
        AND (directory = '' OR directory NOT IN (SELECT id FROM media_items WHERE type = 3))
    ''');
    final items = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    int deletedFolders = 0;
    int deletedItems = 0;
    int attempted = 0;
    int ok = 0;
    int fail = 0;

    for (final r in items) {
      final id = r['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final t = r['type'];
      final typeIndex =
          t is int ? t : (t is num ? t.toInt() : int.tryParse('$t') ?? -1);
      if (typeIndex == 3) {
        final res = await deleteMediaFolderCompletely(id);
        deletedFolders += (res['folderCount'] as int? ?? 0);
        deletedItems += (res['mediaCount'] as int? ?? 0);
        attempted += (res['fileDeleteAttempted'] as int? ?? 0);
        ok += (res['fileDeleted'] as int? ?? 0);
        fail += (res['fileDeleteFailed'] as int? ?? 0);
      } else {
        final res = await deleteMediaItemCompletely(id);
        deletedItems += (res['dbDeleted'] == true) ? 1 : 0;
        if (res['fileDeleteAttempted'] == true) {
          attempted += 1;
          if (res['fileDeleted'] == true) {
            ok += 1;
          } else {
            fail += 1;
          }
        }
      }
    }
    return {
      'orphanRows': items.length,
      'deletedFolders': deletedFolders,
      'deletedItems': deletedItems,
      'fileDeleteAttempted': attempted,
      'fileDeleted': ok,
      'fileDeleteFailed': fail,
    };
  }

  Future<Map<String, dynamic>> repairMissingMediaFiles(
    List<String> missingPaths,
  ) async {
    final unique = <String>{};
    final targets = <String>[];
    for (final p0 in missingPaths) {
      final p = p0.trim();
      if (p.isEmpty) continue;
      if (unique.add(p)) targets.add(p);
    }
    if (targets.isEmpty) {
      return {'checked': 0, 'repaired': 0, 'deletedRows': 0, 'unresolved': 0};
    }

    int checked = 0;
    int repaired = 0;
    int deletedRows = 0;
    int unresolved = 0;

    for (final p0 in targets) {
      checked++;
      try {
        final row = await getMediaItemByFilePath(p0);
        if (row == null) {
          unresolved++;
          continue;
        }
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) {
          unresolved++;
          continue;
        }

        final fixedPath = await tryRepairMediaItemPath(row);
        if (fixedPath != null &&
            fixedPath.isNotEmpty &&
            await File(fixedPath).exists()) {
          repaired++;
          continue;
        }

        final n = await deleteMediaItem(id);
        if (n > 0) {
          deletedRows += n;
        } else {
          unresolved++;
        }
      } catch (_) {
        unresolved++;
      }
    }

    return {
      'checked': checked,
      'repaired': repaired,
      'deletedRows': deletedRows,
      'unresolved': unresolved,
    };
  }

  Future<Map<String, dynamic>> pruneVideoViewStagingJsonIfNeeded() async {
    final root = _appDocumentsDirectoryPath;
    if (root == null || root.isEmpty) {
      return {'exists': false, 'parseOk': false, 'pruned': 0, 'deleted': false};
    }
    final file = File(p.join(root, _videoViewStagingJsonFileName));
    if (!await file.exists()) {
      return {'exists': false, 'parseOk': true, 'pruned': 0, 'deleted': false};
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        await file.delete();
        _stagedVideoViewParamsByMediaId.clear();
        return {'exists': true, 'parseOk': true, 'pruned': 0, 'deleted': true};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await file.delete();
        _stagedVideoViewParamsByMediaId.clear();
        return {'exists': true, 'parseOk': false, 'pruned': 0, 'deleted': true};
      }
      final itemsRaw = decoded['items'];
      if (itemsRaw is! Map) {
        await file.delete();
        _stagedVideoViewParamsByMediaId.clear();
        return {'exists': true, 'parseOk': false, 'pruned': 0, 'deleted': true};
      }
      final items = Map<String, dynamic>.from(itemsRaw as Map);
      final ids =
          items.keys
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
      if (ids.isEmpty) {
        await file.delete();
        _stagedVideoViewParamsByMediaId.clear();
        return {'exists': true, 'parseOk': true, 'pruned': 0, 'deleted': true};
      }
      final db = await database;
      final existing = <String>{};
      const chunk = 900;
      for (int i = 0; i < ids.length; i += chunk) {
        final part = ids.sublist(i, (i + chunk).clamp(0, ids.length));
        final qs = List.filled(part.length, '?').join(',');
        final rows = await db.rawQuery(
          'SELECT id FROM media_items WHERE id IN ($qs)',
          part,
        );
        existing.addAll(
          rows.map((r) => r['id']?.toString() ?? '').where((s) => s.isNotEmpty),
        );
      }
      int pruned = 0;
      for (final id in ids) {
        if (!existing.contains(id)) {
          items.remove(id);
          pruned++;
        }
      }
      if (items.isEmpty) {
        await file.delete();
        _stagedVideoViewParamsByMediaId.clear();
        return {
          'exists': true,
          'parseOk': true,
          'pruned': pruned,
          'deleted': true,
        };
      }
      final payload = <String, dynamic>{'v': 1, 'items': items};
      await file.writeAsString(jsonEncode(payload), flush: true);
      _stagedVideoViewParamsByMediaId
        ..clear()
        ..addAll(
          items.map((k, v) {
            if (v is Map) {
              try {
                final m = Map<String, dynamic>.from(v);
                return MapEntry(k, VideoViewParams.fromJsonStaging(m));
              } catch (_) {}
            }
            return MapEntry(k, VideoViewParams());
          }),
        );
      return {
        'exists': true,
        'parseOk': true,
        'pruned': pruned,
        'deleted': false,
      };
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {}
      _stagedVideoViewParamsByMediaId.clear();
      return {'exists': true, 'parseOk': false, 'pruned': 0, 'deleted': true};
    }
  }

  /// 在异步写库前同步记下当前取景参数（见 [_stagedVideoViewParamsByMediaId]）。
  void stageVideoViewParamsForDisk(String mediaId, VideoViewParams params) {
    _stagedVideoViewParamsByMediaId[mediaId] = params;
    _syncVideoViewStagingJsonToDiskSync();
  }

  void _syncVideoViewStagingJsonToDiskSync() {
    final root = _appDocumentsDirectoryPath;
    if (root == null) return;
    try {
      final payload = <String, dynamic>{
        'v': 1,
        'items': <String, dynamic>{
          for (final e in _stagedVideoViewParamsByMediaId.entries)
            e.key: e.value.toJsonStaging(),
        },
      };
      File(
        p.join(root, _videoViewStagingJsonFileName),
      ).writeAsStringSync(jsonEncode(payload), flush: true);
    } catch (_) {}
  }

  /// 冷启动时把 JSON 暂存合并进 SQLite（应对进程被杀时 await 未完成）。
  Future<void> _mergeVideoViewStagingJsonIfNeeded() async {
    final root = _appDocumentsDirectoryPath;
    if (root == null) return;
    final file = File(p.join(root, _videoViewStagingJsonFileName));
    if (!await file.exists()) return;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        await file.delete();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final itemsRaw = decoded['items'];
      if (itemsRaw is! Map) return;
      final db = await database;
      await _ensureMediaItemsVideoViewColumns(db);
      final items = Map<String, dynamic>.from(itemsRaw);
      for (final entry in items.entries) {
        final id = entry.key;
        final value = entry.value;
        if (value is! Map) continue;
        final m = Map<String, dynamic>.from(value);
        final p = VideoViewParams.fromJsonStaging(m);
        await updateMediaItem({
          'id': id,
          ...p.toDbUpdateMap(),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
      await file.delete();
    } catch (e, stackTrace) {
      _handleError('合并取景 JSON 暂存失败', e, stackTrace);
    }
  }

  /// 将暂存取景写入数据库；若某 id 在写入期间又被更新，则保留较新快照以便下次刷盘。
  Future<void> flushStagedVideoViewParamsToDisk() async {
    if (_stagedVideoViewParamsByMediaId.isEmpty) return;
    final ids = _stagedVideoViewParamsByMediaId.keys.toList();
    for (final id in ids) {
      final p = _stagedVideoViewParamsByMediaId[id];
      if (p == null) continue;
      try {
        await updateMediaItem({
          'id': id,
          ...p.toDbUpdateMap(),
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });
        if (_stagedVideoViewParamsByMediaId[id] == p) {
          _stagedVideoViewParamsByMediaId.remove(id);
        }
      } catch (e, stackTrace) {
        _handleError('刷盘 media 取景参数失败', e, stackTrace);
      }
    }
    _syncVideoViewStagingJsonToDiskSync();
  }

  /// 更新媒体项
  Future<int> updateMediaItem(Map<String, dynamic> item) async {
    try {
      final db = await database;
      if (item.containsKey('video_view_scale') ||
          item.containsKey('video_view_tx') ||
          item.containsKey('video_view_ty') ||
          item.containsKey('video_view_rot') ||
          item.containsKey('video_view_basis_w') ||
          item.containsKey('video_view_basis_h') ||
          item.containsKey('video_view_anchor_x') ||
          item.containsKey('video_view_anchor_y')) {
        await _ensureMediaItemsVideoViewColumns(db);
      }
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

  /// 更新媒体项文件路径（用于跨设备导入后的路径修复）
  Future<int> updateMediaItemPath(String id, String newPath) async {
    try {
      final db = await database;
      return await db.update(
        'media_items',
        {'path': newPath, 'thumbnail_path': null},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stackTrace) {
      _handleError('更新媒体项路径失败', e, stackTrace);
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
        whereArgs: [id],
      );
    } catch (e, stackTrace) {
      _handleError('更新媒体项目录失败', e, stackTrace);
      rethrow;
    }
  }

  /// Persists user order within each media type for one directory.
  ///
  /// [orderedIds] may be a full directory list; `sort_order` is rewritten
  /// per type (folder / video / image / …) so categories never interleave.
  Future<void> reorderMediaItems(
    String directory,
    List<String> orderedIds,
  ) async {
    final ids = orderedIds
        .where((id) => id != 'recycle_bin' && id != 'favorites')
        .toList(growable: false);
    if (ids.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await txn.query(
        'media_items',
        columns: ['id', 'type', 'is_favorite'],
        where:
            'directory = ? AND id NOT IN (\'recycle_bin\', \'favorites\')',
        whereArgs: [directory],
      );
      final typeById = <String, int>{};
      final favById = <String, bool>{};
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        typeById[id] = mediaTypeIndex(row);
        final favRaw = row['is_favorite'];
        favById[id] =
            favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);
      }
      // Separate counters for starred vs unstarred within each type.
      final counters = <String, int>{};
      final batch = txn.batch();
      for (final id in ids) {
        final typeIndex = typeById[id];
        if (typeIndex == null) continue;
        final isFav = favById[id] ?? false;
        final key = '$typeIndex:${isFav ? 1 : 0}';
        final index = counters[key] ?? 0;
        counters[key] = index + 1;
        batch.update(
          'media_items',
          {'sort_order': index, 'updated_at': now},
          where: 'id = ? AND directory = ?',
          whereArgs: [id, directory],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Moves one item into [directory] at the front of its fav/unfav zone.
  Future<void> moveMediaItemToDirectory(String id, String directory) async {
    if (id == 'recycle_bin' || id == 'favorites') {
      throw ArgumentError('System media folders cannot be moved');
    }
    final db = await database;
    await _ensureMediaItemsRecycleColumns(db);
    await db.transaction((txn) async {
      final currentRows = await txn.query(
        'media_items',
        columns: ['directory', 'type', 'is_favorite'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (currentRows.isEmpty) return;
      final current = currentRows.first;
      final wasInRecycleBin =
          current['directory']?.toString() == 'recycle_bin';
      final typeIndex = mediaTypeIndex(current);
      final favRaw = current['is_favorite'];
      final isFav =
          favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);
      final now = DateTime.now().millisecondsSinceEpoch;
      final int? frontOrder;
      if (isFav) {
        frontOrder = await _allocateFrontSortOrder(
          txn,
          directory: directory,
          typeIndex: typeIndex,
          nowMs: now,
          favoriteOnly: true,
        );
      } else {
        frontOrder = await _allocateUnfavoritedFrontSortOrder(
          txn,
          directory: directory,
          typeIndex: typeIndex,
          nowMs: now,
        );
      }
      await txn.update(
        'media_items',
        {
          'directory': directory,
          'sort_order': frontOrder,
          if (!isFav && frontOrder == null)
            'date_added': DateTime.now().toIso8601String(),
          if (wasInRecycleBin) 'deleted_from_directory': null,
          if (wasInRecycleBin) 'deleted_at': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// 将导出包中该文件的显示与收藏相关字段合并到已有 [media_items] 行（用于文件夹导入遇哈希重复时保留 ZIP 内效果）。
  static const List<String> _mediaDisplayMergeKeys = [
    'is_favorite',
    'ken_burns_center_x',
    'ken_burns_center_y',
    'video_view_scale',
    'video_view_tx',
    'video_view_ty',
    'video_view_rot',
    'video_view_basis_w',
    'video_view_basis_h',
    'video_view_anchor_x',
    'video_view_anchor_y',
  ];

  Future<void> mergeMediaItemDisplayFieldsFromExport(
    String id,
    Map<String, dynamic> exportedRow,
  ) async {
    if (exportedRow.isEmpty) return;
    final update = <String, dynamic>{};
    for (final k in _mediaDisplayMergeKeys) {
      if (!exportedRow.containsKey(k)) continue;
      final v = exportedRow[k];
      if (v == null) continue;
      if (k == 'is_favorite') {
        if (v is bool) {
          update[k] = v ? 1 : 0;
        } else if (v is num) {
          update[k] = v.toInt();
        } else {
          update[k] = v;
        }
      } else if (k == 'video_view_rot' && v is num) {
        update[k] = v.toInt();
      } else {
        update[k] = v;
      }
    }
    if (update.isEmpty) return;
    try {
      final db = await database;
      update['updated_at'] = DateTime.now().millisecondsSinceEpoch;
      await db.update('media_items', update, where: 'id = ?', whereArgs: [id]);
    } catch (e, stackTrace) {
      _handleError('合并媒体显示/收藏字段失败', e, stackTrace);
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

  /// 更新文件夹的父文件夹
  Future<void> updateFolderParentFolder(
    String folderName,
    String? newParentFolderName,
  ) async {
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
        if (await _wouldCreateCircularReference(
          currentFolder['id'],
          newParentFolderId,
        )) {
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
  Future<bool> _wouldCreateCircularReference(
    String folderId,
    String? newParentId,
  ) async {
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
  Future<void> updateDocumentParentFolder(
    String documentName,
    String? newParentFolderName,
  ) async {
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
  /// [outputDirectory] 可选，指定 ZIP 输出目录；为 null 时使用 Downloads/外部存储（不写入 backups）
  /// 允许部分图片/音频文件缺失（已删除或路径无效），缺失文件会跳过并写入 missing_audio_files.txt
  Future<String> exportDirectoryData({
    ValueNotifier<String>? progressNotifier,
    String? outputDirectory,
  }) async {
    try {
      Logger.log('开始导出目录数据...');
      progressNotifier?.value = "准备导出...";

      // 临时目录用于打包，导出完成后删除；不占用 backups
      final Directory tempRoot = await getTemporaryDirectory();
      final String tempDirPath =
          '${tempRoot.path}/directory_export_temp_${DateTime.now().millisecondsSinceEpoch}';
      final Directory tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      final db = await database;

      // 文件名安全化函数
      String safeFileName(String base, String ext) {
        String name = base.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
        if (name.length > 40) name = name.substring(0, 40);
        return name + ext;
      }

      // SPLIT 格式：分页流式写入 JSON，不把整表载入内存（与媒体导出同级的大容量能力）
      progressNotifier?.value = "正在生成数据文件...";
      final String dirDataPath = '$tempDirPath/directory_data';
      await Directory(dirDataPath).create(recursive: true);

      final List<String> tableFileList = [];
      final List<String> missingAudioFiles = [];
      int imageBoxesWithPathCount = 0;
      int imageFilesInZipCount = 0;
      int audioBoxesWithPathCount = 0;

      Future<void> streamTableToDirectoryData(
        String tableName,
        Future<List<Map<String, dynamic>>> Function(
          List<Map<String, dynamic>> batch,
        )
        processBatch,
      ) async {
        const int pageSize = 500;
        int offset = 0;
        final buffer = <Map<String, dynamic>>[];
        int chunkIndex = 0;
        bool wroteAnyChunk = false;

        while (true) {
          final batch = await db.query(
            tableName,
            limit: pageSize,
            offset: offset,
          );
          if (batch.isEmpty) break;
          final processed = await processBatch(batch);
          for (final row in processed) {
            buffer.add(row);
            if (buffer.length >= kExportChunkSize) {
              final fn = '${tableName}_$chunkIndex.json';
              await File(
                '$dirDataPath/$fn',
              ).writeAsString(jsonEncode(buffer), encoding: utf8);
              tableFileList.add(fn);
              buffer.clear();
              chunkIndex++;
              wroteAnyChunk = true;
              progressNotifier?.value = '正在生成数据文件: $tableName ...';
            }
          }
          offset += batch.length;
          progressNotifier?.value = "正在导出$tableName表数据: $offset 条";
          if (batch.length < pageSize) break;
        }
        if (buffer.isEmpty) return;
        if (!wroteAnyChunk) {
          final fn = '$tableName.json';
          await File(
            '$dirDataPath/$fn',
          ).writeAsString(jsonEncode(buffer), encoding: utf8);
          tableFileList.add(fn);
        } else {
          final fn = '${tableName}_$chunkIndex.json';
          await File(
            '$dirDataPath/$fn',
          ).writeAsString(jsonEncode(buffer), encoding: utf8);
          tableFileList.add(fn);
        }
      }

      progressNotifier?.value = "正在导出folders表数据...";
      await streamTableToDirectoryData('folders', (b) async => b);

      progressNotifier?.value = "正在导出documents表数据...";
      await streamTableToDirectoryData('documents', (b) async => b);

      progressNotifier?.value = "正在导出text_boxes表数据...";
      await streamTableToDirectoryData('text_boxes', (b) async => b);

      progressNotifier?.value = "正在处理图片文件...";
      await streamTableToDirectoryData('image_boxes', (
        List<Map<String, dynamic>> batch,
      ) async {
        const int imageBatchSize = 20;
        final out = <Map<String, dynamic>>[];
        for (int i = 0; i < batch.length; i += imageBatchSize) {
          final end =
              (i + imageBatchSize < batch.length)
                  ? i + imageBatchSize
                  : batch.length;
          final sub = batch.sublist(i, end);
          final part = await Future.wait(
            sub.map((imageBox) async {
              final imageBoxCopy = Map<String, dynamic>.from(imageBox);
              final String? imagePath = imageBox['image_path']?.toString();
              final String? imageBoxId = imageBox['id']?.toString();
              if (imagePath != null && imagePath.isNotEmpty) {
                imageBoxesWithPathCount++;
              }
              if (imagePath != null &&
                  imagePath.isNotEmpty &&
                  imageBoxId != null &&
                  imageBoxId.isNotEmpty) {
                final String ext = p.extension(imagePath);
                final String originalFileName = p.basenameWithoutExtension(
                  imagePath,
                );
                final String fileName = safeFileName(
                  '${imageBoxId}_$originalFileName',
                  ext,
                );
                imageBoxCopy['imageFileName'] = fileName;
                final File imageFile = File(imagePath);
                if (await imageFile.exists()) {
                  final String relativePath = 'images/$fileName';
                  await Directory(
                    '$tempDirPath/images',
                  ).create(recursive: true);
                  await copyFileWithStreaming(
                    imageFile,
                    '$tempDirPath/$relativePath',
                  );
                  imageFilesInZipCount++;
                  Logger.log('已导出图片框图片: $relativePath');
                } else {
                  Logger.log('警告：图片文件不存在: $imagePath');
                }
              }
              return imageBoxCopy;
            }),
          );
          out.addAll(part);
        }
        return out;
      });

      progressNotifier?.value = "正在处理音频文件...";
      await streamTableToDirectoryData('audio_boxes', (
        List<Map<String, dynamic>> batch,
      ) async {
        const int audioBatchSize = 10;
        final out = <Map<String, dynamic>>[];
        for (int i = 0; i < batch.length; i += audioBatchSize) {
          final end =
              (i + audioBatchSize < batch.length)
                  ? i + audioBatchSize
                  : batch.length;
          final sub = batch.sublist(i, end);
          final part = await Future.wait(
            sub.map((audioBox) async {
              final audioBoxCopy = Map<String, dynamic>.from(audioBox);
              final String? audioPath = audioBox['audio_path']?.toString();
              final String? audioBoxId = audioBox['id']?.toString();
              if (audioPath != null && audioPath.isNotEmpty) {
                audioBoxesWithPathCount++;
              }
              if (audioPath != null &&
                  audioPath.isNotEmpty &&
                  audioBoxId != null &&
                  audioBoxId.isNotEmpty) {
                final String ext = p.extension(audioPath);
                final String originalFileName = p.basenameWithoutExtension(
                  audioPath,
                );
                final String fileName = safeFileName(
                  '${audioBoxId}_$originalFileName',
                  ext,
                );
                audioBoxCopy['audioFileName'] = fileName;
                final File audioFile = File(audioPath);
                if (await audioFile.exists()) {
                  final String relativePath = 'audios/$fileName';
                  await Directory(
                    '$tempDirPath/audios',
                  ).create(recursive: true);
                  await copyFileWithStreaming(
                    audioFile,
                    '$tempDirPath/$relativePath',
                  );
                  Logger.log('已导出音频文件: $relativePath');
                } else {
                  Logger.log('警告：音频文件不存在: $audioPath');
                  missingAudioFiles.add(audioPath);
                }
              }
              return audioBoxCopy;
            }),
          );
          out.addAll(part);
        }
        return out;
      });

      progressNotifier?.value = "正在导出canvases表数据...";
      await streamTableToDirectoryData('canvases', (b) async => b);

      // 处理目录设置和背景图片
      List<Map<String, dynamic>> directorySettings = await db.query(
        'directory_settings',
      );
      List<Map<String, dynamic>> directorySettingsToExport = [];
      for (var settings in directorySettings) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        final String rowId = '${settings['id'] ?? 0}';

        String? backgroundImagePath =
            settings['background_image_path']?.toString();
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final String ext = p.extension(backgroundImagePath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundImagePath,
          );
          final String fileName = safeFileName(
            '${rowId}_$originalFileName',
            ext,
          );
          settingsCopy['backgroundImageFileName'] = fileName;

          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory(
              '$tempDirPath/background_images',
            ).create(recursive: true);
            await copyFileWithStreaming(
              imageFile,
              '$tempDirPath/$relativePath',
            );
            Logger.log('已导出目录背景图片: $relativePath');
          } else {
            Logger.log('警告：目录背景图片不存在: $backgroundImagePath');
          }
        }

        String? backgroundVideoPath =
            settings['background_video_path']?.toString();
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final String ext = p.extension(backgroundVideoPath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundVideoPath,
          );
          final String fileName = safeFileName(
            '${rowId}_vid_$originalFileName',
            ext,
          );
          settingsCopy['backgroundVideoFileName'] = fileName;
          settingsCopy['backgroundVideoVolume'] =
              await BackgroundVideoVolumePrefs.volumeForPath(
                backgroundVideoPath,
              );
          final File videoFile = File(backgroundVideoPath);
          if (await videoFile.exists()) {
            final String relativePath = 'background_videos/$fileName';
            await Directory(
              '$tempDirPath/background_videos',
            ).create(recursive: true);
            await copyFileWithStreaming(
              videoFile,
              '$tempDirPath/$relativePath',
            );
            Logger.log('已导出目录背景视频: $relativePath');
          } else {
            Logger.log('警告：目录背景视频不存在: $backgroundVideoPath');
          }
        }

        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundImagePath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_image_view'] = vp.toJsonStaging();
          }
        }
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundVideoPath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_video_view'] = vp.toJsonStaging();
          }
        }

        directorySettingsToExport.add(settingsCopy);
      }
      if (directorySettingsToExport.isNotEmpty) {
        await File(
          '$dirDataPath/directory_settings.json',
        ).writeAsString(jsonEncode(directorySettingsToExport), encoding: utf8);
        tableFileList.add('directory_settings.json');
      }

      // 处理文档设置和背景图片
      List<Map<String, dynamic>> documentSettings = await db.query(
        'document_settings',
      );
      List<Map<String, dynamic>> documentSettingsToExport = [];
      for (var settings in documentSettings) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        final String docKey =
            settings['document_id']?.toString().replaceAll(
              RegExp(r'[^A-Za-z0-9_]'),
              '_',
            ) ??
            'doc';

        String? backgroundImagePath =
            settings['background_image_path']?.toString();
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final String ext = p.extension(backgroundImagePath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundImagePath,
          );
          final String fileName = safeFileName(
            '${docKey}_$originalFileName',
            ext,
          );
          settingsCopy['backgroundImageFileName'] = fileName;

          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory(
              '$tempDirPath/background_images',
            ).create(recursive: true);
            await copyFileWithStreaming(
              imageFile,
              '$tempDirPath/$relativePath',
            );
            Logger.log('已导出文档背景图片: $relativePath');
          } else {
            Logger.log('警告：文档背景图片不存在: $backgroundImagePath');
          }
        }

        String? backgroundVideoPath =
            settings['background_video_path']?.toString();
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final String ext = p.extension(backgroundVideoPath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundVideoPath,
          );
          final String fileName = safeFileName(
            '${docKey}_vid_$originalFileName',
            ext,
          );
          settingsCopy['backgroundVideoFileName'] = fileName;
          settingsCopy['backgroundVideoVolume'] =
              await BackgroundVideoVolumePrefs.volumeForPath(
                backgroundVideoPath,
              );
          final File videoFile = File(backgroundVideoPath);
          if (await videoFile.exists()) {
            final String relativePath = 'background_videos/$fileName';
            await Directory(
              '$tempDirPath/background_videos',
            ).create(recursive: true);
            await copyFileWithStreaming(
              videoFile,
              '$tempDirPath/$relativePath',
            );
            Logger.log('已导出文档背景视频: $relativePath');
          } else {
            Logger.log('警告：文档背景视频不存在: $backgroundVideoPath');
          }
        }

        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundImagePath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_image_view'] = vp.toJsonStaging();
          }
        }
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundVideoPath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_video_view'] = vp.toJsonStaging();
          }
        }

        documentSettingsToExport.add(settingsCopy);
      }
      if (documentSettingsToExport.isNotEmpty) {
        await File(
          '$dirDataPath/document_settings.json',
        ).writeAsString(jsonEncode(documentSettingsToExport), encoding: utf8);
        tableFileList.add('document_settings.json');
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        final portable = buildDirectoryPortablePrefsExportMap(prefs);
        if (shouldExportDirectoryPortablePrefs(portable)) {
          await File(
            '$dirDataPath/portable_prefs.json',
          ).writeAsString(jsonEncode(portable), encoding: utf8);
        }
      } catch (e) {
        Logger.log('[导出] 写入 portable_prefs.json 失败（已跳过）: $e');
      }

      // 写入丢失音频文件列表到missing_audio_files.txt
      if (missingAudioFiles.isNotEmpty) {
        final File missingFile = File('$tempDirPath/missing_audio_files.txt');
        await missingFile.writeAsString(missingAudioFiles.join('\n'));
        Logger.log('[导出] 丢失音频文件数量: ${missingAudioFiles.length}');
        Logger.log('[导出] 丢失音频文件列表:');
        for (final f in missingAudioFiles) {
          Logger.log('  - $f');
        }
      }

      final manifest = {'format_version': 2, 'tables': tableFileList};
      final manifestFile = File('$dirDataPath/directory_manifest.json');
      await manifestFile.writeAsString(jsonEncode(manifest), encoding: utf8);
      Logger.log('[导出] SPLIT格式数据文件写入完成: $dirDataPath');
      if (!await manifestFile.exists() || await manifestFile.length() == 0) {
        throw Exception('导出失败：未生成有效的directory_manifest.json');
      }
      Logger.log('[导出] 数据文件存在且有效，准备压缩...');
      // 压缩前打印临时目录下所有文件
      final allFilesPreZip =
          await Directory(tempDirPath).list(recursive: true).toList();
      Logger.log('[导出] 临时目录下文件:');
      for (final f in allFilesPreZip) {
        Logger.log('  - ${f.path}');
      }
      progressNotifier?.value = "正在创建压缩文件...";

      // ZIP 输出目录：用户指定 > 公共下载目录（优先）> 外部存储（不写入 backups）
      String zipOutputDir;
      if (outputDirectory != null && outputDirectory.isNotEmpty) {
        zipOutputDir = outputDirectory;
      } else {
        final saveDir = await getExportSaveDirectory();
        zipOutputDir = saveDir.path;
      }
      await Directory(zipOutputDir).create(recursive: true);
      final String timestamp = DateTime.now().toString().replaceAll(
        RegExp(r'[^0-9]'),
        '',
      );
      final String zipPath = p.join(
        zipOutputDir,
        'directory_backup_$timestamp.zip',
      );
      final tempDirEntity = Directory(tempDirPath);

      // 使用流式ZipEncoder避免内存溢出
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      await for (final entity in tempDirEntity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: tempDirPath);
          Logger.log('[导出] 添加到ZIP: $relativePath');
          // addFile会以流的方式处理文件，避免读入内存；level:0 不压缩，降低大容量导出时的内存占用
          await encoder.addFile(entity, relativePath, 0);
        }
      }
      encoder.close();

      Logger.log('[导出] ZIP文件写入完成: $zipPath');

      final int imageBoxTotalRows =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM image_boxes'),
          ) ??
          0;
      final int audioBoxTotalRows =
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM audio_boxes'),
          ) ??
          0;

      final int zipFileBytes = await File(zipPath).length();
      const int kMaxZipVerifySizeBytes = 400 * 1024 * 1024;

      if (zipFileBytes <= kMaxZipVerifySizeBytes) {
        final inputStream = InputFileStream(zipPath);
        final archiveCheck = ZipDecoder().decodeStream(inputStream);

        try {
          final int zipImageCount =
              archiveCheck
                  .where(
                    (file) =>
                        file.name.startsWith('images/') && !file.isDirectory,
                  )
                  .length;
          Logger.log(
            '[导出] 图片框总数: $imageBoxTotalRows，其中有路径的: $imageBoxesWithPathCount，ZIP内文件: $zipImageCount',
          );
          if (zipImageCount > imageBoxTotalRows) {
            throw Exception(
              '导出失败：图片文件数量异常，ZIP包内$zipImageCount个多于数据库$imageBoxTotalRows个，请联系开发者排查。',
            );
          }
          if (zipImageCount < imageBoxesWithPathCount && kDebugMode) {
            Logger.log(
              '[导出] 警告：部分图片文件不存在已跳过，有路径的$imageBoxesWithPathCount个，实际导出$zipImageCount个',
            );
          }
          final int zipAudioCount =
              archiveCheck
                  .where(
                    (file) =>
                        file.name.startsWith('audios/') && !file.isDirectory,
                  )
                  .length;
          Logger.log(
            '[导出] 音频框总数: $audioBoxTotalRows，其中有路径的: $audioBoxesWithPathCount，ZIP内: $zipAudioCount',
          );
          if (zipAudioCount > audioBoxesWithPathCount) {
            throw Exception(
              '导出失败：音频文件数量异常，ZIP包内$zipAudioCount个多于有路径的$audioBoxesWithPathCount个，请联系开发者排查。',
            );
          }
          if (zipAudioCount < audioBoxesWithPathCount &&
              missingAudioFiles.isNotEmpty &&
              kDebugMode) {
            Logger.log('[导出] 警告：${missingAudioFiles.length}个音频文件不存在已跳过');
          }
        } finally {
          await inputStream.close();
        }
      } else {
        Logger.log(
          '[导出] 压缩包较大 (${(zipFileBytes / (1024 * 1024)).toStringAsFixed(1)}MB)，跳过完整 ZIP 解码校验以降低内存风险',
        );
        Logger.log(
          '[导出] 已统计：图片框有路径 $imageBoxesWithPathCount 条，已复制 $imageFilesInZipCount 个；音频框有路径 $audioBoxesWithPathCount 条；丢失音频路径 ${missingAudioFiles.length} 条',
        );
      }

      // 清理临时目录
      progressNotifier?.value = "正在清理临时文件...";
      try {
        await tempDir.delete(recursive: true);
      } catch (e) {
        Logger.log('警告：清理临时目录失败: $e');
      }
      progressNotifier?.value = "导出完成";
      Logger.log('目录数据导出完成，ZIP文件路径: $zipPath');
      return zipPath;
    } catch (e, stackTrace) {
      _handleError('导出目录数据失败', e, stackTrace);
      rethrow;
    }
  }

  /// 导入目录数据 - 优化版，支持超大数据处理
  Future<void> importDirectoryData(
    String zipPath, {
    ValueNotifier<String>? progressNotifier,
  }) async {
    final Directory appDocDir = await getApplicationDocumentsDirectory();
    final String tempDirPath = '${appDocDir.path}/temp_import';
    final Directory tempDir = Directory(tempDirPath);
    try {
      Logger.log('开始导入目录数据...');
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
        final outPath = resolveSafeExtractPath(tempDirPath, file.name);
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          final outputStream = OutputFileStream(outFile.path);
          file.writeContent(outputStream);
          await outputStream.close();
        } else {
          await Directory(outPath).create(recursive: true);
        }
        processedFiles++;
        progressNotifier?.value = "正在解压: $processedFiles/$totalFiles";
      }
      await inputStream.close();

      // 读取目录数据 - 支持SPLIT格式与旧版directory_data.json
      progressNotifier?.value = "正在读取数据文件...";

      final String dirDataPath = '$tempDirPath/directory_data';
      final File manifestFile = File('$dirDataPath/directory_manifest.json');
      final bool useSplitFormat = await manifestFile.exists();

      Map<String, dynamic>? legacyTableData;
      List<Map<String, String>>? splitTableFiles;
      if (useSplitFormat) {
        final manifest =
            jsonDecode(await manifestFile.readAsString())
                as Map<String, dynamic>;
        final tableFileList =
            (manifest['tables'] as List<dynamic>?)?.cast<String>() ?? [];
        splitTableFiles = [];
        for (final fileName in tableFileList) {
          final tableName = fileName
              .replaceAll(RegExp(r'_\d+\.json$'), '.json')
              .replaceAll('.json', '');
          splitTableFiles.add({'table': tableName, 'file': fileName});
        }
      } else {
        File dbDataFile = File('$tempDirPath/directory_data.json');
        if (!await dbDataFile.exists()) {
          List<FileSystemEntity> allFiles =
              await Directory(tempDirPath).list(recursive: true).toList();
          List<String> foundFiles = [];
          for (final f in allFiles) {
            if (f is File && f.path.endsWith('directory_data.json')) {
              dbDataFile = File(f.path);
              foundFiles.add(f.path);
            }
          }
          if (foundFiles.isEmpty) {
            throw Exception(
              '备份中未找到directory_data.json或directory_data/目录。请确认导出的ZIP包结构正确。',
            );
          } else if (foundFiles.length > 1) {
            throw Exception(
              '在多个位置找到directory_data.json文件，请检查备份包结构：\n${foundFiles.join('\n')}',
            );
          }
        }
        legacyTableData =
            jsonDecode(await dbDataFile.readAsString()) as Map<String, dynamic>;
      }

      final db = await database;

      // 准备背景图片目录
      final String backgroundImagesPath = '${appDocDir.path}/background_images';
      await Directory(backgroundImagesPath).create(recursive: true);

      final String backgroundVideosPath = '${appDocDir.path}/background_videos';
      await Directory(backgroundVideosPath).create(recursive: true);

      // 准备图片目录
      final String imagesDirPath = '${appDocDir.path}/images';
      await Directory(imagesDirPath).create(recursive: true);

      // 准备音频目录
      final String audiosDirPath = '${appDocDir.path}/audios';
      await Directory(audiosDirPath).create(recursive: true);

      progressNotifier?.value = "正在导入数据库...";

      // 事务有时会因并发/时序出现 "no current transaction" COMMIT 错误，重试可恢复
      const maxAttempts = 3;
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        final List<({String path, VideoViewParams params})>
        pendingBackgroundViewRestores = [];
        try {
          // 简化版事务：直接清空并重填
          await db.transaction((txn) async {
            const List<String> tableNames = [
              'folders',
              'documents',
              'text_boxes',
              'image_boxes',
              'audio_boxes',
              'canvases',
              'document_settings',
              'directory_settings',
            ];

            // 预检查 text_boxes 补列
            try {
              final cols = await txn.rawQuery("PRAGMA table_info(text_boxes)");
              final has = cols.any(
                (c) => (c['name'] as String).toLowerCase() == 'text_segments',
              );
              if (!has) {
                await txn.execute(
                  'ALTER TABLE text_boxes ADD COLUMN text_segments TEXT',
                );
              }
            } catch (e) {
              Logger.log('[导入] 检查/添加 text_segments 列失败: $e');
            }

            // 构建每张真实表的列白名单
            final Map<String, Set<String>> allowedCols = {};
            for (final t in tableNames) {
              final info = await txn.rawQuery('PRAGMA table_info(' + t + ')');
              allowedCols[t] = {for (final r in info) r['name'] as String};
            }

            // 全量替换：DELETE 而不是 DROP，保留索引/触发器结构
            for (final t in tableNames) {
              await txn.delete(t);
            }

            final int batchSize = 100;
            Future<void> processTableRows(
              String tableName,
              List<dynamic> rows,
            ) async {
              if (!tableNames.contains(tableName)) return;
              int processedRows = 0;
              for (int i = 0; i < rows.length; i += batchSize) {
                final end =
                    (i + batchSize < rows.length) ? i + batchSize : rows.length;
                final batch = rows.sublist(i, end);
                for (var row in batch) {
                  if (tableName == 'media_items') continue;
                  Map<String, dynamic> newRow = Map<String, dynamic>.from(
                    row as Map,
                  );
                  if (tableName == 'image_boxes' &&
                      newRow.containsKey('imageFileName')) {
                    final fileName = newRow['imageFileName'];
                    final newPath = p.join(imagesDirPath, fileName);
                    final tempPath = p.join(tempDirPath, 'images', fileName);
                    if (await File(tempPath).exists()) {
                      await copyFileWithStreaming(File(tempPath), newPath);
                      newRow['image_path'] = newPath;
                    } else {
                      newRow['image_path'] = null;
                    }
                    newRow.remove('imageFileName');
                  } else if (tableName == 'audio_boxes' &&
                      newRow.containsKey('audioFileName')) {
                    final fileName = newRow['audioFileName'];
                    final newPath = p.join(audiosDirPath, fileName);
                    final tempAudioPath = p.join(
                      tempDirPath,
                      'audios',
                      fileName,
                    );
                    if (await File(tempAudioPath).exists()) {
                      await Directory(
                        p.dirname(newPath),
                      ).create(recursive: true);
                      await copyFileWithStreaming(File(tempAudioPath), newPath);
                      newRow['audio_path'] = newPath;
                    } else {
                      newRow['audio_path'] = null;
                    }
                    newRow.remove('audioFileName');
                  } else if (tableName == 'directory_settings' ||
                      tableName == 'document_settings') {
                    Map<String, dynamic>? imgViewJson;
                    Map<String, dynamic>? vidViewJson;
                    final rawImgView = newRow['exported_background_image_view'];
                    if (rawImgView is Map) {
                      imgViewJson = Map<String, dynamic>.from(rawImgView);
                    }
                    final rawVidView = newRow['exported_background_video_view'];
                    if (rawVidView is Map) {
                      vidViewJson = Map<String, dynamic>.from(rawVidView);
                    }
                    newRow.remove('exported_background_image_view');
                    newRow.remove('exported_background_video_view');

                    if (newRow.containsKey('backgroundImageFileName')) {
                      final fileName = newRow['backgroundImageFileName'];
                      final newPath = p.join(backgroundImagesPath, fileName);
                      final tempPath = p.join(
                        tempDirPath,
                        'background_images',
                        fileName,
                      );
                      if (await File(tempPath).exists()) {
                        await copyFileWithStreaming(File(tempPath), newPath);
                        newRow['background_image_path'] = newPath;
                      } else {
                        newRow['background_image_path'] = null;
                      }
                      newRow.remove('backgroundImageFileName');
                    }

                    if (newRow.containsKey('backgroundVideoFileName')) {
                      final fileName = newRow['backgroundVideoFileName'];
                      final newPath = p.join(backgroundVideosPath, fileName);
                      final tempPath = p.join(
                        tempDirPath,
                        'background_videos',
                        fileName,
                      );
                      if (await File(tempPath).exists()) {
                        await Directory(
                          backgroundVideosPath,
                        ).create(recursive: true);
                        await copyFileWithStreaming(File(tempPath), newPath);
                        newRow['background_video_path'] = newPath;
                        final v = newRow['backgroundVideoVolume'];
                        if (v is num) {
                          await BackgroundVideoVolumePrefs.setVolumeForPath(
                            newPath,
                            v.toDouble(),
                          );
                        }
                      } else {
                        newRow['background_video_path'] = null;
                      }
                      newRow.remove('backgroundVideoFileName');
                      newRow.remove('backgroundVideoVolume');
                    }

                    final imgP = newRow['background_image_path'] as String?;
                    if (imgViewJson != null &&
                        imgP != null &&
                        imgP.isNotEmpty) {
                      pendingBackgroundViewRestores.add((
                        path: imgP,
                        params: VideoViewParams.fromJsonStaging(imgViewJson),
                      ));
                    }
                    final vidP = newRow['background_video_path'] as String?;
                    if (vidViewJson != null &&
                        vidP != null &&
                        vidP.isNotEmpty) {
                      pendingBackgroundViewRestores.add((
                        path: vidP,
                        params: VideoViewParams.fromJsonStaging(vidViewJson),
                      ));
                    }
                  }
                  if (tableName == 'text_boxes') {
                    if (newRow.containsKey('textSegments') &&
                        !newRow.containsKey('text_segments')) {
                      newRow['text_segments'] = newRow['textSegments'];
                    }
                    if (newRow.containsKey('text_segments') &&
                        newRow['text_segments'] != null &&
                        newRow['text_segments'] is! String) {
                      try {
                        newRow['text_segments'] = jsonEncode(
                          newRow['text_segments'],
                        );
                      } catch (_) {}
                    }
                    newRow.remove('textSegments');
                  }
                  final allowed = allowedCols[tableName] ?? const <String>{};
                  final clean = <String, dynamic>{};
                  for (final k in newRow.keys) {
                    if (allowed.contains(k)) clean[k] = newRow[k];
                  }
                  try {
                    await txn.insert(
                      tableName,
                      clean,
                      conflictAlgorithm: ConflictAlgorithm.replace,
                    );
                  } catch (rowErr, rowStack) {
                    Logger.log('[导入] 行插入失败(表:$tableName): $rowErr');
                    Error.throwWithStackTrace(
                      Exception(
                        '目录数据导入失败，表 $tableName 存在无法写入的记录，已回滚以保护现有数据。原始错误: $rowErr',
                      ),
                      rowStack,
                    );
                  }
                  processedRows++;
                  if (processedRows % kProgressUpdateInterval == 0) {
                    progressNotifier?.value = '正在导入$tableName表: $processedRows';
                  }
                }
              }
              Logger.log('[导入] 表 $tableName 导入完成，共 $processedRows 行');
            }

            if (useSplitFormat) {
              for (final tf in splitTableFiles!) {
                final tableName = tf['table']!;
                final f = File('$dirDataPath/${tf['file']}');
                if (!await f.exists()) continue;
                progressNotifier?.value = "正在读取: ${tf['file']}";
                final rows =
                    jsonDecode(await f.readAsString()) as List<dynamic>;
                await processTableRows(tableName, rows);
              }
            } else {
              for (var entry in legacyTableData!.entries) {
                await processTableRows(entry.key, entry.value as List<dynamic>);
              }
            }
          });
          for (final item in pendingBackgroundViewRestores) {
            await upsertVideoViewParamsForFilePath(item.path, item.params);
          }
          Logger.log(
            '[导入] 已恢复 ${pendingBackgroundViewRestores.length} 条背景取景参数',
          );
          break;
        } on DatabaseException catch (e) {
          final msg = e.toString();
          final isRecoverableTransactionStateError =
              msg.contains('no current transaction') &&
              (msg.contains('COMMIT') || msg.contains('ROLLBACK'));
          if (isRecoverableTransactionStateError && attempt < maxAttempts) {
            Logger.log(
              '[导入] 事务异常，${200 * attempt}ms 后重试 ($attempt/$maxAttempts): $msg',
            );
            progressNotifier?.value =
                '导入事务临时异常，正在自动重试 $attempt/$maxAttempts...';
            await Future.delayed(Duration(milliseconds: 200 * attempt));
          } else {
            rethrow;
          }
        }
      }

      final portablePrefsFile = File('$dirDataPath/portable_prefs.json');
      if (await portablePrefsFile.exists()) {
        try {
          final raw =
              jsonDecode(await portablePrefsFile.readAsString())
                  as Map<String, dynamic>;
          final prefs = await SharedPreferences.getInstance();
          await applyDirectoryPortablePrefsImportMap(prefs, raw);
          Logger.log('[导入] 已恢复 portable_prefs.json（播放游标/续播、文档栏视频静音、背景视频音量）');
        } catch (e) {
          Logger.log('[导入] portable_prefs.json 恢复失败（已跳过）: $e');
        }
      }

      // 清理临时目录
      progressNotifier?.value = "正在清理临时文件...";
      try {
        await Directory(tempDirPath).delete(recursive: true);
      } catch (e) {
        Logger.log('警告：清理临时目录失败: $e');
        // 不影响主要功能，继续执行
      }

      progressNotifier?.value = "导入完成";
      Logger.log('目录数据导入完成');
    } catch (e, stackTrace) {
      _handleError('导入数据失败', e, stackTrace);
      rethrow;
    } finally {
      if (await tempDir.exists()) {
        try {
          await tempDir.delete(recursive: true);
        } catch (e) {
          Logger.log('清理导入临时目录失败: $e');
        }
      }
    }
  }

  // 保留原来的方法名称，但内部调用新方法，以保持兼容性
  Future<String> exportAllData() async {
    return exportDirectoryData();
  }

  Future<void> importAllData(
    String zipPath, {
    ValueNotifier<String>? progressNotifier,
  }) async {
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

  /// 删除文档关联的物理文件（图片、音频、背景图），释放存储空间
  Future<void> _deleteDocumentPhysicalFiles(String documentId) async {
    try {
      final payload = await _collectDocumentFilesForDeletion(documentId);
      await _deleteCollectedDocumentFiles(payload);
    } catch (e) {
      if (kDebugMode) Logger.log('_deleteDocumentPhysicalFiles 失败: $e');
    }
  }

  Future<
    ({
      List<String> mediaPaths,
      List<({String? path, BackgroundMediaOrigin? origin})> backgroundFiles,
    })
  >
  _collectDocumentFilesForDeletion(String documentId) async {
    final appDir = (await getApplicationDocumentsDirectory()).path;
    final mediaPaths = <String>[];
    final backgroundFiles = <({String? path, BackgroundMediaOrigin? origin})>[];

    String toAbsolute(String? pathStr) {
      if (pathStr == null || pathStr.isEmpty) return '';
      final s = pathStr.trim();
      if (s.isEmpty) return '';
      final abs =
          s.startsWith('/') || (s.length > 1 && s[1] == ':')
              ? s
              : p.join(appDir, s);
      return p.normalize(p.absolute(abs));
    }

    try {
      final db = await database;
      final imageBoxes = await db.query(
        'image_boxes',
        columns: ['image_path'],
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      for (final row in imageBoxes) {
        final abs = toAbsolute(row['image_path']?.toString());
        if (abs.isNotEmpty) mediaPaths.add(abs);
      }

      final audioBoxes = await db.query(
        'audio_boxes',
        columns: ['audio_path'],
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      for (final row in audioBoxes) {
        final abs = toAbsolute(row['audio_path']?.toString());
        if (abs.isNotEmpty) mediaPaths.add(abs);
      }

      final settings = await db.query(
        'document_settings',
        columns: [
          'background_image_path',
          'background_video_path',
          'background_image_origin',
          'background_video_origin',
        ],
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      for (final row in settings) {
        final img = row['background_image_path'] as String?;
        final vid = row['background_video_path'] as String?;
        final io = BackgroundMediaOrigin.fromDbValue(
          row['background_image_origin'] as int?,
        );
        final vo = BackgroundMediaOrigin.fromDbValue(
          row['background_video_origin'] as int?,
        );
        backgroundFiles.add((path: img, origin: io));
        backgroundFiles.add((path: vid, origin: vo));
      }
    } catch (e) {
      if (kDebugMode) Logger.log('_collectDocumentFilesForDeletion 失败: $e');
    }

    return (mediaPaths: mediaPaths, backgroundFiles: backgroundFiles);
  }

  Future<void> _deleteCollectedDocumentFiles(
    ({
      List<String> mediaPaths,
      List<({String? path, BackgroundMediaOrigin? origin})> backgroundFiles,
    })
    payload,
  ) async {
    try {
      final fileCleanupService = getService<FileCleanupService>();
      if (!fileCleanupService.isInitialized) return;
      final appDir = (await getApplicationDocumentsDirectory()).path;
      for (final bg in payload.backgroundFiles) {
        try {
          await deleteBackgroundPhysicalFileIfAllowed(
            bg.path,
            bg.origin,
            appDir,
          );
        } catch (_) {}
      }
      for (final filePath in payload.mediaPaths) {
        try {
          await fileCleanupService.deleteMediaFileCompletely(filePath);
        } catch (e) {
          if (kDebugMode) Logger.log('删除文档关联文件失败: $filePath, $e');
        }
      }
    } catch (e) {
      if (kDebugMode) Logger.log('_deleteCollectedDocumentFiles 失败: $e');
    }
  }

  /// 递归收集文件夹及其子文件夹下所有文档的 ID
  Future<List<String>> _collectDocumentIdsInFolder(String folderId) async {
    final db = await database;
    final ids = <String>[];

    final documents = await db.query(
      'documents',
      columns: ['id'],
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );
    for (final doc in documents) ids.add(doc['id'] as String);

    final subFolders = await db.query(
      'folders',
      columns: ['id'],
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );
    for (final sub in subFolders) {
      ids.addAll(await _collectDocumentIdsInFolder(sub['id'] as String));
    }
    return ids;
  }

  Future<void> deleteDocument(
    String documentName, {
    String? parentFolder,
  }) async {
    final db = await database;

    try {
      List<Map<String, dynamic>> documents = await db.query(
        'documents',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [documentName],
      );
      ({
        List<String> mediaPaths,
        List<({String? path, BackgroundMediaOrigin? origin})> backgroundFiles,
      })?
      deletePayload;
      if (documents.isNotEmpty) {
        final documentId = documents.first['id'] as String;
        deletePayload = await _collectDocumentFilesForDeletion(documentId);
      }

      await db.transaction((txn) async {
        if (documents.isNotEmpty) {
          String documentId = documents.first['id'] as String;
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
          await txn.delete(
            'documents',
            where: 'id = ?',
            whereArgs: [documentId],
          );
        }

        String? parentFolderId;
        if (parentFolder != null) {
          final parentFolderData = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [parentFolder],
          );
          parentFolderId =
              parentFolderData.isNotEmpty
                  ? parentFolderData.first['id'] as String?
                  : null;
        }

        List<Map<String, dynamic>> remainingDocuments = await txn.query(
          'documents',
          where:
              parentFolderId == null
                  ? 'parent_folder IS NULL'
                  : 'parent_folder = ?',
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

      if (deletePayload != null) {
        await _deleteCollectedDocumentFiles(deletePayload);
      }

      try {
        final fileCleanupService = getService<FileCleanupService>();
        if (fileCleanupService.isInitialized) {
          await fileCleanupService.deleteDocumentCompletely(documentName);
        }
      } catch (e) {
        if (kDebugMode) Logger.log('文件清理服务删除文档失败: $e');
      }

      if (kDebugMode) Logger.log('成功删除文档: $documentName');
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
          {'background_image_path': null, 'background_image_origin': null},
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        Logger.log('Background image path deleted for document: $documentName');
      } else {
        Logger.log('Document not found: $documentName');
      }
    } catch (e, stackTrace) {
      _handleError(
        'Failed to delete document background image for $documentName',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteDocumentBackgroundVideo(String documentName) async {
    final db = await database;
    try {
      final List<Map<String, dynamic>> docs = await db.query(
        'documents',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [documentName],
      );

      if (docs.isNotEmpty) {
        final documentId = docs.first['id'] as String;
        await db.update(
          'document_settings',
          {'background_video_path': null, 'background_video_origin': null},
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        Logger.log('Background video path deleted for document: $documentName');
      } else {
        Logger.log('Document not found: $documentName');
      }
    } catch (e, stackTrace) {
      _handleError(
        'Failed to delete document background video for $documentName',
        e,
        stackTrace,
      );
      rethrow;
    }
  }

  /// 清空文档背景图/视频（留白），保留已保存的 [background_color]；并按来源规则尝试删除拍照产生的本地副本。
  Future<void> clearDocumentBackgroundToBlank(String documentName) async {
    final appDir = (await getApplicationDocumentsDirectory()).path;
    final db = await database;
    final docs = await db.query(
      'documents',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: [documentName],
    );
    if (docs.isEmpty) return;
    final documentId = docs.first['id'] as String;
    final rows = await db.query(
      'document_settings',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    if (rows.isNotEmpty) {
      final s = rows.first;
      final img = s['background_image_path'] as String?;
      final vid = s['background_video_path'] as String?;
      final io = BackgroundMediaOrigin.fromDbValue(
        s['background_image_origin'] as int?,
      );
      final vo = BackgroundMediaOrigin.fromDbValue(
        s['background_video_origin'] as int?,
      );
      await deleteBackgroundPhysicalFileIfAllowed(img, io, appDir);
      await deleteBackgroundPhysicalFileIfAllowed(vid, vo, appDir);
      await db.update(
        'document_settings',
        {
          'background_image_path': null,
          'background_video_path': null,
          'background_image_origin': null,
          'background_video_origin': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
    }
  }

  Future<void> deleteFolder(String folderName, {String? parentFolder}) async {
    final db = await database;

    try {
      final folderToDelete = await db.query(
        'folders',
        where: 'name = ?',
        whereArgs: [folderName],
      );
      if (folderToDelete.isEmpty) {
        throw Exception('文件夹不存在: $folderName');
      }

      final folderId = folderToDelete.first['id'] as String;
      final documentIds = await _collectDocumentIdsInFolder(folderId);
      final deletePayloads =
          <
            ({
              List<String> mediaPaths,
              List<({String? path, BackgroundMediaOrigin? origin})>
              backgroundFiles,
            })
          >[];
      for (final docId in documentIds) {
        deletePayloads.add(await _collectDocumentFilesForDeletion(docId));
      }

      await db.transaction((txn) async {
        await _deleteFolderRecursive(txn, folderId, folderName);

        String? parentFolderId;
        if (parentFolder != null) {
          final parentFolderData = await txn.query(
            'folders',
            where: 'name = ?',
            whereArgs: [parentFolder],
          );
          parentFolderId =
              parentFolderData.isNotEmpty
                  ? parentFolderData.first['id'] as String?
                  : null;
        }

        List<Map<String, dynamic>> remainingFolders = await txn.query(
          'folders',
          where:
              parentFolderId == null
                  ? 'parent_folder IS NULL'
                  : 'parent_folder = ?',
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

      for (final payload in deletePayloads) {
        await _deleteCollectedDocumentFiles(payload);
      }

      try {
        final fileCleanupService = getService<FileCleanupService>();
        if (fileCleanupService.isInitialized) {
          await fileCleanupService.deleteFolderCompletely(folderName);
        }
      } catch (e) {
        if (kDebugMode) Logger.log('文件清理服务删除文件夹失败: $e');
      }

      if (kDebugMode) Logger.log('成功删除文件夹: $folderName');
    } catch (e, stackTrace) {
      _handleError('删除文件夹失败: $folderName', e, stackTrace);
      rethrow;
    }
  }

  /// 在事务内部递归删除文件夹
  Future<void> _deleteFolderRecursive(
    Transaction txn,
    String folderId,
    String folderName,
  ) async {
    if (kDebugMode) {
      Logger.log('开始递归删除文件夹: $folderName (ID: $folderId)');
    }

    // 获取子文档
    List<Map<String, dynamic>> documents = await txn.query(
      'documents',
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );

    if (kDebugMode) {
      Logger.log('文件夹 $folderName 包含 ${documents.length} 个文档');
    }

    // 删除子文档
    for (var doc in documents) {
      final docId = doc['id'] as String;
      final docName = doc['name'] as String;
      if (kDebugMode) {
        Logger.log('删除文档: $docName (ID: $docId)');
      }
      await txn.delete(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [docId],
      );
      await txn.delete(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [docId],
      );
      await txn.delete(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [docId],
      );
      await txn.delete(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [docId],
      );
      await txn.delete('documents', where: 'id = ?', whereArgs: [docId]);
    }

    // 获取子文件夹
    List<Map<String, dynamic>> subFolders = await txn.query(
      'folders',
      where: 'parent_folder = ?',
      whereArgs: [folderId],
    );

    if (kDebugMode) {
      Logger.log('文件夹 $folderName 包含 ${subFolders.length} 个子文件夹');
    }

    // 递归删除子文件夹
    for (var subFolder in subFolders) {
      final subFolderId = subFolder['id'] as String;
      final subFolderName = subFolder['name'] as String;
      if (kDebugMode) {
        Logger.log('递归删除子文件夹: $subFolderName (ID: $subFolderId)');
      }
      await _deleteFolderRecursive(txn, subFolderId, subFolderName);
    }

    // 删除当前文件夹
    if (kDebugMode) {
      Logger.log('删除文件夹本身: $folderName (ID: $folderId)');
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
        where:
            parentFolderId == null
                ? 'parent_folder IS NULL'
                : 'parent_folder = ?',
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
            Logger.log('警告：发现无效文件夹数据，已跳过: $folder');
          }
        }
      }

      if (kDebugMode) {
        Logger.log('获取文件夹成功: ${validResults.length} 个有效文件夹');
      }

      return validResults;
    } catch (e, stackTrace) {
      _handleError('获取文件夹时出错', e, stackTrace);
      Logger.log('获取文件夹时出错: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getDocuments({
    String? parentFolder,
  }) async {
    final db = await database;
    try {
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
      }

      List<Map<String, dynamic>> result = await db.query(
        'documents',
        where:
            parentFolderId == null
                ? 'parent_folder IS NULL'
                : 'parent_folder = ?',
        whereArgs: parentFolderId == null ? null : [parentFolderId],
        orderBy: 'order_index ASC',
      );

      // 数据验证和清理
      List<Map<String, dynamic>> validResults = [];
      for (var document in result) {
        if (document['name'] != null &&
            document['name'].toString().isNotEmpty) {
          validResults.add(Map<String, dynamic>.from(document));
        } else {
          if (kDebugMode) {
            Logger.log('警告：发现无效文档数据，已跳过: $document');
          }
        }
      }

      if (kDebugMode) {
        Logger.log('获取文档成功: ${validResults.length} 个有效文档');
      }

      return validResults;
    } catch (e, stackTrace) {
      _handleError('获取文档时出错', e, stackTrace);
      Logger.log('获取文档时出错: $e');
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
      Logger.log('根据名称获取文件夹时出错: $e');
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
      Logger.log('根据名称获取文档时出错: $e');
      return null;
    }
  }

  Future<String> exportDocument(String documentName) async {
    try {
      Logger.log('开始导出文档: $documentName');
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

      // 导出文档相关的数据 (包含画布)
      final List<Map<String, dynamic>> textBoxRows = await db.query(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final List<Map<String, dynamic>> imageBoxRows = await db.query(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final List<Map<String, dynamic>> audioBoxRows = await db.query(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final List<Map<String, dynamic>> canvasRows = await db.query(
        'canvases',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final Map<String, List<Map<String, dynamic>>> documentData = {
        'documents': documents,
        'text_boxes': textBoxRows,
        'image_boxes': imageBoxRows,
        'audio_boxes': audioBoxRows,
        'canvases': canvasRows,
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
        String imagePath =
            imageBox['imagePath'] ?? imageBox['image_path'] ?? '';
        if (imagePath.isNotEmpty) {
          String fileName = p.basename(imagePath);
          imageBoxCopy['imageFileName'] = fileName;

          // 复制图片文件
          File imageFile = File(imagePath);
          if (await imageFile.exists()) {
            String relativePath = 'images/$fileName';
            await Directory('$tempDirPath/images').create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            Logger.log('已导出图片: $relativePath');
          } else {
            Logger.log('警告：图片文件不存在: $imagePath');
          }
        }
        imageBoxesToExport.add(imageBoxCopy);
      }
      documentData['image_boxes'] = imageBoxesToExport;

      // 处理音频框数据和音频文件
      List<Map<String, dynamic>> audioBoxesToExport = [];
      for (var audioBox in documentData['audio_boxes']!) {
        Map<String, dynamic> audioBoxCopy = Map<String, dynamic>.from(audioBox);
        String audioPath =
            audioBox['audioPath'] ?? audioBox['audio_path'] ?? '';
        if (audioPath.isNotEmpty) {
          String fileName = p.basename(audioPath);
          audioBoxCopy['audioFileName'] = fileName;

          // 复制音频文件
          File audioFile = File(audioPath);
          if (await audioFile.exists()) {
            String relativePath = 'audios/$fileName';
            await Directory('$tempDirPath/audios').create(recursive: true);
            await audioFile.copy('$tempDirPath/$relativePath');
            Logger.log('已导出音频: $relativePath');
          } else {
            Logger.log('警告：音频文件不存在: $audioPath');
          }
        }
        audioBoxesToExport.add(audioBoxCopy);
      }
      documentData['audio_boxes'] = audioBoxesToExport;

      // 画布无需复制文件，只需原样写入（已在 documentData 初始化）

      // 处理文档设置和背景图片/视频（与目录整包导出字段一致，便于取景参数可移植）
      String safeDocExportFileName(String base, String ext) {
        String name = base.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
        if (name.length > 80) name = name.substring(0, 80);
        return name + ext;
      }

      String docKey = documentId.toString().replaceAll(
        RegExp(r'[^A-Za-z0-9_]'),
        '_',
      );
      if (docKey.length > 40) docKey = docKey.substring(0, 40);

      List<Map<String, dynamic>> documentSettingsToExport = [];
      for (var settings in documentData['document_settings']!) {
        Map<String, dynamic> settingsCopy = Map<String, dynamic>.from(settings);
        String? backgroundImagePath =
            settings['background_image_path']?.toString();
        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final String ext = p.extension(backgroundImagePath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundImagePath,
          );
          final String fileName = safeDocExportFileName(
            '${docKey}_$originalFileName',
            ext,
          );
          settingsCopy['backgroundImageFileName'] = fileName;

          File imageFile = File(backgroundImagePath);
          if (await imageFile.exists()) {
            String relativePath = 'background_images/$fileName';
            await Directory(
              '$tempDirPath/background_images',
            ).create(recursive: true);
            await imageFile.copy('$tempDirPath/$relativePath');
            Logger.log('已导出背景图片: $relativePath');
          } else {
            Logger.log('警告：背景图片不存在: $backgroundImagePath');
          }
        }

        String? backgroundVideoPath =
            settings['background_video_path']?.toString();
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final String ext = p.extension(backgroundVideoPath);
          final String originalFileName = p.basenameWithoutExtension(
            backgroundVideoPath,
          );
          final String fileName = safeDocExportFileName(
            '${docKey}_vid_$originalFileName',
            ext,
          );
          settingsCopy['backgroundVideoFileName'] = fileName;
          final File videoFile = File(backgroundVideoPath);
          if (await videoFile.exists()) {
            final String relativePath = 'background_videos/$fileName';
            await Directory(
              '$tempDirPath/background_videos',
            ).create(recursive: true);
            await videoFile.copy('$tempDirPath/$relativePath');
            Logger.log('已导出背景视频: $relativePath');
          } else {
            Logger.log('警告：背景视频不存在: $backgroundVideoPath');
          }
        }

        if (backgroundImagePath != null && backgroundImagePath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundImagePath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_image_view'] = vp.toJsonStaging();
          }
        }
        if (backgroundVideoPath != null && backgroundVideoPath.isNotEmpty) {
          final vp = await getVideoViewParamsForMediaFilePath(
            backgroundVideoPath,
          );
          if (!vp.isDefault) {
            settingsCopy['exported_background_video_view'] = vp.toJsonStaging();
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
      final String formattedTime =
          '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final String zipPath = '$backupPath/$documentName-$formattedTime.zip';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(Directory(tempDirPath), includeDirName: false);
      encoder.close();

      // 清理临时目录
      await tempDir.delete(recursive: true);

      Logger.log('文档导出完成: $zipPath');
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

  Future<void> importDocument(
    String zipPath, {
    String? targetDocumentName,
    String? targetParentFolder,
  }) async {
    try {
      Logger.log('开始导入文档: $zipPath');
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
      try {
        final archive = ZipDecoder().decodeStream(inputStream);
        for (final file in archive) {
          if (file.isFile) {
            final outPath = resolveSafeExtractPath(tempDirPath, file.name);
            await extractArchiveFileToPath(file, outPath);
          }
        }
      } finally {
        await inputStream.close();
      }

      // 读取文档数据
      final File dataFile = File('$tempDirPath/document_data.json');
      if (!await dataFile.exists()) {
        throw Exception('导入文件格式错误：缺少document_data.json');
      }

      final String jsonContent = await dataFile.readAsString();
      final Map<String, dynamic> importData = jsonDecode(jsonContent);

      final db = await database;

      final List<({String path, VideoViewParams params})>
      pendingDocBackgroundViewRestores = [];

      await db.transaction((txn) async {
        // 处理文档数据
        List<dynamic> documents = importData['documents'] ?? [];
        if (documents.isEmpty) {
          throw Exception('导入文件中没有找到文档数据');
        }

        Map<String, dynamic> documentData = Map<String, dynamic>.from(
          documents.first,
        );
        String originalDocumentId = documentData['id'];
        String newDocumentId = const Uuid().v4();

        // 设置文档名称
        String finalDocumentName =
            targetDocumentName ??
            documentData['name'] ??
            p.basenameWithoutExtension(zipPath);

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
        Logger.log('已导入文档: $uniqueName');

        // === 先处理文本/图片/音频框并记录旧->新ID映射，供画布重映射 ===
        final Map<String, String> textIdMap = {};
        final Map<String, String> imageIdMap = {};
        final Map<String, String> audioIdMap = {};
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

            // 始终生成新ID，保持与导出/复制策略一致
            final oldId = data['id'].toString();
            data['id'] = const Uuid().v4();
            textIdMap[oldId] = data['id'];
            await txn.insert(
              'text_boxes',
              data,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
        Logger.log('已导入 ${textBoxes.length} 个文本框');

        // 处理图片框和图片文件
        List<dynamic> imageBoxes = importData['image_boxes'] ?? [];
        for (var imageBox in List.from(imageBoxes)) {
          Map<String, dynamic> imageBoxData = Map<String, dynamic>.from(
            imageBox,
          );
          final oldId = imageBoxData['id'].toString();
          final newImageBoxId = const Uuid().v4();
          imageBoxData['id'] = newImageBoxId;
          imageBoxData['document_id'] = newDocumentId;

          // 处理图片文件
          String? imageFileName = imageBoxData['imageFileName'];
          if (imageFileName != null && imageFileName.isNotEmpty) {
            String sourcePath = '$tempDirPath/images/$imageFileName';
            File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              String targetPath =
                  '${appDocDir.path}/images/$newImageBoxId.${p.extension(imageFileName).substring(1)}';
              await Directory(p.dirname(targetPath)).create(recursive: true);
              await sourceFile.copy(targetPath);
              imageBoxData['image_path'] = targetPath;
              Logger.log('已导入图片: $imageFileName -> $targetPath');
            }
          }

          // 移除临时字段和错误字段名
          imageBoxData.remove('imageFileName');
          imageBoxData.remove('imagePath');
          await txn.insert('image_boxes', imageBoxData);
          imageIdMap[oldId] = newImageBoxId;
        }
        Logger.log('已导入 ${imageBoxes.length} 个图片框');

        // 处理音频框和音频文件
        List<dynamic> audioBoxes = importData['audio_boxes'] ?? [];
        for (var audioBox in audioBoxes) {
          Map<String, dynamic> audioBoxData = Map<String, dynamic>.from(
            audioBox,
          );
          final oldId = audioBoxData['id'].toString();
          final newAudioBoxId = const Uuid().v4();
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
              Logger.log('已导入音频: $audioFileName -> $targetPath');
            }
          }
          // 移除临时字段和错误字段名
          audioBoxData.remove('audioFileName');
          audioBoxData.remove('audioPath');
          await txn.insert('audio_boxes', audioBoxData);
          audioIdMap[oldId] = newAudioBoxId;
        }
        Logger.log('已导入 ${audioBoxes.length} 个音频框');

        // === 导入画布并重映射内部关联 ID ===
        List<dynamic> canvases = importData['canvases'] ?? [];
        String remap(String? csv, Map<String, String> m) {
          if (csv == null || csv.trim().isEmpty) return '';
          return csv
              .split(',')
              .map((id) => m[id.trim()] ?? '')
              .where((v) => v.isNotEmpty)
              .join(',');
        }

        for (var canvas in canvases) {
          Map<String, dynamic> c = Map<String, dynamic>.from(canvas as Map);
          c['id'] = const Uuid().v4();
          c['document_id'] = newDocumentId;
          c['front_text_box_ids'] = remap(
            c['front_text_box_ids']?.toString(),
            textIdMap,
          );
          c['back_text_box_ids'] = remap(
            c['back_text_box_ids']?.toString(),
            textIdMap,
          );
          c['front_image_box_ids'] = remap(
            c['front_image_box_ids']?.toString(),
            imageIdMap,
          );
          c['back_image_box_ids'] = remap(
            c['back_image_box_ids']?.toString(),
            imageIdMap,
          );
          c['front_audio_box_ids'] = remap(
            c['front_audio_box_ids']?.toString(),
            audioIdMap,
          );
          c['back_audio_box_ids'] = remap(
            c['back_audio_box_ids']?.toString(),
            audioIdMap,
          );
          final now = DateTime.now().millisecondsSinceEpoch;
          c['created_at'] = now;
          c['updated_at'] = now;
          await txn.insert('canvases', c);
        }
        Logger.log('已导入 ${canvases.length} 个画布');

        // 处理文档设置和背景图片/视频
        List<dynamic> documentSettings = importData['document_settings'] ?? [];
        final String bgVideosDir = '${appDocDir.path}/background_videos';
        await Directory(bgVideosDir).create(recursive: true);
        for (var settings in documentSettings) {
          Map<String, dynamic> settingsData = Map<String, dynamic>.from(
            settings,
          );
          settingsData['document_id'] = newDocumentId;
          settingsData.remove('id');

          Map<String, dynamic>? imgViewJson;
          Map<String, dynamic>? vidViewJson;
          final rawImgView = settingsData['exported_background_image_view'];
          if (rawImgView is Map) {
            imgViewJson = Map<String, dynamic>.from(rawImgView);
          }
          final rawVidView = settingsData['exported_background_video_view'];
          if (rawVidView is Map) {
            vidViewJson = Map<String, dynamic>.from(rawVidView);
          }
          settingsData.remove('exported_background_image_view');
          settingsData.remove('exported_background_video_view');

          settingsData['background_image_path'] = null;
          settingsData['background_video_path'] = null;

          String? backgroundImageFileName =
              settingsData['backgroundImageFileName'];
          if (backgroundImageFileName != null &&
              backgroundImageFileName.isNotEmpty) {
            String sourcePath =
                '$tempDirPath/background_images/$backgroundImageFileName';
            File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              String targetPath =
                  '${appDocDir.path}/background_images/${newDocumentId}_$backgroundImageFileName';
              await Directory(p.dirname(targetPath)).create(recursive: true);
              await sourceFile.copy(targetPath);
              settingsData['background_image_path'] = targetPath;
              Logger.log('已导入背景图片: $backgroundImageFileName -> $targetPath');
            }
          }
          settingsData.remove('backgroundImageFileName');

          String? backgroundVideoFileName =
              settingsData['backgroundVideoFileName'];
          if (backgroundVideoFileName != null &&
              backgroundVideoFileName.isNotEmpty) {
            final String sourcePath =
                '$tempDirPath/background_videos/$backgroundVideoFileName';
            final File sourceFile = File(sourcePath);
            if (await sourceFile.exists()) {
              final String targetPath =
                  '$bgVideosDir/${newDocumentId}_$backgroundVideoFileName';
              await sourceFile.copy(targetPath);
              settingsData['background_video_path'] = targetPath;
              Logger.log('已导入背景视频: $backgroundVideoFileName -> $targetPath');
            }
          }
          settingsData.remove('backgroundVideoFileName');

          final imgP = settingsData['background_image_path'] as String?;
          if (imgViewJson != null && imgP != null && imgP.isNotEmpty) {
            pendingDocBackgroundViewRestores.add((
              path: imgP,
              params: VideoViewParams.fromJsonStaging(imgViewJson),
            ));
          }
          final vidP = settingsData['background_video_path'] as String?;
          if (vidViewJson != null && vidP != null && vidP.isNotEmpty) {
            pendingDocBackgroundViewRestores.add((
              path: vidP,
              params: VideoViewParams.fromJsonStaging(vidViewJson),
            ));
          }

          await txn.insert('document_settings', settingsData);
        }
        Logger.log('已导入 ${documentSettings.length} 个文档设置');
      });

      for (final item in pendingDocBackgroundViewRestores) {
        await upsertVideoViewParamsForFilePath(item.path, item.params);
      }
      if (pendingDocBackgroundViewRestores.isNotEmpty) {
        Logger.log(
          '[导入文档] 已恢复 ${pendingDocBackgroundViewRestores.length} 条背景取景参数',
        );
      }

      // 清理临时目录
      await tempDir.delete(recursive: true);

      Logger.log('文档导入完成');
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
      Logger.log('获取所有目录文件夹时出错: $e');
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
  Future<String> copyDocument(
    String sourceDocumentName, {
    String? parentFolder,
  }) async {
    // NEW SIGNATURE
    Logger.log(
      'copyDocument called for $sourceDocumentName, parentFolder: $parentFolder',
    );
    final db = await database;

    // 1. 生成唯一的文档名称
    String newName = '$sourceDocumentName-副本';
    String finalNewDocumentName = newName;
    int attempt = 0;
    String baseName = newName;
    while (await doesNameExist(finalNewDocumentName)) {
      attempt++;
      finalNewDocumentName = attempt > 1 ? '$baseName($attempt)' : baseName;
      if (attempt > 100) {
        Logger.log(
          'Failed to generate a unique name for document copy after 100 attempts.',
        );
        throw Exception('Failed to generate a unique name for document copy.');
      }
    }
    Logger.log('Final new document name for copy: $finalNewDocumentName');

    try {
      // 2. 预读取所有数据（事务外）
      List<Map<String, dynamic>> sourceDocs = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [sourceDocumentName],
      );
      if (sourceDocs.isEmpty) {
        throw Exception('Source document not found: $sourceDocumentName');
      }
      String sourceId = sourceDocs.first['id'].toString();

      int maxOrder = 0;
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
        final docs = await db.query(
          'documents',
          where: 'parent_folder = ?',
          whereArgs: [parentFolderId],
          orderBy: 'order_index DESC',
          limit: 1,
        );
        if (docs.isNotEmpty) {
          maxOrder = (docs.first['order_index'] as int?) ?? 0;
        }
      }

      final textBoxes = await db.query(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId],
      );
      final imageBoxes = await db.query(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId],
      );
      final audioBoxes = await db.query(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [sourceId],
      );
      final sourceCanvases = await db.query(
        'canvases',
        where: 'document_id = ?',
        whereArgs: [sourceId],
      );
      final docSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [sourceId],
      );

      String newDocId = const Uuid().v4();
      final Map<String, String> textIdMap = {};
      final Map<String, String> imageIdMap = {};
      final Map<String, String> audioIdMap = {};

      // 3. 预复制背景图片（事务外，避免事务内文件 I/O）
      Map<String, dynamic>? newSettings;
      if (docSettings.isNotEmpty) {
        newSettings = Map<String, dynamic>.from(docSettings.first);
        newSettings!.remove('id');
        newSettings!['document_id'] = newDocId;
        newSettings!.remove('document_name');
        String? originalBackgroundPath = newSettings!['background_image_path'];
        if (originalBackgroundPath != null &&
            originalBackgroundPath.isNotEmpty) {
          try {
            final originalFile = File(originalBackgroundPath);
            if (await originalFile.exists()) {
              final appDir = await getApplicationDocumentsDirectory();
              final backgroundDir = Directory('${appDir.path}/backgrounds');
              if (!await backgroundDir.exists()) {
                await backgroundDir.create(recursive: true);
              }
              final ext = p.extension(originalBackgroundPath);
              final newBackgroundPath =
                  '${backgroundDir.path}/${const Uuid().v4()}$ext';
              await originalFile.copy(newBackgroundPath);
              newSettings!['background_image_path'] = newBackgroundPath;
              Logger.log(
                '复制背景图片: $originalBackgroundPath -> $newBackgroundPath',
              );
            } else {
              newSettings!['background_image_path'] = null;
            }
          } catch (e) {
            Logger.log('复制背景图片时出错: $e');
            newSettings!['background_image_path'] = null;
          }
        }
      }

      // 4. 事务内执行所有 DB 写入，确保原子性
      await db.transaction((txn) async {
        await txn.insert('documents', {
          'id': newDocId,
          'name': finalNewDocumentName,
          'parent_folder': parentFolderId,
          'is_template': 0,
          'order_index': maxOrder + 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        for (var textBox in textBoxes) {
          final oldId = textBox['id'].toString();
          final newTextBox = Map<String, dynamic>.from(textBox);
          newTextBox.remove('id');
          newTextBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newTextBox['id'] = newId;
          textIdMap[oldId] = newId;
          await txn.insert('text_boxes', newTextBox);
        }
        for (var imageBox in imageBoxes) {
          final oldId = imageBox['id'].toString();
          final newImageBox = Map<String, dynamic>.from(imageBox);
          newImageBox.remove('id');
          newImageBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newImageBox['id'] = newId;
          imageIdMap[oldId] = newId;
          await txn.insert('image_boxes', newImageBox);
        }
        for (var audioBox in audioBoxes) {
          final oldId = audioBox['id'].toString();
          final newAudioBox = Map<String, dynamic>.from(audioBox);
          newAudioBox.remove('id');
          newAudioBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newAudioBox['id'] = newId;
          audioIdMap[oldId] = newId;
          await txn.insert('audio_boxes', newAudioBox);
        }

        String remapIdList(String? csv, Map<String, String> idMap) {
          if (csv == null || csv.trim().isEmpty) return '';
          return csv
              .split(',')
              .map((id) => idMap[id.trim()] ?? '')
              .where((v) => v.isNotEmpty)
              .join(',');
        }

        for (var canvas in sourceCanvases) {
          final newCanvas = Map<String, dynamic>.from(canvas);
          newCanvas['id'] = const Uuid().v4();
          newCanvas['document_id'] = newDocId;
          newCanvas['front_text_box_ids'] = remapIdList(
            canvas['front_text_box_ids']?.toString(),
            textIdMap,
          );
          newCanvas['back_text_box_ids'] = remapIdList(
            canvas['back_text_box_ids']?.toString(),
            textIdMap,
          );
          newCanvas['front_image_box_ids'] = remapIdList(
            canvas['front_image_box_ids']?.toString(),
            imageIdMap,
          );
          newCanvas['back_image_box_ids'] = remapIdList(
            canvas['back_image_box_ids']?.toString(),
            imageIdMap,
          );
          newCanvas['front_audio_box_ids'] = remapIdList(
            canvas['front_audio_box_ids']?.toString(),
            audioIdMap,
          );
          newCanvas['back_audio_box_ids'] = remapIdList(
            canvas['back_audio_box_ids']?.toString(),
            audioIdMap,
          );
          newCanvas['created_at'] = DateTime.now().millisecondsSinceEpoch;
          newCanvas['updated_at'] = DateTime.now().millisecondsSinceEpoch;
          await txn.insert('canvases', newCanvas);
        }

        if (newSettings != null) {
          await txn.insert('document_settings', newSettings);
        }
      });

      Logger.log('Successfully copied document: $finalNewDocumentName');
      return finalNewDocumentName;
    } catch (e, stackTrace) {
      _handleError('复制文档时出错', e, stackTrace);
      Logger.log('复制文档时出错: $e');
      rethrow;
    }
  }

  Future<String> createDocumentFromTemplate(
    String templateName,
    String newDocumentName, {
    String? parentFolder,
  }) async {
    Logger.log(
      'createDocumentFromTemplate called for template $templateName, newName: $newDocumentName, parentFolder: $parentFolder',
    );
    final db = await database;

    String finalNewDocumentName = newDocumentName;
    int attempt = 0;
    String baseName = newDocumentName;
    while (await doesNameExist(finalNewDocumentName)) {
      attempt++;
      finalNewDocumentName = attempt > 1 ? '$baseName($attempt)' : baseName;
      if (attempt > 100) {
        Logger.log(
          'Failed to generate a unique name for document from template after 100 attempts.',
        );
        throw Exception(
          'Failed to generate a unique name for document from template.',
        );
      }
    }
    Logger.log('Final new document name from template: $finalNewDocumentName');

    try {
      final templateDocs = await db.query(
        'documents',
        where: 'name = ?',
        whereArgs: [templateName],
      );
      if (templateDocs.isEmpty) {
        throw Exception('Template document not found: $templateName');
      }
      String templateId = templateDocs.first['id'].toString();

      int maxOrder = 0;
      String? parentFolderId;
      if (parentFolder != null) {
        final folder = await getFolderByName(parentFolder);
        parentFolderId = folder?['id'];
      }
      final docs = await db.query(
        'documents',
        where: 'parent_folder ${parentFolderId == null ? 'IS NULL' : '= ?'}',
        whereArgs: parentFolderId != null ? [parentFolderId] : [],
        orderBy: 'order_index DESC',
        limit: 1,
      );
      if (docs.isNotEmpty) {
        maxOrder = (docs.first['order_index'] as int?) ?? 0;
      }

      final textBoxes = await db.query(
        'text_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId],
      );
      final imageBoxes = await db.query(
        'image_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId],
      );
      final audioBoxes = await db.query(
        'audio_boxes',
        where: 'document_id = ?',
        whereArgs: [templateId],
      );
      final templateCanvases = await db.query(
        'canvases',
        where: 'document_id = ?',
        whereArgs: [templateId],
      );
      final docSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [templateId],
      );

      String newDocId = const Uuid().v4();
      final Map<String, String> tplTextIdMap = {};
      final Map<String, String> tplImageIdMap = {};
      final Map<String, String> tplAudioIdMap = {};

      // 预复制背景图片（事务外）
      Map<String, dynamic>? newSettings;
      if (docSettings.isNotEmpty) {
        final settings = Map<String, dynamic>.from(docSettings.first);
        settings.remove('id');
        settings['document_id'] = newDocId;
        settings.remove('document_name');
        if (settings.containsKey('last_scroll_offset')) {
          settings['last_scroll_offset'] = 0.0;
        }
        newSettings = settings;
        String? originalBackgroundPath = settings['background_image_path'];
        if (originalBackgroundPath != null &&
            originalBackgroundPath.isNotEmpty) {
          try {
            final originalFile = File(originalBackgroundPath);
            if (await originalFile.exists()) {
              final appDir = await getApplicationDocumentsDirectory();
              final backgroundsDir = Directory(
                p.join(appDir.path, 'backgrounds'),
              );
              if (!await backgroundsDir.exists()) {
                await backgroundsDir.create(recursive: true);
              }
              final ext = p.extension(originalBackgroundPath);
              final newBackgroundPath = p.join(
                backgroundsDir.path,
                '${const Uuid().v4()}$ext',
              );
              await originalFile.copy(newBackgroundPath);
              settings['background_image_path'] = newBackgroundPath;
              Logger.log(
                '从模板复制背景图片: $originalBackgroundPath -> $newBackgroundPath',
              );
            } else {
              settings['background_image_path'] = null;
            }
          } catch (e) {
            Logger.log('复制模板背景图片时出错: $e');
            settings['background_image_path'] = null;
          }
        }
      }

      // 事务内执行所有 DB 写入
      await db.transaction((txn) async {
        await txn.insert('documents', {
          'id': newDocId,
          'name': finalNewDocumentName,
          'parent_folder': parentFolderId,
          'is_template': 0,
          'order_index': maxOrder + 1,
          'created_at': DateTime.now().millisecondsSinceEpoch,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        for (var textBox in textBoxes) {
          final oldId = textBox['id'].toString();
          final newTextBox = Map<String, dynamic>.from(textBox);
          newTextBox.remove('id');
          newTextBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newTextBox['id'] = newId;
          tplTextIdMap[oldId] = newId;
          await txn.insert('text_boxes', newTextBox);
        }
        for (var imageBox in imageBoxes) {
          final oldId = imageBox['id'].toString();
          final newImageBox = Map<String, dynamic>.from(imageBox);
          newImageBox.remove('id');
          newImageBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newImageBox['id'] = newId;
          tplImageIdMap[oldId] = newId;
          await txn.insert('image_boxes', newImageBox);
        }
        for (var audioBox in audioBoxes) {
          final oldId = audioBox['id'].toString();
          final newAudioBox = Map<String, dynamic>.from(audioBox);
          newAudioBox.remove('id');
          newAudioBox['document_id'] = newDocId;
          final newId = const Uuid().v4();
          newAudioBox['id'] = newId;
          tplAudioIdMap[oldId] = newId;
          await txn.insert('audio_boxes', newAudioBox);
        }

        String remap(String? csv, Map<String, String> m) {
          if (csv == null || csv.trim().isEmpty) return '';
          return csv
              .split(',')
              .map((id) => m[id.trim()] ?? '')
              .where((v) => v.isNotEmpty)
              .join(',');
        }

        for (var canvas in templateCanvases) {
          final newCanvas = Map<String, dynamic>.from(canvas);
          newCanvas['id'] = const Uuid().v4();
          newCanvas['document_id'] = newDocId;
          newCanvas['front_text_box_ids'] = remap(
            canvas['front_text_box_ids']?.toString(),
            tplTextIdMap,
          );
          newCanvas['back_text_box_ids'] = remap(
            canvas['back_text_box_ids']?.toString(),
            tplTextIdMap,
          );
          newCanvas['front_image_box_ids'] = remap(
            canvas['front_image_box_ids']?.toString(),
            tplImageIdMap,
          );
          newCanvas['back_image_box_ids'] = remap(
            canvas['back_image_box_ids']?.toString(),
            tplImageIdMap,
          );
          newCanvas['front_audio_box_ids'] = remap(
            canvas['front_audio_box_ids']?.toString(),
            tplAudioIdMap,
          );
          newCanvas['back_audio_box_ids'] = remap(
            canvas['back_audio_box_ids']?.toString(),
            tplAudioIdMap,
          );
          final now = DateTime.now().millisecondsSinceEpoch;
          newCanvas['created_at'] = now;
          newCanvas['updated_at'] = now;
          await txn.insert('canvases', newCanvas);
        }

        if (newSettings != null) {
          await txn.insert('document_settings', newSettings);
        }
      });

      Logger.log(
        'Successfully created document from template: $finalNewDocumentName',
      );
      return finalNewDocumentName;
    } catch (e, stackTrace) {
      _handleError('从模板创建文档时出错', e, stackTrace);
      Logger.log('从模板创建文档时出错: $e');
      rethrow;
    }
  }

  Future<void> importDirectoryDataImpl(String zipPath) async {
    try {
      Logger.log('开始导入目录数据...');
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String tempDirPath = '${appDocDir.path}/temp_import';
      Logger.log('临时目录路径: $tempDirPath');

      // 清理临时目录
      if (await Directory(tempDirPath).exists()) {
        await Directory(tempDirPath).delete(recursive: true);
      }
      await Directory(tempDirPath).create(recursive: true);

      // 用流式InputFileStream解压ZIP文件
      final inputStream = InputFileStream(zipPath);
      try {
        final archive = ZipDecoder().decodeStream(inputStream);
        for (var file in archive) {
          if (file.isFile) {
            final outPath = resolveSafeExtractPath(tempDirPath, file.name);
            await extractArchiveFileToPath(file, outPath);
          }
        }
      } finally {
        await inputStream.close();
      }

      // 读取目录数据
      final File dbDataFile = File('$tempDirPath/directory_data.json');
      if (!await dbDataFile.exists()) {
        throw Exception('备份中未找到目录数据文件');
      }

      final Map<String, dynamic> tableData = jsonDecode(
        await dbDataFile.readAsString(),
      );
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
          Logger.log('处理表: $tableName, 行数: ${rows.length}');

          if (tableName == 'directory_settings') {
            for (var row in rows) {
              Map<String, dynamic> settings = Map<String, dynamic>.from(row);
              String? fileName = settings.remove('backgroundImageFileName');
              if (fileName != null) {
                // 复制背景图片到新位置
                String newPath = p.join(backgroundImagesPath, fileName);
                String tempPath = p.join(
                  tempDirPath,
                  'background_images',
                  fileName,
                );
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  settings['background_image_path'] = newPath;
                  Logger.log('已导入目录背景图片: $newPath');
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
                String tempPath = p.join(
                  tempDirPath,
                  'background_images',
                  fileName,
                );
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  settings['background_image_path'] = newPath;
                  Logger.log('已导入文档背景图片: $newPath');
                }
              }
              await txn.insert(tableName, settings);
            }
          } else if (tableName == 'image_boxes') {
            for (var row in rows) {
              Map<String, dynamic> imageBox = Map<String, dynamic>.from(row);
              String? imageFileName = imageBox.remove('imageFileName');
              if (imageFileName != null) {
                String newPath = p.join(imagesDirPath, imageFileName);
                String tempPath = p.join(tempDirPath, 'images', imageFileName);
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  imageBox['image_path'] = newPath;
                  Logger.log('已导入图片框图片: $newPath');
                } else {
                  imageBox['image_path'] = null; // 导出时文件已缺失，导入时清空路径
                }
              }
              await txn.insert(tableName, imageBox);
            }
          } else if (tableName == 'audio_boxes') {
            Logger.log('[导入调试] 正在导入audio_boxes, 行数: ' + rows.length.toString());
            for (var row in rows) {
              Map<String, dynamic> audioBox = Map<String, dynamic>.from(row);
              String? audioFileName = audioBox.remove('audioFileName');
              Logger.log(
                '[导入调试] audioBox: ' +
                    audioBox.toString() +
                    ', audioFileName: ' +
                    (audioFileName ?? 'null'),
              );
              if (audioFileName != null) {
                String audiosDirPath = p.join(appDocDir.path, 'audios');
                await Directory(audiosDirPath).create(recursive: true);
                String newPath = p.join(audiosDirPath, audioFileName);
                String tempPath = p.join(tempDirPath, 'audios', audioFileName);
                Logger.log('[导入音频] audioFileName: $audioFileName');
                Logger.log('[导入音频] tempPath: $tempPath');
                Logger.log(
                  '[导入音频] tempPath文件是否存在: ${await File(tempPath).exists()}',
                );
                if (await File(tempPath).exists()) {
                  await File(tempPath).copy(newPath);
                  Logger.log('[导入音频] 已复制音频文件: $tempPath -> $newPath');
                  audioBox['audio_path'] = newPath;
                } else {
                  Logger.log('[导入音频] 警告：未找到音频文件: $tempPath');
                  audioBox['audio_path'] = null;
                }
              } else {
                Logger.log('[导入音频] audioFileName字段为null');
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
      final List<Map<String, dynamic>> audioBoxes = await db2.query(
        'audio_boxes',
      );
      for (final audioBox in audioBoxes) {
        String? audioPath = audioBox['audio_path'];
        if (audioPath != null && audioPath.isNotEmpty) {
          if (!await File(audioPath).exists()) {
            Logger.log('[导入后校验] 音频文件不存在，清空路径: $audioPath');
            await db2.update(
              'audio_boxes',
              {'audio_path': null},
              where: 'id = ?',
              whereArgs: [audioBox['id']],
            );
          } else {
            Logger.log('[导入后校验] 音频文件存在: $audioPath');
          }
        }
      }

      // 清理临时目录
      await Directory(tempDirPath).delete(recursive: true);

      Logger.log('目录数据导入完成');
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
  Future<Map<String, dynamic>?> getDirectorySettings([
    String? folderName,
  ]) async {
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
    String? videoPath,
    int? colorValue,
    int? isFreeSortMode,
    bool? clearImagePath, // 新增参数，明确指示是否要清除背景图片
    bool? clearVideoPath,

    /// 为 true 时同时写入图/视频路径（可为 null），用于生命周期保存当前内存状态。
    bool commitBackgroundPaths = false,
    BackgroundMediaOrigin? backgroundImageOrigin,
    BackgroundMediaOrigin? backgroundVideoOrigin,
  }) async {
    try {
      final db = await database;

      Map<String, dynamic> data = {
        'folder_name': folderName,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

      if (commitBackgroundPaths) {
        data['background_image_path'] = imagePath;
        data['background_video_path'] = videoPath;
        data['background_image_origin'] =
            imagePath == null ? null : backgroundImageOrigin?.dbValue;
        data['background_video_origin'] =
            videoPath == null ? null : backgroundVideoOrigin?.dbValue;
      } else {
        if (clearImagePath == true) {
          data['background_image_path'] = null;
          data['background_image_origin'] = null;
        } else if (imagePath != null) {
          data['background_image_path'] = imagePath;
          data['background_video_path'] = null;
          data['background_image_origin'] = backgroundImageOrigin?.dbValue;
          data['background_video_origin'] = null;
        }

        if (clearVideoPath == true) {
          data['background_video_path'] = null;
          data['background_video_origin'] = null;
        } else if (videoPath != null) {
          data['background_video_path'] = videoPath;
          data['background_image_path'] = null;
          data['background_video_origin'] = backgroundVideoOrigin?.dbValue;
          data['background_image_origin'] = null;
        }
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

  /// Delete directory background image（不影响背景视频）
  Future<void> deleteDirectoryBackgroundImage([String? folderName]) async {
    try {
      await insertOrUpdateDirectorySettings(
        folderName: folderName,
        clearImagePath: true,
      );
    } catch (e, stackTrace) {
      _handleError('删除目录背景图片失败', e, stackTrace);
      rethrow;
    }
  }

  /// Delete directory background video（不影响背景图片）
  Future<void> deleteDirectoryBackgroundVideo([String? folderName]) async {
    try {
      await insertOrUpdateDirectorySettings(
        folderName: folderName,
        clearVideoPath: true,
      );
    } catch (e, stackTrace) {
      _handleError('删除目录背景视频失败', e, stackTrace);
      rethrow;
    }
  }

  /// Insert document
  Future<void> insertDocument(
    String name, {
    String? parentFolder,
    String? position,
  }) async {
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
      await db.insert('documents', {
        'id': const Uuid().v4(),
        'name': name,
        'parent_folder': parentFolderId,
        'order_index': order,
        'is_template': 0,
        'position': position,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
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
  Future<void> insertFolder(
    String name, {
    String? parentFolder,
    String? position,
  }) async {
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
      await db.insert('folders', {
        'id': const Uuid().v4(),
        'name': name,
        'parent_folder': parentFolderId,
        'order_index': order,
        'position': position,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e, stackTrace) {
      _handleError('插入文件夹失败', e, stackTrace);
      rethrow;
    }
  }

  /// Get text boxes by document
  Future<List<Map<String, dynamic>>> getTextBoxesByDocument(
    String documentName,
  ) async {
    Logger.log('🔍 [DB] 开始查询文本框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'text_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      Logger.log('✅ [DB] 文本框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        Logger.log('📋 [DB] 第一条文本框数据字段: ${result.first.keys.toList()}');
        Logger.log('📋 [DB] 第一条文本框数据值: ${result.first}');
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
          convertedMap['isStrikeThrough'] = convertedMap.remove(
            'is_strike_through',
          );
        }
        if (convertedMap.containsKey('background_color')) {
          convertedMap['backgroundColor'] = convertedMap.remove(
            'background_color',
          );
        }
        if (convertedMap.containsKey('text_align')) {
          convertedMap['textAlign'] = convertedMap.remove('text_align');
        }
        // Map text_segments (DB) -> textSegments (UI List)
        if (convertedMap.containsKey('text_segments')) {
          try {
            final raw = convertedMap.remove('text_segments');
            convertedMap['textSegments'] =
                (raw == null || raw == '') ? [] : jsonDecode(raw as String);
          } catch (_) {
            convertedMap['textSegments'] = [];
          }
        }

        return convertedMap;
      }).toList();
    } catch (e, stackTrace) {
      Logger.log('❌ [DB] 获取文档文本框失败: $e');
      _handleError('获取文档文本框失败', e, stackTrace);
      return [];
    }
  }

  /// Get image boxes by document
  Future<List<Map<String, dynamic>>> getImageBoxesByDocument(
    String documentName,
  ) async {
    Logger.log('🔍 [DB] 开始查询图片框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'image_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      Logger.log('✅ [DB] 图片框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        Logger.log('📋 [DB] 第一条图片框数据字段: ${result.first.keys.toList()}');
        Logger.log('📋 [DB] 第一条图片框数据值: ${result.first}');
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
      Logger.log('❌ [DB] 获取文档图片框失败: $e');
      _handleError('获取文档图片框失败', e, stackTrace);
      return [];
    }
  }

  /// Get audio boxes by document
  Future<List<Map<String, dynamic>>> getAudioBoxesByDocument(
    String documentName,
  ) async {
    Logger.log('🔍 [DB] 开始查询音频框数据，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'audio_boxes',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      Logger.log('✅ [DB] 音频框查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        Logger.log('📋 [DB] 第一条音频框数据字段: ${result.first.keys.toList()}');
        Logger.log('📋 [DB] 第一条音频框数据值: ${result.first}');
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
      Logger.log('❌ [DB] 获取文档音频框失败: $e');
      _handleError('获取文档音频框失败', e, stackTrace);
      return [];
    }
  }

  /// 获取指定文档的画布列表
  Future<List<Map<String, dynamic>>> getCanvasesByDocument(
    String documentName,
  ) async {
    Logger.log('🔍 [DB] 开始查询画布数据，文档名: $documentName');
    try {
      final db = await database;
      final List<Map<String, dynamic>> result = await db.query(
        'canvases',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
        orderBy: 'created_at ASC',
      );
      Logger.log('✅ [DB] 画布查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        Logger.log('📋 [DB] 第一条画布数据字段: ${result.first.keys.toList()}');
        Logger.log('📋 [DB] 第一条画布数据值: ${result.first}');
      }
      return result;
    } catch (e, stackTrace) {
      Logger.log('❌ [DB] 获取画布失败: $e');
      _handleError('获取画布失败', e, stackTrace);
      return [];
    }
  }

  /// 保存画布列表（新增 / 更新 / 删除）
  Future<void> saveCanvases(
    List<Map<String, dynamic>> canvases,
    List<String> deletedCanvasIds,
    String documentName,
  ) async {
    Logger.log(
      '🔧 [DB] 开始保存画布，文档名: $documentName, 传入画布数: ${canvases.length}, 已删除数: ${deletedCanvasIds.length}',
    );
    final db = await database;
    await db.transaction((txn) async {
      // 获取文档ID
      final docRows = await txn.query(
        'documents',
        columns: ['id'],
        where: 'name = ?',
        whereArgs: [documentName],
      );
      if (docRows.isEmpty) {
        Logger.log('❌ [DB] 保存画布失败：文档不存在');
        return;
      }
      final documentId = docRows.first['id'];

      // 查询现有画布ID
      final existingRows = await txn.query(
        'canvases',
        columns: ['id'],
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final existingIds = existingRows.map((e) => e['id'] as String).toSet();
      final incomingIds = canvases.map((c) => c['id'] as String).toSet();
      final idsToDelete = existingIds
          .difference(incomingIds)
          .union(deletedCanvasIds.toSet());
      Logger.log(
        '🔧 [DB] existingIds=${existingIds.length}, incomingIds=${incomingIds.length}, idsToDelete=${idsToDelete.length}',
      );

      // 删除遗失或标记删除的画布
      for (final delId in idsToDelete) {
        final count = await txn.delete(
          'canvases',
          where: 'id = ?',
          whereArgs: [delId],
        );
        Logger.log('🗑️ [DB] 删除画布 id=$delId, affected=$count');
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final canvas in canvases) {
        final id = canvas['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final data = <String, dynamic>{
          'id': id,
          'document_id': documentId,
          'position_x':
              (canvas['position_x'] ?? canvas['positionX'] ?? 0.0).toDouble(),
          'position_y':
              (canvas['position_y'] ?? canvas['positionY'] ?? 0.0).toDouble(),
          'width': (canvas['width'] ?? 300.0).toDouble(),
          'height': (canvas['height'] ?? 200.0).toDouble(),
          'is_flipped':
              (canvas['is_flipped'] ?? canvas['isFlipped'] ?? 0) == 1 ? 1 : 0,
          'front_text_box_ids':
              canvas['front_text_box_ids'] ?? canvas['frontTextBoxIds'],
          'front_image_box_ids':
              canvas['front_image_box_ids'] ?? canvas['frontImageBoxIds'],
          'front_audio_box_ids':
              canvas['front_audio_box_ids'] ?? canvas['frontAudioBoxIds'],
          'back_text_box_ids':
              canvas['back_text_box_ids'] ?? canvas['backTextBoxIds'],
          'back_image_box_ids':
              canvas['back_image_box_ids'] ?? canvas['backImageBoxIds'],
          'back_audio_box_ids':
              canvas['back_audio_box_ids'] ?? canvas['backAudioBoxIds'],
          'updated_at': now,
        };
        if (!existingIds.contains(id)) {
          data['created_at'] = now;
          await txn.insert(
            'canvases',
            data,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          Logger.log('➕ [DB] 新增画布 id=$id');
        } else {
          await txn.update('canvases', data, where: 'id = ?', whereArgs: [id]);
          Logger.log('✏️ [DB] 更新画布 id=$id');
        }
      }

      final total =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM canvases WHERE document_id = ?',
              [documentId],
            ),
          ) ??
          0;
      Logger.log('📊 [DB] 保存完成，当前文档画布总数: $total');
    });
  }

  /// 根据ID删除单个画布
  Future<void> deleteCanvasById(String canvasId) async {
    final db = await database;
    final count = await db.delete(
      'canvases',
      where: 'id = ?',
      whereArgs: [canvasId],
    );
    if (kDebugMode) {
      Logger.log('🗑️ [DB] deleteCanvasById id=$canvasId affected=$count');
    }
  }

  /// Set document as template
  Future<void> setDocumentAsTemplate(
    String documentName,
    bool isTemplate,
  ) async {
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
  Future<void> saveTextBoxes(
    List<Map<String, dynamic>> textBoxes,
    String documentName,
  ) async {
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

        final existingIds =
            existingBoxes.map((box) => box['id'] as String).toSet();
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
  Future<void> saveImageBoxes(
    List<Map<String, dynamic>> imageBoxes,
    String documentName,
  ) async {
    try {
      final db = await database;
      final appDocDir = (await getApplicationDocumentsDirectory()).path;
      final deletedPaths = <String>[];

      String toAbsolute(String? pathStr) {
        if (pathStr == null || pathStr.isEmpty) return '';
        final s = pathStr.trim();
        if (s.isEmpty) return '';
        final abs =
            s.startsWith('/') || (s.length > 1 && s[1] == ':')
                ? s
                : p.join(appDocDir, s);
        return p.normalize(p.absolute(abs));
      }

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

        final existingIds =
            existingBoxes.map((box) => box['id'] as String).toSet();
        final newIds = imageBoxes.map((box) => box['id'] as String).toSet();

        // Delete removed image boxes（同时删除物理文件以释放空间）
        final idsToDelete = existingIds.difference(newIds);
        for (final id in idsToDelete) {
          final box = existingBoxes.firstWhere(
            (b) => b['id'] == id,
            orElse: () => <String, dynamic>{},
          );
          final path = box['image_path'] ?? box['imagePath'] ?? '';
          final abs = toAbsolute(path.toString());
          if (abs.isNotEmpty) deletedPaths.add(abs);
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

      if (deletedPaths.isNotEmpty) {
        try {
          final fcs = getService<FileCleanupService>();
          if (fcs.isInitialized) {
            for (final filePath in deletedPaths) {
              try {
                await fcs.deleteMediaFileCompletely(filePath);
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    } catch (e, stackTrace) {
      _handleError('保存图片框失败', e, stackTrace);
      rethrow;
    }
  }

  /// Save audio boxes
  Future<void> saveAudioBoxes(
    List<Map<String, dynamic>> audioBoxes,
    String documentName,
  ) async {
    try {
      final db = await database;
      final appDocDir = (await getApplicationDocumentsDirectory()).path;
      final deletedPaths = <String>[];

      String toAbsolute(String? pathStr) {
        if (pathStr == null || pathStr.isEmpty) return '';
        final s = pathStr.trim();
        if (s.isEmpty) return '';
        final abs =
            s.startsWith('/') || (s.length > 1 && s[1] == ':')
                ? s
                : p.join(appDocDir, s);
        return p.normalize(p.absolute(abs));
      }

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

        final existingIds =
            existingBoxes.map((box) => box['id'] as String).toSet();
        final newIds = audioBoxes.map((box) => box['id'] as String).toSet();

        // Delete removed audio boxes（同时删除物理文件以释放空间）
        final idsToDelete = existingIds.difference(newIds);
        for (final id in idsToDelete) {
          final box = existingBoxes.firstWhere(
            (b) => b['id'] == id,
            orElse: () => <String, dynamic>{},
          );
          final path = box['audio_path'] ?? box['audioPath'] ?? '';
          final abs = toAbsolute(path.toString());
          if (abs.isNotEmpty) deletedPaths.add(abs);
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

      if (deletedPaths.isNotEmpty) {
        try {
          final fcs = getService<FileCleanupService>();
          if (fcs.isInitialized) {
            for (final filePath in deletedPaths) {
              try {
                await fcs.deleteMediaFileCompletely(filePath);
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    } catch (e, stackTrace) {
      _handleError('保存音频框失败', e, stackTrace);
      rethrow;
    }
  }

  /// Get document settings
  Future<Map<String, dynamic>?> getDocumentSettings(String documentName) async {
    Logger.log('🔍 [DB] 开始查询文档设置，文档名: $documentName');
    try {
      final db = await database;
      List<Map<String, dynamic>> result = await db.query(
        'document_settings',
        where: 'document_id = (SELECT id FROM documents WHERE name = ?)',
        whereArgs: [documentName],
      );
      Logger.log('✅ [DB] 文档设置查询成功，返回 ${result.length} 条记录');
      if (result.isNotEmpty) {
        Logger.log('📋 [DB] 文档设置数据字段: ${result.first.keys.toList()}');
        Logger.log('📋 [DB] 文档设置数据值: ${result.first}');
        return result.first;
      }
      Logger.log('ℹ️ [DB] 未找到文档设置数据');
      return null;
    } catch (e, stackTrace) {
      Logger.log('❌ [DB] 获取文档设置失败: $e');
      _handleError('获取文档设置失败', e, stackTrace);
      return null;
    }
  }

  /// Insert or update document settings
  Future<void> insertOrUpdateDocumentSettings(
    String documentName, {
    String? imagePath,
    String? videoPath,
    int? colorValue,
    bool? textEnhanceMode,
    bool? positionLocked,
    double? lastScrollOffset,

    /// 为 true 时按传入的 [imagePath]/[videoPath]（可为 null）整体写入背景媒体，用于生命周期保存。
    bool commitBackgroundMedia = false,
    BackgroundMediaOrigin? backgroundImageOrigin,
    BackgroundMediaOrigin? backgroundVideoOrigin,
  }) async {
    try {
      Logger.log('🔧 [DB] 开始插入或更新文档设置，文档名: $documentName');
      Logger.log(
        '🔧 [DB] 传入参数 - imagePath: $imagePath, videoPath: $videoPath, colorValue: $colorValue, textEnhanceMode: $textEnhanceMode, positionLocked: $positionLocked',
      );

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
      Logger.log('🔧 [DB] 找到文档ID: $documentId');

      // Check if settings exist
      List<Map<String, dynamic>> existingSettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );

      Logger.log('🔧 [DB] 现有设置数量: ${existingSettings.length}');
      if (existingSettings.isNotEmpty) {
        Logger.log('🔧 [DB] 现有设置: ${existingSettings.first}');
      }

      Map<String, dynamic> settingsData = {
        'document_id': documentId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      };

      if (existingSettings.isNotEmpty) {
        var existing = existingSettings.first;
        int? imgOrig = existing['background_image_origin'] as int?;
        int? vidOrig = existing['background_video_origin'] as int?;
        if (commitBackgroundMedia) {
          settingsData['background_image_path'] = imagePath;
          settingsData['background_video_path'] = videoPath;
          imgOrig =
              imagePath == null
                  ? null
                  : (backgroundImageOrigin?.dbValue ?? imgOrig);
          vidOrig =
              videoPath == null
                  ? null
                  : (backgroundVideoOrigin?.dbValue ?? vidOrig);
        } else {
          String? nextImg = existing['background_image_path'] as String?;
          String? nextVid = existing['background_video_path'] as String?;
          if (imagePath != null) {
            nextImg = imagePath;
            nextVid = null;
            imgOrig = backgroundImageOrigin?.dbValue ?? imgOrig;
            vidOrig = null;
          } else if (videoPath != null) {
            nextVid = videoPath;
            nextImg = null;
            vidOrig = backgroundVideoOrigin?.dbValue ?? vidOrig;
            imgOrig = null;
          }
          settingsData['background_image_path'] = nextImg;
          settingsData['background_video_path'] = nextVid;
        }
        settingsData['background_image_origin'] = imgOrig;
        settingsData['background_video_origin'] = vidOrig;
        settingsData['background_color'] =
            colorValue ?? existing['background_color'];
        settingsData['text_enhance_mode'] =
            textEnhanceMode != null
                ? (textEnhanceMode ? 1 : 0)
                : existing['text_enhance_mode'];
        settingsData['position_locked'] =
            positionLocked != null
                ? (positionLocked ? 1 : 0)
                : existing['position_locked'];
        settingsData['last_scroll_offset'] =
            lastScrollOffset ?? existing['last_scroll_offset'] ?? 0.0;
        // 保留原有的created_at字段
        settingsData['created_at'] = existing['created_at'];
        Logger.log(
          '🔧 [DB] 更新现有设置 - text_enhance_mode: ${settingsData['text_enhance_mode']}, position_locked: ${settingsData['position_locked']}',
        );
      } else {
        int? imgOrig;
        int? vidOrig;
        if (commitBackgroundMedia) {
          settingsData['background_image_path'] = imagePath;
          settingsData['background_video_path'] = videoPath;
          imgOrig = imagePath == null ? null : backgroundImageOrigin?.dbValue;
          vidOrig = videoPath == null ? null : backgroundVideoOrigin?.dbValue;
        } else if (imagePath != null) {
          settingsData['background_image_path'] = imagePath;
          settingsData['background_video_path'] = null;
          imgOrig = backgroundImageOrigin?.dbValue;
          vidOrig = null;
        } else if (videoPath != null) {
          settingsData['background_video_path'] = videoPath;
          settingsData['background_image_path'] = null;
          vidOrig = backgroundVideoOrigin?.dbValue;
          imgOrig = null;
        } else {
          settingsData['background_image_path'] = null;
          settingsData['background_video_path'] = null;
          imgOrig = null;
          vidOrig = null;
        }
        settingsData['background_image_origin'] = imgOrig;
        settingsData['background_video_origin'] = vidOrig;
        settingsData['background_color'] = colorValue;
        settingsData['text_enhance_mode'] =
            textEnhanceMode != null ? (textEnhanceMode ? 1 : 0) : 1;
        settingsData['position_locked'] =
            positionLocked != null ? (positionLocked ? 1 : 0) : 1;
        settingsData['last_scroll_offset'] = lastScrollOffset ?? 0.0;
        settingsData['created_at'] = DateTime.now().millisecondsSinceEpoch;
        Logger.log(
          '🔧 [DB] 创建新设置 - text_enhance_mode: ${settingsData['text_enhance_mode']}, position_locked: ${settingsData['position_locked']}',
        );
      }

      Logger.log('🔧 [DB] 最终写入数据: $settingsData');

      if (existingSettings.isNotEmpty) {
        // 使用UPDATE操作更新现有记录
        await db.update(
          'document_settings',
          settingsData,
          where: 'document_id = ?',
          whereArgs: [documentId],
        );
        Logger.log('🔧 [DB] UPDATE操作完成');
      } else {
        // 使用INSERT操作创建新记录
        await db.insert('document_settings', settingsData);
        Logger.log('🔧 [DB] INSERT操作完成');
      }

      Logger.log('🔧 [DB] 数据库写入完成');

      // 验证写入结果
      List<Map<String, dynamic>> verifySettings = await db.query(
        'document_settings',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      if (verifySettings.isNotEmpty) {
        Logger.log('🔧 [DB] 验证写入结果: ${verifySettings.first}');
      }
    } catch (e, stackTrace) {
      Logger.log('❌ [DB] 插入或更新文档设置失败: $e');
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
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';",
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        Logger.log('在insertCoverImage中创建了cover_image表');
      }

      // Delete existing records and insert new one
      await db.delete('cover_image');
      await db.insert('cover_image', {
        'path': imagePath,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      Logger.log('成功插入封面图片路径: $imagePath');
    } catch (e, stackTrace) {
      _handleError('插入封面图片路径失败', e, stackTrace);
      Logger.log('插入封面图片路径时出错: $e');
      rethrow;
    }
  }

  /// Get cover image
  Future<List<Map<String, dynamic>>> getCoverImage() async {
    try {
      final db = await database;

      // Ensure cover_image table exists
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';",
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        Logger.log('在getCoverImage中创建了cover_image表');
        return [];
      }

      return await db.query('cover_image', orderBy: 'id DESC', limit: 1);
    } catch (e, stackTrace) {
      _handleError('获取封面图片失败', e, stackTrace);
      Logger.log('获取封面图片时出错: $e');
      return [];
    }
  }

  /// Delete cover image
  Future<void> deleteCoverImage() async {
    try {
      final db = await database;

      // Ensure cover_image table exists
      List<Map<String, dynamic>> tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_image';",
      );

      if (tables.isEmpty) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS cover_image (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT,
            timestamp INTEGER
          )
        ''');
        Logger.log('在deleteCoverImage中创建了cover_image表');
        return;
      }

      await db.delete('cover_image');
      Logger.log('成功删除所有封面图片记录');
    } catch (e, stackTrace) {
      _handleError('删除封面图片失败', e, stackTrace);
      Logger.log('删除封面图片时出错: $e');
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

  /// 获取数据库中所有有效引用的文件路径（用于清理孤立文件、媒体整库导入时保留非包内文件）。
  ///
  /// 须覆盖：媒体库与缩略图、[image_boxes]/[audio_boxes]、文档/目录/日记/封面背景、
  /// [background_file_view_params]、日记条目内嵌媒体路径。应用仅将 `documents/`、`folders/`
  /// 用作删除文档/文件夹后的整目录清理目标，正常引用不会指向这两处，故孤立扫描可安全清理其中的残留文件。
  Future<Set<String>> getAllValidFilePaths() async {
    final db = await database;
    final appDocDir = (await getApplicationDocumentsDirectory()).path;
    final validPaths = <String>{};

    String toAbsolute(String? pathStr) {
      if (pathStr == null || pathStr.isEmpty) return '';
      final s = pathStr.trim();
      if (s.isEmpty) return '';
      final abs =
          s.startsWith('/') || (s.length > 1 && s[1] == ':')
              ? s
              : p.join(appDocDir, s);
      return p.normalize(p.absolute(abs));
    }

    try {
      final mediaItems = await db.query(
        'media_items',
        columns: ['path', 'thumbnail_path'],
      );
      for (final row in mediaItems) {
        final path = row['path']?.toString();
        if (path != null && path.isNotEmpty) validPaths.add(toAbsolute(path));
        final thumb = row['thumbnail_path']?.toString();
        if (thumb != null && thumb.isNotEmpty)
          validPaths.add(toAbsolute(thumb));
      }

      final imageBoxes = await db.query('image_boxes', columns: ['image_path']);
      for (final row in imageBoxes) {
        final path = row['image_path']?.toString();
        if (path != null && path.isNotEmpty) validPaths.add(toAbsolute(path));
      }

      final audioBoxes = await db.query('audio_boxes', columns: ['audio_path']);
      for (final row in audioBoxes) {
        final path = row['audio_path']?.toString();
        if (path != null && path.isNotEmpty) validPaths.add(toAbsolute(path));
      }

      final docSettings = await db.query(
        'document_settings',
        columns: ['background_image_path', 'background_video_path'],
      );
      for (final row in docSettings) {
        for (final key in ['background_image_path', 'background_video_path']) {
          final path = row[key]?.toString();
          if (path != null && path.isNotEmpty) validPaths.add(toAbsolute(path));
        }
      }

      final coverImages = await db.query('cover_image', columns: ['path']);
      for (final row in coverImages) {
        final path = row['path']?.toString();
        if (path != null && path.isNotEmpty) validPaths.add(toAbsolute(path));
      }

      final coverSettings = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings'",
      );
      if (coverSettings.isNotEmpty) {
        final rows = await db.query(
          'cover_settings',
          columns: ['background_image_path', 'background_video_path'],
        );
        for (final row in rows) {
          for (final key in [
            'background_image_path',
            'background_video_path',
          ]) {
            final path = row[key]?.toString();
            if (path != null && path.isNotEmpty)
              validPaths.add(toAbsolute(path));
          }
        }
      }

      final diarySettings = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='diary_settings'",
      );
      if (diarySettings.isNotEmpty) {
        final rows = await db.query(
          'diary_settings',
          columns: ['background_image_path', 'background_video_path'],
        );
        for (final row in rows) {
          for (final key in [
            'background_image_path',
            'background_video_path',
          ]) {
            final path = row[key]?.toString();
            if (path != null && path.isNotEmpty)
              validPaths.add(toAbsolute(path));
          }
        }
      }

      // 目录界面的背景图片
      final dirSettings = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='directory_settings'",
      );
      if (dirSettings.isNotEmpty) {
        final rows = await db.query(
          'directory_settings',
          columns: ['background_image_path', 'background_video_path'],
        );
        for (final row in rows) {
          for (final key in [
            'background_image_path',
            'background_video_path',
          ]) {
            final path = row[key]?.toString();
            if (path != null && path.isNotEmpty)
              validPaths.add(toAbsolute(path));
          }
        }
      }

      // 背景图/视频取景参数表：主键与路径变体均可能指向磁盘文件，须纳入有效集以免孤立清理误删。
      final bgViewParams = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='background_file_view_params'",
      );
      if (bgViewParams.isNotEmpty) {
        final rows = await db.query(
          'background_file_view_params',
          columns: ['path', 'normalized_path', 'slash_path'],
        );
        for (final row in rows) {
          for (final key in ['path', 'normalized_path', 'slash_path']) {
            final pathStr = row[key]?.toString();
            if (pathStr != null && pathStr.isNotEmpty) {
              validPaths.add(toAbsolute(pathStr));
            }
          }
        }
      }

      final diaryEntries = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='diary_entries'",
      );
      if (diaryEntries.isNotEmpty) {
        final rows = await db.query(
          'diary_entries',
          columns: ['image_paths', 'audio_paths', 'video_paths'],
        );
        for (final row in rows) {
          for (final key in ['image_paths', 'audio_paths', 'video_paths']) {
            final val = row[key];
            if (val == null) continue;
            try {
              final list = jsonDecode(val.toString()) as List?;
              if (list != null)
                for (final p in list) validPaths.add(toAbsolute(p.toString()));
            } catch (_) {}
          }
        }
      }

      validPaths.remove('');
      return validPaths;
    } catch (e) {
      if (kDebugMode) Logger.log('getAllValidFilePaths 失败: $e');
      return {};
    }
  }

  /// 将仍位于「媒体库」目录 [kMediaLibraryDirName] 下的日记引用（含图片/视频/音频路径及日记背景若落在该目录）复制到 [kDiaryOwnedMediaDirName]。
  /// 与媒体库整目录替换解耦；应用内录音目录 `audio/` 不受此迁移影响。仅执行一次（SharedPreferences `diary_media_isolation_v1_done`）。
  Future<void> migrateDiaryMediaOutOfLibraryFolderIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('diary_media_isolation_v1_done') == true) return;

      final appDoc = await getApplicationDocumentsDirectory();
      final appDocPath = appDoc.path;
      final mediaLibRoot = p.join(appDocPath, kMediaLibraryDirName);
      final diaryDir = await ensureDiaryMediaDirectory();

      String toAbs(String? s) {
        if (s == null) return '';
        final t = s.trim();
        if (t.isEmpty) return '';
        if (t.startsWith('/') || (t.length > 1 && t[1] == ':')) {
          return p.normalize(p.absolute(t));
        }
        return p.normalize(p.join(appDocPath, t));
      }

      Future<String?> copyOneToDiary(String srcAbs) async {
        final src = File(srcAbs);
        if (!await src.exists()) return null;
        final ext = p.extension(srcAbs);
        final dest = File(p.join(diaryDir.path, '${const Uuid().v4()}$ext'));
        await copyFileWithStreamingToFile(src, dest);
        return dest.path;
      }

      Future<List<String>> migratePathList(List<String> raw) async {
        final out = <String>[];
        for (final item in raw) {
          final abs = toAbs(item);
          if (abs.isEmpty) {
            out.add(item);
            continue;
          }
          if (isPathUnderDirectory(abs, mediaLibRoot)) {
            final n = await copyOneToDiary(abs);
            if (n != null) {
              out.add(n);
            } else {
              out.add(item);
            }
          } else {
            out.add(item);
          }
        }
        return out;
      }

      List<String> decodeList(dynamic val) {
        if (val == null) return [];
        if (val is String) {
          try {
            final list = jsonDecode(val) as List?;
            return list?.map((e) => e.toString()).toList() ?? [];
          } catch (_) {
            return [];
          }
        }
        if (val is List) return val.map((e) => e.toString()).toList();
        return [];
      }

      final db = await database;
      final rows = await db.query('diary_entries');
      for (final row in rows) {
        final id = row['id'] as String;
        final images = decodeList(row['image_paths']);
        final videos = decodeList(row['video_paths']);
        final audios = decodeList(row['audio_paths']);
        final newImages = await migratePathList(images);
        final newVideos = await migratePathList(videos);
        final newAudios = await migratePathList(audios);
        final changed =
            jsonEncode(images) != jsonEncode(newImages) ||
            jsonEncode(videos) != jsonEncode(newVideos) ||
            jsonEncode(audios) != jsonEncode(newAudios);
        if (changed) {
          await db.update(
            'diary_entries',
            {
              'image_paths': jsonEncode(newImages),
              'video_paths': jsonEncode(newVideos),
              'audio_paths': jsonEncode(newAudios),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      }

      final dsRows = await db.query('diary_settings');
      if (dsRows.isNotEmpty) {
        final first = dsRows.first;
        final bg = first['background_image_path']?.toString();
        if (bg != null && bg.isNotEmpty) {
          final abs = toAbs(bg);
          if (isPathUnderDirectory(abs, mediaLibRoot)) {
            final n = await copyOneToDiary(abs);
            if (n != null) {
              final now = DateTime.now().millisecondsSinceEpoch;
              await db.update(
                'diary_settings',
                {'background_image_path': n, 'updated_at': now},
                where: 'id = ?',
                whereArgs: [first['id']],
              );
            }
          }
        }
      }

      await prefs.setBool('diary_media_isolation_v1_done', true);
      if (kDebugMode) {
        Logger.log('日记媒体已迁移到 $kDiaryOwnedMediaDirName，与媒体库目录隔离');
      }
    } catch (e, stack) {
      if (kDebugMode) {
        Logger.log(
          'migrateDiaryMediaOutOfLibraryFolderIfNeeded 失败: $e\n$stack',
        );
      }
    }
  }

  /// 按当前 `media_items` 表结构创建同构空表（含主键）。
  ///
  /// 导入用临时表若手写 CREATE 会落后于迁移新增列（如 `sort_order`），
  /// 导致 INSERT 报 no column named ...。从 PRAGMA 派生可避免再次漂移。
  Future<void> _createMediaItemsSchemaClone(
    DatabaseExecutor db,
    String tableName,
  ) async {
    await _ensureMediaItemsKenBurnsColumns(db);
    await _ensureMediaItemsVideoViewColumns(db);
    await _ensureMediaItemsRecycleColumns(db);
    await _ensureMediaItemsInsertColumns(db);

    final info = await db.rawQuery('PRAGMA table_info(media_items)');
    if (info.isEmpty) {
      throw StateError('media_items 表不存在，无法创建 $tableName');
    }

    final columnDefs = <String>[];
    final pkOrdered = <MapEntry<int, String>>[];
    for (final col in info) {
      final name = col['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final type = (col['type']?.toString() ?? '').trim();
      final notNull = (col['notnull'] as int?) == 1;
      final dflt = col['dflt_value'];
      final pk = (col['pk'] as int?) ?? 0;

      final parts = <String>[name];
      if (type.isNotEmpty) parts.add(type);
      if (notNull) parts.add('NOT NULL');
      if (dflt != null) parts.add('DEFAULT $dflt');
      columnDefs.add(parts.join(' '));
      if (pk > 0) pkOrdered.add(MapEntry(pk, name));
    }

    pkOrdered.sort((a, b) => a.key.compareTo(b.key));
    final pkNames = pkOrdered.map((e) => e.value).toList();
    final pkSql =
        pkNames.isEmpty ? '' : ', PRIMARY KEY (${pkNames.join(', ')})';

    await db.execute(
      'CREATE TABLE $tableName (${columnDefs.join(', ')}$pkSql)',
    );
  }

  /// 替换所有媒体项（分块读取，不一次性加载）- 用于大容量导入
  Future<void> replaceAllMediaItemsFromChunks(
    Future<List<dynamic>?> Function() getNextChunk,
  ) async {
    final db = await database;
    const tempTable = 'media_items_temp';
    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS $tempTable');
      await _createMediaItemsSchemaClone(txn, tempTable);
      final columnInfo = await txn.rawQuery('PRAGMA table_info($tempTable)');
      final allowedColumns = columnInfo
          .map((c) => c['name']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toSet();
      List<dynamic>? chunk;
      while (true) {
        chunk = await getNextChunk();
        if (chunk == null || chunk.isEmpty) break;
        final batch = txn.batch();
        for (var item in chunk) {
          final row = Map<String, dynamic>.from(item)
            ..removeWhere((key, _) => !allowedColumns.contains(key));
          batch.insert(
            tempTable,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
      await txn.execute('DROP TABLE IF EXISTS media_items');
      await txn.execute('ALTER TABLE $tempTable RENAME TO media_items');
      await _ensureMediaItemsIndexes(txn);
    });
  }

  /// 替换所有媒体项（清空并批量插入）- 使用临时表保证事务安全
  Future<void> replaceAllMediaItems(List<dynamic> items) async {
    final db = await database;
    const tempTable = 'media_items_temp';

    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS $tempTable');
      await _createMediaItemsSchemaClone(txn, tempTable);
      final columnInfo = await txn.rawQuery('PRAGMA table_info($tempTable)');
      final allowedColumns = columnInfo
          .map((c) => c['name']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toSet();

      final batch = txn.batch();
      for (var item in items) {
        final row = Map<String, dynamic>.from(item)
          ..removeWhere((key, _) => !allowedColumns.contains(key));
        batch.insert(
          tempTable,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);

      await txn.execute('DROP TABLE IF EXISTS media_items');
      await txn.execute('ALTER TABLE $tempTable RENAME TO media_items');
      await _ensureMediaItemsIndexes(txn);
    });
  }

  /// 替换所有日记条目（分块读取，不一次性加载）- 用于大容量导入，避免 OOM
  Future<void> replaceAllDiaryEntriesFromChunks(
    Future<List<DiaryEntry>?> Function() getNextChunk,
  ) async {
    final db = await database;
    const tempTable = 'diary_entries_temp';
    await db.transaction((txn) async {
      await txn.execute('DROP TABLE IF EXISTS $tempTable');
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
      List<DiaryEntry>? chunk;
      while (true) {
        chunk = await getNextChunk();
        if (chunk == null || chunk.isEmpty) break;
        final batch = txn.batch();
        for (var entry in chunk) {
          batch.insert(
            tempTable,
            entry.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
      await txn.execute('DROP TABLE IF EXISTS diary_entries');
      await txn.execute('ALTER TABLE $tempTable RENAME TO diary_entries');
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
        batch.insert(
          tempTable,
          entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
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
  Future<void> insertOrUpdateDiarySettings({
    String? imagePath,
    String? videoPath,
    int? colorValue,
    BackgroundMediaOrigin? backgroundImageOrigin,
    BackgroundMediaOrigin? backgroundVideoOrigin,
  }) async {
    try {
      final db = await database;
      final existing = await db.query('diary_settings');

      String? nextImg;
      String? nextVid;
      int? nextImgOrig;
      int? nextVidOrig;
      if (existing.isNotEmpty) {
        nextImg = existing.first['background_image_path'] as String?;
        nextVid = existing.first['background_video_path'] as String?;
        nextImgOrig = existing.first['background_image_origin'] as int?;
        nextVidOrig = existing.first['background_video_origin'] as int?;
      }
      if (imagePath != null) {
        nextImg = imagePath;
        nextVid = null;
        nextImgOrig = backgroundImageOrigin?.dbValue ?? nextImgOrig;
        nextVidOrig = null;
      } else if (videoPath != null) {
        nextVid = videoPath;
        nextImg = null;
        nextVidOrig = backgroundVideoOrigin?.dbValue ?? nextVidOrig;
        nextImgOrig = null;
      }

      Map<String, dynamic> data = {
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'background_image_path': nextImg,
        'background_video_path': nextVid,
        'background_image_origin': nextImgOrig,
        'background_video_origin': nextVidOrig,
      };
      if (colorValue != null) {
        data['background_color'] = colorValue;
      }
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

  /// 删除日记本背景图片（不影响背景视频）
  Future<void> deleteDiaryBackgroundImage() async {
    try {
      final db = await database;
      await db.update('diary_settings', {
        'background_image_path': null,
        'background_image_origin': null,
      });
    } catch (e, stackTrace) {
      _handleError('删除日记本背景图片失败', e, stackTrace);
      rethrow;
    }
  }

  /// 删除日记本背景视频（不影响背景图片）
  Future<void> deleteDiaryBackgroundVideo() async {
    try {
      final db = await database;
      await db.update('diary_settings', {
        'background_video_path': null,
        'background_video_origin': null,
      });
    } catch (e, stackTrace) {
      _handleError('删除日记本背景视频失败', e, stackTrace);
      rethrow;
    }
  }

  /// 清空日记背景图/视频（留白），保留已保存的 [background_color]；并按来源规则尝试删除拍照产生的本地副本。
  Future<void> clearDiaryBackgroundToBlank() async {
    final appDir = (await getApplicationDocumentsDirectory()).path;
    final db = await database;
    final existing = await db.query('diary_settings');
    if (existing.isEmpty) return;
    final s = existing.first;
    final img = s['background_image_path'] as String?;
    final vid = s['background_video_path'] as String?;
    final io = BackgroundMediaOrigin.fromDbValue(
      s['background_image_origin'] as int?,
    );
    final vo = BackgroundMediaOrigin.fromDbValue(
      s['background_video_origin'] as int?,
    );
    await deleteBackgroundPhysicalFileIfAllowed(img, io, appDir);
    await deleteBackgroundPhysicalFileIfAllowed(vid, vo, appDir);
    await db.update('diary_settings', {
      'background_image_path': null,
      'background_video_path': null,
      'background_image_origin': null,
      'background_video_origin': null,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 清空目录背景图/视频（留白），保留已保存的 [background_color]；并按来源规则尝试删除拍照产生的本地副本。
  Future<void> clearDirectoryBackgroundToBlank([String? folderName]) async {
    final appDir = (await getApplicationDocumentsDirectory()).path;
    final s = await getDirectorySettings(folderName);
    if (s == null) return;
    final img = s['background_image_path'] as String?;
    final vid = s['background_video_path'] as String?;
    final io = BackgroundMediaOrigin.fromDbValue(
      s['background_image_origin'] as int?,
    );
    final vo = BackgroundMediaOrigin.fromDbValue(
      s['background_video_origin'] as int?,
    );
    await deleteBackgroundPhysicalFileIfAllowed(img, io, appDir);
    await deleteBackgroundPhysicalFileIfAllowed(vid, vo, appDir);
    final db = await database;
    final payload = <String, dynamic>{
      'background_image_path': null,
      'background_video_path': null,
      'background_image_origin': null,
      'background_video_origin': null,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (folderName != null) {
      await db.update(
        'directory_settings',
        payload,
        where: 'folder_name = ?',
        whereArgs: [folderName],
      );
    } else {
      await db.update(
        'directory_settings',
        payload,
        where: 'folder_name IS NULL',
      );
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
      'mediaItemCount': 0,
      'diaryEntryCount': 0,
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

      // 检查媒体项数据完整性
      try {
        final mediaItems = await db.query('media_items');
        report['mediaItemCount'] = mediaItems.length;
        const systemDirs = ['root', 'recycle_bin', 'favorites'];
        final folderIds =
            (await db.query(
              'media_items',
              columns: ['id'],
              where: 'type = ?',
              whereArgs: [3],
            )).map((r) => r['id'] as String).toSet();
        for (var item in mediaItems) {
          final dir = item['directory']?.toString();
          if (dir != null &&
              dir.isNotEmpty &&
              !systemDirs.contains(dir) &&
              !folderIds.contains(dir)) {
            report['isValid'] = false;
            report['issues'].add('媒体项 ${item['name']} 的父目录引用无效: $dir');
          }
          final typeIndex = item['type'] as int? ?? 0;
          if (typeIndex != 3 &&
              (item['path'] == null || item['path'].toString().isEmpty)) {
            report['isValid'] = false;
            report['issues'].add('媒体项 ${item['name']} 缺少有效路径');
          }
        }
      } catch (e) {
        report['issues'].add('媒体项检查异常: $e');
      }

      // 检查日记条目数据完整性
      try {
        final diaryTable = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='diary_entries'",
        );
        if (diaryTable.isNotEmpty) {
          final diaryEntries = await db.query('diary_entries');
          report['diaryEntryCount'] = diaryEntries.length;
          for (var entry in diaryEntries) {
            if (entry['id'] == null || entry['id'].toString().isEmpty) {
              report['isValid'] = false;
              report['issues'].add('发现无效日记条目 ID');
            }
            if (entry['date'] == null || entry['date'].toString().isEmpty) {
              report['isValid'] = false;
              report['issues'].add('日记条目 ${entry['id']} 缺少日期');
            }
          }
        }
      } catch (e) {
        report['issues'].add('日记条目检查异常: $e');
      }

      if (kDebugMode) {
        Logger.log('数据完整性检查完成: ${report['isValid'] ? '通过' : '发现问题'}');
        if (report['issues'].isNotEmpty) {
          Logger.log('发现的问题:');
          for (var issue in report['issues']) {
            Logger.log('  - $issue');
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

  Future<String> sqliteIntegrityCheck({bool quick = true}) async {
    final db = await database;
    final pragma = quick ? 'quick_check' : 'integrity_check';
    final rows = await db.rawQuery('PRAGMA $pragma;');
    if (rows.isEmpty) return '';
    final values = <String>[];
    for (final r in rows) {
      if (r.isEmpty) continue;
      final v = r.values.first;
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) values.add(s);
    }
    return values.join('\n');
  }

  Future<int> sqliteForeignKeyViolationCount() async {
    final db = await database;
    final rows = await db.rawQuery('PRAGMA foreign_key_check;');
    return rows.length;
  }

  Future<Map<String, int>> getCoreTableRowCounts() async {
    final db = await database;
    final counts = <String, int>{};
    const tables = [
      'folders',
      'documents',
      'text_boxes',
      'image_boxes',
      'audio_boxes',
      'media_items',
      'diary_entries',
      'document_settings',
    ];
    for (final t in tables) {
      try {
        final exists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [t],
        );
        if (exists.isEmpty) continue;
        final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $t');
        final n = rows.isNotEmpty ? (rows.first['c'] as int? ?? 0) : 0;
        counts[t] = n;
      } catch (_) {}
    }
    return counts;
  }

  Future<Map<String, dynamic>> getMediaRecycleBinHealth() async {
    final db = await database;
    var hasDeletedFromDirectory = false;
    var hasDeletedAt = false;
    try {
      final columns = await db.rawQuery('PRAGMA table_info(media_items);');
      final names = columns.map((c) => c['name']?.toString() ?? '').toSet();
      hasDeletedFromDirectory = names.contains('deleted_from_directory');
      hasDeletedAt = names.contains('deleted_at');
    } catch (_) {}

    int recycleItemCount = 0;
    int restorableCount = 0;
    int missingOriginalDirectoryCount = 0;
    int invalidOriginalDirectoryCount = 0;
    final samples = <Map<String, dynamic>>[];

    try {
      final rows = await db.query(
        'media_items',
        columns: [
          'id',
          'name',
          'type',
          'directory',
          if (hasDeletedFromDirectory) 'deleted_from_directory',
          if (hasDeletedAt) 'deleted_at',
        ],
        where: 'directory = ?',
        whereArgs: ['recycle_bin'],
      );
      recycleItemCount = rows.length;
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id == 'recycle_bin' || id == 'favorites') continue;
        restorableCount++;
        final original =
            hasDeletedFromDirectory
                ? (row['deleted_from_directory']?.toString() ?? '').trim()
                : '';
        var issue = '';
        if (original.isEmpty) {
          missingOriginalDirectoryCount++;
          issue = 'missing_original_directory';
        } else if (original != 'root' && original != 'favorites') {
          final parents = await db.query(
            'media_items',
            columns: ['id', 'type', 'directory'],
            where: 'id = ? AND type = ?',
            whereArgs: [original, 3],
            limit: 1,
          );
          if (parents.isEmpty ||
              (parents.first['directory']?.toString() ?? '') == 'recycle_bin') {
            invalidOriginalDirectoryCount++;
            issue = 'invalid_original_directory';
          }
        }
        if (issue.isNotEmpty && samples.length < 8) {
          samples.add({
            'id': id,
            'name': row['name']?.toString() ?? '',
            'originalDirectory': original,
            'issue': issue,
          });
        }
      }
    } catch (e) {
      return {
        'ok': false,
        'hasDeletedFromDirectory': hasDeletedFromDirectory,
        'hasDeletedAt': hasDeletedAt,
        'recycleItemCount': recycleItemCount,
        'restorableCount': restorableCount,
        'missingOriginalDirectoryCount': missingOriginalDirectoryCount,
        'invalidOriginalDirectoryCount': invalidOriginalDirectoryCount,
        'samples': samples,
        'error': e.toString(),
      };
    }

    final schemaOk = hasDeletedFromDirectory && hasDeletedAt;
    return {
      'ok': schemaOk,
      'schemaOk': schemaOk,
      'hasDeletedFromDirectory': hasDeletedFromDirectory,
      'hasDeletedAt': hasDeletedAt,
      'recycleItemCount': recycleItemCount,
      'restorableCount': restorableCount,
      'missingOriginalDirectoryCount': missingOriginalDirectoryCount,
      'invalidOriginalDirectoryCount': invalidOriginalDirectoryCount,
      'samples': samples,
    };
  }

  Future<Map<String, dynamic>> getVideoViewStagingJsonStatus() async {
    final root = _appDocumentsDirectoryPath;
    if (root == null || root.isEmpty) {
      return {
        'exists': false,
        'sizeBytes': 0,
        'parseOk': false,
        'itemCount': 0,
        'unknownIdCount': 0,
      };
    }
    final file = File(p.join(root, _videoViewStagingJsonFileName));
    if (!await file.exists()) {
      return {
        'exists': false,
        'sizeBytes': 0,
        'parseOk': true,
        'itemCount': 0,
        'unknownIdCount': 0,
      };
    }
    int size = 0;
    try {
      size = await file.length();
    } catch (_) {}
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return {
          'exists': true,
          'sizeBytes': size,
          'parseOk': true,
          'itemCount': 0,
          'unknownIdCount': 0,
        };
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return {
          'exists': true,
          'sizeBytes': size,
          'parseOk': false,
          'itemCount': 0,
          'unknownIdCount': 0,
        };
      }
      final itemsRaw = decoded['items'];
      if (itemsRaw is! Map) {
        return {
          'exists': true,
          'sizeBytes': size,
          'parseOk': false,
          'itemCount': 0,
          'unknownIdCount': 0,
        };
      }
      final items = Map<String, dynamic>.from(itemsRaw as Map);
      final ids = items.keys.toList();
      int unknown = 0;
      if (ids.isNotEmpty) {
        final db = await database;
        const chunk = 900;
        for (int i = 0; i < ids.length; i += chunk) {
          final part = ids.sublist(i, (i + chunk).clamp(0, ids.length));
          final qs = List.filled(part.length, '?').join(',');
          final rows = await db.rawQuery(
            'SELECT id FROM media_items WHERE id IN ($qs)',
            part,
          );
          final existing = rows.map((r) => r['id']?.toString() ?? '').toSet();
          for (final id in part) {
            if (!existing.contains(id)) unknown++;
          }
        }
      }
      return {
        'exists': true,
        'sizeBytes': size,
        'parseOk': true,
        'itemCount': items.length,
        'unknownIdCount': unknown,
      };
    } catch (_) {
      return {
        'exists': true,
        'sizeBytes': size,
        'parseOk': false,
        'itemCount': 0,
        'unknownIdCount': 0,
      };
    }
  }

  Future<Map<String, dynamic>> findDuplicateMediaItemsSummary({
    int limit = 20,
  }) async {
    final db = await database;
    try {
      final rows = await db.rawQuery(
        '''
        SELECT file_hash AS hash, COUNT(*) AS c
        FROM media_items
        WHERE file_hash IS NOT NULL AND TRIM(file_hash) <> '' AND directory <> 'recycle_bin'
        GROUP BY file_hash
        HAVING c > 1
        ORDER BY c DESC
        LIMIT ?
      ''',
        [limit],
      );
      int total = 0;
      try {
        final countRows = await db.rawQuery('''
          SELECT COUNT(*) AS c FROM (
            SELECT file_hash
            FROM media_items
            WHERE file_hash IS NOT NULL AND TRIM(file_hash) <> '' AND directory <> 'recycle_bin'
            GROUP BY file_hash
            HAVING COUNT(*) > 1
          )
        ''');
        total = countRows.isNotEmpty ? (countRows.first['c'] as int? ?? 0) : 0;
      } catch (_) {}
      final top = <Map<String, dynamic>>[];
      for (final r in rows) {
        final h = r['hash']?.toString() ?? '';
        final c = r['c'] as int? ?? 0;
        if (h.isEmpty || c <= 1) continue;
        top.add({'hash': h, 'count': c});
      }
      return {'total': total, 'top': top};
    } catch (_) {
      return {'total': 0, 'top': <Map<String, dynamic>>[]};
    }
  }

  Future<List<Map<String, dynamic>>> getDuplicateMediaItemsByHash(
    String fileHash,
  ) async {
    final db = await database;
    if (fileHash.trim().isEmpty) return [];
    final rows = await db.query(
      'media_items',
      columns: [
        'id',
        'name',
        'path',
        'type',
        'directory',
        'date_added',
        'thumbnail_path',
        'is_favorite',
        'file_hash',
      ],
      where: 'file_hash = ? AND directory <> ?',
      whereArgs: [fileHash, 'recycle_bin'],
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>> resolveDuplicateMediaItems({
    int maxGroups = 50,
  }) async {
    final db = await database;
    final resolvedHashes = <String>[];
    int movedMediaRows = 0;

    List<String> duplicateHashes = [];
    try {
      final rows = await db.rawQuery(
        '''
        SELECT file_hash AS hash
        FROM media_items
        WHERE file_hash IS NOT NULL AND TRIM(file_hash) <> '' AND directory <> 'recycle_bin'
        GROUP BY file_hash
        HAVING COUNT(*) > 1
        ORDER BY COUNT(*) DESC
        LIMIT ?
      ''',
        [maxGroups],
      );
      duplicateHashes =
          rows
              .map((r) => r['hash']?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
    } catch (_) {}

    int pickScore(Map<String, dynamic> row) {
      int score = 0;
      final dir = row['directory']?.toString() ?? '';
      final favRaw = row['is_favorite'];
      final isFav =
          favRaw == true || favRaw == 1 || (favRaw is num && favRaw != 0);
      if (isFav) score += 100;
      if (dir != 'recycle_bin') score += 50;
      final thumb = row['thumbnail_path']?.toString() ?? '';
      if (thumb.isNotEmpty) score += 5;
      final dateAdded = row['date_added']?.toString() ?? '';
      if (dateAdded.isNotEmpty) score += 1;
      return score;
    }

    for (final hash in duplicateHashes) {
      final items = await getDuplicateMediaItemsByHash(hash);
      if (items.length <= 1) continue;

      items.sort((a, b) => pickScore(b) - pickScore(a));
      final keepId = items.first['id']?.toString() ?? '';
      if (keepId.isEmpty) continue;

      for (final row in items.skip(1)) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        try {
          final moved = await moveMediaItemToRecycleBin(id);
          if (moved) movedMediaRows++;
        } catch (_) {}
      }
      resolvedHashes.add(hash);
    }

    return {
      'groupsResolved': resolvedHashes.length,
      'mediaRowsMovedToRecycle': movedMediaRows,
      'mediaRowsDeleted': 0,
      'orphanFilesDeleted': 0,
      'orphanBytesDeleted': 0,
      'hashes': resolvedHashes.take(10).toList(),
    };
  }

  Future<List<Map<String, dynamic>>> describeFilePathReferences(
    String absPath,
  ) async {
    final db = await database;
    final p0 = absPath.trim();
    if (p0.isEmpty) return [];
    final usages = <Map<String, dynamic>>[];

    try {
      final rows = await db.rawQuery(
        '''
        SELECT ds.document_id AS document_id,
               d.name AS document_name,
               f.name AS folder_name,
               ds.background_image_path AS img,
               ds.background_video_path AS vid
        FROM document_settings ds
        JOIN documents d ON d.id = ds.document_id
        LEFT JOIN folders f ON f.id = d.parent_folder
        WHERE ds.background_image_path = ? OR ds.background_video_path = ?
      ''',
        [p0, p0],
      );
      for (final r in rows) {
        final docId = r['document_id']?.toString() ?? '';
        final docName = r['document_name']?.toString() ?? '';
        final folderName = r['folder_name']?.toString();
        final img = r['img']?.toString() ?? '';
        final vid = r['vid']?.toString() ?? '';
        if (img == p0) {
          usages.add({
            'type': 'document_background_image',
            'documentId': docId,
            'documentName': docName,
            'folderName': folderName,
          });
        }
        if (vid == p0) {
          usages.add({
            'type': 'document_background_video',
            'documentId': docId,
            'documentName': docName,
            'folderName': folderName,
          });
        }
      }
    } catch (_) {}

    try {
      final rows = await db.rawQuery(
        '''
        SELECT folder_name AS folder_name, background_image_path AS img, background_video_path AS vid
        FROM directory_settings
        WHERE background_image_path = ? OR background_video_path = ?
      ''',
        [p0, p0],
      );
      for (final r in rows) {
        final folderName = r['folder_name']?.toString() ?? '';
        final img = r['img']?.toString() ?? '';
        final vid = r['vid']?.toString() ?? '';
        if (img == p0) {
          usages.add({
            'type': 'directory_background_image',
            'folderName': folderName,
          });
        }
        if (vid == p0) {
          usages.add({
            'type': 'directory_background_video',
            'folderName': folderName,
          });
        }
      }
    } catch (_) {}

    try {
      final rows = await db.rawQuery(
        '''
        SELECT background_image_path AS img, background_video_path AS vid
        FROM diary_settings
        WHERE background_image_path = ? OR background_video_path = ?
      ''',
        [p0, p0],
      );
      for (final r in rows) {
        final img = r['img']?.toString() ?? '';
        final vid = r['vid']?.toString() ?? '';
        if (img == p0) usages.add({'type': 'diary_background_image'});
        if (vid == p0) usages.add({'type': 'diary_background_video'});
      }
    } catch (_) {}

    bool hasCoverSettings = false;
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings'",
      );
      hasCoverSettings = rows.isNotEmpty;
    } catch (_) {}
    if (hasCoverSettings) {
      try {
        final rows = await db.rawQuery(
          '''
          SELECT background_image_path AS img, background_video_path AS vid
          FROM cover_settings
          WHERE background_image_path = ? OR background_video_path = ?
        ''',
          [p0, p0],
        );
        for (final r in rows) {
          final img = r['img']?.toString() ?? '';
          final vid = r['vid']?.toString() ?? '';
          if (img == p0) usages.add({'type': 'cover_background_image'});
          if (vid == p0) usages.add({'type': 'cover_background_video'});
        }
      } catch (_) {}
    }

    try {
      final rows = await db.query(
        'cover_image',
        columns: ['id'],
        where: 'path = ?',
        whereArgs: [p0],
      );
      for (final r in rows) {
        usages.add({'type': 'cover_image', 'id': r['id']});
      }
    } catch (_) {}

    try {
      final rows = await db.rawQuery(
        '''
        SELECT ib.id AS box_id, d.id AS document_id, d.name AS document_name, f.name AS folder_name
        FROM image_boxes ib
        JOIN documents d ON d.id = ib.document_id
        LEFT JOIN folders f ON f.id = d.parent_folder
        WHERE ib.image_path = ?
      ''',
        [p0],
      );
      for (final r in rows) {
        usages.add({
          'type': 'document_image_box',
          'documentId': r['document_id']?.toString() ?? '',
          'documentName': r['document_name']?.toString() ?? '',
          'folderName': r['folder_name']?.toString(),
          'boxId': r['box_id']?.toString() ?? '',
        });
      }
    } catch (_) {}

    try {
      final rows = await db.rawQuery(
        '''
        SELECT ab.id AS box_id, d.id AS document_id, d.name AS document_name, f.name AS folder_name
        FROM audio_boxes ab
        JOIN documents d ON d.id = ab.document_id
        LEFT JOIN folders f ON f.id = d.parent_folder
        WHERE ab.audio_path = ?
      ''',
        [p0],
      );
      for (final r in rows) {
        usages.add({
          'type': 'document_audio_box',
          'documentId': r['document_id']?.toString() ?? '',
          'documentName': r['document_name']?.toString() ?? '',
          'folderName': r['folder_name']?.toString(),
          'boxId': r['box_id']?.toString() ?? '',
        });
      }
    } catch (_) {}

    try {
      final rows = await db.query(
        'media_items',
        columns: ['id', 'name', 'type', 'directory', 'path', 'thumbnail_path'],
        where: 'path = ? OR thumbnail_path = ?',
        whereArgs: [p0, p0],
      );
      for (final r in rows) {
        final pathV = r['path']?.toString() ?? '';
        final thumbV = r['thumbnail_path']?.toString() ?? '';
        if (pathV == p0) {
          usages.add({
            'type': 'media_item_file',
            'mediaId': r['id']?.toString() ?? '',
            'mediaName': r['name']?.toString() ?? '',
            'mediaType': r['type'],
            'directory': r['directory']?.toString() ?? '',
          });
        }
        if (thumbV == p0) {
          usages.add({
            'type': 'media_item_thumbnail',
            'mediaId': r['id']?.toString() ?? '',
            'mediaName': r['name']?.toString() ?? '',
            'mediaType': r['type'],
            'directory': r['directory']?.toString() ?? '',
          });
        }
      }
    } catch (_) {}

    try {
      final rows = await db.query(
        _backgroundFileViewParamsTable,
        columns: ['path'],
        where: 'path = ?',
        whereArgs: [p0],
      );
      if (rows.isNotEmpty) usages.add({'type': 'background_file_view_params'});
    } catch (_) {}

    try {
      final like = '%$p0%';
      final rows = await db.rawQuery(
        '''
        SELECT id, date, image_paths, audio_paths, video_paths
        FROM diary_entries
        WHERE (image_paths LIKE ?) OR (audio_paths LIKE ?) OR (video_paths LIKE ?)
      ''',
        [like, like, like],
      );
      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        final date = r['date']?.toString() ?? '';
        bool hit = false;
        for (final k in ['image_paths', 'audio_paths', 'video_paths']) {
          final raw = r[k]?.toString() ?? '';
          if (raw.isEmpty || !raw.contains(p0)) continue;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is List) {
              if (decoded.whereType<String>().contains(p0)) {
                hit = true;
              }
            }
          } catch (_) {}
        }
        if (hit) {
          usages.add({
            'type': 'diary_entry_media',
            'diaryId': id,
            'date': date,
          });
        }
      }
    } catch (_) {}

    return usages;
  }

  Future<List<Map<String, dynamic>>> describeMissingFileReferences(
    List<String> missingPaths,
  ) async {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final p0 in missingPaths) {
      final p = p0.trim();
      if (p.isEmpty) continue;
      if (!seen.add(p)) continue;
      final usages = await describeFilePathReferences(p);
      bool repairable = usages.any((u) {
        final t = u['type']?.toString() ?? '';
        return t == 'document_background_image' ||
            t == 'document_background_video' ||
            t == 'directory_background_image' ||
            t == 'directory_background_video' ||
            t == 'diary_background_image' ||
            t == 'diary_background_video' ||
            t == 'cover_background_image' ||
            t == 'cover_background_video' ||
            t == 'cover_image' ||
            t == 'background_file_view_params' ||
            t == 'diary_entry_media';
      });
      out.add({'path': p, 'usages': usages, 'repairable': repairable});
    }
    return out;
  }

  Future<Map<String, dynamic>> repairMissingFileReferences(
    List<String> missingPaths,
  ) async {
    final db = await database;
    final unique = <String>{};
    final paths = <String>[];
    for (final p0 in missingPaths) {
      final p = p0.trim();
      if (p.isEmpty) continue;
      if (unique.add(p)) paths.add(p);
    }
    if (paths.isEmpty) {
      return {'fixed': 0, 'unfixed': 0, 'fixedByType': <String, int>{}};
    }

    int fixed = 0;
    final fixedByType = <String, int>{};
    final fixedPaths = <String>{};
    bool bump(String k, int n) {
      if (n <= 0) return false;
      fixed += n;
      fixedByType[k] = (fixedByType[k] ?? 0) + n;
      return true;
    }

    bool hasCoverSettings = false;
    try {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cover_settings'",
      );
      hasCoverSettings = rows.isNotEmpty;
    } catch (_) {}

    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      for (final p in paths) {
        bool touched = false;
        try {
          final n = await txn.update(
            'document_settings',
            {
              'background_image_path': null,
              'background_image_origin': null,
              'updated_at': now,
            },
            where: 'background_image_path = ?',
            whereArgs: [p],
          );
          touched = bump('document_background_image', n) || touched;
        } catch (_) {}
        try {
          final n = await txn.update(
            'document_settings',
            {
              'background_video_path': null,
              'background_video_origin': null,
              'updated_at': now,
            },
            where: 'background_video_path = ?',
            whereArgs: [p],
          );
          touched = bump('document_background_video', n) || touched;
        } catch (_) {}

        try {
          final n = await txn.update(
            'directory_settings',
            {
              'background_image_path': null,
              'background_image_origin': null,
              'updated_at': now,
            },
            where: 'background_image_path = ?',
            whereArgs: [p],
          );
          touched = bump('directory_background_image', n) || touched;
        } catch (_) {}
        try {
          final n = await txn.update(
            'directory_settings',
            {
              'background_video_path': null,
              'background_video_origin': null,
              'updated_at': now,
            },
            where: 'background_video_path = ?',
            whereArgs: [p],
          );
          touched = bump('directory_background_video', n) || touched;
        } catch (_) {}

        try {
          final n = await txn.update(
            'diary_settings',
            {
              'background_image_path': null,
              'background_image_origin': null,
              'updated_at': now,
            },
            where: 'background_image_path = ?',
            whereArgs: [p],
          );
          touched = bump('diary_background_image', n) || touched;
        } catch (_) {}
        try {
          final n = await txn.update(
            'diary_settings',
            {
              'background_video_path': null,
              'background_video_origin': null,
              'updated_at': now,
            },
            where: 'background_video_path = ?',
            whereArgs: [p],
          );
          touched = bump('diary_background_video', n) || touched;
        } catch (_) {}

        if (hasCoverSettings) {
          try {
            final n = await txn.update(
              'cover_settings',
              {'background_image_path': null, 'background_image_origin': null},
              where: 'background_image_path = ?',
              whereArgs: [p],
            );
            touched = bump('cover_background_image', n) || touched;
          } catch (_) {}
          try {
            final n = await txn.update(
              'cover_settings',
              {'background_video_path': null, 'background_video_origin': null},
              where: 'background_video_path = ?',
              whereArgs: [p],
            );
            touched = bump('cover_background_video', n) || touched;
          } catch (_) {}
        }

        try {
          final n = await txn.delete(
            'cover_image',
            where: 'path = ?',
            whereArgs: [p],
          );
          touched = bump('cover_image', n) || touched;
        } catch (_) {}

        try {
          final n = await txn.delete(
            _backgroundFileViewParamsTable,
            where: 'path = ?',
            whereArgs: [p],
          );
          touched = bump('background_file_view_params', n) || touched;
        } catch (_) {}

        try {
          final like = '%$p%';
          final rows = await txn.rawQuery(
            '''
            SELECT id, image_paths, audio_paths, video_paths
            FROM diary_entries
            WHERE (image_paths LIKE ?) OR (audio_paths LIKE ?) OR (video_paths LIKE ?)
          ''',
            [like, like, like],
          );
          for (final r in rows) {
            final id = r['id']?.toString() ?? '';
            if (id.isEmpty) continue;
            Map<String, dynamic> next = {};
            for (final k in ['image_paths', 'audio_paths', 'video_paths']) {
              final raw = r[k]?.toString() ?? '';
              if (raw.isEmpty || !raw.contains(p)) continue;
              try {
                final decoded = jsonDecode(raw);
                if (decoded is List) {
                  final list = decoded.whereType<String>().toList();
                  final before = list.length;
                  list.removeWhere((e) => e == p);
                  if (list.length != before) {
                    next[k] = list.isEmpty ? null : jsonEncode(list);
                  }
                }
              } catch (_) {}
            }
            if (next.isEmpty) continue;
            await txn.update(
              'diary_entries',
              next,
              where: 'id = ?',
              whereArgs: [id],
            );
            touched = bump('diary_entry_media', 1) || touched;
          }
        } catch (_) {}
        if (touched) fixedPaths.add(p);
      }
    });

    return {
      'fixed': fixed,
      'fixedPathCount': fixedPaths.length,
      'pathCount': paths.length,
      'unfixedPathCount': (paths.length - fixedPaths.length).clamp(
        0,
        paths.length,
      ),
      'fixedByType': fixedByType,
    };
  }

  /// 修复数据完整性问题
  Future<void> repairDataIntegrity() async {
    final db = await database;

    try {
      await db.transaction((txn) async {
        // 修复无效的文件夹名称
        await txn.update('folders', {
          'name': '未命名文件夹_${DateTime.now().millisecondsSinceEpoch}',
        }, where: 'name IS NULL OR name = ""');

        // 修复无效的文档名称
        await txn.update('documents', {
          'name': '未命名文档_${DateTime.now().millisecondsSinceEpoch}',
        }, where: 'name IS NULL OR name = ""');

        // 清理无效的父文件夹引用
        await txn.update('folders', {
          'parent_folder': null,
        }, where: 'parent_folder NOT IN (SELECT id FROM folders)');

        await txn.update('documents', {
          'parent_folder': null,
        }, where: 'parent_folder NOT IN (SELECT id FROM folders)');
      });

      if (kDebugMode) {
        Logger.log('数据完整性修复完成');
      }
    } catch (e, stackTrace) {
      _handleError('数据完整性修复失败', e, stackTrace);
      rethrow;
    }
  }

  /// 复制文件夹（包含其子文件夹与文档）
  /// - sourceFolderName: 要复制的源文件夹名称
  /// - targetParentFolder: 复制后的新文件夹应放到的父文件夹名称；若为空，则与源文件夹同级
  Future<String> copyFolder(
    String sourceFolderName, {
    String? targetParentFolder,
  }) async {
    final db = await database;

    // 1) 获取源文件夹信息
    final Map<String, dynamic>? sourceFolder = await getFolderByName(
      sourceFolderName,
    );
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
      final Map<String, dynamic>? settings = await getDirectorySettings(
        sourceFolderName,
      );
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
    final List<Map<String, dynamic>> docs = await getDocuments(
      parentFolder: sourceFolderName,
    );
    for (final doc in docs) {
      final String docName = doc['name'] as String;
      await copyDocument(docName, parentFolder: finalNewFolderName);
    }

    // 7) 递归复制子文件夹
    final List<Map<String, dynamic>> subFolders = await getFolders(
      parentFolder: sourceFolderName,
    );
    for (final folder in subFolders) {
      final String childFolderName = folder['name'] as String;
      await copyFolder(childFolderName, targetParentFolder: finalNewFolderName);
    }

    return finalNewFolderName;
  }
}
