import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'fcm_sender_service.dart';

import 'package:firebase_core/firebase_core.dart';

/// Top-level background message handler (must be a top-level function)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  // FCM shows the notification automatically when app is terminated/background
  // for messages that contain a "notification" block.
  // Data-only messages (like calls) won't show automatically, so we handle them here.
  final data = message.data;
  if (data['type'] == 'call') {
    final callerName = data['callerName'] ?? 'Someone';
    final isVideo = data['isVideo'] == 'true';
    final callId = data['id'] ?? '';

    final localNotifications = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
    await localNotifications.initialize(initSettings);

    const androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'comms_calls_channel_v3', // increment channel ID again to force Android to apply new settings
      'Incoming Calls',
      channelDescription: 'Used for incoming video and audio calls',
      importance: Importance.max,
      priority: Priority.max,
      icon: '@mipmap/ic_launcher',
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      autoCancel: false,
      ongoing: true,
    );

    // Explicitly create the channel in background to ensure it exists
    final androidPlugin = localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          'comms_calls_channel_v3',
          'Incoming Calls',
          description: 'Used for incoming video and audio calls',
          importance: Importance.max,
        ),
      );
    }

    localNotifications.show(
      callId.hashCode,
      isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
      '$callerName is calling you',
      const NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'call:$callId',
    );
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// The channel ID used for message notifications on Android
  static const String _channelId = 'comms_channel';
  static const String _channelName = 'Comms Notifications';

  /// Separate high-priority channel for incoming calls
  static const String _callChannelId = 'comms_calls_channel_v3';
  static const String _callChannelName = 'Incoming Calls';

  /// Set this to the currently active chat room ID to suppress notifications
  /// for that chat while the user is viewing it.
  static String? activeChatRoomId;

  /// Callback to navigate to a specific chat or incoming call screen.
  /// Set this from main.dart after routes are ready.
  Function(String type, String id)? onNotificationTap;

  Future<void> initialize() async {
    // Register the background handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Request notification permissions
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Set up the local notification plugin
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // Parse the payload to navigate to the right screen
        final payload = response.payload;
        if (payload != null) {
          final parts = payload.split(':');
          if (parts.length == 2) {
            onNotificationTap?.call(parts[0], parts[1]);
          }
        }
      },
    );

    // Create Android notification channels
    if (Platform.isAndroid) {
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      // Messages channel
      const messageChannel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Notifications for Comms messages',
        importance: Importance.high,
        playSound: true,
      );
      await androidPlugin?.createNotificationChannel(messageChannel);

      // Calls channel — max priority with full-screen intent
      const callChannel = AndroidNotificationChannel(
        _callChannelId,
        _callChannelName,
        description: 'Incoming call notifications',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin?.createNotificationChannel(callChannel);
    }

    // Handle foreground FCM messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      _showLocalNotification(message);
    });

    // Handle notification tap when app is in background (not terminated)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleMessageTap(message);
    });

    // Handle notification tap when app was terminated
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      // Delay slightly to let the app finish initializing
      Future.delayed(const Duration(milliseconds: 800), () {
        _handleMessageTap(initialMessage);
      });
    }

    // Save the FCM token for the current user
    await _saveFcmToken();

    // Refresh token if it changes (e.g., after reinstall)
    _messaging.onTokenRefresh.listen((newToken) async {
      await _updateTokenInFirestore(newToken);
    });
  }

  /// Save the FCM token to Firestore so Cloud Functions can send notifications
  Future<void> _saveFcmToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final token = await _messaging.getToken();
    if (token != null) {
      await _updateTokenInFirestore(token);
    }
  }

  Future<void> _updateTokenInFirestore(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({'fcmToken': token});
  }

  /// Show a local notification for foreground FCM messages
  void _showLocalNotification(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;

    final type = message.data['type']?.toString() ?? '';
    final id = message.data['id']?.toString() ?? '';

    // Suppress notification if the user is currently viewing this chat
    if (type == 'chat' && id == activeChatRoomId?.toString()) {
      return;
    }

    // Use the call channel for call notifications
    final isCall = type == 'call';

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          isCall ? _callChannelId : _channelId,
          isCall ? _callChannelName : _channelName,
          importance: isCall ? Importance.max : Importance.high,
          priority: isCall ? Priority.max : Priority.high,
          icon: '@mipmap/ic_launcher',
          fullScreenIntent: isCall,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: '$type:$id',
    );
  }

  /// Navigate to the correct screen when a notification is tapped
  void _handleMessageTap(RemoteMessage message) {
    final type = message.data['type'] ?? '';
    final id = message.data['id'] ?? '';
    if (type.isNotEmpty && id.isNotEmpty) {
      onNotificationTap?.call(type, id);
    }
  }

  /// Call this after a user signs in to save their FCM token
  Future<void> onUserSignedIn() async {
    await _saveFcmToken();
  }

  /// Call this after a user signs out to remove their token
  Future<void> onUserSignedOut() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .update({'fcmToken': FieldValue.delete()});
  }

  /// Show a local notification when a new message is received while the app
  /// is open (used as a fallback since FCM handles background/terminated).
  void showMessageNotification({
    required String senderName,
    required String messageText,
    required String chatRoomId,
  }) {
    // Don't show if user is already viewing this chat
    if (chatRoomId == activeChatRoomId) return;

    _localNotifications.show(
      chatRoomId.hashCode,
      senderName,
      messageText,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: 'chat:$chatRoomId',
    );
  }

  /// Show a local notification for an incoming call
  void showCallNotification({
    required String callerName,
    required String callId,
    required bool isVideo,
  }) {
    _localNotifications.show(
      callId.hashCode,
      isVideo ? 'Incoming Video Call' : 'Incoming Voice Call',
      '$callerName is calling you',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _callChannelId,
          _callChannelName,
          importance: Importance.max,
          priority: Priority.max,
          icon: '@mipmap/ic_launcher',
          fullScreenIntent: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: 'call:$callId',
    );
  }

  /// Send a push notification securely using our embedded FcmSenderService.
  /// Call this whenever a message is sent or a call is initiated.
  static Future<void> sendPushNotification({
    required String recipientFcmToken,
    required String title,
    required String message,
    required Map<String, String> data,
  }) async {
    await FcmSenderService.sendPushNotification(
      recipientFcmToken: recipientFcmToken,
      title: title,
      message: message,
      data: data,
    );
  }

  /// Show a snackbar-style in-app notification banner
  static void showInAppBanner(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(body),
          ],
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF171717),
      ),
    );
  }
}
