import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/chat_room_model.dart';
import '../../models/user_model.dart';
import '../../services/chat_service.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../../widgets/walkie_talk.dart';
import '../../widgets/web_tips.dart';
import '../contacts/person_profile_screen.dart';
import 'create_group_screen.dart';
import 'offline_lobby_screen.dart';
import '../../services/local_prefs.dart';

class ChatListScreen extends StatefulWidget {
  final UserModel me;
  final String? selectedRoomId;
  final ValueChanged<ChatRoomModel> onOpen;
  final VoidCallback onFindPeople;
  const ChatListScreen({super.key, required this.me, required this.onOpen, required this.onFindPeople, this.selectedRoomId});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController _filter = TextEditingController();
  late final Stream<List<ChatRoomModel>> _rooms = ChatService.instance.chatRooms(widget.me.uid);
  String _query = '';

  /// Press and hold a chat to talk to them by walkie-talkie.
  final WalkieTalker _talker = WalkieTalker();

  @override
  void dispose() {
    _talker.dispose();
    super.dispose();
  }

  Future<void> _newGroup() async {
    final room = await Navigator.of(context).push<ChatRoomModel>(
      MaterialPageRoute(
        builder: (_) => PeoplePickerScreen(me: widget.me, title: 'New group', askForGroupName: true),
      ),
    );
    if (room != null) widget.onOpen(room);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          PageHeader(
            title: 'Chats',
            actions: [
              // Nearby chat needs the phone's own radios.
              if (!kIsWeb) ...[
                CircleIconButton(
                  icon: Icons.wifi_tethering_rounded,
                  tooltip: 'Chat nearby without internet',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OfflineLobbyScreen())),
                ),
                const SizedBox(width: 8),
              ],
              CircleIconButton(icon: Icons.group_add_rounded, tooltip: 'New group', onTap: _newGroup),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchField(controller: _filter, hint: 'Search chats', onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
          ),
          if (kIsWeb) const WebTips(),
          Expanded(
            child: StreamBuilder<List<ChatRoomModel>>(
              stream: _rooms,
              builder: (context, snap) {
                if (snap.hasError) {
                  return const EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Can\'t reach Comms',
                    message: 'Check your internet connection. Your chats will appear as soon as you are back online.',
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final rooms = snap.data!.where((r) => r.isGroup || r.lastMessage.isNotEmpty || r.id == widget.selectedRoomId).toList();
                if (rooms.isEmpty) {
                  return EmptyState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'No chats yet',
                    message: 'Find someone by name or email and say hello.',
                    action: ElevatedButton.icon(
                      onPressed: widget.onFindPeople,
                      icon: const Icon(Icons.person_search_rounded),
                      label: const Text('Find people'),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: rooms.length,
                  itemBuilder: (context, i) => FadeSlideIn(
                    key: ValueKey(rooms[i].id),
                    index: i,
                    child: _RoomTile(
                      room: rooms[i],
                      me: widget.me,
                      query: _query,
                      selected: rooms[i].id == widget.selectedRoomId,
                      onTap: () => widget.onOpen(rooms[i]),
                      onTalk: (name) => _talker.start(context, room: rooms[i], me: widget.me, name: name),
                      onTalkEnd: () => _talker.finish(context),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomTile extends StatelessWidget {
  final ChatRoomModel room;
  final UserModel me;
  final String query;
  final bool selected;
  final VoidCallback onTap;
  final void Function(String name) onTalk;
  final VoidCallback onTalkEnd;
  const _RoomTile({
    required this.room,
    required this.me,
    required this.query,
    required this.selected,
    required this.onTap,
    required this.onTalk,
    required this.onTalkEnd,
  });

  @override
  Widget build(BuildContext context) {
    if (room.isGroup) return _tile(context, null);
    final otherId = room.participants.firstWhere((id) => id != me.uid, orElse: () => '');
    return StreamBuilder<UserModel?>(
      stream: UserService.instance.userStream(otherId),
      initialData: UserService.instance.cached(otherId),
      builder: (context, snap) => _tile(context, snap.data),
    );
  }

  Widget _tile(BuildContext context, UserModel? other) {
    final name = room.isGroup ? (room.groupName ?? 'Group') : (other == null ? '…' : Nicknames.instance.name(other.uid, other.name));
    if (query.isNotEmpty && !name.toLowerCase().contains(query)) return const SizedBox.shrink();
    final unread = room.unreadCount[me.uid] ?? 0;
    final mineLast = room.lastMessageSenderId == me.uid;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      // Hold to talk (walkie-talkie), let go to send.
      child: GestureDetector(
        onLongPressStart: (_) => onTalk(name),
        onLongPressEnd: (_) => onTalkEnd(),
        onLongPressCancel: onTalkEnd,
        child: Material(
          color: selected ? AppColors.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: other == null
                        ? null
                        : () => openProfile(
                            context,
                            me: me,
                            person: other,
                            onMessage: (_) {
                              Navigator.of(context).pop();
                              onTap();
                            },
                          ),
                    child: Hero(
                      tag: 'avatar-${room.id}',
                      child: Avatar(name: name, photoUrl: other?.photoUrl ?? '', size: 52, online: other?.isOnline ?? false, group: room.isGroup),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.body(16, weight: FontWeight.w700),
                              ),
                            ),
                            Text(
                              _time(room.lastMessageTime),
                              style: AppTheme.body(
                                12,
                                color: unread > 0 ? AppColors.primary : AppColors.textFaint,
                                weight: unread > 0 ? FontWeight.w700 : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            if (mineLast)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.done_rounded, size: 15, color: AppColors.textFaint),
                              ),
                            Expanded(
                              child: Text(
                                other?.isBusy == true ? 'On a call' : (room.lastMessage.isEmpty ? 'No messages yet' : room.lastMessage),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.body(14, color: unread > 0 ? AppColors.text : AppColors.textMuted),
                              ),
                            ),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                              child: unread > 0
                                  ? Container(
                                      key: ValueKey(unread),
                                      margin: const EdgeInsets.only(left: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(10)),
                                      child: Text(
                                        unread > 99 ? '99+' : '$unread',
                                        style: AppTheme.body(11.5, weight: FontWeight.w800, color: AppColors.textDark),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
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
    );
  }

  static String _time(DateTime t) {
    final now = DateTime.now();
    if (DateUtils.isSameDay(t, now)) return DateFormat.jm().format(t);
    if (now.difference(t).inDays < 7) return DateFormat.E().format(t);
    return DateFormat.MMMd().format(t);
  }
}
