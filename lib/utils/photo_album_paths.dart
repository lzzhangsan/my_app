import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

/// 获取「相册」列表供批量导入、自动导入、后台监听使用。
///
/// Android：数据来自系统 [MediaStore](https://developer.android.com/reference/android/provider/MediaStore)
/// 的 bucket（与系统相册、绝大多数应用一致），**不是**遍历磁盘上的每一个物理文件夹。
/// 未编入媒体索引的文件（例如刚复制进设备尚未扫描）在任意相册里都可能暂时看不到。
///
/// 使用 [RequestType.common] + `hasAll: true` 列出「全部」及各 bucket；并在 Android 上合并
/// 纯图 / 纯视频查询中多出来的 bucket，再解析为 [RequestType.common]，避免单类型 [AssetPathEntity]
/// 在点进相册时只显示图或只显示视频。
Future<List<AssetPathEntity>> getMergedAlbumPathListForImport() async {
  final common = await PhotoManager.getAssetPathList(
    hasAll: true,
    onlyAll: false,
    type: RequestType.common,
  );
  if (!Platform.isAndroid) {
    return common;
  }
  final imageOnly = await PhotoManager.getAssetPathList(
    hasAll: false,
    onlyAll: false,
    type: RequestType.image,
  );
  final videoOnly = await PhotoManager.getAssetPathList(
    hasAll: false,
    onlyAll: false,
    type: RequestType.video,
  );
  final seen = {for (final p in common) p.id};
  final out = List<AssetPathEntity>.from(common);
  for (final p in <AssetPathEntity>[...imageOnly, ...videoOnly]) {
    if (seen.contains(p.id)) continue;
    try {
      final resolved = await AssetPathEntity.obtainPathFromProperties(
        id: p.id,
        type: RequestType.common,
      );
      seen.add(p.id);
      out.add(resolved);
    } catch (e) {
      debugPrint('合并相册 bucket ${p.id} 时无法以 common 解析，已跳过: $e');
    }
  }
  return out;
}
