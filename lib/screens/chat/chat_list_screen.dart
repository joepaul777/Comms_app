import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../models/chat_room_model.dart';
import '../../models/user_model.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final ChatService _chatService = ChatService();
  final AuthService _authService = AuthService();
  final UserService _userService = UserService();

  @override
  Widget build(BuildContext context) {
    final currentUid = _authService.currentUserId;
    if (currentUid == null) return const SizedBox();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text(
          'Chats',
          style: GoogleFonts.outfit(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_rounded, color: AppColors.primary),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const CreateGroupScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<List<ChatRoomModel>>(
        stream: _chatService.getChatRooms(currentUid),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            );
          }

          final chatRooms = snapshot.data ?? [];

          if (chatRooms.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 64,
                    color: AppColors.textMuted.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No conversations yet',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Start chatting from the Contacts tab',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.textMuted.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: chatRooms.length,
            itemBuilder: (context, index) {
              final chatRoom = chatRooms[index];
              return _ChatRoomTile(
                chatRoom: chatRoom,
                currentUid: currentUid,
                userService: _userService,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(chatRoom: chatRoom),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _ChatRoomTile extends StatelessWidget {
  final ChatRoomModel chatRoom;
  final String currentUid;
  final UserService userService;
  final VoidCallback onTap;

  const _ChatRoomTile({
    required this.chatRoom,
    required this.currentUid,
    required this.userService,
    required this.onTap,
  });

  String _getOtherUserId() {
    return chatRoom.participants.firstWhere(
      (id) => id != currentUid,
      orElse: () => '',
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inDays == 0) {
      final hour = time.hour > 12 ? time.hour - 12 : time.hour;
      final period = time.hour >= 12 ? 'PM' : 'AM';
      final minute = time.minute.toString().padLeft(2, '0');
      return '$hour:$minute $period';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[time.weekday - 1];
    } else {
      return '${time.day}/${time.month}/${time.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (chatRoom.isGroup) {
      return _buildGroupTile(context);
    }

    final otherUserId = _getOtherUserId();
    return StreamBuilder<UserModel?>(
      stream: userService.getUserStream(otherUserId),
      builder: (context, snapshot) {
        final user = snapshot.data;
        final name = user?.name ?? 'User';
        final photoUrl = user?.photoUrl ?? '';
        final isOnline = user?.isOnline ?? false;

        return _buildTile(
          context: context,
          name: name,
          photoUrl: photoUrl,
          isOnline: isOnline,
          isGroup: false,
        );
      },
    );
  }

  Widget _buildGroupTile(BuildContext context) {
    return _buildTile(
      context: context,
      name: chatRoom.groupName ?? 'Group',
      photoUrl: chatRoom.groupIcon ?? '',
      isOnline: false,
      isGroup: true,
    );
  }

  Widget _buildTile({
    required BuildContext context,
    required String name,
    required String photoUrl,
    required bool isOnline,
    required bool isGroup,
  }) {
    final unread = chatRoom.unreadCount[currentUid] ?? 0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Avatar
            Stack(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                    image: photoUrl.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(photoUrl),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: photoUrl.isEmpty
                      ? Center(
                          child: isGroup
                              ? const Icon(
                                  Icons.group_rounded,
                                  color: AppColors.primary,
                                  size: 24,
                                )
                              : Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: GoogleFonts.outfit(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.primary,
                                  ),
                                ),
                        )
                      : null,
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppColors.online,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.bg, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight:
                                unread > 0 ? FontWeight.w700 : FontWeight.w600,
                            color: AppColors.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatTime(chatRoom.lastMessageTime),
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: unread > 0
                              ? AppColors.primary
                              : AppColors.textMuted,
                          fontWeight:
                              unread > 0 ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chatRoom.lastMessage.isEmpty
                              ? 'Tap to start chatting'
                              : chatRoom.lastMessage,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: unread > 0
                                ? AppColors.text.withValues(alpha: 0.8)
                                : AppColors.textMuted,
                            fontWeight:
                                unread > 0 ? FontWeight.w500 : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            unread.toString(),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDark,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
