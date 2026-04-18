import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/app_settings.dart';
import '../models/recording.dart';
import '../utils/categories.dart';
import 'classifier_service.dart';
import 'fgs_bridge.dart';
import 'storage_service.dart';

enum RecorderPhase { idle, listening, capturing }

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

const int _sampleRate = 16000;
const int _bytesPerSample = 2;
const int _bytesPerSecond = _sampleRate * _bytesPerSample;

/// PCM-streaming recorder. Subscribes to raw 16 kHz mono int16 samples from
/// the mic, keeps a short ring buffer so we can pre-roll when a trigger
/// fires, and holds the file open while quiet passages pass until a full
/// post-roll of silence has elapsed.
class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();
  final StorageService _storage;
  final ClassifierService _classifier;
  final _uuid = const Uuid();

  StreamSubscription<Uint8List>? _sub;
  bool _running = false;
  Timer? _endTimer;
  Timer? _statusTimer;

  // Session state
  AppSettings _settings = const AppSettings();
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndsAt;
  int _segmentsCaptured = 0;

  // Pre-roll ring buffer of raw PCM bytes — sized to `preRollSeconds`.
  final Queue<Uint8List> _preRoll = Queue();
  int _preRollBytes = 0;

  // Capture-in-progress state
  bool _capturing = false;
  final List<Uint8List> _captureChunks = [];
  int _captureBytes = 0;
  DateTime? _captureStartedAt;
  DateTime? _lastLoudAt;
  double _peakDb = -100;
  double _sumDb = 0;
  int _dbSamples = 0;
  final List<double> _waveform = [];

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

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Hot-swap the session config. Safe to call whether or not a session is
  /// running. Threshold, pre-roll length, post-roll, and ignore window all
  /// take effect immediately.
  void updateSettings(AppSettings s) {
    _settings = s;
    // Shrink the pre-roll buffer if the user reduced pre-roll length.
    final maxBytes = s.preRollSeconds * _bytesPerSecond;
    while (_preRollBytes > maxBytes && _preRoll.isNotEmpty) {
      final head = _preRoll.removeFirst();
      _preRollBytes -= head.length;
    }
    _emit();
  }

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

    await FgsBridge.start();
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
    ));
    _sub = stream.listen(_onChunk, onError: (_) {}, cancelOnError: false);

    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) => _emit());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _endTimer?.cancel();
    _endTimer = null;
    _statusTimer?.cancel();
    _statusTimer = null;

    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}

    // If we were mid-capture when stop was called, commit what we have if
    // it's long enough — otherwise discard. We don't want half-finished
    // segments silently lost.
    if (_capturing) {
      await _finalizeCapture(forced: true);
    }
    _preRoll.clear();
    _preRollBytes = 0;

    await FgsBridge.stop();

    _status = SessionStatus.idle.copyWith(segmentsCaptured: _segmentsCaptured);
    _emit();
  }

  void _onChunk(Uint8List chunk) {
    if (!_running) return;
    final now = DateTime.now();
    final db = _computeDb(chunk);

    // Session end enforced by timer, but also check here for robustness.
    if (_sessionEndsAt != null && now.isAfter(_sessionEndsAt!)) {
      unawaited(stop());
      return;
    }

    final ignoreEnd =
        _sessionStartedAt!.add(Duration(minutes: _settings.ignoreFirstMinutes));
    final inIgnoreWindow = now.isBefore(ignoreEnd);

    final threshold = _settings.amplitudeThresholdDb;
    final loud = db > threshold;

    if (_capturing) {
      _captureChunks.add(chunk);
      _captureBytes += chunk.length;
      if (loud) _lastLoudAt = now;

      _peakDb = math.max(_peakDb, db);
      _sumDb += db;
      _dbSamples++;
      _waveform.addAll(_subSamples(chunk));

      final capAge = now.difference(_captureStartedAt!);
      final silence = _lastLoudAt == null
          ? capAge
          : now.difference(_lastLoudAt!);
      final postRollOver = silence.inSeconds >= _settings.postRollSeconds;
      final maxReached = capAge.inSeconds >= _settings.maxSegmentSeconds;

      _status = _status.copyWith(
        phase: RecorderPhase.capturing,
        lastAmplitudeDb: db,
        ignoreWindow: false,
        remainingIgnore: Duration.zero,
      );

      if (postRollOver || maxReached) {
        unawaited(_finalizeCapture());
      }
      return;
    }

    // Not capturing — buffer into pre-roll ring.
    _pushPreRoll(chunk);

    if (!inIgnoreWindow && loud) {
      _beginCapture(now);
    } else {
      _status = _status.copyWith(
        phase: RecorderPhase.listening,
        lastAmplitudeDb: db,
        ignoreWindow: inIgnoreWindow,
        remainingIgnore:
            inIgnoreWindow ? ignoreEnd.difference(now) : Duration.zero,
      );
    }
  }

  void _pushPreRoll(Uint8List chunk) {
    _preRoll.add(chunk);
    _preRollBytes += chunk.length;
    final maxBytes = _settings.preRollSeconds * _bytesPerSecond;
    while (_preRollBytes > maxBytes && _preRoll.isNotEmpty) {
      final head = _preRoll.removeFirst();
      _preRollBytes -= head.length;
    }
  }

  void _beginCapture(DateTime now) {
    _capturing = true;
    _captureStartedAt =
        now.subtract(Duration(seconds: _settings.preRollSeconds));
    _lastLoudAt = now;
    _captureChunks.clear();
    _captureBytes = 0;
    _peakDb = -100;
    _sumDb = 0;
    _dbSamples = 0;
    _waveform.clear();

    // Seed capture with the pre-roll.
    for (final c in _preRoll) {
      _captureChunks.add(c);
      _captureBytes += c.length;
      final n = c.length ~/ _bytesPerSample;
      final db = _computeDb(c);
      _sumDb += db * n;
      _dbSamples += n;
      _peakDb = math.max(_peakDb, db);
      _waveform.addAll(_subSamples(c));
    }
  }

  /// Produce multiple waveform points per PCM chunk so that short clips
  /// still render with fine-grained bars. Each point covers a ~20 ms window
  /// (320 samples at 16 kHz) so we get ~50 points per second of audio.
  static const int _wfWindowSamples = 320;
  List<double> _subSamples(Uint8List chunk) {
    final n = chunk.length ~/ _bytesPerSample;
    if (n == 0) return const [];
    final bd = ByteData.sublistView(chunk);
    final out = <double>[];
    for (var start = 0; start < n; start += _wfWindowSamples) {
      final end = math.min(start + _wfWindowSamples, n);
      var peak = 0;
      for (var i = start; i < end; i++) {
        final s = bd.getInt16(i * _bytesPerSample, Endian.little).abs();
        if (s > peak) peak = s;
      }
      if (peak == 0) {
        out.add(0);
        continue;
      }
      final db = 20 * (math.log(peak / 32768.0) / math.ln10);
      out.add(((db + 60) / 60).clamp(0.0, 1.0));
    }
    return out;
  }

  Future<void> _finalizeCapture({bool forced = false}) async {
    if (!_capturing) return;
    _capturing = false;
    final chunks = List<Uint8List>.from(_captureChunks);
    final bytes = _captureBytes;
    final startedAt = _captureStartedAt!;
    final peak = _peakDb;
    final avgDb = _dbSamples == 0 ? -100.0 : _sumDb / _dbSamples;
    final wf = _downsample(_waveform, 240);

    _captureChunks.clear();
    _captureBytes = 0;
    _captureStartedAt = null;
    _lastLoudAt = null;
    _peakDb = -100;
    _sumDb = 0;
    _dbSamples = 0;
    _waveform.clear();

    final duration = DateTime.now().difference(startedAt);
    if (duration.inSeconds < _settings.minSegmentSeconds && forced) {
      // Too short; drop it.
      return;
    }
    if (duration.inSeconds < _settings.minSegmentSeconds) return;

    final path = await _storage.newRecordingPath();
    final wavPath = path.replaceAll('.m4a', '.wav');
    final file = File(wavPath);
    final sink = file.openWrite();
    try {
      sink.add(_buildWavHeader(bytes));
      for (final c in chunks) {
        sink.add(c);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    SoundCategory cat = SoundCategory.unknown;
    String catLabel = 'Other';
    double conf = 0;
    List<SoundCategory> tags = const [];
    try {
      final r = await _classifier.classifyWavFile(wavPath);
      if (r != null) {
        cat = r.primary.category;
        catLabel = r.primary.label;
        conf = r.primary.confidence;
        tags = r.tags.map((t) => t.category).toList();
      }
    } catch (_) {}

    final rec = Recording(
      id: _uuid.v4(),
      filePath: wavPath,
      startedAt: startedAt,
      durationMs: duration.inMilliseconds,
      peakDb: peak,
      avgDb: avgDb,
      category: cat,
      categoryLabel: catLabel,
      categoryConfidence: conf,
      tags: tags,
      waveform: wf,
    );
    await _storage.add(rec);
    _segmentsCaptured++;
    for (final cb in _listeners) {
      cb(rec);
    }
    _emit();
  }

  /// Compute peak-dBFS of a PCM chunk (int16 LE samples). Peak catches
  /// transients better than RMS for our amplitude-trigger purposes.
  double _computeDb(Uint8List chunk) {
    final n = chunk.length ~/ _bytesPerSample;
    if (n == 0) return -100;
    final bd = ByteData.sublistView(chunk);
    int peak = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * _bytesPerSample, Endian.little).abs();
      if (s > peak) peak = s;
    }
    if (peak == 0) return -100;
    final norm = peak / 32768.0;
    return 20 * (math.log(norm) / math.ln10);
  }

  Uint8List _buildWavHeader(int dataBytes) {
    final header = ByteData(44);
    // "RIFF"
    header.setUint8(0, 0x52);
    header.setUint8(1, 0x49);
    header.setUint8(2, 0x46);
    header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataBytes, Endian.little);
    // "WAVE"
    header.setUint8(8, 0x57);
    header.setUint8(9, 0x41);
    header.setUint8(10, 0x56);
    header.setUint8(11, 0x45);
    // "fmt "
    header.setUint8(12, 0x66);
    header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74);
    header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // channels
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, _bytesPerSecond, Endian.little);
    header.setUint16(32, _bytesPerSample, Endian.little);
    header.setUint16(34, 16, Endian.little);
    // "data"
    header.setUint8(36, 0x64);
    header.setUint8(37, 0x61);
    header.setUint8(38, 0x74);
    header.setUint8(39, 0x61);
    header.setUint32(40, dataBytes, Endian.little);
    return header.buffer.asUint8List();
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

  void _emit() {
    _statusCtrl.add(_status);
  }

  void dispose() {
    _endTimer?.cancel();
    _statusTimer?.cancel();
    _sub?.cancel();
    _statusCtrl.close();
    _recorder.dispose();
  }
}
