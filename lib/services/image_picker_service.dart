import 'package:flutter/material.dart';
import 'logger.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../widgets/media_library_image_picker.dart';
import '../widgets/media_library_video_picker.dart';
import '../models/background_media_origin.dart';

/// 带来源信息的选图/选视频结果（用于背景等媒体策略）。
class PickedMedia {
  const PickedMedia({required this.path, required this.origin});
  final String path;
  final BackgroundMediaOrigin origin;
}

class ImagePickerService {
  static Future<PickedMedia?> pickImage(BuildContext context) async {
    final source = await showDialog<dynamic>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text('选择图片来源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.camera_alt, color: Colors.blue),
                title: Text('拍照'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
              ListTile(
                leading: Icon(Icons.photo_library, color: Colors.green),
                title: Text('相册'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              ListTile(
                leading: Icon(Icons.folder, color: Colors.orange),
                title: Text('媒体库'),
                onTap: () => Navigator.of(context).pop('media_library'),
              ),
              SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text('取消'),
              ),
            ],
          ),
        );
      },
    );

    if (source == null) {
      return null;
    }

    if (source == 'media_library') {
      final selectedImagePath = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => MediaLibraryImagePicker(
          onImageSelected: (String imagePath) {
            Navigator.of(context).pop(imagePath);
          },
        ),
      );
      if (selectedImagePath == null || selectedImagePath.isEmpty) {
        return null;
      }
      return PickedMedia(
        path: selectedImagePath,
        origin: BackgroundMediaOrigin.mediaLibrary,
      );
    }

    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickImage(
        source: source as ImageSource,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        return null;
      }

      final appDir = await getApplicationDocumentsDirectory();
      final subDir =
          source == ImageSource.camera ? 'camera' : 'gallery';
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedImage = File('${appDir.path}/images/$subDir/$fileName');

      await savedImage.parent.create(recursive: true);
      await File(pickedFile.path).copy(savedImage.path);

      return PickedMedia(
        path: savedImage.path,
        origin:
            source == ImageSource.camera
                ? BackgroundMediaOrigin.camera
                : BackgroundMediaOrigin.gallery,
      );
    } catch (e) {
      Logger.log('选择图片时出错: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片时出错，请重试\n${e.toString()}')),
        );
      }
      return null;
    }
  }

  static Future<PickedMedia?> pickVideo(BuildContext context) async {
    final source = await showDialog<dynamic>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: Text('选择视频来源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.videocam, color: Colors.blue),
                title: Text('拍摄'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
              ListTile(
                leading: Icon(Icons.video_library, color: Colors.green),
                title: Text('相册'),
                onTap: () => Navigator.of(context).pop(ImageSource.gallery),
              ),
              ListTile(
                leading: Icon(Icons.folder, color: Colors.orange),
                title: Text('媒体库'),
                onTap: () => Navigator.of(context).pop('media_library'),
              ),
              SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text('取消'),
              ),
            ],
          ),
        );
      },
    );
    if (source == null) return null;

    if (source == 'media_library') {
      final selectedPath = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder:
            (context) => MediaLibraryVideoPicker(
              onVideoSelected: (String p) {
                Navigator.of(context).pop(p);
              },
            ),
      );
      if (selectedPath == null || selectedPath.isEmpty) return null;
      return PickedMedia(
        path: selectedPath,
        origin: BackgroundMediaOrigin.mediaLibrary,
      );
    }

    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickVideo(
        source: source as ImageSource,
      );
      if (pickedFile == null) return null;
      final appDir = await getApplicationDocumentsDirectory();
      final subDir =
          source == ImageSource.camera ? 'camera' : 'gallery';
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.mp4';
      final savedVideo = File('${appDir.path}/videos/$subDir/$fileName');
      await savedVideo.parent.create(recursive: true);
      await File(pickedFile.path).copy(savedVideo.path);
      return PickedMedia(
        path: savedVideo.path,
        origin:
            source == ImageSource.camera
                ? BackgroundMediaOrigin.camera
                : BackgroundMediaOrigin.gallery,
      );
    } catch (e) {
      Logger.log('选择视频时出错: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择视频时出错，请重试\n${e.toString()}')),
        );
      }
      return null;
    }
  }
}
