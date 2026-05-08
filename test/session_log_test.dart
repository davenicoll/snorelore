import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snorelore/services/session_log_service.dart';

void main() {
  group('SessionLogEntry', () {
    test('clean exit (user) is endedCleanly and not inferredKilled', () {
      final e = SessionLogEntry(
        startedAt: DateTime(2026, 5, 8, 22, 30),
        endedAt: DateTime(2026, 5, 9, 7, 0),
        stopReason: SessionStopReason.user,
        segmentsCaptured: 14,
      );
      expect(e.endedCleanly, isTrue);
      expect(e.inferredKilled, isFalse);
    });

    test('schedule exit is endedCleanly', () {
      final e = SessionLogEntry(
        startedAt: DateTime(2026, 5, 8, 22, 30),
        endedAt: DateTime(2026, 5, 9, 7, 0),
        stopReason: SessionStopReason.schedule,
      );
      expect(e.endedCleanly, isTrue);
    });

    test('stream error is not clean and not inferredKilled', () {
      final e = SessionLogEntry(
        startedAt: DateTime(2026, 5, 8, 22, 30),
        endedAt: DateTime(2026, 5, 9, 1, 14),
        stopReason: SessionStopReason.streamError,
        stopDetail: 'AudioFocusLost',
      );
      expect(e.endedCleanly, isFalse);
      expect(e.inferredKilled, isFalse);
    });

    test('missing endedAt means inferredKilled (app died)', () {
      final e = SessionLogEntry(
        startedAt: DateTime(2026, 5, 8, 22, 30),
        lastChunkAt: DateTime(2026, 5, 9, 2, 14),
      );
      expect(e.inferredKilled, isTrue);
      expect(e.endedCleanly, isFalse);
    });

    test('JSON round-trip preserves all fields', () {
      final e = SessionLogEntry(
        startedAt: DateTime.utc(2026, 5, 8, 22, 30),
        lastChunkAt: DateTime.utc(2026, 5, 9, 2, 14),
        endedAt: DateTime.utc(2026, 5, 9, 7, 0),
        stopReason: SessionStopReason.streamDone,
        stopDetail: 'mic closed',
        segmentsCaptured: 7,
      );
      final round = SessionLogEntry.fromJson(
        jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>,
      );
      expect(round.startedAt, e.startedAt);
      expect(round.lastChunkAt, e.lastChunkAt);
      expect(round.endedAt, e.endedAt);
      expect(round.stopReason, e.stopReason);
      expect(round.stopDetail, e.stopDetail);
      expect(round.segmentsCaptured, e.segmentsCaptured);
    });

    test('copyWith preserves immutable startedAt', () {
      final e = SessionLogEntry(startedAt: DateTime(2026, 5, 8, 22, 30));
      final updated = e.copyWith(
        endedAt: DateTime(2026, 5, 9, 7, 0),
        stopReason: SessionStopReason.user,
      );
      expect(updated.startedAt, e.startedAt);
      expect(updated.endedAt, isNotNull);
      expect(updated.stopReason, SessionStopReason.user);
    });
  });
}
