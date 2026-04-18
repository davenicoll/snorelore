import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../utils/categories.dart';

class ClassificationResult {
  final SoundCategory category;
  final String label;
  final double confidence;
  const ClassificationResult({
    required this.category,
    required this.label,
    required this.confidence,
  });
}

/// Outcome of classifying a whole clip. [primary] is what we show as the
/// recording's category; [tags] are other categories that also appeared
/// above a confidence threshold somewhere in the clip.
class ClipClassification {
  final ClassificationResult primary;
  final List<ClassificationResult> tags;
  const ClipClassification({required this.primary, required this.tags});
}

/// Runs the embedded YAMNet audio classifier. YAMNet expects a mono
/// waveform of 15600 samples at 16 kHz (0.975 s) as float32 in [-1, 1], and
/// returns a 521-class probability vector.
///
/// https://www.tensorflow.org/hub/tutorials/yamnet
class ClassifierService {
  static const String _modelAsset = 'assets/models/yamnet.tflite';
  static const String _labelsAsset = 'assets/models/yamnet_class_map.csv';
  static const int _frame = 15600;

  Interpreter? _interp;
  List<String> _labels = const [];
  bool _initialising = false;

  Future<void> init() async {
    if (_interp != null || _initialising) return;
    _initialising = true;
    try {
      _interp = await Interpreter.fromAsset(_modelAsset);
      final labelsRaw = await rootBundle.loadString(_labelsAsset);
      _labels = labelsRaw
          .split('\n')
          .skip(1)
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((l) {
            // Lines look like: 0,/m/09x0r,Speech
            final parts = l.split(',');
            return parts.length >= 3 ? parts.sublist(2).join(',') : l;
          })
          .toList();
    } catch (e) {
      // Leave _interp null; the caller will gracefully skip classification.
    } finally {
      _initialising = false;
    }
  }

  bool get ready => _interp != null && _labels.isNotEmpty;

  /// Score at which a non-primary category is promoted to a tag on the clip.
  /// YAMNet scores are softmax probabilities across 521 classes, so anything
  /// approaching 0.1 is already a reasonably strong signal.
  static const double _tagThreshold = 0.10;

  /// Cap the total number of YAMNet inferences per clip. A 2-minute clip at
  /// ~1 window/s would otherwise run 120+ inferences.
  static const int _maxWindows = 60;

  Future<ClipClassification?> classifyWavFile(String path) async {
    if (_interp == null) await init();
    if (_interp == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final samples = _decodePcm16MonoFromWav(bytes);
    if (samples.isEmpty) return null;
    return _classifySamples(samples);
  }

  /// Slides YAMNet's 0.975s input window across the full clip and keeps the
  /// per-class max score. Max (not average) is what we want: a 40s mostly-
  /// quiet clip with one 3s snore should still score high on "Snoring".
  ClipClassification? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null) return null;

    // Build the list of window start offsets. For short clips we zero-pad a
    // single frame; otherwise we stride through the audio. If the number of
    // windows would exceed the cap, we widen the stride so we still cover
    // the whole clip — we just sample it more coarsely.
    final starts = <int>[];
    if (samples.length <= _frame) {
      starts.add(0);
    } else {
      final usable = samples.length - _frame;
      var step = _frame; // no overlap by default
      final naive = usable ~/ step + 1;
      if (naive > _maxWindows) {
        step = usable ~/ (_maxWindows - 1);
        if (step < 1) step = 1;
      }
      for (var s = 0; s <= usable; s += step) {
        starts.add(s);
        if (starts.length >= _maxWindows) break;
      }
    }
    if (starts.isEmpty) return null;

    final maxScores = List<double>.filled(521, 0);

    // Reusable output buffers — TFLite needs the exact shape each call, but
    // we can let Dart reuse the lists.
    final scoresOut = List.generate(1, (_) => List<double>.filled(521, 0));
    final embOut = List.generate(1, (_) => List<double>.filled(1024, 0));
    final specOut = List.generate(
        1, (_) => List.generate(96, (_) => List<double>.filled(64, 0)));

    for (final start in starts) {
      Float32List frame;
      if (samples.length <= _frame) {
        frame = Float32List(_frame);
        frame.setRange(0, samples.length, samples);
      } else {
        frame = Float32List.sublistView(samples, start, start + _frame);
      }
      try {
        interp.runForMultipleInputs(
          [[frame]],
          {0: scoresOut, 1: embOut, 2: specOut},
        );
      } catch (_) {
        return null;
      }
      final row = scoresOut[0];
      for (var k = 0; k < 521; k++) {
        if (row[k] > maxScores[k]) maxScores[k] = row[k];
      }
    }

