import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_services.dart';
import 'screens/home_screen.dart';
import 'services/audio_playback_service.dart';
import 'services/audio_recorder_service.dart';
import 'services/classifier_service.dart';
import 'services/settings_service.dart';
import 'services/storage_service.dart';
import 'utils/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final settings = SettingsService();
  final storage = StorageService();
  final classifier = ClassifierService();
  final recorder = AudioRecorderService(storage, classifier);
  final playback = AudioPlaybackService();

  // Warm up the classifier so the first clip doesn't stall on inference.
  unawaited(classifier.init());

  runApp(SnoreLoreApp(
    settings: settings,
    storage: storage,
    classifier: classifier,
    recorder: recorder,
    playback: playback,
  ));
}

class SnoreLoreApp extends StatelessWidget {
  final SettingsService settings;
  final StorageService storage;
  final ClassifierService classifier;
  final AudioRecorderService recorder;
  final AudioPlaybackService playback;

  const SnoreLoreApp({
    super.key,
    required this.settings,
    required this.storage,
    required this.classifier,
    required this.recorder,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    return AppServices(
      settings: settings,
      storage: storage,
      classifier: classifier,
      recorder: recorder,
      playback: playback,
      child: MaterialApp(
        title: 'SnoreLore',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
