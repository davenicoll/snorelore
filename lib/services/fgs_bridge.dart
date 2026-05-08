import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Thin wrapper over the native Android foreground service. On non-Android
/// platforms all calls no-op, so the recorder logic can stay platform-agnostic.
class FgsBridge {
  static const _channel = MethodChannel('snorelore/fgs');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<void> update({required String title, required String content}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'content': content,
      });
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final v = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// Schedule a one-shot AlarmManager broadcast to wake the app at
  /// [fireAt]. Returns true if the OS accepted the schedule.
  static Future<bool> scheduleAutoStart(DateTime fireAt) async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>(
        'scheduleAutoStart',
        {'epochMs': fireAt.millisecondsSinceEpoch},
      );
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> cancelAutoStart() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelAutoStart');
    } catch (_) {}
  }

  /// Currently-armed alarm time, or null if nothing is scheduled.
  static Future<DateTime?> autoStartScheduledAt() async {
    if (!Platform.isAndroid) return null;
    try {
      final v = await _channel.invokeMethod<int>('autoStartScheduledAt');
      if (v == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(v);
    } catch (_) {
      return null;
    }
  }

  /// On API 31+, exact alarms require user grant unless USE_EXACT_ALARM
  /// applies. False here means we should send the user to settings.
  static Future<bool> canScheduleExact() async {
    if (!Platform.isAndroid) return true;
    try {
      final v = await _channel.invokeMethod<bool>('canScheduleExact');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openExactAlarmSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openExactAlarmSettings');
    } catch (_) {}
  }

  /// Returns true once if there's a pending auto-start (either from a
  /// just-fired alarm or a launch intent extra). The flag is cleared
  /// on read.
  static Future<bool> consumePendingAutoStart() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('consumePendingAutoStart');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
