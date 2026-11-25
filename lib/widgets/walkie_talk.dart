import 'dart:async';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import '../models/chat_room_model.dart';
import '../models/user_model.dart';
import '../platform/platform.dart';
import '../services/e2e_service.dart';
import '../services/rate_limiter.dart';
import '../services/walkie_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// Press and hold a chat to talk; let go to send. Records while held and shows a
/// "Talking to …" banner over everything.
class WalkieTalker {
  final AudioRecorder _recorder = AudioRecorder();
  OverlayEntry? _banner;
  final ValueNotifier<Duration> _elapsed = ValueNotifier(Duration.zero);
  Timer? _ticker;
  DateTime? _startedAt;
  bool _held = false;
  bool _recording = false;
  String _format = 'm4a';
  ChatRoomModel? _room;
  UserModel? _me;
  String _name = '';

  Future<void> start(BuildContext context, {required ChatRoomModel room, required UserModel me, required String name}) async {
    if (_held) return;
    _held = true;
    _room = room;
    _me = me;
    _name = name;
    HapticFeedback.mediumImpact();
    // Only people who turned walkie-talkie on can be talked to.
    List<UserModel> listeners;
    try {
      listeners = await Walkie.listeners(room, me.uid);
    } catch (_) {
      listeners = const [];
      if (context.mounted) showSnack(context, 'Could not reach $name. Check your connection.', error: true);
      _held = false;
      return;
    }
    if (!context.mounted || !_held) {
      _held = false;
      return;
    }
    if (listeners.isEmpty) {
      _held = false;
      showSnack(
        context,
        room.isGroup ? 'No one in this group has walkie-talkie turned on' : '$name hasn\'t turned on walkie-talkie',
        error: true,
      );
      return;
    }
    if (!await _recorder.hasPermission()) {
      _held = false;
      if (context.mounted) showSnack(context, 'Allow the microphone to use walkie-talkie', error: true);
      return;
    }
    if (!_held || !context.mounted) {
      _held = false;
      return;
    }
    final aac = !kIsWeb || await _recorder.isEncoderSupported(AudioEncoder.aacLc);
    _format = aac ? 'm4a' : 'webm';
    final dir = await temporaryDirectory();
    await _recorder.start(
      RecordConfig(encoder: aac ? AudioEncoder.aacLc : AudioEncoder.opus, bitRate: 64000, sampleRate: aac && !kIsWeb ? 44100 : 48000, numChannels: 1),
      path: '${dir.path}/walkie-${DateTime.now().millisecondsSinceEpoch}.$_format',
    );
    _recording = true;
    _startedAt = DateTime.now();
    _elapsed.value = Duration.zero;
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed.value = DateTime.now().difference(_startedAt!);
      if (_elapsed.value >= Walkie.maxLength && context.mounted) finish(context);
    });
    if (context.mounted) _showBanner(context, listeners);
    // Let go before recording even started.
    if (!_held && context.mounted) await finish(context);
  }

  Future<void> finish(BuildContext context) async {
    final wasHeld = _held;
    _held = false;
    if (!_recording) return;
    _recording = false;
    _ticker?.cancel();
    _banner?.remove();
    _banner = null;
    final length = DateTime.now().difference(_startedAt ?? DateTime.now());
    final path = await _recorder.stop();
    if (path == null || !wasHeld && length < const Duration(milliseconds: 300)) return;
    if (length < const Duration(milliseconds: 700)) {
      if (context.mounted) showSnack(context, 'Keep holding while you talk');
      return;
    }
    HapticFeedback.lightImpact();
    final room = _room!;
    final me = _me!;
    final name = _name;
    try {
      final clip = await fileFromPicked(XFile(path, name: kIsWeb ? 'walkie.$_format' : null));
      await Walkie.send(room: room, sender: me, clip: clip, length: length);
      if (context.mounted) showSnack(context, 'Sent to $name');
    } on NoKeyException {
      if (context.mounted) showSnack(context, '$name needs to update Comms first', error: true);
    } on RateLimitException catch (e) {
      if (context.mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      debugPrint('walkie-talkie send failed: $e');
      if (context.mounted) showSnack(context, 'Could not send. Check your connection.', error: true);
    }
  }

  void _showBanner(BuildContext context, List<UserModel> listeners) {
    _banner?.remove();
    final who = _room!.isGroup ? '$_name (${listeners.length} listening)' : _name;
    _banner = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            alignment: Alignment.center,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 32),
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
              decoration: BoxDecoration(
                color: AppColors.bgAlt,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.4)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _Pulse(),
                  const SizedBox(height: 16),
                  Text('Talking to $who', textAlign: TextAlign.center, style: AppTheme.display(20, weight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  ValueListenableBuilder<Duration>(
                    valueListenable: _elapsed,
                    builder: (_, d, _) => Text(
                      '${d.inSeconds}s of ${Walkie.maxLength.inSeconds}s · let go to send',
                      style: AppTheme.body(14, color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_banner!);
  }

  void dispose() {
    _ticker?.cancel();
    _banner?.remove();
    _recorder.dispose();
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: AppColors.primary,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.25 + 0.35 * _c.value), blurRadius: 12 + 22 * _c.value, spreadRadius: 2 + 6 * _c.value)],
        ),
        child: child,
      ),
      child: const Icon(Icons.settings_voice_rounded, color: AppColors.textDark, size: 38),
    );
  }
}
