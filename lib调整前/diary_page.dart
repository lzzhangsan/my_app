import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'models/diary_entry.dart';
import 'services/diary_service.dart';
import 'package:uuid/uuid.dart';
import 'resizable_audio_box.dart';
import 'services/image_picker_service.dart';
import 'resizable_image_box.dart';
import 'dart:io';
import 'package:flutter_svg/flutter_svg.dart';
import 'widgets/video_player_widget.dart';
import 'services/media_service.dart';
import 'dart:ui';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'services/database_service.dart';
import 'core/service_locator.dart';

// 全局函数：显示进度条弹窗，支持取消操作
void showProgressDialog(BuildContext context, ValueNotifier<double> progress, ValueNotifier<String> message, {bool barrierDismissible = false}) {
  showDialog(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, child) => LinearProgressIndicator(value: value),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: message,
            builder: (context, value, child) => Text(value),
          ),
        ],
      ),
      actions: barrierDismissible ? [TextButton(onPressed: () => Navigator.pop(context), child: Text('取消'))] : null,
    ),
  );
}

class DiaryPage extends StatefulWidget {
  const DiaryPage({super.key});

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  final DiaryService _diaryService = DiaryService();
  List<DiaryEntry> _entries = [];
  DateTime _selectedDate = DateTime.now();
  String _searchKeyword = '';
  bool _showFavoritesOnly = false;
  bool _calendarExpanded = false;

  // 新增：日记本背景图片和颜色
  File? _diaryBgImage;
  Color? _diaryBgColor;

  @override
  void initState() {
    super.initState();
    _loadEntries();
    _loadDiarySettings();
  }

  Future<void> _loadDiarySettings() async {
    final db = getService<DatabaseService>();
    final settings = await db.getDiarySettings();
    if (mounted) {
      setState(() {
        if (settings != null) {
          final imagePath = settings['background_image_path'] as String?;
          final colorValue = settings['background_color'] as int?;
          if (imagePath != null && imagePath.isNotEmpty && File(imagePath).existsSync()) {
            _diaryBgImage = File(imagePath);
          } else {
            _diaryBgImage = null;
          }
          if (colorValue != null) {
            _diaryBgColor = Color(colorValue);
          } else {
            _diaryBgColor = null;
          }
        } else {
          _diaryBgImage = null;
          _diaryBgColor = null;
        }
      });
    }
  }

  Future<void> _pickDiaryBackgroundImage() async {
    final imagePath = await ImagePickerService.pickImage(context);
    if (imagePath != null) {
      final appDir = await getApplicationDocumentsDirectory();
      final bgDir = Directory('${appDir.path}/diary_backgrounds');
      if (!await bgDir.exists()) await bgDir.create(recursive: true);
      final fileName = 'diary_bg_${DateTime.now().millisecondsSinceEpoch}${path.extension(imagePath)}';
      final destPath = '${bgDir.path}/$fileName';
      final newImage = await File(imagePath).copy(destPath);
      await getService<DatabaseService>().insertOrUpdateDiarySettings(imagePath: destPath, colorValue: _diaryBgColor?.value);
      setState(() {
        _diaryBgImage = newImage;
      });
    }
  }

  Future<void> _removeDiaryBackgroundImage() async {
    await getService<DatabaseService>().deleteDiaryBackgroundImage();
    setState(() {
      _diaryBgImage = null;
    });
  }

