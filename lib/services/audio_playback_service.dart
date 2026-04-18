import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Immutable snapshot of playback state broadcast to listeners. Tiles
/// compare [activeSession] against their own session id to decide whether
/// they should render progress / a pause icon — this is a *session* id,
/// not a clip id, because the same clip can be rendered in multiple
/// places (e.g. under different category headings) and only the tile the
/// user actually tapped should light up.
class PlaybackState {
  final String? activeSession;
  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;

  const PlaybackState({
    this.activeSession,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  static const idle = PlaybackState();
}

/// One app-wide [AudioPlayer] shared by every tile. Because there is only
/// one player, only one clip can ever play at a time. Callers pass a
/// `session` string that uniquely identifies which tile is driving
/// playback — when a different session takes over, the previous session's
/// UI flips back to an idle state.
class AudioPlaybackService {
  final AudioPlayer _player = AudioPlayer();
  final StreamController<PlaybackState> _ctrl =
      StreamController<PlaybackState>.broadcast();

  String? _activeSession;
  String? _loadedPath;
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
        activeSession: _activeSession,
        playing: _player.playing,
        loading: _loading,
        position: _player.position,
        duration: _duration,
      );

  void _emit() => _ctrl.add(_snapshot());

  /// Ensure [filePath] is loaded in the player and mark [session] as the
  /// caller. Does not play. Used for scrubbing a clip that the user
  /// hasn't tapped play on yet.
  Future<void> ensureLoaded(String session, String filePath) async {
    final needReload = _loadedPath != filePath;
    if (needReload) {
      _loading = true;
      _emit();
      try {
        final d = await _player.setFilePath(filePath);
        _duration = d ?? Duration.zero;
        _loadedPath = filePath;
      } catch (_) {
        _loadedPath = null;
        _duration = Duration.zero;
      } finally {
        _loading = false;
      }
    }
    _activeSession = session;
    _emit();
  }

  Future<void> toggle(String session, String filePath) async {
    if (_activeSession == session && _player.playing) {
      await _player.pause();
      _emit();
      return;
    }
    await ensureLoaded(session, filePath);
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
