import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import '../../config.dart';
import '../../models/call_model.dart';
import '../../models/chat_room_model.dart';
import '../../models/message_model.dart';
import '../../models/user_model.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/media_service.dart';
import '../../services/notification_service.dart';
import '../../services/rate_limiter.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/composer.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/ui.dart';
import 'group_info_sheet.dart';

class _Upload {
  final String id;
  final MessageType type;
  final String name;
  final CancelToken cancel = CancelToken();
  double progress = 0;
  String? error;
  _Upload(this.id, this.type, this.name);
}

class ChatScreen extends StatefulWidget {
  final ChatRoomModel room;
  final UserModel me;

  /// When shown beside the chat list on a wide screen there is no back button.
  final bool embedded;
  final VoidCallback? onClosed;

  const ChatScreen({super.key, required this.room, required this.me, this.embedded = false, this.onClosed});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final ChatService _chat = ChatService.instance;
  final ScrollController _scroll = ScrollController();
  final List<_Upload> _uploads = [];
  late ChatRoomModel _room = widget.room;
  StreamSubscription? _roomSub;
  MessageModel? _replyTo;
  MessageModel? _editing;

  // Messages already on screen, so only new ones animate in.
  final Set<String> _known = {};
  bool _primed = false;
  final Set<String> _removing = {};

  // Typing: when this phone last saw each person's typing value change.
  final Map<String, (int, DateTime)> _typingSeen = {};
  Timer? _typingTimer;
  static const _typingShowsFor = Duration(seconds: 7);

  // Newest message from someone else this phone has already marked as seen.
  int _markedSeen = 0;

  // Jump-to-latest button.
  bool _scrolledUp = false;
  int _unseen = 0;

  String? get _otherId => _room.isGroup ? null : _room.participants.firstWhere((id) => id != widget.me.uid, orElse: () => '');

  @override
  void initState() {
    super.initState();
    NotificationService.activeChatRoomId = _room.id;
    NotificationService.instance.cancelChat(_room.id);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _listenToRoom();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app with this chat open counts as seeing it.
    if (state == AppLifecycleState.resumed && mounted) {
      NotificationService.instance.cancelChat(_room.id);
      setState(() {});
    }
  }

  void _maybeMarkSeen(List<MessageModel> messages) {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    final newest = messages.where((m) => m.senderId != widget.me.uid && !m.pending).firstOrNull;
    if (newest == null) return;
    final ts = newest.timestamp.millisecondsSinceEpoch;
    if (ts <= _markedSeen || ts <= (_room.readUpTo[widget.me.uid] ?? 0)) return;
    _markedSeen = ts;
    _chat.markSeen(_room.id, widget.me.uid, ts);
  }

  Receipt _receiptFor(MessageModel m, List<String> others) {
    if (m.senderId != widget.me.uid || m.type == MessageType.system) return Receipt.none;
    if (m.pending) return Receipt.sending;
    final ts = m.timestamp.millisecondsSinceEpoch;
    final seen = others.where((o) => (_room.readUpTo[o] ?? 0) >= ts).length;
    if (seen == 0 || others.isEmpty) return Receipt.sent;
    return seen == others.length ? Receipt.seen : Receipt.seenBySome;
  }

  Future<void> _react(MessageModel m, String? emoji) async {
    try {
      await _chat.react(_room.id, m.id, widget.me.uid, emoji);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not add the reaction', error: true);
    }
  }

  void _listenToRoom() {
    _roomSub = _chat.chatRoom(_room.id).listen((room) {
      if (!mounted) return;
      if (room == null) {
        _close();
        return;
      }
      _trackTyping(room);
      setState(() => _room = room);
      _chat.markRead(room, widget.me.uid);
    });
  }

  void _onScroll() {
    final up = _scroll.hasClients && _scroll.offset > 400;
    if (up != _scrolledUp) {
      setState(() {
        _scrolledUp = up;
        if (!up) _unseen = 0;
      });
    }
  }

