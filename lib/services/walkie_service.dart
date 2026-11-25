import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:comms_device/comms_device.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_room_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import '../platform/platform.dart';
import 'chat_service.dart';
import 'e2e_service.dart';
import 'media_service.dart';
import 'user_service.dart';

/// Walkie-talkie: hold a chat in the chat list and talk; when you let go, the other
/// person's phone plays it out loud straight away, through whatever they're listening
/// with (speaker, headphones or Bluetooth).
///
/// It's off until a person turns it on, and their phone stays quiet while it's on
/// silent, vibrate or Do Not Disturb. Every clip is also kept in the chat as a voice
/// message (end-to-end encrypted like the rest), so nothing is missed.
class Walkie {
  Walkie._();

  /// Longest clip; it is sent when time runs out.
  static const maxLength = Duration(seconds: 30);

  // ---- This person's setting ---------------------------------------------------

  /// Kept on the phone too, so it can be checked when a clip arrives with Comms closed.
  static Future<File> _file() async => File('${(await supportDirectory()).path}/walkie.json');

  static Future<bool> enabled() async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      return (jsonDecode(await f.readAsString()) as Map)['on'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Also published on the profile, so people can see whether they can talk to you.
  static Future<void> setEnabled(String uid, bool on) async {
    try {
      await (await _file()).writeAsString(jsonEncode({'on': on}));
    } catch (_) {}
    await FirebaseFirestore.instance.collection('users').doc(uid).update({'walkieTalkie': on});
  }

  // ---- Sending -------------------------------------------------------------------

  /// The people in [room] who can hear a walkie-talkie message right now.
  static Future<List<UserModel>> listeners(ChatRoomModel room, String myUid) async {
    final others = room.participants.where((id) => id != myUid).toList();
    final people = await UserService.instance.getUsers(others, maxAge: Duration.zero);
    return people.where((p) => p.walkieTalkie).toList();
  }

  /// Sends a recorded clip. Throws NoKeyException if someone needs to update Comms.
  static Future<void> send({required ChatRoomModel room, required UserModel sender, required File clip, required Duration length}) async {
    final chat = ChatService.instance;
    chat.checkCanSend();
    await chat.recipientKeys(room, sender.uid);
    final id = chat.newId();
    final ext = MediaService.extensionOf(clip.path, MessageType.audio);
    final contentKey = E2E.newContentKey();
    final local = await MediaService.instance.keepCopy(clip, id, ext);
    final url = await MediaService.instance.uploadEncrypted(local, contentKey);
    await chat.sendMessage(
      room: room,
      sender: sender,
      text: '',
      type: MessageType.audio,
      id: id,
      mediaUrl: url,
      mediaName: '$id.$ext',
      mediaSize: await local.length(),
      durationMs: length.inMilliseconds,
      contentKey: contentKey,
      walkie: true,
    );
  }

  // ---- Receiving -----------------------------------------------------------------

  static bool _playing = false;

  /// Plays a walkie-talkie clip out loud, if this person allows it, the phone isn't
  /// silenced and no call is on. Waits until it has finished (or [maxLength] passes).
  static Future<void> playIfAllowed(File clip, {bool inCall = false}) async {
    if (inCall || _playing || kIsWeb) return;
    if (!await enabled()) return;
    if (!await CommsDevice.soundOn()) return;
    if (!await clip.exists()) return;
    _playing = true;
    final player = AudioPlayer();
    try {
      // Plays where the phone's sound is going now (speaker, headphones or Bluetooth),
      // turning other sound down for a moment rather than stopping it.
      await player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ));
      final done = player.onPlayerComplete.first;
      await player.play(localAudio(clip));
      await done.timeout(maxLength + const Duration(seconds: 5));
    } catch (e) {
      debugPrint('walkie-talkie playback failed: $e');
    } finally {
      _playing = false;
      await player.dispose();
    }
  }
}
