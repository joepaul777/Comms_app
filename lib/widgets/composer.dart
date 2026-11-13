import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import '../config.dart';
import '../models/message_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'ui.dart';

/// The bar at the bottom of a chat: text, attachments and voice messages.
class Composer extends StatefulWidget {
  final Future<bool> Function(String text) onSendText;
  final VoidCallback onAttach;
  final Future<void> Function(File file, Duration length) onSendVoice;
  final MessageModel? replyTo;

  /// A message being edited; its words fill the box and sending saves them.
  final MessageModel? editing;
  final Future<bool> Function(String text)? onSaveEdit;
  final VoidCallback? onCancelEdit;

  /// Called with true while the person types, and false once they stop.
  final void Function(bool typing)? onTyping;
  final VoidCallback onCancelReply;
  const Composer({
    super.key,
    required this.onSendText,
    required this.onAttach,
    required this.onSendVoice,
    required this.replyTo,
    this.onTyping,
    this.editing,
    this.onSaveEdit,
    this.onCancelEdit,
    required this.onCancelReply,
  });

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> with SingleTickerProviderStateMixin {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  final AudioRecorder _recorder = AudioRecorder();
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  bool _recording = false;
  DateTime? _recordStart;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  StreamSubscription<Amplitude>? _ampSub;
  final List<double> _levels = List.filled(24, 0.08, growable: true);
  bool _sending = false;
  Timer? _idle;
  DateTime? _lastTypingPing;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    if (_text.text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    final now = DateTime.now();
    // Tell the others at most every 3 seconds, and stop 4 seconds after the last key.
    if (_lastTypingPing == null || now.difference(_lastTypingPing!) > const Duration(seconds: 3)) {
      _lastTypingPing = now;
      widget.onTyping?.call(true);
    }
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 4), _stopTyping);
  }

  void _stopTyping() {
    _idle?.cancel();
    if (_lastTypingPing == null) return;
    _lastTypingPing = null;
    widget.onTyping?.call(false);
  }

  @override
  void didUpdateWidget(covariant Composer old) {
    super.didUpdateWidget(old);
    if (widget.replyTo != null && old.replyTo?.id != widget.replyTo!.id) _focus.requestFocus();
    final editing = widget.editing;
    if (editing != null && old.editing?.id != editing.id) {
      _text.text = editing.text;
      _text.selection = TextSelection.collapsed(offset: editing.text.length);
      _focus.requestFocus();
    } else if (editing == null && old.editing != null) {
      _text.clear();
    }
  }

  @override
  void dispose() {
    _stopTyping();
    _ticker?.cancel();
    _ampSub?.cancel();
    _recorder.dispose();
    _pulse.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final value = _text.text.trim();
    if (value.isEmpty || _sending) return;
    _sending = true;
    final editing = widget.editing;
    if (editing != null) {
      if (value != editing.text) {
        final saved = await (widget.onSaveEdit?.call(value) ?? Future.value(false));
        if (!saved) {
          _sending = false;
          return;
        }
      } else {
        widget.onCancelEdit?.call();
      }
      _sending = false;
      return;
    }
    _text.clear();
    final ok = await widget.onSendText(value);
    if (!ok && mounted && _text.text.isEmpty) {
      // Put the words back so nothing is lost.
      _text.text = value;
      _text.selection = TextSelection.collapsed(offset: value.length);
    }
    _sending = false;
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (mounted) showSnack(context, 'Allow the microphone to send voice messages', error: true);
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    HapticFeedback.mediumImpact();
    setState(() {
      _recording = true;
      _recordStart = DateTime.now();
      _elapsed = Duration.zero;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final elapsed = DateTime.now().difference(_recordStart!);
      setState(() => _elapsed = elapsed);
      if (elapsed.inSeconds >= AppConfig.maxVoiceSeconds) _stopRecording(send: true);
    });
    _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 110)).listen((amp) {
      final level = ((amp.current + 50) / 50).clamp(0.06, 1.0);
      setState(() {
        _levels.removeAt(0);
        _levels.add(level);
      });
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    _ticker?.cancel();
    await _ampSub?.cancel();
    final length = _elapsed;
    final path = await _recorder.stop();
    setState(() {
      _recording = false;
      _levels.fillRange(0, _levels.length, 0.08);
    });
    if (path == null) return;
    final file = File(path);
    if (!send || length < const Duration(milliseconds: 800)) {
      if (send && mounted) showSnack(context, 'Hold on a little longer to record', error: true);
      if (await file.exists()) await file.delete();
      return;
    }
    HapticFeedback.lightImpact();
    await widget.onSendVoice(file, length);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(10, 8, 10, 8 + MediaQuery.of(context).padding.bottom * 0.4),
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: widget.editing != null
                  ? _ReplyBanner(key: const ValueKey('edit'), message: widget.editing!, onClose: widget.onCancelEdit ?? () {}, editing: true)
                  : widget.replyTo == null
                      ? const SizedBox(width: double.infinity)
                      : _ReplyBanner(key: ValueKey('reply-${widget.replyTo!.id}'), message: widget.replyTo!, onClose: widget.onCancelReply),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
              ),
              child: _recording ? _recordingRow() : _typingRow(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typingRow() {
    return Row(
      key: const ValueKey('typing'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        CircleIconButton(icon: Icons.add_rounded, onTap: widget.onAttach, tooltip: 'Photo or video'),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _text,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            maxLength: 4000,
            textCapitalization: TextCapitalization.sentences,
            style: AppTheme.body(15.5),
            decoration: InputDecoration(
              hintText: 'Message',
              counterText: '',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: AppColors.primary)),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (_, value, _) {
            final hasText = value.text.trim().isNotEmpty;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
              child: hasText
                  ? CircleIconButton(
                      key: const ValueKey('send'),
                      icon: Icons.arrow_upward_rounded,
                      background: AppColors.primary,
                      foreground: AppColors.textDark,
                      onTap: _send,
                      tooltip: 'Send',
                    )
                  : CircleIconButton(
                      key: const ValueKey('mic'),
                      icon: Icons.mic_rounded,
                      background: AppColors.primary,
                      foreground: AppColors.textDark,
                      onTap: _startRecording,
                      tooltip: 'Record a voice message',
                    ),
            );
          },
        ),
      ],
    );
  }

  Widget _recordingRow() {
    return Row(
      key: const ValueKey('recording'),
      children: [
        CircleIconButton(icon: Icons.delete_outline_rounded, foreground: AppColors.error, onTap: () => _stopRecording(send: false), tooltip: 'Discard'),
        const SizedBox(width: 10),
        FadeTransition(
          opacity: Tween(begin: 0.3, end: 1.0).animate(_pulse),
          child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.error, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 8),
        SizedBox(width: 46, child: Text(formatDuration(_elapsed), style: AppTheme.body(14, weight: FontWeight.w600))),
        Expanded(
          child: SizedBox(
            height: 32,
            child: Row(
              children: _levels
                  .map((l) => Expanded(
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            width: 3,
                            height: 4 + l * 26,
                            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(width: 10),
        CircleIconButton(
          icon: Icons.send_rounded,
          background: AppColors.primary,
          foreground: AppColors.textDark,
          onTap: () => _stopRecording(send: true),
          tooltip: 'Send voice message',
        ),
      ],
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  final MessageModel message;
  final VoidCallback onClose;
  final bool editing;
  const _ReplyBanner({super.key, required this.message, required this.onClose, this.editing = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.bgAlt,
        borderRadius: BorderRadius.circular(14),
        border: const Border(left: BorderSide(color: AppColors.primary, width: 3)),
      ),
      child: Row(
        children: [
          Icon(editing ? Icons.edit_rounded : Icons.reply_rounded, color: AppColors.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(editing ? 'Editing message' : 'Replying to ${message.senderName}', style: AppTheme.body(12.5, weight: FontWeight.w600, color: AppColors.primary)),
                Text(
                  message.type == MessageType.text ? message.text : _label(message.type),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.body(13, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted), onPressed: onClose),
        ],
      ),
    );
  }

  static String _label(MessageType type) => switch (type) {
        MessageType.image => 'Photo',
        MessageType.video => 'Video',
        MessageType.audio => 'Voice message',
        _ => 'Message',
      };
}
