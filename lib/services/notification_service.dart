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
      // macOS sandbox uygulamalarda izin otomatik istenemeyebilir; çökme olmasın.
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

      FirebaseMessaging.onMessage.listen((message) {
        final request = _wakeFromFcmData(message.data);
        if (request == null) return;
        if (request.type == WakeRequestType.reconnect) {
          final reconnect = ReconnectRequest(
            fromDeviceId: request.fromDeviceId,
            fromDeviceName: request.fromDeviceName,
            clientCreatedAt: request.createdAt,
          );
          onReconnectPushReceived?.call(reconnect);
          return;
        }
        showWakeNotification(request);
        onWakeNotificationTapped?.call(request);
      });

      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final request = _wakeFromFcmData(message.data);
        if (request != null) {
          onWakeNotificationTapped?.call(request);
        }
      });

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        final request = _wakeFromFcmData(initial.data);
        if (request != null) {
          onWakeNotificationTapped?.call(request);
        }
      }

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
        request.fromDeviceId.hashCode,
        title,
        body,
        NotificationDetails(
          iOS: const DarwinNotificationDetails(),
          macOS: const DarwinNotificationDetails(),
          android: AndroidNotificationDetails(
            'directdrop_reconnect',
            'DirectDrop Bağlantı İsteği',
            importance: Importance.high,
            priority: Priority.high,
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
      // Bağlantıyı wake_listener yönetir; burada otomatik navigasyon yapma.
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
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Arka plan FCM: ${message.messageId}');
  } catch (e) {
    debugPrint('Arka plan FCM handler: $e');
  }
}
