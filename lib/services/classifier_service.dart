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
  final List<SoundCategory> windowCategoriesSecondary;
  const ClipClassification({
    required this.primary,
    required this.tags,
    required this.windowCategories,
    this.windowCategoriesSecondary = const [],
  });
}

class _ClipAgg {
  final ClassificationResult primary;
  final List<ClassificationResult> tags;
  const _ClipAgg({required this.primary, required this.tags});
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
  Set<int> _denyListIndices = const {};
  bool _initialising = false;

  /// Pre-inference gain applied to the float32 PCM frame fed to YAMNet,
  /// with hard clipping to ±1.0. Boosts quiet bedroom signals into the
  /// SNR regime YAMNet was trained on — a quiet snore that raw-scored
  /// 0.05 may score 0.3+ after boosting. This is the single most
  /// impactful trick in the Sleep Talk Recorder pipeline, where they
  /// use 6.7× on int16; 5× on our float32 pipeline is roughly
  /// equivalent in dynamic-range terms while leaving a little headroom
  /// for louder sounds that might otherwise hard-clip.
  static const double _preInferenceGain = 5.0;

  /// AudioSet label names whose scores we zero out before any
  /// downstream processing. These are pure-noise classes that fire on
  /// fan noise, AC hum, and electrical buzz — they dilute the real
  /// signals we care about. Sleep Talk Recorder uses the equivalent of
  /// this via the TFLite Task Library's `setLabelDenyList`; we apply
  /// it post-inference on the raw 521-class scores.
  static const Set<String> _denyListLabelNames = {
    'Silence',
    'Humming',
    'Sine wave',
    'Static',
    'Mains hum',
    'White noise',
    'Pink noise',
  };

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
      final deny = <int>{};
      for (var i = 0; i < _labels.length; i++) {
        if (_denyListLabelNames.contains(_labels[i])) deny.add(i);
      }
      _denyListIndices = deny;
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

  /// Peak amplitude below which a segment is treated as silent regardless
  /// of what YAMNet scored. Measured on the float32 [-1,1] samples as
  /// peak-dBFS: anything below -50 dBFS is pretty much room tone.
  static const double _silenceThresholdDb = -50;

  /// Length of one display band on the waveform (1 s). Each band is
  /// produced from up to [_inferencesPerBand] overlapping YAMNet
  /// inferences — YAMNet's own native stride is 0.48 s inside a 0.975 s
  /// window, so running at 0.5 s stride externally matches its internal
  /// resolution and catches sub-second events that a 1 s non-overlapping
  /// stride would split across band boundaries.
  static const int _bandSamples = 16000;
  static const int _inferencesPerBand = 2;
  static const int _inferenceStride = _bandSamples ~/ _inferencesPerBand;

  /// Rolling window (in bands) for sustained-category clip-level
  /// aggregation. Max-of-rolling-10-band-mean surfaces a 10 s patch of
  /// snoring even when the rest of the clip is silent.
  static const int _sustainedWindowBands = 10;

  /// Cap the total number of YAMNet inferences per clip. With 2
  /// inferences per 1 s band, 600 covers a 5-minute clip (matches the
  /// recorder's maxSegmentSeconds ceiling). For longer clips bands
  /// widen beyond 1 s so the cap still holds.
  static const int _maxTotalInferences = 600;

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

