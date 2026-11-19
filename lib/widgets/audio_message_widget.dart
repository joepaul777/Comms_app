import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import '../models/message_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../platform/platform.dart';
import 'media_message_widget.dart';
import 'ui.dart';

/// A voice message: play/pause, a little waveform that fills as it plays, and the time.
class AudioMessage extends StatefulWidget {
  final MessageModel message;
  final bool mine;
  const AudioMessage({super.key, required this.message, required this.mine});

  @override
  State<AudioMessage> createState() => _AudioMessageState();
}

class _AudioMessageState extends State<AudioMessage> {
  static _AudioMessageState? _playing; // only one voice message plays at a time
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    final ms = widget.message.durationMs;
    if (ms != null) _duration = Duration(milliseconds: ms);
    _subs.add(_player.onPositionChanged.listen((p) => setState(() => _position = p)));
    _subs.add(_player.onDurationChanged.listen((d) => setState(() => _duration = d)));
    _subs.add(_player.onPlayerStateChanged.listen((s) => setState(() => _isPlaying = s == PlayerState.playing)));
    _subs.add(_player.onPlayerComplete.listen((_) => setState(() {
          _position = Duration.zero;
          _isPlaying = false;
        })));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    if (_playing == this) _playing = null;
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle(String path) async {
    if (_isPlaying) {
      await _player.pause();
      return;
    }
    if (_playing != null && _playing != this) await _playing!._player.pause();
    _playing = this;
    if (_position > Duration.zero) {
      await _player.resume();
    } else {
      await _player.play(localAudio(File(path)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? AppColors.textDark : AppColors.text;
    final accent = widget.mine ? AppColors.textDark : AppColors.primary;
    return MediaLoader(
      message: widget.message,
      builder: (context, state) {
        final file = state.file;
        final progress = state.progress;
        final expired = state.expired;
        final total = _duration ?? Duration.zero;
        final fraction = total.inMilliseconds == 0 ? 0.0 : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        return SizedBox(
          width: 230,
          child: Row(
            children: [
              GestureDetector(
                onTap: file != null ? () => _toggle(file.path) : (state.failed ? state.retry : null),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: widget.mine ? AppColors.textDark.withValues(alpha: 0.12) : AppColors.primarySoft,
                    shape: BoxShape.circle,
                  ),
                  child: file == null
                      ? Padding(
                          padding: const EdgeInsets.all(11),
                          child: expired
                              ? Icon(Icons.mic_off_rounded, size: 18, color: accent)
                              : state.failed
                                  ? Icon(Icons.refresh_rounded, size: 18, color: accent)
                                  : CircularProgressIndicator(strokeWidth: 2, color: accent, value: (progress ?? 0) > 0 ? progress : null),
                        )
                      : AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            key: ValueKey(_isPlaying),
                            color: accent,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Waveform(seed: widget.message.id.hashCode, progress: fraction, color: fg),
                    const SizedBox(height: 4),
                    Text(
                      expired && file == null
                          ? 'Voice message expired'
                          : state.failed && file == null
                              ? 'Couldn\'t load · tap to retry'
                              : formatDuration(_isPlaying || _position > Duration.zero ? _position : total),
                      style: AppTheme.body(11.5, color: fg.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Waveform extends StatelessWidget {
  final int seed;
  final double progress;
  final Color color;
  const _Waveform({required this.seed, required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    const bars = 28;
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(bars, (i) {
          final h = 5 + ((seed >> (i % 16)) ^ (i * 7919)).abs() % 17;
          final played = i / bars <= progress;
          return Expanded(
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 2.6,
                height: h.toDouble(),
                decoration: BoxDecoration(
                  color: played ? color : color.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
