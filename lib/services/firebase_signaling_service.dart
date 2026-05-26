import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../models/signaling_message.dart';
import 'firebase_auth_service.dart';

typedef SignalingCallback = FutureOr<void> Function(SignalingMessage message);

class FirebaseSignalingService {
  FirebaseSignalingService({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;
  StreamSubscription<DatabaseEvent>? _messagesSubscription;
  DatabaseReference? _roomRef;

  DatabaseReference get _rooms => _database.ref('rooms');

  Future<String> createRoom({
    required String roomCode,
    required String hostPeerId,
    required String deviceName,
    required String persistentDeviceId,
  }) async {
    final hostAuthUid = await FirebaseAuthService.instance.requireUid();
    _roomRef = _rooms.child(roomCode);
    await _roomRef!.set({
      'createdAt': ServerValue.timestamp,
      'hostPeerId': hostPeerId,
      'hostDeviceName': deviceName,
      'hostPersistentId': persistentDeviceId,
      'hostAuthUid': hostAuthUid,
      'allowedUids': {hostAuthUid: true},
      'status': 'waiting',
    });
    return roomCode;
  }

  Future<void> joinRoom({
    required String roomCode,
    required String guestPeerId,
    required String deviceName,
    required String persistentDeviceId,
  }) async {
    final guestAuthUid = await FirebaseAuthService.instance.requireUid();
    _roomRef = _rooms.child(roomCode);
    final snapshot = await _roomRef!.get();
    if (!snapshot.exists) {
      throw StateError('Oda bulunamadı. Kodu kontrol edin.');
    }

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (data['status'] == 'closed') {
      throw StateError('Bu oda kapatılmış.');
    }

    final allowedUids = <String, dynamic>{};
    final existing = data['allowedUids'];
    if (existing is Map) {
      allowedUids.addAll(Map<String, dynamic>.from(existing));
    }
    allowedUids[guestAuthUid] = true;

    await _roomRef!.update({
      'guestPeerId': guestPeerId,
      'guestDeviceName': deviceName,
      'guestPersistentId': persistentDeviceId,
      'guestAuthUid': guestAuthUid,
      'allowedUids': allowedUids,
      'status': 'connected',
    });
  }

  Future<String?> getHostPersistentId(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('hostPersistentId').get();
    return snapshot.value as String?;
  }

  Future<String?> getGuestPersistentId(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('guestPersistentId').get();
    return snapshot.value as String?;
  }

  Future<String?> getHostDeviceName(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('hostDeviceName').get();
    return snapshot.value as String?;
  }

  Future<String?> getGuestDeviceName(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('guestDeviceName').get();
    return snapshot.value as String?;
  }

  Future<String?> getHostPeerId(String roomCode) async {
    final snapshot = await _rooms.child(roomCode).child('hostPeerId').get();
    return snapshot.value as String?;
  }

  Future<String?> getGuestPeerId(String roomCode) async {
    final snapshot = await _rooms.child(roomCode).child('guestPeerId').get();
    return snapshot.value as String?;
  }

  Future<void> sendMessage(SignalingMessage message) async {
    if (_roomRef == null) {
      throw StateError('Oda bağlantısı yok.');
    }

    final messageId = _roomRef!
        .child('signaling')
        .child(message.toPeerId)
        .push()
        .key!;

    await _roomRef!
        .child('signaling')
        .child(message.toPeerId)
        .child(messageId)
        .set(message.toJson());
  }

  void listenForMessages({
    required String roomCode,
    required String localPeerId,
    required SignalingCallback onMessage,
  }) {
    _roomRef ??= _rooms.child(roomCode);
    _messagesSubscription?.cancel();
    _messagesSubscription = _roomRef!
        .child('signaling')
        .child(localPeerId)
        .onChildAdded
        .listen((event) {
      final value = event.snapshot.value;
      if (value is! Map) return;

      final message = SignalingMessage.fromJson(value);
      onMessage(message);

      // İşlenen mesajı temizle — Realtime DB şişmesin.
      event.snapshot.ref.remove();
    });
  }

  Future<void> clearSignaling() async {
    await _roomRef?.child('signaling').remove();
  }

  Future<void> replayPendingMessages({
    required String localPeerId,
    required SignalingCallback onMessage,
  }) async {
    if (_roomRef == null) return;

    final snapshot =
        await _roomRef!.child('signaling').child(localPeerId).get();
    if (!snapshot.exists || snapshot.value is! Map) return;

    final children = Map<String, dynamic>.from(snapshot.value as Map);
    for (final entry in children.entries) {
      final value = entry.value;
      if (value is! Map) continue;

      final message =
          SignalingMessage.fromJson(Map<String, dynamic>.from(value));
      await onMessage(message);
      await _roomRef!
          .child('signaling')
          .child(localPeerId)
          .child(entry.key)
          .remove();
    }
  }

  Future<void> closeRoom() async {
    await _roomRef?.update({'status': 'closed'});
    await dispose();
  }

  Future<void> dispose() async {
    await _messagesSubscription?.cancel();
    _messagesSubscription = null;
    _roomRef = null;
  }
}
