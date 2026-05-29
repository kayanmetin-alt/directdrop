import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'firebase_auth_service.dart';
import 'paired_devices_service.dart';

/// Ana sayfada son eşleşmeler; dokununca davet ile yeniden bağlanır (QR gerekmez).
class RecentConnectionService extends ChangeNotifier {
  RecentConnectionService._();

  static final RecentConnectionService instance = RecentConnectionService._();

  final DeviceRegistryService _registry = DeviceRegistryService();
  StreamSubscription<DatabaseEvent>? _inviteSubscription;
  bool _listening = false;
  PairedDevice? _incomingInvitePeer;

  PairedDevice? get incomingInvitePeer => _incomingInvitePeer;

  Future<void> startHomeListener() async {
    if (_listening) return;
    _listening = true;

    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      await _registry.registerCurrentDevice();
      await PairedDevicesService.instance.load();

      final myId = await DeviceIdentityService.instance.getDeviceId();
      await _inviteSubscription?.cancel();

      _inviteSubscription =
          _registry.incomingPairRef(myId).onChildAdded.listen((event) {
        unawaited(_onInviteAdded(event.snapshot));
      });

      await _processExistingInvites(myId);
    } catch (e) {
      debugPrint('Ana sayfa davet dinleyicisi: $e');
    }
  }

  void stopHomeListener() {
    _listening = false;
    _inviteSubscription?.cancel();
    _inviteSubscription = null;
    _incomingInvitePeer = null;
  }

  void clearIncomingInvite() {
    _incomingInvitePeer = null;
    notifyListeners();
  }

  Future<void> _onInviteAdded(DataSnapshot snapshot) async {
    final fromId = snapshot.key;
    if (fromId == null) return;

    final value = snapshot.value;
    if (value is! Map) return;

    await PairedDevicesService.instance.load();
    final peer = PairedDevicesService.instance.findByDeviceId(fromId);
    if (peer == null) return;

    _incomingInvitePeer = peer;
    notifyListeners();
  }

  Future<void> _processExistingInvites(String myId) async {
    final snapshot = await _registry.incomingPairRef(myId).get();
    if (!snapshot.exists || snapshot.value is! Map) return;

    final invites = Map<String, dynamic>.from(snapshot.value as Map);
    for (final fromId in invites.keys) {
      final peer = PairedDevicesService.instance.findByDeviceId(fromId);
      if (peer != null) {
        _incomingInvitePeer = peer;
        notifyListeners();
        return;
      }
    }
  }

  /// Kayıtlı cihaza yeniden bağlan (QR okutmadan, Firebase daveti ile).
  Future<TransferSessionController> connectToPeer(PairedDevice peer) async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await _registry.registerCurrentDevice();

    final myId = await DeviceIdentityService.instance.getDeviceId();
    final controller = TransferSessionController();

    if (myId.compareTo(peer.deviceId) < 0) {
      await controller.hostPairInvite(peer);
    } else {
      final roomCode = await _waitForRoomCodeFromPeer(
        peer.deviceId,
        timeout: const Duration(seconds: 55),
      );
      if (roomCode == null) {
        throw StateError(
          'Karşı cihaz yanıt vermedi. Diğer tarafta uygulamayı açıp '
          'listeden sizin cihaza dokunmasını isteyin — veya QR ile yeniden eşleşin.',
        );
      }
      await controller.joinRoom(roomCode);
    }

    final session = await _waitUntilConnected(
      controller,
      timeout: const Duration(seconds: 90),
    );
    if (session == null) {
      await controller.disconnect();
      controller.dispose();
      throw StateError(
        'Bağlantı kurulamadı. Her iki tarafta uygulama açık olsun; '
        'olmadıysa Transfer Başlat / Koda Katıl ile QR kullanın.',
      );
    }

    return controller;
  }

  Future<String?> _waitForRoomCodeFromPeer(
    String peerDeviceId, {
    required Duration timeout,
  }) async {
    final myId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _registry.incomingPairRef(myId).child(peerDeviceId);
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final snapshot = await ref.get();
      if (snapshot.exists && snapshot.value is Map) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);
        final roomCode = data['roomCode'] as String?;
        if (roomCode != null && roomCode.isNotEmpty) {
          await ref.remove();
          return roomCode.trim().toUpperCase();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }
    return null;
  }

  Future<TransferSessionController?> _waitUntilConnected(
    TransferSessionController controller, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (controller.isConnected) return controller;
      if (controller.isDisposed) return null;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return controller.isConnected ? controller : null;
  }
}
