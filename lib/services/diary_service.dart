import 'package:shared_preferences/shared_preferences.dart';
import '../models/diary_entry.dart';
import 'dart:convert';

class DiaryService {
  static const String _diaryKey = 'diary_entries';

  Future<List<DiaryEntry>> loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_diaryKey);
    if (jsonString == null) return [];
    final List<dynamic> decoded = json.decode(jsonString);
    return decoded.map((e) => DiaryEntry.fromMap(e)).toList();
  }

  Future<void> saveEntries(List<DiaryEntry> entries) async {
    // 先去重，只保留每个id的最后一条
    final Map<String, DiaryEntry> unique = {};
    for (final e in entries) {
      unique[e.id] = e;
    }
    final uniqueList = unique.values.toList();
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode(uniqueList.map((e) => e.toMap()).toList());
    await prefs.setString(_diaryKey, jsonString);
  }

  Future<void> addEntry(DiaryEntry entry) async {
    final entries = await loadEntries();
    entries.add(entry);
    await saveEntries(entries);
  }

  Future<void> updateEntry(DiaryEntry entry) async {
    final entries = await loadEntries();
    final idx = entries.indexWhere((e) => e.id == entry.id);
    if (idx != -1) {
      entries[idx] = entry;
      await saveEntries(entries);
    }
  }

  Future<void> deleteEntry(String id) async {
    final entries = await loadEntries();
    entries.removeWhere((e) => e.id == id);
    await saveEntries(entries);
  }

  Future<void> autoSaveEntry(DiaryEntry entry) async {
    final entries = await loadEntries();
    final idx = entries.indexWhere((e) => e.id == entry.id);
    if (idx != -1) {
      entries[idx] = entry;
    } else {
      entries.add(entry);
    }
    await saveEntries(entries);
  }
} 