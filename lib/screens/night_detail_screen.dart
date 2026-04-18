import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';
import '../models/recording.dart';
import '../utils/theme.dart';
import '../widgets/recording_tile.dart';

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

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('EEEE, MMM d').format(widget.night);
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
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: _recordings.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final r = _recordings[i];
                  return RecordingTile(
                    key: ValueKey(r.id),
                    recording: r,
                    onDelete: () => _deleteRecording(r),
                    onShare: () => _shareRecording(r),
                    showReanalyze: _developerMode,
                    onReanalyze: () => _reanalyzeRecording(r),
                  );
                },
              ),
      ),
    );
  }
}