  Future<void> _pickDiaryBackgroundColor() async {
    Color tempColor = _diaryBgColor ?? Colors.white;
    final pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('选择背景颜色'),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: tempColor,
              onColorChanged: (Color color) {
                tempColor = color;
              },
              colorPickerWidth: 300.0,
              pickerAreaHeightPercent: 0.7,
              enableAlpha: false,
              displayThumbColor: true,
              paletteType: PaletteType.hsv,
            ),
          ),
          actions: [
            TextButton(child: Text('取消'), onPressed: () => Navigator.of(context).pop()),
            TextButton(child: Text('确定'), onPressed: () => Navigator.of(context).pop(tempColor)),
          ],
        );
      },
    );
    if (pickedColor != null) {
      await getService<DatabaseService>().insertOrUpdateDiarySettings(imagePath: _diaryBgImage?.path, colorValue: pickedColor.value);
      setState(() {
        _diaryBgColor = pickedColor;
      });
    }
  }

  Future<void> _loadEntries() async {
    final entries = await _diaryService.loadEntries();
    setState(() {
      _entries = entries;
    });
  }

  List<DiaryEntry> get _entriesForSelectedDate {
    final filtered = _showFavoritesOnly ? _entries.where((e) => e.isFavorite).toList() : _entries;
    if (_searchKeyword.isEmpty) return filtered..sort((a, b) => b.date.compareTo(a.date));
    
    // 尝试解析搜索关键词中的日期信息
    final dateSearchResult = _searchEntriesByDate(_searchKeyword, filtered);
    if (dateSearchResult.isNotEmpty) {
      return dateSearchResult..sort((a, b) => b.date.compareTo(a.date));
    }
    
    // 如果不是日期搜索，则按内容搜索
    return filtered.where((e) => (e.content ?? '').contains(_searchKeyword)).toList()..sort((a, b) => b.date.compareTo(a.date));
  }
  
  // 根据日期搜索日记条目
  List<DiaryEntry> _searchEntriesByDate(String keyword, List<DiaryEntry> entries) {
    // 移除所有空格
    final cleanKeyword = keyword.replaceAll(' ', '');
    
    // 匹配年份：2023年、2023
    final yearRegex = RegExp(r'(\d{4})(年)?$');
    final yearMatch = yearRegex.firstMatch(cleanKeyword);
    if (yearMatch != null) {
      final year = int.parse(yearMatch.group(1)!);
      return entries.where((e) => e.date.year == year).toList();
    }
    
    // 匹配年月：2023年5月、2023-5、2023.5、2023/5
    final yearMonthRegex = RegExp(r'(\d{4})[年\-\.\//](\d{1,2})(月)?$');
    final yearMonthMatch = yearMonthRegex.firstMatch(cleanKeyword);
    if (yearMonthMatch != null) {
      final year = int.parse(yearMonthMatch.group(1)!);
      final month = int.parse(yearMonthMatch.group(2)!);
      if (month >= 1 && month <= 12) {
        return entries.where((e) => e.date.year == year && e.date.month == month).toList();
      }
    }
    
    // 匹配年月日：2023年5月1日、2023-5-1、2023.5.1、2023/5/1
    final dateRegex = RegExp(r'(\d{4})[年\-\.\//](\d{1,2})[月\-\.\//](\d{1,2})(日)?$');
    final dateMatch = dateRegex.firstMatch(cleanKeyword);
    if (dateMatch != null) {
      final year = int.parse(dateMatch.group(1)!);
      final month = int.parse(dateMatch.group(2)!);
      final day = int.parse(dateMatch.group(3)!);
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return entries.where((e) => 
          e.date.year == year && 
          e.date.month == month && 
          e.date.day == day
        ).toList();
      }
    }
    
    // 匹配月日：5月1日、5-1、5.1、5/1
    final monthDayRegex = RegExp(r'^(\d{1,2})[月\-\.\//](\d{1,2})(日)?$');
    final monthDayMatch = monthDayRegex.firstMatch(cleanKeyword);
    if (monthDayMatch != null) {
      final month = int.parse(monthDayMatch.group(1)!);
      final day = int.parse(monthDayMatch.group(2)!);
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return entries.where((e) => e.date.month == month && e.date.day == day).toList();
      }
    }
    
    // 匹配月份：5月
    final monthRegex = RegExp(r'^(\d{1,2})(月)$');
    final monthMatch = monthRegex.firstMatch(cleanKeyword);
    if (monthMatch != null) {
      final month = int.parse(monthMatch.group(1)!);
      if (month >= 1 && month <= 12) {
        return entries.where((e) => e.date.month == month).toList();
      }
    }
    
    // 匹配日期：1日
    final dayRegex = RegExp(r'^(\d{1,2})(日)$');
    final dayMatch = dayRegex.firstMatch(cleanKeyword);
    if (dayMatch != null) {
      final day = int.parse(dayMatch.group(1)!);
      if (day >= 1 && day <= 31) {
        return entries.where((e) => e.date.day == day).toList();
      }
    }
    
    return [];
  }

  bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void _onDateSelected(DateTime date) {
    setState(() {
      _selectedDate = date;
    });
  }

  void _addOrEditEntry({DiaryEntry? entry}) async {
    final result = await Navigator.of(context).push<DiaryEntry>(
      MaterialPageRoute(
        builder: (context) => DiaryEditPage(entry: entry, date: _selectedDate),
      ),
    );
    if (result != null) {
      if (entry == null) {
        await _diaryService.addEntry(result);
      } else {
        await _diaryService.updateEntry(result);
      }
      _loadEntries();
    }
  }

  void _deleteEntry(DiaryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这条日记吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _diaryService.deleteEntry(entry.id);
      _loadEntries();
    }
  }

  void _toggleCalendar([bool? expand]) {
    setState(() {
      if (expand != null) {
        _calendarExpanded = expand;
      } else {
        _calendarExpanded = !_calendarExpanded;
      }
    });
  }

  void _showDiarySettings() {
    showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image),
              title: Text('设置背景图片'),
              onTap: () async {
                Navigator.pop(context);
                await _pickDiaryBackgroundImage();
              },
            ),
            ListTile(
              leading: Icon(Icons.color_lens),
              title: Text('设置背景颜色'),
              onTap: () async {
                Navigator.pop(context);
                await _pickDiaryBackgroundColor();
              },
            ),
            if (_diaryBgImage != null)
              ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('清除背景图片'),
                onTap: () async {
                  Navigator.pop(context);
                  await _removeDiaryBackgroundImage();
                },
              ),
            Divider(),
            ListTile(
              leading: Icon(Icons.upload_file),
              title: Text('导出日记本数据'),
              onTap: () {
                Navigator.pop(context);
                _exportDiaryData();
              },
            ),
            ListTile(
              leading: Icon(Icons.download_rounded),
              title: Text('导入日记本数据'),
              onTap: () {
                Navigator.pop(context);
                _importDiaryData();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 背景层：优先显示图片，其次颜色
        if (_diaryBgColor != null)
          Container(color: _diaryBgColor),
        if (_diaryBgImage != null)
          Positioned.fill(
            child: Image.file(_diaryBgImage!, fit: BoxFit.cover),
          ),
        // 主内容层
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            leading: IconButton(
              icon: Icon(Icons.settings),
              tooltip: '设置',
              onPressed: _showDiarySettings,
            ),
            title: const Text('日记本'),
            centerTitle: true,
            actions: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Text(
                  '${_entries.length}篇',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.blue,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(_showFavoritesOnly ? Icons.favorite : Icons.favorite_border, color: _showFavoritesOnly ? Colors.red : null),
                tooltip: _showFavoritesOnly ? '显示全部' : '只看收藏',
                onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
              ),
              IconButton(
                icon: _TodayCircleIcon(),
                tooltip: '回到今天',
                onPressed: () => setState(() => _selectedDate = DateTime.now()),
              ),
            ]
          ),
          body: Column(
            children: [
              GestureDetector(
                onVerticalDragUpdate: (details) {
                  if (details.delta.dy > 8) {
                    _toggleCalendar(true);
                  } else if (details.delta.dy < -8) {
                    _toggleCalendar(false);
                  }
                },
                child: AnimatedCrossFade(
                  duration: const Duration(milliseconds: 250),
                  crossFadeState: _calendarExpanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                  firstChild: _buildCalendar(full: true),
                  secondChild: _buildCalendar(full: false),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: TextField(
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索日记内容或日期(如2023年、5月1日)...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: EdgeInsets.symmetric(vertical: 0, horizontal: 8),
                  ),
                  onChanged: (value) => setState(() => _searchKeyword = value),
                ),
              ),
              Expanded(child: _buildDiaryList()),
            ],
          ),
          floatingActionButton: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Container(
                height: 48,
                width: 48,
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.15),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: FloatingActionButton(
                  onPressed: () => _addOrEditEntry(),
                  heroTag: 'addDiaryBtn',
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  focusElevation: 0,
                  hoverElevation: 0,
                  highlightElevation: 0,
                  splashColor: Colors.white.withOpacity(0.1),
                  child: Icon(
                    Icons.add,
                    size: 24,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCalendar({bool full = true}) {
    final now = DateTime.now();
    final firstDayOfMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    final lastDayOfMonth = DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
    final daysInMonth = lastDayOfMonth.day;
    final weekDayOffset = firstDayOfMonth.weekday % 7;
    final days = List.generate(daysInMonth, (i) => DateTime(_selectedDate.year, _selectedDate.month, i + 1));
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.keyboard_double_arrow_left, size: 28),
                      tooltip: '上一年',
                      onPressed: () => setState(() => _selectedDate = DateTime(_selectedDate.year - 1, _selectedDate.month, 1)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _onDateSelected(DateTime(_selectedDate.year, _selectedDate.month - 1, 1)),
                    ),
                  ],
                ),
                Text(full ? '${_selectedDate.year}年${_selectedDate.month}月' : '${_selectedDate.year}年${_selectedDate.month}月 ${_selectedDate.day}日', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _onDateSelected(DateTime(_selectedDate.year, _selectedDate.month + 1, 1)),
                    ),
                    IconButton(
                      icon: Icon(Icons.keyboard_double_arrow_right, size: 28),
                      tooltip: '下一年',
                      onPressed: () => setState(() => _selectedDate = DateTime(_selectedDate.year + 1, _selectedDate.month, 1)),
                    ),
                  ],
                ),
              ],
            ),
            if (full) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: const [
                  Text('日'), Text('一'), Text('二'), Text('三'), Text('四'), Text('五'), Text('六'),
                ],
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  childAspectRatio: 1.1,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                ),
                itemCount: weekDayOffset + days.length,
                itemBuilder: (context, index) {
                  if (index < weekDayOffset) {
                    return const SizedBox.shrink();
                  }
                  final day = days[index - weekDayOffset];
                  final isSelected = isSameDay(day, _selectedDate);
                  final hasEntry = _entries.any((e) => isSameDay(e.date, day));
                  return GestureDetector(
                    onTap: () => _onDateSelected(day),
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blueAccent : (hasEntry ? Colors.blue.withOpacity(0.2) : null),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          '${day.day}',
                          style: TextStyle(
                            fontSize: 14,
                            color: isSelected ? Colors.white : Colors.black87,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ] else ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(7, (index) {
                  final weekday = ['日', '一', '二', '三', '四', '五', '六'][index];
                  final isCurrentWeekday = (_selectedDate.weekday % 7) == index;
                  return Text(
                    weekday,
                    style: TextStyle(
                      color: isCurrentWeekday ? Colors.blue : Colors.black87,
                      fontWeight: isCurrentWeekday ? FontWeight.bold : FontWeight.normal,
                      fontSize: isCurrentWeekday ? 16 : 14,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiaryList() {
    final entries = _entriesForSelectedDate;
    if (entries.isEmpty) {
      return const Center(child: Text('这一天还没有日记，快来记录吧~'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ListTile(
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  DateFormat('yyyy年MM月dd日').format(entry.date),
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(entry.isFavorite ? Icons.favorite : Icons.favorite_border, color: entry.isFavorite ? Colors.red : null),
                      tooltip: entry.isFavorite ? '取消收藏' : '收藏',
                      onPressed: () async {
                        final updated = entry.copyWith(isFavorite: !entry.isFavorite);
                        await _diaryService.updateEntry(updated);
                        _loadEntries();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: '删除',
                      onPressed: () => _deleteEntry(entry),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ],
            ),
            subtitle: Text(entry.content ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
            leading: FutureBuilder<Widget>(
              future: _getEntryThumbnail(entry),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
                  return snapshot.data!;
                } else {
                  return const Icon(Icons.book, size: 40);
                }
              },
            ),
            trailing: null,
            onTap: () => _addOrEditEntry(entry: entry),
          ),
        );
      },
    );
  }

  // 获取日记条目的缩略图
  Future<Widget> _getEntryThumbnail(DiaryEntry entry) async {
    // 如果有图片，优先显示第一张图片
    if (entry.imagePaths.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(entry.imagePaths.first),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Icon(Icons.broken_image, size: 40),
        ),
      );
    }
    
    // 如果有视频，显示第一个视频的缩略图
    if (entry.videoPaths.isNotEmpty) {
      // 尝试获取视频缩略图
      try {
        final videoPath = entry.videoPaths.first;
        final mediaService = MediaService();
        final thumbnailFile = await mediaService.generateVideoThumbnail(videoPath);
        
        if (thumbnailFile != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              thumbnailFile,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(Icons.videocam, size: 40),
            ),
          );
        }
      } catch (e) {
        debugPrint('获取视频缩略图失败: $e');
      }
      
      // 如果获取缩略图失败，显示视频图标
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.videocam,
          size: 32,
          color: Colors.grey[700],
        ),
      );
    }
    
    // 如果既没有图片也没有视频，显示默认图标
    return const Icon(Icons.book, size: 40);
  }

  // 日记本数据导出 - 优化版，支持超大数据处理（几十G）
  Future<void> _exportDiaryData() async {
    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>('准备导出...');
    
    // 1. 创建唯一的临时导出目录
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String tempExportPath = path.join(appDir.path, 'temp_diary_export_${const Uuid().v4()}');
    final Directory tempExportDir = Directory(tempExportPath);

    try {
      await tempExportDir.create(recursive: true);
      
      showProgressDialog(context, progress, message);

      // 2. 获取所有日记条目
      message.value = '正在获取日记数据...';
      final allEntries = await _diaryService.loadEntries();
      if (allEntries.isEmpty) {
        if (mounted) Navigator.of(context).pop();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有日记可供导出')),
          );
        }
        return;
      }
      progress.value = 0.1;

      // 3. 准备媒体文件和元数据
      message.value = '正在整理媒体文件...';
      final List<Map<String, dynamic>> entriesForJson = [];
      final Set<String> mediaPathsToExport = {};

      for (var entry in allEntries) {
        entriesForJson.add(entry.toMap());
        // 合并所有类型的媒体路径
        final allPaths = [...entry.imagePaths, ...entry.videoPaths, ...entry.audioPaths];
        for (var mediaPath in allPaths) {
          // 只添加有效的文件路径
          if (mediaPath.isNotEmpty && await File(mediaPath).exists()) {
            mediaPathsToExport.add(mediaPath);
          }
        }
      }
      progress.value = 0.3;

      // 4. 将元数据写入临时目录中的json文件
      final jsonFile = File(path.join(tempExportDir.path, 'diary_data.json'));
      await jsonFile.writeAsString(jsonEncode(entriesForJson));

      // 5. 将媒体文件复制到临时目录的media子文件夹中
      message.value = '正在复制媒体文件...';
      final tempMediaDir = Directory(path.join(tempExportDir.path, 'media'));
      await tempMediaDir.create();

      int mediaDone = 0;
      int mediaTotal = mediaPathsToExport.isEmpty ? 1 : mediaPathsToExport.length;
      final Map<String, String> mediaPathMapping = {}; // 记录原始路径到新文件名的映射
      
      for (var mediaPath in mediaPathsToExport) {
        final originalFileName = path.basename(mediaPath);
        final fileExtension = path.extension(originalFileName);
        final baseName = path.basenameWithoutExtension(originalFileName);
        
        // 生成唯一的文件名，避免冲突
        String uniqueFileName = originalFileName;
        int counter = 1;
        while (mediaPathMapping.values.contains(uniqueFileName)) {
          uniqueFileName = '${baseName}_$counter$fileExtension';
          counter++;
        }
        
        final targetPath = path.join(tempMediaDir.path, uniqueFileName);
        await File(mediaPath).copy(targetPath);
        mediaPathMapping[mediaPath] = uniqueFileName;
        mediaDone++;
        progress.value = 0.3 + (mediaDone / mediaTotal) * 0.5; // 30%-80% for media copy
        print('已复制媒体文件: $originalFileName -> $uniqueFileName');
      }

      // 5.5. 更新JSON数据中的媒体路径
      message.value = '正在更新媒体路径...';
      for (var entry in entriesForJson) {
        // 更新图片路径
        if (entry['image_paths'] != null) {
          final List<String> updatedImagePaths = [];
          final originalImagePaths = jsonDecode(entry['image_paths']) as List;
          for (var imagePath in originalImagePaths) {
            if (mediaPathMapping.containsKey(imagePath)) {
              updatedImagePaths.add('media/${mediaPathMapping[imagePath]}');
            } else {
              updatedImagePaths.add(imagePath);
            }
          }
          entry['image_paths'] = jsonEncode(updatedImagePaths);
        }
        
        // 更新视频路径
        if (entry['video_paths'] != null) {
          final List<String> updatedVideoPaths = [];
          final originalVideoPaths = jsonDecode(entry['video_paths']) as List;
          for (var videoPath in originalVideoPaths) {
            if (mediaPathMapping.containsKey(videoPath)) {
              updatedVideoPaths.add('media/${mediaPathMapping[videoPath]}');
            } else {
              updatedVideoPaths.add(videoPath);
            }
          }
          entry['video_paths'] = jsonEncode(updatedVideoPaths);
        }
        
        // 更新音频路径
        if (entry['audio_paths'] != null) {
          final List<String> updatedAudioPaths = [];
          final originalAudioPaths = jsonDecode(entry['audio_paths']) as List;
          for (var audioPath in originalAudioPaths) {
            if (mediaPathMapping.containsKey(audioPath)) {
              updatedAudioPaths.add('media/${mediaPathMapping[audioPath]}');
            } else {
              updatedAudioPaths.add(audioPath);
            }
          }
          entry['audio_paths'] = jsonEncode(updatedAudioPaths);
        }
      }
      
      // 重新写入更新后的JSON文件
      await jsonFile.writeAsString(jsonEncode(entriesForJson));

      // 6. 从临时目录创建zip文件
      message.value = '正在压缩文件...';
      final downloadsDir = await getDownloadsDirectory();
      final zipFilePath = path.join(downloadsDir!.path, 'diary_export_${DateTime.now().toIso8601String().split('T').first}.zip');
      
      final encoder = ZipFileEncoder();
      encoder.create(zipFilePath);
      await encoder.addDirectory(tempExportDir, includeDirName: false);
      encoder.close();

      progress.value = 1.0;
      if (mounted) Navigator.of(context).pop();

      // 7. 分享zip文件
      await Share.shareXFiles([XFile(zipFilePath)], text: '日记数据导出');

    } catch (e) {
      debugPrint('导出日记数据失败: $e');
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    } finally {
      // 关键：无论成功或失败，都清理临时目录
      if (await tempExportDir.exists()) {
        try {
          await tempExportDir.delete(recursive: true);
          print('成功清理日记导出临时文件: ${tempExportDir.path}');
        } catch (e) {
          print('警告：清理日记导出临时目录时失败: $e');
        }
      }
    }
  }

  // 日记本数据导入 - 优化版，支持超大数据处理
  Future<void> _importDiaryData() async {
    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>('准备导入...');

    // 1. 创建唯一的临时导入目录
    final Directory appDir = await getApplicationDocumentsDirectory();
    final String tempImportPath = path.join(appDir.path, 'temp_diary_import_${const Uuid().v4()}');
    final Directory tempImportDir = Directory(tempImportPath);

    try {
      await tempImportDir.create(recursive: true);

      // 2. 选择ZIP文件
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
      if (result == null || result.files.isEmpty) {
        return; // 用户取消选择
      }

      showProgressDialog(context, progress, message);

      final zipFile = File(result.files.single.path!);
      final archive = ZipDecoder().decodeStream(InputFileStream(zipFile.path));
      
      // 3. 解压到临时目录
      int total = archive.files.length;
      int done = 0;
      for (final file in archive) {
        final filename = file.name;
        final outPath = path.join(tempImportDir.path, filename);
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          final outputStream = OutputFileStream(outFile.path);
          file.writeContent(outputStream);
          await outputStream.close();
        } else {
          await Directory(outPath).create(recursive: true);
        }
        done++;
        progress.value = (done / total) * 0.5; // 解压占50%
        message.value = '正在解压: $done/$total';
      }

      // 4. 读取并处理JSON数据
      message.value = '正在处理日记数据...';
      final jsonFile = File(path.join(tempImportDir.path, 'diary_data.json'));
      if (!await jsonFile.exists()) {
        throw Exception('压缩包中未找到 diary_data.json');
      }

      final entriesJson = jsonDecode(await jsonFile.readAsString()) as List;
      final List<DiaryEntry> entriesToImport = [];
      final permanentMediaDir = await _getPermanentMediaDirectory();

      print('开始处理JSON数据，共 ${entriesJson.length} 个条目');
      
      for (int i = 0; i < entriesJson.length; i++) {
        final item = entriesJson[i];
        final entryMap = item as Map<String, dynamic>;
        
        print('处理第 $i 个条目:');
        print('  原始imagePaths: ${entryMap['image_paths']}');
        print('  原始videoPaths: ${entryMap['video_paths']}');
        print('  原始audioPaths: ${entryMap['audio_paths']}');
        
        // 路径重映射 - 处理media/前缀的路径
        List<String> remapPaths(List<dynamic> originalPaths) {
          return originalPaths.map((p) {
            final pathStr = p.toString();
            print('处理媒体路径: $pathStr');
            
            if (pathStr.startsWith('media/')) {
              // 如果是media/开头的路径，提取文件名并映射到永久目录
              final fileName = path.basename(pathStr);
              final mappedPath = path.join(permanentMediaDir.path, fileName);
              print('映射 media/ 路径: $pathStr -> $mappedPath');
              return mappedPath;
            } else if (pathStr.contains('media/')) {
              // 如果路径中包含media/，提取media/后面的部分
              final mediaIndex = pathStr.indexOf('media/');
              final mediaPath = pathStr.substring(mediaIndex + 6); // 去掉"media/"
              final fileName = path.basename(mediaPath);
              final mappedPath = path.join(permanentMediaDir.path, fileName);
              print('映射包含media/的路径: $pathStr -> $mappedPath');
              return mappedPath;
            } else {
              // 如果是完整路径，直接使用文件名
              final fileName = path.basename(pathStr);
              final mappedPath = path.join(permanentMediaDir.path, fileName);
              print('映射完整路径: $pathStr -> $mappedPath');
              return mappedPath;
            }
          }).toList();
        }
        
        // 解析媒体路径
        List<String> parseMediaPaths(dynamic paths) {
          if (paths == null) return [];
          if (paths is List) {
            return paths.map((p) => p.toString()).toList();
          }
          if (paths is String) {
            try {
              final decoded = jsonDecode(paths) as List;
              return decoded.map((p) => p.toString()).toList();
            } catch (_) {
              return [paths];
            }
          }
          return [];
        }
        
        final imagePaths = remapPaths(parseMediaPaths(entryMap['image_paths']));
        final videoPaths = remapPaths(parseMediaPaths(entryMap['video_paths']));
        final audioPaths = remapPaths(parseMediaPaths(entryMap['audio_paths']));
        
        print('  映射后imagePaths: $imagePaths');
        print('  映射后videoPaths: $videoPaths');
        print('  映射后audioPaths: $audioPaths');
        
        // 创建临时Map，使用已处理的媒体路径
        final processedEntryMap = Map<String, dynamic>.from(entryMap);
        processedEntryMap['imagePaths'] = imagePaths;
        processedEntryMap['videoPaths'] = videoPaths;
        processedEntryMap['audioPaths'] = audioPaths;
        
        entriesToImport.add(DiaryEntry.fromMap(processedEntryMap));
      }
      progress.value = 0.7;

      // 5. 导入数据库（事务安全）
      message.value = '正在写入数据库...';
      await _diaryService.replaceAllEntries(entriesToImport);
      progress.value = 0.8;

      // 6. 迁移媒体文件
      message.value = '正在迁移媒体文件...';
      final tempMediaDir = Directory(path.join(tempImportDir.path, 'media'));
      if (await tempMediaDir.exists()) {
        final mediaFiles = await tempMediaDir.list().toList();
        int mediaCount = 0;
        int skippedCount = 0;
        
        for (var entity in mediaFiles) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            final targetPath = path.join(permanentMediaDir.path, fileName);
            
            try {
              // 检查源文件是否存在且可读
              if (await entity.exists()) {
                // 如果目标文件已存在，先删除
                final targetFile = File(targetPath);
                if (await targetFile.exists()) {
                  await targetFile.delete();
                }
                
                // 复制文件
                await entity.copy(targetPath);
                
                // 验证复制是否成功
                if (await File(targetPath).exists()) {
                  mediaCount++;
                  print('已迁移媒体文件: $fileName');
                } else {
                  print('警告：媒体文件复制失败: $fileName');
                  skippedCount++;
                }
              } else {
                print('警告：源媒体文件不存在: ${entity.path}');
                skippedCount++;
              }
            } catch (e) {
              print('警告：迁移媒体文件时出错: $fileName, 错误: $e');
              skippedCount++;
            }
          }
        }
        print('总共迁移了 $mediaCount 个媒体文件，跳过 $skippedCount 个文件');
        
        // 验证迁移结果
        if (mediaCount == 0 && mediaFiles.isNotEmpty) {
          print('警告：没有成功迁移任何媒体文件，可能存在权限或路径问题');
        }
      } else {
        print('临时媒体目录不存在，跳过媒体文件迁移');
      }
      progress.value = 0.95;

      // 7. 验证媒体文件映射
      message.value = '正在验证媒体文件...';
      int validMediaCount = 0;
      int invalidMediaCount = 0;
      
      print('开始验证媒体文件映射...');
      print('永久媒体目录: ${permanentMediaDir.path}');
      
      for (var entry in entriesToImport) {
        final allMediaPaths = [...entry.imagePaths, ...entry.videoPaths, ...entry.audioPaths];
        print('日记条目 ${entry.id} 的媒体路径: $allMediaPaths');
        
        for (var mediaPath in allMediaPaths) {
          if (mediaPath.isNotEmpty) {
            final mediaFile = File(mediaPath);
            print('检查媒体文件: $mediaPath');
            
            if (await mediaFile.exists()) {
              validMediaCount++;
              print('✓ 媒体文件存在: $mediaPath');
            } else {
              invalidMediaCount++;
              print('✗ 媒体文件不存在: $mediaPath');
              
              // 尝试列出永久媒体目录中的所有文件
              try {
                final files = await permanentMediaDir.list().toList();
                print('永久媒体目录中的文件: ${files.map((f) => path.basename(f.path)).toList()}');
              } catch (e) {
                print('无法列出永久媒体目录: $e');
              }
            }
          }
        }
      }
      
      print('媒体文件验证完成: $validMediaCount 个有效, $invalidMediaCount 个无效');
      progress.value = 0.98;

      // 8. 刷新UI
      message.value = '导入完成!';
      await _loadEntries();
      progress.value = 1.0;
      
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('日记数据导入成功')),
        );
      }
    } catch (e) {
      debugPrint('导入日记数据失败: $e');
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    } finally {
      // 关键：无论成功或失败，都清理临时目录
      if (await tempImportDir.exists()) {
        try {
          await tempImportDir.delete(recursive: true);
          print('成功清理日记导入临时文件: ${tempImportDir.path}');
        } catch (e) {
          print('警告：清理日记导入临时目录时失败: $e');
        }
      }
    }
  }

  Future<Directory> _getPermanentMediaDirectory() async {
    final docDir = await getApplicationDocumentsDirectory();
    final mediaDir = Directory(path.join(docDir.path, 'media'));
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  void _showEntryDetails(DiaryEntry entry) {
    // ... existing code ...
  }
}

