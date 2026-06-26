import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// Tek bir yeniden bağlanma oturumu (çift oda / çift tıklama önlenir).
class PairConnectRole {
  const PairConnectRole._({
    required this.isHost,
    required this.roomCode,
    required this.roomReady,
  });

  final bool isHost;
  final String roomCode;
  final bool roomReady;

  factory PairConnectRole.host(
    String roomCode, {
    bool roomReady = false,
  }) =>
      PairConnectRole._(
        isHost: true,
        roomCode: roomCode,
        roomReady: roomReady,
      );

  factory PairConnectRole.guest(
    String roomCode, {
    bool roomReady = false,
  }) =>
      PairConnectRole._(
        isHost: false,
        roomCode: roomCode,
        roomReady: roomReady,
      );
}

class PairConnectCoordinator {
  PairConnectCoordinator({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;
  static const _sessionMaxAge = Duration(minutes: 3);

  DatabaseReference get _sessions => _database.ref('pairConnect');

  static String pairKey(String deviceIdA, String deviceIdB) {
    return deviceIdA.compareTo(deviceIdB) < 0
        ? '${deviceIdA}__$deviceIdB'
        : '${deviceIdB}__$deviceIdA';
  }

  DatabaseReference sessionRef(String myId, String peerId) =>
      _sessions.child(pairKey(myId, peerId));

  // Cihaz saatleri arasındaki fark için tolerans (emülatör vb.).
  static const _clockSkewToleranceMs = 120000;

  bool _isFreshSession(Map<String, dynamic> data) {
    final ms = (data['clientUpdatedAt'] as num?)?.toInt();
    if (ms == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ms;
    return age >= -_clockSkewToleranceMs &&
        age <= _sessionMaxAge.inMilliseconds;
  }

  PairConnectRole? _roleFromSnapshot(
    DataSnapshot snapshot,
    String myDeviceId,
  ) {
    if (!snapshot.exists || snapshot.value is! Map) return null;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (!_isFreshSession(data)) return null;

    final hostId = data['hostDeviceId'] as String?;
    final roomCode = (data['roomCode'] as String?)?.trim().toUpperCase();
    if (hostId == null || roomCode == null || roomCode.isEmpty) return null;

    final roomReady = data['roomReady'] == true;
    if (hostId == myDeviceId) {
      return PairConnectRole.host(roomCode, roomReady: roomReady);
    }
    return PairConnectRole.guest(roomCode, roomReady: roomReady);
  }

  Future<PairConnectRole?> readRole({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    try {
      final snapshot = await sessionRef(myDeviceId, peerDeviceId).get();
      return _roleFromSnapshot(snapshot, myDeviceId);
    } on FirebaseException catch (e) {
      debugPrint('pairConnect okunamadı: $e');
      return null;
    }
  }

  Future<void> clearSession({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    try {
      await sessionRef(myDeviceId, peerDeviceId).remove();
    } catch (e) {
      debugPrint('pairConnect temizlenemedi: $e');
    }
  }
}
