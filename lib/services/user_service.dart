import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<UserModel?> getUser(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    if (doc.exists) {
      return UserModel.fromMap(doc.data()!);
    }
    return null;
  }

  Stream<UserModel?> getUserStream(String uid) {
    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists ? UserModel.fromMap(doc.data()!) : null);
  }

  Future<List<UserModel>> searchUsers(String query) async {
    if (query.isEmpty) return [];

    final queryLower = query.toLowerCase();

    // Search by email (exact prefix match)
    final emailResults = await _firestore
        .collection('users')
        .where('email', isGreaterThanOrEqualTo: queryLower)
        .where('email', isLessThan: '${queryLower}z')
        .limit(10)
        .get();

    // Search by name
    final nameResults = await _firestore
        .collection('users')
        .orderBy('name')
        .startAt([query.substring(0, 1).toUpperCase() + query.substring(1)])
        .endAt(['${query.substring(0, 1).toUpperCase() + query.substring(1)}\uf8ff'])
        .limit(10)
        .get();

    final Map<String, UserModel> uniqueUsers = {};
    for (final doc in emailResults.docs) {
      uniqueUsers[doc.id] = UserModel.fromMap(doc.data());
    }
    for (final doc in nameResults.docs) {
      uniqueUsers[doc.id] = UserModel.fromMap(doc.data());
    }

    return uniqueUsers.values.toList();
  }

  Future<void> updateUserProfile({
    required String uid,
    String? name,
    String? photoUrl,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (photoUrl != null) updates['photoUrl'] = photoUrl;
    if (updates.isNotEmpty) {
      await _firestore.collection('users').doc(uid).update(updates);
    }
  }

  Future<void> addContact(String currentUid, String contactUid) async {
    await _firestore.collection('users').doc(currentUid).update({
      'contacts': FieldValue.arrayUnion([contactUid]),
    });
  }

  Future<void> removeContact(String currentUid, String contactUid) async {
    await _firestore.collection('users').doc(currentUid).update({
      'contacts': FieldValue.arrayRemove([contactUid]),
    });
  }

  Stream<List<UserModel>> getContacts(String uid) {
    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .asyncMap((doc) async {
      if (!doc.exists) return [];
      final contacts = List<String>.from(doc.data()?['contacts'] ?? []);
      if (contacts.isEmpty) return [];

      final List<UserModel> users = [];
      // Firestore whereIn limited to 30 items
      for (var i = 0; i < contacts.length; i += 30) {
        final batch = contacts.sublist(
          i,
          i + 30 > contacts.length ? contacts.length : i + 30,
        );
        final results = await _firestore
            .collection('users')
            .where('uid', whereIn: batch)
            .get();
        users.addAll(results.docs.map((d) => UserModel.fromMap(d.data())));
      }
      return users;
    });
  }
}
