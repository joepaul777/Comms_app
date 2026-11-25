import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/call_model.dart';
import '../models/chat_room_model.dart';
import 'chat_service.dart';
import 'user_service.dart';
import 'e2e_service.dart';
import 'media_service.dart';
import 'push_api.dart';
import 'local_prefs.dart';
import 'walkie_service.dart';
import 'call_service.dart';
import 'notification_tap.dart';

export 'notification_tap.dart';

const _messageChannel = AndroidNotificationChannel(
  'comms_messages',
  'Messages',
  description: 'New chat messages',
  importance: Importance.high,
);

final _callChannel = AndroidNotificationChannel(
  'comms_calls_v4',
  'Incoming calls',
  description: 'Rings when someone calls you',
  importance: Importance.max,
  sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
  enableVibration: true,
  vibrationPattern: Int64List.fromList([0, 900, 600, 900, 600]),
);

const _missedChannel = AndroidNotificationChannel(
  'comms_missed_calls',
  'Missed calls',
  description: 'Calls you did not answer',
  importance: Importance.high,
);


/// The running app listens here, so a push picked up by the background handler can
/// be passed to it. Only the app knows which chat is on screen.
const _mainPortName = 'comms_main_isolate';

/// The same number for the same text in every part of the app (the background handler
/// and the app itself), so a notification shown by one can be cleared by the other.
int stableNotificationId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

int callNotificationId(String callId) => stableNotificationId('call:$callId');
int chatNotificationId(String roomId) => stableNotificationId('chat:$roomId');

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _pluginReady = false;

Future<void> _initPlugin({DidReceiveNotificationResponseCallback? onTap}) async {
  if (_pluginReady && onTap == null) return;
  await _plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
    onDidReceiveNotificationResponse: onTap,
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );
  final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_messageChannel);
  await android?.createNotificationChannel(_callChannel);
  await android?.createNotificationChannel(_missedChannel);
  _pluginReady = true;
}

/// Unlocks an encrypted chat push on this phone: the server only ever sends scrambled
/// text, so the words are put into the notification here. Returns the push with
/// `body` filled in, plus `mediaUrl`, `mediaName` and the media key when there is one.
Future<(Map<String, dynamic>, List<int>?)> _unlockChat(Map<String, dynamic> data) async {
  final to = data['to'] as String? ?? '';
  final wrapped = data['k'] as String? ?? '';
  final locked = data['c'] as String? ?? '';
  if (to.isEmpty || wrapped.isEmpty || locked.isEmpty) return (data, null);
  try {
    await E2E.instance.load(to);
    final opened = await E2E.instance.open(
      {'f': data['f'], 'n': data['n'], 'c': locked, 'k': {to: wrapped}},
      aad: E2E.messageAad(data['id'] as String? ?? '', data['messageId'] as String? ?? ''),
    );
    if (opened == null) return (data, null);
    final p = opened.payload;
    final text = p['t'] as String? ?? '';
    final isGroup = data['isGroup'] == 'true';
    return (
      {
        ...data,
        if (text.isNotEmpty) 'body': isGroup ? '${data['senderName'] ?? ''}: $text' : text,
        if (text.isNotEmpty) 'msgText': text,
        if (p['w'] == 1) 'walkie': 'true',
        if (p['w'] == 1) 'body': isGroup ? '${data['senderName'] ?? ''}: 📻 Walkie-talkie' : '📻 Walkie-talkie',
        if (p['w'] == 1) 'msgText': '📻 Walkie-talkie',
        'mediaUrl': p['u'] ?? '',
        'mediaName': p['m'] ?? '',
      },
      opened.contentKey,
    );
  } catch (e) {
    debugPrint('could not unlock push: $e');
    return (data, null);
  }
}

/// One notification per chat, listing its newest unread messages, with a Reply box.
Future<void> _showChat(Map<String, dynamic> data) async {
  final roomId = data['id'] as String? ?? '';
  final senderId = data['senderId'] as String? ?? '';
  final isGroup = data['isGroup'] == 'true';
  await _ensureNicknames();
  final serverName = data['senderName'] as String? ?? '';
  final senderName = Nicknames.instance.name(senderId, serverName.isNotEmpty ? serverName : (isGroup ? 'Someone' : data['title'] as String? ?? 'Someone'));
  final title = isGroup ? (data['title'] as String? ?? 'Group') : senderName;
  var text = data['msgText'] as String? ?? data['body'] as String? ?? 'New message';
  // Older pushes put "Name: " in front of group messages; the sender is shown separately here.
  if (isGroup && data['msgText'] == null && text.startsWith('$serverName: ')) text = text.substring(serverName.length + 2);
  await _postChat(
    roomId,
    title: title,
    isGroup: isGroup,
    message: Message(text, DateTime.now(), Person(name: senderName, key: senderId.isEmpty ? null : senderId)),
    alert: true,
  );
}

