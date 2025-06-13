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
  const DiaryPage({Key? key}) : super(key: key);

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

  @override
  void initState() {
    super.initState();
    _loadEntries();
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
    return filtered.where((e) => (e.content ?? '').contains(_searchKeyword)).toList()..sort((a, b) => b.date.compareTo(a.date));
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
    return Scaffold(
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
                hintText: '搜索日记...',
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
            leading: entry.imagePaths.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(entry.imagePaths.first),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Icon(Icons.broken_image, size: 40),
                    ),
                  )
                : const Icon(Icons.book, size: 40),
            trailing: null,
            onTap: () => _addOrEditEntry(entry: entry),
          ),
        );
      },
    );
  }

  // 日记本数据导出
  Future<void> _exportDiaryData() async {
    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>("准备导出...");
    try {
      showProgressDialog(context, progress, message, barrierDismissible: true);
      final entries = await _diaryService.loadEntries();
      final Directory? extDir = await getExternalStorageDirectory();
      if (extDir == null) throw Exception("无法获取外部存储目录");
      final String backupPath = "${extDir.path}/Download/diary_backups";
      final Directory backupDir = Directory(backupPath);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }
      final String tempDirPath = "$backupPath/temp_diary_backup";
      final Directory tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);
      // 保存日记数据为json
      final File dataFile = File("$tempDirPath/diary_data.json");
      await dataFile.writeAsString(jsonEncode(entries.map((e) => e.toMap()).toList()));
      progress.value = 0.1;
      message.value = "正在导出日记数据...";
      await Future.delayed(const Duration(milliseconds: 10));
      // 分批异步拷贝媒体文件，并实时更新进度
      final Set<String> allMediaPaths = {};
      for (final entry in entries) {
        allMediaPaths.addAll(entry.imagePaths);
        allMediaPaths.addAll(entry.audioPaths);
        allMediaPaths.addAll(entry.videoPaths);
      }
      final mediaList = allMediaPaths.where((path) => path.isNotEmpty).toList();
      int total = mediaList.length;
      int done = 0;
      for (final path in mediaList) {
        final file = File(path);
        if (await file.exists()) {
          final fileName = path.split(Platform.pathSeparator).last;
          final ext = fileName.split('.').last.toLowerCase();
          final typeDir = (['jpg','jpeg','png','gif','bmp','webp'].contains(ext)) ? 'images' :
                          (['mp3','aac','wav','m4a','ogg'].contains(ext)) ? 'audios' :
                          (['mp4','mov','avi','mkv','webm'].contains(ext)) ? 'videos' : 'others';
          final targetDir = Directory("$tempDirPath/$typeDir");
          if (!await targetDir.exists()) await targetDir.create(recursive: true);
          await file.copy("${targetDir.path}/$fileName");
        }
        done++;
        progress.value = 0.1 + (done / total) * 0.7; // 进度从 0.1 到 0.8
        message.value = "正在导出媒体文件: $done/$total";
        await Future.delayed(const Duration(milliseconds: 10));
      }
      // 打包为zip，使用 ZipFileEncoder 流式写入
      message.value = "正在打包为zip...";
      final String timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '');
      final String zipPath = "$backupPath/diary_backup_$timestamp.zip";
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      await encoder.addDirectory(tempDir, includeDirName: false);
      encoder.close();
      progress.value = 0.9;
      await Future.delayed(const Duration(milliseconds: 10));
      await tempDir.delete(recursive: true);
      progress.value = 1.0;
      message.value = "导出完成，文件保存在: $zipPath";
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context);
      // 复制路径到剪贴板，并提示用户
      await Clipboard.setData(ClipboardData(text: zipPath));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("导出完成，文件路径已复制到剪贴板: $zipPath")));
      // 分享文件（可选）
      await Share.shareXFiles([XFile(zipPath)], subject: '日记本数据备份');
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("导出日记本数据失败: $e")));
    }
  }

  // 日记本数据导入
  Future<void> _importDiaryData() async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("警告"),
        content: Text("导入新日记本数据将会覆盖当前所有日记，确定要继续吗？"),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text("取消")),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text("确定")),
        ],
      ),
    );
    if (confirm != true) return;
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (result == null || result.files.single.path == null) return;
    final progress = ValueNotifier<double>(0.0);
    final message = ValueNotifier<String>("准备导入...");
    try {
      showProgressDialog(context, progress, message, barrierDismissible: true);
      final Directory? extDir = await getExternalStorageDirectory();
      if (extDir == null) throw Exception("无法获取外部存储目录");
      final String tempDirPath = "${extDir.path}/Download/diary_import_temp";
      final Directory tempDir = Directory(tempDirPath);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);
      // 分批异步解压zip，利用 InputFileStream 流式解压
      message.value = "正在解压文件...";
      final inputStream = InputFileStream(result.files.single.path!);
      final archive = ZipDecoder().decodeStream(inputStream);
      int total = archive.length;
      int done = 0;
      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          File("$tempDirPath/$filename")..createSync(recursive: true)..writeAsBytesSync(data);
        }
        done++;
        progress.value = (done / total) * 0.5; // 解压进度占 0.5
        message.value = "解压中: $done/$total";
        await Future.delayed(const Duration(milliseconds: 10));
      }
      // 恢复日记数据
      message.value = "正在恢复日记数据...";
      final File dataFile = File("$tempDirPath/diary_data.json");
      if (!await dataFile.exists()) throw Exception("未找到日记数据文件");
      final List<dynamic> entryList = jsonDecode(await dataFile.readAsString());
      final List<DiaryEntry> entries = entryList.map((e) => DiaryEntry.fromMap(e)).toList();
      progress.value = 0.6;
      await Future.delayed(const Duration(milliseconds: 10));
      // 恢复媒体文件到原目录，分批异步拷贝
      final Map<String, String> typeDirs = { 'images': 'imagePaths', 'audios': 'audioPaths', 'videos': 'videoPaths' };
      int mediaTotal = 0;
      for (final type in typeDirs.keys) {
        final dir = Directory("$tempDirPath/$type");
        if (await dir.exists()) {
          final files = await dir.list().where((e) => e is File).toList();
          mediaTotal += files.length;
        }
      }
      int mediaDone = 0;
      for (final type in typeDirs.keys) {
        final dir = Directory("$tempDirPath/$type");
        if (await dir.exists()) {
          for (final file in await dir.list().where((e) => e is File).toList()) {
            if (file is File) {
              final appMediaDir = Directory("${extDir.path}/${type}");
              if (!await appMediaDir.exists()) await appMediaDir.create(recursive: true);
              await file.copy("${appMediaDir.path}/${file.uri.pathSegments.last}");
            }
            mediaDone++;
            progress.value = 0.6 + (mediaDone / mediaTotal) * 0.3; // 媒体恢复进度占 0.3
            message.value = "恢复媒体文件: $mediaDone/$mediaTotal";
            await Future.delayed(const Duration(milliseconds: 10));
          }
        }
      }
      // 修正音频路径为新手机本地路径
      for (final entry in entries) {
        if (entry.audioPaths.isNotEmpty) {
          for (int i = 0; i < entry.audioPaths.length; i++) {
            final oldPath = entry.audioPaths[i];
            if (oldPath.isEmpty) continue;
            final fileName = oldPath.split(Platform.pathSeparator).last;
            final newPath = "${extDir.path}/audios/$fileName";
            if (File(newPath).existsSync()) {
              entry.audioPaths[i] = newPath;
            }
          }
        }
      }
      progress.value = 0.9;
      message.value = "正在保存日记数据...";
      await _diaryService.saveEntries(entries);
      await tempDir.delete(recursive: true);
      progress.value = 1.0;
      message.value = "导入完成，即将刷新页面...";
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.pop(context);
      await _loadEntries();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("日记本数据导入成功")));
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("导入日记本数据失败: $e")));
    }
  }
}

