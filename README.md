# SnoreLore

Flutter app that records sleep noises overnight — snores, coughs, sleep-talking, alarms, pets — and lets you share the weird ones for laughs in the morning.

## What it does

- **Listen while you sleep.** Tap Start (or set auto-schedule), put the phone on your nightstand.
- **Only captures when something happens.** Waits out an ignore window (default 20 min) so falling asleep isn't recorded, then listens for sound crossing a sensitivity threshold.
- **Clips, not continuous.** Each captured segment runs until silence returns, with a cooldown between clips so a single snoring episode doesn't become a hundred tiny files.
- **Categorised on-device.** An embedded [YAMNet](https://www.tensorflow.org/hub/tutorials/yamnet) TFLite model tags each clip (snoring, cough, sleep-talk, alarm, pet, doorbell, …). Nothing leaves your phone.
- **Playback with scrubbable waveform.** Drag through a clip, share it, or delete it — individually or a whole night at once.

## Settings

- Auto-schedule nightly start/stop
- Ignore-first-N-minutes (0–60, default 20)
- Sensitivity (quiet-to-loud trigger threshold)
- Cooldown (seconds between clips)
- Max clip length

## Getting started

```bash
flutter pub get
flutter run
```

Grant microphone and notification permissions on first launch.

## Build

```bash
flutter build apk --release
# → build/app/outputs/apk/release/snorelore.apk
```

## Release

Releases are created manually:

```bash
flutter build apk --release
gh release create vX.Y.Z \
  --title "vX.Y.Z" \
  --notes "Release notes" \
  build/app/outputs/apk/release/snorelore.apk
```

## Dependencies

- `record` — amplitude-triggered audio capture
- `just_audio` — playback with scrubbable position
- `tflite_flutter` + bundled YAMNet model — on-device classification
- `share_plus` — export clips
- `permission_handler`, `wakelock_plus`, `shared_preferences`, `path_provider`

## Privacy

All recording, classification, and storage happen on-device. Nothing is uploaded. When you share a clip, it uses the standard Android share sheet — the destination is entirely up to you.
