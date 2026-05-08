import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_services.dart';
import 'screens/home_screen.dart';
import 'services/audio_playback_service.dart';
import 'services/audio_recorder_service.dart';
import 'services/auto_start_service.dart';
import 'services/classifier_service.dart';
import 'services/session_log_service.dart';
import 'services/settings_service.dart';
import 'services/silero_vad_service.dart';
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
  final silero = SileroVadService();
  final classifier = ClassifierService(silero: silero);
  final sessionLog = SessionLogService();
  final recorder = AudioRecorderService(storage, classifier, sessionLog);
  final playback = AudioPlaybackService();
  final autoStart = AutoStartService();

  // Warm up both inference models so the first clip doesn't stall.
  unawaited(classifier.init());
  unawaited(silero.init());

  // Pick up an alarm-fired auto-start, if any. Has to happen after
  // the recorder is constructed but before runApp so the UI lands
  // already-running when the alarm woke the app.
  await autoStart.handleColdLaunch(
    settingsService: settings,
    recorder: recorder,
  );

  // Make sure the next alarm is armed for users who already had
  // auto-schedule on before this version. New installs will (re)arm
  // when they enable the toggle.
  if (!recorder.isRunning) {
    final s = await settings.load();
    if (s.autoSchedule) {
      unawaited(autoStart.scheduleNext(s));
    }
  }

  runApp(SnoreLoreApp(
    settings: settings,
    storage: storage,
    classifier: classifier,
    recorder: recorder,
    playback: playback,
    sessionLog: sessionLog,
  ));
}

class SnoreLoreApp extends StatelessWidget {
  final SettingsService settings;
  final StorageService storage;
  final ClassifierService classifier;
  final AudioRecorderService recorder;
  final AudioPlaybackService playback;
  final SessionLogService sessionLog;

  const SnoreLoreApp({
    super.key,
    required this.settings,
    required this.storage,
    required this.classifier,
    required this.recorder,
    required this.playback,
    required this.sessionLog,
  });

  @override
  Widget build(BuildContext context) {
    return AppServices(
      settings: settings,
      storage: storage,
      classifier: classifier,
      recorder: recorder,
      playback: playback,
      sessionLog: sessionLog,
      child: MaterialApp(
        title: 'SnoreLore',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
