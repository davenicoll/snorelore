import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Immutable snapshot of playback state broadcast to listeners. Tiles
/// compare [activeClipId] against their own recording id to decide whether
/// they should render progress / a pause icon.
class PlaybackState {
  final String? activeClipId;
  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;

  const PlaybackState({
    this.activeClipId,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  static const idle = PlaybackState();
}

/// One app-wide [AudioPlayer] shared by every tile. Because there is only
/// one player, only one clip can ever play at a time — no per-tile
/// coordination needed. Tiles call [toggle] / [seek] against the service
/// and subscribe to [state$] for UI updates.
class AudioPlaybackService {
  final AudioPlayer _player = AudioPlayer();
  final StreamController<PlaybackState> _ctrl =
      StreamController<PlaybackState>.broadcast();

  String? _activeClipId;
  Duration _duration = Duration.zero;
  bool _loading = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  AudioPlaybackService() {
    _posSub = _player.positionStream.listen((_) => _emit());
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
      _emit();
    });
  }

  Stream<PlaybackState> get state$ => _ctrl.stream;
  PlaybackState get state => _snapshot();

  PlaybackState _snapshot() => PlaybackState(
        activeClipId: _activeClipId,
        playing: _player.playing,
        loading: _loading,
        position: _player.position,
        duration: _duration,
      );

  void _emit() => _ctrl.add(_snapshot());

  /// Make sure [clipId] at [filePath] is the currently loaded clip. If
  /// it's already loaded this is a no-op; otherwise load it (without
  /// playing). Useful for scrubbing a clip the user hasn't hit play on
  /// yet.
  Future<void> ensureLoaded(String clipId, String filePath) async {
    if (_activeClipId == clipId) return;
    _loading = true;
    _emit();
    try {
      final d = await _player.setFilePath(filePath);
      _duration = d ?? Duration.zero;
      _activeClipId = clipId;
    } catch (_) {
      _activeClipId = null;
      _duration = Duration.zero;
    } finally {
      _loading = false;
    }
    _emit();
  }

  Future<void> toggle(String clipId, String filePath) async {
    if (_activeClipId == clipId && _player.playing) {
      await _player.pause();
      _emit();
      return;
    }
    await ensureLoaded(clipId, filePath);
    await _player.play();
    _emit();
  }

  Future<void> pause() async {
    if (!_player.playing) return;
    await _player.pause();
    _emit();
  }

  Future<void> seek(Duration target) async {
    await _player.seek(target);
    _emit();
  }

  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _ctrl.close();
    _player.dispose();
  }
}
