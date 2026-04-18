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

/// Outcome of classifying a whole clip.
///
/// [primary] is what we show as the recording's category.
/// [tags] are other categories that also appeared above a confidence
/// threshold somewhere in the clip.
/// [windowCategories] is the dominant simplified category per YAMNet window
/// (roughly one per second of audio), used to colorise the waveform so the
/// listener can see when in the clip each category actually fired.
class ClipClassification {
  final ClassificationResult primary;
  final List<ClassificationResult> tags;
  final List<SoundCategory> windowCategories;
  const ClipClassification({
    required this.primary,
    required this.tags,
    required this.windowCategories,
  });
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
  List<SoundCategory> _labelCategories = const [];
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
      _labelCategories =
          _labels.map((l) => mapYamnetLabel(l)).toList(growable: false);
    } catch (e) {
      // Leave _interp null; the caller will gracefully skip classification.
    } finally {
      _initialising = false;
    }
  }

  bool get ready => _interp != null && _labels.isNotEmpty;

  /// Confidence floor for promoting a non-primary category onto the clip as
  /// a tag. YAMNet scores are softmax probabilities across 521 classes, so
  /// anything approaching 0.2 is a reasonably strong signal.
  static const double _tagThreshold = 0.20;

  /// Below this, we refuse to commit to any category and the clip is filed
  /// as "Other". Picking a noisy top category for a clip that's really just
  /// room tone produces the mis-labels the user is seeing.
  static const double _primaryMinConfidence = 0.10;

  /// How close a category's best score must be to the globally top-scoring
  /// category before we allow priority to swap it in. At 0.5 almost anything
  /// could override the raw top pick; at 0.75 we only reorder on near-ties.
  static const double _priorityFloorRatio = 0.75;

  /// Per-segment confidence floor for colouring the waveform. A segment
  /// below this threshold is rendered in the neutral base colour rather
  /// than tinted.
  static const double _windowMinConfidence = 0.15;

  /// Length of one classification segment. The waveform is coloured in
  /// bands of this size — one dominant category per band.
  static const int _segmentSeconds = 10;
  static const int _segmentSamples = _segmentSeconds * 16000;

  /// Cap the total number of YAMNet inferences per clip. For short clips
  /// we run YAMNet at its native 0.975 s stride within each segment; for
  /// long clips we thin that stride so the total stays under the cap. A
  /// 5-minute clip with the default cap runs ~3 inferences per 10 s band.
  static const int _maxTotalInferences = 90;

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

  /// Classifies the clip in non-overlapping 10 s segments. Each segment
  /// becomes one entry in the returned `windowCategories` list, which drives
  /// the per-band colouring of the waveform. Within each segment we run
  /// YAMNet multiple times at its native 0.975 s input size and take the
  /// per-class max, so a 10 s band of mostly-silence with one strong snore
  /// still scores high on Snoring. The per-clip primary and tags come from
  /// the max across every inference in the clip — same behaviour as before.
  ClipClassification? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null || samples.isEmpty) return null;

    final numSegments =
        math.max(1, (samples.length / _segmentSamples).ceil());
    // Budget YAMNet inferences across segments so long clips don't explode.
    // Each segment runs at least 1 inference; short clips run up to ~10
    // (0.975 s stride inside a 10 s band), long clips thin down.
    final perSegBudget =
        math.max(1, _maxTotalInferences ~/ numSegments);

    final maxScores = List<double>.filled(521, 0);
    final windowCategories = <SoundCategory>[];

    // Reusable output buffers — TFLite needs the exact shape each call, but
    // we can let Dart reuse the lists.
    final scoresOut = List.generate(1, (_) => List<double>.filled(521, 0));
    final embOut = List.generate(1, (_) => List<double>.filled(1024, 0));
    final specOut = List.generate(
        1, (_) => List.generate(96, (_) => List<double>.filled(64, 0)));

    for (var seg = 0; seg < numSegments; seg++) {
      final segStart = seg * _segmentSamples;
      final segEnd = math.min(segStart + _segmentSamples, samples.length);
      final segLen = segEnd - segStart;

      // Accumulate per-class max within this segment across its inferences.
      final segScores = List<double>.filled(521, 0);

      // Build inference offsets within the segment. For segments shorter
      // than one YAMNet frame we zero-pad and run once.
      final inferOffsets = <int>[];
      if (segLen <= _frame) {
        inferOffsets.add(0);
      } else {
        final usable = segLen - _frame;
        final budget = math.max(1, perSegBudget);
        final step = budget > 1
            ? math.max(_frame ~/ 2, usable ~/ (budget - 1))
            : usable;
        for (var off = 0; off <= usable; off += step) {
          inferOffsets.add(off);
          if (inferOffsets.length >= budget) break;
        }
        if (inferOffsets.isEmpty) inferOffsets.add(0);
      }

      for (final off in inferOffsets) {
        Float32List frame;
        if (segLen <= _frame) {
          frame = Float32List(_frame);
          for (var i = 0; i < segLen; i++) {
            frame[i] = samples[segStart + i];
          }
        } else {
          frame = Float32List.sublistView(
              samples, segStart + off, segStart + off + _frame);
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
          final s = row[k];
          if (s > segScores[k]) segScores[k] = s;
        }
      }

      // Roll segment max into the clip-wide max for the primary/tag pick.
      for (var k = 0; k < 521; k++) {
        if (segScores[k] > maxScores[k]) maxScores[k] = segScores[k];
      }

      // Per-segment dominant category: collapse raw classes to our simplified
      // set by taking each category's best-scoring class within this segment.
      final perCat = <SoundCategory, double>{};
      for (var k = 0; k < 521; k++) {
        final score = segScores[k];
        if (score <= 0) continue;
        final cat = k < _labelCategories.length
            ? _labelCategories[k]
            : SoundCategory.unknown;
        if (cat == SoundCategory.unknown) continue;
        final prev = perCat[cat];
        if (prev == null || score > prev) perCat[cat] = score;
      }
      SoundCategory winCat = SoundCategory.unknown;
      double winConf = 0;
      perCat.forEach((c, s) {
        if (s > winConf) {
          winConf = s;
          winCat = c;
        }
      });
      if (winConf < _windowMinConfidence) winCat = SoundCategory.unknown;
      windowCategories.add(winCat);
    }

    if (windowCategories.isEmpty) return null;
    return _pickPrimaryAndTags(maxScores, windowCategories);
  }

  ClipClassification? _pickPrimaryAndTags(
      List<double> maxScores, List<SoundCategory> windowCategories) {
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

    final globalTop = best.values.map((v) => v.$2).reduce(math.max);

    // If the entire clip is this noisy, don't commit to a label — these are
    // the mis-classifications where room tone gets tagged as "Speech" or
    // "Pet" on the flimsiest of signals.
    if (globalTop < _primaryMinConfidence) {
      return ClipClassification(
        primary: const ClassificationResult(
          category: SoundCategory.unknown,
          label: 'Other',
          confidence: 0,
        ),
        tags: const [],
        windowCategories: windowCategories,
      );
    }

    // Primary: highest-priority category whose best score is within
    // `_priorityFloorRatio` of the globally top-scoring category. Keeps
    // "Snoring" as the pick even when YAMNet's argmax is a nearby label like
    // "Cat purring" — but only on genuine near-ties, not on weak noise.
    final nearTopFloor = globalTop * _priorityFloorRatio;
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
    if (primaryCat == SoundCategory.unknown) {
      // Fall back: use the top category as primary regardless of priority.
      final topEntry = best.entries
          .reduce((a, b) => a.value.$2 >= b.value.$2 ? a : b);
      primaryCat = topEntry.key;
      primaryHit = topEntry.value;
    }
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

    return ClipClassification(
      primary: primary,
      tags: tags,
      windowCategories: windowCategories,
    );
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
