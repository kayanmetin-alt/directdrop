import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/device_presence.dart';
import '../models/paired_device.dart';
import 'device_identity_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_rtdb_service.dart';
import 'pairings_registry_service.dart';

class DeviceRegistryService {
  DeviceRegistryService({FirebaseDatabase? database})
      : _database = database ?? FirebaseRtdbService.database;

  /// Firebase RTDB yeniden bağlanınca bekleyen istekleri tazelemek için.
  static void Function()? onFirebaseReconnected;

  final FirebaseDatabase _database;
  Timer? _heartbeatTimer;
  StreamSubscription<DatabaseEvent>? _connectedSubscription;
  bool _connectionMonitorStarted = false;

  DatabaseReference get _devices => _database.ref('devices');
  DatabaseReference get _presence => _database.ref('presence');
  DatabaseReference get _pairInvites => _database.ref('pairInvites');

  Future<void> registerCurrentDevice({String? fcmToken}) async {
    try {
      await _registerCurrentDeviceOnce(fcmToken: fcmToken);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied' && e.code != 'unknown') rethrow;
      debugPrint('Cihaz kaydı başarısız ($e); yeni cihaz kimliği deneniyor...');
      await DeviceIdentityService.instance.resetDeviceId();
      await _registerCurrentDeviceOnce(fcmToken: fcmToken);
    }
  }