  /// Classifies the clip at 1 s band granularity with a multi-stage
  /// pipeline inspired by the DCASE sound-event-detection literature and
  /// BirdNET-family bioacoustic tools.
  ///
  /// Stage 1 — overlapping inference: 2 YAMNet inferences per 1 s band
  /// (0.5 s stride, 0.975 s frame). Matches YAMNet's native 0.48 s
  /// internal stride so sub-second events that straddle band boundaries
  /// are still seen.
  ///
  /// Stage 2 — amplitude gate: bands below -50 dBFS become `silence`
  /// without running YAMNet at all.
  ///
  /// Stage 3 — collapse to simplified categories: for each band and each
  /// of our 23 SoundCategory buckets, keep the best child class's score.
  ///
  /// Stage 4 — median filter (length 3) on each category's per-band
  /// score series. Kills isolated single-band spikes (YAMNet's
  /// momentary "Purr" firing in an otherwise snoring run) without
  /// suppressing 2+-band runs.
  ///
  /// Stage 5 — per-band top-2 dominant categories: priored argmax with
  /// per-category commit thresholds from `categoryCommitThreshold`, plus
  /// a clip-primary fallback for bands where nothing passes its floor
  /// but the clip primary has non-trivial presence at that band.
  ///
  /// Stage 6 — clip-level aggregation: per-category MAX across bands
  /// for events, max-over-rolling-10-band-mean for sustained. Priored
  /// argmax picks the clip primary; tags are other categories above
  /// the tag threshold.
  ClipClassification? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null || samples.isEmpty) return null;

    final maxBands = _maxTotalInferences ~/ _inferencesPerBand;
    final secondsInClip = math.max(1, (samples.length / _bandSamples).ceil());
    final numBands = math.min(secondsInClip, maxBands);
    final bandStride = secondsInClip <= maxBands
        ? _bandSamples
        : (samples.length / numBands).floor();

    final bandSilent = List<bool>.filled(numBands, false);
    // Per-band 521-class scores: MAX across the overlapping inferences in
    // each band.
    final perBandRaw =
        List.generate(numBands, (_) => List<double>.filled(521, 0));

    // Reusable TFLite output buffers.
    final scoresOut = List.generate(1, (_) => List<double>.filled(521, 0));
    final embOut = List.generate(1, (_) => List<double>.filled(1024, 0));
    final specOut = List.generate(
        1, (_) => List.generate(96, (_) => List<double>.filled(64, 0)));

    // Offsets within a band for the overlapping inferences.
    final inferOffsets = <int>[
      for (var k = 0; k < _inferencesPerBand; k++) k * _inferenceStride,
    ];

    for (var i = 0; i < numBands; i++) {
      final bandStart = i * bandStride;
      final bandEnd = math.min(bandStart + bandStride, samples.length);

      // Stage 2 — amplitude gate.
      final bandDb = _segmentPeakDb(samples, bandStart, bandEnd);
      if (bandDb < _silenceThresholdDb) {
        bandSilent[i] = true;
        continue;
      }

      // Stage 1 — overlapping inferences. Each frame is 0.975 s. We
      // aggregate the 2 frames per band via geometric mean per class —
      // more calibrated than MAX (Kittler/Hatef 1998 on sum/product
      // combining rules). MAX biases toward whichever frame was noisy.
      //
      // Pre-inference: apply _preInferenceGain and hard-clip to ±1.0.
      // Borrowed from Sleep Talk Recorder's pipeline (they use 6.7×
      // on int16). Pushes quiet bedroom audio into YAMNet's trained
      // SNR range so a quiet snore scores in the 0.2–0.5 band
      // instead of 0.05.
      //
      // Post-inference: zero out deny-list indices (Silence, Humming,
      // Sine wave, Static, Mains hum, White/Pink noise) so they
      // can't contaminate the downstream per-category collapse.
      var inferCount = 0;
      for (final off in inferOffsets) {
        final frameStart = bandStart + off;
        if (frameStart >= samples.length) break;
        final frame = Float32List(_frame);
        final avail =
            math.min(_frame, samples.length - frameStart);
        for (var j = 0; j < avail; j++) {
          final v = samples[frameStart + j] * _preInferenceGain;
          frame[j] = v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v);
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
        if (inferCount == 0) {
          for (var k = 0; k < 521; k++) {
            perBandRaw[i][k] = row[k];
          }
        } else {
          for (var k = 0; k < 521; k++) {
            perBandRaw[i][k] =
                math.sqrt(perBandRaw[i][k] * row[k]);
          }
        }
        inferCount++;
      }
      for (final idx in _denyListIndices) {
        perBandRaw[i][idx] = 0.0;
      }
    }

    // Stage 3 — collapse to simplified categories, per band.
    var perBandCat =
        List.generate(numBands, (_) => <SoundCategory, double>{});
    for (var i = 0; i < numBands; i++) {
      if (bandSilent[i]) continue;
      final row = perBandRaw[i];
      final perCat = perBandCat[i];
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
    }

    // Stage 4 — median filter the per-category score series, using a
    // filter length chosen per category.
    perBandCat = _medianFilterPerCategory(perBandCat, bandSilent);

    // Stage 5a — compute the clip primary and tags from the filtered
    // per-band scores BEFORE per-band argmax. We use the primary as a
    // fallback signal when no category crosses its per-band commit
    // threshold at a given band (so quiet snoring inside a clip that is
    // overall clearly Snoring still colours those bands).
    final clipAgg = _computeClipAggregation(perBandCat);
    final clipPrimaryCat = clipAgg.primary.category;

    // Stage 5b — per-band top-2 dominant categories.
    //
    //   - Priored argmax picks the winner; raw score must pass the
    //     winner's per-category commit threshold (not a flat 0.10) for
    //     it to stick.
    //   - If the winner fails its threshold but the clip primary has
    //     raw score >= half the primary's threshold at this band, use
    //     the clip primary as a fallback tint. Otherwise unknown.
    //   - Secondary is the priored-runner-up, provided its own raw
    //     score passes its commit threshold. Secondary ≠ primary by
    //     construction.
    final windowCategories = <SoundCategory>[];
    final windowCategoriesSecondary = <SoundCategory>[];
    for (var i = 0; i < numBands; i++) {
      if (bandSilent[i]) {
        windowCategories.add(SoundCategory.silence);
        windowCategoriesSecondary.add(SoundCategory.silence);
        continue;
      }
      final (win, winRaw, second, secondRaw) =
          _topTwoPriored(perBandCat[i]);
      final winThresh = _thresholdFor(win);
      final secondThresh = _thresholdFor(second);
      var committedWin = win;
      if (winRaw < winThresh) {
        // Fallback to clip primary if it has non-trivial score here.
        if (clipPrimaryCat != SoundCategory.unknown) {
          final primaryRaw = perBandCat[i][clipPrimaryCat] ?? 0.0;
          final primaryFloor = _thresholdFor(clipPrimaryCat) * 0.5;
          if (primaryRaw >= primaryFloor) {
            committedWin = clipPrimaryCat;
          } else {
            committedWin = SoundCategory.unknown;
          }
        } else {
          committedWin = SoundCategory.unknown;
        }
      }
      windowCategories.add(committedWin);
      windowCategoriesSecondary.add(
        (second != SoundCategory.unknown &&
                second != committedWin &&
                secondRaw >= secondThresh)
            ? second
            : SoundCategory.unknown,
      );
    }

    if (windowCategories.isEmpty) return null;
    return ClipClassification(
      primary: clipAgg.primary,
      tags: clipAgg.tags,
      windowCategories: windowCategories,
      windowCategoriesSecondary: windowCategoriesSecondary,
    );
  }

  double _thresholdFor(SoundCategory cat) =>
      categoryCommitThreshold[cat] ?? 0.10;

  /// Top-2 by priored score for a single band. Returns (winner,
  /// winnerRaw, runnerUp, runnerUpRaw). Raw scores (not priored) so the
  /// caller can gate by the per-category commit threshold.
  (SoundCategory, double, SoundCategory, double) _topTwoPriored(
      Map<SoundCategory, double> bandScores) {
    SoundCategory win = SoundCategory.unknown;
    SoundCategory second = SoundCategory.unknown;
    double winRaw = 0;
    double winPriored = 0;
    double secondRaw = 0;
    double secondPriored = 0;
    bandScores.forEach((c, raw) {
      final priored = raw * (categoryPrior[c] ?? 1.0);
      if (priored > winPriored) {
        second = win;
        secondRaw = winRaw;
        secondPriored = winPriored;
        win = c;
        winRaw = raw;
        winPriored = priored;
      } else if (priored > secondPriored) {
        second = c;
        secondRaw = raw;
        secondPriored = priored;
      }
    });
    return (win, winRaw, second, secondRaw);
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

  /// Median filter per category across bands. Each category uses its
  /// own filter length from [categoryMedianLen] — punctate events
  /// (sneeze, cough, alarm) use length 1 so they aren't smoothed away,
  /// while sustained categories (snoring, breathing) use 3–5 bands so
  /// brief score dips get pulled back up. This follows the DCASE 2024
  /// Task 4 baseline's per-class median-filter array.
  ///
  /// Silent bands are excluded from the window (they contribute no
  /// audio evidence) and are not written to.
  List<Map<SoundCategory, double>> _medianFilterPerCategory(
      List<Map<SoundCategory, double>> perBand,
      List<bool> silent) {
    if (perBand.length < 2) return perBand;
    final allCats = <SoundCategory>{for (final m in perBand) ...m.keys};
    final out = List.generate(perBand.length, (_) => <SoundCategory, double>{});
    for (final cat in allCats) {
      final filterLen = categoryMedianLen[cat] ?? 3;
      if (filterLen <= 1) {
        // No smoothing for this category — copy raw scores through.
        for (var i = 0; i < perBand.length; i++) {
          if (silent[i]) continue;
          final v = perBand[i][cat] ?? 0.0;
          if (v > 0) out[i][cat] = v;
        }
        continue;
      }
      final half = filterLen ~/ 2;
      for (var i = 0; i < perBand.length; i++) {
        if (silent[i]) continue;
        final vals = <double>[];
        final lo = math.max(0, i - half);
        final hi = math.min(perBand.length - 1, i + half);
        for (var j = lo; j <= hi; j++) {
          if (silent[j]) continue;
          vals.add(perBand[j][cat] ?? 0.0);
        }
        if (vals.isEmpty) continue;
        vals.sort();
        final median = vals[vals.length ~/ 2];
        if (median > 0) out[i][cat] = median;
      }
    }
    return out;
  }


  /// Clip-level aggregation: computes the primary category and tags
  /// from the per-band per-category score series. MAX across bands for
  /// event categories, max-of-rolling-10-band-mean for sustained ones,
  /// priored argmax to pick primary.
  _ClipAgg _computeClipAggregation(
      List<Map<SoundCategory, double>> perBand) {
    final allCats = <SoundCategory>{for (final m in perBand) ...m.keys};
    final clipAgg = <SoundCategory, double>{};
    for (final cat in allCats) {
      final mode = categoryAggregation[cat] ?? CategoryAggregation.max;
      if (mode == CategoryAggregation.max) {
        var peak = 0.0;
        for (final m in perBand) {
          final v = m[cat] ?? 0.0;
          if (v > peak) peak = v;
        }
        if (peak > 0) clipAgg[cat] = peak;
      } else {
        final windowSize =
            math.min(_sustainedWindowBands, perBand.length);
        if (windowSize == 0) continue;
        var bestMean = 0.0;
        for (var start = 0; start <= perBand.length - windowSize; start++) {
          var sum = 0.0;
          for (var j = start; j < start + windowSize; j++) {
            sum += perBand[j][cat] ?? 0.0;
          }
          final mean = sum / windowSize;
          if (mean > bestMean) bestMean = mean;
        }
        if (bestMean > 0) clipAgg[cat] = bestMean;
      }
    }

    const otherOnly = ClassificationResult(
      category: SoundCategory.unknown,
      label: 'Other',
      confidence: 0,
    );

    if (clipAgg.isEmpty) {
      return const _ClipAgg(primary: otherOnly, tags: []);
    }

    final rawTop = clipAgg.values.reduce(math.max);
    if (rawTop < _primaryMinConfidence) {
      return const _ClipAgg(primary: otherOnly, tags: []);
    }

    double prioredScore(SoundCategory cat, double raw) =>
        raw * (categoryPrior[cat] ?? 1.0);
    final topEntry = clipAgg.entries.reduce((a, b) =>
        prioredScore(a.key, a.value) >= prioredScore(b.key, b.value)
            ? a
            : b);
    final primary = ClassificationResult(
      category: topEntry.key,
      label: categoryInfo[topEntry.key]?.label ?? 'Other',
      confidence: topEntry.value,
    );

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

    return _ClipAgg(primary: primary, tags: tags);
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
