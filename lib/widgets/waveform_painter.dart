import 'package:flutter/material.dart';
import '../utils/theme.dart';

class WaveformPainter extends CustomPainter {
  final List<double> samples;
  final double progress;
  final Color color;
  final Color playedColor;

  WaveformPainter({
    required this.samples,
    this.progress = 0,
    this.color = AppColors.primary,
    this.playedColor = AppColors.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final playedPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = playedColor;

    final gap = 2.0;
    final barW = ((size.width - gap) / samples.length) - gap;
    final mid = size.height / 2;
    final progressX = progress * size.width;

    for (var i = 0; i < samples.length; i++) {
      final x = i * (barW + gap);
      final amp = samples[i].clamp(0.0, 1.0);
      final h = (amp * size.height).clamp(2.0, size.height);
      final rect = Rect.fromLTWH(x, mid - h / 2, barW, h);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(1.5));
      canvas.drawRRect(rrect, x + barW / 2 < progressX ? playedPaint : paint);
    }

    // Progress handle
    if (progress > 0 && progress < 1) {
      final handle = Paint()..color = playedColor;
      canvas.drawRect(
        Rect.fromLTWH(progressX - 1, 0, 2, size.height),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.progress != progress ||
      old.samples != samples ||
      old.color != color ||
      old.playedColor != playedColor;
}
