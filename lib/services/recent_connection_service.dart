import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../utils/user_facing_error.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_signaling_service.dart';
import 'pair_connect_coordinator.dart';
import 'paired_devices_service.dart';

/// Son eşleşmeler + Firebase ile yeniden bağlanma.
class RecentConnectionService extends ChangeNotifier {
  RecentConnectionService._();

  static final RecentConnectionService instance = RecentConnectionService._();

  static const _inviteMaxAge = Duration(minutes: 3);

  final DeviceRegistryService _registry = DeviceRegistryService();
  final FirebaseSignalingService _signaling = FirebaseSignalingService();
  final PairConnectCoordinator _coordinator = PairConnectCoordinator();

  StreamSubscription<DatabaseEvent>? _inviteAddedSubscription;
  StreamSubscription<DatabaseEvent>? _inviteChangedSubscription;
  final Map<String, StreamSubscription<DatabaseEvent>> _pairSessionSubs = {};

  bool _listening = false;
  PairedDevice? _incomingInvitePeer;
  String? _autoConnectActivePeerId;
  final Map<String, Future<TransferSessionController>> _inflight = {};

  void Function(PairedDevice peer)? openAutoConnectScreen;

  PairedDevice? get incomingInvitePeer => _incomingInvitePeer;

  bool get isListening => _listening;

  void clearAutoConnectActive() {
    _autoConnectActivePeerId = null;
  }

