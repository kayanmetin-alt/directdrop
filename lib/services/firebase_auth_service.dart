import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Her cihaz anonim Firebase Auth oturumu açar; RTDB kuralları auth.uid ile korunur.
class FirebaseAuthService {
  FirebaseAuthService._();

  static final FirebaseAuthService instance = FirebaseAuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  String? get uid => _auth.currentUser?.uid;

  Future<String> requireUid() async {
    await ensureSignedIn();
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('Firebase Auth oturumu açılamadı.');
    }
    return user.uid;
  }

  Future<void> ensureSignedIn() async {
    if (_auth.currentUser != null) return;

    try {
      await _auth.signInAnonymously();
      debugPrint('Firebase anonim oturum: ${_auth.currentUser?.uid}');
    } on FirebaseAuthException catch (e) {
      throw StateError(
        'Firebase Auth başarısız (${e.code}). '
        'Console\'da Anonymous sign-in etkin mi kontrol edin.',
      );
    }
  }
}
