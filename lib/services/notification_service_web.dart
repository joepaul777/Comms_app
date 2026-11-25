import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
/// While Comms is open in a tab, it watches your chats itself and shows the browser's
/// own notifications. Once notifications are allowed, the browser also gets web push
/// (push_sw.js), so messages and calls arrive with Comms closed, including on an
/// iPhone with Comms added to the Home Screen. Your phone still gets its own pushes.
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

  /// Identifies Comms to the browsers' push services (the private half is on the server).
  static const _vapidPublicKey = 'BFFlmdibS8j3gKojzELdBKQ3nWIwNyaE9ALd57rVqp55hBPTGKmARlfEBwPJB7ICwYXfr1sEL0OL2sKGEYtYGHY';

  bool _pushActive = false;

  Future<void> initialize() async {
    // A notification tapped while Comms was closed opens it with ?open=chat|<id>.
    final open = Uri.base.queryParameters['open'];
    if (open != null && open.isNotEmpty) {
      _deliverOpen(open);
      try {
        web.window.history.replaceState(null, '', Uri.base.replace(queryParameters: {}).toString().replaceAll('?', ''));
      } catch (_) {}
    }
    if (!pushSupported) return;
    try {
      await web.window.navigator.serviceWorker.register('push_sw.js'.toJS).toDart;
      // A notification tapped while Comms is already open.
      web.window.navigator.serviceWorker.onmessage = ((web.MessageEvent event) {
        final data = event.data;
        if (data is JSObject && data.has('commsOpen')) {
          final open = data.getProperty<JSAny?>('commsOpen'.toJS);
          if (open is JSString) _deliverOpen(open.toDart);
        }
      }).toJS;
    } catch (e) {
      debugPrint('notification worker failed: $e');
    }
  }

  void _deliverOpen(String open) {
    final parts = open.split('|');
    if (parts.length < 2 || parts[1].isEmpty) return;
    _deliver(NotificationTap(parts[0], parts[1], ''));
  }

  /// True when this browser can get notifications with Comms closed.
  bool get pushSupported {
    try {
      return web.window.navigator.has('serviceWorker') && web.window.has('PushManager') && _supported;
    } catch (_) {
      return false;
    }
  }

  /// An iPhone or iPad (iPads say they are Macs, but have touch screens).
  bool get isApplePhone {
    final ua = web.window.navigator.userAgent;
    return ua.contains('iPhone') || ua.contains('iPad') || (ua.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1);
  }

  /// Opened from the Home Screen (as an app) rather than in a browser tab.
  bool get isInstalled {
    try {
      if (web.window.matchMedia('(display-mode: standalone)').matches) return true;
      final standalone = web.window.navigator.getProperty<JSAny?>('standalone'.toJS);
      return standalone is JSBoolean && standalone.toDart;
    } catch (_) {
      return false;
    }
  }

  /// Turns on web push for this browser when notifications are allowed.
  Future<void> saveDeviceToken() async {
    if (await permitted()) await _subscribe();
  }

  static String _browserId(String endpoint) {
    var hash = 0x811c9dc5;
    for (final unit in endpoint.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 'w${hash.toRadixString(16)}';
  }

  static String _b64url(JSArrayBuffer? buffer) =>
      buffer == null ? '' : base64Url.encode(buffer.toDart.asUint8List()).replaceAll('=', '');

  static Uint8List _keyBytes(String b64url) => base64Url.decode(b64url.padRight((b64url.length + 3) ~/ 4 * 4, '='));

  DocumentReference<Map<String, dynamic>>? _privateDoc() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid == null ? null : FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('data');
  }

  Future<web.PushSubscription?> _currentSubscription() async {
    try {
      final reg = await web.window.navigator.serviceWorker.ready.toDart;
      return await reg.pushManager.getSubscription().toDart;
    } catch (_) {
      return null;
    }
  }

  Future<void> _subscribe() async {
    final doc = _privateDoc();
    if (!pushSupported || doc == null) return;
    try {
      final reg = await web.window.navigator.serviceWorker.ready.toDart;
      final sub = await reg.pushManager.getSubscription().toDart ??
          await reg.pushManager
              .subscribe(web.PushSubscriptionOptionsInit(userVisibleOnly: true, applicationServerKey: _keyBytes(_vapidPublicKey).toJS))
              .toDart;
      final endpoint = sub.endpoint;
      // Only this person can read their private document (and the Comms server).
      await doc.set({
        'webPush': {
          _browserId(endpoint): {
            'endpoint': endpoint,
            'p256dh': _b64url(sub.getKey('p256dh')),
            'auth': _b64url(sub.getKey('auth')),
            'at': DateTime.now().millisecondsSinceEpoch,
          },
        },
      }, SetOptions(merge: true));
      _pushActive = true;
    } catch (e) {
      debugPrint('web push subscribe failed: $e');
    }
  }

  /// Signing out of the browser stops its notifications, but not the phone's.
  Future<void> forgetDevice() async {
    await _rooms?.cancel();
    _rooms = null;
    _watching = null;
    final sub = await _currentSubscription();
    if (sub != null) {
      try {
        await _privateDoc()?.update({'webPush.${_browserId(sub.endpoint)}': FieldValue.delete()});
      } catch (_) {}
      try {
        await sub.unsubscribe().toDart;
      } catch (_) {}
    }
    _pushActive = false;
  }

  bool get _supported {
    try {
      return web.window.has('Notification');
    } catch (_) {
      return false;
    }
  }

  Future<bool> permitted() async => _supported && web.Notification.permission == 'granted';

  /// 'granted', 'denied', 'default' (not asked yet) or 'unsupported'.
  Future<String> permissionState() async => _supported ? web.Notification.permission : 'unsupported';

  /// Must be called straight from a tap (iPhones only ask then).
  Future<bool> askPermission() async {
    if (!_supported) return false;
    try {
      final answer = await web.Notification.requestPermission().toDart;
      final granted = answer.toDart == 'granted';
      if (granted) await _subscribe();
      return granted;
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
    if (!_supported || web.Notification.permission != 'granted' || _pushActive) return;
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
