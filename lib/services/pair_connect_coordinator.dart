import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../utils/room_code_generator.dart';
import 'firebase_auth_service.dart';

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
        ? '${deviceIdA}__${deviceIdB}'
        : '${deviceIdB}__${deviceIdA}';
  }

  DatabaseReference sessionRef(String myId, String peerId) =>
      _sessions.child(pairKey(myId, peerId));

  bool _isFreshSession(Map<String, dynamic> data) {
    final ms = (data['clientUpdatedAt'] as num?)?.toInt();
    if (ms == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ms;
    return age >= 0 && age <= _sessionMaxAge.inMilliseconds;
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

  /// Ev sahibi veya misafir rolünü tek oturumda belirler.
  Future<PairConnectRole> resolveRole({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    final ref = sessionRef(myDeviceId, peerDeviceId);
    final existing = await ref.get();
    final parsed = _roleFromSnapshot(existing, myDeviceId);
    if (parsed != null) return parsed;

    final roomCode = RoomCodeGenerator.generate();
    final uid = await FirebaseAuthService.instance.requireUid();
    try {
      await ref.set({
        'hostDeviceId': myDeviceId,
        'roomCode': roomCode,
        'roomReady': false,
        'fromAuthUid': uid,
        'clientUpdatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      debugPrint('pairConnect yazılamadı (yarış), yeniden okunuyor');
    }

    await Future<void>.delayed(const Duration(milliseconds: 400));
    final after = await ref.get();
    final role = _roleFromSnapshot(after, myDeviceId);
    if (role != null) return role;

    return PairConnectRole.host(roomCode);
  }

  Future<void> markRoomReady({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    final ref = sessionRef(myDeviceId, peerDeviceId);
    try {
      await ref.update({
        'roomReady': true,
        'clientUpdatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('pairConnect roomReady güncellenemedi: $e');
    }
  }

  Future<PairConnectRole?> readRole({
    required String myDeviceId,
    required String peerDeviceId,
  }) async {
    final snapshot = await sessionRef(myDeviceId, peerDeviceId).get();
    return _roleFromSnapshot(snapshot, myDeviceId);
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
