import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_services.dart';
import '../models/recording.dart';
import '../services/audio_playback_service.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import 'waveform_painter.dart';

/// Compact recording row. Subscribes to the app-wide [AudioPlaybackService]
/// so only one clip can ever play at a time and scrubbing resolves on the
/// real playback position.
class CategoryRecordingTile extends StatefulWidget {
  final Recording recording;
  final DisplayCategory highlight;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;
  final VoidCallback? onReanalyze;
  final bool showReanalyze;

  const CategoryRecordingTile({
    super.key,
    required this.recording,
    required this.highlight,
    this.onShare,
    this.onDelete,
    this.onReanalyze,
    this.showReanalyze = false,
  });

  @override
  State<CategoryRecordingTile> createState() => _CategoryRecordingTileState();
}

class _CategoryRecordingTileState extends State<CategoryRecordingTile> {
  /// Off-white base for untinted bars. Renders brightly against the dark
  /// card background and makes the category-coloured tints pop when they
  /// overlay specific segments.
  static const Color _waveformBase = Color(0xFFE8E6F5);

  StreamSubscription<PlaybackState>? _sub;
  PlaybackState _state = PlaybackState.idle;
  bool _scrubbing = false;
  double _scrubFraction = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final svc = AppServices.of(context).playback;
      _state = svc.state;
      _sub = svc.state$.listen((s) {
        if (mounted) setState(() => _state = s);
      });
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _isActive => _state.activeClipId == widget.recording.id;
  bool get _playing => _isActive && _state.playing;

  int get _totalMs => _isActive && _state.duration.inMilliseconds > 0
      ? _state.duration.inMilliseconds
      : widget.recording.durationMs;

  double get _progress {
    if (_scrubbing) return _scrubFraction;
    if (!_isActive) return 0;
    if (_totalMs == 0) return 0;
    return (_state.position.inMilliseconds / _totalMs).clamp(0.0, 1.0);
  }

  Future<void> _togglePlay() async {
    final svc = AppServices.of(context).playback;
    await svc.toggle(widget.recording.id, widget.recording.filePath);
  }

  Future<void> _seekToFraction(double fraction) async {
    final svc = AppServices.of(context).playback;
    await svc.ensureLoaded(widget.recording.id, widget.recording.filePath);
    final totalMs = svc.state.duration.inMilliseconds > 0
        ? svc.state.duration.inMilliseconds
        : widget.recording.durationMs;
    await svc.seek(
      Duration(milliseconds: (fraction.clamp(0.0, 1.0) * totalMs).round()),
    );
  }

  /// Per-bar colour list for the waveform. Only windows whose category
  /// folds into [highlight] get tinted with that bucket's colour; every
  /// other window (different bucket, unknown, silence) renders in the
  /// base waveform colour.
  List<Color?> _segmentColors() {
    final info = displayCategoryInfo[widget.highlight]!;
    return widget.recording.windowCategories.map<Color?>((c) {
      if (c == SoundCategory.unknown || c == SoundCategory.silence) {
        return null;
      }
      return displayCategoryOf(c) == widget.highlight ? info.color : null;
    }).toList();
  }

  String _header() {
    final r = widget.recording;
    final time = DateFormat.jm().format(r.startedAt);
    final d = Duration(milliseconds: r.durationMs);
    final dur = d.inMinutes >= 1
        ? '${d.inMinutes}m ${d.inSeconds % 60}s'
        : '${d.inSeconds}s';
    return '$time ($dur)';
  }

  @override
  Widget build(BuildContext context) {
    final info = displayCategoryInfo[widget.highlight]!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              _header(),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PlayButton(
                playing: _playing,
                color: info.color,
                onTap: _togglePlay,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final width = constraints.maxWidth;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) {
                        final f = d.localPosition.dx / width;
                        _seekToFraction(f);
                      },
                      onHorizontalDragStart: (d) {
                        setState(() {
                          _scrubbing = true;
                          _scrubFraction =
                              (d.localPosition.dx / width).clamp(0.0, 1.0);
                        });
                      },
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _scrubFraction =
                              (d.localPosition.dx / width).clamp(0.0, 1.0);
                        });
                      },
                      onHorizontalDragEnd: (_) async {
                        final f = _scrubFraction;
                        setState(() => _scrubbing = false);
                        await _seekToFraction(f);
                      },
                      child: SizedBox(
                        height: 36,
                        child: CustomPaint(
                          size: const Size.fromHeight(36),
                          painter: WaveformPainter(
                            samples: widget.recording.waveform,
                            segmentColors: _segmentColors(),
                            progress: _progress,
                            baseColor: _waveformBase,
                            unplayedAlpha: 0.35,
                            barWidth: 1.5,
                            gap: 1.0,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
                color: AppColors.surfaceAlt,
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  if (v == 'share') widget.onShare?.call();
                  if (v == 'delete') widget.onDelete?.call();
                  if (v == 'reanalyze') widget.onReanalyze?.call();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'share', child: Text('Share')),
                  if (widget.showReanalyze)
                    const PopupMenuItem(
                        value: 'reanalyze',
                        child: Text('Reanalyze recording')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final Color color;
  final VoidCallback onTap;
  const _PlayButton({
    required this.playing,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.16),
          border: Border.all(color: color, width: 1.4),
        ),
        alignment: Alignment.center,
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          color: color,
          size: 20,
        ),
      ),
    );
  }
}
