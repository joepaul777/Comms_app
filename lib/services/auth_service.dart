import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/user_model.dart';
import 'e2e_service.dart';
import 'notification_service.dart';
import 'user_service.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();
  factory AuthService() => instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _google = GoogleSignIn();
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Returns null if the person closed the Google picker.
  Future<UserCredential?> signInWithGoogle() async {
    if (kIsWeb) {
      // The browser's own Google sign-in window.
      try {
        final result = await _auth.signInWithPopup(GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'}));
        if (result.user != null) await _saveProfile(result.user!);
        return result;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'popup-closed-by-user' || e.code == 'cancelled-popup-request') return null;
        rethrow;
      }
    }
    final account = await _google.signIn();
    if (account == null) return null;
    final auth = await account.authentication;
    final credential = GoogleAuthProvider.credential(accessToken: auth.accessToken, idToken: auth.idToken);
    final result = await _auth.signInWithCredential(credential);
    if (result.user != null) await _saveProfile(result.user!);
    return result;
  }

  Future<void> _saveProfile(User user) async {
    final ref = _db.collection('users').doc(user.uid);
    final snapshot = await ref.get();
    if (!snapshot.exists) {
      await ref.set(UserModel(
        uid: user.uid,
        name: user.displayName ?? 'Comms user',
        email: (user.email ?? '').toLowerCase(),
        photoUrl: user.photoURL ?? '',
        isOnline: true,
      ).toMap());
      return;
    }
    final data = snapshot.data()!;
    final name = (data['name'] as String?)?.trim().isNotEmpty == true ? data['name'] as String : (user.displayName ?? 'Comms user');
    final photo = data['photoUrl'] as String? ?? '';
    await ref.update({
      'isOnline': true,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
      'nameLower': name.toLowerCase(),
      // Keep a photo the person chose themselves; otherwise follow their Google photo.
      if (!photo.startsWith('data:image')) 'photoUrl': user.photoURL ?? photo,
    });
  }

  Future<void> signOut() async {
    final uid = currentUserId;
    if (uid != null) {
      await UserService.instance.setOnline(uid, false);
      await NotificationService.instance.forgetDevice();
      // A browser may be shared, so it forgets the encryption key too. The phone keeps it.
      if (kIsWeb) await E2E.instance.forget(uid);
    }
    if (!kIsWeb) await _google.signOut();
    await _auth.signOut();
  }
}
