import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/message_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'audio_message_widget.dart';
import 'media_message_widget.dart';

class MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool mine;
  final bool showSender;
  final bool joinsPrevious; // same sender as the message above, so the corner is softened
  final VoidCallback onReply;
  final VoidCallback? onDelete;

  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.showSender,
    required this.joinsPrevious,
    required this.onReply,
    this.onDelete,
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
    final isVisual = message.type == MessageType.image || message.type == MessageType.video;

    Widget content;
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
          child: SelectableText(message.text, style: AppTheme.body(15.5, color: fg, height: 1.35)),
        );
    }

    return Dismissible(
      key: ValueKey('swipe-${message.id}'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.18},
      confirmDismiss: (_) async {
        HapticFeedback.selectionClick();
        onReply();
        return false;
      },
      background: const Align(
        alignment: Alignment.centerLeft,
        child: Padding(padding: EdgeInsets.only(left: 18), child: Icon(Icons.reply_rounded, color: AppColors.primary)),
      ),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.only(top: joinsPrevious ? 2 : 8, left: mine ? 48 : 12, right: mine ? 12 : 48),
          child: GestureDetector(
            onLongPress: () => _showActions(context),
            child: ConstrainedBox(
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
                          child: Text(message.senderName, style: AppTheme.body(12.5, weight: FontWeight.w700, color: AppColors.primary)),
                        ),
                      if (message.replyToId != null) _ReplyQuote(message: message, mine: mine),
                      if (isVisual && message.replyToId != null) const SizedBox(height: 6),
                      content,
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 2, 12, 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isVisual && message.text.isNotEmpty)
                              Flexible(child: Text(message.text, style: AppTheme.body(14, color: fg))),
                            const SizedBox(width: 6),
                            Text(
                              DateFormat.jm().format(message.timestamp),
                              style: AppTheme.body(10.5, color: fg.withValues(alpha: 0.6)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(sheet);
                onReply();
              },
            ),
            if (message.type == MessageType.text)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  Navigator.pop(sheet);
                },
              ),
            if (onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
                title: const Text('Delete for everyone', style: TextStyle(color: AppColors.error)),
                onTap: () {
                  Navigator.pop(sheet);
                  onDelete!();
                },
              ),
            const SizedBox(height: 8),
          ],
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
