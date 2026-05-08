import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import 'audio_recorder_service.dart';
import 'fgs_bridge.dart';
import 'settings_service.dart';

/// Wires the AlarmManager-based auto-start into the Dart side.
///
/// Two halves:
///   * [scheduleNext] — called when the user enables auto-schedule or
///     taps Start before the configured start-time. Tells the OS to
///     wake us at [AppSettings.startTime].
///   * [handleColdLaunch] — called once on app boot. If the alarm
///     already fired and dropped a `pending_auto_start` flag, kick off
///     the recorder so the user wakes up in the morning to clips.
class AutoStartService {
  static DateTime nextOccurrence(TimeOfDay t, {DateTime? from}) {
    final now = from ?? DateTime.now();
    var fire = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!fire.isAfter(now)) fire = fire.add(const Duration(days: 1));
    return fire;
  }

  static DateTime resolveEnd(TimeOfDay end, {DateTime? from}) {
    final now = from ?? DateTime.now();
    var stop = DateTime(now.year, now.month, now.day, end.hour, end.minute);
    if (!stop.isAfter(now)) stop = stop.add(const Duration(days: 1));
    return stop;
  }

  /// Schedule (or reschedule) the next auto-start firing. Returns the
  /// fire time on success, null if the OS rejected the request.
  Future<DateTime?> scheduleNext(AppSettings s) async {
    if (!s.autoSchedule) {
      await FgsBridge.cancelAutoStart();
      return null;
    }
    final fireAt = nextOccurrence(s.startTime);
    final ok = await FgsBridge.scheduleAutoStart(fireAt);
    return ok ? fireAt : null;
  }

  Future<void> cancel() => FgsBridge.cancelAutoStart();

  Future<DateTime?> currentScheduledAt() => FgsBridge.autoStartScheduledAt();

  Future<bool> canScheduleExact() => FgsBridge.canScheduleExact();

  Future<void> openExactAlarmSettings() => FgsBridge.openExactAlarmSettings();

  /// If the alarm fired before the app was open (or while it was), pick
  /// up the flag and start recording with the user's saved settings.
  Future<void> handleColdLaunch({
    required SettingsService settingsService,
    required AudioRecorderService recorder,
  }) async {
    final pending = await FgsBridge.consumePendingAutoStart();
    if (!pending) return;
    final s = await settingsService.load();
    if (!s.autoSchedule) return;
    try {
      final endsAt = resolveEnd(s.endTime);
      await recorder.start(settings: s, endsAt: endsAt);
      // Re-arm for tomorrow so the user doesn't have to do anything.
      await scheduleNext(s);
    } catch (e, st) {
      debugPrint('auto-start cold launch failed: $e\n$st');
    }
  }
}
