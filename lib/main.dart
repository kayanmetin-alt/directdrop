import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:window_manager/window_manager.dart';

import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'screens/incoming_connect_screen.dart';
import 'screens/incoming_reconnect_screen.dart';
import 'screens/recent_connect_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_version_service.dart';
import 'services/desktop_background_service.dart';
import 'services/desktop_overlay_service.dart';
import 'services/desktop_window_service.dart';
import 'services/device_identity_service.dart';
import 'services/device_registry_service.dart';
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
import 'services/startup_gate.dart';
import 'services/transfer_history_service.dart';
import 'services/wake_listener_service.dart';
import 'utils/directdrop_scroll_behavior.dart';
import 'utils/user_facing_error.dart';
import 'widgets/incoming_reconnect_prompt.dart';
import 'models/reconnect_request.dart';
import 'models/paired_device.dart';
import 'providers/transfer_session_controller.dart';
import 'dev/screenshot_capture.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Açılışta ölümcül hata (ör. auth) olursa hata ekranını tetikler.
final ValueNotifier<String?> startupErrorNotifier = ValueNotifier<String?>(null);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (DesktopBackgroundService.isSupported) {
    await windowManager.ensureInitialized();
    await DesktopWindowService.configure();
  }

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  // Firebase çekirdeğini başlat — yereldir, hızlıdır; yine de zaman aşımı koy.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 12));
    try {
      FirebaseDatabase.instance.setPersistenceEnabled(false);
    } catch (e) {
      debugPrint('Firebase persistence kapatılamadı: $e');
    }
    if (Platform.isIOS || Platform.isAndroid) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }
  } catch (e, stack) {
    debugPrint('Firebase başlatılamadı: $e\n$stack');
    startupErrorNotifier.value = 'Uygulama başlatılamadı: $e';
  }

  // UI'ı HEMEN göster — hiçbir ağ işlemi açılışı bloklamasın.
  runApp(const DirectDropApp());

  // Auth + çökme sonrası temizlik + servisleri arka planda, zaman aşımlarıyla yürüt.
  unawaited(_bootstrap());
}

/// Açılış işlerini arka planda, takılmaya karşı korumalı şekilde yürütür.
Future<void> _bootstrap() async {
  if (startupErrorNotifier.value != null) {
    StartupGate.markReady();
    return;
  }

  try {
    await FirebaseAuthService.instance.ensureSignedIn();
  } catch (e, stack) {
    debugPrint('Firebase Auth başlatılamadı: $e\n$stack');
    startupErrorNotifier.value = e.toString();
    StartupGate.markReady();
    return;
  }

  // Çökme/zorla kapatma sonrası yarım kalan oturumları sıfırla (zaman aşımlı).
  try {
    await SessionCleanupService.instance.resetOnLaunch();
    await SessionCleanupService.instance.onLaunchAfterAuth().timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('Çökme sonrası temizlik zaman aşımına uğradı; devam ediliyor.');
      },
    );
  } catch (e, stack) {
    debugPrint('Açılış temizliği hatası: $e\n$stack');
  } finally {
    // Temizlik bitti (ya da zaman aşımı) — dinleyiciler artık ilerleyebilir.
    StartupGate.markReady();
  }

  try {
    await NotificationService.instance.initialize();
  } catch (e, stack) {
    debugPrint('Bildirim servisi başlatılamadı: $e\n$stack');
  }
  unawaited(AppVersionService.instance.load());
  unawaited(_startBackgroundServices());
  _wireAutoReconnect();
  _wireIncomingReconnect();
  _wireFirebaseReconnect();
  _wireNotificationWake();
  _wireWakeListener();
  _wireDesktopOverlay();
  await NotificationService.instance.processInitialMessage();

  if (ScreenshotCapture.isEnabled) {
    unawaited(ScreenshotCapture.runAfterBootstrap());
  }
}

/// Hata ekranındaki "Tekrar dene" düğmesi için: Firebase'i (gerekirse) yeniden
/// başlatıp açılış akışını tekrar dener.
void retryStartup() {
  startupErrorNotifier.value = null;
  unawaited(_retryBootstrap());
}

