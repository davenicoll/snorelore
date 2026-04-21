import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/recording.dart';
import '../utils/categories.dart';

class StorageService {
  static Directory? _recordingsDir;
  static File? _indexFile;

  Future<Directory> recordingsDir() async {
    if (_recordingsDir != null) return _recordingsDir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'recordings'));
    if (!await d.exists()) await d.create(recursive: true);
    _recordingsDir = d;
    return d;
  }

  Future<File> indexFile() async {
    if (_indexFile != null) return _indexFile!;
    final docs = await getApplicationDocumentsDirectory();
    final f = File(p.join(docs.path, 'recordings_index.json'));
    if (!await f.exists()) await f.writeAsString('[]');
    _indexFile = f;
    return f;
  }

  Future<List<Recording>> loadAll() async {
    final f = await indexFile();
    try {
      final raw = await f.readAsString();
      final list = (jsonDecode(raw) as List)
          .map((e) => Recording.fromJson(e as Map<String, dynamic>))
          .toList();
      list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<Recording> recs) async {
    final f = await indexFile();
    recs.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    await f.writeAsString(jsonEncode(recs.map((e) => e.toJson()).toList()));
  }

  Future<void> add(Recording r) async {
    final all = await loadAll();
    all.add(r);
    await _saveAll(all);
  }

  Future<void> update(Recording r) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.id == r.id);
    if (idx < 0) return;
    all[idx] = r;
    await _saveAll(all);
  }

  /// Replace the entire index in one write. Used for bulk operations like
  /// "clear all classifications" where touching every record via update()
  /// would mean re-reading and re-writing the index N times.
  Future<void> replaceAll(List<Recording> recs) async {
    await _saveAll(List<Recording>.of(recs));
  }

  Future<void> delete(Recording r) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == r.id);
    await _saveAll(all);
    final file = File(r.filePath);
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteMany(Iterable<Recording> recs) async {
    final ids = recs.map((e) => e.id).toSet();
    final all = await loadAll();
    all.removeWhere((e) => ids.contains(e.id));
    await _saveAll(all);
    for (final r in recs) {
      final file = File(r.filePath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  /// Generate a new recording file path (.m4a) in the recordings dir.
  Future<String> newRecordingPath() async {
    final d = await recordingsDir();
    final ts = DateTime.now().millisecondsSinceEpoch;
    return p.join(d.path, 'rec_$ts.m4a');
  }

  /// Trim a Recording's WAV file and metadata to the "active range" — the
  /// contiguous window of bands containing non-silent / non-unknown
  /// classifications, plus a small padding either side.
  ///
  /// Our amplitude VAD captures with a long post-roll (60 s default), so
  /// a short snore produces a ~62 s WAV mostly filled with silence. The
  /// classifier correctly amplitude-gates that silence, leaving a tiny
  /// coloured region in an otherwise-blank waveform. This trim matches
  /// Sleep Talk Recorder's approach: cut the dead tails, keep only the
  /// audio that actually matters.
  ///
  /// Returns the updated Recording (possibly identical if no trim was
  /// worthwhile). The WAV file is rewritten in place. Waveform and
  /// windowCategories are proportionally trimmed.
  Future<Recording> trimToActiveRange(Recording rec) async {
    final wins = rec.windowCategories;
    if (wins.length < 3) return rec;

    int? firstActive;
    int? lastActive;
    for (var i = 0; i < wins.length; i++) {
      final c = wins[i];
      if (c != SoundCategory.silence && c != SoundCategory.unknown) {
        firstActive ??= i;
        lastActive = i;
      }
    }
    if (firstActive == null || lastActive == null) return rec;

    const paddingBands = 3;
    final trimStartBand = math.max(0, firstActive - paddingBands);
    final trimEndBand = math.min(wins.length - 1, lastActive + paddingBands);

    // Only trim if we'd save at least 2 s — avoid micro-trims that
    // don't meaningfully change the clip.
    const bandMs = 1000;
    final trimStartMs = trimStartBand * bandMs;
    var trimEndMs = (trimEndBand + 1) * bandMs;
    if (trimEndMs > rec.durationMs) trimEndMs = rec.durationMs;
    final newDurationMs = trimEndMs - trimStartMs;
    if (newDurationMs <= 0) return rec;
    if (rec.durationMs - newDurationMs < 2000) return rec;

    // Rewrite the WAV file.
    final file = File(rec.filePath);
    if (!await file.exists()) return rec;
    final bytes = await file.readAsBytes();
    final trimmed = _trimWavBytes(bytes, trimStartMs, trimEndMs);
    if (trimmed == null) return rec;
    await file.writeAsBytes(trimmed);

    // Proportional trim of the waveform samples.
    final oldWf = rec.waveform;
    List<double> newWf = oldWf;
    if (oldWf.isNotEmpty) {
      final wfStart = (oldWf.length * trimStartMs / rec.durationMs)
          .floor()
          .clamp(0, oldWf.length);
      final wfEnd = (oldWf.length * trimEndMs / rec.durationMs)
          .ceil()
          .clamp(wfStart, oldWf.length);
      newWf = oldWf.sublist(wfStart, wfEnd);
    }

    final newWins = wins.sublist(trimStartBand, trimEndBand + 1);
    final oldSecondary = rec.windowCategoriesSecondary;
    final newSecondary = oldSecondary.isEmpty
        ? const <SoundCategory>[]
        : oldSecondary.sublist(
            trimStartBand.clamp(0, oldSecondary.length),
            (trimEndBand + 1).clamp(0, oldSecondary.length),
          );

    return Recording(
      id: rec.id,
      filePath: rec.filePath,
      startedAt: rec.startedAt.add(Duration(milliseconds: trimStartMs)),
      durationMs: newDurationMs,
      peakDb: rec.peakDb,
      avgDb: rec.avgDb,
      category: rec.category,
      categoryLabel: rec.categoryLabel,
      categoryConfidence: rec.categoryConfidence,
      tags: rec.tags,
      waveform: newWf,
      windowCategories: newWins,
      windowCategoriesSecondary: newSecondary,
    );
  }

  /// Byte-level trim of a PCM 16-bit mono 16 kHz WAV. Assumes our own
  /// WAV format with a 44-byte header (matches [AudioRecorderService]'s
  /// [_buildWavHeader]). Returns the trimmed bytes or null if the input
  /// isn't parseable.
  Uint8List? _trimWavBytes(Uint8List bytes, int startMs, int endMs) {
    if (bytes.length < 44) return null;
    // RIFF / WAVE / fmt signature check.
    if (bytes[0] != 0x52 ||
        bytes[1] != 0x49 ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x46) {
      return null;
    }
    const sampleRate = 16000;
    const bytesPerSample = 2;
    const channels = 1;
    const bytesPerMs = sampleRate * bytesPerSample * channels ~/ 1000;
    const headerBytes = 44;

    final dataStart = headerBytes + startMs * bytesPerMs;
    var dataEnd = headerBytes + endMs * bytesPerMs;
    if (dataStart >= bytes.length) return null;
    if (dataEnd > bytes.length) dataEnd = bytes.length;
    final payloadSize = dataEnd - dataStart;
    if (payloadSize <= 0) return null;
    final totalSize = headerBytes + payloadSize;

    final out = Uint8List(totalSize);
    out.setRange(0, headerBytes, bytes);

    // RIFF size at offset 4 (total - 8).
    final bd = ByteData.sublistView(out);
    bd.setUint32(4, totalSize - 8, Endian.little);
    // data size at offset 40.
    bd.setUint32(40, payloadSize, Endian.little);

    out.setRange(headerBytes, totalSize, bytes, dataStart);
    return out;
  }
}
