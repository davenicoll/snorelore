import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Why a recording session ended. `unknown` is what we see when the app
/// was killed mid-session — there was no stop call, so the active log
/// entry never got finalised.
enum SessionStopReason {
  user,
  schedule,
  streamDone,
  streamError,
  startError,
  unknown,
}

class SessionLogEntry {
  final DateTime startedAt;
  final DateTime? lastChunkAt;
  final DateTime? endedAt;
  final SessionStopReason? stopReason;
  final String? stopDetail;
  final int segmentsCaptured;

  const SessionLogEntry({
    required this.startedAt,
    this.lastChunkAt,
    this.endedAt,
    this.stopReason,
    this.stopDetail,
    this.segmentsCaptured = 0,
  });

  bool get endedCleanly =>
      stopReason == SessionStopReason.user ||
      stopReason == SessionStopReason.schedule;

  /// True when the entry has a startedAt but no endedAt — i.e. the app
  /// was killed before stop() ran.
  bool get inferredKilled => endedAt == null;

  SessionLogEntry copyWith({
    DateTime? lastChunkAt,
    DateTime? endedAt,
    SessionStopReason? stopReason,
    String? stopDetail,
    int? segmentsCaptured,
  }) =>
      SessionLogEntry(
        startedAt: startedAt,
        lastChunkAt: lastChunkAt ?? this.lastChunkAt,
        endedAt: endedAt ?? this.endedAt,
        stopReason: stopReason ?? this.stopReason,
        stopDetail: stopDetail ?? this.stopDetail,
        segmentsCaptured: segmentsCaptured ?? this.segmentsCaptured,
      );

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.toIso8601String(),
        'lastChunkAt': lastChunkAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'stopReason': stopReason?.name,
        'stopDetail': stopDetail,
        'segmentsCaptured': segmentsCaptured,
      };

  factory SessionLogEntry.fromJson(Map<String, dynamic> j) => SessionLogEntry(
        startedAt: DateTime.parse(j['startedAt'] as String),
        lastChunkAt: j['lastChunkAt'] == null
            ? null
            : DateTime.parse(j['lastChunkAt'] as String),
        endedAt: j['endedAt'] == null
            ? null
            : DateTime.parse(j['endedAt'] as String),
        stopReason: j['stopReason'] == null
            ? null
            : SessionStopReason.values.firstWhere(
                (r) => r.name == j['stopReason'],
                orElse: () => SessionStopReason.unknown,
              ),
        stopDetail: j['stopDetail'] as String?,
        segmentsCaptured: j['segmentsCaptured'] as int? ?? 0,
      );
}

/// Persists a single "last session" breadcrumb so the recorder can
/// surface what happened the previous night — including the case where
/// Android killed the app and nothing called stop().
class SessionLogService {
  static const _key = 'snorelore_session_log_v1';

  SessionLogEntry? _cache;

  Future<SessionLogEntry?> load() async {
    if (_cache != null) return _cache;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      _cache = SessionLogEntry.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      return _cache;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(SessionLogEntry e) async {
    _cache = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(e.toJson()));
  }

  Future<void> markStart(DateTime startedAt) async {
    await _save(SessionLogEntry(startedAt: startedAt));
  }

  /// Record a chunk having arrived. Throttled by the caller — we
  /// don't want a disk write per sample.
  Future<void> markChunk(DateTime at, {int? segmentsCaptured}) async {
    final cur = await load();
    if (cur == null) return;
    await _save(cur.copyWith(
      lastChunkAt: at,
      segmentsCaptured: segmentsCaptured ?? cur.segmentsCaptured,
    ));
  }

  Future<void> markStop({
    required SessionStopReason reason,
    String? detail,
    int? segmentsCaptured,
  }) async {
    final cur = await load();
    if (cur == null) {
      await _save(SessionLogEntry(
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        stopReason: reason,
        stopDetail: detail,
        segmentsCaptured: segmentsCaptured ?? 0,
      ));
      return;
    }
    await _save(cur.copyWith(
      endedAt: DateTime.now(),
      stopReason: reason,
      stopDetail: detail,
      segmentsCaptured: segmentsCaptured ?? cur.segmentsCaptured,
    ));
  }

  Future<void> clear() async {
    _cache = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
