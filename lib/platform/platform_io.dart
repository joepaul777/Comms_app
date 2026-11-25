import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

export 'dart:io' show File, Directory, FileSystemException;

Future<Directory> supportDirectory() => getApplicationSupportDirectory();
Future<Directory> documentsDirectory() => getApplicationDocumentsDirectory();
Future<Directory> temporaryDirectory() => getTemporaryDirectory();

/// A picked photo or video, or a finished recording, as a file.
Future<File> fileFromPicked(XFile picked) async => File(picked.path);

/// A stored photo, ready to draw. [cacheWidth] decodes it smaller, to save memory.
ImageProvider localImage(File file, {int? cacheWidth}) => ResizeImage.resizeIfNeeded(cacheWidth, null, FileImage(file));

VideoPlayerController localVideo(File file) => VideoPlayerController.file(file);

Source localAudio(File file) => DeviceFileSource(file.path);

void startRingtone() => FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false);

void stopRingtone() => FlutterRingtonePlayer().stop();

/// What this device is called when it asks to be linked.
String get deviceName => 'Android phone';

/// Starts the app again from the top (only needed in the browser).
void reloadApp() {}

// ---- Picture-in-picture (video calls) ------------------------------------------

const _pip = MethodChannel('comms/pip');
final ValueNotifier<bool> _inPip = ValueNotifier(false);
bool _pipListening = false;

/// True while the call is showing in the phone's small floating window.
ValueListenable<bool> get inPictureInPicture {
  if (!_pipListening) {
    _pipListening = true;
    _pip.setMethodCallHandler((call) async {
      if (call.method == 'changed') _inPip.value = call.arguments == true;
    });
  }
  return _inPip;
}

/// Lets the call go into the small window when the person goes home, shaped like the
/// other person's picture ([width] x [height]). [streamId] is only used in browsers.
Future<void> setPictureInPictureReady(bool ready, {int width = 9, int height = 16, String? streamId}) async {
  inPictureInPicture; // start listening
  try {
    await _pip.invokeMethod('setReady', {'ready': ready, 'width': width, 'height': height});
  } catch (_) {}
}

/// Goes into the small window now (the back button, or the minimise button).
Future<bool> enterPictureInPicture({String? streamId}) async {
  try {
    return await _pip.invokeMethod<bool>('enter') ?? false;
  } catch (_) {
    return false;
  }
}

/// The call ended: close the small window.
Future<void> closePictureInPicture() async {
  try {
    await _pip.invokeMethod('close');
  } catch (_) {}
}