Future<void> _retryBootstrap() async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 12));
      try {
        FirebaseDatabase.instance.setPersistenceEnabled(false);
      } catch (_) {}
      if (Platform.isIOS || Platform.isAndroid) {
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler,
        );
      }
    }
  } catch (e, stack) {
    debugPrint('Firebase yeniden başlatılamadı: $e\n$stack');
    startupErrorNotifier.value = 'Uygulama başlatılamadı: $e';
    return;
  }
  await _bootstrap();
}

Future<void> _startBackgroundServices() async {
  try {
    await PairedDevicesService.instance.load();
    await TransferHistoryService.instance.load();
    await DownloadDirectoryService.instance.load();
    await DeviceIdentityService.instance.load();
    if (Platform.isIOS || Platform.isAndroid) {
      await ScreenWakeService.instance.load();
    }
    if (DesktopBackgroundService.isSupported) {
      await DesktopBackgroundService.instance.load();
      await DesktopBackgroundService.instance.initialize();
    }
    unawaited(PersistentInviteCodeService.instance.getOrCreate());
    await RecentConnectionService.instance.ensureListening();
    unawaited(PairedAutoConnectService.instance.ensureRunning());
    unawaited(WakeListenerService.instance.ensureRunning());
  } catch (e, stack) {
    debugPrint('Arka plan servisleri başlatılamadı: $e\n$stack');
  }
}

void _wireDesktopOverlay() {
  if (!DesktopOverlayService.isSupported) return;

  final overlay = DesktopOverlayService.instance;
  overlay.registerActionHandler();

  overlay.onOpenMainApp = () {
    unawaited(_openMainAppFromTray());
  };

  overlay.onReconnectApproved = (request) {
    unawaited(_handleOverlayReconnectApprove(request));
  };

  overlay.onReconnectRejected = (request) {
    unawaited(
      RecentConnectionService.instance.rejectIncomingReconnectRequest(request),
    );
  };

  overlay.onFileApproved = (fileId) {
    unawaited(_handleOverlayFileApproved(fileId));
  };

  overlay.onFileRejected = (fileId) {
    unawaited(_handleOverlayFileRejected(fileId));
  };

  overlay.onAcceptAllFiles = () {
    unawaited(_handleOverlayAcceptAllFiles());
  };

  overlay.onRejectAllFiles = () {
    unawaited(_handleOverlayRejectAllFiles());
  };
}

Future<void> _handleOverlayReconnectApprove(ReconnectRequest request) async {
  final overlay = DesktopOverlayService.instance;
  await overlay.markReconnectConnecting();

  TransferSessionController? controller;
  try {
    controller =
        await RecentConnectionService.instance.approveReconnectRequest(request);
  } catch (e, stack) {
    debugPrint('Overlay reconnect onayı başarısız: $e\n$stack');
  }

  if (controller == null) {
    await overlay.hideOverlayToTray();
    return;
  }

  ActiveSessionRegistry.instance.register(controller);
  overlay.enableOverlayOnlySession();
  overlay.attachReconnectController(controller);
  overlay.attachOverlaySession(controller);

  // Pencere gizli olsa bile navigator'da bağlantı ekranını aç; pencere açılınca hazır olsun.
  _presentActiveSessionInMainBody(request, controller);
}

/// Aktif oturumu ana gövdede bağlantı/transfer ekranında gösterir (pencere gizli olsa bile).
void _presentActiveSessionInMainBody(
  ReconnectRequest request,
  TransferSessionController controller,
) {
  void tryPresent() {
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    if (nav.canPop()) return;

    _openIncomingReconnect(
      request,
      existingController: controller,
    );
  }

  tryPresent();
  if (rootNavigatorKey.currentState?.canPop() != true) {
    WidgetsBinding.instance.addPostFrameCallback((_) => tryPresent());
  }
}

