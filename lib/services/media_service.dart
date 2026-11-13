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

  /// Uploads to tmpfiles.org and returns the file's direct, signed download link.
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
      final page = data['data']['url'] as String;
      // Receivers can still find the file from the page link if this lookup fails.
      return await resolveLink(page) ?? page;
    }
    throw Exception('Upload failed');
  }

  static final RegExp _signedPath = RegExp(r'^/dl/\d+\.[0-9a-f]+/');

  /// tmpfiles.org links to a file are signed: `/dl/<expiry>.<signature>/<id>/<name>`.
  static bool isSignedLink(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && uri.host == 'tmpfiles.org' && _signedPath.hasMatch(uri.path);
  }

  /// The tmpfiles page for a file, from either its page link or an old-style /dl/ link.
  static String pageLinkFor(String url) {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.first == 'dl') segments.removeAt(0);
    return Uri(scheme: 'https', host: uri.host, pathSegments: segments).toString();
  }

  /// Picks the file's download link out of a tmpfiles page.
  static String? signedLinkIn(String html) {
    final match = RegExp(r'href="(https://tmpfiles\.org/dl/[^"]+)"').firstMatch(html);
    final link = match?.group(1)?.replaceAll('&amp;', '&');
    return link != null && isSignedLink(link) ? link : null;
  }

  /// Turns any tmpfiles link into the link that serves the file itself.
  /// Returns null once the file has expired.
  Future<String?> resolveLink(String url) async {
    if (isSignedLink(url)) return url;
    try {
      final res = await _dio.get<String>(
        pageLinkFor(url),
        options: Options(responseType: ResponseType.plain, validateStatus: (s) => s != null && s < 500),
      );
      if (res.statusCode != 200 || res.data == null) return null;
      return signedLinkIn(res.data!);
    } catch (e) {
      debugPrint('media link lookup failed: $e');
      return null;
    }
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
      final link = await resolveLink(url);
      if (link == null) return null;
      final res = await _dio.download(
        link,
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
