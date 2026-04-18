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
}
