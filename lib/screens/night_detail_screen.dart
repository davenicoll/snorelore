import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';
import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import '../widgets/category_recording_tile.dart';

class NightDetailScreen extends StatefulWidget {
  final DateTime night;
  final List<Recording> recordings;

  const NightDetailScreen({
    super.key,
    required this.night,
    required this.recordings,
  });

  @override
  State<NightDetailScreen> createState() => _NightDetailScreenState();
}

class _NightDetailScreenState extends State<NightDetailScreen> {
  late List<Recording> _recordings;
  bool _developerMode = false;

  @override
  void initState() {
    super.initState();
    _recordings = List.of(widget.recordings)
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevMode());
  }

  Future<void> _loadDevMode() async {
    final s = await AppServices.of(context).settings.load();
    if (mounted) setState(() => _developerMode = s.developerMode);
  }

  Future<void> _refresh() async {
    final all = await AppServices.of(context).storage.loadAll();
    final filtered = all.where((r) => r.nightKey == widget.night).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (mounted) setState(() => _recordings = filtered);
  }

  Future<void> _shareRecording(Recording r) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Share.shareXFiles(
        [XFile(r.filePath, mimeType: 'audio/wav')],
        subject: 'SnoreLore · ${r.categoryLabel}',
        text: 'From SnoreLore · ${DateFormat.jm().format(r.startedAt)}',
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }

  Future<void> _deleteRecording(Recording r) async {
    await AppServices.of(context).storage.delete(r);
    await _refresh();
  }

  Future<void> _reanalyzeRecording(Recording r) async {
    final svc = AppServices.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Re-analyzing…'),
        duration: Duration(seconds: 1),
      ),
    );
    try {
      final result = await svc.classifier.classifyWavFile(r.filePath);
      if (result == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not classify clip')),
        );
        return;
      }
      final updated = r.copyWith(
        category: result.primary.category,
        categoryLabel: result.primary.label,
        categoryConfidence: result.primary.confidence,
        tags: result.tags.map((t) => t.category).toList(),
        windowCategories: result.windowCategories,
      );
      await svc.storage.update(updated);
      await _refresh();
      messenger.showSnackBar(
        SnackBar(content: Text('Reclassified as ${result.primary.label}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Reanalyze failed: $e')),
      );
    }
  }

  Future<void> _deleteAll() async {
    final services = AppServices.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete this night?'),
        content: Text(
          'This removes all ${_recordings.length} clips from '
          '${DateFormat('EEE, MMM d').format(widget.night)}.',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete',
                style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await services.storage.deleteMany(_recordings);
    if (mounted) Navigator.pop(context);
  }

  /// Bucket the clips by display category. One clip can land in multiple
  /// buckets when its primary, tags or per-segment categories fan out
  /// across them.
  Map<DisplayCategory, List<Recording>> _groupByDisplayCategory() {
    final out = <DisplayCategory, List<Recording>>{};
    for (final r in _recordings) {
      final buckets =
          displayCategoriesFor(r.category, r.tags, r.windowCategories);
      for (final d in buckets) {
        out.putIfAbsent(d, () => []).add(r);
      }
    }
    for (final list in out.values) {
      list.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('EEEE, MMM d').format(widget.night);
    final grouped = _groupByDisplayCategory();

    return Scaffold(
      appBar: AppBar(
        title: Text(label),
        actions: [
          IconButton(
            tooltip: 'Delete night',
            icon: const Icon(Icons.delete_outline, color: AppColors.red),
            onPressed: _recordings.isEmpty ? null : _deleteAll,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _recordings.isEmpty
            ? const Center(
                child: Text('No clips for this night',
                    style: TextStyle(color: AppColors.textMuted)),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                children: [
                  for (final cat in DisplayCategory.values)
                    if ((grouped[cat]?.isNotEmpty ?? false))
                      _CategorySection(
                        key: ValueKey('section-${cat.name}'),
                        category: cat,
                        recordings: grouped[cat]!,
                        developerMode: _developerMode,
                        onShare: _shareRecording,
                        onDelete: _deleteRecording,
                        onReanalyze: _reanalyzeRecording,
                      ),
                ],
              ),
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final DisplayCategory category;
  final List<Recording> recordings;
  final bool developerMode;
  final Future<void> Function(Recording) onShare;
  final Future<void> Function(Recording) onDelete;
  final Future<void> Function(Recording) onReanalyze;

  const _CategorySection({
    super.key,
    required this.category,
    required this.recordings,
    required this.developerMode,
    required this.onShare,
    required this.onDelete,
    required this.onReanalyze,
  });

  @override
  Widget build(BuildContext context) {
    final info = displayCategoryInfo[category]!;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 4, 6),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: info.color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(info.icon, color: info.color, size: 18),
          ),
          title: Text(
            info.label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${recordings.length} ${recordings.length == 1 ? 'clip' : 'clips'}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          iconColor: info.color,
          collapsedIconColor: AppColors.textMuted,
          children: [
            for (final r in recordings)
              CategoryRecordingTile(
                key: ValueKey('${category.name}-${r.id}'),
                recording: r,
                highlight: category,
                onShare: () => onShare(r),
                onDelete: () => onDelete(r),
                onReanalyze: () => onReanalyze(r),
                showReanalyze: developerMode,
              ),
          ],
        ),
      ),
    );
  }
}