Future<void> _openMainAppFromTray() async {
  final controller = ActiveSessionRegistry.instance.activeController;

  await DesktopBackgroundService.instance.showMainWindow(force: true);

  if (controller == null || controller.isDisposed) return;
  final peerId = controller.peerDeviceId;
  if (peerId == null) return;

  _presentActiveSessionInMainBody(
    ReconnectRequest(
      fromDeviceId: peerId,
      fromDeviceName: controller.peerDisplayName ?? 'Cihaz',
      clientCreatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
    controller,
  );
}

Future<void> _handleOverlayFileApproved(String fileId) async {
  final overlay = DesktopOverlayService.instance;
  await overlay.markFileResolved(fileId, approved: true);

  final controller = ActiveSessionRegistry.instance.activeController;
  unawaited(
    controller?.acceptIncomingFile(fileId).then((_) => _syncOverlayFilesBanner()),
  );
}

Future<void> _handleOverlayFileRejected(String fileId) async {
  final overlay = DesktopOverlayService.instance;
  await overlay.markFileResolved(fileId, approved: false);

  final controller = ActiveSessionRegistry.instance.activeController;
  unawaited(
    controller?.rejectIncomingFile(fileId).then((_) => _syncOverlayFilesBanner()),
  );
}

Future<void> _handleOverlayAcceptAllFiles() async {
  final overlay = DesktopOverlayService.instance;
  await overlay.markAllFilesApproved();

  final controller = ActiveSessionRegistry.instance.activeController;
  unawaited(
    controller?.acceptAllIncomingFiles().then((_) => _syncOverlayFilesBanner()),
  );
}

Future<void> _handleOverlayRejectAllFiles() async {
  final overlay = DesktopOverlayService.instance;
  await overlay.markAllFilesRejected();

  final controller = ActiveSessionRegistry.instance.activeController;
  await controller?.rejectAllIncomingFiles();
  await _syncOverlayFilesBanner();
}

Future<void> _syncOverlayFilesBanner() async {
  if (!await DesktopBackgroundService.instance.isMainWindowHidden()) return;

  final controller = ActiveSessionRegistry.instance.activeController;
  final awaiting = controller?.awaitingApprovalFiles ?? const [];
  final overlay = DesktopOverlayService.instance;

  if (awaiting.isEmpty) {
    await overlay.onTransferItemsChanged(
      controller?.fileTransfer?.items ?? const [],
    );
    return;
  }

  await overlay.showIncomingFilesBanner(
    peerName: controller?.peerDisplayName ?? 'Cihaz',
    files: awaiting,
  );
}

Future<void> _handOffPendingRequestsToOverlay() async {
  if (!DesktopBackgroundService.isSupported) return;
  if (!await DesktopBackgroundService.instance.isMainWindowHidden()) return;

  final pending = RecentConnectionService.instance.incomingReconnectRequest;
  if (pending != null) {
    await DesktopOverlayService.instance.showReconnectBanner(pending);
  }

  final controller = ActiveSessionRegistry.instance.activeController;
  if (controller == null) return;

  // Aktif oturumu panele bağla: arka planda bağlantı koparsa sağ panelde
  // "bağlantı koptu" bildirimi gösterilebilsin.
  if (controller.isConnected) {
    DesktopOverlayService.instance.attachOverlaySession(controller);
  }

  final awaiting = controller.awaitingApprovalFiles;
  if (awaiting.isNotEmpty) {
    await DesktopOverlayService.instance.showIncomingFilesBanner(
      peerName: controller.peerDisplayName ?? 'Cihaz',
      files: awaiting,
    );
  }
}

void _wireNotificationWake() {
  NotificationService.instance.onWakeNotificationTapped = (request) {
    if (request.type == WakeRequestType.reconnect) return;
    unawaited(_openIncomingConnect(request));
  };

  // Masaüstünde menü çubuğundayken gelen dosya bildirimine dokununca pencereyi aç.
  NotificationService.instance.onIncomingFilesTapped = () {
    unawaited(DesktopBackgroundService.instance.showMainWindow());
  };
}

void _wireWakeListener() {
  WakeListenerService.instance.setHandler((request) {
    if (request.type == WakeRequestType.reconnect) return;
    unawaited(_openIncomingConnect(request));
  });
}

void _wireFirebaseReconnect() {
  DeviceRegistryService.onFirebaseReconnected = () {
    unawaited(
      RecentConnectionService.instance.refreshPendingReconnectRequests(),
    );
  };
}

void _wireIncomingReconnect() {
  NotificationService.instance.onReconnectPushReceived = (request) {
    unawaited(RecentConnectionService.instance.promptIncomingReconnect(request));
  };

  NotificationService.instance.onReconnectNotificationTapped = (request) {
    unawaited(
      RecentConnectionService.instance.promptIncomingReconnect(request),
    );
    IncomingReconnectPrompt.scheduleShow(request);
  };

  NotificationService.instance.onReconnectNotificationApproved = (request) {
    _openIncomingReconnect(request, autoApprove: true);
  };

  NotificationService.instance.onReconnectNotificationRejected = (request) {
    unawaited(
      RecentConnectionService.instance.rejectIncomingReconnectRequest(request),
    );
  };

  // Tüm platformlarda ön plandayken tam ekran "gelen arama" ekranını göster.
  RecentConnectionService.instance.onShowReconnectPrompt = (request) {
    IncomingReconnectPrompt.scheduleShow(request);
  };
}

void _openIncomingReconnect(
  ReconnectRequest request, {
  PairedDevice? peer,
  bool autoApprove = false,
  TransferSessionController? existingController,
}) {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;

  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => IncomingReconnectScreen(
        request: request,
        peer: peer,
        autoApprove: autoApprove,
        existingController: existingController,
      ),
    ),
  );
}

