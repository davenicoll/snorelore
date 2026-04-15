import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import 'waveform_painter.dart';

class RecordingTile extends StatelessWidget {
  final Recording recording;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onShare;

  const RecordingTile({
    super.key,
    required this.recording,
    this.onTap,
    this.onDelete,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final info = categoryInfo[recording.category]!;
    final timeFmt = DateFormat.jm().format(recording.startedAt);
    final dur = Duration(milliseconds: recording.durationMs);
    final durLabel = dur.inMinutes >= 1
        ? '${dur.inMinutes}m ${(dur.inSeconds % 60).toString().padLeft(2, '0')}s'
        : '${dur.inSeconds}s';

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: info.color.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(info.icon, color: info.color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          info.label,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$timeFmt · $durLabel',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 26,
                      child: CustomPaint(
                        size: const Size.fromHeight(26),
                        painter: WaveformPainter(
                          samples: recording.waveform,
                          color: info.color.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
                color: AppColors.surfaceAlt,
                onSelected: (v) {
                  if (v == 'delete') onDelete?.call();
                  if (v == 'share') onShare?.call();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'share', child: Text('Share')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
