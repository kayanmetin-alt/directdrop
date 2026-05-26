import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'models/paired_device.dart';
import 'screens/home_screen.dart';
import 'screens/incoming_connect_screen.dart';
import 'services/active_session_registry.dart';
import 'services/device_registry_service.dart';
import 'services/notification_service.dart';
import 'services/paired_auto_connect_service.dart';
import 'services/paired_presence_service.dart';
import 'services/paired_devices_service.dart';
import 'services/transfer_history_service.dart';
import 'services/wake_listener_service.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final Set<String> _activeIncomingFromPeers = {};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseDatabase.instance.setPersistenceEnabled(false);
  if (Platform.isIOS || Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  await NotificationService.instance.initialize();
  try {
    final registry = DeviceRegistryService();
    await registry.registerCurrentDevice();
    registry.startHeartbeat();
    await PairedDevicesService.instance.load();
    await TransferHistoryService.instance.load();
    await PairedPresenceService.instance.start();
    await PairedAutoConnectService.instance.start();
    WakeListenerService.instance.setHandler(_handleWakeRequest);
    NotificationService.instance.onWakeNotificationTapped = _handleWakeRequest;
    await WakeListenerService.instance.start();
    await WakeListenerService.instance.processPendingRequests();
  } catch (e) {
    debugPrint('Cihaz kaydı/bağlantı dinleyicisi başlatılamadı: $e');
  }

  runApp(const DirectDropApp());
}

void _handleWakeRequest(WakeRequest request) {
  final fromId = request.fromDeviceId;
  if (fromId.isEmpty) return;

  final isKnown = PairedDevicesService.instance.devices
      .any((d) => d.deviceId == fromId);

  // Eşleşmiş cihazlar arka planda otomatik bağlanır; onay ekranı açılmaz.
  if (isKnown) {
    unawaited(PairedAutoConnectService.instance.handleIncomingWake(request));
    return;
  }

  if (PairedAutoConnectService.instance.isConnectedTo(fromId)) return;
  if (PairedAutoConnectService.instance.isConnectingTo(fromId)) return;

  if (!_activeIncomingFromPeers.add(fromId)) return;

  Future<void>.delayed(const Duration(minutes: 2), () {
    _activeIncomingFromPeers.remove(fromId);
  });

  final navigator = rootNavigatorKey.currentState;
  if (navigator == null) {
    _activeIncomingFromPeers.remove(fromId);
    return;
  }

  navigator
      .push(
        MaterialPageRoute<void>(
          builder: (_) => IncomingConnectScreen(request: request),
        ),
      )
      .whenComplete(() => _activeIncomingFromPeers.remove(fromId));
}

class DirectDropApp extends StatefulWidget {
  const DirectDropApp({super.key});

  @override
  State<DirectDropApp> createState() => _DirectDropAppState();
}

class _DirectDropAppState extends State<DirectDropApp> with WidgetsBindingObserver {
  final _registry = DeviceRegistryService();

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
    if (state == AppLifecycleState.detached) {
      unawaited(_goOffline());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_goOnline());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_markOffline());
    }
  }

  Future<void> _markOffline() async {
    _registry.stopHeartbeat();
    await _registry.setOnline(false);
  }

  Future<void> _goOnline() async {
    await _registry.registerCurrentDevice();
    _registry.startHeartbeat();
    await PairedPresenceService.instance.start();
    await PairedAutoConnectService.instance.start();
    PairedAutoConnectService.instance.onAppResumed();
    unawaited(WakeListenerService.instance.processPendingRequests());
    unawaited(PairedAutoConnectService.instance.processPendingInvites());
  }

  Future<void> _goOffline() async {
    _registry.stopHeartbeat();
    await _registry.setOnline(false);
    await ActiveSessionRegistry.instance.disconnectActive();
    await PairedAutoConnectService.instance.stop();
    await PairedPresenceService.instance.stop();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'DirectDrop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