const _replyAction = AndroidNotificationAction(
  'reply',
  'Reply',
  inputs: [AndroidNotificationActionInput(label: 'Message')],
  showsUserInterface: false,
  cancelNotification: false,
  allowGeneratedReplies: true,
);

/// Adds [message] to the chat's notification (keeping the earlier unread ones) and shows it.
Future<void> _postChat(String roomId, {required String title, required bool isGroup, required Message message, required bool alert}) async {
  final id = chatNotificationId(roomId);
  final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  var earlier = const <Message>[];
  try {
    earlier = (await android?.getActiveNotificationMessagingStyle(id))?.messages ?? const <Message>[];
  } catch (_) {}
  final all = [...earlier, message];
  final recent = all.length > 8 ? all.sublist(all.length - 8) : all;
  await _plugin.show(
    id,
    title,
    message.text,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _messageChannel.id,
        _messageChannel.name,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: const Color(0xFFFACC15),
        category: AndroidNotificationCategory.message,
        // On a locked phone, only "Comms: new message" shows, never the words.
        visibility: NotificationVisibility.private,
        // Your own reply updates it quietly; new messages ring.
        onlyAlertOnce: !alert,
        styleInformation: MessagingStyleInformation(
          const Person(name: 'You'),
          conversationTitle: isGroup ? title : null,
          groupConversation: isGroup,
          messages: recent,
        ),
        actions: const [_replyAction],
      ),
      iOS: const DarwinNotificationDetails(),
    ),
    payload: 'chat|$roomId',
  );
}

/// Sends what was typed into a notification's Reply box. Works with the app closed.
Future<void> replyFromNotification(String roomId, String text) async {
  final words = text.trim();
  if (roomId.isEmpty || words.isEmpty) return;
  final user = FirebaseAuth.instance.currentUser ?? await FirebaseAuth.instance.authStateChanges().first;
  if (user == null) return;
  String? problem;
  ChatRoomModel? room;
  try {
    final snap = await FirebaseFirestore.instance.collection('chatRooms').doc(roomId).get();
    if (!snap.exists) return;
    room = ChatRoomModel.fromMap(snap.data()!);
    final me = await UserService.instance.getUser(user.uid, fresh: true);
    if (me == null) return;
    await E2E.instance.load(user.uid);
    await ChatService.instance.sendMessage(room: room, sender: me, text: words);
    // Replying means you've read the chat.
    await ChatService.instance.markSeen(roomId, user.uid, DateTime.now().millisecondsSinceEpoch);
  } on NoKeyException {
    problem = 'Not sent: they need to update Comms';
  } catch (e) {
    debugPrint('notification reply failed: $e');
    problem = 'Not sent. Open Comms to try again.';
  }
  final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  MessagingStyleInformation? style;
  try {
    style = await android?.getActiveNotificationMessagingStyle(chatNotificationId(roomId));
  } catch (_) {}
  await _postChat(
    roomId,
    title: style?.conversationTitle ?? room?.groupName ?? 'Comms',
    isGroup: room?.isGroup ?? false,
    message: Message(problem == null ? words : '$words\n⚠ $problem', DateTime.now(), null),
    alert: false,
  );
}

Future<void> _showIncomingCall({required String callId, required String callerName, required bool isVideo}) async {
  await _plugin.show(
    callNotificationId(callId),
    callerName,
    isVideo ? 'Incoming video call' : 'Incoming voice call',
    NotificationDetails(
      android: AndroidNotificationDetails(
        _callChannel.id,
        _callChannel.name,
        importance: Importance.max,
        priority: Priority.max,
        icon: '@mipmap/ic_launcher',
        color: const Color(0xFFFACC15),
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        timeoutAfter: 40000,
        // keep ringing until answered, declined or timed out
        additionalFlags: Int32List.fromList([4]),
        actions: const [
          AndroidNotificationAction('decline', 'Decline', showsUserInterface: false, cancelNotification: true),
          AndroidNotificationAction('answer', 'Answer', showsUserInterface: true, cancelNotification: true),
        ],
      ),
      iOS: const DarwinNotificationDetails(presentSound: true),
    ),
    payload: 'call|$callId',
  );
}