class DiaryEditPage extends StatefulWidget {
  final DiaryEntry? entry;
  final DateTime date;
  const DiaryEditPage({super.key, this.entry, required this.date});

  @override
  State<DiaryEditPage> createState() => _DiaryEditPageState();
}

class _DiaryEditPageState extends State<DiaryEditPage> {
  late TextEditingController _contentController;
  late DateTime _date;
  late String _entryId;
  List<String> _imagePaths = [];
  List<String> _audioPaths = [];
  List<String> _videoPaths = [];
  String? _weather;
  String? _mood;
  String? _location;
  bool _isFavorite = false;
  final DiaryService _diaryService = DiaryService();
  bool _isSaving = false;
  bool _isLoading = true; // 加载状态标志
  Directory? _tempDir; // 缓存目录
  final Map<String, File> _videoThumbnailCache = {}; // 视频缩略图内存缓存
  late TextEditingController _locationController;

  final List<Map<String, dynamic>> _weatherSvgOptions = [
    {'icon': 'assets/icon/weather_sunny.svg', 'label': '晴'},
    {'icon': 'assets/icon/weather_cloudy.svg', 'label': '多云'},
    {'icon': 'assets/icon/weather_rain.svg', 'label': '雨'},
    {'icon': 'assets/icon/weather_snow.svg', 'label': '雪'},
    {'icon': 'assets/icon/weather_fog.svg', 'label': '雾'},
    {'icon': 'assets/icon/weather_wind.svg', 'label': '风'},
    {'icon': 'assets/icon/weather_thunder.svg', 'label': '雷'},
    {'icon': 'assets/icon/weather_haze.svg', 'label': '霾'},
  ];
  final List<Map<String, dynamic>> _moodSvgOptions = [
    {'icon': 'assets/icon/mood_happy.svg', 'label': '开心'},
    {'icon': 'assets/icon/mood_calm.svg', 'label': '平静'},
    {'icon': 'assets/icon/mood_sad.svg', 'label': '难过'},
    {'icon': 'assets/icon/mood_angry.svg', 'label': '生气'},
    {'icon': 'assets/icon/mood_excited.svg', 'label': '激动'},
    {'icon': 'assets/icon/mood_depressed.svg', 'label': '沮丧'},
    {'icon': 'assets/icon/mood_surprised.svg', 'label': '惊讶'},
    {'icon': 'assets/icon/mood_neutral.svg', 'label': '一般'},
  ];

