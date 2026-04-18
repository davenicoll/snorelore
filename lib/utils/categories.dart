import 'package:flutter/material.dart';
import 'theme.dart';

/// Simplified sound categories that SnoreLore cares about.
/// YAMNet's 521 raw labels get collapsed into these.
enum SoundCategory {
  snoring,
  breathing,
  cough,
  sneeze,
  passion,
  fart,
  speech,
  whisper,
  scream,
  laugh,
  cry,
  alarmClock,
  alarmHousehold,
  siren,
  phone,
  doorbell,
  cat,
  dog,
  traffic,
  weather,
  music,
  walking,
  movementBed,
  // Audibly nothing there — assigned when the segment's peak amplitude is
  // below the silence floor regardless of what YAMNet returns.
  silence,
  // Deprecated buckets retained for backward compatibility with recordings
  // that were classified before the taxonomy split. New classifications
  // never produce these.
  animal,
  alarm,
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
  SoundCategory.breathing: CategoryInfo('Breathing', Icons.air, AppColors.teal),
  SoundCategory.cough: CategoryInfo('Coughing', Icons.sick, AppColors.orange),
  SoundCategory.sneeze: CategoryInfo('Sneezing', Icons.masks, AppColors.orange),
  SoundCategory.passion: CategoryInfo('Passion', Icons.favorite, AppColors.pink),
  SoundCategory.fart: CategoryInfo('Fart', Icons.cloud, AppColors.teal),
  SoundCategory.speech: CategoryInfo('Speech', Icons.record_voice_over, AppColors.accent),
  SoundCategory.whisper: CategoryInfo('Whisper', Icons.hearing, AppColors.accent),
  SoundCategory.scream: CategoryInfo('Scream', Icons.priority_high, AppColors.red),
  SoundCategory.laugh: CategoryInfo('Laugh', Icons.mood, AppColors.pink),
  SoundCategory.cry: CategoryInfo('Cry', Icons.water_drop, AppColors.teal),
  SoundCategory.alarmClock: CategoryInfo('Alarm clock', Icons.alarm, AppColors.red),
  SoundCategory.alarmHousehold: CategoryInfo('Smoke alarm', Icons.warning_amber, AppColors.orange),
  SoundCategory.siren: CategoryInfo('Siren', Icons.emergency, AppColors.red),
  SoundCategory.phone: CategoryInfo('Phone', Icons.phone_android, AppColors.pink),
  SoundCategory.doorbell: CategoryInfo('Doorbell', Icons.doorbell, AppColors.orange),
  SoundCategory.cat: CategoryInfo('Cat', Icons.pets, AppColors.teal),
  SoundCategory.dog: CategoryInfo('Dog', Icons.pets, AppColors.primary),
  SoundCategory.traffic: CategoryInfo('Traffic', Icons.directions_car, AppColors.textMuted),
  SoundCategory.weather: CategoryInfo('Weather', Icons.cloud_queue, AppColors.textMuted),
  SoundCategory.music: CategoryInfo('Music', Icons.music_note, AppColors.accent),
  SoundCategory.walking: CategoryInfo('Footsteps', Icons.directions_walk, AppColors.textMuted),
  SoundCategory.movementBed: CategoryInfo('Bedding', Icons.hotel, AppColors.textMuted),
  SoundCategory.silence: CategoryInfo('Silence', Icons.volume_off, AppColors.textMuted),
  // Legacy — render sensibly for old records that haven't been re-analyzed.
  SoundCategory.animal: CategoryInfo('Pet', Icons.pets, AppColors.teal),
  SoundCategory.alarm: CategoryInfo('Alarm', Icons.notifications_active, AppColors.red),
  SoundCategory.movement: CategoryInfo('Movement', Icons.waves, AppColors.textMuted),
  SoundCategory.unknown: CategoryInfo('Other', Icons.graphic_eq, AppColors.textMuted),
};

