import 'package:comms/services/call_audio.dart';
import 'package:flutter_test/flutter_test.dart';

const _offer = 'v=0\r\n'
    'o=- 1 2 IN IP4 127.0.0.1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 9\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=rtcp-fb:111 transport-cc\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
    'a=rtpmap:63 red/48000/2\r\n'
    'a=fmtp:63 111/111\r\n'
    'a=rtpmap:9 G722/8000\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=fmtp:96 x-google-start-bitrate=800\r\n';

void main() {
  test('the voice format line gets the clear-voice settings, keeping its own', () {
    final tuned = clearVoiceSdp(_offer);
    final line = tuned.split('\r\n').firstWhere((l) => l.startsWith('a=fmtp:111 '));
    final params = line.substring('a=fmtp:111 '.length).split(';').toSet();
    expect(params, containsAll(['minptime=10', 'useinbandfec=1', 'usedtx=0', 'maxaveragebitrate=48000', 'stereo=0', 'maxplaybackrate=48000']));
    expect(params.where((p) => p.startsWith('useinbandfec')).length, 1, reason: 'no duplicates');
  });

  test('everything else is left alone', () {
    final before = _offer.split('\r\n');
    final after = clearVoiceSdp(_offer).split('\r\n');
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      if (before[i].startsWith('a=fmtp:111 ')) continue;
      expect(after[i], before[i]);
    }
  });

  test('a description without Opus is returned unchanged', () {
    const sdp = 'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n';
    expect(clearVoiceSdp(sdp), sdp);
  });

  test('Android gets its own microphone settings, browsers the standard ones', () {
    final android = microphoneConstraints(web: false, noiseReduction: false, deviceId: '7');
    expect((android['mandatory'] as Map)['googNoiseSuppression'], 'false');
    expect((android['mandatory'] as Map)['googEchoCancellation'], 'true');
    expect(android['optional'], [
      {'sourceId': '7'},
    ]);
    final web = microphoneConstraints(web: true, noiseReduction: true, deviceId: 'abc');
    expect(web['noiseSuppression'], true);
    expect(web['deviceId'], {'exact': 'abc'});
  });
}
