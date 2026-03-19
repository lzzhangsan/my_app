// lib/models/flippable_canvas.dart
// 可翻转画布数据模型

class FlippableCanvas {
  final String id;
  final String documentName;
  double positionX;
  double positionY;
  double width;
  double height;
  bool isFlipped; // true表示显示反面，false表示显示正面
  
  // 正面内容
  List<String> frontTextBoxIds;
  List<String> frontImageBoxIds;
  List<String> frontAudioBoxIds;
  
  // 反面内容
  List<String> backTextBoxIds;
  List<String> backImageBoxIds;
  List<String> backAudioBoxIds;

  FlippableCanvas({
    required this.id,
    required this.documentName,
    required this.positionX,
    required this.positionY,
    required this.width,
    required this.height,
    this.isFlipped = false,
    List<String>? frontTextBoxIds,
    List<String>? frontImageBoxIds,
    List<String>? frontAudioBoxIds,
    List<String>? backTextBoxIds,
    List<String>? backImageBoxIds,
    List<String>? backAudioBoxIds,
  }) : frontTextBoxIds = frontTextBoxIds ?? [],
       frontImageBoxIds = frontImageBoxIds ?? [],
       frontAudioBoxIds = frontAudioBoxIds ?? [],
       backTextBoxIds = backTextBoxIds ?? [],
       backImageBoxIds = backImageBoxIds ?? [],
       backAudioBoxIds = backAudioBoxIds ?? [];

  // 从Map创建对象
  factory FlippableCanvas.fromMap(Map<String, dynamic> map) {
    return FlippableCanvas(
      id: map['id'],
      documentName: map['document_name'] ?? map['documentName'] ?? '',
      positionX: (map['position_x'] ?? map['positionX'] ?? 0.0).toDouble(),
      positionY: (map['position_y'] ?? map['positionY'] ?? 0.0).toDouble(),
      width: (map['width'] ?? 300.0).toDouble(),
      height: (map['height'] ?? 200.0).toDouble(),
      isFlipped: (map['is_flipped'] ?? map['isFlipped'] ?? 0) == 1,
      frontTextBoxIds: _parseStringList(map['front_text_box_ids']),
      frontImageBoxIds: _parseStringList(map['front_image_box_ids']),
      frontAudioBoxIds: _parseStringList(map['front_audio_box_ids']),
      backTextBoxIds: _parseStringList(map['back_text_box_ids']),
      backImageBoxIds: _parseStringList(map['back_image_box_ids']),
      backAudioBoxIds: _parseStringList(map['back_audio_box_ids']),
    );
  }

  // 转换为Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'document_name': documentName,
      'position_x': positionX,
      'position_y': positionY,
      'width': width,
      'height': height,
      'is_flipped': isFlipped ? 1 : 0,
      'front_text_box_ids': _stringListToString(frontTextBoxIds),
      'front_image_box_ids': _stringListToString(frontImageBoxIds),
      'front_audio_box_ids': _stringListToString(frontAudioBoxIds),
      'back_text_box_ids': _stringListToString(backTextBoxIds),
      'back_image_box_ids': _stringListToString(backImageBoxIds),
      'back_audio_box_ids': _stringListToString(backAudioBoxIds),
    };
  }

  // 翻转画布
  void flip() {
    isFlipped = !isFlipped;
  }

  // 获取当前面的内容ID列表
  List<String> getCurrentTextBoxIds() {
    return isFlipped ? backTextBoxIds : frontTextBoxIds;
  }

  List<String> getCurrentImageBoxIds() {
    return isFlipped ? backImageBoxIds : frontImageBoxIds;
  }

  List<String> getCurrentAudioBoxIds() {
    return isFlipped ? backAudioBoxIds : frontAudioBoxIds;
  }

  // 向当前面添加内容
  void addTextBoxToCurrentSide(String textBoxId) {
    if (isFlipped) {
      if (!backTextBoxIds.contains(textBoxId)) {
        backTextBoxIds.add(textBoxId);
      }
    } else {
      if (!frontTextBoxIds.contains(textBoxId)) {
        frontTextBoxIds.add(textBoxId);
      }
    }
  }

  void addImageBoxToCurrentSide(String imageBoxId) {
    if (isFlipped) {
      if (!backImageBoxIds.contains(imageBoxId)) {
        backImageBoxIds.add(imageBoxId);
      }
    } else {
      if (!frontImageBoxIds.contains(imageBoxId)) {
        frontImageBoxIds.add(imageBoxId);
      }
    }
  }

  void addAudioBoxToCurrentSide(String audioBoxId) {
    if (isFlipped) {
      if (!backAudioBoxIds.contains(audioBoxId)) {
        backAudioBoxIds.add(audioBoxId);
      }
    } else {
      if (!frontAudioBoxIds.contains(audioBoxId)) {
        frontAudioBoxIds.add(audioBoxId);
      }
    }
  }

  // 从指定面移除内容
  void removeTextBoxFromSide(String textBoxId, {bool fromBack = false}) {
    if (fromBack) {
      backTextBoxIds.remove(textBoxId);
    } else {
      frontTextBoxIds.remove(textBoxId);
    }
  }

  void removeImageBoxFromSide(String imageBoxId, {bool fromBack = false}) {
    if (fromBack) {
      backImageBoxIds.remove(imageBoxId);
    } else {
      frontImageBoxIds.remove(imageBoxId);
    }
  }

  void removeAudioBoxFromSide(String audioBoxId, {bool fromBack = false}) {
    if (fromBack) {
      backAudioBoxIds.remove(audioBoxId);
    } else {
      frontAudioBoxIds.remove(audioBoxId);
    }
  }

  // 检查内容是否属于画布
  bool containsTextBox(String textBoxId) {
    return frontTextBoxIds.contains(textBoxId) || backTextBoxIds.contains(textBoxId);
  }

  bool containsImageBox(String imageBoxId) {
    return frontImageBoxIds.contains(imageBoxId) || backImageBoxIds.contains(imageBoxId);
  }

  bool containsAudioBox(String audioBoxId) {
    return frontAudioBoxIds.contains(audioBoxId) || backAudioBoxIds.contains(audioBoxId);
  }

  // 私有辅助方法：解析字符串列表
  static List<String> _parseStringList(dynamic value) {
    if (value == null || value == '') return [];
    if (value is String) {
      return value.split(',').where((s) => s.isNotEmpty).toList();
    }
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return [];
  }

  // 私有辅助方法：字符串列表转字符串
  static String _stringListToString(List<String> list) {
    return list.join(',');
  }

  // 复制画布
  FlippableCanvas copy() {
    return FlippableCanvas(
      id: id,
      documentName: documentName,
      positionX: positionX,
      positionY: positionY,
      width: width,
      height: height,
      isFlipped: isFlipped,
      frontTextBoxIds: List<String>.from(frontTextBoxIds),
      frontImageBoxIds: List<String>.from(frontImageBoxIds),
      frontAudioBoxIds: List<String>.from(frontAudioBoxIds),
      backTextBoxIds: List<String>.from(backTextBoxIds),
      backImageBoxIds: List<String>.from(backImageBoxIds),
      backAudioBoxIds: List<String>.from(backAudioBoxIds),
    );
  }
}