/// Map a YAMNet display name (from class map) to one of our simplified categories.
///
/// YAMNet returns 521 raw labels (see assets/models/yamnet_class_map.csv).
/// Order matters — the first matching rule wins.
SoundCategory mapYamnetLabel(String name) {
  final n = name.toLowerCase().trim();

  // --- Farm/wild animals / birds: not plausible in a bedroom, so we file
  //     these under Other rather than letting them leak into the Pet bucket
  //     and dilute real cat/dog signals. This also prevents "Cattle" from
  //     substring-matching "cat".
  if (n == 'cattle, bovinae' ||
      n == 'moo' ||
      n == 'pig' ||
      n == 'oink' ||
      n == 'sheep' ||
      n == 'bleat' ||
      n == 'goat' ||
      n == 'horse' ||
      n == 'cluck' ||
      n == 'duck' ||
      n == 'chicken, rooster' ||
      n == 'crowing, cock-a-doodle-doo' ||
      n.contains('livestock') ||
      n.contains('wild animals') ||
      n.contains('roaring cats') ||
      n == 'roar' ||
      n.contains('rodent') ||
      n.contains('bird') ||
      n.contains('chirp') ||
      n.contains('pigeon') ||
      n.contains('crow') ||
      n.contains('owl')) {
    return SoundCategory.unknown;
  }

  // --- Human sleep sounds ---------------------------------------------------

  // Snoring — plus YAMNet's Grunt / Snort / Growling labels which in a
  // bedroom are near-always actually snoring rather than effort/dog noises.
  if (n.contains('snor') ||
      n == 'grunt' ||
      n == 'snort' ||
      n == 'growling') {
    return SoundCategory.snoring;
  }

  // Moaning / groaning — intimate vocalisations.
  if (n.contains('moan') || n.contains('groan')) return SoundCategory.passion;

  if (n.contains('sneez')) return SoundCategory.sneeze;

  if (n.contains('cough') || n.contains('throat')) return SoundCategory.cough;

  if (n == 'fart' ||
      n.contains('burping') ||
      n.contains('eructation') ||
      n == 'hiccup') {
    return SoundCategory.fart;
  }

  if (n.contains('laugh') ||
      n.contains('giggl') ||
      n.contains('chuckl') ||
      n.contains('chortl')) {
    return SoundCategory.laugh;
  }

  if (n.contains('screaming') ||
      n == 'shout' ||
      n == 'yell' ||
      n.contains('children shouting')) {
    return SoundCategory.scream;
  }

  if (n.contains('cry') ||
      n.contains('sob') ||
      n.contains('wail') ||
      n == 'whimper') {
    return SoundCategory.cry;
  }

  if (n.contains('whisper')) return SoundCategory.whisper;

  if (n == 'speech' ||
      n.contains('child speech') ||
      n.contains('kid speaking') ||
      n.contains('conversation') ||
      n.contains('narration') ||
      n.contains('babbl') ||
      n.contains('monolog')) {
    return SoundCategory.speech;
  }

  // --- Alarms (specific before generic) -------------------------------------
  if (n.contains('alarm clock')) return SoundCategory.alarmClock;
  if (n.contains('smoke detector') ||
      n.contains('smoke alarm') ||
      n.contains('fire alarm') ||
      n.contains('civil defense')) {
    return SoundCategory.alarmHousehold;
  }
  if (n.contains('police car') ||
      n.contains('ambulance') ||
      n.contains('fire engine') ||
      n.contains('fire truck') ||
      n.contains('emergency vehicle') ||
      n == 'siren') {
    return SoundCategory.siren;
  }
  // Generic alarm / beep / buzzer — treat as clock alarm since in a bedroom
  // that's overwhelmingly the source.
  if (n == 'alarm' ||
      n.contains('buzzer') ||
      n.contains('beep, bleep') ||
      n == 'beep' ||
      n == 'reversing beeps') {
    return SoundCategory.alarmClock;
  }

  // --- Communication devices ------------------------------------------------
  if (n.contains('telephone') ||
      n.contains('ringtone') ||
      n.contains('phone')) {
    return SoundCategory.phone;
  }
  if (n.contains('doorbell') || n.contains('knock')) {
    return SoundCategory.doorbell;
  }

  // --- Cat / Dog ------------------------------------------------------------
  if (n == 'cat' ||
      n == 'purr' ||
      n == 'meow' ||
      n == 'hiss' ||
      n == 'caterwaul') {
    return SoundCategory.cat;
  }
  if (n == 'dog' ||
      n == 'bark' ||
      n == 'howl' ||
      n.contains('whimper (dog)') ||
      n.contains('canidae') ||
      n == 'bow-wow' ||
      n == 'yip') {
    return SoundCategory.dog;
  }
  // Generic "Animal" / "Domestic animals, pets" don't commit to either —
  // leave as unknown so a more specific label wins when it also fires.
  if (n == 'animal' || n == 'domestic animals, pets') {
    return SoundCategory.unknown;
  }

  // --- Breathing ------------------------------------------------------------
  if (n.contains('breath') ||
      n.contains('gasp') ||
      n.contains('pant') ||
      n.contains('sigh')) {
    return SoundCategory.breathing;
  }

  // --- Music ----------------------------------------------------------------
  if (n.contains('music') ||
      n.contains('song') ||
      n.contains('singing') ||
      n.contains('guitar') ||
      n.contains('piano')) {
    return SoundCategory.music;
  }

  // --- Traffic --------------------------------------------------------------
  if (n.contains('traffic') ||
      n.contains('motor vehicle') ||
      n == 'car' ||
      n.contains('car passing') ||
      n.contains('truck') ||
      n.contains('motorcycle') ||
      n == 'vehicle' ||
      n.contains('vehicle horn') ||
      n.contains('car horn') ||
      n.contains('honking') ||
      n.contains('car alarm') ||
      n.contains('race car') ||
      n == 'train' ||
      n.contains('train whistle') ||
      n.contains('train horn') ||
      n.contains('train wheels') ||
      n.contains('railroad car') ||
      n.contains('air horn') ||
      n.contains('aircraft') ||
      n.contains('jet engine')) {
    return SoundCategory.traffic;
  }

  // --- Weather --------------------------------------------------------------
  if (n.contains('thunder') ||
      n == 'rain' ||
      n.contains('raindrop') ||
      n.contains('rain on surface') ||
      n == 'wind' ||
      n.contains('wind noise')) {
    return SoundCategory.weather;
  }

  // --- Movement -------------------------------------------------------------
  if (n.contains('walk, footsteps') ||
      n.contains('footstep') ||
      n == 'run' ||
      n == 'jogging') {
    return SoundCategory.walking;
  }
  if (n == 'rustle' ||
      n.contains('zipper') ||
      n.contains('sliding door') ||
      n == 'door' ||
      n.contains('cupboard open') ||
      n.contains('drawer open') ||
      n.contains('cloth') ||
      n.contains('creak') ||
      n.contains('squeak') ||
      n.contains('thump') ||
      n.contains('rumbl') ||
      n.contains('bed')) {
    return SoundCategory.movementBed;
  }

  return SoundCategory.unknown;
}