  @override
  void initState() {
    super.initState();
    _initEntryId();
    // 初始化late变量，防止在异步加载完成前访问它们
    _date = widget.entry?.date ?? widget.date;
    _contentController = TextEditingController(text: '');
    _initTempDir();
    _loadDraftOrEntry();
    _locationController = TextEditingController(text: _location ?? '');
  }
  
  Future<void> _initTempDir() async {
    _tempDir = await getTemporaryDirectory();
  }

  void _initEntryId() {
    if (widget.entry?.id != null) {
      _entryId = widget.entry!.id;
    } else {
      _entryId = const Uuid().v4();
    }
  }

  // 预加载所有缩略图的缓存，避免界面上一张一张显示的情况
  Future<void> _preloadThumbnails(List<String> imagePaths, List<String> videoPaths) async {
    debugPrint('开始预加载所有缩略图...');
    
    // 清空之前的缓存
    _videoThumbnailCache.clear();
    
    // 预加载所有视频缩略图到内存缓存
    for (final videoPath in videoPaths) {
      try {
        final thumbnailFile = await _getCachedVideoThumbnail(videoPath);
        if (thumbnailFile != null) {
          final fileName = videoPath.split(Platform.pathSeparator).last;
          final cacheKey = 'video_thumb_$fileName';
          _videoThumbnailCache[cacheKey] = thumbnailFile;
          debugPrint('视频缩略图已缓存: $cacheKey');
        }
      } catch (e) {
        debugPrint('预加载视频缩略图失败: $videoPath, 错误: $e');
      }
    }
    
    debugPrint('所有缩略图预加载完成，视频缓存数量: ${_videoThumbnailCache.length}');
  }

