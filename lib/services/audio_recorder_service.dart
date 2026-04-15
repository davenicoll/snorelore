import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/app_settings.dart';
import '../models/recording.dart';
import '../utils/categories.dart';
import 'classifier_service.dart';
import 'storage_service.dart';

enum RecorderPhase { idle, listening, capturing, cooldown }

class SessionStatus {
  final RecorderPhase phase;
  final int segmentsCaptured;
  final DateTime? sessionStartedAt;
  final DateTime? endsAt;
  final double lastAmplitudeDb;
  final bool ignoreWindow;
  final Duration? remainingIgnore;

  const SessionStatus({
    required this.phase,
    required this.segmentsCaptured,
    required this.sessionStartedAt,
    required this.endsAt,
    required this.lastAmplitudeDb,
    required this.ignoreWindow,
    required this.remainingIgnore,
  });

  SessionStatus copyWith({
    RecorderPhase? phase,
    int? segmentsCaptured,
    DateTime? sessionStartedAt,
    DateTime? endsAt,
    double? lastAmplitudeDb,
    bool? ignoreWindow,
    Duration? remainingIgnore,
  }) =>
      SessionStatus(
        phase: phase ?? this.phase,
        segmentsCaptured: segmentsCaptured ?? this.segmentsCaptured,
        sessionStartedAt: sessionStartedAt ?? this.sessionStartedAt,
        endsAt: endsAt ?? this.endsAt,
        lastAmplitudeDb: lastAmplitudeDb ?? this.lastAmplitudeDb,
        ignoreWindow: ignoreWindow ?? this.ignoreWindow,
        remainingIgnore: remainingIgnore ?? this.remainingIgnore,
      );

  static const idle = SessionStatus(
    phase: RecorderPhase.idle,
    segmentsCaptured: 0,
    sessionStartedAt: null,
    endsAt: null,
    lastAmplitudeDb: -100,
    ignoreWindow: false,
    remainingIgnore: null,
  );
}

typedef SegmentCallback = void Function(Recording r);

