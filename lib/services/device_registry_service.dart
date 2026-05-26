import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/device_presence.dart';
import '../models/paired_device.dart';
import 'device_identity_service.dart';
import 'firebase_auth_service.dart';

class DeviceRegistryService {
  DeviceRegistryService({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;
  Timer? _heartbeatTimer;
  StreamSubscription<DatabaseEvent>? _connectedSubscription;
  bool _connectionMonitorStarted = false;

  DatabaseReference get _devices => _database.ref('devices');

  Future<void> registerCurrentDevice({String? fcmToken}) async {
    final identity = DeviceIdentityService.instance;
    final deviceId = await identity.getDeviceId();
    final ownerUid = await FirebaseAuthService.instance.requireUid();
    final ref = _devices.child(deviceId);
    await ref.update({
      'displayName': identity.displayName,
      'platform': identity.platformLabel,
      'lastSeen': ServerValue.timestamp,
      'online': true,
      'ownerUid': ownerUid,
      if (fcmToken != null) 'fcmToken': fcmToken,
    });
    await _configureDisconnectHandlers(ref);
  }

  Future<void> setOnline(bool online) async {
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _devices.child(deviceId);
    await ref.update({
      'online': online,
      'lastSeen': ServerValue.timestamp,
    });
    if (online) {
      await _configureDisconnectHandlers(ref);
    }
  }

  Future<void> _configureDisconnectHandlers(DatabaseReference deviceRef) async {
    await deviceRef.child('online').onDisconnect().set(false);
    await deviceRef.child('lastSeen').onDisconnect().set(ServerValue.timestamp);
  }

  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    final interval = _heartbeatInterval;
    _heartbeatTimer = Timer.periodic(interval, (_) {
      unawaited(_heartbeatTick());
    });
  }

  Duration get _heartbeatInterval {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return const Duration(seconds: 12);
    }
    return const Duration(seconds: 20);
  }

  Future<void> _heartbeatTick() async {
    try {
      await registerCurrentDevice();
    } catch (e) {
      debugPrint('Heartbeat başarısız: $e');
    }
  }

  /// Firebase yeniden bağlanınca onDisconnect yüzünden kalan offline bayrağını düzelt.
  void startConnectionMonitor() {
    if (_connectionMonitorStarted) return;
    _connectionMonitorStarted = true;

    _connectedSubscription?.cancel();
    _connectedSubscription =
        _database.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value == true;
      if (!connected) return;
      unawaited(_onFirebaseReconnected());
    });
  }

  Future<void> _onFirebaseReconnected() async {
    try {
      await registerCurrentDevice();
      if (_heartbeatTimer == null) {
        startHeartbeat();
      }
    } catch (e) {
      debugPrint('Firebase yeniden bağlanma kaydı başarısız: $e');
    }
  }

  Future<void> refreshPresence() => _onFirebaseReconnected();

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> dispose() async {
    stopHeartbeat();
    await _connectedSubscription?.cancel();
    _connectedSubscription = null;
    _connectionMonitorStarted = false;
  }

  Stream<DevicePresence> watchPresence(String deviceId) {
    return _devices.child(deviceId).onValue.map((event) {
      final value = event.snapshot.value;
      if (value is! Map) {
        return const DevicePresence(online: false);
      }
      return DevicePresence(
        online: value['online'] == true,
        lastSeenMs: (value['lastSeen'] as num?)?.toInt(),
      );
    });
  }

  Future<void> updateFcmToken(String token) async {
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    await _devices.child(deviceId).update({
      'fcmToken': token,
      'lastSeen': ServerValue.timestamp,
    });
  }

  Future<void> sendWakeRequest({
    required String targetDeviceId,
    required WakeRequest request,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = _devices.child(targetDeviceId).child('wakeRequests').push();
    await ref.set({
      ...request.toMap(),
      'fromAuthUid': fromAuthUid,
    });
  }

  Future<void> sendPairInvite({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
    required String roomCode,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = _devices
        .child(targetDeviceId)
        .child('incomingPair')
        .child(fromDeviceId);
    // Eski daveti sil; aksi halde Firebase onChildAdded tekrar tetiklenmez.
    await ref.remove();
    await ref.set({
      'roomCode': roomCode,
      'fromDeviceId': fromDeviceId,
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'createdAt': ServerValue.timestamp,
    });
  }

  Future<void> removePairInvite({
    required String targetDeviceId,
    required String fromDeviceId,
  }) async {
    await _devices
        .child(targetDeviceId)
        .child('incomingPair')
        .child(fromDeviceId)
        .remove();
  }

  DatabaseReference incomingPairRef(String deviceId) =>
      _devices.child(deviceId).child('incomingPair');

  Future<String?> getFcmToken(String deviceId) async {
    final snapshot = await _devices.child(deviceId).child('fcmToken').get();
    return snapshot.value as String?;
  }
}