/// Bedroom/sleep prior. Multiplies YAMNet's raw category scores when
/// picking the primary category and when colouring segments. Higher values
/// favour categories we expect to see at night; lower values suppress
/// implausible ones so "Purr" can't beat "Snoring" on a noisy clip.
///
/// These are deliberately gentle multipliers (0.5–1.5) — they nudge
/// decisions at close margins without overriding strong YAMNet confidence.
const Map<SoundCategory, double> categoryPrior = {
  // Expected sleep sounds
  SoundCategory.snoring: 1.5,
  SoundCategory.breathing: 1.3,
  SoundCategory.movementBed: 1.3,
  SoundCategory.speech: 1.2,
  SoundCategory.whisper: 1.2,

  // Semi-common
  SoundCategory.cough: 1.1,
  SoundCategory.sneeze: 1.1,
  SoundCategory.passion: 1.0,
  SoundCategory.laugh: 1.0,
  SoundCategory.cry: 1.0,
  SoundCategory.fart: 1.0,
  SoundCategory.walking: 1.0,

  // Household pets — expected if user has them, but shouldn't steal primary
  // from stronger snoring signals.
  SoundCategory.cat: 0.9,
  SoundCategory.dog: 0.9,

  // Household alarms are rare but important when they fire.
  SoundCategory.alarmClock: 1.0,
  SoundCategory.alarmHousehold: 0.9,
  SoundCategory.phone: 0.8,
  SoundCategory.doorbell: 0.8,
  SoundCategory.siren: 0.6,

  // External background — suppressed so they only win on strong confidence.
  SoundCategory.traffic: 0.5,
  SoundCategory.weather: 0.5,
  SoundCategory.music: 0.5,
  SoundCategory.scream: 0.5,

  // Legacy buckets: leave neutral.
  SoundCategory.animal: 1.0,
  SoundCategory.alarm: 1.0,
  SoundCategory.movement: 1.0,
  SoundCategory.silence: 1.0,
  SoundCategory.unknown: 1.0,
};

