import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Silero VAD (voice activity detection) running on-device via ONNX
/// Runtime. Dedicated to the Talking bucket — YAMNet's Speech /
/// Conversation / Whisper / etc. labels are denied at inference time
/// so they can't compete with the non-voice categories.
///
/// Silero v5 is stateful: it expects fixed 512-sample (32 ms @ 16 kHz)
/// chunks with an LSTM hidden state carried forward between calls. To
/// score a 1 s band we feed 31 consecutive 512-sample chunks and take
/// the MAX voice probability across them — if any 32 ms window in the
/// band has high voice probability, voice is present.
class SileroVadService {
  static const String _modelAsset = 'assets/models/silero_vad.onnx';
  static const int _chunkSamples = 512; // Silero v5's fixed input size
  static const int _stateSize = 2 * 1 * 128;

  OrtSession? _session;
  OrtValue? _srValue;
  bool _initialising = false;

  Future<void> init() async {
    if (_session != null || _initialising) return;
    _initialising = true;
    try {
      final ort = OnnxRuntime();
      _session = await ort.createSessionFromAsset(_modelAsset);
      // sr is an int64 scalar; build once and reuse.
      _srValue = await OrtValue.fromList(
        Int64List.fromList([16000]),
        [1],
      );
    } catch (_) {
      // Leave the session null; callers will treat it as unavailable.
    } finally {
      _initialising = false;
    }
  }

  bool get ready => _session != null;

  /// Score a 1 s band (or any chunk ≥ 512 samples) for voice activity.
  /// Returns the peak voice probability in [0, 1] seen in any 32 ms
  /// sub-chunk, or 0 if the model isn't loaded or the input is too
  /// short.
  Future<double> voiceProbabilityForBand(Float32List samples) async {
    final session = _session;
    final srValue = _srValue;
    if (session == null || srValue == null) return 0;
    if (samples.length < _chunkSamples) return 0;

    // Fresh per-band state — we don't rely on context from earlier
    // bands, each 1 s window is classified independently. Simpler than
    // threading state across bands and avoids state drift over long
    // silent clips.
    var state = Float32List(_stateSize);

    var maxProb = 0.0;
    final limit = samples.length - (samples.length % _chunkSamples);

    for (var off = 0; off + _chunkSamples <= limit; off += _chunkSamples) {
      final chunk =
          Float32List.sublistView(samples, off, off + _chunkSamples);

      final inputValue = await OrtValue.fromList(chunk, [1, _chunkSamples]);
      final stateValue = await OrtValue.fromList(state, [2, 1, 128]);

      Map<String, OrtValue> outputs;
      try {
        outputs = await session.run({
          'input': inputValue,
          'state': stateValue,
          'sr': srValue,
        });
      } catch (_) {
        await inputValue.dispose();
        await stateValue.dispose();
        return maxProb;
      }

      // `output` is shape [1, 1] — a single probability.
      final outProb = outputs['output'];
      if (outProb != null) {
        final flat = await outProb.asFlattenedList();
        if (flat.isNotEmpty) {
          final v = (flat.first as num).toDouble();
          if (v > maxProb) maxProb = v;
        }
      }

      // Carry state forward.
      final stateN = outputs['stateN'];
      if (stateN != null) {
        final flat = await stateN.asFlattenedList();
        state = Float32List.fromList(
          flat.map((e) => (e as num).toDouble()).toList(),
        );
      }

      await inputValue.dispose();
      await stateValue.dispose();
      for (final v in outputs.values) {
        await v.dispose();
      }
    }

    return maxProb;
  }

  Future<void> dispose() async {
    try {
      await _srValue?.dispose();
    } catch (_) {}
    _srValue = null;
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
  }
}
