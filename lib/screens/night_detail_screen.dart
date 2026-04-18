import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';
import '../models/app_settings.dart';
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
  NightDetailView _view = NightDetailView.categories;

  @override
  void initState() {
    super.initState();
    _recordings = List.of(widget.recordings)
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final s = await AppServices.of(context).settings.load();
    if (mounted) {
      setState(() {
        _developerMode = s.developerMode;
        _view = s.nightDetailView;
      });
    }
  }

  Future<void> _setView(NightDetailView v) async {
    setState(() => _view = v);
    final svc = AppServices.of(context).settings;
    final s = await svc.load();
    await svc.save(s.copyWith(nightDetailView: v));
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

    return Scaffold(
      appBar: AppBar(
        title: Text(label),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: AppColors.surfaceAlt,
            onSelected: (v) {
              if (v == 'toggle') {
                _setView(_view == NightDetailView.categories
                    ? NightDetailView.timeline
                    : NightDetailView.categories);
              } else if (v == 'delete') {
                if (_recordings.isNotEmpty) _deleteAll();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'toggle',
                child: Text(
                  _view == NightDetailView.categories
                      ? 'Timeline view'
                      : 'Categories view',
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                enabled: _recordings.isNotEmpty,
                child: const Text(
                  'Delete all',
                  style: TextStyle(color: AppColors.red),
                ),
              ),
            ],
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
            : _view == NightDetailView.timeline
                ? _buildTimeline()
                : _buildCategories(),
      ),
    );
  }

  Widget _buildCategories() {
    final grouped = _groupByDisplayCategory();
    return ListView(
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
    );
  }

  Widget _buildTimeline() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _recordings.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = _recordings[i];
        final highlight = displayCategoryOf(r.category);
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.fromLTRB(8, 2, 4, 4),
          child: CategoryRecordingTile(
            key: ValueKey('timeline-${r.id}'),
            recording: r,
            highlight: highlight,
            sessionId: 'timeline-${r.id}',
            multiColor: true,
            onShare: () => _shareRecording(r),
            onDelete: () => _deleteRecording(r),
            onReanalyze: () => _reanalyzeRecording(r),
            showReanalyze: _developerMode,
          ),
        );
      },
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
                sessionId: '${category.name}-${r.id}',
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