    return _pickPrimaryAndTags(maxScores);
  }

  ClipClassification? _pickPrimaryAndTags(List<double> maxScores) {
    // Per-category aggregation: for each of our simplified categories, keep
    // the best-scoring raw YAMNet label that maps to it.
    final best = <SoundCategory, (int, double)>{};
    for (var i = 0; i < maxScores.length; i++) {
      final score = maxScores[i];
      if (score <= 0) continue;
      final label = i < _labels.length ? _labels[i] : 'Unknown';
      final cat = mapYamnetLabel(label);
      final prev = best[cat];
      if (prev == null || score > prev.$2) {
        best[cat] = (i, score);
      }
    }
    if (best.isEmpty) return null;

    // Primary: highest-priority category whose best score is within 50% of
    // the globally top-scoring category. Keeps "Snoring" as the pick even
    // when YAMNet's argmax is a nearby "Cat purring".
    final globalTop = best.values.map((v) => v.$2).reduce(math.max);
    final nearTopFloor = globalTop * 0.5;
    SoundCategory primaryCat = SoundCategory.unknown;
    (int, double)? primaryHit;
    for (final cat in categoryPriority) {
      final hit = best[cat];
      if (hit != null && hit.$2 >= nearTopFloor) {
        primaryCat = cat;
        primaryHit = hit;
        break;
      }
    }
    primaryHit ??= best.entries
        .reduce((a, b) => a.value.$2 >= b.value.$2 ? a : b)
        .value;
    final primary = ClassificationResult(
      category: primaryCat,
      label: primaryHit.$1 < _labels.length ? _labels[primaryHit.$1] : 'Unknown',
      confidence: primaryHit.$2,
    );

    // Tags: other categories that crossed the threshold anywhere in the
    // clip. Sorted high to low, capped so we don't spam the UI. Skip the
    // primary and skip `unknown` (no value as a tag).
    final tags = <ClassificationResult>[];
    final entries = best.entries.toList()
      ..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    for (final e in entries) {
      if (e.key == primaryCat) continue;
      if (e.key == SoundCategory.unknown) continue;
      if (e.value.$2 < _tagThreshold) continue;
      final label =
          e.value.$1 < _labels.length ? _labels[e.value.$1] : 'Unknown';
      tags.add(ClassificationResult(
        category: e.key,
        label: label,
        confidence: e.value.$2,
      ));
      if (tags.length >= 4) break;
    }

    return ClipClassification(primary: primary, tags: tags);
  }

  /// Parses a standard RIFF WAV with PCM 16-bit mono data and returns the
  /// samples as float32 in [-1, 1]. Tolerates minor chunk ordering quirks.
  Float32List _decodePcm16MonoFromWav(Uint8List bytes) {
    if (bytes.length < 44) return Float32List(0);
    final bd = ByteData.sublistView(bytes);
    if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 || bytes[3] != 0x46) {
      return Float32List(0); // not RIFF
    }
    // Walk chunks to find "data".
    var offset = 12;
    int? dataOffset;
    int? dataLen;
    int channels = 1;
    int sampleRate = 16000;
    int bitsPerSample = 16;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = bd.getUint32(offset + 4, Endian.little);
      if (id == 'fmt ') {
        channels = bd.getUint16(offset + 10, Endian.little);
        sampleRate = bd.getUint32(offset + 12, Endian.little);
        bitsPerSample = bd.getUint16(offset + 22, Endian.little);
      } else if (id == 'data') {
        dataOffset = offset + 8;
        dataLen = size;
        break;
      }
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (dataOffset == null || dataLen == null || bitsPerSample != 16) {
      return Float32List(0);
    }
    final sampleCount = dataLen ~/ 2;
    final out = Float32List(sampleCount ~/ channels);
    final view = ByteData.sublistView(bytes, dataOffset, dataOffset + dataLen);
    if (channels == 1) {
      for (var i = 0; i < out.length; i++) {
        final s = view.getInt16(i * 2, Endian.little);
        out[i] = s / 32768.0;
      }
    } else {
      // Downmix channels by averaging.
      final frames = sampleCount ~/ channels;
      for (var f = 0; f < frames; f++) {
        var sum = 0;
        for (var c = 0; c < channels; c++) {
          sum += view.getInt16((f * channels + c) * 2, Endian.little);
        }
        out[f] = (sum / channels) / 32768.0;
      }
    }

    // If someone hands us non-16kHz audio (iOS historically ignored the
    // requested sample rate), do a naive nearest-neighbour resample.
    if (sampleRate != 16000 && out.isNotEmpty) {
      final ratio = 16000 / sampleRate;
      final resampledLen = (out.length * ratio).round();
      final resampled = Float32List(resampledLen);
      for (var i = 0; i < resampledLen; i++) {
        final srcIdx = (i / ratio).floor();
        resampled[i] = out[srcIdx.clamp(0, out.length - 1)];
      }
      return resampled;
    }
    return out;
  }
}
