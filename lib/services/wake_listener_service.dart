import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../models/paired_device.dart';
import 'device_identity_service.dart';
import 'notification_service.dart';

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
    final ref = FirebaseDatabase.instance
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

  Future<void> processPendingRequests() async {
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final ref = FirebaseDatabase.instance
        .ref('devices')
        .child(deviceId)
        .child('wakeRequests');
    await _processPending(ref);
  }

  Future<void> _processPending(DatabaseReference ref) async {
    final snapshot = await ref.get();
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

    await NotificationService.instance.showWakeNotification(request);
    _handler?.call(request);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
