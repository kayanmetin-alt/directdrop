import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/signaling_message.dart';
import '../utils/room_code_generator.dart';
import 'firebase_auth_service.dart';

typedef SignalingCallback = FutureOr<void> Function(SignalingMessage message);

class FirebaseSignalingService {
  FirebaseSignalingService({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;
  StreamSubscription<DatabaseEvent>? _messagesSubscription;
  StreamSubscription<DatabaseEvent>? _roomStatusSubscription;
  DatabaseReference? _roomRef;

  // Sinyal mesajlarını sıralı işlemek ve çift işlemeyi önlemek için.
  SignalingCallback? _onMessage;
  final Set<String> _processedKeys = {};
  Future<void> _dispatchChain = Future<void>.value();

  DatabaseReference get _rooms => _database.ref('rooms');

  Future<String> createRoom({
    required String roomCode,
    required String hostPeerId,
    required String deviceName,
    required String devicePlatform,
    required String persistentDeviceId,
  }) async {
    final hostAuthUid = await FirebaseAuthService.instance.requireUid();
    var code = roomCode.trim().toUpperCase();

    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        code = RoomCodeGenerator.generate();
      }
      _roomRef = _rooms.child(code);
      try {
        await _prepareRoomSlot(
          ref: _roomRef!,
          hostAuthUid: hostAuthUid,
          persistentDeviceId: persistentDeviceId,
        );
        await _roomRef!.set({
          'createdAt': ServerValue.timestamp,
          'hostPeerId': hostPeerId,
          'hostDeviceName': deviceName,
          'hostDevicePlatform': devicePlatform,
          'hostPersistentId': persistentDeviceId,
          'hostAuthUid': hostAuthUid,
          'allowedUids': {hostAuthUid: true},
          'status': 'waiting',
        });
        return code;
      } on FirebaseException catch (e) {
        if (e.code == 'permission-denied' && attempt < 3) {
          debugPrint(
            'createRoom izin reddedildi ($code), yeni kod deneniyor…',
          );
          continue;
        }
        if (e.code == 'permission-denied') {
          throw StateError(
            'Oda oluşturulamadı. Uygulamayı kapatıp yeniden açın; '
            'olmazsa QR ile yeniden eşleşin.',
          );
        }
        debugPrint('createRoom Firebase hatası: ${e.code} ${e.message}');
        rethrow;
      }
    }

    throw StateError('Oda oluşturulamadı. Lütfen tekrar deneyin.');
  }

  Future<void> _prepareRoomSlot({
    required DatabaseReference ref,
    required String hostAuthUid,
    required String persistentDeviceId,
  }) async {
    final existing = await ref.get();
    if (!existing.exists || existing.value is! Map) return;

    final data = Map<String, dynamic>.from(existing.value as Map);
    final status = data['status'] as String?;
    final existingHostUid = data['hostAuthUid'] as String?;
    final existingHostPersistent = data['hostPersistentId'] as String?;
    final allowed = data['allowedUids'];
    final allowedSelf = allowed is Map &&
        Map<String, dynamic>.from(allowed)[hostAuthUid] == true;

    final canReuse = existingHostUid == hostAuthUid ||
        existingHostPersistent == persistentDeviceId ||
        allowedSelf ||
        status == 'closed' ||
        status == 'connected';

    if (!canReuse) {
      throw FirebaseException(
        plugin: 'firebase_database',
        code: 'permission-denied',
        message: 'Oda kodu başka bir oturuma ait.',
      );
    }

    try {
      await ref.remove();
    } catch (e) {
      debugPrint('Eski oda silinemedi (${ref.path}): $e');
    }
  }

  /// Davet ile katılmadan önce odanın hâlâ açık olduğunu doğrular.
  Future<void> assertRoomJoinable(String roomCode) async {
    final normalized = roomCode.trim().toUpperCase();
    final snapshot = await _rooms.child(normalized).get();
    if (!snapshot.exists) {
      throw StateError('Oda bulunamadı veya süresi doldu. Tekrar deneyin.');
    }
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    final status = data['status'] as String?;
    if (status == 'closed') {
      throw StateError('Bu oda kapatılmış. Yeniden eşleşin.');
    }
    if (status != 'waiting') {
      throw StateError(
        'Oda artık müsait değil (durum: $status). '
        'Sadece bir cihazdan bağlanmayı deneyin.',
      );
    }
  }

