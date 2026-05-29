// Firebase yapılandırması — `flutterfire configure` ile güncellenir.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web henüz desteklenmiyor.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions bu platform için yapılandırılmadı.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAq5jaYyvvaQKTYZP_w0SE3HaU3RPMD0x0',
    appId: '1:866944055436:android:52c9aedf72a5d9c72f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    databaseURL:
        'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyADL_79NO11YrNFl8JLLsjPDPNGiYYz6VI',
    appId: '1:866944055436:ios:d35b461c866a37b42f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    databaseURL:
        'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    iosBundleId: 'com.directdrop.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyADL_79NO11YrNFl8JLLsjPDPNGiYYz6VI',
    appId: '1:866944055436:ios:d35b461c866a37b42f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    databaseURL:
        'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    iosBundleId: 'com.directdrop.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBkwAhofKHTkf3QXEidLoATt7Yn0cxLMs8',
    appId: '1:866944055436:web:f4a5e8bb761d46482f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    authDomain: 'personaltrainer-77e4c.firebaseapp.com',
    databaseURL:
        'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    measurementId: 'G-9G6FZRQD9N',
  );
}
