import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/theme.dart';

class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final double progress;
  final Color color;
  final Color playedColor;
  final double barWidth;
  final double gap;

  WaveformPainter({
    required this.samples,
    this.progress = 0,
    this.color = AppColors.primary,
    this.playedColor = AppColors.accent,
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

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final playedPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = playedColor;

    final mid = size.height / 2;
    final progressX = progress * size.width;
    final radius = Radius.circular(barWidth / 2);

    for (var i = 0; i < barCount; i++) {
      final x = i * step;
      final amp = bars[i].clamp(0.0, 1.0);
      final h = math.max(2.0, amp * size.height);
      final rect = Rect.fromLTWH(x, mid - h / 2, barWidth, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        (x + barWidth / 2) < progressX ? playedPaint : paint,
      );
    }

    if (progress > 0 && progress < 1) {
      canvas.drawRect(
        Rect.fromLTWH(progressX - 1, 0, 2, size.height),
        Paint()..color = playedColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.progress != progress ||
      old.samples != samples ||
      old.color != color ||
      old.playedColor != playedColor ||
      old.barWidth != barWidth ||
      old.gap != gap;
}