Future<void> _showMissedCall(String callId, String callerName, bool isVideo) async {
  await _plugin.show(
    callNotificationId('missed-$callId'),
    'Missed ${isVideo ? 'video' : 'voice'} call',
    callerName,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _missedChannel.id,
        _missedChannel.name,
        icon: '@mipmap/ic_launcher',
        color: const Color(0xFFFACC15),
        category: AndroidNotificationCategory.missedCall,
      ),
    ),
    payload: 'calls|$callId',
  );
}

bool _nicknamesLoaded = false;

/// The notification handler runs on its own, so it loads nicknames itself the first time.
Future<void> _ensureNicknames() async {
  if (_nicknamesLoaded) return;
  _nicknamesLoaded = true;
  await Nicknames.instance.load();
}

/// Declines a ringing call without opening the app.
Future<void> declineCallInBackground(String callId) async {
  final user = FirebaseAuth.instance.currentUser ?? await FirebaseAuth.instance.authStateChanges().first;
  if (user == null) return;
  final ref = FirebaseFirestore.instance.collection('calls').doc(callId);
  final declined = await FirebaseFirestore.instance.runTransaction<bool>((tx) async {
    final snap = await tx.get(ref);
    if (snap.data()?['status'] != CallStatus.ringing.name) return false;
    tx.update(ref, {'status': CallStatus.rejected.name, 'endReason': EndReason.declined, 'endedBy': user.uid});
    return true;
  });
  if (declined) await PushApi.callUpdate(callId);
  try {
    await FirebaseFirestore.instance.collection('users').doc(user.uid).update({'busyUntil': FieldValue.delete()});
  } catch (_) {}
}

/// Runs in its own isolate when a push arrives and the app is not on screen.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await _initPlugin();
  final data = message.data;
  switch (data['type']) {
    case 'chat':
      final app = IsolateNameServer.lookupPortByName(_mainPortName);
      if (app != null) {
        // The app is running; let it decide (no banner for the chat you're in).
        app.send(Map<String, dynamic>.from(data));
        return;
      }
      final (unlocked, key) = await _unlockChat(data);
      await _showChat(unlocked);
      // Save the photo, video or voice note now, while the link still works.
      final file = await MediaService.prefetch(
        url: unlocked['mediaUrl'] ?? '',
        messageId: unlocked['messageId'] ?? '',
        name: unlocked['mediaName'] ?? '',
        type: unlocked['mediaType'] ?? '',
        key: key,
      );
      // Walkie-talkie: play it out loud now (if allowed and the phone isn't silenced).
      if (file != null && unlocked['walkie'] == 'true') await Walkie.playIfAllowed(file);
      break;
    case 'call':
      final sentAt = int.tryParse(data['sentAt'] ?? '') ?? 0;
      // A call that has already stopped ringing should not ring now.
      if (DateTime.now().millisecondsSinceEpoch - sentAt > 38000) return;
      await _ensureNicknames();
      await _showIncomingCall(
        callId: data['id'] ?? '',
        callerName: Nicknames.instance.name(data['callerId'] ?? '', data['callerName'] ?? 'Someone'),
        isVideo: data['isVideo'] == 'true',
      );
      break;
    case 'call_update':
      await _plugin.cancel(callNotificationId(data['id'] ?? ''));
      if (data['missed'] == 'true') {
        await _ensureNicknames();
        await _showMissedCall(data['id'] ?? '', Nicknames.instance.name(data['callerId'] ?? '', data['callerName'] ?? 'Someone'), data['isVideo'] == 'true');
      }
      break;
  }
}