  Future<void> _loadDraftOrEntry() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final entries = await _diaryService.loadEntries();
      DiaryEntry? draft = entries.firstWhere((e) => e.id == _entryId, orElse: () => DiaryEntry(
        id: _entryId,
        date: widget.entry?.date ?? widget.date,
        content: widget.entry?.content ?? '',
        imagePaths: widget.entry?.imagePaths ?? [],
        audioPaths: widget.entry?.audioPaths ?? [],
        videoPaths: widget.entry?.videoPaths ?? [],
        weather: widget.entry?.weather,
        mood: widget.entry?.mood,
        location: widget.entry?.location,
        isFavorite: widget.entry?.isFavorite ?? false,
      ));
      
      // 在设置状态之前预加载所有缩略图
      await _preloadThumbnails(
        List<String>.from(draft.imagePaths), 
        List<String>.from(draft.videoPaths)
      );
      
      if (mounted) {
        setState(() {
          _date = draft.date;
          _contentController.text = draft.content ?? '';
          _imagePaths = List<String>.from(draft.imagePaths);
          _audioPaths = List<String>.from(draft.audioPaths);
          _videoPaths = List<String>.from(draft.videoPaths);
          _weather = draft.weather;
          _mood = draft.mood;
          _location = draft.location;
          _locationController.text = draft.location ?? '';
          _isFavorite = draft.isFavorite;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载日记数据失败: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _contentController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _autoSave();
        Navigator.of(context).pop(_buildEntry());
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(icon: Icon(Icons.close), onPressed: () async {
            await _autoSave();
            Navigator.of(context).pop(_buildEntry());
          }),
          title: _isLoading 
            ? Text('加载中...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22))
            : Text('${_date.month}月${_date.day}日  ${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}  ${_weekdayStr(_date.weekday)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
          centerTitle: true,
          actions: [
            IconButton(
              icon: Icon(_isFavorite ? Icons.favorite : Icons.favorite_border, color: _isFavorite ? Colors.red : Colors.grey),
              tooltip: _isFavorite ? '取消收藏' : '收藏',
              onPressed: () async {
                setState(() {
                  _isFavorite = !_isFavorite;
                });
                await _autoSave();
              },
            ),
          ],
        ),
        body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _contentController,
                  maxLines: null,
                  style: TextStyle(
                    fontSize: 18,
                  ),
                  decoration: InputDecoration(
                    hintText: '记录今日',
                    border: InputBorder.none,
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: Colors.grey.withOpacity(0.5),
                        width: 1.0,
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: Colors.blue.withOpacity(0.7),
                        width: 1.5,
                      ),
                    ),
                  ),
                  onChanged: (_) async {
                    await _autoSave();
                  },
                ),
                SizedBox(height: 12),
                // 图片+视频混合九宫格
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ..._imagePaths.asMap().entries.map((e) => Stack(
                      children: [
                        GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (_) => MediaPreviewDialog(
                              mediaPaths: [..._imagePaths, ..._videoPaths],
                              initialIndex: e.key,
                              isVideo: false,
                              onDelete: (idx) {
                                if (idx < _imagePaths.length) {
                                  _removeImage(idx);
                                } else {
                                  _removeVideo(idx - _imagePaths.length);
                                }
                                Navigator.of(context).pop();
                              },
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: _buildImageThumbnail(e.value, 90, 90),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => _removeImage(e.key),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )),
                    ..._videoPaths.asMap().entries.map((e) => Stack(
                      children: [
                        GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (_) => MediaPreviewDialog(
                              mediaPaths: [..._imagePaths, ..._videoPaths],
                              initialIndex: _imagePaths.length + e.key,
                              isVideo: true,
                              onDelete: (idx) {
                                if (idx < _imagePaths.length) {
                                  _removeImage(idx);
                                } else {
                                  _removeVideo(idx - _imagePaths.length);
                                }
                                Navigator.of(context).pop();
                              },
                            ),
                          ),
                          child: SizedBox(
                            width: 90,
                            height: 90,
                            child: _buildVideoThumbnail(_videoPaths[e.key], e.key),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => _removeVideo(e.key),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onTap: _pickImage,
                          child: Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.add_photo_alternate,
                              size: 32,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _pickVideo,
                          child: Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.video_call,
                              size: 32,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _addAudioBox,
                          child: Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.mic,
                              size: 32,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_audioPaths.isNotEmpty) ...[
                  SizedBox(height: 16),
                  // 语音
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ..._audioPaths.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final path = entry.value;
                        return SizedBox(
                          width: MediaQuery.of(context).size.width / 5 - 24,
                          child: ResizableAudioBox(
                            audioPath: path,
                            onIsRecording: (isRec) {},
                            onSettingsPressed: () {
                              showModalBottomSheet(
                                context: context,
                                builder: (ctx) => SafeArea(
                                  child: Wrap(
                                    children: [
                                      ListTile(
                                        leading: Icon(Icons.mic),
                                        title: Text('录制新语音'),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _updateAudioPath(idx, '');
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.delete),
                                        title: Text('删除语音框'),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _removeAudioBox(idx);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            onPathUpdated: (newPath) async {
                              _updateAudioPath(idx, newPath);
                              await _autoSave();
                            },
                          ),
                        );
                      }),
                  ],
                ),
                ],
                SizedBox(height: 16),
                // 天气和心情下拉选择
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _mood,
                        decoration: InputDecoration(
                          labelText: '今天的心情',
                          prefixIcon: _mood != null
                              ? SvgPicture.asset(_moodSvgOptions.firstWhere((e) => e['label'] == _mood)['icon'], width: 24, height: 24)
                              : null,
                          border: OutlineInputBorder(),
                        ),
                        items: _moodSvgOptions.map((opt) => DropdownMenuItem<String>(
                          value: opt['label'],
                          child: Row(
                            children: [
                              SvgPicture.asset(opt['icon'], width: 24, height: 24),
                              SizedBox(width: 8),
                              Text(opt['label']),
                            ],
                          ),
                        )).toList(),
                        onChanged: (val) async {
                          setState(() {
                            _mood = val;
                          });
                          await _autoSave();
                        },
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _weather,
                        decoration: InputDecoration(
                          labelText: '今天的天气',
                          prefixIcon: _weather != null
                              ? SvgPicture.asset(_weatherSvgOptions.firstWhere((e) => e['label'] == _weather)['icon'], width: 24, height: 24)
                              : null,
                          border: OutlineInputBorder(),
                        ),
                        items: _weatherSvgOptions.map((opt) => DropdownMenuItem<String>(
                          value: opt['label'],
                          child: Row(
                            children: [
                              SvgPicture.asset(opt['icon'], width: 24, height: 24),
                              SizedBox(width: 8),
                              Text(opt['label']),
                            ],
                          ),
                        )).toList(),
                        onChanged: (val) async {
                          setState(() {
                            _weather = val;
                          });
                          await _autoSave();
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                // 地点
                Row(
                  children: [
                    const Icon(Icons.location_on_outlined, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _locationController,
                        decoration: const InputDecoration(
                          hintText: '请输入地点',
                          border: InputBorder.none,
                        ),
                        onChanged: (val) async {
                          setState(() {
                            _location = val;
                          });
                          await _autoSave();
                        },
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 24),
              ],
          ),
        ),
      ),
      ),
  );
  }

  DiaryEntry _buildEntry() {
    return DiaryEntry(
      id: _entryId,
      date: _date,
      content: _contentController.text,
      imagePaths: _imagePaths,
      audioPaths: _audioPaths.where((p) => p.isNotEmpty).toList(),
      videoPaths: _videoPaths,
      weather: _weather,
      mood: _mood,
      location: _location,
      isFavorite: _isFavorite,
    );
  }

  Future<void> _autoSave() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      await _diaryService.autoSaveEntry(_buildEntry());
    } catch (e) {
      debugPrint('自动保存失败: \\${e.toString()}');
    } finally {
      _isSaving = false;
    }
  }

