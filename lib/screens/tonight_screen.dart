import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_services.dart';
import '../models/app_settings.dart';
import '../services/audio_recorder_service.dart';
import '../services/fgs_bridge.dart';
import '../utils/theme.dart';

enum _BatteryChoice { skip, fix }

class TonightScreen extends StatefulWidget {
  const TonightScreen({super.key});

  @override
  State<TonightScreen> createState() => _TonightScreenState();
}

class _TonightScreenState extends State<TonightScreen>
    with TickerProviderStateMixin {
  AppSettings? _settings;
  late final AnimationController _pulse;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await AppServices.of(context).settings.load();
    if (mounted) setState(() => _settings = s);
  }

  Future<_BatteryChoice?> _showBatteryPrompt() {
    return showDialog<_BatteryChoice>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Let SnoreLore run overnight?'),
        content: const Text(
          'Android may pause SnoreLore while your screen is off, which would '
          'miss clips partway through the night. Allow it to run unrestricted?',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, _BatteryChoice.skip),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _BatteryChoice.fix),
            child: const Text('Allow',
                style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Future<bool> _ensureMicPermission() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) status = await Permission.microphone.request();
    if (!status.isGranted) return false;
    final notif = await Permission.notification.status;
    if (!notif.isGranted) await Permission.notification.request();
    return true;
  }

  Future<void> _toggle() async {
    final services = AppServices.of(context);
    final rec = services.recorder;
    final s = _settings ?? await services.settings.load();

    if (rec.isRunning) {
      await rec.stop();
      await WakelockPlus.disable();
      if (mounted) setState(() {});
      return;
    }

    final ok = await _ensureMicPermission();
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
      }
      return;
    }

    // Nudge the user to exempt us from battery optimization once, the first
    // time they start a session. Without this, Android can (and does) kill
    // the mic connection partway through the night.
    final exempt = await FgsBridge.isIgnoringBatteryOptimizations();
    if (!exempt && mounted) {
      final proceed = await _showBatteryPrompt();
      if (proceed == _BatteryChoice.fix) {
        await FgsBridge.requestIgnoreBatteryOptimizations();
        return; // user just left the app to grant it; let them retap Start
      }
    }

    DateTime? endsAt;
    final now = DateTime.now();
    if (s.autoSchedule) {
      var end = DateTime(now.year, now.month, now.day, s.endTime.hour, s.endTime.minute);
      if (!end.isAfter(now)) end = end.add(const Duration(days: 1));
      endsAt = end;
    }

    try {
      await rec.start(settings: s, endsAt: endsAt);
      await WakelockPlus.enable();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start: $e')),
        );
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rec = AppServices.of(context).recorder;
    final s = _settings;
    return StreamBuilder<SessionStatus>(
      stream: rec.status$,
      initialData: rec.status,
      builder: (context, snap) {
        final st = snap.data ?? SessionStatus.idle;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _statusCard(st, s),
            const SizedBox(height: 16),
            Center(child: _startButton(rec.isRunning, st)),
            const SizedBox(height: 24),
            _metricsCard(st),
            const SizedBox(height: 16),
            _tipCard(s),
          ],
        );
      },
    );
  }

  Widget _statusCard(SessionStatus st, AppSettings? s) {
    String title;
    String subtitle;
    Color accent;
    IconData icon;
    switch (st.phase) {
      case RecorderPhase.idle:
        title = 'Ready to sleep';
        subtitle = s?.autoSchedule == true
            ? 'Auto-schedule is on. Tap start to begin tonight.'
            : 'Tap start when you\'re settling in.';
        accent = AppColors.primary;
        icon = Icons.nightlight_round;
        break;
      case RecorderPhase.listening:
        if (st.ignoreWindow) {
          final r = st.remainingIgnore ?? Duration.zero;
          final mm = r.inMinutes.toString();
          final ss = (r.inSeconds % 60).toString().padLeft(2, '0');
          title = 'Drifting off…';
          subtitle = 'Ignoring sounds for another $mm:$ss';
        } else {
          title = 'Listening';
          subtitle = 'Will capture when something stirs';
        }
        accent = AppColors.teal;
        icon = Icons.hearing;
        break;
      case RecorderPhase.capturing:
        title = 'Capturing now';
        subtitle = '${st.lastAmplitudeDb.toStringAsFixed(0)} dB';
        accent = AppColors.accent;
        icon = Icons.fiber_manual_record;
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.2 + 0.15 * _pulse.value),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: accent, size: 28),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _startButton(bool running, SessionStatus st) {
    return GestureDetector(
      onTap: _toggle,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) {
          final scale = running ? 1 + 0.04 * _pulse.value : 1.0;
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: running
                      ? const [AppColors.pink, AppColors.orange]
                      : const [AppColors.primary, AppColors.teal],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (running ? AppColors.pink : AppColors.primary)
                        .withValues(alpha: 0.4),
                    blurRadius: 22,
                    spreadRadius: 2,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                running ? 'STOP' : 'START',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _metricsCard(SessionStatus st) {
    final started = st.sessionStartedAt;
    final elapsed = started == null
        ? Duration.zero
        : DateTime.now().difference(started);
    final hh = elapsed.inHours.toString().padLeft(2, '0');
    final mm = (elapsed.inMinutes % 60).toString().padLeft(2, '0');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _metric('Session', '$hh:$mm'),
            _metric('Clips', st.segmentsCaptured.toString()),
            _metric(
              'Level',
              st.lastAmplitudeDb > -95
                  ? '${st.lastAmplitudeDb.toStringAsFixed(0)} dB'
                  : '—',
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label.toUpperCase(),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                letterSpacing: 1.2,
              )),
        ],
      );

  Widget _tipCard(AppSettings? s) {
    if (s == null) return const SizedBox.shrink();
    return Card(
      color: AppColors.surface.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline,
                size: 18, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Ignoring sounds for the first ${s.ignoreFirstMinutes} min, '
                'then capturing when the level crosses '
                '${s.amplitudeThresholdDb.toStringAsFixed(0)} dB. '
                'Each clip includes ${s.preRollSeconds}s before the noise and '
                'keeps recording for ${s.postRollSeconds}s after the last loud '
                'sound, capped at ${s.maxSegmentSeconds}s.',
                style: const TextStyle(
                    color: AppColors.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
