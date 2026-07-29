import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Debug-only log mirror for devices whose OEM firmware suppresses Flutter
/// stdout from logcat. The host reads this file with `adb run-as`.
class DebugFileLog {
  DebugFileLog._();

  static IOSink? _sink;
  static String? _path;

  static String? get path => _path;

  static Future<void> initialize() async {
    if (!kDebugMode || _sink != null) return;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/codex_debug.log');
    _path = file.path;
    _sink = file.openWrite(mode: FileMode.writeOnly);
    write('[APP_LOG_READY] ${DateTime.now().toIso8601String()} path=$_path');
  }

  static void write(Object? message) {
    if (!kDebugMode) return;
    final text = message?.toString() ?? 'null';
    final timestamp = DateTime.now().toIso8601String();
    for (final line in text.split('\n')) {
      _sink?.writeln('$timestamp $line');
    }
  }

  static ZoneSpecification get zoneSpecification => ZoneSpecification(
    print: (self, parent, zone, line) {
      write(line);
      parent.print(zone, line);
    },
  );
}
