import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import 'waveform_painter.dart';

/// Compact recording row used under a [DisplayCategory] heading on the
/// Night Detail screen. Header line is the time-of-day and clip duration;
/// body is a waveform with only the segments whose category maps to
/// [highlight] tinted, plus an inline play/pause and overflow menu.
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
  /// Only one tile can play audio at a time; the previously active tile
  /// pauses itself when a new one starts.
  static _CategoryRecordingTileState? _activePlayer;

  static const Color _waveformBase = Color(0xFFA497FF);

  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    final p = AudioPlayer();
    _player = p;
    try {
      final d = await p.setFilePath(widget.recording.filePath);
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {
        _dur = d ?? Duration(milliseconds: widget.recording.durationMs);
      });
    } catch (e) {
      _player = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load clip: $e')),
        );
      }
      return;
    }
    _posSub = p.positionStream.listen((pos) {
      if (mounted) setState(() => _pos = pos);
    });
    _stateSub = p.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        p.seek(Duration.zero);
        p.pause();
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _teardown() async {
    await _posSub?.cancel();
    await _stateSub?.cancel();
    _posSub = null;
    _stateSub = null;
    final p = _player;
    _player = null;
    if (_activePlayer == this) _activePlayer = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }

  Future<void> _togglePlay() async {
    await _ensurePlayer();
    final p = _player;
    if (p == null) return;
    if (p.playing) {
      await p.pause();
    } else {
      final prev = _activePlayer;
      if (prev != null && prev != this) {
        try {
          await prev._player?.pause();
        } catch (_) {}
        if (prev.mounted) prev.setState(() {});
      }
      _activePlayer = this;
      await p.play();
    }
    if (mounted) setState(() {});
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
    final playing = _player?.playing ?? false;
    final totalMs = _dur.inMilliseconds == 0
        ? widget.recording.durationMs
        : _dur.inMilliseconds;
    final progress =
        totalMs == 0 ? 0.0 : _pos.inMilliseconds / totalMs;
    final showProgress = playing || _pos.inMilliseconds > 0;

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
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: CustomPaint(
                    size: const Size.fromHeight(34),
                    painter: WaveformPainter(
                      samples: widget.recording.waveform,
                      segmentColors: _segmentColors(),
                      progress: showProgress ? progress.clamp(0.0, 1.0) : 0,
                      baseColor: _waveformBase,
                      unplayedAlpha: 0.35,
                      barWidth: 1.5,
                      gap: 1.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _PlayButton(
                playing: playing,
                color: info.color,
                onTap: _togglePlay,
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