/// How the classifier aggregates a category's score across the multiple
/// YAMNet inferences in one segment (and across the segments of a clip).
///
/// MAX: a single strong hit commits the category. Right for short, rare
///   events — sneeze, cough, fart, alarm, siren, doorbell — where one
///   frame of high confidence is all the evidence you get.
/// MEAN: averaged across frames. Right for sustained sounds — snoring,
///   breathing, speech, traffic — where a single noisy 0.9 frame shouldn't
///   tag the whole segment if the other 9 frames are 0.05.
enum CategoryAggregation { max, mean }

const Map<SoundCategory, CategoryAggregation> categoryAggregation = {
  // Events / transients
  SoundCategory.sneeze: CategoryAggregation.max,
  SoundCategory.cough: CategoryAggregation.max,
  SoundCategory.fart: CategoryAggregation.max,
  SoundCategory.scream: CategoryAggregation.max,
  SoundCategory.laugh: CategoryAggregation.max,
  SoundCategory.cry: CategoryAggregation.max,
  SoundCategory.passion: CategoryAggregation.max,
  SoundCategory.alarmClock: CategoryAggregation.max,
  SoundCategory.alarmHousehold: CategoryAggregation.max,
  SoundCategory.siren: CategoryAggregation.max,
  SoundCategory.phone: CategoryAggregation.max,
  SoundCategory.doorbell: CategoryAggregation.max,
  SoundCategory.cat: CategoryAggregation.max,
  SoundCategory.dog: CategoryAggregation.max,
  SoundCategory.walking: CategoryAggregation.max,
  // Sustained
  SoundCategory.snoring: CategoryAggregation.mean,
  SoundCategory.breathing: CategoryAggregation.mean,
  SoundCategory.speech: CategoryAggregation.mean,
  SoundCategory.whisper: CategoryAggregation.mean,
  SoundCategory.traffic: CategoryAggregation.mean,
  SoundCategory.weather: CategoryAggregation.mean,
  SoundCategory.music: CategoryAggregation.mean,
  SoundCategory.movementBed: CategoryAggregation.mean,
  // Legacy / meta
  SoundCategory.animal: CategoryAggregation.max,
  SoundCategory.alarm: CategoryAggregation.max,
  SoundCategory.movement: CategoryAggregation.mean,
  SoundCategory.silence: CategoryAggregation.mean,
  SoundCategory.unknown: CategoryAggregation.max,
};

/// Categories that represent short, acute events. The waveform smoother
/// never smooths one of these away: even a single 10 s segment of "Sneeze"
/// is informative and almost certainly genuine. Smoothing targets the
/// steady-state categories, where a lone outlier segment in the middle of
/// a long run is the common YAMNet mis-label.
const Set<SoundCategory> eventCategories = {
  SoundCategory.sneeze,
  SoundCategory.cough,
  SoundCategory.fart,
  SoundCategory.scream,
  SoundCategory.laugh,
  SoundCategory.cry,
  SoundCategory.passion,
  SoundCategory.alarmClock,
  SoundCategory.alarmHousehold,
  SoundCategory.siren,
  SoundCategory.phone,
  SoundCategory.doorbell,
};