  void _jumpToLatest() {
    _scroll.animateTo(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
  }

  /// Works from this phone's own clock, so phones with different times still agree.
  void _trackTyping(ChatRoomModel room) {
    final now = DateTime.now();
    _typingSeen.removeWhere((uid, _) => !room.typing.containsKey(uid));
    room.typing.forEach((uid, value) {
      if (uid == widget.me.uid) return;
      final seen = _typingSeen[uid];
      if (seen == null || seen.$1 != value) _typingSeen[uid] = (value, now);
    });
    _scheduleTypingRefresh();
  }

  void _scheduleTypingRefresh() {
    _typingTimer?.cancel();
    if (_typingSeen.isEmpty) return;
    final now = DateTime.now();
    final next = _typingSeen.values
        .map((e) => e.$2.add(_typingShowsFor))
        .where((t) => t.isAfter(now))
        .fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    if (next == null) return;
    _typingTimer = Timer(next.difference(now) + const Duration(milliseconds: 50), () {
      if (mounted) setState(() {});
      _scheduleTypingRefresh();
    });
  }

  List<String> get _typers {
    final now = DateTime.now();
    return [
      for (final e in _typingSeen.entries)
        if (now.difference(e.value.$2) < _typingShowsFor && _room.participants.contains(e.key)) e.key,
    ];
  }

  String _typingLabel(List<String> typers) {
    if (!_room.isGroup) return 'typing…';
    final names = typers.map((id) => (UserService.instance.cached(id)?.name ?? 'Someone').split(' ').first).toList();
    return names.length == 1 ? '${names.first} is typing…' : '${names.length} people are typing…';
  }

  @override
  void didUpdateWidget(covariant ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.room.id != widget.room.id) {
      _roomSub?.cancel();
      _room = widget.room;
      _replyTo = null;
      _known.clear();
      _primed = false;
      _removing.clear();
      _typingSeen.clear();
      _unseen = 0;
      _markedSeen = 0;
      NotificationService.activeChatRoomId = _room.id;
      _listenToRoom();
    }
  }

  @override
  void dispose() {
    if (NotificationService.activeChatRoomId == _room.id) NotificationService.activeChatRoomId = null;
    WidgetsBinding.instance.removeObserver(this);
    _roomSub?.cancel();
    _typingTimer?.cancel();
    _scroll.dispose();
    for (final u in _uploads) {
      u.cancel.cancel();
    }
    super.dispose();
  }

