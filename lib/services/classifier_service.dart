import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../utils/categories.dart';
import 'silero_vad_service.dart';

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

  /// Minimum Silero voice probability to commit a band to Talking
  /// without even running YAMNet. 0.5 is Silero's own idiomatic
  /// threshold.
  static const double _sileroVoiceThreshold = 0.5;

  /// Lower Silero floor for the YAMNet-rescue path. A band that scored
  /// in [_sileroRescueFloor, _sileroVoiceThreshold) is *not* committed
  /// to Talking by Silero alone, but YAMNet runs and if its
  /// Speech-family raw evidence sum exceeds [_speechRescueEvidence] the
  /// band is rescued to Talking. This catches quiet sleep-talk where
  /// Silero is borderline but YAMNet's Speech / Conversation /
  /// Whispering classes still fire.
  static const double _sileroRescueFloor = 0.35;

  /// Speech-family raw score sum (pre-deny, post-gain) above which we
  /// consider YAMNet to have voted convincingly for Talking. Used in
  /// concert with [_sileroRescueFloor] (rescue) and standalone for the
  /// no-Silero rescue when speech evidence is overwhelming.
  static const double _speechRescueEvidence = 0.40;

  /// Standalone YAMNet speech rescue: if Silero is unavailable or
  /// scored below [_sileroRescueFloor] but speech-family evidence is
  /// very high, still commit to Talking. Bedroom audio rarely produces
  /// >0.6 sum across Speech/Conversation/Whispering on non-speech.
  static const double _speechSoloRescueEvidence = 0.55;

  /// Speech-family evidence floor that triggers a secondary Silero
  /// pass on the gain-boosted samples. Cheap signal that "YAMNet
  /// thinks there is speech here" gates running Silero a second time;
  /// without this hint we'd pay the cost on every quiet band.
  static const double _secondaryGainSileroSpeechFloor = 0.20;

  final SileroVadService? _silero;
  ClassifierService({SileroVadService? silero}) : _silero = silero;

  Interpreter? _interp;
  List<String> _labels = const [];
  List<SoundCategory> _labelCategories = const [];
  Set<int> _denyListIndices = const {};
  Set<int> _speechFamilyIndices = const {};
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
  /// downstream processing. Two groups:
  ///
  ///   Pure-noise classes (fan / AC / mains hum / etc.) — always dilute
  ///   real signals.
  ///
  ///   Breathing-family classes — YAMNet fires these as "everything
  ///   during sleep", which swamps the specific classifications
  ///   (snoring, speech) we actually want. Sleep Talk Recorder denies
  ///   `Breathing` for the same reason and their pipeline is the
  ///   prior-art reference for this choice.
  static const Set<String> _denyListLabelNames = {
    // Noise
    'Silence',
    'Humming',
    'Sine wave',
    'Static',
    'Mains hum',
    'White noise',
    'Pink noise',
    // Breathing-family: YAMNet dominance attractor for quiet sleep audio
    'Breathing',
    'Gasp',
    'Pant',
    'Sigh',
    'Sniff',
    // Speech-family: handled by Silero VAD, denied here so YAMNet's
    // own over-firing Speech classes can't compete with snoring /
    // events / pets / music for the per-band argmax.
    'Speech',
    'Child speech, kid speaking',
    'Conversation',
    'Narration, monologue',
    'Babbling',
    'Speech synthesizer',
    'Whispering',
  };

  /// Subset of [_denyListLabelNames] that are speech-family labels. We
  /// still zero these out before the per-category collapse (so YAMNet
  /// Speech can't out-shout Snoring/Pets/Music for the band's argmax),
  /// but we read their raw scores first to feed the Talking rescue
  /// path. Without this, a borderline-Silero band where YAMNet's
  /// Speech labels are firing strongly is silently lost.
  static const Set<String> _speechFamilyLabelNames = {
    'Speech',
    'Child speech, kid speaking',
    'Conversation',
    'Narration, monologue',
    'Babbling',
    'Speech synthesizer',
    'Whispering',
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
      final speech = <int>{};
      for (var i = 0; i < _labels.length; i++) {
        if (_denyListLabelNames.contains(_labels[i])) deny.add(i);
        if (_speechFamilyLabelNames.contains(_labels[i])) speech.add(i);
      }
      _denyListIndices = deny;
      _speechFamilyIndices = speech;
    } catch (e) {
      // Leave _interp null; the caller will gracefully skip classification.
    } finally {
      _initialising = false;
    }
  }

  bool get ready => _interp != null && _labels.isNotEmpty;

  /// Confidence floor for promoting a non-primary category onto the clip
  /// as a tag. Raised in v0.13.1 to match post-gain score distributions —
  /// the 5× pre-inference gain inflates typical YAMNet scores, so the
  /// pre-gain 0.20 was too permissive.
  static const double _tagThreshold = 0.35;

  /// Below this, we refuse to commit to any category and the clip is
  /// filed as "Other". Raised post-gain from 0.10.
  static const double _primaryMinConfidence = 0.20;

  /// Peak amplitude below which a segment is treated as silent regardless
  /// of what YAMNet scored. Measured on the float32 [-1,1] samples as
  /// peak-dBFS on the pre-gain signal. The v0.13.0 5× gain boost
  /// effectively adds +14 dB to quiet bands at inference time, so a raw
  /// -65 dBFS signal lands around -51 dBFS post-gain — still classifiable
  /// by YAMNet. The previous -50 dBFS floor was gating out quiet sleep
  /// sounds that would have classified fine after gain.
  static const double _silenceThresholdDb = -65;

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
    return await _classifySamples(samples);
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
  Future<ClipClassification?> _classifySamples(Float32List samples) async {
    final interp = _interp;
    if (interp == null || samples.isEmpty) return null;

    final maxBands = _maxTotalInferences ~/ _inferencesPerBand;
    final secondsInClip = math.max(1, (samples.length / _bandSamples).ceil());
    final numBands = math.min(secondsInClip, maxBands);
    final bandStride = secondsInClip <= maxBands
        ? _bandSamples
        : (samples.length / numBands).floor();

    // Per-clip Silero state — carried across bands so the LSTM's
    // contextual cues survive band boundaries. Allocated once per
    // classification and passed into every voiceProbabilityForBand
    // call, so a slurred utterance that straddles a 1 s boundary still
    // benefits from prior frames.
    final sileroState = _silero?.ready == true ? _silero!.newClipState() : null;

    final bandSilent = List<bool>.filled(numBands, false);
    // Bands that Silero VAD committed to the Talking bucket. For these
    // bands we skip YAMNet inference entirely and seed the per-band
    // score map directly in stage 3.
    final bandVoice = List<bool>.filled(numBands, false);
    final bandVoiceProb = Float32List(numBands);
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

      // Stage 2.5 — Silero VAD gate for the Talking bucket. Silero is a
      // dedicated speech classifier, much more reliable than YAMNet's
      // Speech class on bedroom audio. Three-tier outcome:
      //   - voiceProb ≥ _sileroVoiceThreshold (0.5): commit Talking,
      //     skip YAMNet (fast path, existing behaviour).
      //   - voiceProb in [_sileroRescueFloor, _sileroVoiceThreshold):
      //     borderline. Run YAMNet, then re-evaluate after speech-family
      //     evidence is computed (rescue path below).
      //   - voiceProb < _sileroRescueFloor: ignore Silero, run YAMNet
      //     normally; only the standalone speech-evidence rescue can
      //     promote the band to Talking.
      double bandSileroProb = 0.0;
      final silero = _silero;
      if (silero != null && silero.ready) {
        final bandSamples = Float32List.sublistView(
          samples,
          bandStart,
          math.min(bandEnd, samples.length),
        );
        try {
          final voiceProb = await silero.voiceProbabilityForBand(
            bandSamples,
            carryState: sileroState,
          );
          bandSileroProb = voiceProb;
          if (voiceProb >= _sileroVoiceThreshold) {
            bandVoice[i] = true;
            bandVoiceProb[i] = voiceProb;
            continue; // skip YAMNet
          }
        } catch (_) {
          // If Silero fails, fall through to YAMNet.
        }
      }

      // Stage 1 — overlapping inferences. Each frame is 0.975 s. We
      // aggregate the 2 frames per band via geometric mean per class —
      // more calibrated than MAX (Kittler/Hatef 1998 on sum/product
      // combining rules). MAX biases toward whichever frame was noisy.
      //
      // Pre-inference: apply _preInferenceGain and soft-clip via tanh.
      // Sleep Talk Recorder uses 6.7× hard-clipped int16, but quiet-only
      // signals tolerate the distortion because they rarely reach the
      // ceiling. Our clips include loud snores / alarms / coughs too,
      // so hard-clipping distorts them. tanh preserves shape for
      // loud signals (approaching ±1) while leaving quiet signals
      // near-linear (tanh(0.25) ≈ 0.245).
      //
      // Post-inference: zero out deny-list indices so they can't
      // contaminate the downstream per-category collapse.
      var inferCount = 0;
      for (final off in inferOffsets) {
        final frameStart = bandStart + off;
        if (frameStart >= samples.length) break;
        final frame = Float32List(_frame);
        final avail =
            math.min(_frame, samples.length - frameStart);
        for (var j = 0; j < avail; j++) {
          // tanh soft clip after gain
          final v = samples[frameStart + j] * _preInferenceGain;
          // math.tanh equivalent via exp — avoids importing dart:math
          // `tanh` indirection. tanh(x) = (e^x - e^-x) / (e^x + e^-x).
          final e2x = math.exp(2 * v);
          frame[j] = (e2x - 1) / (e2x + 1);
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
      // Speech-family rescue: read speech-class scores BEFORE the deny
      // list zeroes them. Sum, not max, so multiple overlapping speech
      // labels ('Speech' + 'Conversation' + 'Whispering') reinforce each
      // other on real talking, while a single isolated false-positive on
      // 'Speech' alone needs to be strong to clear the rescue floor.
      var speechEvidence = 0.0;
      for (final idx in _speechFamilyIndices) {
        speechEvidence += perBandRaw[i][idx];
      }
      // Cap at 1.0 so a band with both Silero and YAMNet voting high
      // doesn't produce voiceProb > 1.
      if (speechEvidence > 1.0) speechEvidence = 1.0;

      // Gain-boosted Silero secondary pass. Raw Silero sees un-gained
      // bedroom audio; quiet sleep-talk that needs the 5× pre-inference
      // gain to be classifiable by YAMNet is also below Silero's
      // training-distribution amplitude. Run Silero a second time on
      // the same gain-boosted (post-tanh-soft-clip) samples YAMNet
      // saw — but ONLY when YAMNet picked up a meaningful speech hint,
      // to avoid doubling Silero cost on every band of a quiet night.
      double secondarySileroProb = 0.0;
      if (silero != null &&
          silero.ready &&
          !bandVoice[i] &&
          speechEvidence >= _secondaryGainSileroSpeechFloor) {
        final n = bandEnd - bandStart;
        final gained = Float32List(n);
        for (var j = 0; j < n; j++) {
          final v = samples[bandStart + j] * _preInferenceGain;
          final e2x = math.exp(2 * v);
          gained[j] = (e2x - 1) / (e2x + 1);
        }
        try {
          // No carryState — gain-boosted samples diverge from the raw
          // clip-state stream and would corrupt the LSTM context that
          // raw-Silero is accumulating across bands.
          secondarySileroProb =
              await silero.voiceProbabilityForBand(gained);
        } catch (_) {}
      }
      final effectiveSileroProb =
          math.max(bandSileroProb, secondarySileroProb);

      // Direct commit if the gain-boosted pass cleared the main
      // threshold on its own.
      if (!bandVoice[i] &&
          secondarySileroProb >= _sileroVoiceThreshold) {
        bandVoice[i] = true;
        bandVoiceProb[i] = secondarySileroProb;
      }

      final sileroBorderline = effectiveSileroProb >= _sileroRescueFloor &&
          effectiveSileroProb < _sileroVoiceThreshold;
      final rescueByCombo =
          sileroBorderline && speechEvidence >= _speechRescueEvidence;
      final rescueBySolo = speechEvidence >= _speechSoloRescueEvidence;
      if (!bandVoice[i] && (rescueByCombo || rescueBySolo)) {
        bandVoice[i] = true;
        bandVoiceProb[i] = math.max(effectiveSileroProb, speechEvidence);
        // Fall through to deny-list zeroing so the per-category collapse
        // (skipped for voice bands anyway) is consistent.
      }

      for (final idx in _denyListIndices) {
        perBandRaw[i][idx] = 0.0;
      }
    }

    // Stage 3 — collapse to simplified categories, per band. Voice
    // bands (from Silero) skip the YAMNet collapse entirely and get
    // their Talking score set directly from Silero's voice probability.
    var perBandCat =
        List.generate(numBands, (_) => <SoundCategory, double>{});
    for (var i = 0; i < numBands; i++) {
      if (bandSilent[i]) continue;
      if (bandVoice[i]) {
        perBandCat[i][SoundCategory.talking] =
            bandVoiceProb[i].toDouble();
        continue;
      }
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
