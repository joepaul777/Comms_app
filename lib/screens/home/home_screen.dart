import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../../models/chat_room_model.dart';
import '../../models/user_model.dart';
import '../../services/assistant_service.dart';
import '../../services/call_service.dart';
import '../../services/rate_limiter.dart';
import '../../services/chat_service.dart';
import '../../services/e2e_service.dart';
import '../../services/local_prefs.dart';
import '../../services/notification_service.dart';
import '../../services/update_service.dart';
import '../../services/user_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/ui.dart';
import '../call/call_history_screen.dart';
import '../call/call_screen.dart';
import '../chat/chat_list_screen.dart';
import '../chat/chat_screen.dart';
import '../contacts/contacts_screen.dart';
import '../profile/profile_screen.dart';
import '../update/update_sheet.dart';

class HomeScreen extends StatefulWidget {
  final String uid;
  const HomeScreen({super.key, required this.uid});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Tab {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _Tab(this.icon, this.activeIcon, this.label);
}

const _tabs = [
  _Tab(Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chats'),
  _Tab(Icons.call_outlined, Icons.call_rounded, 'Calls'),
  _Tab(Icons.people_outline_rounded, Icons.people_rounded, 'People'),
  _Tab(Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
];

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final CallService _calls = CallService.instance;
  StreamSubscription? _meSub;
  StreamSubscription? _incomingSub;
  StreamSubscription? _tapSub;
  StreamSubscription? _assistantSub;
  UserModel? _me;
  int _tab = 0;
  ChatRoomModel? _openRoom; // the chat shown on the right on wide screens
  bool _callScreenOpen = false;
  bool _askedAboutUpdate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Start loading this phone's encryption key straight away; chats wait for it.
    E2E.instance.load(widget.uid).catchError((Object e) => debugPrint('e2e load failed: $e'));
    _meSub = UserService.instance.userStream(widget.uid).listen((me) {
      if (me == null) return;
      ChatService.instance.me = me;
      final first = _me == null;
      final old = _me;
      // The profile is rewritten on every message sent (spam limits); only redraw when
      // something on screen actually changed.
      final changed = old == null ||
          old.name != me.name ||
          old.photoUrl != me.photoUrl ||
          old.email != me.email ||
          old.contacts.length != me.contacts.length ||
          !old.contacts.toSet().containsAll(me.contacts);
      _me = me;
      if (changed) setState(() {});
      if (first) _onReady();
    });
    _calls.addListener(_onCallChange);
    Nicknames.instance.addListener(_namesChanged);
  }

  void _onReady() {
    UserService.instance.setOnline(widget.uid, true);
    UserService.instance.movePrivateData(widget.uid);
    _setUpEncryption();
    NotificationService.instance.saveDeviceToken();
    _calls.cleanupStale(widget.uid);
    _incomingSub = _calls.incomingCalls(widget.uid).listen((ringing) async {
      for (final call in ringing) {
        await _calls.handleIncoming(call, widget.uid);
      }
    });
    _tapSub = NotificationService.instance.taps.listen(_handleTap);
    final pending = NotificationService.instance.takePendingTap();
    if (pending != null) _handleTap(pending);
    Future.delayed(const Duration(seconds: 3), _offerUpdate);
    _assistantSub = AssistantService.instance.requests.listen(_handleAssistant);
    AssistantService.instance.takePending().then((r) {
      if (r != null) _handleAssistant(r);
    });
  }

  /// Publishes this phone's encryption key, so people can send it messages.
  Future<void> _setUpEncryption() async {
    try {
      await E2E.instance.load(widget.uid);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not set up encryption on this phone', error: true);
      return;
    }
    final mine = E2E.instance.publicKey;
    final me = await UserService.instance.getUser(widget.uid, fresh: true).catchError((_) => null);
    if (mine == null || me == null || !mounted || me.publicKey == mine) return;
    // First time, or a fresh install / new phone: this phone takes over.
    if (me.publicKey == null || E2E.instance.createdNow) {
      await UserService.instance.setPublicKey(widget.uid, mine);
      return;
    }
    // Comms was set up on another phone since this one was last used.
    final useHere = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        title: const Text('Use Comms on this phone?'),
        content: const Text(
          'Your account was set up on another phone, so new messages are being locked for that phone. '
          'Switch them to this phone? Messages sent to the other phone can only be read there.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now', style: TextStyle(color: AppColors.textMuted))),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Use this phone')),
        ],
      ),
    );
    if (useHere == true) await UserService.instance.setPublicKey(widget.uid, mine);
  }

  /// JACE asked to send a message. Sends straight away when it is clear who it is for,
  /// otherwise asks which person was meant.
  Future<void> _handleAssistant(AssistantRequest request) async {
    final me = _me;
    if (me == null || !mounted) return;
    final assistant = AssistantService.instance;
    final ranked = await assistant.rank(request.name, await assistant.people(me));
    if (!mounted) return;
    if (ranked.isEmpty) {
      showSnack(context, 'JACE: you have no one to message on Comms yet', error: true);
      return;
    }
    UserModel? to;
    if (AssistantService.isSure(ranked)) {
      to = ranked.first.user;
    } else {
      to = await _askWho(request, ranked.take(6).toList());
      if (to == null) return;
      await assistant.learn(request.name, to.uid);
    }
    await _sendFor(me, to, request.text);
  }

  Future<void> _sendFor(UserModel me, UserModel to, String text) async {
    try {
      final room = await ChatService.instance.getOrCreateDirectChat(me.uid, to.uid);
      if (text.isNotEmpty) {
        await ChatService.instance.sendMessage(room: room, sender: me, text: text);
      }
      _openChat(room);
      if (mounted && text.isNotEmpty) showSnack(context, 'JACE sent your message to ${to.name}');
    } on RateLimitException catch (e) {
      if (mounted) showSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not send. Check your connection.', error: true);
    }
  }

  Future<UserModel?> _askWho(AssistantRequest request, List<NameMatch> options) {
    return showModalBottomSheet<UserModel>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Who did you mean?', style: AppTheme.display(20, weight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                'JACE heard "${request.name}". Pick the person and Comms will remember next time.',
                style: AppTheme.body(13.5, color: AppColors.textMuted),
              ),
              if (request.text.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.bgAlt, borderRadius: BorderRadius.circular(14)),
                  child: Text('"${request.text}"', style: AppTheme.body(14.5)),
                ),
              ],
              const SizedBox(height: 8),
              for (final option in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Avatar(name: option.user.name, photoUrl: option.user.photoUrl, size: 42),
                  title: Text(option.user.name),
                  subtitle: Text(option.user.email, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.send_rounded, color: AppColors.primary),
                  onTap: () => Navigator.pop(sheet, option.user),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _offerUpdate() async {
    if (_askedAboutUpdate || !mounted) return;
    _askedAboutUpdate = true;
    final release = await UpdateService.newerRelease();
    if (release != null && mounted && !_calls.isActive) showUpdateSheet(context, release);
  }

  Future<void> _handleTap(NotificationTap tap) async {
    if (tap.type == 'chat') {
      final snap = await FirebaseFirestore.instance.collection('chatRooms').doc(tap.id).get().catchError((_) => throw Exception());
      if (snap.exists && mounted) _openChat(ChatRoomModel.fromMap(snap.data()!));
    } else if (tap.type == 'calls') {
      setState(() => _tab = 1);
    } else if (tap.type == 'call') {
      final call = await _calls.getCall(tap.id);
      if (call == null) return;
      final showing = await _calls.handleIncoming(call, widget.uid);
      if (showing && tap.action == 'answer') await _calls.accept();
      if (!showing && mounted) setState(() => _tab = 1);
    }
  }

  void _onCallChange() {
    if (_calls.isActive && !_callScreenOpen) {
      _callScreenOpen = true;
      navigatorKey.currentState
          ?.push(PageRouteBuilder(
            fullscreenDialog: true,
            transitionDuration: const Duration(milliseconds: 350),
            pageBuilder: (_, _, _) => const CallScreen(),
            transitionsBuilder: (_, a, _, child) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
            ),
          ))
          .whenComplete(() => _callScreenOpen = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      UserService.instance.setOnline(widget.uid, true);
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      UserService.instance.setOnline(widget.uid, false);
    }
  }

  /// A nickname was changed: show it straight away.
  void _namesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _calls.removeListener(_onCallChange);
    Nicknames.instance.removeListener(_namesChanged);
    _meSub?.cancel();
    _incomingSub?.cancel();
    _tapSub?.cancel();
    _assistantSub?.cancel();
    super.dispose();
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= 900;

  void _openChat(ChatRoomModel room) {
    final me = _me;
    if (me == null) return;
    if (_wide) {
      setState(() {
        _openRoom = room;
        _tab = 0;
      });
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(room: room, me: me)));
    }
  }

  Future<void> _messageUser(UserModel other) async {
    final me = _me;
    if (me == null) return;
    try {
      final room = await ChatService.instance.getOrCreateDirectChat(me.uid, other.uid);
      _openChat(room);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not open the chat. Check your connection.', error: true);
    }
  }

  Widget _tabBody(UserModel me) {
    switch (_tab) {
      case 1:
        return CallHistoryScreen(me: me);
      case 2:
        return ContactsScreen(me: me, onMessage: _messageUser);
      case 3:
        return ProfileScreen(me: me);
      default:
        return ChatListScreen(
          me: me,
          selectedRoomId: _wide ? _openRoom?.id : null,
          onOpen: _openChat,
          onFindPeople: () => setState(() => _tab = 2),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (_wide) {
      return Scaffold(
        body: Row(
          children: [
            _SideRail(index: _tab, onSelect: (i) => setState(() => _tab = i)),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 400,
              child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: KeyedSubtree(key: ValueKey(_tab), child: _tabBody(me))),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _openRoom == null
                  ? const EmptyState(icon: Icons.forum_rounded, title: 'Pick a chat', message: 'Choose a conversation on the left, or find someone in People.')
                  : ChatScreen(key: ValueKey(_openRoom!.id), room: _openRoom!, me: me, embedded: true, onClosed: () => setState(() => _openRoom = null)),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        child: KeyedSubtree(key: ValueKey(_tab), child: _tabBody(me)),
      ),
      bottomNavigationBar: _BottomBar(index: _tab, onSelect: (i) => setState(() => _tab = i)),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _BottomBar({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            height: 66,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.bgAlt.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: AppColors.border),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 8))],
            ),
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final selected = i == index;
                final tab = _tabs[i];
                return Expanded(
                  flex: selected ? 5 : 3,
                  child: TapScale(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(color: selected ? AppColors.primary : Colors.transparent, borderRadius: BorderRadius.circular(20)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(selected ? tab.activeIcon : tab.icon, color: selected ? AppColors.textDark : AppColors.textMuted, size: 23),
                          if (selected)
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 7),
                                child: Text(tab.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: AppTheme.body(13.5, weight: FontWeight.w700, color: AppColors.textDark)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideRail extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _SideRail({required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        width: 84,
        child: Column(
          children: [
            const SizedBox(height: 16),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(16)),
              child: Center(child: Text('CO.', style: AppTheme.display(16, weight: FontWeight.w900, color: AppColors.textDark))),
            ),
            const SizedBox(height: 28),
            for (var i = 0; i < _tabs.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Tooltip(
                  message: _tabs[i].label,
                  child: TapScale(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 56,
                      height: 52,
                      decoration: BoxDecoration(color: i == index ? AppColors.primary : Colors.transparent, borderRadius: BorderRadius.circular(18)),
                      child: Icon(i == index ? _tabs[i].activeIcon : _tabs[i].icon, color: i == index ? AppColors.textDark : AppColors.textMuted),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
