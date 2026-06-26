import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import 'device_identity_service.dart';
import 'firebase_rtdb_service.dart';
import 'desktop_background_service.dart';
import 'notification_service.dart';
import 'recent_connection_service.dart';

typedef WakeRequestHandler = void Function(WakeRequest request);

class WakeListenerService {
  WakeListenerService._();

  static final WakeListenerService instance = WakeListenerService._();

  StreamSubscription<DatabaseEvent>? _subscription;
  WakeRequestHandler? _handler;
  final Set<String> _handledKeys = {};

  void setHandler(WakeRequestHandler handler) {
    _handler = handler;
  }

  Future<void> start() async {
    await _subscription?.cancel();
    _handledKeys.clear();

    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final ref = FirebaseRtdbService.database
        .ref('devices')
        .child(deviceId)
        .child('wakeRequests');

    _subscription = ref.onChildAdded.listen((event) async {
      await _handleSnapshot(event.snapshot);
    });

    await _processPending(ref);
  }

  Future<void> ensureRunning() async {
    await start();
  }

  Future<void> _processPending(DatabaseReference ref) async {
    final snapshot = await FirebaseRtdbService.readOnce(ref);
    if (!snapshot.exists || snapshot.value is! Map) return;

    final requests = Map<String, dynamic>.from(snapshot.value as Map);
    for (final key in requests.keys) {
      await _handleSnapshot(snapshot.child(key));
    }
  }

  Future<void> _handleSnapshot(DataSnapshot snapshot) async {
    final key = snapshot.key;
    if (key == null) return;
    if (_handledKeys.contains(key)) return;

    final value = snapshot.value;
    if (value is! Map) return;

    _handledKeys.add(key);
    await snapshot.ref.remove();

    final request = WakeRequest.fromMap(value);
    if (DateTime.now().millisecondsSinceEpoch - request.createdAt > 120000) {
      return;
    }

    if (request.type == WakeRequestType.reconnect) {
      await RecentConnectionService.instance.promptIncomingReconnect(
        ReconnectRequest(
          fromDeviceId: request.fromDeviceId,
          fromDeviceName: request.fromDeviceName,
          clientCreatedAt: request.createdAt,
        ),
      );
      return;
    }

    final isDesktopConnect = request.type == WakeRequestType.connect &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    if (!isDesktopConnect) {
      await NotificationService.instance.showWakeNotification(request);
    } else if (DesktopBackgroundService.instance.keepsRunningInBackground) {
      final hidden =
          await DesktopBackgroundService.instance.isMainWindowHidden();
      if (hidden && Platform.isMacOS) {
        await NotificationService.instance.showWakeNotification(request);
      }
    }
    _handler?.call(request);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
