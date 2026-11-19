import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/message_model.dart';
import '../services/user_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'audio_message_widget.dart';
import 'media_message_widget.dart';
import 'view_once_message.dart';
import '../services/local_prefs.dart';

/// The six quick reactions, plus more behind the + button.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
const moreReactions = ['🔥', '😍', '🎉', '👏', '😡', '🤔', '💯', '😭', '🥲', '😎', '🤣', '👀', '🙌', '💀', '🤝', '✨', '😅', '🥳'];

/// How many emojis a message is made of, or 0 when it has any other text.
/// Flags and joined emojis (like a family) count as one.
int emojiOnlyCount(String text) {
  final t = text.trim();
  if (t.isEmpty || RegExp(r'[A-Za-z0-9#*]').hasMatch(t)) return 0;
  // ignore: valid_regexps
  final allowed = RegExp(r'^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Regional_Indicator}|\u200D|\uFE0F|\u20E3|\s)+$', unicode: true);
  if (!allowed.hasMatch(t)) return 0;
  // Joined sequences (with zero-width joiners) are one emoji.
  // ignore: valid_regexps
  final joined = t.replaceAll(RegExp(r'\u200D\p{Extended_Pictographic}', unicode: true), '');
  // ignore: valid_regexps
  final pictures = RegExp(r'\p{Extended_Pictographic}', unicode: true).allMatches(joined).length;
  final flags = RegExp(r'\p{Regional_Indicator}', unicode: true).allMatches(joined).length ~/ 2;
  return pictures + flags;
}

