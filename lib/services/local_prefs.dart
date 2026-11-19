import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../platform/platform.dart';

/// Small settings that live only on this phone, stored as a JSON file.
class _LocalFile {
  final String name;
  _LocalFile(this.name);

  Future<File> _file() async => File('${(await supportDirectory()).path}/$name');

  Future<Map<String, dynamic>> read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> write(Map<String, dynamic> data) async {
    try {
      await (await _file()).writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}

/// Names you give other people. Only you see them, and only on this phone.
class Nicknames extends ChangeNotifier {
  Nicknames._();
  static final Nicknames instance = Nicknames._();

  final _store = _LocalFile('nicknames.json');
  Map<String, String> _names = {};

  Future<void> load() async {
    _names = (await _store.read()).map((k, v) => MapEntry(k, '$v'));
    notifyListeners();
  }

  String? of(String uid) => _names[uid];

  /// The nickname if you set one, otherwise their own name.
  String name(String uid, String fallback) {
    final n = _names[uid];
    return n == null || n.isEmpty ? fallback : n;
  }

  Future<void> set(String uid, String? nickname) async {
    final n = nickname?.trim() ?? '';
    if (n.isEmpty) {
      _names.remove(uid);
    } else {
      _names[uid] = n.length > 40 ? n.substring(0, 40) : n;
    }
    notifyListeners();
    await _store.write(_names);
  }
}

/// A chat's wallpaper: a photo kept on this phone, how much it is dimmed, and
/// whether it is toned yellow to match the app.
class Wallpaper {
  final String path;
  final double dim;
  final bool tint;
  const Wallpaper(this.path, this.dim, {this.tint = true});
}

/// Wallpapers, one per chat, only on this phone.
class Wallpapers extends ChangeNotifier {
  Wallpapers._();
  static final Wallpapers instance = Wallpapers._();

  final _store = _LocalFile('wallpapers.json');
  Map<String, dynamic> _data = {};
  bool _loaded = false;

  Future<void> load() async {
    _data = await _store.read();
    // Have the photos at hand before the first chat is drawn (a browser keeps them in its own storage).
    for (final entry in _data.values) {
      final path = entry is Map ? entry['path'] : null;
      if (path is String) await File(path).exists();
    }
    _loaded = true;
    notifyListeners();
  }

  Wallpaper? of(String roomId) {
    if (!_loaded) return null;
    final entry = _data[roomId];
    if (entry is! Map) return null;
    final path = entry['path'] as String?;
    if (path == null || !File(path).existsSync()) return null;
    return Wallpaper(path, (entry['dim'] as num?)?.toDouble() ?? 0.55, tint: entry['tint'] as bool? ?? true);
  }

  /// Copies the photo into the app's own folder so it survives the gallery changing.
  Future<void> set(String roomId, File photo, double dim, {bool tint = true}) async {
    final dir = Directory('${(await supportDirectory()).path}/wallpapers');
    if (!await dir.exists()) await dir.create(recursive: true);
    final old = of(roomId);
    final target = File('${dir.path}/${roomId}_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await photo.copy(target.path);
    _data[roomId] = {'path': target.path, 'dim': dim, 'tint': tint};
    notifyListeners();
    await _store.write(_data);
    if (old != null) _deleteQuietly(old.path);
  }

  Future<void> remove(String roomId) async {
    final old = of(roomId);
    _data.remove(roomId);
    notifyListeners();
    await _store.write(_data);
    if (old != null) _deleteQuietly(old.path);
  }

  void _deleteQuietly(String path) {
    File(path).delete().catchError((_) => File(path));
  }
}
