import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import '../models/call_model.dart';
import '../models/chat_room_model.dart';
import 'chat_service.dart';
import 'local_prefs.dart';
import 'notification_tap.dart';
import 'user_service.dart';

export 'notification_tap.dart';

/// Notifications in the browser.
///
/// There are no pushes here: while Comms is open in a tab, it watches your chats
/// itself and shows the browser's own notification for a new message or a call.
/// Your phone still gets the pushes as usual.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();
  factory NotificationService() => instance;

  /// The chat on screen right now, so its messages don't pop up as notifications.
  static String? activeChatRoomId;

  final StreamController<NotificationTap> _taps = StreamController<NotificationTap>.broadcast();
  NotificationTap? _pendingTap;

  Stream<NotificationTap> get taps => _taps.stream;

  NotificationTap? takePendingTap() {
    final tap = _pendingTap;
    _pendingTap = null;
    return tap;
  }

  void Function(Map<String, dynamic> data)? onForegroundChat;

  StreamSubscription<List<ChatRoomModel>>? _rooms;
  String? _watching;
  final Map<String, DateTime> _seen = {};
  final Map<String, web.Notification> _shown = {};

  Future<void> initialize() async {}

  /// Phones register for pushes; a browser tab does not.
  Future<void> saveDeviceToken() async {}

  /// Signing out of the browser must not stop the phone's notifications.
  Future<void> forgetDevice() async {
    await _rooms?.cancel();
    _rooms = null;
    _watching = null;
  }

  bool get _supported {
    try {
      return web.window.has('Notification');
    } catch (_) {
      return false;
    }
  }

  Future<bool> permitted() async => _supported && web.Notification.permission == 'granted';

  Future<bool> askPermission() async {
    if (!_supported) return false;
    try {
      final answer = await web.Notification.requestPermission().toDart;
      return answer.toDart == 'granted';
    } catch (_) {
      return false;
    }
  }

  bool get _tabHidden => web.document.hidden;

  /// Watches [uid]'s chats and notifies about new messages from other people.
  void startWatching(String uid) {
    if (_watching == uid) return;
    _rooms?.cancel();
    _watching = uid;
    _seen.clear();
    var first = true;
    _rooms = ChatService.instance.chatRooms(uid).listen((rooms) {
      for (final room in rooms) {
        final before = _seen[room.id];
        _seen[room.id] = room.lastMessageTime;
        // The first look only learns where every chat is up to.
        if (first || before == null || !room.lastMessageTime.isAfter(before)) continue;
        if (room.lastMessageSenderId.isEmpty || room.lastMessageSenderId == uid) continue;
        if (!_tabHidden && room.id == activeChatRoomId) continue;
        _notifyChat(room);
      }
      first = false;
    }, onError: (Object e) => debugPrint('notification watch failed: $e'));
  }

  String _nameOf(String uid, String fallback) => Nicknames.instance.name(uid, UserService.instance.cached(uid)?.name ?? fallback);

  void _notifyChat(ChatRoomModel room) {
    final sender = _nameOf(room.lastMessageSenderId, 'Someone');
    final text = room.lastMessage.isEmpty ? 'New message' : room.lastMessage;
    _show(
      'chat:${room.id}',
      room.isGroup ? (room.groupName ?? 'Group') : sender,
      room.isGroup ? '$sender: $text' : text,
      () => _deliver(NotificationTap('chat', room.id, '')),
    );
  }

  Future<void> showRinging(CallModel call) async {
    if (!_tabHidden) return;
    _show(
      'call:${call.id}',
      _nameOf(call.callerId, call.callerName),
      call.isVideo ? 'Incoming video call' : 'Incoming voice call',
      () {},
      stay: true,
    );
  }

  Future<void> showMissedCall(CallModel call) async {
    if (!_tabHidden) return;
    _show(
      'missed:${call.id}',
      'Missed ${call.isVideo ? 'video' : 'voice'} call',
      _nameOf(call.callerId, call.callerName),
      () => _deliver(NotificationTap('calls', call.id, '')),
    );
  }

  void _show(String tag, String title, String body, VoidCallback onTap, {bool stay = false}) {
    if (!_supported || web.Notification.permission != 'granted') return;
    try {
      _shown.remove(tag)?.close();
      final note = web.Notification(
        title,
        web.NotificationOptions(body: body, icon: 'icons/Icon-192.png', tag: tag, requireInteraction: stay),
      );
      note.onclick = ((web.Event _) {
        web.window.focus();
        note.close();
        _shown.remove(tag);
        onTap();
      }).toJS;
      _shown[tag] = note;
    } catch (e) {
      debugPrint('notification failed: $e');
    }
  }

  void _close(String tag) {
    try {
      _shown.remove(tag)?.close();
    } catch (_) {}
  }

  void _deliver(NotificationTap tap) {
    if (_taps.hasListener) {
      _taps.add(tap);
    } else {
      _pendingTap = tap;
    }
  }

  Future<void> cancelCall(String callId) async => _close('call:$callId');

  Future<void> cancelChat(String roomId) async => _close('chat:$roomId');
}
