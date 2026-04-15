import 'package:flutter/material.dart';

class AppSettings {
  final bool autoSchedule;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final int ignoreFirstMinutes;
  final double sensitivity;
  final int preRollSeconds;
  final int postRollSeconds;
  final int maxSegmentSeconds;
  final int minSegmentSeconds;

  const AppSettings({
    this.autoSchedule = false,
    this.startTime = const TimeOfDay(hour: 22, minute: 30),
    this.endTime = const TimeOfDay(hour: 7, minute: 0),
    this.ignoreFirstMinutes = 20,
    this.sensitivity = 0.5,
    this.preRollSeconds = 2,
    this.postRollSeconds = 60,
    this.maxSegmentSeconds = 120,
    this.minSegmentSeconds = 2,
  });

  AppSettings copyWith({
    bool? autoSchedule,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    int? ignoreFirstMinutes,
    double? sensitivity,
    int? preRollSeconds,
    int? postRollSeconds,
    int? maxSegmentSeconds,
    int? minSegmentSeconds,
  }) {
    return AppSettings(
      autoSchedule: autoSchedule ?? this.autoSchedule,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      ignoreFirstMinutes: ignoreFirstMinutes ?? this.ignoreFirstMinutes,
      sensitivity: sensitivity ?? this.sensitivity,
      preRollSeconds: preRollSeconds ?? this.preRollSeconds,
      postRollSeconds: postRollSeconds ?? this.postRollSeconds,
      maxSegmentSeconds: maxSegmentSeconds ?? this.maxSegmentSeconds,
      minSegmentSeconds: minSegmentSeconds ?? this.minSegmentSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
        'autoSchedule': autoSchedule,
        'startHour': startTime.hour,
        'startMinute': startTime.minute,
        'endHour': endTime.hour,
        'endMinute': endTime.minute,
        'ignoreFirstMinutes': ignoreFirstMinutes,
        'sensitivity': sensitivity,
        'preRollSeconds': preRollSeconds,
        'postRollSeconds': postRollSeconds,
        'maxSegmentSeconds': maxSegmentSeconds,
        'minSegmentSeconds': minSegmentSeconds,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        autoSchedule: j['autoSchedule'] as bool? ?? false,
        startTime: TimeOfDay(
          hour: j['startHour'] as int? ?? 22,
          minute: j['startMinute'] as int? ?? 30,
        ),
        endTime: TimeOfDay(
          hour: j['endHour'] as int? ?? 7,
          minute: j['endMinute'] as int? ?? 0,
        ),
        ignoreFirstMinutes: j['ignoreFirstMinutes'] as int? ?? 20,
        sensitivity: (j['sensitivity'] as num?)?.toDouble() ?? 0.5,
        preRollSeconds: j['preRollSeconds'] as int? ?? 2,
        // Backward compat: old settings used `cooldownSeconds`, now
        // interpreted as the post-roll (time to keep recording after silence).
        postRollSeconds: (j['postRollSeconds'] ?? j['cooldownSeconds']) as int? ?? 60,
        maxSegmentSeconds: j['maxSegmentSeconds'] as int? ?? 120,
        minSegmentSeconds: j['minSegmentSeconds'] as int? ?? 2,
      );

  /// Amplitude threshold in dBFS. At sensitivity=0.0 we only pick up loud
  /// sounds (>-25 dB); at 1.0 we trigger on quiet sounds (>-55 dB).
  double get amplitudeThresholdDb => -25.0 - (sensitivity * 30.0);
}