  Future<void> _registerCurrentDeviceOnce({String? fcmToken}) async {
    final identity = DeviceIdentityService.instance;
    final deviceId = await identity.getDeviceId();
    final ownerUid = await FirebaseAuthService.instance.requireUid();
    final ref = _devices.child(deviceId);
    final payload = {
      'displayName': identity.displayName,
      'platform': identity.platformLabel,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
      'online': true,
      'ownerUid': ownerUid,
      // FCM token artık burada tutulmuyor; eski kayıtlardaki alanı temizle.
      'fcmToken': null,
    };
    final snapshot = await ref.get();
    if (snapshot.exists) {
      await ref.update(payload);
    } else {
      await ref.set(payload);
    }
    if (fcmToken != null) {
      await _writeDeviceToken(deviceId, fcmToken);
    }
    await _syncPresence(
      deviceId: deviceId,
      online: true,
      displayName: identity.displayName,
      platform: identity.platformLabel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _configureDisconnectHandlers(ref);
  }

  DatabaseReference get _deviceTokens => _database.ref('deviceTokens');

  Future<void> _syncPresence({
    required String deviceId,
    required bool online,
    String? displayName,
    String? platform,
  }) async {
    try {
      final payload = <String, dynamic>{
        'online': online,
        'lastSeen': ServerValue.timestamp,
        if (displayName != null) 'displayName': displayName,
        if (platform != null) 'platform': platform,
      };
      await _presence.child(deviceId).update(payload);
    } catch (e) {
      debugPrint('Presence güncellenemedi: $e');
    }
  }

  /// FCM token'ı yalnızca sahibinin okuyabildiği ayrı düğüme yazar.
  Future<void> _writeDeviceToken(String deviceId, String token) async {
    try {
      await _deviceTokens.child(deviceId).set(token);
    } catch (e) {
      debugPrint('FCM token yazılamadı: $e');
    }
  }

  Future<void> setOnline(bool online) async {
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _devices.child(deviceId);
    await ref.update({
      'online': online,
      'lastSeen': ServerValue.timestamp,
    });
    await _presence.child(deviceId).update({
      'online': online,
      'lastSeen': ServerValue.timestamp,
    });
    if (online) {
      await _configureDisconnectHandlers(ref);
    }
  }

  Future<void> _configureDisconnectHandlers(DatabaseReference deviceRef) async {
    final deviceId = deviceRef.key;
    try {
      await deviceRef.child('online').onDisconnect().set(false);
      await deviceRef.child('lastSeen').onDisconnect().set(ServerValue.timestamp);
      if (deviceId != null) {
        await _presence.child(deviceId).child('online').onDisconnect().set(false);
        await _presence
            .child(deviceId)
            .child('lastSeen')
            .onDisconnect()
            .set(ServerValue.timestamp);
      }
    } catch (e) {
      debugPrint('onDisconnect kaydı başarısız: $e');
    }
  }

  /// Galeri / dosya görüntüleyici gibi geçici arka plana geçişte Firebase kopunca
  /// yanlışlıkla çevrimdışı veya "ayrıldı" sinyali gitmesin.
  Future<void> suspendBackgroundDisconnectHandlers() async {
    final deviceId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _devices.child(deviceId);
    try {
      await ref.child('online').onDisconnect().cancel();
      await ref.child('lastSeen').onDisconnect().cancel();
      await _presence.child(deviceId).child('online').onDisconnect().cancel();
      await _presence.child(deviceId).child('lastSeen').onDisconnect().cancel();
    } catch (e) {
      debugPrint('onDisconnect iptali başarısız: $e');
    }
    try {
      await ref.update({
        'online': true,
        'lastSeen': ServerValue.timestamp,
      });
      await _presence.child(deviceId).update({
        'online': true,
        'lastSeen': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('Arka plan çevrimiçi durumu güncellenemedi: $e');
    }
  }

  Future<void> restoreBackgroundDisconnectHandlers() async {
    try {
      await registerCurrentDevice();
    } catch (e) {
      debugPrint('Arka plandan dönüş kaydı başarısız: $e');
    }
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
      return const Duration(seconds: 30);
    }
    return const Duration(seconds: 30);
  }

  /// Heartbeat artık her tikte tam yeniden kayıt yapmaz; yalnızca lastSeen/online
  /// alanlarını hafifçe günceller. onDisconnect kuralları sunucuda kalıcıdır,
  /// her tikte yeniden kurmaya gerek yoktur. Hafif güncelleme başarısızsa
  /// (ör. kayıt hiç yoksa) tek seferlik tam kayda düşer.
  Future<void> _heartbeatTick() async {
    try {
      final deviceId = await DeviceIdentityService.instance.getDeviceId();
      await _devices.child(deviceId).update({
        'online': true,
        'lastSeen': ServerValue.timestamp,
      });
      await _presence.child(deviceId).update({
        'online': true,
        'lastSeen': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('Heartbeat (hafif) başarısız, tam kayıt deneniyor: $e');
      try {
        await registerCurrentDevice();
      } catch (e2) {
        debugPrint('Heartbeat tam kayıt da başarısız: $e2');
      }
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
      DeviceRegistryService.onFirebaseReconnected?.call();
    } catch (e) {
      debugPrint('Firebase yeniden bağlanma kaydı başarısız: $e');
    }
  }

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
    return _presence.child(deviceId).onValue.map((event) {
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
    await _writeDeviceToken(deviceId, token);
    await _devices.child(deviceId).update({
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

  Future<Map<String, dynamic>?> readDevice(String deviceId) async {
    final snapshot = await _devices.child(deviceId).get();
    if (!snapshot.exists || snapshot.value is! Map) return null;
    return Map<String, dynamic>.from(snapshot.value as Map);
  }

  /// Eşleştirilmiş cihazların çevrimiçi durumu — yalnızca `presence/` düğümünden.
  Future<Map<String, dynamic>?> readPresence(String deviceId) async {
    final snapshot = await _presence.child(deviceId).get();
    if (!snapshot.exists || snapshot.value is! Map) return null;
    return Map<String, dynamic>.from(snapshot.value as Map);
  }

  DatabaseReference reconnectRequestsRef(String deviceId) =>
      _devices.child(deviceId).child('reconnectRequests');

  /// Karşı cihazdan oda açmasını ister (QR tarama / listeden dokunma).
  /// Dönen `clientCreatedAt` değeri, karşı tarafın göndereceği davetle eşleştirilir.
  Future<int> sendReconnectRequest({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = reconnectRequestsRef(targetDeviceId).child(fromDeviceId);
    try {
      await ref.remove();
    } catch (_) {}
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'clientCreatedAt': createdAt,
    };
    try {
      await ref.set(payload);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      await PairingsRegistryService.instance.ensurePeerForReconnect(
        targetDeviceId,
      );
      await ref.set(payload);
    }

    // RTDB wake → Cloud Function FCM push (uygulama kapalıyken bile bildirim).
    try {
      await sendWakeRequest(
        targetDeviceId: targetDeviceId,
        request: WakeRequest(
          roomCode: '',
          fromDeviceId: fromDeviceId,
          fromDeviceName: fromDeviceName,
          type: WakeRequestType.reconnect,
          createdAt: createdAt,
        ),
      );
    } catch (e) {
      debugPrint('Yeniden bağlanma uyandırma gönderilemedi: $e');
    }
    return createdAt;
  }

  Future<void> sendReconnectRejection({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = _pairInvites.child(targetDeviceId).child(fromDeviceId);
    try {
      await ref.remove();
    } catch (_) {}
    await ref.set({
      'rejected': true,
      'fromDeviceId': fromDeviceId,
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'clientCreatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> clearReconnectRequest({
    required String targetDeviceId,
    required String fromDeviceId,
  }) async {
    try {
      await reconnectRequestsRef(targetDeviceId).child(fromDeviceId).remove();
    } catch (e) {
      debugPrint('Yeniden bağlanma isteği silinemedi: $e');
    }
  }

  DatabaseReference peerDepartedRef(String deviceId) =>
      _devices.child(deviceId).child('peerDeparted');

  /// Karşı cihaza "ben ayrıldım" sinyali — WebRTC'den bağımsız, güvenilir çıkış.
  Future<void> sendPeerDeparted({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = peerDepartedRef(targetDeviceId).child(fromDeviceId);
    try {
      await ref.remove();
    } catch (_) {}
    await ref.set({
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'clientCreatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Beklenmedik kopuşta (uygulama öldürülmesi vb.) karşı cihaza sinyal gönderir.
  Future<void> registerPeerDepartedOnDisconnect({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = peerDepartedRef(targetDeviceId).child(fromDeviceId);
    await ref.onDisconnect().set({
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'clientCreatedAt': ServerValue.timestamp,
    });
  }

  Future<void> cancelPeerDepartedOnDisconnect({
    required String targetDeviceId,
    required String fromDeviceId,
  }) async {
    try {
      await peerDepartedRef(targetDeviceId).child(fromDeviceId).onDisconnect().cancel();
    } catch (e) {
      debugPrint('peerDeparted onDisconnect iptali başarısız: $e');
    }
  }

  Future<void> clearPeerDeparted({
    required String myDeviceId,
    required String fromDeviceId,
  }) async {
    try {
      await peerDepartedRef(myDeviceId).child(fromDeviceId).remove();
    } catch (e) {
      debugPrint('Ayrılma sinyali silinemedi: $e');
    }
  }

  /// Eski / çift tıklama davetlerini temizler.
  Future<void> clearPairInvitesBetween({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    try {
      await _pairInvites.child(peerDeviceId).child(myDeviceId).remove();
      await _pairInvites.child(myDeviceId).child(peerDeviceId).remove();
    } catch (e) {
      debugPrint('Davet temizliği atlandı: $e');
    }
  }

  Future<void> sendPairInvite({
    required String targetDeviceId,
    required String fromDeviceId,
    required String fromDeviceName,
    required String roomCode,
    int? reconnectClientCreatedAt,
  }) async {
    final fromAuthUid = await FirebaseAuthService.instance.requireUid();
    final ref = _pairInvites.child(targetDeviceId).child(fromDeviceId);
    final payload = {
      'roomCode': roomCode,
      'fromDeviceId': fromDeviceId,
      'fromDeviceName': fromDeviceName,
      'fromAuthUid': fromAuthUid,
      'createdAt': ServerValue.timestamp,
      'clientCreatedAt': DateTime.now().millisecondsSinceEpoch,
      if (reconnectClientCreatedAt != null)
        'reconnectClientCreatedAt': reconnectClientCreatedAt,
    };

    try {
      await ref.remove();
    } catch (e) {
      debugPrint('Eski davet silinemedi (devam): $e');
    }

    try {
      await ref.set(payload);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      debugPrint('Davet set reddedildi, update deneniyor: $e');
      await ref.update(payload);
    }
  }

  /// Bu cihaza gelen tüm yeniden bağlanma davetlerini siler (çökme sonrası).
  Future<void> clearAllInvitesForDevice(String targetDeviceId) async {
    try {
      await _pairInvites.child(targetDeviceId).remove();
    } catch (e) {
      debugPrint('Tüm davetler silinemedi: $e');
    }
  }

  Future<void> removePairInvite({
    required String targetDeviceId,
    required String fromDeviceId,
  }) async {
    try {
      await _pairInvites.child(targetDeviceId).child(fromDeviceId).remove();
    } catch (e) {
      // Karşı tarafın gönderdiği daveti silmek için fromAuthUid eşleşmeyebilir.
      debugPrint('Davet silinemedi (devam): $e');
    }
  }

  DatabaseReference pairInvitesRef(String targetDeviceId) =>
      _pairInvites.child(targetDeviceId);

  /// Eski ad; davetler artık `pairInvites/{deviceId}` altında.
  DatabaseReference incomingPairRef(String deviceId) => pairInvitesRef(deviceId);
}
