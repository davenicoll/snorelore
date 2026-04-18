import 'package:flutter/material.dart';
import 'theme.dart';

/// Simplified sound categories that SnoreLore cares about.
/// YAMNet labels get collapsed into these.
enum SoundCategory {
  snoring,
  passion,
  cough,
  speech,
  laugh,
  cry,
  alarm,
  phone,
  doorbell,
  animal,
  music,
  breathing,
  movement,
  unknown,
}

class CategoryInfo {
  final String label;
  final IconData icon;
  final Color color;
  const CategoryInfo(this.label, this.icon, this.color);
}

const Map<SoundCategory, CategoryInfo> categoryInfo = {
  SoundCategory.snoring: CategoryInfo('Snoring', Icons.bedtime, AppColors.primary),
  SoundCategory.passion: CategoryInfo('Passion', Icons.favorite, AppColors.pink),
  SoundCategory.cough: CategoryInfo('Coughing', Icons.sick, AppColors.orange),
  SoundCategory.speech: CategoryInfo('Speech', Icons.record_voice_over, AppColors.accent),
  SoundCategory.laugh: CategoryInfo('Laugh', Icons.mood, AppColors.pink),
  SoundCategory.cry: CategoryInfo('Cry', Icons.water_drop, AppColors.teal),
  SoundCategory.alarm: CategoryInfo('Alarm', Icons.notifications_active, AppColors.red),
  SoundCategory.phone: CategoryInfo('Phone', Icons.phone_android, AppColors.pink),
  SoundCategory.doorbell: CategoryInfo('Doorbell', Icons.doorbell, AppColors.orange),
  SoundCategory.animal: CategoryInfo('Pet', Icons.pets, AppColors.teal),
  SoundCategory.music: CategoryInfo('Music', Icons.music_note, AppColors.accent),
  SoundCategory.breathing: CategoryInfo('Breathing', Icons.air, AppColors.teal),
  SoundCategory.movement: CategoryInfo('Movement', Icons.waves, AppColors.textMuted),
  SoundCategory.unknown: CategoryInfo('Other', Icons.graphic_eq, AppColors.textMuted),
};

/// Map a YAMNet display name (from class map) to one of our simplified categories.
///
/// YAMNet returns 521 raw labels (see assets/models/yamnet_class_map.csv).
/// Tuning the app's category assignments mostly means editing the keyword
/// matches below — add, reorder or narrow them to taste.
SoundCategory mapYamnetLabel(String name) {
  final n = name.toLowerCase();
  if (n.contains('snor') || n.contains('snort')) return SoundCategory.snoring;
  // Moan/Wail/Groan → passion. YAMNet can't tell us how many people are in
  // the room, so we take these intimate vocalisations as the strongest
  // signal available.
  if (n.contains('moan') || n.contains('groan')) return SoundCategory.passion;
  if (n.contains('cough') || n.contains('throat')) return SoundCategory.cough;
  if (n.contains('sneez')) return SoundCategory.cough;
  if (n.contains('laugh') || n.contains('giggl') || n.contains('chuckl') || n.contains('chortl')) {
    return SoundCategory.laugh;
  }
  if (n.contains('cry') || n.contains('sob') || n.contains('wail') || n.contains('whimper')) {
    return SoundCategory.cry;
  }
  if (n.contains('alarm') || n.contains('beep') || n.contains('buzzer') || n.contains('siren')) {
    return SoundCategory.alarm;
  }
  if (n.contains('telephone') || n.contains('ringtone') || n.contains('phone')) {
    return SoundCategory.phone;
  }
  if (n.contains('doorbell') || n.contains('door') || n.contains('knock')) {
    return SoundCategory.doorbell;
  }
  if (n.contains('breath') || n.contains('gasp') || n.contains('pant') || n.contains('sigh')) {
    return SoundCategory.breathing;
  }
  if (n.contains('speech') || n.contains('conversation') || n.contains('narration') ||
      n.contains('whisper') || n.contains('babbl') || n.contains('monolog')) {
    return SoundCategory.speech;
  }
  if (n.contains('dog') || n.contains('cat') || n.contains('bark') || n.contains('meow') ||
      n.contains('purr') || n.contains('bird') || n.contains('animal') || n.contains('yowl')) {
    return SoundCategory.animal;
  }
  if (n.contains('music') || n.contains('song') || n.contains('singing') || n.contains('guitar') ||
      n.contains('piano')) {
    return SoundCategory.music;
  }
  if (n.contains('rustl') || n.contains('creak') || n.contains('squeak') || n.contains('thump') ||
      n.contains('rumbl') || n.contains('bed') || n.contains('footstep')) {
    return SoundCategory.movement;
  }
  return SoundCategory.unknown;
}

/// When several YAMNet classes score close together, prefer the ones we care
/// most about for a sleep journal. e.g. if "Cat purring" wins 0.32 and
/// "Snoring" comes in second at 0.25, we'd rather label the clip as snoring.
const List<SoundCategory> categoryPriority = [
  SoundCategory.snoring,
  SoundCategory.passion,
  SoundCategory.cough,
  SoundCategory.cry,
  SoundCategory.laugh,
  SoundCategory.speech,
  SoundCategory.alarm,
  SoundCategory.phone,
  SoundCategory.doorbell,
  SoundCategory.breathing,
  SoundCategory.music,
  SoundCategory.animal,
  SoundCategory.movement,
  SoundCategory.unknown,
];
