/// Settings that make voices on calls clearer. Kept free of Flutter so they can be
/// tested on their own.
library;

/// Opus (the voice codec every Comms call uses) settings asked of the other side:
/// a higher bit rate for a fuller voice, built-in recovery from lost packets
/// (in-band FEC), no switching off during short pauses (which clips the start of
/// words), mono and full 48 kHz playback.
const _voiceSettings = {
  'useinbandfec': '1',
  'usedtx': '0',
  'maxaveragebitrate': '48000',
  'stereo': '0',
  'sprop-stereo': '0',
  'maxplaybackrate': '48000',
};

/// Rewrites an offer or answer so the voice is sent with [_voiceSettings]. Anything
/// that isn't an Opus format line is left exactly as it was.
String clearVoiceSdp(String sdp) {
  final opus = RegExp(r'^a=rtpmap:(\d+) opus/48000', caseSensitive: false, multiLine: true)
      .allMatches(sdp)
      .map((m) => m.group(1)!)
      .toSet();
  if (opus.isEmpty) return sdp;
  final newline = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(newline);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!line.startsWith('a=fmtp:')) continue;
    final space = line.indexOf(' ');
    if (space < 0) continue;
    final pt = line.substring('a=fmtp:'.length, space);
    if (!opus.contains(pt)) continue;
    final params = <String, String>{};
    for (final part in line.substring(space + 1).split(';')) {
      final kv = part.trim();
      if (kv.isEmpty) continue;
      final eq = kv.indexOf('=');
      if (eq < 0) {
        params[kv] = '';
      } else {
        params[kv.substring(0, eq)] = kv.substring(eq + 1);
      }
    }
    params.addAll(_voiceSettings);
    lines[i] = 'a=fmtp:$pt ${params.entries.map((e) => e.value.isEmpty ? e.key : '${e.key}=${e.value}').join(';')}';
  }
  return lines.join(newline);
}

/// What to ask of the microphone. Browsers take the standard names; Android's
/// WebRTC only understands its own "goog…" names (anything else is silently ignored).
Map<String, dynamic> microphoneConstraints({required bool web, required bool noiseReduction, String? deviceId}) {
  if (web) {
    return {
      if (deviceId != null) 'deviceId': {'exact': deviceId},
      'echoCancellation': true,
      'noiseSuppression': noiseReduction,
      'autoGainControl': noiseReduction,
      // Newer Chrome: stronger focus on the voice when available; ignored elsewhere.
      'voiceIsolation': noiseReduction,
      'channelCount': 1,
    };
  }
  final on = noiseReduction ? 'true' : 'false';
  return {
    'mandatory': {
      'googEchoCancellation': 'true',
      'googEchoCancellation2': 'true',
      'googDAEchoCancellation': 'true',
      'googHighpassFilter': 'true',
      'googNoiseSuppression': on,
      'googNoiseSuppression2': on,
      'googAutoGainControl': on,
      'googAutoGainControl2': on,
      'googTypingNoiseDetection': on,
    },
    'optional': [
      if (deviceId != null) {'sourceId': deviceId},
    ],
  };
}