  Future<void> joinRoom({
    required String roomCode,
    required String guestPeerId,
    required String deviceName,
    required String devicePlatform,
    required String persistentDeviceId,
  }) async {
    final guestAuthUid = await FirebaseAuthService.instance.requireUid();
    final normalizedCode = roomCode.trim().toUpperCase();
    await assertRoomJoinable(normalizedCode);

    _roomRef = _rooms.child(normalizedCode);
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

    try {
      await _roomRef!.update({
        'guestPeerId': guestPeerId,
        'guestDeviceName': deviceName,
        'guestDevicePlatform': devicePlatform,
        'guestPersistentId': persistentDeviceId,
        'guestAuthUid': guestAuthUid,
        'allowedUids': allowedUids,
        'status': 'connected',
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw StateError(
          'Odaya katılınamadı. Kod hatalı, süresi dolmuş veya oda dolu. '
          'Ev sahibinden yeni kod isteyin.',
        );
      }
      debugPrint('joinRoom Firebase hatası: ${e.code} ${e.message}');
      rethrow;
    }
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

  Future<String?> getHostDevicePlatform(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('hostDevicePlatform').get();
    return snapshot.value as String?;
  }

  Future<String?> getGuestDevicePlatform(String roomCode) async {
    final snapshot =
        await _rooms.child(roomCode).child('guestDevicePlatform').get();
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

  /// Misafir odaya katılınca anında haber verir (polling yerine).
  StreamSubscription<DatabaseEvent> watchGuestPeerId(
    String roomCode,
    void Function(String guestPeerId) onGuest,
  ) {
    return _rooms.child(roomCode).child('guestPeerId').onValue.listen((event) {
      final value = event.snapshot.value;
      if (value is String && value.isNotEmpty) {
        onGuest(value);
      }
    });
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

    try {
      await _roomRef!
          .child('signaling')
          .child(message.toPeerId)
          .child(messageId)
          .set(message.toJson());
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw StateError(
          'Sinyal gönderilemedi (oda izni). Uygulamayı kapatıp açın veya QR ile yeniden eşleşin.',
        );
      }
      rethrow;
    }
  }

  void listenForMessages({
    required String roomCode,
    required String localPeerId,
    required SignalingCallback onMessage,
  }) {
    _roomRef ??= _rooms.child(roomCode);
    _onMessage = onMessage;
    _messagesSubscription?.cancel();
    _messagesSubscription = _roomRef!
        .child('signaling')
        .child(localPeerId)
        .onChildAdded
        .listen((event) {
      _enqueue(event.snapshot);
    });
  }

  /// Mesajları sırayla, çift işlemeden ele alır; başarılı işlenince Firebase'den siler.
  void _enqueue(DataSnapshot snapshot) {
    final key = snapshot.key;
    if (key == null) return;
    final value = snapshot.value;
    if (value is! Map) return;
    if (_processedKeys.contains(key)) return;
    _processedKeys.add(key);

    final message = SignalingMessage.fromJson(value);
    _dispatchChain = _dispatchChain.then((_) async {
      var handled = false;
      try {
        await _onMessage?.call(message);
        handled = true;
      } catch (e) {
        debugPrint('Sinyal mesajı işlenemedi: $e');
      }
      if (!handled) {
        _processedKeys.remove(key);
        return;
      }
      try {
        await snapshot.ref.remove();
      } catch (_) {}
    });
  }

  Future<void> clearSignaling() async {
    _processedKeys.clear();
    await _roomRef?.child('signaling').remove();
  }

  Future<void> replayPendingMessages({
    required String localPeerId,
    required SignalingCallback onMessage,
  }) async {
    if (_roomRef == null) return;
    _onMessage = onMessage;

    final snapshot =
        await _roomRef!.child('signaling').child(localPeerId).get();
    if (snapshot.exists && snapshot.value is Map) {
      final children = snapshot.children.toList()
        ..sort((a, b) {
          final aTs = _messageTimestamp(a);
          final bTs = _messageTimestamp(b);
          if (aTs != bTs) return aTs.compareTo(bTs);
          return (a.key ?? '').compareTo(b.key ?? '');
        });
      for (final child in children) {
        _enqueue(child);
      }
    }
    // Kuyruktaki tüm mesajların işlenmesini bekle.
    await _dispatchChain;
  }

  Future<void> notifyPeerDeparted({
    required String localPeerId,
    required String remotePeerId,
  }) async {
    if (_roomRef == null) return;
    try {
      await sendMessage(
        SignalingMessage(
          type: SignalingType.peerLeft,
          fromPeerId: localPeerId,
          toPeerId: remotePeerId,
        ),
      );
    } catch (e) {
      debugPrint('peerLeft gönderilemedi: $e');
    }
  }

  void listenForRoomClosed({
    required String roomCode,
    required void Function() onClosed,
  }) {
    _roomStatusSubscription?.cancel();
    _roomStatusSubscription =
        _rooms.child(roomCode).child('status').onValue.listen((event) {
      if (event.snapshot.value == 'closed') onClosed();
    });
  }

  Future<void> closeRoom() async {
    await _roomRef?.update({'status': 'closed'});
    await dispose();
  }

  Future<void> dispose() async {
    await _messagesSubscription?.cancel();
    _messagesSubscription = null;
    await _roomStatusSubscription?.cancel();
    _roomStatusSubscription = null;
    _roomRef = null;
    _onMessage = null;
    _processedKeys.clear();
  }

  int _messageTimestamp(DataSnapshot snapshot) {
    final value = snapshot.value;
    if (value is! Map) return 0;
    final ts = value['timestamp'];
    if (ts is int) return ts;
    if (ts is num) return ts.toInt();
    return 0;
  }
}
