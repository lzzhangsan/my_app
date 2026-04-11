import 'dart:io';

import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../media_preview_page.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../services/database_service.dart';

/// 打开 [MediaPreviewPage] 调整背景图/背景视频的取景（与媒体库一致），非媒体库路径时写 [background_file_view_params]。
Future<void> pushBackgroundMediaAdjustPage(
  BuildContext context,
  File file,
  MediaType mediaType,
) async {
  final db = getService<DatabaseService>();
  final mediaMap = await db.getMediaItemByFilePath(file.path);
  final typeIdx = mediaType == MediaType.video
      ? MediaType.video.index
      : MediaType.image.index;
  final previewItem =
      mediaMap != null
          ? MediaItem.fromMap(mediaMap)
          : MediaItem.fromMap({
              'id': 'background_preview_temp',
              'name':
                  file.uri.pathSegments.isNotEmpty
                      ? file.uri.pathSegments.last
                      : 'bg',
              'path': file.path,
              'type': typeIdx,
              'directory': '__background_preview__',
              'date_added': DateTime.now().toIso8601String(),
            });
  if (!context.mounted) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => MediaPreviewPage(
        mediaItems: [previewItem],
        initialIndex: 0,
        standaloneBackgroundFilePath: mediaMap == null ? file.path : null,
      ),
    ),
  );
}
