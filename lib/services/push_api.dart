import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../config.dart';

/// Talks to the Comms Worker, which sends notifications on the app's behalf.
class PushApi {
  PushApi._();

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: AppConfig.pushServer,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 10),
  ));

  static Future<Options?> _auth() async {
    final headers = await authHeaders();
    return headers == null ? null : Options(headers: headers);
  }

  /// Proves to the worker who is asking.
  static Future<Map<String, String>?> authHeaders() async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    return token == null ? null : {'Authorization': 'Bearer $token'};
  }

  static Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      final options = await _auth();
      if (options == null) return;
      await _dio.post(path, data: body, options: options);
    } catch (e) {
      // A missed notification must never break sending or calling.
      debugPrint('push $path failed: $e');
    }
  }

  static Future<void> message(String chatRoomId, String messageId) =>
      _post('/notify/message', {'chatRoomId': chatRoomId, 'messageId': messageId});

  static Future<void> call(String callId) => _post('/notify/call', {'callId': callId});

  static Future<void> callUpdate(String callId) => _post('/notify/call-update', {'callId': callId});

  static List<Map<String, dynamic>>? _ice;
  static DateTime _iceFetched = DateTime(2000);

  static const List<Map<String, dynamic>> _fallbackIce = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  /// Servers that help two phones find each other, including relays for strict networks.
  static Future<List<Map<String, dynamic>>> iceServers() async {
    if (_ice != null && DateTime.now().difference(_iceFetched) < const Duration(minutes: 20)) return _ice!;
    try {
      final options = await _auth();
      if (options == null) return _fallbackIce;
      final res = await _dio.get('/ice', options: options);
      final list = (res.data['iceServers'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
      if (list.isNotEmpty) {
        _ice = list;
        _iceFetched = DateTime.now();
        return list;
      }
    } catch (e) {
      debugPrint('ice fetch failed: $e');
    }
    return _fallbackIce;
  }

  /// Latest release info: {version, build, url, notes}.
  static Future<Map<String, dynamic>?> latestRelease() async {
    try {
      final res = await _dio.get('/version');
      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      debugPrint('version check failed: $e');
      return null;
    }
  }
}
