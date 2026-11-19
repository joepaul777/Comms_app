import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../platform/platform.dart';

/// Locks Comms behind the phone's own screen lock (fingerprint, face, PIN or pattern).
///
/// When it is on, Comms asks for it when opened and after being away for a little
/// while, and the app's preview is hidden in the recent-apps screen.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock._();
  static final AppLock instance = AppLock._();

  static const _channel = MethodChannel('comms/lock_screen');

  /// How long Comms can be in the background (picking a photo, say) before it locks.
  static const grace = Duration(seconds: 30);

  bool _enabled = false;
  bool _locked = false;
  bool _asking = false;
  DateTime? _leftAt;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;

  Future<File> _file() async => File('${(await supportDirectory()).path}/security.json');

  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) _enabled = (jsonDecode(await f.readAsString()) as Map)['appLock'] == true;
    } catch (_) {}
    _locked = _enabled;
    WidgetsBinding.instance.addObserver(this);
    await _hidePreview(_enabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled || _asking) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _leftAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final left = _leftAt;
      _leftAt = null;
      if (left != null && DateTime.now().difference(left) >= grace && !_locked) {
        _locked = true;
        notifyListeners();
      }
    }
  }

  /// True if the phone has a screen lock that Comms can use.
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('canLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for the phone's fingerprint, face, PIN or pattern. True when it was given.
  Future<bool> _confirm() async {
    _asking = true;
    try {
      return await _channel.invokeMethod<bool>('unlock') ?? false;
    } catch (_) {
      return false;
    } finally {
      // The prompt itself sends the app to the background briefly; don't count that.
      _leftAt = null;
      _asking = false;
    }
  }

  Future<bool> unlock() async {
    if (!locked) return true;
    final ok = await _confirm();
    if (ok) {
      _locked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Turns the lock on or off. Either way the person has to prove it's them first.
  Future<bool> setEnabled(bool on) async {
    if (on && !await available()) return false;
    if (!await _confirm()) return false;
    _enabled = on;
    _locked = false;
    notifyListeners();
    await _hidePreview(on);
    try {
      await (await _file()).writeAsString(jsonEncode({'appLock': on}));
    } catch (_) {}
    return true;
  }

  Future<void> _hidePreview(bool hide) async {
    try {
      await _channel.invokeMethod('hideInRecents', hide);
    } catch (_) {}
  }
}
