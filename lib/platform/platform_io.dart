import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
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
