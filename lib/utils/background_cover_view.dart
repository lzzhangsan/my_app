import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/service_locator.dart';
import '../models/video_view_params.dart';
import '../services/database_service.dart';
import '../services/logger.dart';
import '../widgets/image_layout_utils.dart';

/// 读取视频像素尺寸（用完即释放控制器）。
Future<Size?> measureVideoFileSize(File file) async {
  final controller = VideoPlayerController.file(file);
  try {
    await controller.initialize();
    final size = controller.value.size;
    if (size.width <= 1 || size.height <= 1) return null;
    return size;
  } catch (e) {
    Logger.log('measureVideoFileSize 失败: $e');
    return null;
  } finally {
    await controller.dispose();
  }
}

/// 背景默认取景：等比放大至铺满屏幕（cover），居中裁切最少、无拉伸。
///
/// 图片层基底为 fitWidth，视频层基底为 contain，与
/// [StoredViewImageLayer] / [StoredViewVideoBackgroundLayer] 一致。
VideoViewParams computeBackgroundCoverViewParams({
  required Size mediaPixelSize,
  required Size viewport,
  required bool isVideo,
}) {
  final vw = viewport.width;
  final vh = viewport.height;
  if (vw <= 1 ||
      vh <= 1 ||
      mediaPixelSize.width <= 1 ||
      mediaPixelSize.height <= 1) {
    return const VideoViewParams();
  }

  final Size base =
      isVideo
          ? containDisplaySize(mediaPixelSize, vw, vh)
          : fitWidthDisplaySize(mediaPixelSize, vw);

  final scaleW = base.width > 1 ? vw / base.width : 1.0;
  final scaleH = base.height > 1 ? vh / base.height : 1.0;
  final targetScale = (scaleW > scaleH ? scaleW : scaleH).clamp(1.0, 6.0);

  return VideoViewParams(
    scale: targetScale,
    txNorm: 0.0,
    tyNorm: 0.0,
    quarterTurns: 0,
    basisW: vw,
    basisH: vh,
  );
}

/// 测量媒体尺寸并写入 [background_file_view_params]，供背景层立刻套用。
///
/// 须在展示该路径的 [setState] **之前**调用，避免 FutureBuilder 先读到默认参数。
Future<void> applyBackgroundCoverViewParams({
  required BuildContext context,
  required String filePath,
  required bool isVideo,
}) async {
  if (filePath.isEmpty) return;
  final viewport = MediaQuery.sizeOf(context);
  try {
    final Size mediaSize;
    if (isVideo) {
      final measured = await measureVideoFileSize(File(filePath));
      if (measured == null) return;
      mediaSize = measured;
    } else {
      mediaSize = await measureImageFileSize(File(filePath));
    }
    final params = computeBackgroundCoverViewParams(
      mediaPixelSize: mediaSize,
      viewport: viewport,
      isVideo: isVideo,
    );
    await getService<DatabaseService>().upsertVideoViewParamsForFilePath(
      filePath,
      params,
    );
  } catch (e) {
    Logger.log('applyBackgroundCoverViewParams 失败 ($filePath): $e');
  }
}
