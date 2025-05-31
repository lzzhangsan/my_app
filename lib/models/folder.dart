// lib/models/folder.dart
// 文件夹模型 - 提供类型安全的数据结构

import 'package:flutter/foundation.dart';

/// 文件夹模型
@immutable
class Folder {
  final String id;
  final String name;
  final String? parentFolder;
  final int orderIndex;
  final String? position;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Folder({
    required this.id,
    required this.name,
    this.parentFolder,
    this.orderIndex = 0,
    this.position,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 从数据库映射创建文件夹
  factory Folder.fromMap(Map<String, dynamic> map) {
    return Folder(
      id: map['id'] as String,
      name: map['name'] as String,
      parentFolder: map['parent_folder'] as String?,
      orderIndex: map['order_index'] as int? ?? 0,
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
      'position': position,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  /// 创建副本
  Folder copyWith({
    String? id,
    String? name,
    String? parentFolder,
    int? orderIndex,
    String? position,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Folder(
      id: id ?? this.id,
      name: name ?? this.name,
      parentFolder: parentFolder ?? this.parentFolder,
      orderIndex: orderIndex ?? this.orderIndex,
      position: position ?? this.position,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 检查是否为根文件夹
  bool get isRoot => parentFolder == null;

  /// 获取文件夹路径
  String getPath(List<Folder> allFolders) {
    if (isRoot) return name;
    
    final parent = allFolders.firstWhere(
      (folder) => folder.id == parentFolder,
      orElse: () => throw StateError('Parent folder not found'),
    );
    
    return '${parent.getPath(allFolders)}/$name';
  }

  /// 检查是否为指定文件夹的子文件夹
  bool isChildOf(String folderId, List<Folder> allFolders) {
    if (parentFolder == null) return false;
    if (parentFolder == folderId) return true;
    
    final parent = allFolders.firstWhere(
      (folder) => folder.id == parentFolder,
      orElse: () => throw StateError('Parent folder not found'),
    );
    
    return parent.isChildOf(folderId, allFolders);
  }

  /// 获取所有子文件夹
  List<Folder> getChildren(List<Folder> allFolders) {
    return allFolders.where((folder) => folder.parentFolder == id).toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  /// 获取文件夹深度
  int getDepth(List<Folder> allFolders) {
    if (isRoot) return 0;
    
    final parent = allFolders.firstWhere(
      (folder) => folder.id == parentFolder,
      orElse: () => throw StateError('Parent folder not found'),
    );
    
    return parent.getDepth(allFolders) + 1;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Folder &&
        other.id == id &&
        other.name == name &&
        other.parentFolder == parentFolder &&
        other.orderIndex == orderIndex &&
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
      position,
      createdAt,
      updatedAt,
    );
  }

  @override
  String toString() {
    return 'Folder(id: $id, name: $name, parentFolder: $parentFolder, orderIndex: $orderIndex, position: $position, createdAt: $createdAt, updatedAt: $updatedAt)';
  }
}