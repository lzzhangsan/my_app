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
    final entries = _entries.where((e) => isSameDay(e.date, _selectedDate)).toList();
    final filtered = _showFavoritesOnly ? entries.where((e) => e.isFavorite).toList() : entries;
    if (_searchKeyword.isEmpty) return filtered..sort((a, b) => b.date.compareTo(a.date));
    return filtered.where((e) => e.content.contains(_searchKeyword)).toList()..sort((a, b) => b.date.compareTo(a.date));
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
    await _diaryService.deleteEntry(entry.id);
    _loadEntries();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记本'),
        centerTitle: true,
        actions: [
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
        ],
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
                      icon: Icon(Icons.keyboard_double_arrow_left, size: 28, weight: 800),
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
                      icon: Icon(Icons.keyboard_double_arrow_right, size: 28, weight: 800),
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
                children: const [
                  Text('日'), Text('一'), Text('二'), Text('三'), Text('四'), Text('五'), Text('六'),
                ],
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
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'edit') {
                            _addOrEditEntry(entry: entry);
                          } else if (value == 'delete') {
                            _deleteEntry(entry);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          const PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      IconButton(
                        icon: Icon(entry.isFavorite ? Icons.favorite : Icons.favorite_border, color: entry.isFavorite ? Colors.red : null),
                        tooltip: entry.isFavorite ? '取消收藏' : '收藏',
                        onPressed: () async {
                          final updated = entry.copyWith(isFavorite: !entry.isFavorite);
                          await _diaryService.updateEntry(updated);
                          _loadEntries();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            subtitle: Text(entry.content, maxLines: 2, overflow: TextOverflow.ellipsis),
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
                  style: TextStyle(fontSize: 18),
                  decoration: InputDecoration(
                    hintText: '记录今日',
                    border: InputBorder.none,
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
                    if (_imagePaths.length + _videoPaths.length < 9)
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
                        ],
                      ),
                  ],
                ),
                SizedBox(height: 16),
                // 语音
                Row(
                  children: [
                    Text('语音：', style: TextStyle(fontSize: 16)),
                    IconButton(
                      icon: Icon(Icons.add_circle_outline),
                      onPressed: _addAudioBox,
                      tooltip: '添加语音',
                    ),
                  ],
                ),
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
            onPageChanged: (idx) => setState(() => _currentIndex = idx),
            itemBuilder: (context, idx) {
              final path = widget.mediaPaths[idx];
              if (path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.avi')) {
                // 视频
                return SizedBox.expand(
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: MediaQuery.of(context).size.width,
                      height: MediaQuery.of(context).size.height,
                      child: VideoPlayerWidget(file: File(path)),
                    ),
                  ),
                );
              } else {
                // 图片
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