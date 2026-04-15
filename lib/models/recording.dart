import '../utils/categories.dart';

class Recording {
  final String id;
  final String filePath;
  final DateTime startedAt;
  final int durationMs;
  final double peakDb;
  final double avgDb;
  final SoundCategory category;
  final String categoryLabel;
  final double categoryConfidence;
  final List<double> waveform;

  const Recording({
    required this.id,
    required this.filePath,
    required this.startedAt,
    required this.durationMs,
    required this.peakDb,
    required this.avgDb,
    required this.category,
    required this.categoryLabel,
    required this.categoryConfidence,
    required this.waveform,
  });

  /// The "night" key for grouping. Sounds between noon and midnight are
  /// assigned to that day; sounds after midnight until noon go back to the
  /// previous day. That way one sleep session is a single night.
  DateTime get nightKey {
    final d = startedAt;
    if (d.hour < 12) {
      final prev = DateTime(d.year, d.month, d.day).subtract(const Duration(days: 1));
      return prev;
    }
    return DateTime(d.year, d.month, d.day);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'startedAt': startedAt.toIso8601String(),
        'durationMs': durationMs,
        'peakDb': peakDb,
        'avgDb': avgDb,
        'category': category.name,
        'categoryLabel': categoryLabel,
        'categoryConfidence': categoryConfidence,
        'waveform': waveform,
      };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        filePath: j['filePath'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        durationMs: j['durationMs'] as int,
        peakDb: (j['peakDb'] as num?)?.toDouble() ?? 0,
        avgDb: (j['avgDb'] as num?)?.toDouble() ?? 0,
        category: SoundCategory.values.firstWhere(
          (c) => c.name == j['category'],
          orElse: () => SoundCategory.unknown,
        ),
        categoryLabel: j['categoryLabel'] as String? ?? 'Other',
        categoryConfidence: (j['categoryConfidence'] as num?)?.toDouble() ?? 0,
        waveform: ((j['waveform'] as List?) ?? [])
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}
