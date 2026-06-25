import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import 'device_registry_service.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  final DeviceRegistryService _registry = DeviceRegistryService();

  bool _initialized = false;
  bool _localNotificationsReady = false;
  void Function(WakeRequest request)? onWakeNotificationTapped;
  void Function()? onIncomingFilesTapped;
  void Function(ReconnectRequest request)? onReconnectNotificationTapped;
  void Function(ReconnectRequest request)? onReconnectNotificationApproved;
  void Function(ReconnectRequest request)? onReconnectNotificationRejected;
  void Function(ReconnectRequest request)? onReconnectPushReceived;

  Future<void> initialize() async {
    if (_initialized) return;

    await _initLocalNotifications();
    await _initFirebaseMessaging();

    _initialized = true;
  }

  Future<void> _initLocalNotifications() async {
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      final darwinInit = DarwinInitializationSettings(
        requestAlertPermission: !Platform.isMacOS,
        requestBadgePermission: !Platform.isMacOS,
        requestSoundPermission: !Platform.isMacOS,
      );
      await _local.initialize(
        InitializationSettings(
          android: androidInit,
          iOS: darwinInit,
          macOS: darwinInit,
        ),
        onDidReceiveNotificationResponse: (response) {
          _handleNotificationResponse(response);
        },
      );
      _localNotificationsReady = true;

      if (Platform.isAndroid) {
        final android = _local.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            'directdrop_reconnect',
            'DirectDrop Bağlantı İsteği',
            description: 'Eşleşmiş cihazlardan gelen bağlantı istekleri',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            'directdrop_wake',
            'DirectDrop Bağlantı',
            description: 'Bağlantı ve dosya transferi uyarıları',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );
      }
    } catch (e) {
      debugPrint('Yerel bildirimler başlatılamadı: $e');
      _localNotificationsReady = false;
    }
  }

  Future<void> _initFirebaseMessaging() async {
    if (Platform.isMacOS || Platform.isWindows) {
      return;
    }

    try {
      if (Platform.isIOS) {
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      if (Platform.isAndroid) {
        final status = await Permission.notification.request();
        if (!status.isGranted) {
          debugPrint('Android bildirim izni verilmedi.');
        }
      }

      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

      FirebaseMessaging.onMessageOpenedApp.listen(_handleRemoteMessageOpened);

      // Push token kaydı opsiyonel; başarısız olursa uygulama çökmemeli.
      unawaited(_refreshFcmToken());
      FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
        try {
          await _registry.updateFcmToken(token);
        } catch (e) {
          debugPrint('FCM token güncellenemedi: $e');
        }
      });
    } catch (e) {
      debugPrint('FCM başlatılamadı (uygulama devam ediyor): $e');
    }
  }

  /// Uygulama bildirimden soğuk açıldığında çağrılır (main bootstrap sonrası).
  Future<void> processInitialMessage() async {
    if (Platform.isMacOS || Platform.isWindows) return;
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        _handleRemoteMessageOpened(initial);
      }
    } catch (e) {
      debugPrint('İlk FCM mesajı okunamadı: $e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    final reconnect = _reconnectFromFcmData(message.data);
    if (reconnect != null) {
      onReconnectPushReceived?.call(reconnect);
      return;
    }

    final request = _wakeFromFcmData(message.data);
    if (request == null) return;
    showWakeNotification(request);
    onWakeNotificationTapped?.call(request);
  }

  void _handleRemoteMessageOpened(RemoteMessage message) {
    final reconnect = _reconnectFromFcmData(message.data);
    if (reconnect != null) {
      onReconnectNotificationTapped?.call(reconnect);
      return;
    }

    final request = _wakeFromFcmData(message.data);
    if (request != null) {
      onWakeNotificationTapped?.call(request);
    }
  }

  Future<void> _refreshFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _registry.updateFcmToken(token);
      }
    } catch (e) {
      debugPrint('FCM token alınamadı (önemsiz): $e');
    }
  }

  ReconnectRequest? _reconnectFromFcmData(Map<String, dynamic> data) {
    final typeRaw = data['type'] as String? ?? '';
    if (typeRaw != 'reconnect') return null;
    final fromId = data['fromDeviceId'] as String? ?? '';
    if (fromId.isEmpty) return null;
    return ReconnectRequest(
      fromDeviceId: fromId,
      fromDeviceName: data['fromDeviceName'] as String? ?? 'Cihaz',
      clientCreatedAt: int.tryParse(data['createdAt']?.toString() ?? '') ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  WakeRequest? _wakeFromFcmData(Map<String, dynamic> data) {
    final typeRaw = data['type'] as String? ?? 'connect';
    if (typeRaw == 'reconnect') {
      final fromId = data['fromDeviceId'] as String? ?? '';
      if (fromId.isEmpty) return null;
      return WakeRequest(
        roomCode: '',
        fromDeviceId: fromId,
        fromDeviceName: data['fromDeviceName'] as String? ?? 'Cihaz',
        type: WakeRequestType.reconnect,
        createdAt: int.tryParse(data['createdAt']?.toString() ?? '') ??
            DateTime.now().millisecondsSinceEpoch,
      );
    }

    final roomCode = data['roomCode'] as String?;
    if (roomCode == null || roomCode.isEmpty) return null;
    return WakeRequest(
      roomCode: roomCode,
      fromDeviceId: data['fromDeviceId'] as String? ?? '',
      fromDeviceName: data['fromDeviceName'] as String? ?? 'Cihaz',
      type: typeRaw == 'file_request'
          ? WakeRequestType.fileRequest
          : WakeRequestType.connect,
      createdAt: int.tryParse(data['createdAt']?.toString() ?? '') ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    if (payload == 'incoming_files') {
      onIncomingFilesTapped?.call();
      return;
    }

    if (payload.startsWith('reconnect|')) {
      final request = _reconnectFromPayload(payload);
      if (request == null) return;
      switch (response.actionId) {
        case 'approve':
          onReconnectNotificationApproved?.call(request);
          return;
        case 'reject':
          onReconnectNotificationRejected?.call(request);
          return;
        default:
          onReconnectNotificationTapped?.call(request);
          return;
      }
    }

    _handleNotificationPayload(payload);
  }

  ReconnectRequest? _reconnectFromPayload(String payload) {
    final parts = payload.split('|');
    if (parts.length < 3 || parts[0] != 'reconnect') return null;
    return ReconnectRequest(
      fromDeviceId: parts[1],
      fromDeviceName: parts[2],
      clientCreatedAt: int.tryParse(parts.length > 3 ? parts[3] : '') ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _handleNotificationPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final parts = payload.split('|');
    if (parts.length < 3) return;
    final request = WakeRequest(
      roomCode: parts[0],
      fromDeviceId: parts[1],
      fromDeviceName: parts[2],
      type: parts.length > 3 && parts[3] == 'file_request'
          ? WakeRequestType.fileRequest
          : WakeRequestType.connect,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    onWakeNotificationTapped?.call(request);
  }

  Future<void> showReconnectRequestNotification(
    ReconnectRequest request, {
    String? peerDisplayName,
  }) async {
    if (!_localNotificationsReady) return;

    final name = peerDisplayName ?? request.fromDeviceName;
    final title = '$name bağlantı kurmak istiyor';
    const body = 'Onaylayın veya reddedin.';
    final payload =
        'reconnect|${request.fromDeviceId}|${request.fromDeviceName}|${request.clientCreatedAt}';

    try {
      await _local.show(
        request.clientCreatedAt % 1000000,
        title,
        body,
        NotificationDetails(
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          macOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          android: AndroidNotificationDetails(
            'directdrop_reconnect',
            'DirectDrop Bağlantı İsteği',
            channelDescription: 'Eşleşmiş cihazlardan gelen bağlantı istekleri',
            importance: Importance.max,
            priority: Priority.max,
            ticker: title,
            visibility: NotificationVisibility.public,
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            actions: <AndroidNotificationAction>[
              const AndroidNotificationAction(
                'approve',
                'Onayla',
                showsUserInterface: true,
              ),
              const AndroidNotificationAction(
                'reject',
                'Reddet',
                showsUserInterface: false,
              ),
            ],
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('Yeniden bağlanma bildirimi gösterilemedi: $e');
    }
  }

  Future<void> showWakeNotification(WakeRequest request) async {
    if (!_localNotificationsReady) {
      return;
    }

    final title = request.type == WakeRequestType.fileRequest
        ? '${request.fromDeviceName} dosya göndermek istiyor'
        : '${request.fromDeviceName} bağlanmak istiyor';
    const body = 'Dokunarak bağlanın ve transferi başlatın.';
    final payload =
        '${request.roomCode}|${request.fromDeviceId}|${request.fromDeviceName}|${request.type == WakeRequestType.fileRequest ? 'file_request' : 'connect'}';

    try {
      await _local.show(
        request.roomCode.hashCode,
        title,
        body,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          android: AndroidNotificationDetails(
            'directdrop_wake',
            'DirectDrop Bağlantı',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('Bildirim gösterilemedi: $e');
    }
  }

  /// Uygulama arka plandayken (masaüstü menü çubuğu) gelen dosya teklifleri için
  /// bildirim gösterir. Dokunulduğunda pencere öne getirilir ve onay paneli açılır.
  Future<void> showIncomingFilesNotification({
    required String peerName,
    required int count,
  }) async {
    if (!_localNotificationsReady) return;

    final title = count > 1
        ? '$peerName $count dosya göndermek istiyor'
        : '$peerName dosya göndermek istiyor';
    const body = 'Onaylamak veya reddetmek için dokunun.';

    try {
      await _local.show(
        'directdrop_incoming_files'.hashCode,
        title,
        body,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          macOS: DarwinNotificationDetails(
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          android: AndroidNotificationDetails(
            'directdrop_wake',
            'DirectDrop Bağlantı',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: 'incoming_files',
      );
    } catch (e) {
      debugPrint('Gelen dosya bildirimi gösterilemedi: $e');
    }
  }
}

/// Uygulama kapalı/arka plandayken gelen FCM — Cloud Function bildirimi yeterli;
/// dokunulunca uygulama açılır ve tam ekran onay ekranı gösterilir.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Arka plan FCM: ${message.messageId} type=${message.data['type']}');
  } catch (e) {
    debugPrint('Arka plan FCM handler: $e');
  }
}
