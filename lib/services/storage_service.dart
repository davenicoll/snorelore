import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/recording.dart';

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
}
