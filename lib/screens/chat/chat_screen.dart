import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../services/call_service.dart';
import '../../models/chat_room_model.dart';
import '../../models/message_model.dart';
import '../../models/user_model.dart';
import '../../models/call_model.dart';
import '../call/audio_call_screen.dart';
import '../call/video_call_screen.dart';

class ChatScreen extends StatefulWidget {
  final ChatRoomModel chatRoom;

  const ChatScreen({super.key, required this.chatRoom});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final CallService _callService = CallService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? get _currentUid => _authService.currentUserId;
  UserModel? _currentUser;

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
    if (_currentUid != null) {
      _chatService.markMessagesAsRead(widget.chatRoom.id, _currentUid!);
    }
  }

  Future<void> _loadCurrentUser() async {
    if (_currentUid != null) {
      _currentUser = await _userService.getUser(_currentUid!);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _currentUid == null) return;

    _chatService.sendMessage(
      chatRoomId: widget.chatRoom.id,
      senderId: _currentUid!,
      senderName: _currentUser?.name ?? 'You',
      text: text,
    );

    _messageController.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _getOtherUserId() {
    return widget.chatRoom.participants.firstWhere(
      (id) => id != _currentUid,
      orElse: () => '',
    );
  }

  Future<void> _makeCall(CallType type) async {
    if (widget.chatRoom.isGroup) return; // Only 1-on-1 calls for now

    final otherUserId = _getOtherUserId();
    final otherUser = await _userService.getUser(otherUserId);
    if (otherUser == null || _currentUser == null) return;

    final call = await _callService.makeCall(
      callerId: _currentUid!,
      callerName: _currentUser!.name,
      callerPhoto: _currentUser!.photoUrl,
      receiverId: otherUserId,
      receiverName: otherUser.name,
      receiverPhoto: otherUser.photoUrl,
      type: type,
    );

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => type == CallType.audio
              ? AudioCallScreen(call: call, isIncoming: false)
              : VideoCallScreen(call: call, isIncoming: false),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: StreamBuilder<List<MessageModel>>(
              stream: _chatService.getMessages(widget.chatRoom.id),
              builder: (context, snapshot) {
                final messages = snapshot.data ?? [];

                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      'Say hello! 👋',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        color: AppColors.textMuted,
                      ),
                    ),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scrollToBottom();
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final isMine = message.senderId == _currentUid;
                    final showSender = widget.chatRoom.isGroup &&
                        !isMine &&
                        message.type != MessageType.system;

                    // Show date separator
                    bool showDate = false;
                    if (index == 0) {
                      showDate = true;
                    } else {
                      final prevDate = messages[index - 1].timestamp;
                      showDate = message.timestamp.day != prevDate.day;
                    }

                    return Column(
                      children: [
                        if (showDate) _DateSeparator(date: message.timestamp),
                        if (message.type == MessageType.system)
                          _SystemMessage(message: message)
                        else
                          _MessageBubble(
                            message: message,
                            isMine: isMine,
                            showSender: showSender,
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (widget.chatRoom.isGroup) {
      return AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chatRoom.groupName ?? 'Group',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            Text(
              '${widget.chatRoom.participants.length} members',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    final otherUserId = _getOtherUserId();
    return AppBar(
      backgroundColor: AppColors.bg,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
        onPressed: () => Navigator.pop(context),
      ),
      title: StreamBuilder<UserModel?>(
        stream: _userService.getUserStream(otherUserId),
        builder: (context, snapshot) {
          final user = snapshot.data;
          return Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(12),
                  image: user?.photoUrl.isNotEmpty == true
                      ? DecorationImage(
                          image: NetworkImage(user!.photoUrl),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: user?.photoUrl.isEmpty != false
                    ? Center(
                        child: Text(
                          user?.initials ?? '?',
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.name ?? 'User',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                    Text(
                      user?.isOnline == true ? 'Online' : 'Offline',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: user?.isOnline == true
                            ? AppColors.online
                            : AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_rounded, color: AppColors.primary),
          onPressed: () => _makeCall(CallType.audio),
        ),
        IconButton(
          icon: const Icon(Icons.videocam_rounded, color: AppColors.primary),
          onPressed: () => _makeCall(CallType.video),
        ),
      ],
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgAlt,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border),
              ),
              child: TextField(
                controller: _messageController,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: AppColors.text,
                ),
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.textMuted,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  filled: false,
                ),
                maxLines: 4,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.send_rounded,
                color: AppColors.textDark,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final bool showSender;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.showSender = false,
  });

  String _formatTime(DateTime time) {
    final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
    final period = time.hour >= 12 ? 'PM' : 'AM';
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isMine
                  ? AppColors.primary.withValues(alpha: 0.15)
                  : AppColors.bgAlt,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isMine ? 16 : 4),
                bottomRight: Radius.circular(isMine ? 4 : 16),
              ),
              border: Border.all(
                color: isMine
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : AppColors.border,
                width: 0.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSender)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      message.senderName,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                Text(
                  message.text,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.text,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(message.timestamp),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: AppColors.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SystemMessage extends StatelessWidget {
  final MessageModel message;

  const _SystemMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            message.text,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _DateSeparator extends StatelessWidget {
  final DateTime date;

  const _DateSeparator({required this.date});

  String _formatDate() {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.bgAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Text(
            _formatDate(),
            style: GoogleFonts.inter(
              fontSize: 11,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
