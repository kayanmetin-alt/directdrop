import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/app_version_service.dart';
import 'services/download_directory_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/notification_service.dart';
import 'services/transfer_history_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  String? startupError;

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    try {
      FirebaseDatabase.instance.setPersistenceEnabled(false);
    } catch (e) {
      debugPrint('Firebase persistence kapatılamadı: $e');
    }

    if (Platform.isIOS || Platform.isAndroid) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }

    try {
      await FirebaseAuthService.instance.ensureSignedIn();
    } catch (e, stack) {
      startupError = e.toString();
      debugPrint('Firebase Auth başlatılamadı: $e\n$stack');
    }

    if (startupError == null) {
      try {
        await NotificationService.instance.initialize();
      } catch (e, stack) {
        debugPrint('Bildirim servisi başlatılamadı: $e\n$stack');
      }
      unawaited(AppVersionService.instance.load());
      unawaited(_startBackgroundServices());
    }
  } catch (e, stack) {
    startupError = 'Uygulama başlatılamadı: $e';
    debugPrint('main başlatma hatası: $e\n$stack');
  }

  runApp(DirectDropApp(startupError: startupError));
}

Future<void> _startBackgroundServices() async {
  try {
    await TransferHistoryService.instance.load();
    await DownloadDirectoryService.instance.load();
  } catch (e, stack) {
    debugPrint('Arka plan servisleri başlatılamadı: $e\n$stack');
  }
}

class DirectDropApp extends StatefulWidget {
  const DirectDropApp({super.key, this.startupError});

  final String? startupError;

  @override
  State<DirectDropApp> createState() => _DirectDropAppState();
}

class _DirectDropAppState extends State<DirectDropApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        FirebaseAuthService.instance.ensureSignedIn().catchError((Object e) {
          debugPrint('Auth yenileme: $e');
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final startupError = widget.startupError;
    return MaterialApp(
      title: 'DirectDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: startupError != null
          ? _StartupErrorScreen(message: startupError)
          : const HomeScreen(),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'DirectDrop başlatılamadı',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Text(message),
              const SizedBox(height: 24),
              const Text(
                'Kontrol listesi:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text('• Firebase Console → Authentication → Anonymous → Enable'),
              const Text('• Uygulamayı kapatıp yeniden açın'),
              if (Platform.isIOS)
                const Text('• Xcode → Signing & Capabilities → Team seçili olsun'),
              if (Platform.isMacOS)
                const Text(
                  '• Keychain Access uygulamasında "DirectDrop" veya '
                  '"firebase" girdilerini silip tekrar deneyin',
                ),
            ],
          ),
        ),
      ),
    );
  }
}
