import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class ImagePickerService {
  static Future<String?> pickImage(BuildContext context) async {
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

    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickImage(
        source: source as ImageSource,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        return null;
      }

      // 获取应用文档目录
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final savedImage = File('${appDir.path}/images/$fileName');

      // 确保目录存在
      await savedImage.parent.create(recursive: true);
      
      // 复制图片到应用目录
      await File(pickedFile.path).copy(savedImage.path);
      
      return savedImage.path;
    } catch (e) {
      print('选择图片时出错: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片时出错，请重试\n${e.toString()}')),
        );
      }
      return null;
    }
  }

  static Future<String?> pickVideo(BuildContext context) async {
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
    try {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickVideo(source: source as ImageSource);
      if (pickedFile == null) return null;
      final appDir = await getApplicationDocumentsDirectory();
      final fileName = '${DateTime.now().millisecondsSinceEpoch}.mp4';
      final savedVideo = File('${appDir.path}/videos/$fileName');
      await savedVideo.parent.create(recursive: true);
      await File(pickedFile.path).copy(savedVideo.path);
      return savedVideo.path;
    } catch (e) {
      print('选择视频时出错: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择视频时出错，请重试\n${e.toString()}')),
        );
      }
      return null;
    }
  }
} 