Future<void> _openIncomingConnect(WakeRequest request) async {
  if (DesktopBackgroundService.isSupported) {
    await DesktopBackgroundService.instance.showMainWindow();
  }
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

  if (DesktopBackgroundService.isSupported) {
    DesktopBackgroundService.instance.onShowMainApp = () async {
      await _openMainAppFromTray();
    };
    // Menü çubuğu menüsünden "Ayarlar": pencereyi aç + Ayarlar ekranını göster.
    DesktopBackgroundService.instance.onOpenSettings = () async {
      await DesktopBackgroundService.instance.showMainWindow(force: true);
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return;
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const SettingsScreen(),
        ),
      );
    };
    DesktopBackgroundService.instance.onMainWindowShown = () {
      IncomingReconnectPrompt.retryPendingIfAny();
    };
    DesktopBackgroundService.instance.onMainWindowHidden = () async {
      await _handOffPendingRequestsToOverlay();
    };
    // Menü çubuğu menüsünden cihaz seçilince: pencereyi aç + bağlantıyı başlat.
    DesktopBackgroundService.instance.onConnectToPeer = (peer) {
      unawaited(_connectToPeerFromTray(peer));
    };
    // Menüden gelen eşleşmeyi onaylayınca: pencereyi aç + gelen istek ekranını göster.
    DesktopBackgroundService.instance.onApproveReconnect = (request) {
      unawaited(_handleOverlayReconnectApprove(request));
    };
  }
}

Future<void> _connectToPeerFromTray(PairedDevice peer) async {
  // Pencere gizliyse: ana uygulamayı açmadan sağ panelden bağlan.
  if (DesktopBackgroundService.isSupported &&
      await DesktopBackgroundService.instance.isMainWindowHidden()) {
    await _connectToPeerViaOverlay(peer);
    return;
  }

  await DesktopBackgroundService.instance.showMainWindow();
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => RecentConnectScreen(peer: peer),
    ),
  );
}

