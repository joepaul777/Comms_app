import 'dart:io';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'fcm_sender_service.dart';

/// Top-level background message handler (must be a top-level function)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // FCM shows the notification automatically when app is terminated/background.
  // Nothing extra needed here for data-only messages.
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// The channel ID used for all Comms notifications on Android
  static const String _channelId = 'comms_channel';
  static const String _channelName = 'Comms Notifications';

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

    // Create Android notification channel
    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Notifications for Comms messages and calls',
        importance: Importance.high,
        playSound: true,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);
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

    final type = message.data['type'] ?? '';
    final id = message.data['id'] ?? '';

    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
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
          _channelId,
          _channelName,
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