  void _close() {
    if (widget.embedded) {
      widget.onClosed?.call();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<bool> _sendText(String text) async {
    try {
      final reply = _replyTo;
      setState(() => _replyTo = null);
      await _chat.sendMessage(room: _room, sender: widget.me, text: text, replyTo: reply);
      return true;
    } on RateLimitException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
      return false;
    } catch (e) {
      if (mounted) showSnack(context, 'Message not sent. Check your connection.', error: true);
      return false;
    }
  }

  void _attach() {
    showModalBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: 12,
            runSpacing: 16,
            children: [
              _AttachOption(icon: Icons.photo_library_rounded, label: 'Photo', onTap: () => _pick(sheet, ImageSource.gallery, false)),
              _AttachOption(icon: Icons.video_library_rounded, label: 'Video', onTap: () => _pick(sheet, ImageSource.gallery, true)),
              _AttachOption(icon: Icons.photo_camera_rounded, label: 'Camera', onTap: () => _pick(sheet, ImageSource.camera, false)),
              _AttachOption(icon: Icons.videocam_rounded, label: 'Record', onTap: () => _pick(sheet, ImageSource.camera, true)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext sheet, ImageSource source, bool video) async {
    Navigator.pop(sheet);
    final picker = ImagePicker();
    final picked = video
        ? await picker.pickVideo(source: source, maxDuration: const Duration(minutes: 5))
        : await picker.pickImage(source: source, imageQuality: 82, maxWidth: 2048, maxHeight: 2048);
    if (picked == null) return;
    final file = File(picked.path);
    if (await file.length() > AppConfig.maxUploadBytes) {
      if (mounted) showSnack(context, 'That file is too big. Files can be up to 95 MB.', error: true);
      return;
    }
    await _sendMedia(file, video ? MessageType.video : MessageType.image, picked.name);
  }

  Future<void> _sendVoice(File file, Duration length) =>
      _sendMedia(file, MessageType.audio, 'voice.m4a', durationMs: length.inMilliseconds);

  Future<void> _sendMedia(File file, MessageType type, String name, {int? durationMs}) async {
    try {
      _chat.checkCanSend();
    } on RateLimitException catch (e) {
      showSnack(context, e.message, error: true);
      return;
    }
    final id = _chat.newId();
    final ext = MediaService.extensionOf(name, type);
    final fileName = '$id.$ext';
    final upload = _Upload(id, type, fileName);
    setState(() => _uploads.add(upload));
    final reply = _replyTo;
    setState(() => _replyTo = null);
    try {
      final local = await MediaService.instance.keepCopy(file, id, ext);
      final url = await MediaService.instance.upload(local, fileName, cancel: upload.cancel, onProgress: (p) {
        if (mounted) setState(() => upload.progress = p);
      });
      final size = await local.length();
      Future<void> send() => _chat.sendMessage(
            room: _room,
            sender: widget.me,
            text: '',
            type: type,
            id: id,
            mediaUrl: url,
            mediaName: fileName,
            mediaSize: size,
            durationMs: durationMs,
            replyTo: reply,
          );
      try {
        await send();
      } on RateLimitException catch (e) {
        // The file is already uploaded; wait out the limit and send it.
        await Future.delayed(e.wait + const Duration(milliseconds: 300));
        await send();
      }
      if (mounted) setState(() => _uploads.remove(upload));
    } on MediaTooLargeException catch (e) {
      if (mounted) setState(() => upload.error = e.toString());
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        if (mounted) setState(() => _uploads.remove(upload));
      } else if (mounted) {
        setState(() => upload.error = 'Upload failed');
      }
    } catch (e) {
      if (mounted) setState(() => upload.error = 'Could not send');
    }
  }

  Future<bool> _saveEdit(String text) async {
    final m = _editing;
    if (m == null) return false;
    if (!m.canEdit(widget.me.uid, AppConfig.editWindow + const Duration(seconds: 30))) {
      showSnack(context, 'Messages can only be edited for 15 minutes', error: true);
      setState(() => _editing = null);
      return false;
    }
    try {
      await _chat.editMessage(_room, m, text);
      if (mounted) setState(() => _editing = null);
      return true;
    } catch (_) {
      if (mounted) showSnack(context, 'Could not edit the message', error: true);
      return false;
    }
  }

  Future<void> _delete(MessageModel m) async {
    try {
      await _chat.deleteMessage(_room.id, m.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _removing.remove(m.id));
      showSnack(context, 'Could not delete the message', error: true);
    }
  }

  Future<void> _call(UserModel? other, CallType type) async {
    if (other == null) return;
    final error = await CallService.instance.startCall(me: _chat.me ?? widget.me, other: other, type: type);
    if (error != null && mounted) showSnack(context, error, error: true);
  }

  Future<void> _deleteChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: const Text('All messages in this chat will be deleted for everyone in it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete', style: TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _chat.deleteChat(_room.id);
      _close();
    } catch (_) {
      if (mounted) showSnack(context, 'Could not delete the chat', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final otherId = _otherId ?? '';
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: otherId.isEmpty
                ? _header(null)
                : StreamBuilder<UserModel?>(
                    stream: UserService.instance.userStream(otherId),
                    initialData: UserService.instance.cached(otherId),
                    builder: (_, snap) => _header(snap.data),
                  ),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0.9, -1.1),
                  radius: 1.4,
                  colors: [Color(0x14FACC15), Color(0x00000000)],
                ),
              ),
              child: StreamBuilder<List<MessageModel>>(
                stream: _chat.messages(_room.id),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const EmptyState(icon: Icons.cloud_off_rounded, title: 'Can\'t load messages', message: 'Check your connection and try again.');
                  }
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final messages = snap.data!;

                  // Anything not seen before arrived just now and gets the pop-in.
                  final fresh = <String>{};
                  if (!_primed) {
                    _known.addAll(messages.map((m) => m.id));
                    _primed = true;
                  } else {
                    for (final m in messages) {
                      if (_known.add(m.id)) {
                        fresh.add(m.id);
                        if (_scrolledUp && m.senderId != widget.me.uid) _unseen++;
                      }
                    }
                  }
                  _removing.retainWhere((id) => messages.any((m) => m.id == id));
                  _maybeMarkSeen(messages);

                  // Where the "Seen" marker goes.
                  final others = _room.participants.where((id) => id != widget.me.uid).toList();
                  String? seenMessageId;
                  List<String> seenBy = const [];
                  final newestTheirs = messages.indexWhere((m) => m.senderId != widget.me.uid && m.type != MessageType.system);
                  final newestMine = messages.indexWhere((m) => m.senderId == widget.me.uid && !m.pending && m.type != MessageType.system);
                  if (newestMine != -1 && (newestTheirs == -1 || newestMine < newestTheirs)) {
                    if (_room.isGroup) {
                      final ts = messages[newestMine].timestamp.millisecondsSinceEpoch;
                      seenBy = others.where((o) => (_room.readUpTo[o] ?? 0) >= ts).toList();
                      if (seenBy.isNotEmpty) seenMessageId = messages[newestMine].id;
                    } else if (others.isNotEmpty) {
                      final upTo = _room.readUpTo[others.first] ?? 0;
                      final i = messages.indexWhere((m) =>
                          m.senderId == widget.me.uid && !m.pending && m.type != MessageType.system && m.timestamp.millisecondsSinceEpoch <= upTo);
                      if (i != -1 && (newestTheirs == -1 || i < newestTheirs)) {
                        seenMessageId = messages[i].id;
                        seenBy = [others.first];
                      }
                    }
                  }
                  final seenAtMs = seenBy.length == 1 ? _room.readAt[seenBy.first] : null;

                  if (messages.isEmpty && _uploads.isEmpty) {
                    return const EmptyState(icon: Icons.waving_hand_rounded, title: 'Say hello', message: 'Messages, photos, videos and voice notes will appear here.');
                  }
                  final positions = <String, int>{
                    for (var i = 0; i < _uploads.length; i++) 'up-${_uploads[_uploads.length - 1 - i].id}': i,
                    for (var i = 0; i < messages.length; i++) messages[i].id: _uploads.length + i,
                  };
                  return Stack(
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.only(bottom: 10, top: 10),
                        itemCount: messages.length + _uploads.length,
                        // Keeps each message's state (a playing voice note, say) when new ones arrive.
                        findChildIndexCallback: (key) => key is ValueKey<String> ? positions[key.value] : null,
                        itemBuilder: (context, i) {
                          if (i < _uploads.length) {
                            final upload = _uploads[_uploads.length - 1 - i];
                            return KeyedSubtree(
                              key: ValueKey('up-${upload.id}'),
                              child: Appear(alignment: Alignment.bottomRight, child: _uploadTile(upload)),
                            );
                          }
                          final index = i - _uploads.length;
                          final m = messages[index];
                          final older = index + 1 < messages.length ? messages[index + 1] : null;
                          final newDay = older == null || !DateUtils.isSameDay(older.timestamp, m.timestamp);
                          final joins = !newDay && older.senderId == m.senderId && older.type != MessageType.system;
                          final mine = m.senderId == widget.me.uid;
                          return KeyedSubtree(
                            key: ValueKey(m.id),
                            child: Column(
                              children: [
                                if (newDay) _DayDivider(date: m.timestamp),
                                MessageBubble(
                                  message: m,
                                  mine: mine,
                                  showSender: _room.isGroup && !joins,
                                  joinsPrevious: joins,
                                  myUid: widget.me.uid,
                                  receipt: _receiptFor(m, others),
                                  onReact: m.type == MessageType.system ? null : (e) => _react(m, e),
                                  onEdit: m.canEdit(widget.me.uid, AppConfig.editWindow)
                                      ? () => setState(() {
                                            _replyTo = null;
                                            _editing = m;
                                          })
                                      : null,
                                  animateIn: fresh.contains(m.id),
                                  removing: _removing.contains(m.id),
                                  onRemoved: () => _delete(m),
                                  onReply: () => setState(() {
                                    _editing = null;
                                    _replyTo = m;
                                  }),
                                  onDelete: mine ? () => setState(() => _removing.add(m.id)) : null,
                                ),
                                if (m.id == seenMessageId)
                                  SeenMarker(
                                    key: ValueKey('seen-${m.id}-${seenBy.length}'),
                                    viewerIds: seenBy,
                                    group: _room.isGroup,
                                    at: seenAtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(seenAtMs),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                      Positioned(
                        right: 14,
                        bottom: 12,
                        child: IgnorePointer(
                          ignoring: !_scrolledUp,
                          child: AnimatedScale(
                            scale: _scrolledUp ? 1 : 0.4,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutBack,
                            child: AnimatedOpacity(
                              opacity: _scrolledUp ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: _JumpButton(unseen: _unseen, onTap: _jumpToLatest),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Builder(builder: (context) {
            final typers = _typers;
            return AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(a), alignment: Alignment.bottomLeft, child: child),
                ),
                child: typers.isEmpty
                    ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                    : Align(
                        key: const ValueKey('typing'),
                        alignment: Alignment.centerLeft,
                        child: TypingBubble(name: _room.isGroup ? _typingLabel(typers) : null),
                      ),
              ),
            );
          }),
          Composer(
            onTyping: (typing) => _chat.setTyping(_room.id, widget.me.uid, typing),
            onSendText: _sendText,
            editing: _editing,
            onCancelEdit: () => setState(() => _editing = null),
            onSaveEdit: _saveEdit,
            onAttach: _attach,
            onSendVoice: _sendVoice,
            replyTo: _replyTo,
            onCancelReply: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _header(UserModel? other) {
    final title = _room.isGroup ? (_room.groupName ?? 'Group') : (other?.name ?? '');
    String subtitle;
    final typers = _typers;
    if (typers.isNotEmpty) {
      subtitle = _typingLabel(typers);
    } else if (_room.isGroup) {
      subtitle = '${_room.participants.length} members';
    } else if (other == null) {
      subtitle = '';
    } else if (other.isBusy) {
      subtitle = 'On a call';
    } else if (other.isOnline) {
      subtitle = 'Online';
    } else {
      subtitle = 'Last seen ${_lastSeen(other.lastSeen)}';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Row(
        children: [
          if (!widget.embedded) IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: _close) else const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _room.isGroup ? () => showGroupInfo(context, _room, widget.me) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(
                  children: [
                    Hero(
                      tag: 'avatar-${_room.id}',
                      child: Avatar(
                        name: title,
                        photoUrl: _room.isGroup ? '' : (other?.photoUrl ?? ''),
                        size: 42,
                        online: other?.isOnline ?? false,
                        group: _room.isGroup,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTheme.display(17, weight: FontWeight.w700)),
                          if (subtitle.isNotEmpty)
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Text(
                                subtitle,
                                key: ValueKey(subtitle),
                                style: AppTheme.body(
                                  12.5,
                                  color: typers.isNotEmpty
                                      ? AppColors.primary
                                      : subtitle == 'Online'
                                          ? AppColors.online
                                          : AppColors.textMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!_room.isGroup) ...[
            CircleIconButton(icon: Icons.call_rounded, onTap: other == null ? null : () => _call(other, CallType.audio), tooltip: 'Voice call'),
            const SizedBox(width: 8),
            CircleIconButton(icon: Icons.videocam_rounded, onTap: other == null ? null : () => _call(other, CallType.video), tooltip: 'Video call'),
          ],
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.bgElevated,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            onSelected: (v) {
              if (v == 'delete') _deleteChat();
              if (v == 'info') showGroupInfo(context, _room, widget.me);
            },
            itemBuilder: (_) => [
              if (_room.isGroup) const PopupMenuItem(value: 'info', child: Text('Group info')),
              if (!_room.isGroup || _room.adminId == widget.me.uid)
                const PopupMenuItem(value: 'delete', child: Text('Delete chat', style: TextStyle(color: AppColors.error))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _uploadTile(_Upload upload) {
    final label = switch (upload.type) {
      MessageType.video => 'Sending video',
      MessageType.audio => 'Sending voice message',
      _ => 'Sending photo',
    };
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(60, 8, 12, 0),
        padding: const EdgeInsets.all(12),
        width: 250,
        decoration: BoxDecoration(
          color: AppColors.bgAlt,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: upload.error == null ? AppColors.primary.withValues(alpha: 0.4) : AppColors.error),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(upload.error == null ? Icons.cloud_upload_rounded : Icons.error_outline_rounded,
                    size: 18, color: upload.error == null ? AppColors.primary : AppColors.error),
                const SizedBox(width: 8),
                Expanded(child: Text(upload.error ?? '$label… ${(upload.progress * 100).round()}%', style: AppTheme.body(13))),
                GestureDetector(
                  onTap: () {
                    upload.cancel.cancel();
                    setState(() => _uploads.remove(upload));
                  },
                  child: const Icon(Icons.close_rounded, size: 18, color: AppColors.textMuted),
                ),
              ],
            ),
            if (upload.error == null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: upload.progress > 0 ? upload.progress : null, minHeight: 5, backgroundColor: AppColors.border),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _lastSeen(DateTime t) {
    final now = DateTime.now();
    if (now.difference(t).inMinutes < 1) return 'just now';
    if (DateUtils.isSameDay(now, t)) return 'today at ${DateFormat.jm().format(t)}';
    if (now.difference(t).inDays < 7) return '${DateFormat.E().format(t)} at ${DateFormat.jm().format(t)}';
    return DateFormat.yMMMd().format(t);
  }
}

class _DayDivider extends StatelessWidget {
  final DateTime date;
  const _DayDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final label = DateUtils.isSameDay(date, now)
        ? 'Today'
        : DateUtils.isSameDay(date, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : DateFormat.yMMMMd().format(date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: AppColors.bgAlt, borderRadius: BorderRadius.circular(12)),
          child: Text(label, style: AppTheme.body(12, weight: FontWeight.w600, color: AppColors.textMuted)),
        ),
      ),
    );
  }
}

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AttachOption({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
              ),
              child: Icon(icon, color: AppColors.primary, size: 28),
            ),
            const SizedBox(height: 8),
            Text(label, style: AppTheme.body(13, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}

class _JumpButton extends StatelessWidget {
  final int unseen;
  final VoidCallback onTap;
  const _JumpButton({required this.unseen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TapScale(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.bgElevated,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4))],
            ),
            child: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.primary, size: 28),
          ),
          if (unseen > 0)
            Positioned(
              top: -6,
              right: -4,
              child: TweenAnimationBuilder<double>(
                key: ValueKey(unseen),
                tween: Tween(begin: 1.4, end: 1),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  constraints: const BoxConstraints(minWidth: 20),
                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    unseen > 99 ? '99+' : '$unseen',
                    textAlign: TextAlign.center,
                    style: AppTheme.body(11, weight: FontWeight.w700, color: AppColors.textDark),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
