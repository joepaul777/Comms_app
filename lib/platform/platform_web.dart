import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

/// Files in the browser.
///
/// A browser has no folders the app can write to, so each "file" is a path with its
/// bytes: kept in memory while the page is open, and saved in the browser's own cache
/// storage so photos, wallpapers and settings are still there next time. Nothing here
/// leaves this browser.
class _Disk {
  static final Map<String, Uint8List> files = {};
  static final Map<String, String> _blobs = {};
  static Future<web.Cache?>? _cache;

  static Future<web.Cache?> cache() => _cache ??= () async {
        try {
          return await web.window.caches.open('comms-files').toDart;
        } catch (_) {
          return null; // private windows can refuse; files then last until the page closes
        }
      }();

  static String _key(String path) => '${web.window.location.origin}/__comms_files__/${Uri.encodeComponent(path)}';

  /// Temporary files (a picked photo, a half-downloaded file) are not worth keeping.
  static bool _keep(String path) => !path.startsWith('/tmp/') && !path.endsWith('.part') && !path.endsWith('.locked');

  static Future<Uint8List?> load(String path) async {
    final inMemory = files[path];
    if (inMemory != null) return inMemory;
    if (!_keep(path)) return null;
    try {
      final c = await cache();
      if (c == null) return null;
      final res = await c.match(_key(path).toJS).toDart;
      if (res == null) return null;
      final buffer = await res.arrayBuffer().toDart;
      return files[path] = buffer.toDart.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String path, Uint8List bytes) async {
    files[path] = bytes;
    _revoke(path);
    if (!_keep(path)) return;
    try {
      final c = await cache();
      await c?.put(_key(path).toJS, web.Response(bytes.toJS)).toDart;
    } catch (_) {}
  }

  static Future<void> remove(String path) async {
    files.remove(path);
    _revoke(path);
    if (!_keep(path)) return;
    try {
      final c = await cache();
      await c?.delete(_key(path).toJS).toDart;
    } catch (_) {}
  }

  /// A link the browser's own players can open (videos and voice notes).
  static String blobUrl(String path) {
    final existing = _blobs[path];
    if (existing != null) return existing;
    final bytes = files[path] ?? Uint8List(0);
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: _mime(path)));
    return _blobs[path] = web.URL.createObjectURL(blob);
  }

  static void _revoke(String path) {
    final url = _blobs.remove(path);
    if (url != null) web.URL.revokeObjectURL(url);
  }

  static String _mime(String path) {
    final ext = path.contains('.') ? path.substring(path.lastIndexOf('.') + 1).toLowerCase() : '';
    const types = {
      'mp4': 'video/mp4',
      'm4v': 'video/mp4',
      'mov': 'video/quicktime',
      'webm': 'video/webm',
      'mkv': 'video/x-matroska',
      '3gp': 'video/3gpp',
      'm4a': 'audio/mp4',
      'aac': 'audio/aac',
      'mp3': 'audio/mpeg',
      'ogg': 'audio/ogg',
      'opus': 'audio/ogg',
      'wav': 'audio/wav',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
    };
    return types[ext] ?? 'application/octet-stream';
  }
}

class FileSystemException implements Exception {
  final String message;
  final String path;
  const FileSystemException(this.message, [this.path = '']);
  @override
  String toString() => 'FileSystemException: $message, path = $path';
}

/// The parts of a file the app uses, kept in the browser.
class File {
  final String path;
  File(this.path);

  Future<bool> exists() async => await _Disk.load(path) != null;

  /// Only knows about files already loaded on this page.
  bool existsSync() => _Disk.files.containsKey(path);

  Future<Uint8List> readAsBytes() async {
    final bytes = await _Disk.load(path);
    if (bytes == null) throw FileSystemException('Cannot open file', path);
    return bytes;
  }

  Future<String> readAsString() async => utf8.decode(await readAsBytes());

  Future<int> length() async => (await readAsBytes()).length;

  Future<File> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    await _Disk.save(path, bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    return this;
  }

  Future<File> writeAsString(String contents, {bool flush = false}) => writeAsBytes(utf8.encode(contents));

  Future<File> delete({bool recursive = false}) async {
    await _Disk.remove(path);
    return this;
  }

  Future<File> copy(String newPath) async {
    await _Disk.save(newPath, await readAsBytes());
    return File(newPath);
  }

