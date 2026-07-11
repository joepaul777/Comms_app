import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/media_service.dart';
import '../../widgets/media_message_widget.dart';
import '../../widgets/audio_message_widget.dart';

import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../services/call_service.dart';
import '../../services/notification_service.dart';
import '../../models/chat_room_model.dart';
import '../../models/message_model.dart';
import '../../models/user_model.dart';
import '../../models/call_model.dart';
import '../call/audio_call_screen.dart';
import '../call/video_call_screen.dart';
import '../../utils/image_utils.dart';

class ChatScreen extends StatefulWidget {
  final ChatRoomModel chatRoom;

  const ChatScreen({super.key, required this.chatRoom});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Media state
  final MediaService _mediaService = MediaService();
  final ImagePicker _imagePicker = ImagePicker();
  
  // Audio state
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _recordingPath;
  bool _isTextFieldEmpty = true;

  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();
  final CallService _callService = CallService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? get _currentUid => _authService.currentUserId;
  UserModel? _currentUser;

  // Reply state
  MessageModel? _replyingTo;

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() {
      setState(() {
        _isTextFieldEmpty = _messageController.text.trim().isEmpty;
      });
    });
    _loadCurrentUser();
    if (_currentUid != null) {
      _chatService.markMessagesAsRead(widget.chatRoom.id, _currentUid!);
    }
    // Suppress notifications for this chat while viewing it
    NotificationService.activeChatRoomId = widget.chatRoom.id;
  }

  Future<void> _loadCurrentUser() async {
    if (_currentUid != null) {
      _currentUser = await _userService.getUser(_currentUid!);
    }
  }

  @override
  void dispose() {
    // Clear active chat so notifications resume
    NotificationService.activeChatRoomId = null;
    _audioRecorder.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }


  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final dir = await getApplicationDocumentsDirectory();
      _recordingPath = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(
        const RecordConfig(),
        path: _recordingPath!,
      );
      setState(() => _isRecording = true);
    }
  }

  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);
    
    if (path != null && _currentUid != null) {
      final file = File(path);
      final fileName = path.split('/').last;
      
      final downloadUrl = await _mediaService.uploadMedia(
        file: file,
        messageId: fileName,
        fileName: fileName,
      );
      
      if (downloadUrl != null) {
        _chatService.sendMessage(
          chatRoomId: widget.chatRoom.id,
          senderId: _currentUid!,
          senderName: _currentUser?.name ?? 'You',
          text: 'Voice Message',
          type: MessageType.audio,
          mediaUrl: downloadUrl,
          localFilePath: path,
        );
        _scrollToBottom();
      }
    }
  }

  Future<void> _pickMedia(ImageSource source, bool isVideo) async {
    final XFile? pickedFile = isVideo 
        ? await _imagePicker.pickVideo(source: source)
        : await _imagePicker.pickImage(source: source, imageQuality: 70);

    if (pickedFile != null && _currentUid != null) {
      final file = File(pickedFile.path);
      final fileName = pickedFile.name;
      final type = isVideo ? MessageType.video : MessageType.image;
      
      final downloadUrl = await _mediaService.uploadMedia(
        file: file,
        messageId: fileName,
        fileName: fileName,
      );
      
      if (downloadUrl != null) {
        _chatService.sendMessage(
          chatRoomId: widget.chatRoom.id,
          senderId: _currentUid!,
          senderName: _currentUser?.name ?? 'You',
          text: isVideo ? 'Video' : 'Image',
          type: type,
          mediaUrl: downloadUrl,
          localFilePath: pickedFile.path,
        );
        _scrollToBottom();
      }
    }
  }

  void _showMediaBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: AppColors.primary),
              title: Text('Gallery', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.gallery, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_rounded, color: AppColors.primary),
              title: Text('Camera (Photo)', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.camera, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam_rounded, color: AppColors.primary),
              title: Text('Camera (Video)', style: GoogleFonts.inter(color: AppColors.text)),
              onTap: () {
                Navigator.pop(context);
                _pickMedia(ImageSource.camera, true);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _currentUid == null) return;

    _chatService.sendMessage(
      chatRoomId: widget.chatRoom.id,
      senderId: _currentUid!,
      senderName: _currentUser?.name ?? 'You',
      text: text,
      replyToId: _replyingTo?.id,
      replyToText: _replyingTo?.text,
      replyToSenderName: _replyingTo?.senderName,
    );

    _messageController.clear();
    setState(() => _replyingTo = null);
    _scrollToBottom();
  }

  void _setReply(MessageModel message) {
    setState(() => _replyingTo = message);
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
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
            child: Stack(
              children: [
                // Subtle chat background pattern
                const _ChatBackgroundPattern(),
                // Messages list
                StreamBuilder<List<MessageModel>>(
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
                              _SwipeableMessageBubble(
                                message: message,
                                isMine: isMine,
                                showSender: showSender,
                                onSwipe: () => _setReply(message),
                              ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          // Reply preview bar
          if (_replyingTo != null) _buildReplyPreview(),
          // Input bar
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildReplyPreview() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bgAlt,
        border: Border(
          top: BorderSide(color: AppColors.primary.withValues(alpha: 0.3), width: 1),
          left: BorderSide(color: AppColors.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _replyingTo!.senderName,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _replyingTo!.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _cancelReply,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (widget.chatRoom.isGroup) {
      return AppBar(
        backgroundColor: AppColors.bg.withOpacity(0.75),
        elevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(color: Colors.transparent),
          ),
        ),
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
      backgroundColor: AppColors.bg.withOpacity(0.75),
      elevation: 0,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(color: Colors.transparent),
        ),
      ),
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
                          image: getImageProvider(user!.photoUrl),
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
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.only(
            left: 8,
            right: 8,
            top: 12,
            bottom: MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgAlt.withOpacity(0.8),
            border: const Border(
              top: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.add_circle_outline_rounded, color: AppColors.primary),
                onPressed: _showMediaBottomSheet,
              ),
              Expanded(
                child: Theme(
                  data: Theme.of(context).copyWith(
                    inputDecorationTheme: const InputDecorationTheme(
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      focusColor: Colors.transparent,
                    ),
                  ),
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
                      cursorColor: AppColors.primary,
                      decoration: InputDecoration(
                        hintText: _isRecording ? 'Recording audio...' : 'Type a message...',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 14,
                          color: _isRecording ? AppColors.error : AppColors.textMuted,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        filled: false,
                        isDense: true,
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _sendMessage(),
                      readOnly: _isRecording,
                      contentInsertionConfiguration: ContentInsertionConfiguration(
                        onContentInserted: (KeyboardInsertedContent content) async {
                          if (content.data != null && _currentUid != null) {
                            final dir = await getTemporaryDirectory();
                            final file = File('${dir.path}/gif_${DateTime.now().millisecondsSinceEpoch}.gif');
                            await file.writeAsBytes(content.data!);
                            final fileName = file.path.split('/').last;
                            final downloadUrl = await _mediaService.uploadMedia(
                              file: file,
                              messageId: fileName,
                              fileName: fileName,
                            );
                            if (downloadUrl != null) {
                              _chatService.sendMessage(
                                chatRoomId: widget.chatRoom.id,
                                senderId: _currentUid!,
                                senderName: _currentUser?.name ?? 'You',
                                text: 'GIF',
                                type: MessageType.gif,
                                mediaUrl: downloadUrl,
                                localFilePath: file.path,
                              );
                              _scrollToBottom();
                            }
                          }
                        },
                        allowedMimeTypes: const <String>['image/gif', 'image/png'],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  if (!_isTextFieldEmpty) {
                    _sendMessage();
                  } else {
                    if (_isRecording) {
                      _stopRecordingAndSend();
                    } else {
                      _startRecording();
                    }
                  }
                },
                onLongPressStart: (_) {
                  if (_isTextFieldEmpty) _startRecording();
                },
                onLongPressEnd: (_) {
                  if (_isTextFieldEmpty) _stopRecordingAndSend();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: _isRecording ? 52 : 44,
                  height: _isRecording ? 52 : 44,
                  margin: EdgeInsets.only(bottom: _isRecording ? 0 : 2),
                  decoration: BoxDecoration(
                    color: _isRecording ? AppColors.error : Colors.transparent,
                    gradient: _isRecording ? null : AppColors.primaryGradient,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (_isRecording ? AppColors.error : AppColors.primary).withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    _isTextFieldEmpty ? Icons.mic_rounded : Icons.send_rounded,
                    color: _isRecording ? Colors.white : AppColors.textDark,
                    size: _isRecording ? 24 : 20,
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

/// Swipeable wrapper that triggers reply on right-swipe
class _SwipeableMessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final bool showSender;
  final VoidCallback onSwipe;

  const _SwipeableMessageBubble({
    required this.message,
    required this.isMine,
    this.showSender = false,
    required this.onSwipe,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(message.id),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        onSwipe();
        return false; // Don't actually dismiss
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Icon(
          Icons.reply_rounded,
          color: AppColors.primary.withValues(alpha: 0.6),
          size: 24,
        ),
      ),
      child: _MessageBubble(
        message: message,
        isMine: isMine,
        showSender: showSender,
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
  }

  String _formatTime(DateTime time) {
    final hour = time.hour > 12 ? time.hour - 12 : (time.hour == 0 ? 12 : time.hour);
    final period = time.hour >= 12 ? 'PM' : 'AM';
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute $period';
  }

  @override
  Widget build(BuildContext context) {
    final hasReply = message.replyToText != null && message.replyToText!.isNotEmpty;

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
                // Reply quote
                if (hasReply)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.bg.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.6),
                          width: 2,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.replyToSenderName ?? '',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                        Text(
                          message.replyToText ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                _buildMessageContent(context),
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

/// Subtle dot pattern background for the chat area
class _ChatBackgroundPattern extends StatelessWidget {
  const _ChatBackgroundPattern();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _DotPatternPainter(),
      ),
    );
  }
}

class _DotPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    const spacing = 28.0;
    const dotRadius = 1.0;

    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