/// Amplitude-triggered recorder. Polls the mic; when the level exceeds the
/// configured threshold, starts writing a WAV segment. Stops when silence
/// persists for [_silenceGap] or after [maxSegmentSeconds]. Then waits
/// [cooldownSeconds] before listening again.
class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();
  final StorageService _storage;
  final ClassifierService _classifier;
  final _uuid = const Uuid();

  Timer? _pollTimer;
  Timer? _endTimer;
  bool _running = false;

  // Segment state
  DateTime? _segmentStartedAt;
  String? _segmentPath;
  double _peakDb = -100;
  double _sumDb = 0;
  int _dbSamples = 0;
  DateTime? _lastLoudAt;
  final List<double> _waveform = [];

  // Session state
  AppSettings _settings = const AppSettings();
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndsAt;
  int _segmentsCaptured = 0;
  DateTime? _cooldownUntil;

  static const Duration _pollInterval = Duration(milliseconds: 200);
  static const Duration _silenceGap = Duration(seconds: 3);

  final StreamController<SessionStatus> _statusCtrl =
      StreamController<SessionStatus>.broadcast();
  SessionStatus _status = SessionStatus.idle;

  final List<SegmentCallback> _listeners = [];

  AudioRecorderService(this._storage, this._classifier);

  Stream<SessionStatus> get status$ => _statusCtrl.stream;
  SessionStatus get status => _status;
  bool get isRunning => _running;

  void addSegmentListener(SegmentCallback cb) => _listeners.add(cb);
  void removeSegmentListener(SegmentCallback cb) => _listeners.remove(cb);

  void _emit() {
    _statusCtrl.add(_status);
  }

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start({
    required AppSettings settings,
    DateTime? endsAt,
  }) async {
    if (_running) return;
    final ok = await hasPermission();
    if (!ok) throw StateError('Microphone permission denied');

    _settings = settings;
    _sessionStartedAt = DateTime.now();
    _sessionEndsAt = endsAt;
    _segmentsCaptured = 0;
    _running = true;
    _cooldownUntil = null;

    _status = SessionStatus.idle.copyWith(
      phase: RecorderPhase.listening,
      sessionStartedAt: _sessionStartedAt,
      endsAt: _sessionEndsAt,
      segmentsCaptured: 0,
    );
    _emit();

    if (endsAt != null) {
      final dur = endsAt.difference(DateTime.now());
      if (dur.inSeconds > 0) {
        _endTimer = Timer(dur, () => stop());
      }
    }

    await _beginSegmentRecording();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _onTick());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _endTimer?.cancel();
    _endTimer = null;

    try {
      final path = await _recorder.stop();
      // Drop the in-progress segment; nothing worth keeping here.
      if (path != null) {
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    _resetSegment();

    _status = SessionStatus.idle.copyWith(segmentsCaptured: _segmentsCaptured);
    _emit();
  }

  Future<void> _beginSegmentRecording() async {
    final path = await _storage.newRecordingPath();
    _segmentPath = path.replaceAll('.m4a', '.wav');
    _segmentStartedAt = DateTime.now();
    _peakDb = -100;
    _sumDb = 0;
    _dbSamples = 0;
    _lastLoudAt = null;
    _waveform.clear();

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _segmentPath!,
    );
  }

  void _resetSegment() {
    _segmentPath = null;
    _segmentStartedAt = null;
    _peakDb = -100;
    _sumDb = 0;
    _dbSamples = 0;
    _lastLoudAt = null;
    _waveform.clear();
  }

  Future<void> _onTick() async {
    if (!_running) return;
    final now = DateTime.now();

    // Session end?
    if (_sessionEndsAt != null && now.isAfter(_sessionEndsAt!)) {
      await stop();
      return;
    }

    // Ignore-first window still active?
    final ignoreEnd =
        _sessionStartedAt!.add(Duration(minutes: _settings.ignoreFirstMinutes));
    final inIgnoreWindow = now.isBefore(ignoreEnd);

    // Cooldown?
    if (_cooldownUntil != null) {
      if (now.isBefore(_cooldownUntil!)) {
        _status = _status.copyWith(
          phase: RecorderPhase.cooldown,
          lastAmplitudeDb: -100,
          ignoreWindow: inIgnoreWindow,
          remainingIgnore:
              inIgnoreWindow ? ignoreEnd.difference(now) : Duration.zero,
        );
        _emit();
        return;
      }
      _cooldownUntil = null;
      await _beginSegmentRecording();
    }

    // Read amplitude.
    final amp = await _recorder.getAmplitude();
    final db = amp.current.isFinite ? amp.current : -100.0;

    final threshold = _settings.amplitudeThresholdDb;
    final loud = db > threshold;

    _peakDb = math.max(_peakDb, db);
    _sumDb += db;
    _dbSamples++;

    // Track waveform (normalize -60..0 dB → 0..1)
    final sample = ((db + 60) / 60).clamp(0.0, 1.0);
    _waveform.add(sample);

    // Don't capture during the ignore window — but keep collecting amplitude
    // so we can show activity.
    if (inIgnoreWindow) {
      _status = _status.copyWith(
        phase: RecorderPhase.listening,
        lastAmplitudeDb: db,
        ignoreWindow: true,
        remainingIgnore: ignoreEnd.difference(now),
      );
      _emit();
      // Reset segment state so we don't accidentally save part of the
      // pre-sleep period when the window closes.
      _lastLoudAt = null;
      if (_segmentStartedAt != null &&
          now.difference(_segmentStartedAt!).inSeconds > 30) {
        await _discardAndRestartSegment();
      }
      return;
    }

    if (loud) {
      _lastLoudAt ??= now;
      // Extend the "last loud at" so silence detection waits for quiet.
      _lastLoudAt = now;
    }

    final inCapture = _lastLoudAt != null;
    final segAge = _segmentStartedAt == null
        ? Duration.zero
        : now.difference(_segmentStartedAt!);

    if (inCapture) {
      final silence = now.difference(_lastLoudAt!);
      if (silence > _silenceGap ||
          segAge.inSeconds >= _settings.maxSegmentSeconds) {
        await _finishSegment();
      } else {
        _status = _status.copyWith(
          phase: RecorderPhase.capturing,
          lastAmplitudeDb: db,
          ignoreWindow: false,
          remainingIgnore: Duration.zero,
        );
        _emit();
      }
    } else {
      // Listening only. Keep the rolling segment short so we don't waste disk.
      if (segAge.inSeconds > 10) {
        await _discardAndRestartSegment();
      }
      _status = _status.copyWith(
        phase: RecorderPhase.listening,
        lastAmplitudeDb: db,
        ignoreWindow: false,
        remainingIgnore: Duration.zero,
      );
      _emit();
    }
  }

  Future<void> _discardAndRestartSegment() async {
    try {
      final path = await _recorder.stop();
      if (path != null) {
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    _resetSegment();
    await _beginSegmentRecording();
  }

  Future<void> _finishSegment() async {
    final path = _segmentPath;
    final startedAt = _segmentStartedAt;
    if (path == null || startedAt == null) return;

    String? stoppedPath;
    try {
      stoppedPath = await _recorder.stop();
    } catch (_) {}
    final finalPath = stoppedPath ?? path;
    final duration = DateTime.now().difference(startedAt);

    if (duration.inSeconds < _settings.minSegmentSeconds) {
      final f = File(finalPath);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } else {
      final avgDb = _dbSamples == 0 ? -100.0 : _sumDb / _dbSamples;
      // Downsample waveform to ~120 points for UI.
      final wf = _downsample(_waveform, 120);

      SoundCategory cat = SoundCategory.unknown;
      String catLabel = 'Other';
      double conf = 0;
      try {
        final r = await _classifier.classifyWavFile(finalPath);
        if (r != null) {
          cat = r.category;
          catLabel = r.label;
          conf = r.confidence;
        }
      } catch (_) {}

      final rec = Recording(
        id: _uuid.v4(),
        filePath: finalPath,
        startedAt: startedAt,
        durationMs: duration.inMilliseconds,
        peakDb: _peakDb,
        avgDb: avgDb,
        category: cat,
        categoryLabel: catLabel,
        categoryConfidence: conf,
        waveform: wf,
      );
      await _storage.add(rec);
      _segmentsCaptured++;
      for (final cb in _listeners) {
        cb(rec);
      }
    }

    _resetSegment();

    // Enter cooldown and leave the mic alone until it ends.
    _cooldownUntil =
        DateTime.now().add(Duration(seconds: _settings.cooldownSeconds));
    _status = _status.copyWith(
      phase: RecorderPhase.cooldown,
      segmentsCaptured: _segmentsCaptured,
      lastAmplitudeDb: -100,
    );
    _emit();
  }

  List<double> _downsample(List<double> src, int target) {
    if (src.isEmpty) return const [];
    if (src.length <= target) return List.of(src);
    final out = <double>[];
    final bucket = src.length / target;
    for (var i = 0; i < target; i++) {
      final start = (i * bucket).floor();
      final end = math.min(((i + 1) * bucket).floor(), src.length);
      double mx = 0;
      for (var j = start; j < end; j++) {
        if (src[j] > mx) mx = src[j];
      }
      out.add(mx);
    }
    return out;
  }

  void dispose() {
    _pollTimer?.cancel();
    _endTimer?.cancel();
    _statusCtrl.close();
    _recorder.dispose();
  }
}