  Future<File> rename(String newPath) async {
    final bytes = await readAsBytes();
    await _Disk.save(newPath, bytes);
    await _Disk.remove(path);
    return File(newPath);
  }

  Future<FileReader> open() async => FileReader._(await readAsBytes());

  FileWriter openWrite() => FileWriter._(this);

  @override
  String toString() => "File: '$path'";
}

/// Reads a file in pieces, the way a file on disk is read.
class FileReader {
  final Uint8List _bytes;
  int _at = 0;
  FileReader._(this._bytes);

  Future<int> length() async => _bytes.length;

  Future<Uint8List> read(int count) async {
    final end = (_at + count).clamp(0, _bytes.length);
    final piece = Uint8List.sublistView(_bytes, _at, end);
    _at = end;
    return piece;
  }

  Future<void> close() async {}
}

/// Collects what is written and saves it as the file once closed.
class FileWriter {
  final File _file;
  final BytesBuilder _out = BytesBuilder(copy: false);
  bool _closed = false;
  FileWriter._(this._file);

  void add(List<int> data) => _out.add(data);

  Future<void> flush() async {}

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.writeAsBytes(_out.takeBytes());
  }
}

class Directory {
  final String path;
  Directory(this.path);
  Future<bool> exists() async => true;
  Future<Directory> create({bool recursive = false}) async => this;
}

Future<Directory> supportDirectory() async => Directory('/support');
Future<Directory> documentsDirectory() async => Directory('/documents');
Future<Directory> temporaryDirectory() async => Directory('/tmp');

/// A picked photo or video, or a finished recording, as a file.
Future<File> fileFromPicked(XFile picked) async {
  final bytes = await picked.readAsBytes();
  var name = picked.name.isNotEmpty ? picked.name : 'file';
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final file = File('/tmp/${DateTime.now().microsecondsSinceEpoch}-$name');
  await file.writeAsBytes(bytes);
  return file;
}

ImageProvider localImage(File file, {int? cacheWidth}) =>
    ResizeImage.resizeIfNeeded(cacheWidth, null, MemoryImage(_Disk.files[file.path] ?? Uint8List(0)));

VideoPlayerController localVideo(File file) => VideoPlayerController.networkUrl(Uri.parse(_Disk.blobUrl(file.path)));

Source localAudio(File file) => UrlSource(_Disk.blobUrl(file.path));

// ---- Ringtone ---------------------------------------------------------------

web.AudioContext? _ringContext;
Timer? _ringTimer;

/// A phone-style ring made in the browser: two short bursts every three seconds.
void startRingtone() {
  stopRingtone();
  try {
    final ctx = _ringContext = web.AudioContext();
    void ring() {
      final start = ctx.currentTime;
      for (final burst in [0.0, 0.55]) {
        for (final pitch in [440.0, 480.0]) {
          final tone = ctx.createOscillator();
          final volume = ctx.createGain();
          tone.frequency.value = pitch;
          volume.gain.setValueAtTime(0, start + burst);
          volume.gain.linearRampToValueAtTime(0.08, start + burst + 0.03);
          volume.gain.setValueAtTime(0.08, start + burst + 0.4);
          volume.gain.linearRampToValueAtTime(0, start + burst + 0.45);
          tone.connect(volume);
          volume.connect(ctx.destination);
          tone.start(start + burst);
          tone.stop(start + burst + 0.5);
        }
      }
    }

    ring();
    _ringTimer = Timer.periodic(const Duration(seconds: 3), (_) => ring());
  } catch (_) {}
}

void stopRingtone() {
  _ringTimer?.cancel();
  _ringTimer = null;
  try {
    _ringContext?.close();
  } catch (_) {}
  _ringContext = null;
}

/// "Chrome on Windows", "Safari on Mac" and so on.
String get deviceName {
  final ua = web.window.navigator.userAgent;
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('OPR/')
          ? 'Opera'
          : ua.contains('Firefox/')
              ? 'Firefox'
              : ua.contains('Chrome/')
                  ? 'Chrome'
                  : ua.contains('Safari/')
                      ? 'Safari'
                      : 'A browser';
  final system = ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Android')
          ? 'Android'
          : ua.contains('iPhone') || ua.contains('iPad')
              ? 'iPhone'
              : ua.contains('Mac OS')
                  ? 'Mac'
                  : ua.contains('Linux')
                      ? 'Linux'
                      : '';
  return system.isEmpty ? browser : '$browser on $system';
}

void reloadApp() => web.window.location.reload();
