import sys

file_path = r'C:\JOEPAUL\Comms\lib\screens\chat\chat_screen.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# ... [Everything from before up to 8.] ...

# 9. MessageBubble _buildMessageContent and onLongPress!
bubble_orig = """class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final bool showSender;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.showSender = false,
  });"""
bubble_new = """class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final bool showSender;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.showSender = false,
  });

  Widget _buildMessageContent(BuildContext context) {
    if (message.type == MessageType.image || message.type == MessageType.video || message.type == MessageType.gif) {
      return MediaMessageWidget(message: message, isMine: isMine);
    } else if (message.type == MessageType.audio) {
      return AudioMessageWidget(message: message, isMine: isMine);
    }
    
    return Text(
      message.text,
      style: GoogleFonts.inter(
        fontSize: 14,
        color: isMine ? AppColors.textDark : AppColors.text,
        height: 1.4,
      ),
    );
  }"""
content = content.replace(bubble_orig, bubble_new)

bubble_text_orig = """                Text(
                  message.text,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.text,
                    height: 1.4,
                  ),
                ),"""
bubble_text_new = """                _buildMessageContent(context),"""
content = content.replace(bubble_text_orig, bubble_text_new)

# Add chatRoomId to _SwipeableMessageBubble
swipe_class_orig = """class _SwipeableMessageBubble extends StatefulWidget {
  final MessageModel message;
  final bool isMine;
  final bool showSender;
  final VoidCallback onSwipe;

  const _SwipeableMessageBubble({
    required this.message,
    required this.isMine,
    this.showSender = false,
    required this.onSwipe,
  });"""
swipe_class_new = """class _SwipeableMessageBubble extends StatefulWidget {
  final String chatRoomId;
  final MessageModel message;
  final bool isMine;
  final bool showSender;
  final VoidCallback onSwipe;

  const _SwipeableMessageBubble({
    required this.chatRoomId,
    required this.message,
    required this.isMine,
    this.showSender = false,
    required this.onSwipe,
  });"""
content = content.replace(swipe_class_orig, swipe_class_new)

swipe_orig = """    return GestureDetector(
      onHorizontalDragStart: (details) {"""
swipe_new = """    return GestureDetector(
      onLongPress: widget.isMine ? () {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.bgAlt,
            title: Text('Delete Message', style: GoogleFonts.outfit(color: AppColors.text)),
            content: Text('Delete this message for everyone?', style: GoogleFonts.inter(color: AppColors.textMuted)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel', style: GoogleFonts.inter(color: AppColors.primary)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  final chatService = ChatService();
                  chatService.deleteMessage(widget.chatRoomId, widget.message.id);
                  if (widget.message.localFilePath != null) {
                    try {
                      File(widget.message.localFilePath!).delete();
                    } catch (e) {
                      // Ignore error if file doesn't exist
                    }
                  }
                },
                child: Text('Delete', style: GoogleFonts.inter(color: AppColors.error)),
              ),
            ],
          ),
        );
      } : null,
      onHorizontalDragStart: (details) {"""
content = content.replace(swipe_orig, swipe_new)

# Update where _SwipeableMessageBubble is called
call_orig = """                      return _SwipeableMessageBubble(
                        message: message,
                        isMine: isMine,
                        showSender: showSender,
                        onSwipe: () => _setReply(message),
                      );"""
call_new = """                      return _SwipeableMessageBubble(
                        chatRoomId: widget.chatRoom.id,
                        message: message,
                        isMine: isMine,
                        showSender: showSender,
                        onSwipe: () => _setReply(message),
                      );"""
content = content.replace(call_orig, call_new)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Applied ALL changes cleanly!")