  Future<void> _pickImage() async {
    final path = await ImagePickerService.pickImage(context);
    if (path != null) {
      setState(() {
        _imagePaths.add(path);
      });
      await _autoSave();
    }
  }

  void _removeImage(int idx) async {
    setState(() {
      _imagePaths.removeAt(idx);
    });
    await _autoSave();
  }

  void _addAudioBox() async {
    setState(() {
      _audioPaths.add('');
    });
    await _autoSave();
  }

  void _updateAudioPath(int idx, String newPath) async {
    setState(() {
      _audioPaths[idx] = newPath;
    });
    await _autoSave();
  }

  void _removeAudioBox(int idx) async {
    setState(() {
      _audioPaths.removeAt(idx);
    });
    await _autoSave();
  }

  void _removeVideo(int idx) async {
    setState(() {
      _videoPaths.removeAt(idx);
    });
    await _autoSave();
  }

  Widget _buildVideoThumbnail(String path, int index) {
    // 使用全局缓存Map存储缩略图，实现瞬间显示
    final fileName = path.split(Platform.pathSeparator).last;
    final cacheKey = 'video_thumb_$fileName';
    
    // 检查内存缓存
    if (_videoThumbnailCache.containsKey(cacheKey) && _videoThumbnailCache[cacheKey] != null) {
      final thumbnailFile = _videoThumbnailCache[cacheKey]!;
      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              thumbnailFile,
              width: 90,
              height: 90,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    } else {
      // 显示占位符
      return Container(
        width: 90,
        height: 90,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(
          child: Icon(
            Icons.videocam,
            size: 32,
            color: Colors.grey,
          ),
        ),
      );
    }
  }
  
