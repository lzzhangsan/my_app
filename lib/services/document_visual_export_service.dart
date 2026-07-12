import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image_lib;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:screenshot/screenshot.dart';

import '../models/flippable_canvas.dart';
import '../resizable_and_configurable_text_box.dart';
import 'database_service.dart';

enum DocumentVisualExportFormat { images, pdf }

class DocumentVisualExportService {
  DocumentVisualExportService(this._databaseService);

  final DatabaseService _databaseService;
  final ScreenshotController _screenshotController = ScreenshotController();

  Future<List<String>> export(
    BuildContext context,
    String documentName,
    DocumentVisualExportFormat format,
  ) async {
    final textBoxes = await _databaseService.getTextBoxesByDocument(
      documentName,
    );
    final imageBoxes = await _databaseService.getImageBoxesByDocument(
      documentName,
    );
    final audioBoxes = await _databaseService.getAudioBoxesByDocument(
      documentName,
    );
    final canvasRows = await _databaseService.getCanvasesByDocument(
      documentName,
    );
    final settings = await _databaseService.getDocumentSettings(documentName);
    final canvases = canvasRows.map(FlippableCanvas.fromMap).toList();

    final hiddenIds = <String>{};
    for (final canvas in canvases) {
      hiddenIds.addAll(
        canvas.isFlipped ? canvas.frontTextBoxIds : canvas.backTextBoxIds,
      );
      hiddenIds.addAll(
        canvas.isFlipped ? canvas.frontImageBoxIds : canvas.backImageBoxIds,
      );
      hiddenIds.addAll(
        canvas.isFlipped ? canvas.frontAudioBoxIds : canvas.backAudioBoxIds,
      );
    }

    final visibleText =
        textBoxes
            .where((box) => !hiddenIds.contains(box['id']?.toString()))
            .toList();
    final visibleImages =
        imageBoxes
            .where((box) => !hiddenIds.contains(box['id']?.toString()))
            .toList();
    final visibleAudio =
        audioBoxes
            .where((box) => !hiddenIds.contains(box['id']?.toString()))
            .toList();

    await _precacheImages(context, visibleImages, settings);

    final pageWidth = MediaQuery.sizeOf(context).width;
    final pageHeight = pageWidth * 1.4142;
    final contentBottom = _contentBottom(
      visibleText,
      visibleImages,
      visibleAudio,
      canvases,
    );
    final pageCount = math.max(1, (contentBottom / pageHeight).ceil());
    final pages = <Uint8List>[];

    for (var page = 0; page < pageCount; page++) {
      final widget = _buildPage(
        width: pageWidth,
        height: pageHeight,
        pageTop: page * pageHeight,
        textBoxes: visibleText,
        imageBoxes: visibleImages,
        audioBoxes: visibleAudio,
        canvases: canvases,
        settings: settings,
      );
      pages.add(
        await _screenshotController.captureFromWidget(
          widget,
          context: context,
          targetSize: Size(pageWidth, pageHeight),
          pixelRatio: 2,
          delay: const Duration(milliseconds: 80),
        ),
      );
    }

    final tempDirectory = await getTemporaryDirectory();
    final safeName = documentName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;

    if (format == DocumentVisualExportFormat.images) {
      final outputPath = path.join(
        tempDirectory.path,
        '${safeName}_$stamp.png',
      );
      final longImage = _stitchPages(
        pages,
        logicalPageWidth: pageWidth,
        logicalContentHeight: contentBottom,
      );
      await File(outputPath).writeAsBytes(longImage, flush: true);
      return [outputPath];
    }

    final document = pw.Document();
    for (final pageBytes in pages) {
      final image = pw.MemoryImage(pageBytes);
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build:
              (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ),
      );
    }
    final outputPath = path.join(tempDirectory.path, '${safeName}_$stamp.pdf');
    await File(outputPath).writeAsBytes(await document.save(), flush: true);
    return [outputPath];
  }

  Uint8List _stitchPages(
    List<Uint8List> pages, {
    required double logicalPageWidth,
    required double logicalContentHeight,
  }) {
    if (pages.isEmpty) {
      throw StateError('文档图片生成失败');
    }
    final firstPage = image_lib.decodePng(pages.first);
    if (firstPage == null) throw StateError('文档图片生成失败');

    final width = firstPage.width;
    final scale = width / logicalPageWidth;
    final fullHeight = firstPage.height * pages.length;
    final contentHeight = (logicalContentHeight * scale).ceil().clamp(
      1,
      fullHeight,
    );
    final result = image_lib.Image(
      width: width,
      height: contentHeight,
      numChannels: 4,
    );
    var destinationY = 0;
    for (var index = 0; index < pages.length; index++) {
      if (destinationY >= contentHeight) break;
      final page = index == 0 ? firstPage : image_lib.decodePng(pages[index]);
      if (page == null) throw StateError('文档图片生成失败');
      image_lib.compositeImage(result, page, dstY: destinationY);
      destinationY += page.height;
    }
    return Uint8List.fromList(image_lib.encodePng(result, level: 6));
  }

  Future<void> _precacheImages(
    BuildContext context,
    List<Map<String, dynamic>> imageBoxes,
    Map<String, dynamic>? settings,
  ) async {
    final paths = <String>{
      if (settings?['background_image_path'] != null)
        settings!['background_image_path'].toString(),
      for (final box in imageBoxes)
        if (box['imagePath'] != null) box['imagePath'].toString(),
    };
    for (final imagePath in paths) {
      final file = File(imagePath);
      if (!file.existsSync()) continue;
      try {
        await precacheImage(FileImage(file), context);
      } catch (_) {
        // Missing or damaged images are represented by placeholders on export.
      }
    }
  }

  double _contentBottom(
    List<Map<String, dynamic>> textBoxes,
    List<Map<String, dynamic>> imageBoxes,
    List<Map<String, dynamic>> audioBoxes,
    List<FlippableCanvas> canvases,
  ) {
    var bottom = 0.0;
    for (final box in textBoxes) {
      bottom = math.max(
        bottom,
        _number(box['positionY']) + _number(box['height'], 100),
      );
    }
    for (final box in imageBoxes) {
      bottom = math.max(
        bottom,
        _number(box['positionY']) + _number(box['height'], 200),
      );
    }
    for (final box in audioBoxes) {
      bottom = math.max(bottom, _number(box['positionY']) + 48);
    }
    for (final canvas in canvases) {
      bottom = math.max(bottom, canvas.positionY + canvas.height);
    }
    return bottom + 24;
  }

  Widget _buildPage({
    required double width,
    required double height,
    required double pageTop,
    required List<Map<String, dynamic>> textBoxes,
    required List<Map<String, dynamic>> imageBoxes,
    required List<Map<String, dynamic>> audioBoxes,
    required List<FlippableCanvas> canvases,
    required Map<String, dynamic>? settings,
  }) {
    final colorValue = settings?['background_color'] as int?;
    final backgroundColor =
        colorValue == null ? Colors.white : Color(colorValue);
    final backgroundPath = settings?['background_image_path']?.toString();

    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: backgroundColor)),
              if (backgroundPath != null && File(backgroundPath).existsSync())
                Positioned.fill(
                  child: Image.file(File(backgroundPath), fit: BoxFit.cover),
                ),
              Transform.translate(
                offset: Offset(0, -pageTop),
                child: SizedBox(
                  width: width,
                  height: pageTop + height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final canvas in canvases) _buildCanvas(canvas),
                      for (final box in imageBoxes) _buildImageBox(box),
                      for (final box in textBoxes) _buildTextBox(box),
                      for (final box in audioBoxes) _buildAudioBox(box),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas(FlippableCanvas canvas) {
    return Positioned(
      left: canvas.positionX,
      top: canvas.positionY,
      width: canvas.width,
      height: canvas.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          border: Border.all(color: Colors.grey.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }

  Widget _buildImageBox(Map<String, dynamic> box) {
    final imagePath = box['imagePath']?.toString();
    final file = imagePath == null ? null : File(imagePath);
    return Positioned(
      left: _number(box['positionX']),
      top: _number(box['positionY']),
      width: _number(box['width'], 200),
      height: _number(box['height'], 200),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child:
            file != null && file.existsSync()
                ? Image.file(file, fit: BoxFit.cover)
                : const ColoredBox(
                  color: Color(0xFFE0E0E0),
                  child: Icon(Icons.broken_image_outlined, color: Colors.grey),
                ),
      ),
    );
  }

  Widget _buildTextBox(Map<String, dynamic> box) {
    final defaultStyle = CustomTextStyle(
      fontSize: _number(box['fontSize'], 16),
      fontColor: Color((box['fontColor'] as int?) ?? Colors.black.toARGB32()),
      fontWeight:
          FontWeight.values[((box['fontWeight'] as int?) ??
                  FontWeight.normal.index)
              .clamp(0, FontWeight.values.length - 1)],
      isItalic: box['isItalic'] == true || box['isItalic'] == 1,
      backgroundColor:
          box['backgroundColor'] == null
              ? null
              : Color(box['backgroundColor'] as int),
      textAlign:
          TextAlign.values[((box['textAlign'] as int?) ?? 0).clamp(
            0,
            TextAlign.values.length - 1,
          )],
    );
    final rawSegments = box['textSegments'];
    final segments = <TextSegment>[];
    if (rawSegments is List) {
      for (final raw in rawSegments) {
        if (raw is Map) {
          try {
            segments.add(TextSegment.fromMap(Map<String, dynamic>.from(raw)));
          } catch (_) {}
        }
      }
    }
    if (segments.isEmpty) {
      segments.add(
        TextSegment(text: box['text']?.toString() ?? '', style: defaultStyle),
      );
    }

    return Positioned(
      left: _number(box['positionX']),
      top: _number(box['positionY']),
      width: _number(box['width'], 200),
      height: _number(box['height'], 100),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 1),
          borderRadius: BorderRadius.circular(10),
          color: defaultStyle.backgroundColor,
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFD2B48C).withValues(alpha: 0.2),
              blurRadius: 3.5,
              spreadRadius: 0.3,
              offset: const Offset(1, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.all(5),
        child: RichText(
          overflow: TextOverflow.clip,
          textAlign: defaultStyle.textAlign,
          text: TextSpan(
            children: [
              for (final segment in segments)
                TextSpan(
                  text: segment.text,
                  style: _flutterTextStyle(segment.style),
                ),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle _flutterTextStyle(CustomTextStyle style) {
    final outline =
        style.fontColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    const offsets = [
      Offset(-1, -1),
      Offset(-1, 0),
      Offset(-1, 1),
      Offset(0, -1),
      Offset(0, 1),
      Offset(1, -1),
      Offset(1, 0),
      Offset(1, 1),
    ];
    return TextStyle(
      fontSize: style.fontSize,
      color: style.fontColor,
      fontWeight: style.fontWeight,
      fontStyle: style.isItalic ? FontStyle.italic : FontStyle.normal,
      backgroundColor: style.backgroundColor,
      height: 1.23,
      shadows: [
        for (final offset in offsets) Shadow(offset: offset, color: outline),
      ],
    );
  }

  Widget _buildAudioBox(Map<String, dynamic> box) {
    final audioPath = box['audioPath']?.toString() ?? '';
    return Positioned(
      left: _number(box['positionX']),
      top: _number(box['positionY']),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey.shade400),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.audiotrack, size: 20, color: Colors.deepOrange),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                path.basename(audioPath).isEmpty
                    ? '语音'
                    : path.basename(audioPath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _number(dynamic value, [double fallback = 0]) {
    return value is num ? value.toDouble() : fallback;
  }
}
