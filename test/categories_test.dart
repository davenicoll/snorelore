import 'package:flutter_test/flutter_test.dart';
import 'package:snorelore/utils/categories.dart';

void main() {
  group('mapYamnetLabel — Pets bucket', () {
    test('cat-family labels still route to pets', () {
      expect(mapYamnetLabel('Cat'), SoundCategory.pets);
      expect(mapYamnetLabel('Meow'), SoundCategory.pets);
      expect(mapYamnetLabel('Purr'), SoundCategory.pets);
      expect(mapYamnetLabel('Caterwaul'), SoundCategory.pets);
    });

    test('dog-family child labels still route to pets', () {
      expect(mapYamnetLabel('Dog'), SoundCategory.pets);
      expect(mapYamnetLabel('Bark'), SoundCategory.pets);
      expect(mapYamnetLabel('Howl'), SoundCategory.pets);
      expect(mapYamnetLabel('Yip'), SoundCategory.pets);
      expect(mapYamnetLabel('Bow-wow'), SoundCategory.pets);
    });

    test('Hiss does NOT route to pets (v0.15.1)', () {
      // AudioSet Hiss is generic sibilance (fans, breath, fart tails),
      // not feline hiss. Must not land in pets.
      expect(mapYamnetLabel('Hiss'), isNot(SoundCategory.pets));
    });

    test('Canidae umbrella does NOT route to pets (v0.15.3)', () {
      // Over-broad parent class — fires on bedroom noise. Specific
      // child labels (bark/howl/yip/bow-wow) must still cover real dogs.
      expect(mapYamnetLabel('Canidae, dogs, wolves'),
          isNot(SoundCategory.pets));
    });

    test('bare Whimper routes to events, dog whimper to pets', () {
      expect(mapYamnetLabel('Whimper'), SoundCategory.events);
      // The specifically dog-tagged label remains a pet sound.
      expect(mapYamnetLabel('Whimper (dog)'), SoundCategory.pets);
    });

    test('Howl is not eaten by the bird filter', () {
      // Regression: an over-broad n.contains('owl') filter caught 'howl'
      // and routed real dog howls to unknown. Bird filter now uses
      // exact matches for the actual AudioSet owl labels.
      expect(mapYamnetLabel('Howl'), SoundCategory.pets);
      // Genuine bird labels still excluded.
      expect(mapYamnetLabel('Owl'), SoundCategory.unknown);
      expect(mapYamnetLabel('Hoot'), SoundCategory.unknown);
    });

    test('generic Animal / Domestic animals are unknown', () {
      expect(mapYamnetLabel('Animal'), SoundCategory.unknown);
      expect(
          mapYamnetLabel('Domestic animals, pets'), SoundCategory.unknown);
    });
  });

  group('mapYamnetLabel — Talking bucket', () {
    test('speech-family labels route to talking', () {
      // These are denied at inference time but the mapping must still
      // be correct in case the deny list is ever lifted (or tests want
      // to exercise the mapping directly).
      expect(mapYamnetLabel('Speech'), SoundCategory.talking);
      expect(mapYamnetLabel('Whispering'), SoundCategory.talking);
      expect(mapYamnetLabel('Conversation'), SoundCategory.talking);
      expect(mapYamnetLabel('Narration, monologue'), SoundCategory.talking);
      expect(mapYamnetLabel('Babbling'), SoundCategory.talking);
      expect(
          mapYamnetLabel('Child speech, kid speaking'), SoundCategory.talking);
    });
  });

  group('displayCategoriesFor — multi-window floor (v0.15.3)', () {
    test('primary always counts even with no window matches', () {
      final out = displayCategoriesFor(
        SoundCategory.snoring,
        const [],
        const [],
      );
      expect(out, contains(DisplayCategory.snoring));
    });

    test('tag always counts even with one window match', () {
      final out = displayCategoriesFor(
        SoundCategory.snoring,
        const [SoundCategory.events],
        const [SoundCategory.pets], // single pets window
      );
      expect(out, contains(DisplayCategory.snoring));
      expect(out, contains(DisplayCategory.events));
      // Pets has only one window — must NOT add the bucket.
      expect(out, isNot(contains(DisplayCategory.pets)));
    });

    test('two windows of the same bucket DO add it', () {
      final out = displayCategoriesFor(
        SoundCategory.snoring,
        const [],
        const [SoundCategory.pets, SoundCategory.pets],
      );
      expect(out, contains(DisplayCategory.pets));
    });

    test('isolated single Pets window from a Hiss-like glitch is dropped',
        () {
      // Regression: pre-v0.15.3 a single false-positive band put the
      // entire clip into Pets on the Nights summary.
      final out = displayCategoriesFor(
        SoundCategory.snoring,
        const [],
        const [SoundCategory.pets],
      );
      expect(out, isNot(contains(DisplayCategory.pets)));
    });

    test('silence/unknown windows are ignored', () {
      final out = displayCategoriesFor(
        SoundCategory.snoring,
        const [],
        const [
          SoundCategory.silence,
          SoundCategory.silence,
          SoundCategory.unknown,
          SoundCategory.unknown,
        ],
      );
      expect(out, {DisplayCategory.snoring});
    });
  });
}
