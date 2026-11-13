import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class UserService {
  UserService._();
  static final UserService instance = UserService._();
  factory UserService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final Map<String, UserModel> _cache = {};

  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');

  UserModel? cached(String uid) => _cache[uid];

  Future<UserModel?> getUser(String uid, {bool fresh = false}) async {
    if (!fresh && _cache.containsKey(uid)) return _cache[uid];
    final doc = await _users.doc(uid).get(fresh ? const GetOptions(source: Source.server) : null);
    if (!doc.exists) return null;
    return _cache[uid] = UserModel.fromMap(doc.data()!);
  }

  Stream<UserModel?> userStream(String uid) {
    return _users.doc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return _cache[uid] = UserModel.fromMap(doc.data()!);
    });
  }

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
        found[doc.id] = _cache[doc.id] = UserModel.fromMap(doc.data());
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
    return _users.doc(myUid).update({'contacts': FieldValue.arrayUnion([contactUid])});
  }

  Future<void> removeContact(String myUid, String contactUid) {
    return _users.doc(myUid).update({'contacts': FieldValue.arrayRemove([contactUid])});
  }

  Future<List<UserModel>> getUsers(List<String> uids) async {
    final missing = uids.where((id) => !_cache.containsKey(id)).toSet().toList();
    for (var i = 0; i < missing.length; i += 30) {
      final chunk = missing.sublist(i, i + 30 > missing.length ? missing.length : i + 30);
      final snap = await _users.where('uid', whereIn: chunk).get();
      for (final doc in snap.docs) {
        _cache[doc.id] = UserModel.fromMap(doc.data());
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
