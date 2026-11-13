import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import '../models/message_model.dart';

class MediaTooLargeException implements Exception {
  @override
  String toString() => 'Files can be up to 95 MB';
}

/// Photos, videos and voice notes travel through tmpfiles.org, which deletes them
/// after an hour. Every phone keeps its own copy in the app's private folder,
/// named after the message, so nothing depends on the link afterwards.
class MediaService {
  MediaService._();
  static final MediaService instance = MediaService._();
  factory MediaService() => instance;

  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
  final Map<String, Future<File?>> _downloads = {};
  Directory? _dir;

  static String extensionOf(String name, MessageType type) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1) {
      final ext = name.substring(dot + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) return ext;
    }
    switch (type) {
      case MessageType.image:
        return 'jpg';
      case MessageType.video:
        return 'mp4';
      case MessageType.audio:
        return 'm4a';
      default:
        return 'bin';
    }
  }

  static Future<Directory> mediaDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/media');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> fileFor(String messageId, String ext) async {
    _dir ??= await mediaDirectory();
    return File('${_dir!.path}/$messageId.$ext');
  }

  /// This phone's copy of a message's media, if it has one.
  Future<File?> localCopy(MessageModel message) async {
    final file = await fileFor(message.id, extensionOf(message.mediaName ?? '', message.type));
    return await file.exists() && await file.length() > 0 ? file : null;
  }

  /// Keeps the sender's own copy before the upload starts.
  Future<File> keepCopy(File source, String messageId, String ext) async {
    final target = await fileFor(messageId, ext);
    return source.copy(target.path);
  }

  /// Uploads to tmpfiles.org and returns a direct download link.
  Future<String> upload(File file, String fileName, {void Function(double)? onProgress, CancelToken? cancel}) async {
    final size = await file.length();
    if (size > AppConfig.maxUploadBytes) throw MediaTooLargeException();
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(file.path, filename: fileName)});
    final res = await _dio.post(
      'https://tmpfiles.org/api/v1/upload',
      data: form,
      cancelToken: cancel,
      onSendProgress: (sent, total) {
        if (total > 0) onProgress?.call(sent / total);
      },
    );
    final data = res.data;
    if (data is Map && data['status'] == 'success') {
      return directLink(data['data']['url'] as String);
    }
    throw Exception('Upload failed');
  }

  /// tmpfiles.org hands back a page link; the file itself lives under /dl/.
  static String directLink(String pageUrl) {
    final uri = Uri.parse(pageUrl);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.first == 'dl') return uri.replace(scheme: 'https').toString();
    return Uri(scheme: 'https', host: uri.host, pathSegments: ['dl', ...segments]).toString();
  }

  /// Downloads a message's media to this phone once. Safe to call many times.
  Future<File?> download(MessageModel message, {void Function(double)? onProgress}) {
    if (message.mediaUrl == null || message.mediaUrl!.isEmpty) return Future.value(null);
    return _downloads.putIfAbsent(message.id, () async {
      try {
        final existing = await localCopy(message);
        if (existing != null) return existing;
        final ext = extensionOf(message.mediaName ?? '', message.type);
        return await fetchTo(message.mediaUrl!, await fileFor(message.id, ext), onProgress: onProgress);
      } finally {
        // Allow a retry later if this attempt failed.
        unawaited(Future.delayed(const Duration(seconds: 1), () => _downloads.remove(message.id)));
      }
    });
  }

  Future<File?> fetchTo(String url, File target, {void Function(double)? onProgress}) async {
    final partial = File('${target.path}.part');
    try {
      final res = await _dio.download(
        url,
        partial.path,
        onReceiveProgress: (got, total) {
          if (total > 0) onProgress?.call(got / total);
        },
        options: Options(validateStatus: (s) => s == 200),
      );
      final type = res.headers.value('content-type') ?? '';
      // An expired tmpfiles link answers with a web page, not the file.
      if (type.contains('text/html')) {
        await partial.delete();
        return null;
      }
      return await partial.rename(target.path);
    } catch (e) {
      debugPrint('media download failed: $e');
      if (await partial.exists()) await partial.delete();
      return null;
    }
  }

  /// Used by the notification handler, which runs without the rest of the app.
  static Future<void> prefetch({required String url, required String messageId, required String name, required String type}) async {
    if (url.isEmpty) return;
    final messageType = MessageType.values.firstWhere((t) => t.name == type, orElse: () => MessageType.image);
    final dir = await mediaDirectory();
    final target = File('${dir.path}/$messageId.${extensionOf(name, messageType)}');
    if (await target.exists()) return;
    await MediaService.instance.fetchTo(url, target);
  }
}