  Future<void> ensureListening() async {
    if (_listening) return;
    _listening = true;

    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      await _registerWithTimeout();
      await PairedDevicesService.instance.load();

      final myId = await DeviceIdentityService.instance.getDeviceId();
      await _inviteAddedSubscription?.cancel();
      await _inviteChangedSubscription?.cancel();

      final invitesRef = _registry.pairInvitesRef(myId);
      _inviteAddedSubscription = invitesRef.onChildAdded.listen((event) {
        unawaited(_onInviteSnapshot(event.snapshot));
      });
      _inviteChangedSubscription = invitesRef.onChildChanged.listen((event) {
        unawaited(_onInviteSnapshot(event.snapshot));
      });

      await _refreshPairSessionWatchers();
      PairedDevicesService.instance.addListener(_refreshPairSessionWatchers);

      await _processExistingInvites(myId);
    } catch (e) {
      debugPrint('Davet dinleyicisi: $e');
      _listening = false;
    }
  }

  @Deprecated('ensureListening kullanın')
  Future<void> startHomeListener() => ensureListening();

  void stopListening() {
    _listening = false;
    PairedDevicesService.instance.removeListener(_refreshPairSessionWatchers);
    _inviteAddedSubscription?.cancel();
    _inviteChangedSubscription?.cancel();
    for (final sub in _pairSessionSubs.values) {
      sub.cancel();
    }
    _pairSessionSubs.clear();
    _inviteAddedSubscription = null;
    _inviteChangedSubscription = null;
    _incomingInvitePeer = null;
  }

  Future<void> _refreshPairSessionWatchers() async {
    if (!_listening) return;
    final myId = await DeviceIdentityService.instance.getDeviceId();
    final peers = PairedDevicesService.instance.devices;
    final activeKeys = <String>{};

    for (final peer in peers) {
      final key = PairConnectCoordinator.pairKey(myId, peer.deviceId);
      activeKeys.add(key);
      if (_pairSessionSubs.containsKey(key)) continue;

      _pairSessionSubs[key] =
          _coordinator.sessionRef(myId, peer.deviceId).onValue.listen((event) {
        unawaited(_onPairSessionSnapshot(peer, event.snapshot, myId));
      });
    }

    for (final key in _pairSessionSubs.keys.toList()) {
      if (!activeKeys.contains(key)) {
        await _pairSessionSubs.remove(key)?.cancel();
      }
    }
  }

  Future<void> _onPairSessionSnapshot(
    PairedDevice peer,
    DataSnapshot snapshot,
    String myId,
  ) async {
    if (!snapshot.exists || snapshot.value is! Map) return;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    final hostId = data['hostDeviceId'] as String?;
    if (hostId == null || hostId == myId) return;
    if (data['roomReady'] != true) return;

    final clientMs = (data['clientUpdatedAt'] as num?)?.toInt();
    if (clientMs == null) return;
    final age = DateTime.now().millisecondsSinceEpoch - clientMs;
    if (age < 0 || age > _inviteMaxAge.inMilliseconds) return;

    _incomingInvitePeer = peer;
    notifyListeners();
    await _tryAutoAcceptInvite(peer);
  }

  void clearIncomingInvite() {
    _incomingInvitePeer = null;
    notifyListeners();
  }

  Future<void> _onInviteSnapshot(DataSnapshot snapshot) async {
    final fromId = snapshot.key;
    if (fromId == null) return;

    final value = snapshot.value;
    if (value is! Map) return;
    if (!_isFreshInvite(Map<String, dynamic>.from(value))) return;

    await PairedDevicesService.instance.load();
    final peer = PairedDevicesService.instance.findByDeviceId(fromId);
    if (peer == null) return;

    _incomingInvitePeer = peer;
    notifyListeners();
    await _tryAutoAcceptInvite(peer);
  }

  Future<void> _tryAutoAcceptInvite(PairedDevice peer) async {
    if (!_listening) return;
    if (_autoConnectActivePeerId == peer.deviceId) return;
    if (_inflight.containsKey(peer.deviceId)) return;

    _autoConnectActivePeerId = peer.deviceId;
    final opener = openAutoConnectScreen;
    if (opener != null) {
      opener(peer);
      return;
    }
    debugPrint('Otomatik bağlantı: openAutoConnectScreen tanımlı değil');
  }

  Future<void> _processExistingInvites(String myId) async {
    try {
      final snapshot = await _registry.pairInvitesRef(myId).get();
      if (!snapshot.exists || snapshot.value is! Map) return;

      final invites = Map<String, dynamic>.from(snapshot.value as Map);
      for (final fromId in invites.keys) {
        final data = invites[fromId];
        if (data is! Map) continue;
        if (!_isFreshInvite(Map<String, dynamic>.from(data))) {
          await _registry.removePairInvite(
            targetDeviceId: myId,
            fromDeviceId: fromId,
          );
          continue;
        }
        final peer = PairedDevicesService.instance.findByDeviceId(fromId);
        if (peer != null) {
          _incomingInvitePeer = peer;
          notifyListeners();
          await _tryAutoAcceptInvite(peer);
          return;
        }
      }
    } catch (e) {
      debugPrint('Mevcut davetler okunamadı: $e');
    }
  }

  bool _isFreshInvite(Map<String, dynamic> data) {
    final clientMs = (data['clientCreatedAt'] as num?)?.toInt();
    if (clientMs != null) {
      final age = DateTime.now().millisecondsSinceEpoch - clientMs;
      return age >= 0 && age <= _inviteMaxAge.inMilliseconds;
    }
    final serverMs = (data['createdAt'] as num?)?.toInt();
    if (serverMs != null) {
      final age = DateTime.now().millisecondsSinceEpoch - serverMs;
      return age >= 0 && age <= _inviteMaxAge.inMilliseconds;
    }
    return false;
  }

  String? _roomCodeFromInviteSnapshot(DataSnapshot snapshot) {
    if (!snapshot.exists || snapshot.value is! Map) return null;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (!_isFreshInvite(data)) return null;
    final roomCode = data['roomCode'] as String?;
    if (roomCode == null || roomCode.isEmpty) return null;
    return roomCode.trim().toUpperCase();
  }

  Future<void> _registerWithTimeout() async {
    try {
      await _registry.registerCurrentDevice().timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError(
          'Cihaz sunucuya kaydedilemedi (zaman aşımı). İnternet bağlantınızı kontrol edin.',
        ),
      );
    } on FirebaseException catch (e) {
      throw StateError(userFacingMessage(e));
    }
  }

  Future<TransferSessionController> _withInflight(
    String peerDeviceId,
    Future<TransferSessionController> Function() action,
  ) async {
    final existing = _inflight[peerDeviceId];
    if (existing != null) return existing;

    final future = action();
    _inflight[peerDeviceId] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[peerDeviceId], future)) {
        _inflight.remove(peerDeviceId);
      }
    }
  }

  /// Karşı taraftan gelen davet / oturum ile odaya katıl.
  Future<TransferSessionController> acceptInviteFromPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    return _withInflight(
      peer.deviceId,
      () => _acceptInviteFromPeer(peer, onProgress: onProgress),
    );
  }

  Future<TransferSessionController> _acceptInviteFromPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    var controller = TransferSessionController();
    try {
      onProgress?.call('${peer.displayName} davet etti, odaya katılınıyor…');
      await FirebaseAuthService.instance.ensureSignedIn();
      await _registerWithTimeout();

      final myId = await DeviceIdentityService.instance.getDeviceId();
      String? roomCode = await _readInviteRoomCode(peer.deviceId);

      final sessionRole = await _coordinator.readRole(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      if (sessionRole != null && !sessionRole.isHost) {
        roomCode = sessionRole.roomCode;
      }

      roomCode ??= await _waitForRoomCodeFromPeer(
        peer.deviceId,
        timeout: const Duration(seconds: 20),
      );

      if (roomCode == null) {
        throw StateError(
          'Davet bulunamadı. Sadece bir cihazdan bağlanın; 5 sn sonra tekrar deneyin.',
        );
      }

      return await _joinRoomAsGuest(
        controller: controller,
        peer: peer,
        roomCode: roomCode,
        myId: myId,
        onProgress: onProgress,
      );
    } on StateError {
      if (!controller.isConnected && !controller.isDisposed) {
        await controller.disconnect();
        controller.dispose();
      }
      rethrow;
    } catch (e, stack) {
      debugPrint('acceptInviteFromPeer: $e\n$stack');
      if (!controller.isConnected && !controller.isDisposed) {
        await controller.disconnect();
        controller.dispose();
      }
      throw StateError(userFacingMessage(e));
    }
  }

  /// Listeden dokununca: tek oda (pairConnect), karşı taraf otomatik katılır.
  Future<TransferSessionController> connectToPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    return _withInflight(
      peer.deviceId,
      () => _connectToPeer(peer, onProgress: onProgress),
    );
  }

  Future<TransferSessionController> _connectToPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await _registerWithTimeout();

    final myId = await DeviceIdentityService.instance.getDeviceId();

    onProgress?.call('Karşı cihaz kontrol ediliyor…');
    final existingInvite = await _readInviteRoomCode(peer.deviceId);
    if (existingInvite != null) {
      return _acceptInviteFromPeer(peer, onProgress: onProgress);
    }

    final existingSession = await _coordinator.readRole(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );
    if (existingSession != null && !existingSession.isHost) {
      return _acceptInviteFromPeer(peer, onProgress: onProgress);
    }

    onProgress?.call(
      'Bağlantı hazırlanıyor…\n'
      'Karşı cihazda uygulama açıksa otomatik katılacak.',
    );

    var role = await _coordinator.resolveRole(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );

    if (!role.isHost) {
      return _acceptInviteFromPeer(peer, onProgress: onProgress);
    }

    try {
      await _signaling.assertRoomJoinable(role.roomCode);
    } on StateError {
      await _coordinator.clearSession(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      role = await _coordinator.resolveRole(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      if (!role.isHost) {
        return _acceptInviteFromPeer(peer, onProgress: onProgress);
      }
    }

    var controller = TransferSessionController();
    try {
      await _registry.clearPairInvitesBetween(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      onProgress?.call('Oda açılıyor (${role.roomCode})…');
      await controller.hostPairInvite(peer, roomCode: role.roomCode);
      await _coordinator.markRoomReady(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );

      onProgress?.call('Karşı cihazın katılması bekleniyor…');
      final session = await _waitUntilConnected(
        controller,
        timeout: const Duration(seconds: 90),
      );
      if (session == null) {
        throw StateError(
          'Karşı cihaz katılmadı. Diğer tarafta uygulama açık olsun; '
          'sadece bir kez listeden dokunun.',
        );
      }
      await _coordinator.clearSession(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      clearIncomingInvite();
      return controller;
    } on StateError {
      await _coordinator.clearSession(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      if (!controller.isConnected && !controller.isDisposed) {
        await controller.disconnect();
        controller.dispose();
      }
      rethrow;
    } catch (e, stack) {
      debugPrint('connectToPeer host: $e\n$stack');
      await _coordinator.clearSession(
        myDeviceId: myId,
        peerDeviceId: peer.deviceId,
      );
      if (!controller.isConnected && !controller.isDisposed) {
        await controller.disconnect();
        controller.dispose();
      }
      throw StateError(userFacingMessage(e));
    }
  }

  Future<TransferSessionController> _joinRoomAsGuest({
    required TransferSessionController controller,
    required PairedDevice peer,
    required String roomCode,
    required String myId,
    void Function(String message)? onProgress,
  }) async {
    onProgress?.call('Odaya katılınıyor ($roomCode)…');
    try {
      await _waitUntilRoomJoinable(roomCode, onProgress: onProgress);
    } on StateError catch (e) {
      throw StateError(
        '${e.message} Başka bir oda açılmış olabilir — her iki tarafta '
        'uygulamayı kapatıp açın, yalnızca bir taraftan deneyin.',
      );
    }

    await controller.joinRoom(roomCode);

    onProgress?.call('WebRTC bağlantısı kuruluyor…');
    final session = await _waitUntilConnected(
      controller,
      timeout: const Duration(seconds: 90),
    );
    if (session == null) {
      throw StateError(
        'WebRTC bağlantısı kurulamadı. Aynı ağda veya mobil veride '
        'tekrar deneyin; olmazsa QR ile yeniden eşleşin.',
      );
    }

    await _registry.removePairInvite(
      targetDeviceId: myId,
      fromDeviceId: peer.deviceId,
    );
    clearIncomingInvite();
    return controller;
  }

  /// Ev sahibi odayı Firebase'e yazana kadar bekler (erken pairConnect tetiklenmesi).
  Future<void> _waitUntilRoomJoinable(
    String roomCode, {
    void Function(String message)? onProgress,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    StateError? lastError;
    var attempt = 0;

    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      try {
        await _signaling.assertRoomJoinable(roomCode);
        return;
      } on StateError catch (e) {
        lastError = e;
        final msg = e.message;
        if (msg.contains('müsait değil') && !msg.contains('bulunamadı')) {
          rethrow;
        }
        if (attempt == 1 || attempt % 5 == 0) {
          onProgress?.call('Oda açılması bekleniyor ($roomCode)…');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    throw lastError ??
        StateError(
          'Oda zaman aşımına uğradı. Ev sahibinde uygulama açık olsun; '
          'yalnızca bir cihazdan deneyin.',
        );
  }

  Future<String?> _readInviteRoomCode(String peerDeviceId) async {
    final myId = await DeviceIdentityService.instance.getDeviceId();
    final snapshot = await _registry
        .pairInvitesRef(myId)
        .child(peerDeviceId)
        .get()
        .timeout(const Duration(seconds: 10));
    return _roomCodeFromInviteSnapshot(snapshot);
  }

  Future<String?> _waitForRoomCodeFromPeer(
    String peerDeviceId, {
    required Duration timeout,
  }) async {
    final myId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _registry.pairInvitesRef(myId).child(peerDeviceId);

    final existingCode = _roomCodeFromInviteSnapshot(
      await ref.get().timeout(const Duration(seconds: 10)),
    );
    if (existingCode != null) return existingCode;

    final completer = Completer<String?>();
    late final StreamSubscription<DatabaseEvent> sub;

    sub = ref.onValue.listen(
      (event) {
        final code = _roomCodeFromInviteSnapshot(event.snapshot);
        if (code != null && !completer.isCompleted) {
          completer.complete(code);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } on FirebaseException catch (e) {
      throw StateError(userFacingMessage(e));
    } finally {
      await sub.cancel();
    }
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
