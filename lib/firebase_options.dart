// Firebase yapılandırması — `flutterfire configure` ile güncelleyin.
// Şimdilik placeholder; README'deki adımları izleyin.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web henüz desteklenmiyor.');
    }
    switch (defaultTargetPlatform) {
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

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyADL_79NO11YrNFl8JLLsjPDPNGiYYz6VI',
    appId: '1:866944055436:ios:d35b461c866a37b42f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    databaseURL: 'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    iosBundleId: 'com.directdrop.app',
  );

  // TODO: Firebase Console'dan alınan değerlerle değiştirin.

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyADL_79NO11YrNFl8JLLsjPDPNGiYYz6VI',
    appId: '1:866944055436:ios:d35b461c866a37b42f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    databaseURL: 'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    iosBundleId: 'com.directdrop.app',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBkwAhofKHTkf3QXEidLoATt7Yn0cxLMs8',
    appId: '1:866944055436:web:f4a5e8bb761d46482f63a9',
    messagingSenderId: '866944055436',
    projectId: 'personaltrainer-77e4c',
    authDomain: 'personaltrainer-77e4c.firebaseapp.com',
    databaseURL: 'https://personaltrainer-77e4c-default-rtdb.europe-west1.firebasedatabase.app',
    storageBucket: 'personaltrainer-77e4c.firebasestorage.app',
    measurementId: 'G-9G6FZRQD9N',
  );

}