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

  /// Per-segment confidence floor for colouring the waveform. A segment
  /// below this threshold is rendered in the neutral base colour rather
  /// than tinted. Applied to the raw (unpriored) aggregated score so
  /// priors can't fabricate signal over the floor. Lowered from 0.20 to
  /// 0.10 so softer sustained signals (whispered snoring, gentle
  /// breathing) still earn a tint — the bedroom prior and temporal
  /// smoothing then filter out the noisy ones.
  static const double _windowMinConfidence = 0.10;

  /// Peak amplitude below which a segment is treated as silent regardless
  /// of what YAMNet scored. Measured on the float32 [-1,1] samples as
  /// peak-dBFS: anything below -50 dBFS is pretty much room tone.
  static const double _silenceThresholdDb = -50;

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

  /// Classifies the clip in non-overlapping 10 s segments.
  ///
  /// For each segment we run YAMNet multiple times at its native 0.975 s
  /// input size, collapse each inference's 521-class probabilities into our
  /// simplified categories (keeping the best child class per category),
  /// then aggregate across inferences per category according to its
  /// [CategoryAggregation]: MAX for transient events (sneeze, cough,
  /// alarm), MEAN for sustained sounds (snoring, breathing, speech).
  /// That means a single 0.9 frame of "Purr" embedded in nine frames of
  /// 0.05 snoring no longer wins the segment — where the old max-only
  /// aggregation let it.
  ///
  /// An amplitude gate short-circuits silent segments to `silence`
  /// regardless of YAMNet, and the bedroom prior tips close ties towards
  /// plausible-at-night categories. The clip-wide primary and tags are
  /// computed by aggregating the per-segment per-category scores across
  /// segments using the same MAX/MEAN rules.
  ClipClassification? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null || samples.isEmpty) return null;

    final numSegments =
        math.max(1, (samples.length / _segmentSamples).ceil());
    final perSegBudget =
        math.max(1, _maxTotalInferences ~/ numSegments);

    final windowCategories = <SoundCategory>[];
    // One map per segment: category → aggregated raw (unpriored) score.
    // Used afterwards to compute the clip primary and tags.
    final perSegmentAgg = <Map<SoundCategory, double>>[];

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

      // Amplitude gate. If the whole 10 s band is below the silence floor
      // there's nothing for YAMNet to classify. Skip inference entirely.
      final segAmpDb = _segmentPeakDb(samples, segStart, segEnd);
      if (segAmpDb < _silenceThresholdDb) {
        windowCategories.add(SoundCategory.silence);
        perSegmentAgg.add(const <SoundCategory, double>{});
        continue;
      }

      // Inference offsets within the segment.
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

      // Collect per-inference per-category scores (best raw-label score per
      // category within each inference).
      final perInference = <Map<SoundCategory, double>>[];
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
        final perCat = <SoundCategory, double>{};
        for (var k = 0; k < 521; k++) {
          final s = row[k];
          if (s <= 0) continue;
          final cat = k < _labelCategories.length
              ? _labelCategories[k]
              : SoundCategory.unknown;
          if (cat == SoundCategory.unknown) continue;
          final prev = perCat[cat];
          if (prev == null || s > prev) perCat[cat] = s;
        }
        perInference.add(perCat);
      }

      // Aggregate per category across this segment's inferences, MAX for
      // events and MEAN for sustained sounds.
      final segAgg = _aggregatePerCategory(perInference);
      perSegmentAgg.add(segAgg);

      // Pick the segment's dominant category — priored argmax. Raw score
      // must also pass the confidence floor, so priors can only break
      // close ties, not fabricate signal.
      SoundCategory winCat = SoundCategory.unknown;
      double winRaw = 0;
      double winPriored = 0;
      segAgg.forEach((c, raw) {
        final priored = raw * (categoryPrior[c] ?? 1.0);
        if (priored > winPriored) {
          winPriored = priored;
          winRaw = raw;
          winCat = c;
        }
      });
      if (winRaw < _windowMinConfidence) winCat = SoundCategory.unknown;
      windowCategories.add(winCat);
    }

    if (windowCategories.isEmpty) return null;
    return _pickPrimaryAndTags(
      perSegmentAgg,
      _smoothSegments(windowCategories),
    );
  }

  /// Aggregate the per-inference per-category score maps into one map of
  /// (category → aggregated raw score). The aggregation mode is MAX or
  /// MEAN per category, to match the temporal behaviour of the sound.
  Map<SoundCategory, double> _aggregatePerCategory(
      List<Map<SoundCategory, double>> perInference) {
    if (perInference.isEmpty) return const {};
    final allCats = <SoundCategory>{
      for (final m in perInference) ...m.keys,
    };
    final out = <SoundCategory, double>{};
    for (final cat in allCats) {
      final mode = categoryAggregation[cat] ?? CategoryAggregation.max;
      if (mode == CategoryAggregation.max) {
        var peak = 0.0;
        for (final m in perInference) {
          final v = m[cat] ?? 0.0;
          if (v > peak) peak = v;
        }
        if (peak > 0) out[cat] = peak;
      } else {
        var sum = 0.0;
        for (final m in perInference) {
          sum += m[cat] ?? 0.0;
        }
        final mean = sum / perInference.length;
        if (mean > 0) out[cat] = mean;
      }
    }
    return out;
  }

  /// Peak-dBFS of the float32 samples in [start, end). Used to short-circuit
  /// silent segments before running any YAMNet inferences on them.
  double _segmentPeakDb(Float32List samples, int start, int end) {
    if (start >= samples.length) return -100;
    final hi = math.min(end, samples.length);
    var peak = 0.0;
    for (var i = start; i < hi; i++) {
      final a = samples[i].abs();
      if (a > peak) peak = a;
    }
    if (peak <= 0) return -100;
    return 20 * (math.log(peak) / math.ln10);
  }

  /// Mode-of-5 filter run in 2 passes. Each pass, for each segment, counts
  /// categories across the centre and the 2 neighbours either side; if a
  /// single category holds a strict majority (≥3) and the centre disagrees,
  /// the centre is rewritten. Event categories (sneeze, cough, alarm…) are
  /// never rewritten — even a single 10 s segment of them is informative.
  /// Two passes handles the case of 2 adjacent outliers.
  List<SoundCategory> _smoothSegments(List<SoundCategory> cats) {
    if (cats.length < 3) return cats;
    var current = List<SoundCategory>.of(cats);
    for (var pass = 0; pass < 2; pass++) {
      final snapshot = List<SoundCategory>.of(current);
      for (var i = 0; i < snapshot.length; i++) {
        if (eventCategories.contains(snapshot[i])) continue;
        final lo = math.max(0, i - 2);
        final hi = math.min(snapshot.length - 1, i + 2);
        final counts = <SoundCategory, int>{};
        for (var j = lo; j <= hi; j++) {
          counts[snapshot[j]] = (counts[snapshot[j]] ?? 0) + 1;
        }
        SoundCategory mode = snapshot[i];
        var modeCount = 0;
        counts.forEach((c, n) {
          if (n > modeCount) {
            modeCount = n;
            mode = c;
          }
        });
        if (modeCount >= 3 && mode != snapshot[i]) {
          current[i] = mode;
        }
      }
    }
    return current;
  }

  ClipClassification? _pickPrimaryAndTags(
      List<Map<SoundCategory, double>> perSegmentAgg,
      List<SoundCategory> windowCategories) {
    // Clip-level per-category score: aggregate the per-segment scores
    // across segments using the same MAX/MEAN rules. So snoring's clip
    // score is the mean of its per-segment means (= overall snoring
    // prevalence); sneeze's clip score is the max across segments.
    final allCats = <SoundCategory>{
      for (final m in perSegmentAgg) ...m.keys,
    };
    final clipAgg = <SoundCategory, double>{};
    for (final cat in allCats) {
      final mode = categoryAggregation[cat] ?? CategoryAggregation.max;
      if (mode == CategoryAggregation.max) {
        var peak = 0.0;
        for (final m in perSegmentAgg) {
          final v = m[cat] ?? 0.0;
          if (v > peak) peak = v;
        }
        if (peak > 0) clipAgg[cat] = peak;
      } else {
        var sum = 0.0;
        for (final m in perSegmentAgg) {
          sum += m[cat] ?? 0.0;
        }
        final mean = sum / perSegmentAgg.length;
        if (mean > 0) clipAgg[cat] = mean;
      }
    }

    ClipClassification otherOnly() => ClipClassification(
          primary: const ClassificationResult(
            category: SoundCategory.unknown,
            label: 'Other',
            confidence: 0,
          ),
          tags: const [],
          windowCategories: windowCategories,
        );

    if (clipAgg.isEmpty) return otherOnly();

    // Raw (unpriored) top gates commitment — priors can shuffle close
    // contenders but can't push a weak signal over the confidence floor.
    final rawTop = clipAgg.values.reduce(math.max);
    if (rawTop < _primaryMinConfidence) return otherOnly();

    double prioredScore(SoundCategory cat, double raw) =>
        raw * (categoryPrior[cat] ?? 1.0);

    // Priored argmax — bedroom priors do all the tie-breaking work. No
    // separate priority walk: the prior is the mechanism.
    final topEntry = clipAgg.entries.reduce((a, b) =>
        prioredScore(a.key, a.value) >= prioredScore(b.key, b.value)
            ? a
            : b);
    final primary = ClassificationResult(
      category: topEntry.key,
      label: categoryInfo[topEntry.key]?.label ?? 'Other',
      confidence: topEntry.value,
    );

    // Tags: other categories whose raw aggregated score crossed the tag
    // threshold. Sorted high to low, capped so we don't spam the UI.
    final tags = <ClassificationResult>[];
    final entries = clipAgg.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in entries) {
      if (e.key == topEntry.key) continue;
      if (e.key == SoundCategory.unknown) continue;
      if (e.key == SoundCategory.silence) continue;
      if (e.value < _tagThreshold) continue;
      tags.add(ClassificationResult(
        category: e.key,
        label: categoryInfo[e.key]?.label ?? 'Other',
        confidence: e.value,
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
