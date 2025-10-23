import 'package:flutter/foundation.dart';

/// Simple app-wide logger.
/// In debug mode it prints to console. In release mode it can be disabled.
class Logger {
  Logger._();

  static bool get enabled => !kReleaseMode;

  static void i(String message) {
    if (enabled) {
      // ignore: avoid_print
      print('[INFO] $message');
    }
  }

  static void d(String message) {
    if (enabled) {
      // ignore: avoid_print
      print('[DEBUG] $message');
    }
  }

  static void w(String message) {
    if (enabled) {
      // ignore: avoid_print
      print('[WARN] $message');
    }
  }

  static void e(String message, [Object? error, StackTrace? stackTrace]) {
    if (enabled) {
      // ignore: avoid_print
      print('[ERROR] $message${error != null ? ' Error: $error' : ''}');
      if (stackTrace != null) {
        // ignore: avoid_print
        print(stackTrace);
      }
    }
  }
}

