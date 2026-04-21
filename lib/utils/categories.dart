import 'package:flutter/material.dart';
import 'theme.dart';

/// Simplified sound categories. In v0.14.1 we collapsed down to six
/// product categories that map 1:1 with [DisplayCategory] — Sleep Talk
/// Recorder's simple 4-category taxonomy informed this, but we keep
/// pets and music split because the UX calls for them.
///
/// Classifier outputs are limited to these values. Legacy values
/// (speech, cough, cat, …) are retained so recordings classified in
/// earlier versions still decode and render correctly, but new
/// classifications never produce them.
enum SoundCategory {
  // Active categories produced by the classifier.
  talking,
  snoring,
  events,
  pets,
  music,

  // Meta / gating.
  silence, // amplitude gate result
  unknown, // no category crossed threshold

  // --- Legacy values (pre-v0.14.1) ---------------------------------------
  // Kept so that already-stored recordings decode correctly. Each folds
  // into one of the active categories via [displayCategoryOf]. New
  // classifications never produce these.
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
  walking,
  movementBed,
  animal,
  alarm,
  movement,
}

class CategoryInfo {
  final String label;
  final IconData icon;
  final Color color;
  const CategoryInfo(this.label, this.icon, this.color);
}

/// Per-category display metadata. Active categories use their own info;
/// legacy categories render with the info of the active category they
/// fold into (so a legacy `cat` recording shows under Pets).
const Map<SoundCategory, CategoryInfo> categoryInfo = {
  SoundCategory.talking:
      CategoryInfo('Talking', Icons.record_voice_over, AppColors.accent),
  SoundCategory.snoring:
      CategoryInfo('Snoring', Icons.bedtime, AppColors.primary),
  SoundCategory.events:
      CategoryInfo('Events', Icons.flash_on, AppColors.orange),
  SoundCategory.pets: CategoryInfo('Pets', Icons.pets, AppColors.amber),
  SoundCategory.music: CategoryInfo('Music', Icons.music_note, AppColors.cyan),
  SoundCategory.silence:
      CategoryInfo('Silence', Icons.volume_off, AppColors.textMuted),
  SoundCategory.unknown:
      CategoryInfo('Other', Icons.graphic_eq, AppColors.textMuted),

  // Legacy — use the display label of the folded-into active category.
  SoundCategory.speech:
      CategoryInfo('Talking', Icons.record_voice_over, AppColors.accent),
  SoundCategory.whisper:
      CategoryInfo('Talking', Icons.hearing, AppColors.accent),
  SoundCategory.cough:
      CategoryInfo('Events', Icons.sick, AppColors.orange),
  SoundCategory.sneeze:
      CategoryInfo('Events', Icons.masks, AppColors.orange),
  SoundCategory.fart: CategoryInfo('Events', Icons.cloud, AppColors.orange),
  SoundCategory.passion:
      CategoryInfo('Events', Icons.favorite, AppColors.orange),
  SoundCategory.laugh: CategoryInfo('Events', Icons.mood, AppColors.orange),
  SoundCategory.cry:
      CategoryInfo('Events', Icons.water_drop, AppColors.orange),
  SoundCategory.scream:
      CategoryInfo('Events', Icons.priority_high, AppColors.orange),
  SoundCategory.alarmClock:
      CategoryInfo('Events', Icons.alarm, AppColors.orange),
  SoundCategory.alarmHousehold:
      CategoryInfo('Events', Icons.warning_amber, AppColors.orange),
  SoundCategory.siren:
      CategoryInfo('Events', Icons.emergency, AppColors.orange),
  SoundCategory.phone:
      CategoryInfo('Events', Icons.phone_android, AppColors.orange),
  SoundCategory.doorbell:
      CategoryInfo('Events', Icons.doorbell, AppColors.orange),
  SoundCategory.cat: CategoryInfo('Pets', Icons.pets, AppColors.amber),
  SoundCategory.dog: CategoryInfo('Pets', Icons.pets, AppColors.amber),
  SoundCategory.animal: CategoryInfo('Pets', Icons.pets, AppColors.amber),
  SoundCategory.alarm:
      CategoryInfo('Events', Icons.notifications_active, AppColors.orange),
  SoundCategory.breathing:
      CategoryInfo('Other', Icons.air, AppColors.textMuted),
  SoundCategory.traffic:
      CategoryInfo('Other', Icons.directions_car, AppColors.textMuted),
  SoundCategory.weather:
      CategoryInfo('Other', Icons.cloud_queue, AppColors.textMuted),
  SoundCategory.walking:
      CategoryInfo('Other', Icons.directions_walk, AppColors.textMuted),
  SoundCategory.movementBed:
      CategoryInfo('Other', Icons.hotel, AppColors.textMuted),
  SoundCategory.movement:
      CategoryInfo('Other', Icons.waves, AppColors.textMuted),
};

