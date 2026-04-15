import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_services.dart';
import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import 'night_detail_screen.dart';

class NightsScreen extends StatefulWidget {
  const NightsScreen({super.key});

  @override
  State<NightsScreen> createState() => _NightsScreenState();
}

class _NightsScreenState extends State<NightsScreen> {
  List<Recording> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppServices.of(context).recorder.addSegmentListener(_onNewClip);
    });
  }

  @override
  void dispose() {
    try {
      AppServices.of(context).recorder.removeSegmentListener(_onNewClip);
    } catch (_) {}
    super.dispose();
  }

  void _onNewClip(Recording r) {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final all = await AppServices.of(context).storage.loadAll();
    if (mounted) setState(() {
      _all = all;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_all.isEmpty) {
      return const _EmptyView();
    }
    final grouped = <DateTime, List<Recording>>{};
    for (final r in _all) {
      grouped.putIfAbsent(r.nightKey, () => []).add(r);
    }
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: keys.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) {
          final night = keys[i];
          final recs = grouped[night]!;
          return _NightCard(
            night: night,
            recordings: recs,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      NightDetailScreen(night: night, recordings: recs),
                ),
              );
              _load();
            },
          );
        },
      ),
    );
  }
}

class _NightCard extends StatelessWidget {
  final DateTime night;
  final List<Recording> recordings;
  final VoidCallback onTap;

  const _NightCard({
    required this.night,
    required this.recordings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEEE, MMM d');
    final nextDay = night.add(const Duration(days: 1));
    final label = fmt.format(night);
    final endLabel = DateFormat('MMM d').format(nextDay);

    final counts = <SoundCategory, int>{};
    for (final r in recordings) {
      counts[r.category] = (counts[r.category] ?? 0) + 1;
    }
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final totalDurMs = recordings.fold<int>(0, (s, r) => s + r.durationMs);
    final dur = Duration(milliseconds: totalDurMs);
    final totalLabel = dur.inMinutes >= 1
        ? '${dur.inMinutes}m'
        : '${dur.inSeconds}s';

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '→ $endLabel',
                    style: const TextStyle(
                        color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${recordings.length} clip${recordings.length == 1 ? '' : 's'} · $totalLabel total',
                style:
                    const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: top.take(5).map((e) {
                  final info = categoryInfo[e.key]!;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: info.color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(info.icon, color: info.color, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          '${info.label} · ${e.value}',
                          style: TextStyle(
                            color: info.color,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.nightlife,
                size: 64,
                color: AppColors.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            const Text(
              'No recordings yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Head to Tonight and tap Start to begin your first session.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
