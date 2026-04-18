import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/theme.dart';

class WaveformPainter extends CustomPainter {
  final List<double> samples;

  /// Optional per-segment colour override. Each entry corresponds to an
  /// equal slice of the clip. Where an entry is null the bar falls back to
  /// [baseColor]. Used to tint the parts of the waveform where the
  /// classifier detected a specific category.
  final List<Color?>? segmentColors;

  /// Playback progress in [0, 1]. When > 0 the played portion of each bar
  /// is rendered at full opacity and the unplayed portion at [unplayedAlpha]
  /// of its resolved colour.
  final double progress;

  /// Base colour for bars that don't fall within a classified segment.
  final Color baseColor;

  /// Alpha multiplier for bars that haven't been played yet. Ignored when
  /// [progress] is 0 (i.e. the preview on the collapsed tile).
  final double unplayedAlpha;

  final double barWidth;
  final double gap;

  WaveformPainter({
    required this.samples,
    this.segmentColors,
    this.progress = 0,
    this.baseColor = AppColors.primary,
    this.unplayedAlpha = 0.35,
    this.barWidth = 2.0,
    this.gap = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0) return;

    final step = barWidth + gap;
    final barCount = math.max(1, (size.width / step).floor());

    // Resample the waveform to exactly `barCount` values. If the source has
    // more samples than bars we peak-bucket; if fewer, we stretch by picking
    // the nearest source sample for each bar. Either way the rendered density
    // is driven by width, not by how many raw samples the clip produced.
    final bars = List<double>.filled(barCount, 0);
    final n = samples.length;
    if (n <= barCount) {
      for (var i = 0; i < barCount; i++) {
        final srcIdx = ((i * n) ~/ barCount).clamp(0, n - 1);
        bars[i] = samples[srcIdx];
      }
    } else {
      for (var i = 0; i < barCount; i++) {
        final start = (i * n) ~/ barCount;
        final end = math.min(((i + 1) * n) ~/ barCount, n);
        var peak = 0.0;
        for (var j = start; j < end; j++) {
          final v = samples[j];
          if (v > peak) peak = v;
        }
        bars[i] = peak;
      }
    }

    final mid = size.height / 2;
    final progressX = progress * size.width;
    final radius = Radius.circular(barWidth / 2);
    final segColors = segmentColors;
    final segCount = segColors?.length ?? 0;

    for (var i = 0; i < barCount; i++) {
      final x = i * step;
      final amp = bars[i].clamp(0.0, 1.0);
      final h = math.max(2.0, amp * size.height);

      Color resolved = baseColor;
      if (segCount > 0) {
        final segIdx = ((i * segCount) ~/ barCount).clamp(0, segCount - 1);
        final seg = segColors![segIdx];
        if (seg != null) resolved = seg;
      }

      final played = progress > 0 && (x + barWidth / 2) < progressX;
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = progress > 0 && !played
            ? resolved.withValues(alpha: resolved.a * unplayedAlpha)
            : resolved;

      final rect = Rect.fromLTWH(x, mid - h / 2, barWidth, h);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
    }

    if (progress > 0 && progress < 1) {
      canvas.drawRect(
        Rect.fromLTWH(progressX - 1, 0, 2, size.height),
        Paint()..color = baseColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.progress != progress ||
      old.samples != samples ||
      old.baseColor != baseColor ||
      old.unplayedAlpha != unplayedAlpha ||
      old.barWidth != barWidth ||
      old.gap != gap ||
      !_sameSegments(old.segmentColors, segmentColors);

  static bool _sameSegments(List<Color?>? a, List<Color?>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