/// Map a YAMNet display name to one of the six active categories.
///
/// Ordering matters — the first matching rule wins. Farm/wild animal /
/// bird labels and the generic Animal/Domestic-animals parents are
/// excluded because a bedroom classifier shouldn't emit them; they
/// fall through to unknown.
///
/// Breathing-family labels (Breathing / Gasp / Pant / Sigh / Sniff)
/// are already denied at inference time so they never reach this
/// mapping.
SoundCategory mapYamnetLabel(String name) {
  final n = name.toLowerCase().trim();

  // Exclude farm / wild / bird labels — never produced for bedroom audio.
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

  // Snoring-family: YAMNet's Grunt / Snort / Growling all read as snores
  // in an overnight bedroom recording.
  if (n.contains('snor') ||
      n == 'grunt' ||
      n == 'snort' ||
      n == 'growling') {
    return SoundCategory.snoring;
  }

  // Events: short/loud/transient sounds. One broad bucket so YAMNet's
  // close-scoring neighbours (sneeze/cough, cry/scream, alarm variants)
  // can't fight each other for the argmax.
  if (n.contains('sneez') ||
      n.contains('cough') ||
      n.contains('throat')) {
    return SoundCategory.events;
  }
  if (n == 'fart' ||
      n.contains('burping') ||
      n.contains('eructation') ||
      n == 'hiccup') {
    return SoundCategory.events;
  }
  if (n.contains('laugh') ||
      n.contains('giggl') ||
      n.contains('chuckl') ||
      n.contains('chortl')) {
    return SoundCategory.events;
  }
  if (n.contains('screaming') ||
      n == 'shout' ||
      n == 'yell' ||
      n.contains('children shouting')) {
    return SoundCategory.events;
  }
  if (n.contains('cry') ||
      n.contains('sob') ||
      n.contains('wail') ||
      n == 'whimper') {
    return SoundCategory.events;
  }
  if (n.contains('moan') || n.contains('groan')) {
    return SoundCategory.events;
  }
  if (n.contains('alarm') ||
      n.contains('buzzer') ||
      n.contains('beep, bleep') ||
      n == 'beep' ||
      n == 'reversing beeps' ||
      n.contains('smoke detector') ||
      n.contains('smoke alarm') ||
      n.contains('fire alarm') ||
      n.contains('civil defense') ||
      n.contains('police car') ||
      n.contains('ambulance') ||
      n.contains('fire engine') ||
      n.contains('fire truck') ||
      n.contains('emergency vehicle') ||
      n == 'siren') {
    return SoundCategory.events;
  }
  if (n.contains('telephone') ||
      n.contains('ringtone') ||
      n.contains('phone')) {
    return SoundCategory.events;
  }
  if (n.contains('doorbell') || n.contains('knock')) {
    return SoundCategory.events;
  }

  // Talking: conversational speech including whispering.
  if (n.contains('whisper')) return SoundCategory.talking;
  if (n == 'speech' ||
      n.contains('child speech') ||
      n.contains('kid speaking') ||
      n.contains('conversation') ||
      n.contains('narration') ||
      n.contains('babbl') ||
      n.contains('monolog')) {
    return SoundCategory.talking;
  }

  // Pets: cat and dog variants.
  if (n == 'cat' ||
      n == 'purr' ||
      n == 'meow' ||
      n == 'hiss' ||
      n == 'caterwaul') {
    return SoundCategory.pets;
  }
  if (n == 'dog' ||
      n == 'bark' ||
      n == 'howl' ||
      n.contains('whimper (dog)') ||
      n.contains('canidae') ||
      n == 'bow-wow' ||
      n == 'yip') {
    return SoundCategory.pets;
  }
  // Generic "Animal" / "Domestic animals, pets" umbrellas — ambiguous,
  // file as unknown so a more specific child label wins when it fires.
  if (n == 'animal' || n == 'domestic animals, pets') {
    return SoundCategory.unknown;
  }

  // Music.
  if (n.contains('music') ||
      n.contains('song') ||
      n.contains('singing') ||
      n.contains('guitar') ||
      n.contains('piano')) {
    return SoundCategory.music;
  }

  // Everything else — traffic, weather, movement, rustle, breathing
  // (already denied), etc. — is "unknown" rather than a specific
  // category. The v0.13.1 denylist already strips the noisy attractors.
  return SoundCategory.unknown;
}

