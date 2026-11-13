import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/call_model.dart';
import 'media_service.dart';
import 'push_api.dart';

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

/// What happened when a notification was tapped.
class NotificationTap {
  final String type; // chat, call
  final String id;
  final String action; // '', answer, decline
  NotificationTap(this.type, this.id, this.action);
}

int callNotificationId(String callId) => callId.hashCode & 0x7fffffff;
int chatNotificationId(String roomId) => roomId.hashCode & 0x7fffffff;

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

Future<void> _showChat(Map<String, dynamic> data) async {
  final roomId = data['id'] as String? ?? '';
  await _plugin.show(
    chatNotificationId(roomId),
    data['title'] as String? ?? 'Comms',
    data['body'] as String? ?? 'New message',
    NotificationDetails(
      android: AndroidNotificationDetails(
        _messageChannel.id,
        _messageChannel.name,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: const Color(0xFFFACC15),
        category: AndroidNotificationCategory.message,
      ),
      iOS: const DarwinNotificationDetails(),
    ),
    payload: 'chat|$roomId',
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
      await _showChat(data);
      // Save the photo, video or voice note now, while the link still works.
      await MediaService.prefetch(
        url: data['mediaUrl'] ?? '',
        messageId: data['messageId'] ?? '',
        name: data['mediaName'] ?? '',
        type: data['mediaType'] ?? '',
      );
      break;
    case 'call':
      final sentAt = int.tryParse(data['sentAt'] ?? '') ?? 0;
      // A call that has already stopped ringing should not ring now.
      if (DateTime.now().millisecondsSinceEpoch - sentAt > 38000) return;
      await _showIncomingCall(callId: data['id'] ?? '', callerName: data['callerName'] ?? 'Someone', isVideo: data['isVideo'] == 'true');
      break;
    case 'call_update':
      await _plugin.cancel(callNotificationId(data['id'] ?? ''));
      if (data['missed'] == 'true') {
        await _showMissedCall(data['id'] ?? '', data['callerName'] ?? 'Someone', data['isVideo'] == 'true');
      }
      break;
  }
}

/// Runs when the Decline button is pressed while the app is closed.
@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  if (response.actionId != 'decline') return;
  final parts = (response.payload ?? '').split('|');
  if (parts.length < 2 || parts[0] != 'call') return;
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await declineCallInBackground(parts[1]);
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

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await _initPlugin(onTap: _onTap);

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true && launch!.notificationResponse != null) {
      _pendingTap = _parse(launch.notificationResponse!);
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
        if (data['id'] != activeChatRoomId) {
          _showChat(data);
          onForegroundChat?.call(data);
        }
        MediaService.prefetch(
          url: data['mediaUrl'] ?? '',
          messageId: data['messageId'] ?? '',
          name: data['mediaName'] ?? '',
          type: data['mediaType'] ?? '',
        );
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
    await FirebaseFirestore.instance.collection('users').doc(uid).update({'fcmToken': token});
  }

  Future<void> forgetDevice() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({'fcmToken': FieldValue.delete()});
      await _messaging.deleteToken();
    } catch (_) {}
  }

  Future<void> cancelCall(String callId) => _plugin.cancel(callNotificationId(callId));

  Future<void> cancelChat(String roomId) => _plugin.cancel(chatNotificationId(roomId));

  Future<void> showMissedCall(CallModel call) => _showMissedCall(call.id, call.callerName, call.isVideo);
}
