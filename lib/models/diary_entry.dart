import 'dart:convert';

class DiaryEntry {
  final String id;
  final DateTime date;
  final String? content;
  final List<String> imagePaths;
  final List<String> audioPaths;
  final List<String> videoPaths;
  final String? weather;
  final String? mood;
  final String? location;
  final bool isFavorite;

  DiaryEntry({
    required this.id,
    required this.date,
    this.content,
    this.imagePaths = const [],
    this.audioPaths = const [],
    this.videoPaths = const [],
    this.weather,
    this.mood,
    this.location,
    this.isFavorite = false,
  });

  DiaryEntry copyWith({
    String? id,
    DateTime? date,
    String? content,
    List<String>? imagePaths,
    List<String>? audioPaths,
    List<String>? videoPaths,
    String? weather,
    String? mood,
    String? location,
    bool? isFavorite,
  }) {
    return DiaryEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      content: content ?? this.content,
      imagePaths: imagePaths ?? this.imagePaths,
      audioPaths: audioPaths ?? this.audioPaths,
      videoPaths: videoPaths ?? this.videoPaths,
      weather: weather ?? this.weather,
      mood: mood ?? this.mood,
      location: location ?? this.location,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'content': content,
      'image_paths': jsonEncode(imagePaths),
      'audio_paths': jsonEncode(audioPaths),
      'video_paths': jsonEncode(videoPaths),
      'weather': weather,
      'mood': mood,
      'location': location,
      'is_favorite': isFavorite ? 1 : 0,
    };
  }

  factory DiaryEntry.fromMap(Map<String, dynamic> map) {
    DateTime safeDate;
    try {
      safeDate = DateTime.parse(map['date']?.toString() ?? '');
    } catch (_) {
      safeDate = DateTime.now();
    }
    
    // 处理媒体路径，支持多种字段名格式
    List<String> parseMediaPaths(dynamic paths) {
      if (paths == null) return [];
      if (paths is List) {
        return paths.map((p) => p.toString()).toList();
      }
      if (paths is String) {
        try {
          final decoded = jsonDecode(paths) as List;
          return decoded.map((p) => p.toString()).toList();
        } catch (_) {
          return [paths];
        }
      }
      return [];
    }
    
    return DiaryEntry(
      id: map['id']?.toString() ?? '',
      date: safeDate,
      content: map['content'] as String?,
      imagePaths: parseMediaPaths(map['imagePaths'] ?? map['image_paths']),
      audioPaths: parseMediaPaths(map['audioPaths'] ?? map['audio_paths']),
      videoPaths: parseMediaPaths(map['videoPaths'] ?? map['video_paths']),
      weather: map['weather'] as String?,
      mood: map['mood'] as String?,
      location: map['location'] as String?,
      isFavorite: map['isFavorite'] == true || map['is_favorite'] == 1,
    );
  }
} 