/// Bedroom/sleep prior for the collapsed taxonomy. Gentler than the
/// pre-v0.13.1 0.5–1.5 range because the 5× gain boost (v0.13.0) makes
/// absolute score differences larger.
const Map<SoundCategory, double> categoryPrior = {
  SoundCategory.snoring: 1.3,
  SoundCategory.talking: 1.0, // over-fires on ambient, keep neutral
  SoundCategory.events: 1.0,
  SoundCategory.pets: 0.9, // plausible but don't steal primary from snoring
  SoundCategory.music: 0.75, // external, suppressed
  SoundCategory.silence: 1.0,
  SoundCategory.unknown: 1.0,
  // Legacy — unused by new classifier, but keep map total so ??1.0
  // fallback stays consistent.
  SoundCategory.speech: 1.0,
  SoundCategory.whisper: 1.0,
  SoundCategory.breathing: 1.0,
  SoundCategory.cough: 1.0,
  SoundCategory.sneeze: 1.0,
  SoundCategory.fart: 1.0,
  SoundCategory.passion: 1.0,
  SoundCategory.laugh: 1.0,
  SoundCategory.cry: 1.0,
  SoundCategory.scream: 1.0,
  SoundCategory.alarmClock: 1.0,
  SoundCategory.alarmHousehold: 1.0,
  SoundCategory.siren: 1.0,
  SoundCategory.phone: 1.0,
  SoundCategory.doorbell: 1.0,
  SoundCategory.cat: 0.9,
  SoundCategory.dog: 0.9,
  SoundCategory.traffic: 1.0,
  SoundCategory.weather: 1.0,
  SoundCategory.walking: 1.0,
  SoundCategory.movementBed: 1.0,
  SoundCategory.animal: 0.9,
  SoundCategory.alarm: 1.0,
  SoundCategory.movement: 1.0,
};

/// Per-category aggregation mode across YAMNet inferences.
///   MAX: single strong hit commits (events)
///   MEAN: averaged across frames (sustained)
enum CategoryAggregation { max, mean }

const Map<SoundCategory, CategoryAggregation> categoryAggregation = {
  SoundCategory.snoring: CategoryAggregation.mean,
  // Silero produces high-confidence scores (≥0.5) on any voice band.
  // MAX aggregation at the clip level means a single strong voice band
  // commits the clip primary to Talking — matches the product intent
  // for a sleep-talking capture app.
  SoundCategory.talking: CategoryAggregation.max,
  SoundCategory.events: CategoryAggregation.max,
  SoundCategory.pets: CategoryAggregation.max,
  SoundCategory.music: CategoryAggregation.mean,
  SoundCategory.silence: CategoryAggregation.mean,
  SoundCategory.unknown: CategoryAggregation.max,
  // Legacy fallback
  SoundCategory.speech: CategoryAggregation.mean,
  SoundCategory.whisper: CategoryAggregation.mean,
  SoundCategory.breathing: CategoryAggregation.mean,
  SoundCategory.cough: CategoryAggregation.max,
  SoundCategory.sneeze: CategoryAggregation.max,
  SoundCategory.fart: CategoryAggregation.max,
  SoundCategory.passion: CategoryAggregation.max,
  SoundCategory.laugh: CategoryAggregation.max,
  SoundCategory.cry: CategoryAggregation.max,
  SoundCategory.scream: CategoryAggregation.max,
  SoundCategory.alarmClock: CategoryAggregation.max,
  SoundCategory.alarmHousehold: CategoryAggregation.max,
  SoundCategory.siren: CategoryAggregation.max,
  SoundCategory.phone: CategoryAggregation.max,
  SoundCategory.doorbell: CategoryAggregation.max,
  SoundCategory.cat: CategoryAggregation.max,
  SoundCategory.dog: CategoryAggregation.max,
  SoundCategory.traffic: CategoryAggregation.mean,
  SoundCategory.weather: CategoryAggregation.mean,
  SoundCategory.walking: CategoryAggregation.max,
  SoundCategory.movementBed: CategoryAggregation.mean,
  SoundCategory.animal: CategoryAggregation.max,
  SoundCategory.alarm: CategoryAggregation.max,
  SoundCategory.movement: CategoryAggregation.mean,
};

