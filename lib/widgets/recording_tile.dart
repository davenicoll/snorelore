import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import 'waveform_painter.dart';

class RecordingTile extends StatefulWidget {
  final Recording recording;
  final VoidCallback? onDelete;
  final VoidCallback? onShare;

  const RecordingTile({
    super.key,
    required this.recording,
    this.onDelete,
    this.onShare,
  });

  @override
  State<RecordingTile> createState() => _RecordingTileState();
}

class _RecordingTileState extends State<RecordingTile> {
  bool _expanded = false;
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _scrubbing = false;
  double _scrubTarget = 0;

  @override
  void dispose() {
    _teardownPlayer();
    super.dispose();
  }

  Future<void> _toggleExpanded() async {
    if (_expanded) {
      setState(() => _expanded = false);
      await _teardownPlayer();
    } else {
      setState(() => _expanded = true);
      await _setupPlayer();
    }
  }

  Future<void> _setupPlayer() async {
    final p = AudioPlayer();
    _player = p;
    try {
      final d = await p.setFilePath(widget.recording.filePath);
      if (!mounted) return;
      setState(() {
        _dur = d ?? Duration(milliseconds: widget.recording.durationMs);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load clip: $e')),
      );
      return;
    }
    _posSub = p.positionStream.listen((pos) {
      if (!_scrubbing && mounted) setState(() => _pos = pos);
    });
    _stateSub = p.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        p.seek(Duration.zero);
        p.pause();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _teardownPlayer() async {
    await _posSub?.cancel();
    await _stateSub?.cancel();
    _posSub = null;
    _stateSub = null;
    final p = _player;
    _player = null;
    try {
      await p?.dispose();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _pos = Duration.zero;
        _dur = Duration.zero;
      });
    }
  }

  Future<void> _togglePlay() async {
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
    } else {
      await p.play();
    }
    if (mounted) setState(() {});
  }

  String _mmss(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.recording;
    final info = categoryInfo[r.category]!;
    final timeFmt = DateFormat.jm().format(r.startedAt);
    final dur = Duration(milliseconds: r.durationMs);
    final durLabel = dur.inMinutes >= 1
        ? '${dur.inMinutes}m ${(dur.inSeconds % 60).toString().padLeft(2, '0')}s'
        : '${dur.inSeconds}s';

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: _toggleExpanded,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$timeFmt · $durLabel',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted),
                            ),
                          ],
                        ),
                        if (r.tags.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _TagRow(tags: r.tags),
                        ],
                        if (!_expanded) ...[
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 26,
                            child: CustomPaint(
                              size: const Size.fromHeight(26),
                              painter: WaveformPainter(
                                samples: r.waveform,
                                color:
                                    info.color.withValues(alpha: 0.55),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        color: AppColors.textMuted),
                    color: AppColors.surfaceAlt,
                    onSelected: (v) {
                      if (v == 'delete') widget.onDelete?.call();
                      if (v == 'share') widget.onShare?.call();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'share', child: Text('Share')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              if (_expanded) _expandedPlayer(r, info),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expandedPlayer(Recording r, CategoryInfo info) {
    final totalMs =
        _dur.inMilliseconds == 0 ? r.durationMs : _dur.inMilliseconds;
    final progressMs =
        _scrubbing ? (_scrubTarget * totalMs).round() : _pos.inMilliseconds;
    final progress = totalMs == 0 ? 0.0 : progressMs / totalMs;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 6, 4),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (_, c) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) {
                  setState(() {
                    _scrubbing = true;
                    _scrubTarget = progress.clamp(0.0, 1.0);
                  });
                },
                onHorizontalDragUpdate: (d) {
                  setState(() {
                    _scrubTarget = ((_scrubTarget * c.maxWidth + d.delta.dx) /
                            c.maxWidth)
                        .clamp(0.0, 1.0);
                  });
                },
                onHorizontalDragEnd: (_) async {
                  final target = Duration(
                      milliseconds: (_scrubTarget * totalMs).round());
                  setState(() => _scrubbing = false);
                  await _player?.seek(target);
                },
                onTapDown: (d) async {
                  final x = d.localPosition.dx / c.maxWidth;
                  final target = Duration(
                      milliseconds: (x.clamp(0.0, 1.0) * totalMs).round());
                  await _player?.seek(target);
                  setState(() => _pos = target);
                },
                child: SizedBox(
                  height: 80,
                  child: CustomPaint(
                    size: Size(c.maxWidth, 80),
                    painter: WaveformPainter(
                      samples: r.waveform,
                      progress: progress.clamp(0.0, 1.0),
                      color: info.color.withValues(alpha: 0.35),
                      playedColor: info.color,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(_mmss(Duration(milliseconds: progressMs)),
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
              const Spacer(),
              Text(_mmss(Duration(milliseconds: totalMs)),
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          _playButton(info),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _playButton(CategoryInfo info) {
    final playing = _player?.playing ?? false;
    final ready = _player != null;
    return GestureDetector(
      onTap: ready ? _togglePlay : null,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            colors: [AppColors.primary, AppColors.teal],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.4),
              blurRadius: 14,
            ),
          ],
        ),
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          color: Colors.white,
          size: 30,
        ),
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  final List<SoundCategory> tags;
  const _TagRow({required this.tags});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: tags.map((t) {
        final info = categoryInfo[t]!;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: info.color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(info.icon, color: info.color, size: 11),
              const SizedBox(width: 4),
              Text(
                info.label,
                style: TextStyle(
                  color: info.color,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
