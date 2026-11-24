// The real Comms web app, pointed at the local Firebase emulators, with a few hooks
// so a test script can sign in, call, answer and hang up. Used by tool/call_test.mjs:
//
//   flutter build web -t tool/call_test_main.dart -o build/web_calltest
//
// Never deployed; the hooks only exist in this build.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:comms/main.dart';
import 'package:comms/models/call_model.dart';
import 'package:comms/models/user_model.dart';
import 'package:comms/services/call_service.dart';
import 'package:comms/services/local_prefs.dart';
import 'package:comms/services/user_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

const _options = FirebaseOptions(
  apiKey: 'demo-key',
  appId: '1:1:web:1',
  messagingSenderId: '1',
  projectId: 'demo-comms',
  authDomain: 'demo-comms.firebaseapp.com',
);

void _hook(String name, JSFunction fn) => globalContext.setProperty(name.toJS, fn);

/// Runs [body] and hands back its result, or the error as text (Dart errors can't be read from JavaScript).
JSPromise<JSString> _guard(Future<String> Function() body) => () async {
      try {
        return (await body()).toJS;
      } catch (e) {
        return 'error: $e'.toJS;
      }
    }().toJS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: _options);
  await FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 9099);
  FirebaseFirestore.instance.useFirestoreEmulator('127.0.0.1', 8080);
  await Nicknames.instance.load();
  await Wallpapers.instance.load();

  final calls = CallService.instance;

  _hook('commsSignIn', ((JSString uid) => _guard(() async {
        final id = uid.toDart;
        final token = jsonEncode({'sub': id, 'email': '$id@test.dev', 'email_verified': true, 'name': id});
        final result = await FirebaseAuth.instance.signInWithCredential(GoogleAuthProvider.credential(idToken: token));
        final user = result.user!;
        final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);
        if (!(await ref.get()).exists) {
          await ref.set(UserModel(uid: user.uid, name: id, email: '$id@test.dev', isOnline: true).toMap());
        }
        return user.uid;
      })).toJS);

  _hook('commsCall', ((JSString to, JSBoolean video) => _guard(() async {
        final me = await UserService.instance.getUser(FirebaseAuth.instance.currentUser!.uid, fresh: true);
        final other = await UserService.instance.getUser(to.toDart, fresh: true);
        final problem = await calls.startCall(me: me!, other: other!, type: video.toDart ? CallType.video : CallType.audio);
        return problem ?? 'ok';
      })).toJS);

  _hook('commsAccept', (() => _guard(() async {
        await calls.accept();
        return 'ok';
      })).toJS);
  _hook('commsDecline', (() => _guard(() async {
        await calls.decline();
        return 'ok';
      })).toJS);
  _hook('commsHangUp', (() => _guard(() async {
        await calls.hangUp();
        return 'ok';
      })).toJS);
  _hook('commsToggleCamera', (() => _guard(() async {
        calls.toggleCamera();
        return 'ok';
      })).toJS);
  _hook('commsState', (() => jsonEncode({
        'phase': calls.phase.name,
        'message': calls.endMessage,
        'status': calls.call?.status.name,
        'note': calls.mediaNote,
        'local': calls.localStream?.getTracks().map((t) => t.kind).toList(),
        'remote': calls.remoteStream?.getTracks().map((t) => t.kind).toList(),
      }).toJS).toJS);

  runApp(const CommsApp());
}
