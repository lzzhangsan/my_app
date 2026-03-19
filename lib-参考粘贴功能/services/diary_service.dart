import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/diary_entry.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'database_service.dart';
import '../core/service_locator.dart';

class DiaryService {
  static const String _diaryKey = 'diary_entries';

  // 兼容旧数据：首次迁移SharedPreferences到数据库
  Future<void> migrateOldDataIfNeeded() async {
    final db = await getService<DatabaseService>().database;
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM diary_entries')) ?? 0;
    if (count == 0) {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_diaryKey);
      if (jsonString != null) {
        final List<dynamic> decoded = json.decode(jsonString);
        for (final e in decoded) {
          final entry = DiaryEntry.fromMap(e);
          await addEntry(entry);
        }
        await prefs.remove(_diaryKey);
      }
    }
  }

  Future<int> getEntryCount() async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM diary_entries')) ?? 0;
  }

  Future<List<DiaryEntry>> loadEntries() async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final maps = await db.query('diary_entries', orderBy: 'date DESC');
    return _mapsToEntries(maps);
  }

  /// 按 ID 获取单条日记（用于编辑页，避免全量加载）
  Future<DiaryEntry?> getEntryById(String id) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final maps = await db.query('diary_entries', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return _mapsToEntries(maps).first;
  }
  
  // 分页加载日记数据，用于处理大量数据（可按月份筛选）
  Future<List<DiaryEntry>> loadEntriesPaged(int offset, int limit, {int? year, int? month}) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    String? where;
    List<Object?>? whereArgs;
    if (year != null && month != null) {
      final start = DateTime(year, month, 1).toIso8601String();
      final end = DateTime(year, month + 1, 1).toIso8601String();
      where = 'date >= ? AND date < ?';
      whereArgs = [start, end];
    }
    final maps = await db.query(
      'diary_entries',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC',
      limit: limit,
      offset: offset,
    );
    return _mapsToEntries(maps);
  }

  /// 获取指定月份有日记的日期列表（轻量，用于日历圆点）
  Future<List<DateTime>> getDatesWithEntries(int year, int month) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final start = DateTime(year, month, 1).toIso8601String();
    final end = DateTime(year, month + 1, 1).toIso8601String();
    final rows = await db.rawQuery(
      "SELECT DISTINCT date FROM diary_entries WHERE date >= ? AND date < ?",
      [start, end],
    );
    return rows.map((r) => DateTime.parse(r['date'] as String)).toList();
  }

  /// 加载指定日期的日记（通常数量少，避免全量加载）
  Future<List<DiaryEntry>> loadEntriesForDate(DateTime date, {String? searchKeyword, bool? favoritesOnly}) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final dateStr = DateTime(date.year, date.month, date.day).toIso8601String().substring(0, 10);
    final nextDateStr = DateTime(date.year, date.month, date.day + 1).toIso8601String().substring(0, 10);
    var maps = await db.query(
      'diary_entries',
      where: 'date >= ? AND date < ?',
      whereArgs: [dateStr, nextDateStr],
      orderBy: 'date DESC',
    );
    var entries = _mapsToEntries(maps);
    if (favoritesOnly == true) entries = entries.where((e) => e.isFavorite).toList();
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      entries = entries.where((e) => (e.content ?? '').contains(searchKeyword)).toList();
    }
    return entries;
  }

  /// 加载所有日记（保留用于导出、搜索等需要全量的场景）
  Future<List<DiaryEntry>> loadEntriesFiltered({String? searchKeyword, bool? favoritesOnly, int? limit}) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    var maps = await db.query('diary_entries', orderBy: 'date DESC', limit: limit ?? 99999);
    var entries = _mapsToEntries(maps);
    if (favoritesOnly == true) entries = entries.where((e) => e.isFavorite).toList();
    if (searchKeyword != null && searchKeyword.isNotEmpty) {
      entries = entries.where((e) => (e.content ?? '').contains(searchKeyword)).toList();
    }
    return entries;
  }

  /// 在全部日记中搜索（数据库级，不限于已加载条目）
  Future<List<DiaryEntry>> searchAllEntries({
    required String keyword,
    bool favoritesOnly = false,
  }) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final cleanKeyword = keyword.replaceAll(' ', '');
    String? where;
    List<Object?>? whereArgs = [];

    final yearRegex = RegExp(r'(\d{4})(年)?$');
    final yearMatch = yearRegex.firstMatch(cleanKeyword);
    if (yearMatch != null) {
      final year = int.parse(yearMatch.group(1)!);
      where = "date LIKE ?";
      whereArgs = ['$year%'];
    } else {
      final yearMonthRegex = RegExp(r'(\d{4})[年\-\.\//](\d{1,2})(月)?$');
      final yearMonthMatch = yearMonthRegex.firstMatch(cleanKeyword);
      if (yearMonthMatch != null) {
        final year = int.parse(yearMonthMatch.group(1)!);
        final month = int.parse(yearMonthMatch.group(2)!);
        if (month >= 1 && month <= 12) {
          final start = DateTime(year, month, 1).toIso8601String();
          final end = DateTime(year, month + 1, 1).toIso8601String();
          where = 'date >= ? AND date < ?';
          whereArgs = [start, end];
        }
      } else {
        final dateRegex = RegExp(r'(\d{4})[年\-\.\//](\d{1,2})[月\-\.\//](\d{1,2})(日)?$');
        final dateMatch = dateRegex.firstMatch(cleanKeyword);
        if (dateMatch != null) {
          final year = int.parse(dateMatch.group(1)!);
          final month = int.parse(dateMatch.group(2)!);
          final day = int.parse(dateMatch.group(3)!);
          if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
            final start = DateTime(year, month, day).toIso8601String().substring(0, 10);
            final end = DateTime(year, month, day + 1).toIso8601String().substring(0, 10);
            where = 'date >= ? AND date < ?';
            whereArgs = [start, end];
          }
        } else {
          final monthDayRegex = RegExp(r'^(\d{1,2})[月\-\.\//](\d{1,2})(日)?$');
          final monthDayMatch = monthDayRegex.firstMatch(cleanKeyword);
          if (monthDayMatch != null) {
            final month = int.parse(monthDayMatch.group(1)!);
            final day = int.parse(monthDayMatch.group(2)!);
            if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
              where = "strftime('%m', date) = ? AND strftime('%d', date) = ?";
              whereArgs = [month.toString().padLeft(2, '0'), day.toString().padLeft(2, '0')];
            }
          } else {
            final monthRegex = RegExp(r'^(\d{1,2})(月)$');
            final monthMatch = monthRegex.firstMatch(cleanKeyword);
            if (monthMatch != null) {
              final month = int.parse(monthMatch.group(1)!);
              if (month >= 1 && month <= 12) {
                where = "strftime('%m', date) = ?";
                whereArgs = [month.toString().padLeft(2, '0')];
              }
            } else {
              final dayRegex = RegExp(r'^(\d{1,2})(日)$');
              final dayMatch = dayRegex.firstMatch(cleanKeyword);
              if (dayMatch != null) {
                final day = int.parse(dayMatch.group(1)!);
                if (day >= 1 && day <= 31) {
                  where = "strftime('%d', date) = ?";
                  whereArgs = [day.toString().padLeft(2, '0')];
                }
              }
            }
          }
        }
      }
    }

    if (where == null) {
      where = 'content LIKE ?';
      whereArgs = ['%$keyword%'];
    }

    if (favoritesOnly) {
      where = '$where AND is_favorite = 1';
    }

    final maps = await db.query(
      'diary_entries',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC',
    );
    return _mapsToEntries(maps);
  }
  
  // 将数据库记录转换为DiaryEntry对象
  List<DiaryEntry> _mapsToEntries(List<Map<String, dynamic>> maps) {
    return maps.map((map) => DiaryEntry(
      id: map['id']?.toString() ?? '',
      date: DateTime.parse(map['date']?.toString() ?? ''),
      content: map['content'] is String ? map['content'] as String? : map['content']?.toString(),
      imagePaths: map['image_paths'] is String
          ? (json.decode(map['image_paths']?.toString() ?? '[]') as List<dynamic>).map((e) => e.toString()).toList()
          : (map['image_paths'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      audioPaths: map['audio_paths'] is String
          ? (json.decode(map['audio_paths']?.toString() ?? '[]') as List<dynamic>).map((e) => e.toString()).toList()
          : (map['audio_paths'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      videoPaths: map['video_paths'] is String
          ? (json.decode(map['video_paths']?.toString() ?? '[]') as List<dynamic>).map((e) => e.toString()).toList()
          : (map['video_paths'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      weather: map['weather'] is String ? map['weather'] as String? : map['weather']?.toString(),
      mood: map['mood'] is String ? map['mood'] as String? : map['mood']?.toString(),
      location: map['location'] is String ? map['location'] as String? : map['location']?.toString(),
      isFavorite: (map['is_favorite'] ?? 0) == 1,
    )).toList();
  }

  Future<void> saveEntries(List<DiaryEntry> entries) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    await db.transaction((txn) async {
      await txn.delete('diary_entries');
      final batch = txn.batch();
      for (var entry in entries) {
        batch.insert('diary_entries', _entryToDbMap(entry), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> replaceAllEntries(List<DiaryEntry> entries) async {
    final dbService = getService<DatabaseService>();
    await dbService.replaceAllDiaryEntries(entries);
  }

  /// 分块替换所有日记条目，避免大容量导入时 OOM
  Future<void> replaceAllEntriesFromChunks(Future<List<DiaryEntry>?> Function() getNextChunk) async {
    final dbService = getService<DatabaseService>();
    await dbService.replaceAllDiaryEntriesFromChunks(getNextChunk);
  }

  Future<void> addEntry(DiaryEntry entry) async {
    final db = await getService<DatabaseService>().database;
    await db.insert('diary_entries', _entryToDbMap(entry), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateEntry(DiaryEntry entry) async {
    final db = await getService<DatabaseService>().database;
    await db.update('diary_entries', _entryToDbMap(entry), where: 'id = ?', whereArgs: [entry.id]);
  }

  Future<void> deleteEntry(String id) async {
    final db = await getService<DatabaseService>().database;
    // 1. 先获取记录中的媒体路径（用于 DB 删除成功后再删物理文件）
    final rows = await db.query('diary_entries', where: 'id = ?', whereArgs: [id]);
    final paths = <String>[];
    if (rows.isNotEmpty) {
      final row = rows.first;
      for (final key in ['image_paths', 'audio_paths', 'video_paths']) {
        final val = row[key];
        if (val == null) continue;
        try {
          final list = json.decode(val.toString()) as List?;
          if (list != null) {
            for (final p in list) {
              final s = p.toString().trim();
              if (s.isNotEmpty) paths.add(s);
            }
          }
        } catch (_) {}
      }
    }
    // 2. 先删 DB，保证数据一致性；若 DB 删除失败则保留文件，便于恢复
    await db.delete('diary_entries', where: 'id = ?', whereArgs: [id]);
    // 3. DB 删除成功后，再删除物理文件（失败仅留下孤立文件，不影响 DB 权威性）
    for (final filePath in paths) {
      try {
        final f = File(filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> autoSaveEntry(DiaryEntry entry) async {
    await addEntry(entry);
  }

  Map<String, dynamic> _entryToDbMap(DiaryEntry entry) => {
    'id': entry.id,
    'date': entry.date.toIso8601String(),
    'content': entry.content,
    'image_paths': json.encode(entry.imagePaths),
    'audio_paths': json.encode(entry.audioPaths),
    'video_paths': json.encode(entry.videoPaths),
    'weather': entry.weather,
    'mood': entry.mood,
    'location': entry.location,
    'is_favorite': entry.isFavorite ? 1 : 0,
  };
}