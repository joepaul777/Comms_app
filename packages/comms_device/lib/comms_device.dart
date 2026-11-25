import 'package:flutter/services.dart';

/// Small device checks Comms needs, also from the notification handler while the app
/// is closed (a plugin is available there; the app's own Android code is not).
class CommsDevice {
  CommsDevice._();

  static const _channel = MethodChannel('comms_device');

  /// True when the phone may make sound: the ringer is on (not silent or vibrate) and
  /// Do Not Disturb is off. False when unsure.
  static Future<bool> soundOn() async {
    try {
      return await _channel.invokeMethod<bool>('soundOn') ?? false;
    } catch (_) {
      return false;
    }
  }
}
