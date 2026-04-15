import 'package:flutter/widgets.dart';

import 'services/audio_recorder_service.dart';
import 'services/classifier_service.dart';
import 'services/settings_service.dart';
import 'services/storage_service.dart';

class AppServices extends InheritedWidget {
  final SettingsService settings;
  final StorageService storage;
  final ClassifierService classifier;
  final AudioRecorderService recorder;

  const AppServices({
    super.key,
    required this.settings,
    required this.storage,
    required this.classifier,
    required this.recorder,
    required super.child,
  });

  static AppServices of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppServices>();
    assert(s != null, 'AppServices missing in tree');
    return s!;
  }

  @override
  bool updateShouldNotify(covariant AppServices old) =>
      settings != old.settings ||
      storage != old.storage ||
      classifier != old.classifier ||
      recorder != old.recorder;
}
