import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'e2e_service.dart';
import 'user_service.dart';

/// A device asking for the account's encryption key.
class LinkRequest {
  final String oneOffKey;
  final String device;
  final String code;
  final DateTime at;
  const LinkRequest(this.oneOffKey, this.device, this.code, this.at);
}

/// Lets a second device (Comms in a browser) read the same messages as the phone,
/// without the server ever being able to read the key.
///
/// 1. The new device makes a one-off key pair and posts the public half to the
///    person's private document (which only they can open), and shows a 6-digit code.
/// 2. The phone shows "Link Chrome on Windows?" with the same code. Once the person
///    says yes, it locks the account's key for that one-off key and posts it back.
/// 3. The new device unlocks it, checks it matches the key on the profile, and keeps it.
///
/// Someone who got into the Google account still can't link a device without the
/// phone saying yes, and the server only ever sees locked bytes.
class DeviceLink {
  DeviceLink._();

  /// Requests older than this are ignored.
  static const lifetime = Duration(minutes: 10);

  static DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      FirebaseFirestore.instance.collection('users').doc(uid).collection('private').doc('link');

  static String _aad(String uid, String oneOffKey) => 'link:$uid:$oneOffKey';

  // ---- The new device -------------------------------------------------------

  /// Asks the person's other device for the key. Returns the code to show, and a
  /// future that finishes with true once the key has arrived and been saved, or
  /// false if the other device said no.
  static Future<(String code, Future<bool> done, VoidCallback cancel)> ask(String uid, String device) async {
    final (pair, oneOffKey) = await E2E.oneOffKeyPair();
    final code = await E2E.linkCode(oneOffKey);
    await _doc(uid).set({
      'pub': oneOffKey,
      'device': device,
      'status': 'waiting',
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    final result = Completer<bool>();
    late final StreamSubscription sub;
    var handling = false;
    sub = _doc(uid).snapshots().listen((snap) async {
      final data = snap.data();
      if (result.isCompleted || handling || data == null || data['pub'] != oneOffKey) return;
      if (data['status'] == 'denied') {
        result.complete(false);
        return;
      }
      final box = data['box'];
      if (data['status'] != 'approved' || box is! String) return;
      handling = true;
      try {
        final account = (await UserService.instance.getUser(uid, fresh: true))?.publicKey;
        if (account == null) throw StateError('no key on the profile');
        final seed = await E2E.unlockHandedKey(pair, oneOffKey, account, box, aad: _aad(uid, oneOffKey));
        await E2E.instance.adoptSeed(uid, seed);
        await _doc(uid).delete().catchError((_) {});
        result.complete(true);
      } catch (e) {
        debugPrint('link failed: $e');
        if (!result.isCompleted) result.completeError(e);
      }
    }, onError: (Object e) {
      if (!result.isCompleted) result.completeError(e);
    });
    result.future.whenComplete(sub.cancel).ignore();
    void cancel() {
      sub.cancel();
      if (!result.isCompleted) result.complete(false);
      _doc(uid).get().then((snap) {
        if (snap.data()?['pub'] == oneOffKey) _doc(uid).delete();
      }).catchError((_) {});
    }

    return (code, result.future, cancel);
  }

  // ---- The device that has the key -------------------------------------------

  /// New requests to link a device, while this device holds the account's key.
  static Stream<LinkRequest> requests(String uid) {
    final shown = <String>{};
    return _doc(uid).snapshots().asyncExpand((snap) async* {
      final data = snap.data();
      final pub = data?['pub'];
      if (data == null || pub is! String || data['status'] != 'waiting' || shown.contains(pub)) return;
      final at = DateTime.fromMillisecondsSinceEpoch((data['at'] as num?)?.toInt() ?? 0);
      if (DateTime.now().difference(at) > lifetime) return;
      // Only a device that has the key on the profile can hand it over.
      if (!await E2E.instance.ready() || E2E.instance.uid != uid) return;
      final profileKey = UserService.instance.cached(uid)?.publicKey ?? (await UserService.instance.getUser(uid, fresh: true))?.publicKey;
      if (profileKey != E2E.instance.publicKey) return;
      if (E2E.instance.publicKey == null || pub == E2E.instance.publicKey) return;
      shown.add(pub);
      yield LinkRequest(pub, (data['device'] as String?)?.trim().isNotEmpty == true ? data['device'] as String : 'A browser', await E2E.linkCode(pub), at);
    });
  }

  static Future<void> approve(String uid, LinkRequest request) async {
    final box = await E2E.instance.lockKeyFor(request.oneOffKey, aad: _aad(uid, request.oneOffKey));
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final snap = await tx.get(_doc(uid));
      if (snap.data()?['pub'] != request.oneOffKey) throw StateError('That request has gone');
      tx.update(_doc(uid), {'status': 'approved', 'box': box});
    });
  }

  static Future<void> deny(String uid, LinkRequest request) async {
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(_doc(uid));
        if (snap.data()?['pub'] != request.oneOffKey) return;
        tx.update(_doc(uid), {'status': 'denied'});
      });
    } catch (_) {}
  }
}