/// Runs when a notification button (Decline, Reply) is pressed without opening the app.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  final parts = (response.payload ?? '').split('|');
  if (parts.length < 2) return;
  final isDecline = response.actionId == 'decline' && parts[0] == 'call';
  final isReply = response.actionId == 'reply' && parts[0] == 'chat';
  if (!isDecline && !isReply) return;
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  if (isDecline) {
    await declineCallInBackground(parts[1]);
  } else {
    await _initPlugin();
    await replyFromNotification(parts[1], response.input ?? '');
  }
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();
  factory NotificationService() => instance;

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// The chat on screen right now, so its messages don't pop up as notifications.
  static String? activeChatRoomId;

  final StreamController<NotificationTap> _taps = StreamController<NotificationTap>.broadcast();
  NotificationTap? _pendingTap;

  /// Taps on notifications. A tap that opened the app is replayed to the first listener.
  Stream<NotificationTap> get taps => _taps.stream;

  NotificationTap? takePendingTap() {
    final tap = _pendingTap;
    _pendingTap = null;
    return tap;
  }

  /// Called by the app when a push for a chat arrives while it is open.
  void Function(Map<String, dynamic> data)? onForegroundChat;

  final ReceivePort _port = ReceivePort();
  final Set<String> _handledMessages = {};

  /// One place decides about every chat push, however it arrived.
  Future<void> _handleChat(Map<String, dynamic> raw) async {
    final messageId = raw['messageId']?.toString() ?? '';
    if (messageId.isNotEmpty && !_handledMessages.add(messageId)) return; // already handled
    final (data, key) = await _unlockChat(raw);
    final looking = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final inThatChat = looking && data['id'] == activeChatRoomId;
    if (!inThatChat) {
      _showChat(data);
      if (looking) onForegroundChat?.call(data);
    }
    final file = await MediaService.prefetch(
      url: data['mediaUrl'] ?? '',
      messageId: messageId,
      name: data['mediaName'] ?? '',
      type: data['mediaType'] ?? '',
      key: key,
    );
    if (file != null && data['walkie'] == 'true') {
      await Walkie.playIfAllowed(file, inCall: CallService.instance.isActive);
    }
  }

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    IsolateNameServer.removePortNameMapping(_mainPortName);
    IsolateNameServer.registerPortWithName(_port.sendPort, _mainPortName);
    _port.listen((raw) {
      if (raw is Map) _handleChat(Map<String, dynamic>.from(raw));
    });
    await _initPlugin(onTap: _onTap);

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) {
      // The home screen may already be listening by now (it often is), so hand it over
      // the normal way rather than leaving it waiting to be picked up.
      final tap = _parse(launch.notificationResponse!);
      if (tap != null) _deliver(tap);
    }

    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      try {
        await android?.requestFullScreenIntentPermission();
      } catch (_) {}
    }

    FirebaseMessaging.onMessage.listen((message) {
      final data = message.data;
      if (data['type'] == 'chat') {
        _handleChat(data);
      } else if (data['type'] == 'call_update') {
        _plugin.cancel(callNotificationId(data['id'] ?? ''));
      }
      // Calls are picked up directly from the database while the app is open.
    });

    _messaging.onTokenRefresh.listen(_saveToken);
    await saveDeviceToken();
  }

  NotificationTap? _parse(NotificationResponse response) {
    final parts = (response.payload ?? '').split('|');
    if (parts.length < 2) return null;
    return NotificationTap(parts[0], parts[1], response.actionId ?? '');
  }

  void _onTap(NotificationResponse response) {
    final tap = _parse(response);
    if (tap == null) return;
    if (tap.type == 'call' && tap.action == 'decline') {
      declineCallInBackground(tap.id);
      return;
    }
    if (tap.type == 'chat' && tap.action == 'reply') {
      replyFromNotification(tap.id, response.input ?? '');
      return;
    }
    _deliver(tap);
  }

  void _deliver(NotificationTap tap) {
    if (_taps.hasListener) {
      _taps.add(tap);
    } else {
      _pendingTap = tap;
    }
  }

  Future<void> saveDeviceToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      debugPrint('fcm token failed: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    // Kept in the private document, which only this person (and the notification server) can read.
    await _privateDoc(uid).set({'fcmToken': token}, SetOptions(merge: true));
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({'fcmToken': FieldValue.delete()});
    } catch (_) {}
  }

  Future<void> forgetDevice() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await _privateDoc(uid).set({'fcmToken': FieldValue.delete()}, SetOptions(merge: true));
      await _messaging.deleteToken();
    } catch (_) {}
  }

  DocumentReference<Map<String, dynamic>> _privateDoc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('data');

  Future<void> cancelCall(String callId) => _plugin.cancel(callNotificationId(callId));

  Future<void> cancelChat(String roomId) => _plugin.cancel(chatNotificationId(roomId));

  // The browser version watches chats itself and asks before showing notifications;
  // on a phone, pushes do that work.
  void startWatching(String uid) {}
  Future<bool> permitted() async => true;
  Future<String> permissionState() async => 'granted';
  bool get pushSupported => true;
  bool get isApplePhone => false;
  bool get isInstalled => true;
  Future<bool> askPermission() async => true;
  Future<void> showRinging(CallModel call) async {}

  Future<void> showMissedCall(CallModel call) => _showMissedCall(call.id, Nicknames.instance.name(call.callerId, call.callerName), call.isVideo);
}
