import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/paired_device.dart';
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
          _handleNotificationPayload(response.payload);
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
        if (request != null) {
          showWakeNotification(request);
          onWakeNotificationTapped?.call(request);
        }
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
    final roomCode = data['roomCode'] as String?;
    if (roomCode == null || roomCode.isEmpty) return null;
    return WakeRequest(
      roomCode: roomCode,
      fromDeviceId: data['fromDeviceId'] as String? ?? '',
      fromDeviceName: data['fromDeviceName'] as String? ?? 'Cihaz',
      type: data['type'] == 'file_request'
          ? WakeRequestType.fileRequest
          : WakeRequestType.connect,
      createdAt: int.tryParse(data['createdAt']?.toString() ?? '') ??
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