class DiaryEditPage extends StatefulWidget {
  final DiaryEntry? entry;
  final DateTime date;
  const DiaryEditPage({Key? key, this.entry, required this.date}) : super(key: key);

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
  final Map<String, File?> _videoThumbnailCache = {};

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
    _loadDraftOrEntry();
  }

  void _initEntryId() {
    if (widget.entry?.id != null) {
      _entryId = widget.entry!.id;
    } else {
      _entryId = const Uuid().v4();
    }
  }

  Future<void> _loadDraftOrEntry() async {
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
    setState(() {
      _date = draft.date;
      _contentController = TextEditingController(text: draft.content);
      _imagePaths = List<String>.from(draft.imagePaths);
      _audioPaths = List<String>.from(draft.audioPaths);
      _videoPaths = List<String>.from(draft.videoPaths);
      _weather = draft.weather;
      _mood = draft.mood;
      _location = draft.location;
      _isFavorite = draft.isFavorite;
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
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
          title: Text('${_date.month}月${_date.day}日  ${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}  ${_weekdayStr(_date.weekday)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
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
        body: SafeArea(
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
                            child: Image.file(
                              File(e.value),
                              width: 90,
                              height: 90,
                              fit: BoxFit.cover,
                            ),
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
                        controller: TextEditingController(text: _location ?? ''),
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

  Future<void> _pickVideo() async {
    try {
      final path = await ImagePickerService.pickVideo(context);
      if (path != null && path.isNotEmpty) {
        setState(() {
          _videoPaths.add(path);
        });
        await _autoSave();
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('未选择或保存视频')),
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

  void _removeVideo(int idx) async {
    setState(() {
      _videoPaths.removeAt(idx);
    });
    await _autoSave();
  }

  Widget _buildVideoThumbnail(String path, int index) {
    if (_videoThumbnailCache.containsKey(path)) {
      final file = _videoThumbnailCache[path];
      if (file != null) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                file,
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
      }
    }
    return FutureBuilder<File?>(
      future: MediaService().generateVideoThumbnail(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData && snapshot.data != null) {
          _videoThumbnailCache[path] = snapshot.data;
          return Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  snapshot.data!,
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
      },
    );
  }

  Widget _buildVideoPlayer(String path) {
    return VideoPlayerWidget(
      file: File(path),
    );
  }

  String _weekdayStr(int weekday) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${weekdays[(weekday - 1) % 7]}';
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
    Key? key,
    required this.mediaPaths,
    required this.initialIndex,
    required this.isVideo,
    required this.onDelete,
  }) : super(key: key);

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
                debugPrint('幕尺寸: ${MediaQuery.of(context).size.width}x${MediaQuery.of(context).size.height}');
                // 修改BoxFit.cover为BoxFit.contain，确保视频完整显示
                debugPrint('BoxFit设置: BoxFit.contain');
                return SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.contain, // 从cover改为contain，确保视频完整显示
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width,
                      height: MediaQuery.of(context).size.height,
                      child: VideoPlayerWidget(file: File(path)),
                    ),
                  ),
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

