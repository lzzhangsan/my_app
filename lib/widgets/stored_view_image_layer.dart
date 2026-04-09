import 'dart:io';

import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../models/video_view_params.dart';
import '../services/database_service.dart';
import 'fit_width_blur_static_image.dart';
import 'image_interactive_surface.dart';
import 'image_layout_utils.dart' show ImageLetterboxFill;

/// 套用媒体库中为该文件保存的 `video_view_*`（路径一致或内容 MD5 与库中记录一致）。
/// 用于文档/目录/日记封面等背景及文档内图片框，与媒体页、文档栏播放器只读展示一致。
class StoredViewImageLayer extends StatefulWidget {
  const StoredViewImageLayer({
    super.key,
    required this.file,
    this.useScreenSizeForNormalization = false,
    this.readonlyTranslateYOffset = 0,
    this.useCacheWidth = true,
  });

  final File file;
  final bool useScreenSizeForNormalization;
  final double readonlyTranslateYOffset;
  final bool useCacheWidth;

  @override
  State<StoredViewImageLayer> createState() => _StoredViewImageLayerState();
}

class _StoredViewImageLayerState extends State<StoredViewImageLayer> {
  late Future<VideoViewParams> _paramsFuture;

  @override
  void initState() {
    super.initState();
    _paramsFuture = _loadParams();
  }

  @override
  void didUpdateWidget(covariant StoredViewImageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _paramsFuture = _loadParams();
    }
  }

  Future<VideoViewParams> _loadParams() {
    return getService<DatabaseService>().getVideoViewParamsForMediaFilePath(
      widget.file.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<VideoViewParams>(
      future: _paramsFuture,
      builder: (context, snapshot) {
        final p = snapshot.data ?? const VideoViewParams();
        final sideways = p.quarterTurns % 2 == 1;
        return ImageInteractiveSurface(
          key: ValueKey('svil_${widget.file.path}_${p.hashCode}'),
          initial: p,
          editable: false,
          useScreenSizeForNormalization: widget.useScreenSizeForNormalization,
          readonlyTranslateYOffset: widget.readonlyTranslateYOffset,
          child: FitWidthBlurStaticImage(
            file: widget.file,
            letterboxFill: ImageLetterboxFill.transparent,
            fitContainInViewport: sideways,
            useCacheWidth: widget.useCacheWidth,
          ),
        );
      },
    );
  }
}