  // 获取持久化缓存的视频缩略图
  Future<File?> _getCachedVideoThumbnail(String videoPath) async {
    try {
      // 使用文件名作为缓存标识符，而不是hashCode
      final fileName = videoPath.split(Platform.pathSeparator).last;
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = '${tempDir.path}/video_thumb_$fileName.jpg';
      final thumbnailFile = File(thumbnailPath);
      
      // 检查缓存是否存在
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        debugPrint('使用视频缩略图缓存: $thumbnailPath');
        return thumbnailFile;
      }
      
      debugPrint('生成新的视频缩略图: $videoPath');
      // 缓存不存在，生成新的缩略图
      final newThumbnail = await MediaService().generateVideoThumbnail(videoPath);
      if (newThumbnail != null) {
        // 复制到持久化缓存位置
        await newThumbnail.copy(thumbnailPath);
        return thumbnailFile;
      }
      
      return null;
    } catch (e) {
      debugPrint('获取缓存视频缩略图失败: $e');
      return null;
    }
  }

  Widget _buildVideoPlayer(String path) {
    return VideoPlayerWidget(
      file: File(path),
    );
  }
  
  // 构建图片缩略图，直接显示原图实现瞬间加载
  Widget _buildImageThumbnail(String imagePath, double width, double height) {
    // 直接显示原图，无需缓存检查，实现瞬间显示
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        File(imagePath),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.image,
              size: 32,
              color: Colors.grey,
            ),
          );
        },
      ),
    );
  }
  
  // 获取持久化缓存的图片缩略图
  Future<File?> _getCachedImageThumbnail(String imagePath) async {
    try {
      // 使用文件名作为缓存标识符，而不是hashCode
      final fileName = imagePath.split(Platform.pathSeparator).last;
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = '${tempDir.path}/img_thumb_$fileName';
      final thumbnailFile = File(thumbnailPath);
      
      // 检查缓存是否存在
      if (await thumbnailFile.exists() && await thumbnailFile.length() > 100) {
        debugPrint('使用图片缩略图缓存: $thumbnailPath');
        return thumbnailFile;
      }
      
      debugPrint('生成新的图片缩略图: $imagePath');
      // 缓存不存在，创建新的缩略图
      final originalFile = File(imagePath);
      if (await originalFile.exists()) {
        // 简单地复制原图作为缩略图
        // 在实际应用中，你可能需要使用图像处理库来调整大小和质量
        await originalFile.copy(thumbnailPath);
        return thumbnailFile;
      }
      
      return null;
    } catch (e) {
      debugPrint('获取缓存图片缩略图失败: $e');
      return null;
    }
  }

  String _weekdayStr(int weekday) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${weekdays[(weekday - 1) % 7]}';
  }

  @override
  Future<void> _pickVideo() async {
    try {
      final path = await ImagePickerService.pickVideo(context);
      if (path != null && path.isNotEmpty) {
        setState(() {
          _videoPaths.add(path);
        });
        // 预加载缩略图
        final thumb = await _getCachedVideoThumbnail(path);
        if (thumb != null) {
          final fileName = path.split(Platform.pathSeparator).last;
          final cacheKey = 'video_thumb_$fileName';
          setState(() {
            _videoThumbnailCache[cacheKey] = thumb;
          });
        }
        await _autoSave();
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未选择或保存视频')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择视频时发生错误：\n${e.toString()}')),
        );
      }
    }
  }
}