/// Categories that represent short, acute events. The waveform smoother
/// never rewrites them, so a genuine 1-band event stays visible.
const Set<SoundCategory> eventCategories = {
  SoundCategory.events,
  SoundCategory.pets, // bark / meow are punctate
  // Legacy fallback
  SoundCategory.cough,
  SoundCategory.sneeze,
  SoundCategory.fart,
  SoundCategory.laugh,
  SoundCategory.cry,
  SoundCategory.scream,
  SoundCategory.passion,
  SoundCategory.alarmClock,
  SoundCategory.alarmHousehold,
  SoundCategory.siren,
  SoundCategory.phone,
  SoundCategory.doorbell,
};

/// Per-category commit threshold for the per-band argmax. Calibrated
/// for v0.13.0's 5× gain boost — typical post-gain scores land in
/// 0.25–0.5 for confident classifications.
const Map<SoundCategory, double> categoryCommitThreshold = {
  SoundCategory.snoring: 0.15,
  SoundCategory.talking: 0.25,
  SoundCategory.events: 0.25,
  SoundCategory.pets: 0.25,
  SoundCategory.music: 0.25,
  SoundCategory.silence: 1.0, // never committed via argmax
  SoundCategory.unknown: 1.0,
  // Legacy fallback thresholds (no new classification produces these).
  SoundCategory.speech: 0.25,
  SoundCategory.whisper: 0.15,
  SoundCategory.breathing: 0.10,
  SoundCategory.cough: 0.25,
  SoundCategory.sneeze: 0.30,
  SoundCategory.fart: 0.30,
  SoundCategory.passion: 0.25,
  SoundCategory.laugh: 0.25,
  SoundCategory.cry: 0.25,
  SoundCategory.scream: 0.30,
  SoundCategory.alarmClock: 0.30,
  SoundCategory.alarmHousehold: 0.35,
  SoundCategory.siren: 0.35,
  SoundCategory.phone: 0.30,
  SoundCategory.doorbell: 0.30,
  SoundCategory.cat: 0.25,
  SoundCategory.dog: 0.25,
  SoundCategory.traffic: 0.20,
  SoundCategory.weather: 0.25,
  SoundCategory.walking: 0.20,
  SoundCategory.movementBed: 0.15,
  SoundCategory.animal: 0.25,
  SoundCategory.alarm: 0.30,
  SoundCategory.movement: 0.15,
};

/// Per-category median-filter length (in bands) applied to the per-band
/// score time series. Events use length 1 (no smoothing — a 1-band
/// event must survive); sustained categories use longer windows.
const Map<SoundCategory, int> categoryMedianLen = {
  SoundCategory.snoring: 5,
  SoundCategory.talking: 1, // DCASE uses 1 for Speech
  SoundCategory.events: 1, // punctate — never smooth
  SoundCategory.pets: 3,
  SoundCategory.music: 5,
  SoundCategory.silence: 1,
  SoundCategory.unknown: 1,
  // Legacy fallback (unused by new classifier)
  SoundCategory.speech: 1,
  SoundCategory.whisper: 1,
  SoundCategory.breathing: 5,
  SoundCategory.cough: 1,
  SoundCategory.sneeze: 1,
  SoundCategory.fart: 1,
  SoundCategory.passion: 3,
  SoundCategory.laugh: 1,
  SoundCategory.cry: 3,
  SoundCategory.scream: 1,
  SoundCategory.alarmClock: 1,
  SoundCategory.alarmHousehold: 1,
  SoundCategory.siren: 3,
  SoundCategory.phone: 1,
  SoundCategory.doorbell: 1,
  SoundCategory.cat: 3,
  SoundCategory.dog: 3,
  SoundCategory.traffic: 5,
  SoundCategory.weather: 5,
  SoundCategory.walking: 3,
  SoundCategory.movementBed: 3,
  SoundCategory.animal: 3,
  SoundCategory.alarm: 1,
  SoundCategory.movement: 3,
};

