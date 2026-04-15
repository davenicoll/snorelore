import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:share_plus/share_plus.dart';

import '../app_services.dart';
import '../models/recording.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';
import '../widgets/waveform_painter.dart';

class RecordingDetailScreen extends StatefulWidget {
  final Recording recording;
  const RecordingDetailScreen({super.key, required this.recording});

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _ready = false;
  bool _scrubbing = false;
  double _scrubTarget = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final d = await _player.setFilePath(widget.recording.filePath);
      if (!mounted) return;
      setState(() {
        _dur = d ??
            Duration(milliseconds: widget.recording.durationMs);
        _ready = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _ready = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load clip: $e')),
      );
    }
    _posSub = _player.positionStream.listen((p) {
      if (!_scrubbing && mounted) setState(() => _pos = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _share() async {
    final r = widget.recording;
    await Share.shareXFiles(
      [XFile(r.filePath, mimeType: 'audio/wav')],
      subject: 'SnoreLore · ${r.categoryLabel}',
      text: 'From SnoreLore · ${DateFormat.jm().format(r.startedAt)}',
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete this clip?'),
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
    await AppServices.of(context).storage.delete(widget.recording);
    if (mounted) Navigator.pop(context);
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
    final totalMs = _dur.inMilliseconds == 0 ? r.durationMs : _dur.inMilliseconds;
    final progressMs = _scrubbing
        ? (_scrubTarget * totalMs).round()
        : _pos.inMilliseconds;
    final progress = totalMs == 0 ? 0.0 : progressMs / totalMs;

    return Scaffold(
      appBar: AppBar(
        title: Text(info.label),
        actions: [
          IconButton(
              onPressed: _share, icon: const Icon(Icons.ios_share)),
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline, color: AppColors.red),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            _header(r, info),
            const SizedBox(height: 24),
            _waveform(r, info, progress, totalMs),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(_mmss(Duration(milliseconds: progressMs)),
                    style: const TextStyle(color: AppColors.textMuted)),
                const Spacer(),
                Text(_mmss(Duration(milliseconds: totalMs)),
                    style: const TextStyle(color: AppColors.textMuted)),
              ],
            ),
            const SizedBox(height: 24),
            _playButton(),
            const SizedBox(height: 24),
            _detailsCard(r, info),
          ],
        ),
      ),
    );
  }

  Widget _header(Recording r, CategoryInfo info) {
    final when = DateFormat('EEE, MMM d · jm').format(r.startedAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: info.color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(info.icon, color: info.color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.categoryLabel,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(when,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
                  if (r.categoryConfidence > 0)
                    Text(
                      '${(r.categoryConfidence * 100).toStringAsFixed(0)}% confidence',
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 11),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waveform(
    Recording r,
    CategoryInfo info,
    double progress,
    int totalMs,
  ) {
    return LayoutBuilder(
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
              _scrubTarget =
                  ((_scrubTarget * c.maxWidth + d.delta.dx) / c.maxWidth)
                      .clamp(0.0, 1.0);
            });
          },
          onHorizontalDragEnd: (_) async {
            final target = Duration(milliseconds: (_scrubTarget * totalMs).round());
            setState(() => _scrubbing = false);
            await _player.seek(target);
          },
          onTapDown: (d) async {
            final x = d.localPosition.dx / c.maxWidth;
            final target =
                Duration(milliseconds: (x.clamp(0.0, 1.0) * totalMs).round());
            await _player.seek(target);
            setState(() => _pos = target);
          },
          child: SizedBox(
            height: 120,
            child: CustomPaint(
              size: Size(c.maxWidth, 120),
              painter: WaveformPainter(
                samples: r.waveform,
                progress: progress.clamp(0.0, 1.0),
                color: info.color.withValues(alpha: 0.4),
                playedColor: info.color,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _playButton() {
    final playing = _player.playing;
    return GestureDetector(
      onTap: _ready ? _toggle : null,
      child: Container(
        width: 88,
        height: 88,
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
              blurRadius: 18,
            ),
          ],
        ),
        child: Icon(
          playing ? Icons.pause : Icons.play_arrow,
          color: Colors.white,
          size: 44,
        ),
      ),
    );
  }

  Widget _detailsCard(Recording r, CategoryInfo info) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _row('Peak',
                '${r.peakDb.toStringAsFixed(1)} dB', Icons.north_east),
            const Divider(height: 16),
            _row('Average',
                '${r.avgDb.toStringAsFixed(1)} dB', Icons.show_chart),
            const Divider(height: 16),
            _row(
                'Duration',
                _mmss(Duration(milliseconds: r.durationMs)),
                Icons.timer_outlined),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: const TextStyle(color: AppColors.textMuted)),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}
