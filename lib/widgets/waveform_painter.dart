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

  /// Optional secondary colours. When provided, each bar is split
  /// horizontally: the top half uses [segmentColors]' resolved colour,
  /// the bottom half uses [segmentColorsSecondary]'s resolved colour.
  /// A null entry falls back to the primary side, so bands with only
  /// one category stay single-colour.
  final List<Color?>? segmentColorsSecondary;

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
    this.segmentColorsSecondary,
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
    final primary = segmentColors;
    final secondary = segmentColorsSecondary;
    final primaryCount = primary?.length ?? 0;
    final secondaryCount = secondary?.length ?? 0;

    for (var i = 0; i < barCount; i++) {
      final x = i * step;
      final amp = bars[i].clamp(0.0, 1.0);
      final h = math.max(2.0, amp * size.height);

      Color primaryColor = baseColor;
      if (primaryCount > 0) {
        final segIdx = ((i * primaryCount) ~/ barCount).clamp(0, primaryCount - 1);
        final seg = primary![segIdx];
        if (seg != null) primaryColor = seg;
      }
      Color? secondaryColor;
      if (secondaryCount > 0) {
        final segIdx =
            ((i * secondaryCount) ~/ barCount).clamp(0, secondaryCount - 1);
        final seg = secondary![segIdx];
        if (seg != null && seg != primaryColor) secondaryColor = seg;
      }

      final played = progress > 0 && (x + barWidth / 2) < progressX;
      Color toRenderAlpha(Color c) => progress > 0 && !played
          ? c.withValues(alpha: c.a * unplayedAlpha)
          : c;

      if (secondaryColor == null) {
        // Single-colour bar (common case).
        final paint = Paint()
          ..style = PaintingStyle.fill
          ..color = toRenderAlpha(primaryColor);
        final rect = Rect.fromLTWH(x, mid - h / 2, barWidth, h);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
      } else {
        // Dual colour: primary on top half (above centreline), secondary
        // on bottom half. The halves share the rounded outer corners but
        // meet on the centreline.
        final topRect = Rect.fromLTWH(x, mid - h / 2, barWidth, h / 2);
        final bottomRect = Rect.fromLTWH(x, mid, barWidth, h / 2);
        final topPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = toRenderAlpha(primaryColor);
        final bottomPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = toRenderAlpha(secondaryColor);
        canvas.drawRRect(
          RRect.fromRectAndCorners(topRect,
              topLeft: radius, topRight: radius),
          topPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(bottomRect,
              bottomLeft: radius, bottomRight: radius),
          bottomPaint,
        );
      }
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
      !_sameSegments(old.segmentColors, segmentColors) ||
      !_sameSegments(old.segmentColorsSecondary, segmentColorsSecondary);

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