// ---------------------------------------------------------------------------
// Display-level grouping — 1:1 with the collapsed SoundCategory set.
// ---------------------------------------------------------------------------

enum DisplayCategory {
  talking,
  snoring,
  events,
  pets,
  music,
  other,
}

class DisplayCategoryInfo {
  final String label;
  final IconData icon;
  final Color color;
  const DisplayCategoryInfo(this.label, this.icon, this.color);
}

const Map<DisplayCategory, DisplayCategoryInfo> displayCategoryInfo = {
  DisplayCategory.talking: DisplayCategoryInfo(
      'Talking', Icons.record_voice_over, AppColors.accent),
  DisplayCategory.snoring:
      DisplayCategoryInfo('Snoring', Icons.bedtime, AppColors.primary),
  DisplayCategory.events:
      DisplayCategoryInfo('Events', Icons.flash_on, AppColors.orange),
  DisplayCategory.pets:
      DisplayCategoryInfo('Pets', Icons.pets, AppColors.amber),
  DisplayCategory.music:
      DisplayCategoryInfo('Music', Icons.music_note, AppColors.cyan),
  DisplayCategory.other:
      DisplayCategoryInfo('Other', Icons.graphic_eq, AppColors.textMuted),
};

/// Fold a [SoundCategory] into a display bucket. For active categories
/// this is near-identity; legacy categories fold to the bucket they
/// match semantically.
DisplayCategory displayCategoryOf(SoundCategory c) {
  switch (c) {
    case SoundCategory.talking:
    case SoundCategory.speech:
    case SoundCategory.whisper:
      return DisplayCategory.talking;
    case SoundCategory.snoring:
      return DisplayCategory.snoring;
    case SoundCategory.events:
    case SoundCategory.cough:
    case SoundCategory.sneeze:
    case SoundCategory.fart:
    case SoundCategory.laugh:
    case SoundCategory.cry:
    case SoundCategory.scream:
    case SoundCategory.passion:
    case SoundCategory.alarmClock:
    case SoundCategory.alarmHousehold:
    case SoundCategory.siren:
    case SoundCategory.phone:
    case SoundCategory.doorbell:
    case SoundCategory.alarm:
      return DisplayCategory.events;
    case SoundCategory.pets:
    case SoundCategory.cat:
    case SoundCategory.dog:
    case SoundCategory.animal:
      return DisplayCategory.pets;
    case SoundCategory.music:
      return DisplayCategory.music;
    case SoundCategory.silence:
    case SoundCategory.unknown:
    case SoundCategory.breathing:
    case SoundCategory.traffic:
    case SoundCategory.weather:
    case SoundCategory.walking:
    case SoundCategory.movementBed:
    case SoundCategory.movement:
      return DisplayCategory.other;
  }
}

/// Set of display buckets a recording belongs to — the primary plus
/// any tag plus any per-segment category. A clip whose primary is
/// Snoring but contains a real events window shows up under both.
Set<DisplayCategory> displayCategoriesFor(
    SoundCategory primary,
    List<SoundCategory> tags,
    List<SoundCategory> windowCategories) {
  final out = <DisplayCategory>{displayCategoryOf(primary)};
  for (final t in tags) {
    out.add(displayCategoryOf(t));
  }
  for (final w in windowCategories) {
    if (w == SoundCategory.unknown || w == SoundCategory.silence) continue;
    out.add(displayCategoryOf(w));
  }
  return out;
}
