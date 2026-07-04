import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;
  String? get currentUserId => _auth.currentUser?.uid;
  bool get isSignedIn => _auth.currentUser != null;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential?> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await _auth.signInWithCredential(credential);

      // Create or update user document in Firestore
      if (userCredential.user != null) {
        await _createOrUpdateUser(userCredential.user!);
      }

      return userCredential;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _createOrUpdateUser(User user) async {
    final userDoc = _firestore.collection('users').doc(user.uid);
    final docSnapshot = await userDoc.get();

    if (!docSnapshot.exists) {
      // New user - create document
      final newUser = UserModel(
        uid: user.uid,
        name: user.displayName ?? 'User',
        email: user.email ?? '',
        photoUrl: user.photoURL ?? '',
        isOnline: true,
        lastSeen: DateTime.now(),
        createdAt: DateTime.now(),
      );
      await userDoc.set(newUser.toMap());
    } else {
      // Existing user - update online status
      await userDoc.update({
        'isOnline': true,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
        'photoUrl': user.photoURL ?? '',
        'name': user.displayName ?? docSnapshot.data()?['name'] ?? 'User',
      });
    }
  }

  Future<void> signOut() async {
    try {
      // Set offline before signing out
      if (currentUserId != null) {
        await _firestore.collection('users').doc(currentUserId).update({
          'isOnline': false,
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
        });
      }
      await _googleSignIn.signOut();
      await _auth.signOut();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> setOnlineStatus(bool isOnline) async {
    if (currentUserId != null) {
      await _firestore.collection('users').doc(currentUserId).update({
        'isOnline': isOnline,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }
}
