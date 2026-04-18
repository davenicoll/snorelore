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

  /// Length of one display band on the waveform. One YAMNet inference
  /// per band gives a per-second dominant category for fine event
  /// localisation.
  static const int _bandSamples = 16000; // 1 s at 16 kHz

  /// Rolling window (in bands) used to aggregate sustained categories
  /// for the clip-wide primary pick. Sustained scores are max-of-mean
  /// over a 10 s window — surfaces snoring that happened in a specific
  /// 10 s patch without diluting it across the whole clip.
  static const int _sustainedWindowBands = 10;

  /// Cap the total number of YAMNet inferences per clip. At 1 s bands
  /// this equals the max clip length in seconds we can fully cover —
  /// 300 matches the recorder's maxSegmentSeconds ceiling. Longer clips
  /// stride sparser and have bands that cover >1 s each.
  static const int _maxTotalInferences = 300;

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

  /// Classifies the clip at 1 s band granularity with multi-scale
  /// clip-level aggregation.
  ///
  /// For each 1 s display band we run a single YAMNet inference
  /// (0.975 s frame, 1 s stride — near-zero overlap) and collapse the
  /// 521-class probabilities into our simplified categories. The band's
  /// dominant category drives the waveform colour; silence amplitude-gate
  /// short-circuits quiet bands without running the model.
  ///
  /// For the clip-wide primary the aggregation uses different scales per
  /// category type: transient events (sneeze, cough, alarm…) aggregate
  /// via MAX across all bands — one 1 s band of high confidence commits
  /// the category. Sustained sounds (snoring, breathing, speech…)
  /// aggregate via the best rolling 10 s window mean — 10 s of snoring
  /// anywhere in the clip surfaces as the primary even if the rest is
  /// silent. Bedroom priors tip close ties towards plausible-at-night
  /// categories; raw (unpriored) scores still gate commitment.
  ClipClassification? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null || samples.isEmpty) return null;

    // One band per second of audio. If the clip is long enough that
    // 1 s bands would blow past the inference cap, widen the band so
    // we still cover the whole clip with at most _maxTotalInferences
    // bands (each band is then >1 s but still a single inference).
    final secondsInClip = math.max(1, (samples.length / _bandSamples).ceil());
    final numBands = math.min(secondsInClip, _maxTotalInferences);
    final bandStride = secondsInClip <= _maxTotalInferences
        ? _bandSamples
        : (samples.length / numBands).floor();

    // Per-band per-category raw score maps. Used for clip-wide aggregation.
    final perBand = <Map<SoundCategory, double>>[];
    final windowCategories = <SoundCategory>[];

    // Reusable TFLite output buffers.
    final scoresOut = List.generate(1, (_) => List<double>.filled(521, 0));
    final embOut = List.generate(1, (_) => List<double>.filled(1024, 0));
    final specOut = List.generate(
        1, (_) => List.generate(96, (_) => List<double>.filled(64, 0)));

    for (var i = 0; i < numBands; i++) {
      final bandStart = i * bandStride;
      final bandEnd = math.min(bandStart + bandStride, samples.length);

      // Amplitude gate: silent bands skip inference entirely.
      final bandDb = _segmentPeakDb(samples, bandStart, bandEnd);
      if (bandDb < _silenceThresholdDb) {
        windowCategories.add(SoundCategory.silence);
        perBand.add(const <SoundCategory, double>{});
        continue;
      }

      // Build the 0.975 s frame that YAMNet expects. If the band has
      // enough samples, take the first _frame samples; otherwise pad.
      Float32List frame;
      if (bandEnd - bandStart >= _frame) {
        frame = Float32List.sublistView(
            samples, bandStart, bandStart + _frame);
      } else {
        frame = Float32List(_frame);
        for (var j = 0; j < bandEnd - bandStart; j++) {
          frame[j] = samples[bandStart + j];
        }
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

      // Collapse the 521 raw scores to per-category best (max over the
      // children mapping to each simplified category).
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
      perBand.add(perCat);

      // Band-level dominant category: priored argmax, raw-score gated.
      SoundCategory winCat = SoundCategory.unknown;
      double winRaw = 0;
      double winPriored = 0;
      perCat.forEach((c, raw) {
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
      perBand,
      _smoothSegments(windowCategories),
    );
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

  /// Mode-of-5 filter run in 2 passes. At 1 s bands this is a 5 s context
  /// smoother — the centre is rewritten when a single other category
  /// holds a strict majority (≥3) across centre + 2 neighbours either
  /// side. Event categories (sneeze, cough, alarm…) are never rewritten,
  /// so a genuine 1–2 second sneeze survives smoothing. Runs of 3+ bands
  /// of any category are preserved, so real 3 s+ events stay intact.
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
      List<Map<SoundCategory, double>> perBand,
      List<SoundCategory> windowCategories) {
    // Multi-scale clip-level aggregation. For each category:
    //   - MAX categories (events): take the highest per-band raw score
    //     anywhere in the clip — a single 1 s band of high-confidence
    //     sneeze commits the category.
    //   - MEAN categories (sustained): take the max over rolling 10 s
    //     window means — 10 s of snoring anywhere in the clip surfaces,
    //     even if the rest is silent. Using max-of-rolling-mean rather
    //     than mean-over-whole-clip means a brief snore patch in an
    //     otherwise quiet clip still gets the right primary.
    final allCats = <SoundCategory>{
      for (final m in perBand) ...m.keys,
    };
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
