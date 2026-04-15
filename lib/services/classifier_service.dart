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

  Future<ClassificationResult?> classifyWavFile(String path) async {
    if (_interp == null) await init();
    if (_interp == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final samples = _decodePcm16MonoFromWav(bytes);
    if (samples.isEmpty) return null;
    return _classifySamples(samples);
  }

  /// Splits the waveform into YAMNet's 0.975s windows, averages the class
  /// probabilities, and returns the top class.
  ClassificationResult? _classifySamples(Float32List samples) {
    final interp = _interp;
    if (interp == null) return null;

    // Chunk into _frame samples. If shorter than a frame, zero-pad.
    final chunks = <Float32List>[];
    if (samples.length < _frame) {
      final padded = Float32List(_frame);
      padded.setRange(0, samples.length, samples);
      chunks.add(padded);
    } else {
      for (var start = 0; start + _frame <= samples.length; start += _frame) {
        chunks.add(Float32List.sublistView(samples, start, start + _frame));
      }
    }
    if (chunks.isEmpty) return null;

    // Cap number of inferences (3 s of audio is plenty for a label).
    final maxChunks = math.min(chunks.length, 4);

    List<double>? accum;
    for (var i = 0; i < maxChunks; i++) {
      final input = [chunks[i]];
      // YAMNet has three outputs: scores (N,521), embeddings (N,1024),
      // spectrogram (N,96,64). We only need scores.
      final scores = List.generate(1, (_) => List<double>.filled(521, 0));
      final emb = List.generate(1, (_) => List<double>.filled(1024, 0));
      final spec =
          List.generate(1, (_) => List.generate(96, (_) => List<double>.filled(64, 0)));
      final outputs = <int, Object>{0: scores, 1: emb, 2: spec};
      try {
        interp.runForMultipleInputs([input], outputs);
      } catch (_) {
        return null;
      }
      accum ??= List<double>.filled(521, 0);
      for (var k = 0; k < 521; k++) {
        accum[k] += scores[0][k];
      }
    }
    if (accum == null) return null;
    for (var k = 0; k < 521; k++) {
      accum[k] /= maxChunks;
    }

    var bestIdx = 0;
    var bestVal = accum[0];
    for (var i = 1; i < accum.length; i++) {
      if (accum[i] > bestVal) {
        bestVal = accum[i];
        bestIdx = i;
      }
    }
    final label = bestIdx < _labels.length ? _labels[bestIdx] : 'Unknown';
    return ClassificationResult(
      category: mapYamnetLabel(label),
      label: label,
      confidence: bestVal,
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
