import 'package:flutter/material.dart';

class DiaryEntry {
  final String id;
  final DateTime date;
  final String content;
  final List<String> imagePaths;
  final List<String> audioPaths;
  final String? weather;
  final String? mood;
  final String? location;
  final bool isFavorite;

  DiaryEntry({
    required this.id,
    required this.date,
    required this.content,
    this.imagePaths = const [],
    this.audioPaths = const [],
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
      'imagePaths': imagePaths,
      'audioPaths': audioPaths,
      'weather': weather,
      'mood': mood,
      'location': location,
      'isFavorite': isFavorite,
    };
  }

  factory DiaryEntry.fromMap(Map<String, dynamic> map) {
    return DiaryEntry(
      id: map['id'] as String,
      date: DateTime.parse(map['date'] as String),
      content: map['content'] as String,
      imagePaths: List<String>.from(map['imagePaths'] ?? []),
      audioPaths: List<String>.from(map['audioPaths'] ?? []),
      weather: map['weather'] as String?,
      mood: map['mood'] as String?,
      location: map['location'] as String?,
      isFavorite: map['isFavorite'] == true,
    );
  }
} 