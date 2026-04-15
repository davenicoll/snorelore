import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/app_settings.dart';
import '../utils/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings? _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AppServices.of(context).settings.load();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _save(AppSettings s) async {
    setState(() => _settings = s);
    await AppServices.of(context).settings.save(s);
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
                title: 'Cooldown',
                value: s.cooldownSeconds.toDouble(),
                min: 10,
                max: 180,
                divisions: 17,
                valueLabel: '${s.cooldownSeconds}s',
                onChanged: (v) =>
                    _save(s.copyWith(cooldownSeconds: v.round())),
                help: 'Quiet window after each clip',
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
        const SizedBox(height: 28),
        Center(
          child: Text(
            'SnoreLore · v0.1',
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.7),
              fontSize: 12,
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
