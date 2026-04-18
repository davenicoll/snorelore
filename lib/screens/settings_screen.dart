import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_services.dart';
import '../models/app_settings.dart';
import '../services/fgs_bridge.dart';
import '../utils/categories.dart';
import '../utils/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings? _settings;
  bool _batteryExempt = false;
  String _versionLabel = '';
  int _versionTaps = 0;
  DateTime? _lastVersionTap;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = AppServices.of(context);
    final s = await svc.settings.load();
    final b = await FgsBridge.isIgnoringBatteryOptimizations();
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _settings = s;
        _batteryExempt = b;
        _versionLabel = 'SnoreLore · v${info.version}';
      });
    }
  }

  Future<void> _save(AppSettings s) async {
    setState(() => _settings = s);
    final svc = AppServices.of(context);
    await svc.settings.save(s);
    // Apply immediately so changes take effect mid-session.
    svc.recorder.updateSettings(s);
  }

  void _onVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTap != null &&
        now.difference(_lastVersionTap!) > const Duration(seconds: 2)) {
      _versionTaps = 0;
    }
    _lastVersionTap = now;
    _versionTaps++;

    final s = _settings;
    if (s == null) return;

    if (!s.developerMode && _versionTaps >= 10) {
      _versionTaps = 0;
      _save(s.copyWith(developerMode: true));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer mode enabled')),
      );
    } else if (s.developerMode && _versionTaps >= 10) {
      _versionTaps = 0;
      _save(s.copyWith(developerMode: false));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Developer mode disabled')),
      );
    }
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) {
    return showTimePicker(
      context: context,
      initialTime: initial,
      builder: (ctx, child) => Theme(
        data: Theme.of(context).copyWith(
          timePickerTheme: TimePickerThemeData(
            backgroundColor: AppColors.surface,
            hourMinuteColor: AppColors.surfaceAlt,
            dayPeriodColor: AppColors.surfaceAlt,
            dialBackgroundColor: AppColors.surfaceAlt,
          ),
        ),
        child: child!,
      ),
    );
  }

  String _fmt(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final m = t.minute.toString().padLeft(2, '0');
    final p = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '$h:$m $p';
  }

  Future<void> _reanalyzeAll() async {
    final svc = AppServices.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final all = await svc.storage.loadAll();
    if (!mounted) return;
    if (all.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No recordings to re-analyze')),
      );
      return;
    }

    final progress = ValueNotifier<int>(0);
    final total = all.length;
    bool cancelled = false;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Re-analyzing'),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$v / $total',
                style: const TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: total == 0 ? 0 : v / total,
                backgroundColor: AppColors.surfaceAlt,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.of(context).pop();
            },
            child: const Text('Stop'),
          ),
        ],
      ),
    );

    for (var i = 0; i < all.length; i++) {
      if (cancelled) break;
      final r = all[i];
      try {
        final result = await svc.classifier.classifyWavFile(r.filePath);
        if (result != null) {
          final updated = r.copyWith(
            category: result.primary.category,
            categoryLabel: result.primary.label,
            categoryConfidence: result.primary.confidence,
            tags: result.tags.map((t) => t.category).toList(),
            windowCategories: result.windowCategories,
          );
          await svc.storage.update(updated);
        }
      } catch (_) {}
      progress.value = i + 1;
    }

    if (mounted && !cancelled) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          cancelled
              ? 'Re-analysis stopped at ${progress.value} / $total'
              : 'Re-analyzed $total recordings',
        ),
      ),
    );
  }

  Future<void> _clearClassifications() async {
    final svc = AppServices.of(context);
    final all = await svc.storage.loadAll();
    if (all.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recordings to clear')),
      );
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear all classifications?'),
        content: Text(
          'Resets category, tags and waveform colouring on all '
          '${all.length} clips. Recordings themselves are not deleted. '
          'You can re-run classification afterwards.',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear',
                style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final wiped = all
        .map((r) => r.copyWith(
              category: SoundCategory.unknown,
              categoryLabel: 'Other',
              categoryConfidence: 0,
              tags: const [],
              windowCategories: const [],
            ))
        .toList();
    await svc.storage.replaceAll(wiped);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared classifications on ${wiped.length} clips')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    if (s == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _sectionTitle('Schedule'),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Auto-schedule nightly'),
                subtitle: const Text(
                  'Start and stop at set times every day',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                value: s.autoSchedule,
                onChanged: (v) => _save(s.copyWith(autoSchedule: v)),
              ),
              const Divider(height: 1),
              ListTile(
                enabled: s.autoSchedule,
                title: const Text('Start'),
                trailing: Text(
                  _fmt(s.startTime),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () async {
                  final t = await _pickTime(s.startTime);
                  if (t != null) _save(s.copyWith(startTime: t));
                },
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text('Stop'),
                trailing: Text(
                  _fmt(s.endTime),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () async {
                  final t = await _pickTime(s.endTime);
                  if (t != null) _save(s.copyWith(endTime: t));
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('Recording'),
        Card(
          child: Column(
            children: [
              _slider(
                title: 'Ignore first',
                value: s.ignoreFirstMinutes.toDouble(),
                min: 0,
                max: 60,
                divisions: 60,
                valueLabel: '${s.ignoreFirstMinutes} min',
                onChanged: (v) =>
                    _save(s.copyWith(ignoreFirstMinutes: v.round())),
                help: 'Wait this long after starting before capturing anything',
              ),
              const Divider(height: 1),
              _slider(
                title: 'Sensitivity',
                value: s.sensitivity,
                min: 0,
                max: 1,
                divisions: 10,
                valueLabel: '${(s.sensitivity * 100).round()}%',
                onChanged: (v) => _save(s.copyWith(sensitivity: v)),
                help: 'Higher captures quieter sounds',
              ),
              const Divider(height: 1),
              _slider(
                title: 'Pre-roll',
                value: s.preRollSeconds.toDouble(),
                min: 0,
                max: 10,
                divisions: 10,
                valueLabel: '${s.preRollSeconds}s',
                onChanged: (v) =>
                    _save(s.copyWith(preRollSeconds: v.round())),
                help: 'Capture this many seconds of audio before the trigger',
              ),
              const Divider(height: 1),
              _slider(
                title: 'Keep recording after noise',
                value: s.postRollSeconds.toDouble(),
                min: 5,
                max: 180,
                divisions: 35,
                valueLabel: '${s.postRollSeconds}s',
                onChanged: (v) =>
                    _save(s.copyWith(postRollSeconds: v.round())),
                help: 'How long to keep recording after the last loud sound',
              ),
              const Divider(height: 1),
              _slider(
                title: 'Max clip length',
                value: s.maxSegmentSeconds.toDouble(),
                min: 10,
                max: 300,
                divisions: 29,
                valueLabel: '${s.maxSegmentSeconds}s',
                onChanged: (v) =>
                    _save(s.copyWith(maxSegmentSeconds: v.round())),
                help: 'Stop capturing after this many seconds',
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('Background'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  _batteryExempt ? Icons.check_circle : Icons.battery_alert,
                  color: _batteryExempt ? AppColors.teal : AppColors.orange,
                ),
                title: const Text('Battery optimization'),
                subtitle: Text(
                  _batteryExempt
                      ? 'SnoreLore is allowed to run unrestricted'
                      : 'Android may kill SnoreLore mid-night. Tap to allow it to run unrestricted.',
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12),
                ),
                trailing: _batteryExempt
                    ? null
                    : const Icon(Icons.chevron_right,
                        color: AppColors.textMuted),
                onTap: _batteryExempt
                    ? null
                    : () async {
                        await FgsBridge.requestIgnoreBatteryOptimizations();
                        // Recheck after returning from the system prompt.
                        await Future.delayed(const Duration(seconds: 1));
                        await _load();
                      },
              ),
            ],
          ),
        ),
        if (s.developerMode) ...[
          const SizedBox(height: 20),
          _sectionTitle('Developer'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.refresh, color: AppColors.primary),
                  title: const Text('Re-analyze all recordings'),
                  subtitle: const Text(
                    'Re-run classification on every saved clip',
                    style:
                        TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppColors.textMuted),
                  onTap: _reanalyzeAll,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined,
                      color: AppColors.red),
                  title: const Text('Clear all classifications'),
                  subtitle: const Text(
                    'Reset every clip to Other and strip waveform colouring',
                    style:
                        TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppColors.textMuted),
                  onTap: _clearClassifications,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 28),
        Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onVersionTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 8),
              child: Text(
                _versionLabel.isEmpty ? 'SnoreLore' : _versionLabel,
                style: TextStyle(
                  color: AppColors.textMuted.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: AppColors.textMuted,
          ),
        ),
      );

  Widget _slider({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    required String help,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                valueLabel,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              thumbColor: AppColors.accent,
              inactiveTrackColor: AppColors.surfaceAlt,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          Text(
            help,
            style:
                const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
