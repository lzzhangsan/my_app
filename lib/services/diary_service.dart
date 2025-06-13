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

  Future<List<DiaryEntry>> loadEntries() async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final maps = await db.query('diary_entries', orderBy: 'date DESC');
    return _mapsToEntries(maps);
  }
  
  // 分页加载日记数据，用于处理大量数据
  Future<List<DiaryEntry>> loadEntriesPaged(int offset, int limit) async {
    await migrateOldDataIfNeeded();
    final db = await getService<DatabaseService>().database;
    final maps = await db.query(
      'diary_entries', 
      orderBy: 'date DESC',
      limit: limit,
      offset: offset
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
    final db = await getService<DatabaseService>().database;
    await db.transaction((txn) async {
      await txn.delete('diary_entries');
      for (final entry in entries) {
        await txn.insert('diary_entries', _entryToDbMap(entry));
      }
    });
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
    await db.delete('diary_entries', where: 'id = ?', whereArgs: [id]);
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