/// How far one of your messages has got.
enum Receipt { none, sending, sent, seenBySome, seen }

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool mine;
  final bool showSender;
  final bool joinsPrevious; // same sender as the message above, so the corner is softened
  final VoidCallback onReply;
  final VoidCallback? onDelete;

  /// Pops in when it first appears (a message just sent or received).
  final bool animateIn;

  /// Shrinks away, then calls [onRemoved].
  final bool removing;
  final VoidCallback? onRemoved;

  final String myUid;
  final Receipt receipt;
  final void Function(String? emoji)? onReact;
  final VoidCallback? onEdit;

  /// For view-once photos and videos.
  final List<String> others;
  final Future<void> Function(File file)? onOpenViewOnce;

  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.showSender,
    required this.joinsPrevious,
    required this.onReply,
    this.onDelete,
    this.animateIn = false,
    this.removing = false,
    this.onRemoved,
    required this.myUid,
    this.receipt = Receipt.none,
    this.onReact,
    this.onEdit,
    this.others = const [],
    this.onOpenViewOnce,
  });

  @override
  Widget build(BuildContext context) {
    if (message.type == MessageType.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(color: AppColors.bgAlt, borderRadius: BorderRadius.circular(20)),
          child: Text(message.text, style: AppTheme.body(12.5, color: AppColors.textMuted)),
        ),
      );
    }

    final maxWidth = MediaQuery.sizeOf(context).width.clamp(0, 900) * 0.76;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(!mine && joinsPrevious ? 8 : 20),
      topRight: Radius.circular(mine && joinsPrevious ? 8 : 20),
      bottomLeft: Radius.circular(mine ? 20 : 6),
      bottomRight: Radius.circular(mine ? 6 : 20),
    );
    final fg = mine ? AppColors.textDark : AppColors.text;
    final isVisual = (message.type == MessageType.image || message.type == MessageType.video) && !message.isViewOnce;

    Widget content;
    final emojis = message.type == MessageType.text ? emojiOnlyCount(message.text) : 0;
    if (message.isViewOnce) {
      content = ViewOnceMessage(message: message, mine: mine, myUid: myUid, others: others, onOpen: onOpenViewOnce);
    } else {
    switch (message.type) {
      case MessageType.image:
        content = ImageMessage(message: message);
        break;
      case MessageType.video:
        content = VideoMessage(message: message);
        break;
      case MessageType.audio:
        content = Padding(padding: const EdgeInsets.fromLTRB(10, 10, 14, 4), child: AudioMessage(message: message, mine: mine));
        break;
      default:
        content = Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Text(
            message.text,
            // Messages of only a few emojis are shown larger so they stand out.
            style: emojis > 0 && emojis <= 8
                ? TextStyle(fontSize: emojis <= 3 ? 34 : 26, height: 1.2)
                : AppTheme.body(15.5, color: fg, height: 1.35),
          ),
        );
    }
    }

    final body = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth.toDouble()),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: mine ? AppColors.primary : AppColors.bubbleOther,
            borderRadius: radius,
            border: mine ? null : Border.all(color: AppColors.border),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSender && !mine)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    child: Text(Nicknames.instance.name(message.senderId, message.senderName), style: AppTheme.body(12.5, weight: FontWeight.w700, color: AppColors.primary)),
                  ),
                if (message.replyToId != null) _ReplyQuote(message: message, mine: mine),
                if (isVisual && message.replyToId != null) const SizedBox(height: 6),
                content,
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 12, 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isVisual && message.text.isNotEmpty) Flexible(child: Text(message.text, style: AppTheme.body(14, color: fg))),
                      const SizedBox(width: 6),
                      if (message.editedAt != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text('edited', style: AppTheme.body(10.5, color: fg.withValues(alpha: 0.6)).copyWith(fontStyle: FontStyle.italic)),
                        ),
                      Text(
                        DateFormat.jm().format(message.timestamp),
                        style: AppTheme.body(10.5, color: fg.withValues(alpha: 0.6)),
                      ),
                      if (mine && receipt != Receipt.none) ...[
                        const SizedBox(width: 5),
                        ReceiptMark(receipt: receipt, color: fg),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

    final reactions = message.reactions;
    final bubble = Builder(
      builder: (bubbleContext) => GestureDetector(
        onLongPress: () => _openMenu(bubbleContext, body),
        child: body,
      ),
    );

    return Appear(
      animate: animateIn,
      leaving: removing,
      onLeft: onRemoved,
      alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
      child: SwipeToReply(
        onReply: onReply,
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(top: joinsPrevious ? 2 : 8, left: mine ? 48 : 12, right: mine ? 12 : 48),
            child: Column(
              crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                bubble,
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: reactions.isEmpty
                      ? const SizedBox(height: 0)
                      : Transform.translate(
                          offset: const Offset(0, -6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: ReactionPill(
                              reactions: reactions,
                              myUid: myUid,
                              onTap: () => _showReactions(context),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openMenu(BuildContext bubbleContext, Widget body) {
    HapticFeedback.mediumImpact();
    final box = bubbleContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final actions = <MenuAction>[
      MenuAction(Icons.reply_rounded, 'Reply', onReply),
      if (onEdit != null) MenuAction(Icons.edit_rounded, 'Edit', onEdit!),
      if (message.type == MessageType.text && message.text.isNotEmpty)
        MenuAction(Icons.copy_rounded, 'Copy', () => Clipboard.setData(ClipboardData(text: message.text))),
      if (onDelete != null) MenuAction(Icons.delete_outline_rounded, 'Delete for everyone', onDelete!, danger: true),
    ];
    Navigator.of(bubbleContext).push(PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, animation, _) => MessageMenu(
        animation: animation,
        bubbleRect: rect,
        bubble: body,
        mine: mine,
        current: message.reactions[myUid],
        onReact: onReact,
        actions: actions,
      ),
    ));
  }

  void _showReactions(BuildContext context) {
    final entries = message.reactions.entries.toList()..sort((a, b) => a.key == myUid ? -1 : (b.key == myUid ? 1 : 0));
    showModalBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Reactions', style: AppTheme.display(18, weight: FontWeight.w700)),
            ),
            for (final e in entries)
              ListTile(
                leading: Text(e.value, style: const TextStyle(fontSize: 26)),
                title: Text(e.key == myUid ? 'You' : Nicknames.instance.name(e.key, UserService.instance.cached(e.key)?.name ?? 'Someone')),
                subtitle: e.key == myUid ? const Text('Tap to remove') : null,
                onTap: e.key == myUid
                    ? () {
                        Navigator.pop(sheet);
                        onReact?.call(null);
                      }
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class MenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const MenuAction(this.icon, this.label, this.onTap, {this.danger = false});
}

/// What appears when a message is held: the background blurs, the message lifts,
/// a row of reactions pops out one by one, and the actions sit beside it.
class MessageMenu extends StatefulWidget {
  final Animation<double> animation;
  final Rect bubbleRect;
  final Widget bubble;
  final bool mine;
  final String? current;
  final void Function(String? emoji)? onReact;
  final List<MenuAction> actions;
  const MessageMenu({
    super.key,
    required this.animation,
    required this.bubbleRect,
    required this.bubble,
    required this.mine,
    required this.current,
    required this.onReact,
    required this.actions,
  });

  @override
  State<MessageMenu> createState() => _MessageMenuState();
}

class _MessageMenuState extends State<MessageMenu> {
  bool _more = false;

  void _pick(String emoji) {
    HapticFeedback.lightImpact();
    Navigator.pop(context);
    widget.onReact?.call(emoji == widget.current ? null : emoji);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final a = CurvedAnimation(parent: widget.animation, curve: Curves.easeOutCubic);
    final rect = widget.bubbleRect;
    final showBubble = rect.height < screen.height * 0.55;

    // Reaction bar above the message, actions below; flipped when there is no room.
    const barHeight = 56.0;
    final actionsHeight = widget.actions.length * 48.0 + 12;
    final spaceAbove = rect.top - pad.top - 12;
    final spaceBelow = screen.height - rect.bottom - pad.bottom - 12;
    final barAbove = spaceAbove > barHeight + 8 || !showBubble;
    final actionsBelow = spaceBelow > actionsHeight + 8;

    double barTop = barAbove ? rect.top - barHeight - 8 : rect.bottom + 8;
    double actionsTop = actionsBelow ? rect.bottom + 8 : rect.top - actionsHeight - 8 - (barAbove ? barHeight + 8 : 0);
    if (!barAbove && actionsBelow) actionsTop = rect.bottom + barHeight + 16;
    if (!showBubble) {
      barTop = screen.height / 2 - barHeight - 8;
      actionsTop = screen.height / 2 + 8;
    }
    barTop = barTop.clamp(pad.top + 8, screen.height - pad.bottom - barHeight - 8);
    actionsTop = actionsTop.clamp(pad.top + 8, screen.height - pad.bottom - actionsHeight - 8);

    final side = widget.mine ? Alignment.centerRight : Alignment.centerLeft;
    Widget placed(double top, Widget child) => Positioned(
          top: top,
          left: 12,
          right: 12,
          child: Align(alignment: side, child: child),
        );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: AnimatedBuilder(
              animation: a,
              builder: (_, _) => BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 7 * a.value, sigmaY: 7 * a.value),
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.45 * a.value)),
              ),
            ),
          ),
        ),
        if (showBubble)
          Positioned.fromRect(
            rect: rect,
            child: IgnorePointer(
              child: ScaleTransition(
                scale: Tween(begin: 1.0, end: 1.04).animate(a),
                child: Material(type: MaterialType.transparency, child: widget.bubble),
              ),
            ),
          ),
        if (widget.onReact != null)
          placed(
            barTop,
            FadeTransition(
              opacity: a,
              child: ScaleTransition(
                scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: widget.animation, curve: Curves.easeOutBack)),
                alignment: widget.mine ? Alignment.bottomRight : Alignment.bottomLeft,
                child: _reactionBar(),
              ),
            ),
          ),
        placed(
          actionsTop,
          FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(a),
              child: _actions(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _reactionBar() {
    Widget emoji(String e, int i) {
      final picked = e == widget.current;
      // Each emoji pops in a moment after the one before.
      final start = (0.1 + i * 0.06).clamp(0.0, 0.7);
      final pop = CurvedAnimation(parent: widget.animation, curve: Interval(start, (start + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutBack));
      return ScaleTransition(
        scale: pop,
        child: GestureDetector(
          onTap: () => _pick(e),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: picked ? AppColors.primary.withValues(alpha: 0.25) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Text(e, style: const TextStyle(fontSize: 27)),
          ),
        ),
      );
    }

    return Material(
      color: AppColors.bgElevated,
      elevation: 10,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(30),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: _more
              ? SizedBox(
                  width: 300,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    children: [for (final e in [...quickReactions, ...moreReactions]) GestureDetector(onTap: () => _pick(e), child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: const TextStyle(fontSize: 26))))],
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < quickReactions.length; i++) emoji(quickReactions[i], i),
                    GestureDetector(
                      onTap: () => setState(() => _more = true),
                      child: Container(
                        margin: const EdgeInsets.only(left: 2, right: 2),
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(color: AppColors.bgAlt, shape: BoxShape.circle),
                        child: const Icon(Icons.add_rounded, color: AppColors.textMuted),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _actions() {
    return Material(
      color: AppColors.bgElevated,
      elevation: 10,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in widget.actions)
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    action.onTap();
                  },
                  child: Container(
                    height: 48,
                    constraints: const BoxConstraints(minWidth: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(action.label, style: AppTheme.body(15, color: action.danger ? AppColors.error : AppColors.text)),
                        ),
                        const SizedBox(width: 16),
                        Icon(action.icon, size: 20, color: action.danger ? AppColors.error : AppColors.textMuted),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The little bubble of reactions under a message. It bounces whenever they change.
class ReactionPill extends StatelessWidget {
  final Map<String, String> reactions;
  final String myUid;
  final VoidCallback onTap;
  const ReactionPill({super.key, required this.reactions, required this.myUid, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final e in reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final top = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final shown = top.take(3).join();
    final mineToo = reactions.containsKey(myUid);
    return GestureDetector(
      onTap: onTap,
      child: TweenAnimationBuilder<double>(
        key: ValueKey('$shown${reactions.length}'),
        tween: Tween(begin: 0.4, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.elasticOut,
        builder: (_, v, child) => Transform.scale(scale: v, child: child),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: mineToo ? AppColors.primary.withValues(alpha: 0.7) : AppColors.border, width: 1.4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(shown, style: const TextStyle(fontSize: 15)),
              if (reactions.length > 1) ...[
                const SizedBox(width: 4),
                Text('${reactions.length}', style: AppTheme.body(12, weight: FontWeight.w600, color: AppColors.textMuted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Comms' own receipt mark: a ring that fills in.
///  - sending: a ring being drawn
///  - sent: an empty ring
///  - seen by some of a group: half full
///  - seen: a full dot that pops when it fills
class ReceiptMark extends StatelessWidget {
  final Receipt receipt;
  final Color color;
  const ReceiptMark({super.key, required this.receipt, required this.color});

  @override
  Widget build(BuildContext context) {
    final fill = switch (receipt) {
      Receipt.seen => 1.0,
      Receipt.seenBySome => 0.5,
      _ => 0.0,
    };
    return SizedBox(
      width: 11,
      height: 11,
      child: receipt == Receipt.sending
          ? CircularProgressIndicator(strokeWidth: 1.6, color: color.withValues(alpha: 0.6))
          : TweenAnimationBuilder<double>(
              tween: Tween(end: fill),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutBack,
              builder: (_, f, _) => CustomPaint(painter: _RingPainter(fill: f, color: color)),
            ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fill;
  final Color color;
  _RingPainter({required this.fill, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 0.8;
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.75));
    if (fill <= 0) return;
    // Fills from the bottom up like a glass.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    final h = size.height * fill.clamp(0.0, 1.0);
    canvas.drawRect(Rect.fromLTWH(0, size.height - h, size.width, h), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fill != fill || old.color != color;
}


/// Drag a message to the right to reply. It moves a short way with growing
/// resistance, shows a reply icon, and springs back when let go.
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const SwipeToReply({super.key, required this.child, required this.onReply});

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  static const double _trigger = 56;
  static const double _max = 76;

  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  double _drag = 0; // finger distance
  double _offset = 0; // how far the bubble has moved
  double _releasedAt = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _back.addListener(() => setState(() => _offset = _releasedAt * (1 - Curves.easeOutCubic.transform(_back.value))));
  }

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    _back.stop();
    _drag = math.max(0, _drag + d.delta.dx);
    // Moves 1:1 at first, then slows and stops at _max.
    final moved = _max * (1 - math.exp(-_drag / _max));
    final armed = moved >= _trigger;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _offset = moved;
      _armed = armed;
    });
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _drag = 0;
    _releasedAt = _offset;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final shown = (_offset / _trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_offset > 1)
            Positioned(
              left: 14,
              child: Opacity(
                opacity: shown,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * shown + (_armed ? 0.12 : 0),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _armed ? AppColors.primary : AppColors.bgElevated,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.reply_rounded, size: 19, color: _armed ? AppColors.textDark : AppColors.primary),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(_offset, 0), child: widget.child),
        ],
      ),
    );
  }
}

/// Grows, fades and slides a list item in, and shrinks it away when it leaves.
class Appear extends StatefulWidget {
  final Widget child;
  final bool animate;
  final bool leaving;
  final VoidCallback? onLeft;
  final Alignment alignment;
  const Appear({
    super.key,
    required this.child,
    this.animate = true,
    this.leaving = false,
    this.onLeft,
    this.alignment = Alignment.bottomCenter,
  });

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    reverseDuration: const Duration(milliseconds: 260),
    value: widget.animate ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void didUpdateWidget(covariant Appear old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _c.reverse().then((_) {
        if (mounted && widget.leaving) widget.onLeft?.call();
      });
    } else if (!widget.leaving && old.leaving) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final pop = CurvedAnimation(parent: _c, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    return SizeTransition(
      sizeFactor: size,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _c, curve: const Interval(0, 0.6)),
        child: AnimatedBuilder(
          animation: pop,
          builder: (_, child) => Transform.scale(
            scale: 0.8 + 0.2 * pop.value,
            alignment: widget.alignment,
            child: Transform.translate(offset: Offset(0, 14 * (1 - _c.value)), child: child),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  final MessageModel message;
  final bool mine;
  const _ReplyQuote({required this.message, required this.mine});

  @override
  Widget build(BuildContext context) {
    final fg = mine ? AppColors.textDark : AppColors.text;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: mine ? Colors.black.withValues(alpha: 0.1) : AppColors.bgElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: mine ? AppColors.textDark : AppColors.primary, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message.replyToSenderName ?? '', style: AppTheme.body(12, weight: FontWeight.w700, color: fg)),
          Text(
            message.replyToText ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.body(12.5, color: fg.withValues(alpha: 0.75)),
          ),
        ],
      ),
    );
  }
}

/// Three dots bouncing one after another, shown while someone is typing.
class TypingBubble extends StatefulWidget {
  final String? name; // shown in group chats
  const TypingBubble({super.key, this.name});

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: AppColors.bubbleOther,
              border: Border.all(color: AppColors.border),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
                bottomLeft: Radius.circular(6),
              ),
            ),
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  // Each dot rises and falls a little after the one before it.
                  final t = (_c.value - i * 0.16) % 1.0;
                  final lift = t < 0.4 ? math.sin(t / 0.4 * math.pi) : 0.0;
                  return Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
                    child: Transform.translate(
                      offset: Offset(0, -5 * lift),
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Color.lerp(AppColors.textMuted, AppColors.primary, lift),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          if (widget.name != null) ...[
            const SizedBox(width: 8),
            Flexible(child: Text(widget.name!, overflow: TextOverflow.ellipsis, style: AppTheme.body(12, color: AppColors.textMuted))),
          ],
        ],
      ),
    );
  }
}
