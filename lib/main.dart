import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/incoming_connect_screen.dart';
import 'screens/incoming_reconnect_screen.dart';
import 'screens/recent_connect_screen.dart';
import 'services/app_version_service.dart';
import 'services/download_directory_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/notification_service.dart';
import 'services/paired_devices_service.dart';
import 'services/session_cleanup_service.dart';
import 'services/active_session_registry.dart';
import 'services/paired_auto_connect_service.dart';
import 'services/persistent_invite_code_service.dart';
import 'services/recent_connection_service.dart';
import 'services/screen_wake_service.dart';
import 'services/transfer_history_service.dart';
import 'services/wake_listener_service.dart';
import 'utils/directdrop_scroll_behavior.dart';
import 'models/reconnect_request.dart';
import 'models/paired_device.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
      await SessionCleanupService.instance.resetOnLaunch();
      await SessionCleanupService.instance.onLaunchAfterAuth();
      try {
        await NotificationService.instance.initialize();
      } catch (e, stack) {
        debugPrint('Bildirim servisi başlatılamadı: $e\n$stack');
      }
      unawaited(AppVersionService.instance.load());
      unawaited(_startBackgroundServices());
      _wireAutoReconnect();
      _wireIncomingReconnect();
      _wireNotificationWake();
      _wireWakeListener();
    }
  } catch (e, stack) {
    startupError = 'Uygulama başlatılamadı: $e';
    debugPrint('main başlatma hatası: $e\n$stack');
  }

  runApp(DirectDropApp(startupError: startupError));
}

Future<void> _startBackgroundServices() async {
  try {
    await PairedDevicesService.instance.load();
    await TransferHistoryService.instance.load();
    await DownloadDirectoryService.instance.load();
    if (Platform.isIOS || Platform.isAndroid) {
      await ScreenWakeService.instance.load();
    }
    unawaited(PersistentInviteCodeService.instance.getOrCreate());
    await RecentConnectionService.instance.ensureListening();
    unawaited(PairedAutoConnectService.instance.ensureRunning());
    unawaited(WakeListenerService.instance.ensureRunning());
  } catch (e, stack) {
    debugPrint('Arka plan servisleri başlatılamadı: $e\n$stack');
  }
}

void _wireNotificationWake() {
  NotificationService.instance.onWakeNotificationTapped = (request) {
    if (request.type == WakeRequestType.reconnect) return;
    _openIncomingConnect(request);
  };
}

void _wireWakeListener() {
  WakeListenerService.instance.setHandler((request) {
    if (request.type == WakeRequestType.reconnect) return;
    _openIncomingConnect(request);
  });
}

void _wireIncomingReconnect() {
  NotificationService.instance.onReconnectPushReceived = (request) {
    unawaited(RecentConnectionService.instance.promptIncomingReconnect(request));
  };

  NotificationService.instance.onReconnectNotificationTapped = (request) {
    RecentConnectionService.instance.promptIncomingReconnect(request);
    _openIncomingReconnect(request);
  };

  NotificationService.instance.onReconnectNotificationApproved = (request) {
    RecentConnectionService.instance.promptIncomingReconnect(request);
    _openIncomingReconnect(request, autoApprove: true);
  };

  NotificationService.instance.onReconnectNotificationRejected = (request) {
    unawaited(
      RecentConnectionService.instance.rejectIncomingReconnectRequest(request),
    );
  };
}

void _openIncomingReconnect(
  ReconnectRequest request, {
  PairedDevice? peer,
  bool autoApprove = false,
}) {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;

  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => IncomingReconnectScreen(
        request: request,
        peer: peer,
        autoApprove: autoApprove,
      ),
    ),
  );
}

void _openIncomingConnect(WakeRequest request) {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => IncomingConnectScreen(request: request),
    ),
  );
}

void _wireAutoReconnect() {
  RecentConnectionService.instance.openAutoConnectScreen = (peer) {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => RecentConnectScreen(
          peer: peer,
          autoAcceptInvite: true,
        ),
      ),
    );
  };
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
      unawaited(RecentConnectionService.instance.ensureListening());
      unawaited(WakeListenerService.instance.ensureRunning());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(SessionCleanupService.instance.markGracefulShutdown());
      if (state == AppLifecycleState.detached) {
        RecentConnectionService.instance.stopListening();
        unawaited(ActiveSessionRegistry.instance.disconnectActive());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final startupError = widget.startupError;
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'DirectDrop',
      debugShowCheckedModeBanner: false,
      scrollBehavior: Platform.isAndroid
          ? const DirectDropScrollBehavior()
          : null,
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
              if (Platform.isAndroid)
                const Text('• google-services.json ve Firebase Android uygulaması tanımlı olsun'),
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