// 图片全屏滑动放大组件
class _ImageGalleryViewer extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;
  const _ImageGalleryViewer({required this.imagePaths, required this.initialIndex});
  @override
  State<_ImageGalleryViewer> createState() => _ImageGalleryViewerState();
}

class _ImageGalleryViewerState extends State<_ImageGalleryViewer> {
  late PageController _pageController;
  double _scale = 1.0;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () {
        setState(() {
          _scale = _scale == 1.0 ? 2.0 : 1.0;
        });
      },
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.imagePaths.length,
            onPageChanged: (idx) => setState(() => _currentIndex = idx),
            itemBuilder: (context, idx) {
              return Center(
                child: InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 4.0,
                  scaleEnabled: true,
                  child: Image.file(
                    File(widget.imagePaths[idx]),
                    fit: BoxFit.contain,
                    width: MediaQuery.of(context).size.width,
                    height: MediaQuery.of(context).size.height,
                  ),
                ),
              );
            },
          ),
          Positioned(
            top: 40,
            right: 20,
            child: IconButton(
              icon: Icon(Icons.close, color: Colors.white, size: 32),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

// 自定义"今"字圆圈icon
class _TodayCircleIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black, width: 2),
      ),
      child: Center(
        child: Text('今', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    );
  }
}

// 新增视频全屏播放组件
class _VideoPlayerViewer extends StatefulWidget {
  final List<String> videoPaths;
  final int initialIndex;
  const _VideoPlayerViewer({
    required this.videoPaths,
    required this.initialIndex,
  });

  @override
  State<_VideoPlayerViewer> createState() => _VideoPlayerViewerState();
}

class _VideoPlayerViewerState extends State<_VideoPlayerViewer> {
  late PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: widget.videoPaths.length,
          onPageChanged: (idx) => setState(() => _currentIndex = idx),
          itemBuilder: (context, idx) {
            return VideoPlayerWidget(
              file: File(widget.videoPaths[idx]),
            );
          },
        ),
        Positioned(
          top: 40,
          right: 20,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 32),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }
}

// 新增MediaPreviewDialog组件，支持图片/视频混合滑动预览、删除、放大、关闭等操作，操作方式与媒体管理界面一致。
class MediaPreviewDialog extends StatefulWidget {
  final List<String> mediaPaths;
  final int initialIndex;
  final bool isVideo;
  final void Function(int idx) onDelete;
  const MediaPreviewDialog({
    super.key,
    required this.mediaPaths,
    required this.initialIndex,
    required this.isVideo,
    required this.onDelete,
  });

  @override
  State<MediaPreviewDialog> createState() => _MediaPreviewDialogState();
}

class _MediaPreviewDialogState extends State<MediaPreviewDialog> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.mediaPaths.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
              debugPrint('日记页面切换到媒体: $_currentIndex');
            },
            itemBuilder: (context, idx) {
              final path = widget.mediaPaths[idx];
              debugPrint('构建日记媒体项: $path');
              if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi')) {
                // 视频
                debugPrint('日记页面视频: $path');
                debugPrint('幕尺寸: \\${MediaQuery.of(context).size.width}x\\${MediaQuery.of(context).size.height}');
                debugPrint('BoxFit设置: BoxFit.cover');
                return SizedBox.expand(
                  child: VideoPlayerWidget(file: File(path)),
                );
              } else {
                // 图片
                debugPrint('日记页面图片: $path');
                return SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: Image.file(
                      File(path),
                      width: MediaQuery.of(context).size.width,
                      height: MediaQuery.of(context).size.height,
                    ),
                  ),
                );
              }
            },
          ),
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              icon: Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: IconButton(
              icon: Icon(Icons.delete, color: Colors.red, size: 28),
              onPressed: () => widget.onDelete(_currentIndex),
            ),
          ),
        ],
      ),
    );
  }
}

