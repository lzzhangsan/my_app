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

class DiaryPage extends StatefulWidget {
  const DiaryPage({Key? key}) : super(key: key);

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  final DiaryService _diaryService = DiaryService();
  List<DiaryEntry> _entries = [];
  DateTime _selectedDate = DateTime.now();

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

  List<DiaryEntry> get _entriesForSelectedDate => _entries.where((e) => isSameDay(e.date, _selectedDate)).toList();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记本'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _buildCalendar(),
          Expanded(child: _buildDiaryList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addOrEditEntry(),
        child: const Icon(Icons.add),
        tooltip: '新增日记',
      ),
    );
  }

  Widget _buildCalendar() {
    final now = DateTime.now();
    final firstDayOfMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    final lastDayOfMonth = DateTime(_selectedDate.year, _selectedDate.month + 1, 0);
    final daysInMonth = lastDayOfMonth.day;
    final weekDayOffset = firstDayOfMonth.weekday % 7;
    final days = List.generate(daysInMonth, (i) => DateTime(_selectedDate.year, _selectedDate.month, i + 1));
    return Card(
      margin: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _onDateSelected(DateTime(_selectedDate.year, _selectedDate.month - 1, 1)),
              ),
              Text('${_selectedDate.year}年${_selectedDate.month}月', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _onDateSelected(DateTime(_selectedDate.year, _selectedDate.month + 1, 1)),
              ),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 1.2,
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
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: isSelected ? Colors.blueAccent : (hasEntry ? Colors.blue.withOpacity(0.2) : null),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${day.day}',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.black87,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
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
            title: Text(DateFormat('HH:mm').format(entry.date)),
            subtitle: Text(entry.content, maxLines: 2, overflow: TextOverflow.ellipsis),
            leading: entry.imagePaths.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(entry.imagePaths.first, width: 48, height: 48, fit: BoxFit.cover),
                  )
                : const Icon(Icons.book, size: 40),
            trailing: PopupMenuButton<String>(
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
  List<String> _imagePaths = [];
  List<String> _audioPaths = [];
  String? _weather;
  String? _mood;
  String? _location;

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
    _date = widget.entry?.date ?? widget.date;
    _contentController = TextEditingController(text: widget.entry?.content ?? '');
    _imagePaths = List<String>.from(widget.entry?.imagePaths ?? []);
    _audioPaths = List<String>.from(widget.entry?.audioPaths ?? []);
    _weather = widget.entry?.weather;
    _mood = widget.entry?.mood;
    _location = widget.entry?.location;
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final path = await ImagePickerService.pickImage(context);
    if (path != null) {
      setState(() {
        _imagePaths.add(path);
      });
    }
  }

  void _removeImage(int idx) {
    setState(() {
      _imagePaths.removeAt(idx);
    });
  }

  void _addAudioBox() {
    setState(() {
      _audioPaths.add('');
    });
  }

  void _updateAudioPath(int idx, String newPath) {
    setState(() {
      _audioPaths[idx] = newPath;
    });
  }

  void _removeAudioBox(int idx) {
    setState(() {
      _audioPaths.removeAt(idx);
    });
  }

  void _save() {
    final entry = DiaryEntry(
      id: widget.entry?.id ?? const Uuid().v4(),
      date: _date,
      content: _contentController.text,
      imagePaths: _imagePaths,
      audioPaths: _audioPaths.where((p) => p.isNotEmpty).toList(),
      weather: _weather,
      mood: _mood,
      location: _location,
    );
    Navigator.of(context).pop(entry);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(icon: Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: Text('${_date.month}月${_date.day}日  ${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}  ${_weekdayStr(_date.weekday)}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        centerTitle: true,
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
              ),
              SizedBox(height: 12),
              // 图片九宫格
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ..._imagePaths.asMap().entries.map((e) => GestureDetector(
                    onTap: () => showDialog(
                      context: context,
                      builder: (_) => Dialog(
                        child: InteractiveViewer(
                          child: Image.file(File(e.value)),
                        ),
                      ),
                    ),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.file(
                            File(e.value),
                            width: 90,
                            height: 90,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => _removeImage(e.key),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.close, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
                  if (_imagePaths.length < 9)
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.add, size: 32, color: Colors.grey),
                      ),
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
              ..._audioPaths.asMap().entries.map((entry) {
                final idx = entry.key;
                final path = entry.value;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
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
                    onPathUpdated: (newPath) => _updateAudioPath(idx, newPath),
                  ),
                );
              }),
              SizedBox(height: 16),
              // 天气选择
              Row(
                children: [
                  Text('天气：', style: TextStyle(fontSize: 16)),
                  ..._weatherSvgOptions.map((opt) => IconButton(
                    icon: SvgPicture.asset(opt['icon'], width: 32, height: 32, color: _weather == opt['label'] ? Colors.blue : Colors.grey),
                    onPressed: () => setState(() => _weather = opt['label']),
                    tooltip: opt['label'],
                  )),
                ],
              ),
              // 心情选择
              Row(
                children: [
                  Text('心情：', style: TextStyle(fontSize: 16)),
                  ..._moodSvgOptions.map((opt) => IconButton(
                    icon: SvgPicture.asset(opt['icon'], width: 32, height: 32, color: _mood == opt['label'] ? Colors.orange : Colors.grey),
                    onPressed: () => setState(() => _mood = opt['label']),
                    tooltip: opt['label'],
                  )),
                ],
              ),
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
                      onChanged: (val) => setState(() => _location = val),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('取消'),
                  ),
                  SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _save,
                    child: Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _weekdayStr(int weekday) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${weekdays[(weekday - 1) % 7]}';
  }
} 