/// Tray menüsünden başlatılan giden bağlantıyı sağ panelden (ekransız) yürütür:
/// istek gönderildi -> onay bekleniyor -> bağlanılıyor -> bağlandı (otomatik kapanır).
Future<void> _connectToPeerViaOverlay(PairedDevice peer) async {
  final overlay = DesktopOverlayService.instance;
  final service = RecentConnectionService.instance;

  await overlay.beginOutgoingConnect(peer.displayName);

  TransferSessionController controller;
  try {
    controller = await service.connectToPeer(
      peer,
      onProgress: (message) {
        unawaited(overlay.updateOutgoingStatus(message));
      },
    );
  } catch (e, stack) {
    debugPrint('Tray üzerinden bağlanma başarısız: $e\n$stack');
    await overlay.showDisconnectedNotice(peer.displayName, userFacingMessage(e));
    return;
  }

  ActiveSessionRegistry.instance.register(controller);
  service.clearIncomingInvite();
  overlay.enableOverlayOnlySession();
  // Bağlanınca "X bağlandı" gösterip paneli otomatik kapatır.
  overlay.attachReconnectController(controller);
  // Sonraki dosya transferleri ve kopma tespiti için oturumu izle.
  overlay.attachOverlaySession(controller);

  // Pencere açılırsa aktif oturum ana gövdede gösterilebilsin.
  _presentActiveSessionInMainBody(
    ReconnectRequest(
      fromDeviceId: peer.deviceId,
      fromDeviceName: peer.displayName,
      clientCreatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
    controller,
  );
}

Future<void> _maybePresentActiveSessionOnResume() async {
  if (!DesktopBackgroundService.isSupported) return;

  final controller = ActiveSessionRegistry.instance.activeController;
  if (controller == null || controller.isDisposed) return;
  if (!controller.isConnected) return;
  if (await DesktopBackgroundService.instance.isMainWindowHidden()) return;

  final peerId = controller.peerDeviceId;
  if (peerId == null) return;

  _presentActiveSessionInMainBody(
    ReconnectRequest(
      fromDeviceId: peerId,
      fromDeviceName: controller.peerDisplayName ?? 'Cihaz',
      clientCreatedAt: DateTime.now().millisecondsSinceEpoch,
    ),
    controller,
  );
}

class DirectDropApp extends StatefulWidget {
  const DirectDropApp({super.key});

  @override
  State<DirectDropApp> createState() => _DirectDropAppState();
}

class _DirectDropAppState extends State<DirectDropApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        if (DesktopBackgroundService.isSupported &&
            !await DesktopBackgroundService.instance.isMainWindowHidden()) {
          await DesktopOverlayService.instance
              .suppressPanelsForVisibleMainWindow();
        }
        _retryReconnectPrompt();
      }());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _retryReconnectPrompt() {
    final pending = RecentConnectionService.instance.incomingReconnectRequest;
    if (pending == null) return;

    if (DesktopBackgroundService.isSupported) {
      unawaited(() async {
        if (await DesktopBackgroundService.instance.isMainWindowHidden()) {
          await DesktopOverlayService.instance.showReconnectBanner(pending);
          return;
        }
        await DesktopOverlayService.instance.suppressPanelsForVisibleMainWindow();
        IncomingReconnectPrompt.retryPendingIfAny();
      }());
      return;
    }
    IncomingReconnectPrompt.retryPendingIfAny();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final activeController = ActiveSessionRegistry.instance.activeController;
    final hasActiveSession = ActiveSessionRegistry.instance.hasActiveSession;

    if (state == AppLifecycleState.resumed) {
      unawaited(
        FirebaseAuthService.instance.ensureSignedIn().catchError((Object e) {
          debugPrint('Auth yenileme: $e');
        }),
      );
      unawaited(RecentConnectionService.instance.ensureListening());
      unawaited(RecentConnectionService.instance.refreshPendingReconnectRequests());
      unawaited(WakeListenerService.instance.ensureRunning());
      _retryReconnectPrompt();
      activeController?.onAppResumed();
      unawaited(_maybePresentActiveSessionOnResume());
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      activeController?.markBackgrounded();
      if (state == AppLifecycleState.paused && !hasActiveSession) {
        if (!DesktopBackgroundService.instance.shouldSkipGracefulShutdownOnPause()) {
          unawaited(SessionCleanupService.instance.markGracefulShutdown());
        }
      }
      return;
    }

    if (state == AppLifecycleState.detached) {
      if (DesktopBackgroundService.instance.isQuitting) {
        RecentConnectionService.instance.stopListening();
        unawaited(ActiveSessionRegistry.instance.disconnectActive());
        unawaited(SessionCleanupService.instance.markGracefulShutdown());
        return;
      }
      if (hasActiveSession && (Platform.isAndroid || Platform.isIOS)) {
        unawaited(activeController?.flushTransferCheckpoints());
        activeController?.markBackgrounded();
        return;
      }
      unawaited(activeController?.flushTransferCheckpoints());
      RecentConnectionService.instance.stopListening();
      unawaited(ActiveSessionRegistry.instance.disconnectActive());
      unawaited(SessionCleanupService.instance.markGracefulShutdown());
    }
  }

  @override
  Widget build(BuildContext context) {
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
      home: ValueListenableBuilder<String?>(
        valueListenable: startupErrorNotifier,
        builder: (context, error, _) {
          if (error != null) {
            return _StartupErrorScreen(message: error);
          }
          return const HomeScreen();
        },
      ),
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
              const SizedBox(height: 24),
              Center(
                child: FilledButton.icon(
                  onPressed: retryStartup,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar dene'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
