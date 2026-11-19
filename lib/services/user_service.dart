import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';
import 'shared_stream.dart';

class UserService {
  UserService._();
  static final UserService instance = UserService._();
  factory UserService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, UserModel> _cache = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Map<String, SharedStream<UserModel?>> _streams = {};

  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');

  /// Things only this person can see: their contact list and their notification address.
  DocumentReference<Map<String, dynamic>> privateDoc(String uid) => _users.doc(uid).collection('private').doc('data');

  UserModel _remember(String uid, UserModel user) {
    _fetchedAt[uid] = DateTime.now();
    return _cache[uid] = user;
  }

  UserModel? cached(String uid) => _cache[uid];

  Future<UserModel?> getUser(String uid, {bool fresh = false}) async {
    if (!fresh && _cache.containsKey(uid)) return _cache[uid];
    final doc = await _users.doc(uid).get(fresh ? const GetOptions(source: Source.server) : null);
    if (!doc.exists) return null;
    final user = UserModel.fromMap(doc.data()!);
    // Keep the private contact list on our own profile.
    final cachedContacts = _cache[uid]?.contacts;
    return _remember(uid, uid == FirebaseAuth.instance.currentUser?.uid && cachedContacts != null ? user.withContacts(cachedContacts) : user);
  }

  /// A person's profile, live. Every screen asking for the same person shares one listener.
  Stream<UserModel?> userStream(String uid) {
    return (_streams[uid] ??= SharedStream<UserModel?>(
      () => uid == FirebaseAuth.instance.currentUser?.uid
          ? _ownProfile(uid)
          : _users.doc(uid).snapshots().map((doc) {
              if (!doc.exists) return null;
              return _remember(uid, UserModel.fromMap(doc.data()!));
            }),
      onClosed: () => _streams.remove(uid),
    ))
        .stream;
  }

  /// Your own profile, with your contact list from the private document.
  Stream<UserModel?> _ownProfile(String uid) {
    late final StreamController<UserModel?> controller;
    StreamSubscription? public, private;
    UserModel? profile;
    List<String>? contacts;
    var gotProfile = false, gotPrivate = false;
    void emit() {
      if (!gotProfile || !gotPrivate) return;
      final p = profile;
      if (p == null) {
        controller.add(null);
        return;
      }
      controller.add(_remember(uid, contacts == null ? p : p.withContacts(contacts!)));
    }

    controller = StreamController<UserModel?>(
      onListen: () {
        public = _users.doc(uid).snapshots().listen((doc) {
          profile = doc.exists ? UserModel.fromMap(doc.data()!) : null;
          gotProfile = true;
          emit();
        }, onError: controller.addError);
        private = privateDoc(uid).snapshots().listen((doc) {
          final list = doc.data()?['contacts'];
          contacts = list is List ? List<String>.from(list) : null;
          gotPrivate = true;
          emit();
        }, onError: (_) {
          gotPrivate = true;
          emit();
        });
      },
      onCancel: () async {
        await public?.cancel();
        await private?.cancel();
      },
    );
    return controller.stream;
  }

  /// Moves the contact list off the public profile (where anyone signed in could read it)
  /// into the private document. Safe to run every time.
  Future<void> movePrivateData(String uid) async {
    try {
      final doc = await _users.doc(uid).get();
      final data = doc.data();
      if (data == null || !data.containsKey('contacts')) return;
      final list = data['contacts'] is List ? List<String>.from(data['contacts']) : <String>[];
      await privateDoc(uid).set({'contacts': FieldValue.arrayUnion(list)}, SetOptions(merge: true));
      await _users.doc(uid).update({'contacts': FieldValue.delete()});
    } catch (_) {
      // Tried again next time the app opens.
    }
  }

  /// Publishes this phone's public encryption key on the profile.
  Future<void> setPublicKey(String uid, String key) => _users.doc(uid).update({'publicKey': key});

  /// Finds people by the start of their name or email.
  Future<List<UserModel>> search(String query, {required String excludeUid}) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final lower = q.toLowerCase();
    final capitalised = lower[0].toUpperCase() + lower.substring(1);
    final results = await Future.wait([
      _users.where('nameLower', isGreaterThanOrEqualTo: lower).where('nameLower', isLessThan: '$lower').limit(15).get(),
      _users.where('email', isGreaterThanOrEqualTo: lower).where('email', isLessThan: '$lower').limit(15).get(),
      // People who have not opened version 2 yet have no lowercase name stored.
      _users.where('name', isGreaterThanOrEqualTo: capitalised).where('name', isLessThan: '$capitalised').limit(15).get(),
    ]);
    final found = <String, UserModel>{};
    for (final snapshot in results) {
      for (final doc in snapshot.docs) {
        if (doc.id == excludeUid) continue;
        found[doc.id] = _remember(doc.id, UserModel.fromMap(doc.data()));
      }
    }
    final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  Future<void> updateProfile(String uid, {String? name, String? photoUrl}) async {
    final updates = <String, dynamic>{
      if (name != null) 'name': name.trim(),
      if (name != null) 'nameLower': name.trim().toLowerCase(),
      if (photoUrl != null) 'photoUrl': photoUrl,
    };
    if (updates.isNotEmpty) await _users.doc(uid).update(updates);
  }

  Future<void> addContact(String myUid, String contactUid) {
    return privateDoc(myUid).set({'contacts': FieldValue.arrayUnion([contactUid])}, SetOptions(merge: true));
  }

  Future<void> removeContact(String myUid, String contactUid) {
    return privateDoc(myUid).set({'contacts': FieldValue.arrayRemove([contactUid])}, SetOptions(merge: true));
  }

  /// People's profiles, from memory when we have them (and they are newer than [maxAge]).
  Future<List<UserModel>> getUsers(List<String> uids, {Duration? maxAge}) async {
    final now = DateTime.now();
    bool fresh(String id) =>
        _cache.containsKey(id) && (maxAge == null || now.difference(_fetchedAt[id] ?? DateTime(2000)) < maxAge || _streams.containsKey(id));
    final missing = uids.where((id) => !fresh(id)).toSet().toList();
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    for (var i = 0; i < missing.length; i += 30) {
      final chunk = missing.sublist(i, i + 30 > missing.length ? missing.length : i + 30);
      // The database only answers small lists, so nobody can download everyone at once.
      final snap = await _users.where('uid', whereIn: chunk).limit(30).get();
      for (final doc in snap.docs) {
        final user = UserModel.fromMap(doc.data());
        final keep = doc.id == myUid ? _cache[doc.id]?.contacts : null;
        _remember(doc.id, keep != null ? user.withContacts(keep) : user);
      }
    }
    return uids.map((id) => _cache[id]).whereType<UserModel>().toList();
  }

  Stream<List<UserModel>> contacts(String uid) {
    return userStream(uid).asyncMap((me) async {
      final ids = me?.contacts ?? const <String>[];
      if (ids.isEmpty) return <UserModel>[];
      final list = await getUsers(ids);
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    });
  }

  /// Marks this person as busy (ringing or on a call) for the next minute.
  Future<void> setBusy(String uid, bool busy) async {
    try {
      await _users.doc(uid).update({
        'busyUntil': busy ? DateTime.now().add(const Duration(seconds: 60)).millisecondsSinceEpoch : FieldValue.delete(),
      });
    } catch (_) {
      // Not being marked busy only means someone else might ring through.
    }
  }

  Future<void> setOnline(String uid, bool online) async {
    try {
      await _users.doc(uid).update({'isOnline': online, 'lastSeen': DateTime.now().millisecondsSinceEpoch});
    } catch (_) {}
  }
}
