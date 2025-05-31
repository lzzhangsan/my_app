// lib/models/document.dart
// 文档模型 - 提供类型安全的数据结构

import 'package:flutter/foundation.dart';

/// 文档模型
@immutable
class Document {
  final String id;
  final String name;
  final String? parentFolder;
  final int orderIndex;
  final bool isTemplate;
  final String? position;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Document({
    required this.id,
    required this.name,
    this.parentFolder,
    this.orderIndex = 0,
    this.isTemplate = false,
    this.position,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 从数据库映射创建文档
  factory Document.fromMap(Map<String, dynamic> map) {
    return Document(
      id: map['id'] as String,
      name: map['name'] as String,
      parentFolder: map['parent_folder'] as String?,
      orderIndex: map['order_index'] as int? ?? 0,
      isTemplate: (map['is_template'] as int? ?? 0) == 1,
      position: map['position'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  /// 转换为数据库映射
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parent_folder': parentFolder,
      'order_index': orderIndex,
      'is_template': isTemplate ? 1 : 0,
      'position': position,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// 创建副本
  Document copyWith({
    String? id,
    String? name,
    String? parentFolder,
    int? orderIndex,
    bool? isTemplate,
    String? position,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Document(
      id: id ?? this.id,
      name: name ?? this.name,
      parentFolder: parentFolder ?? this.parentFolder,
      orderIndex: orderIndex ?? this.orderIndex,
      isTemplate: isTemplate ?? this.isTemplate,
      position: position ?? this.position,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Document &&
        other.id == id &&
        other.name == name &&
        other.parentFolder == parentFolder &&
        other.orderIndex == orderIndex &&
        other.isTemplate == isTemplate &&
        other.position == position &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      name,
      parentFolder,
      orderIndex,
      isTemplate,
      position,
      createdAt,
      updatedAt,
    );
  }

  @override
  String toString() {
    return 'Document(id: $id, name: $name, parentFolder: $parentFolder, orderIndex: $orderIndex, isTemplate: $isTemplate, position: $position, createdAt: $createdAt, updatedAt: $updatedAt)';
  }
}

/// 文档设置模型
@immutable
class DocumentSettings {
  final String documentId;
  final String? backgroundImagePath;
  final int? backgroundColor;
  final int textEnhanceMode;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DocumentSettings({
    required this.documentId,
    this.backgroundImagePath,
    this.backgroundColor,
    this.textEnhanceMode = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 从数据库映射创建文档设置
  factory DocumentSettings.fromMap(Map<String, dynamic> map) {
    return DocumentSettings(
      documentId: map['document_id'] as String,
      backgroundImagePath: map['background_image_path'] as String?,
      backgroundColor: map['background_color'] as int?,
      textEnhanceMode: map['text_enhance_mode'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  /// 转换为数据库映射
  Map<String, dynamic> toMap() {
    return {
      'document_id': documentId,
      'background_image_path': backgroundImagePath,
      'background_color': backgroundColor,
      'text_enhance_mode': textEnhanceMode,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// 创建副本
  DocumentSettings copyWith({
    String? documentId,
    String? backgroundImagePath,
    int? backgroundColor,
    int? textEnhanceMode,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DocumentSettings(
      documentId: documentId ?? this.documentId,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textEnhanceMode: textEnhanceMode ?? this.textEnhanceMode,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DocumentSettings &&
        other.documentId == documentId &&
        other.backgroundImagePath == backgroundImagePath &&
        other.backgroundColor == backgroundColor &&
        other.textEnhanceMode == textEnhanceMode &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      documentId,
      backgroundImagePath,
      backgroundColor,
      textEnhanceMode,
      createdAt,
      updatedAt,
    );
  }

  @override
  String toString() {
    return 'DocumentSettings(documentId: $documentId, backgroundImagePath: $backgroundImagePath, backgroundColor: $backgroundColor, textEnhanceMode: $textEnhanceMode, createdAt: $createdAt, updatedAt: $updatedAt)';
  }
}