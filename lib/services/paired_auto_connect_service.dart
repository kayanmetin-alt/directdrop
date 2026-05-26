import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models/paired_device.dart';
import '../models/room.dart';
import '../providers/transfer_session_controller.dart';
import '../services/webrtc_service.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'paired_devices_service.dart';
import 'paired_presence_service.dart';

class PairedAutoConnectService extends ChangeNotifier {
  PairedAutoConnectService._();

  static final PairedAutoConnectService instance = PairedAutoConnectService._();

  static const _connectCooldown = Duration(seconds: 15);
  static const _syncInterval = Duration(seconds: 20);
  static const _pendingSessionTimeout = Duration(seconds: 95);
  static const _inviteNudgeInterval = Duration(seconds: 12);

  final DeviceRegistryService _registry = DeviceRegistryService();
  final Map<String, TransferSessionController> _sessionsByPeerId = {};
  final Map<String, DateTime> _lastConnectAttempt = {};
  final Set<String> _connectingPeers = {};
  final Set<String> _processedInviteKeys = {};
  StreamSubscription<DatabaseEvent>? _inviteSubscription;
  StreamSubscription<DatabaseEvent>? _inviteChangedSubscription;
  Timer? _syncDebounce;
  Timer? _periodicSyncTimer;
  String? _myDeviceId;
  bool _started = false;
  bool _syncInProgress = false;
  final Map<String, DateTime> _sessionStartedAt = {};
  final Map<String, DateTime> _lastInviteNudge = {};

  TransferSessionController? sessionFor(String peerDeviceId) =>
      _sessionsByPeerId[peerDeviceId];

  bool isConnectedTo(String peerDeviceId) {
    final session = _sessionsByPeerId[peerDeviceId];
    return session != null && session.isConnected;
  }

  bool isConnectingTo(String peerDeviceId) =>
      _connectingPeers.contains(peerDeviceId) ||
      isPendingConnection(peerDeviceId);

  bool isPendingConnection(String peerDeviceId) {
    final session = _sessionsByPeerId[peerDeviceId];
    if (session == null) return false;
    return !session.isConnected;
  }

  bool isHostingPeer(String peerDeviceId) {
    final session = _sessionsByPeerId[peerDeviceId];
    if (session == null || session.isConnected) return false;
    return session.session?.role == PeerRole.host;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    _myDeviceId = await DeviceIdentityService.instance.getDeviceId();
    PairedPresenceService.instance.addListener(_onPresenceChanged);
    PairedDevicesService.instance.addListener(_onPresenceChanged);
    await _startInviteListener();
    await processPendingInvites();
    _startPeriodicSync();
    _scheduleSync();
  }

  void onAppResumed() {
    if (!_started) return;
    _scheduleSync(immediate: true);
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    PairedPresenceService.instance.removeListener(_onPresenceChanged);
    PairedDevicesService.instance.removeListener(_onPresenceChanged);
    await _inviteSubscription?.cancel();
    await _inviteChangedSubscription?.cancel();
    _inviteSubscription = null;
    _inviteChangedSubscription = null;
    _syncDebounce?.cancel();
    _syncDebounce = null;
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;

    for (final session in _sessionsByPeerId.values) {
      await session.disconnect();
      session.dispose();
    }
    _sessionsByPeerId.clear();
    _connectingPeers.clear();
    _processedInviteKeys.clear();
    _lastConnectAttempt.clear();
    _sessionStartedAt.clear();
    _lastInviteNudge.clear();
    notifyListeners();
  }

  Future<void> ensureConnection(PairedDevice peer) async {
    if (isConnectedTo(peer.deviceId)) return;
    if (isConnectingTo(peer.deviceId)) return;
    _scheduleSync();
  }

  /// Manuel dokunuş için bağlantı dener. Düşük deviceId her zaman ev sahibi olur.
  Future<void> requestConnection(
    PairedDevice peer, {
    bool force = false,
  }) async {
    if (isConnectedTo(peer.deviceId)) return;

    if (force) {
      _lastConnectAttempt.remove(peer.deviceId);
    } else if (isConnectingTo(peer.deviceId)) {
      return;
    }

    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();
    _myDeviceId = myId;

    if (_shouldHost(myId, peer.deviceId)) {
      final existing = _sessionsByPeerId[peer.deviceId];
      if (existing != null && !existing.isConnected) {
        if (!force) return;
        await _disposeSession(peer.deviceId);
      }
      await _hostForPeer(peer);
      return;
    }

    // Yüksek deviceId: ev sahibi olma, gelen daveti bekle.
    await processPendingInvites();
    _scheduleSync(immediate: true);
  }

  /// Eşleşmiş cihazdan gelen wake/davet — onay ekranı açılmaz.
  Future<void> handleIncomingWake(WakeRequest request) async {
    final fromId = request.fromDeviceId;
    if (fromId.isEmpty || !_isKnownPeer(fromId)) return;
    if (isConnectedTo(fromId)) return;

    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();

    if (_shouldHost(myId, fromId)) {
      // Biz ev sahibiyiz; karşı taraf yanlışlıkla oda açmış olabilir.
      return;
    }

    final existing = _sessionsByPeerId[fromId];
    if (existing != null) {
      if (existing.isConnected) return;
      if (existing.session?.role == PeerRole.host) {
        await _disposeSession(fromId);
      } else if (_connectingPeers.contains(fromId)) {
        return;
      }
    }

    await acceptWakeRequest(request);
  }

  Future<TransferSessionController> acceptWakeRequest(
    WakeRequest request,
  ) async {
    final peerId = request.fromDeviceId;

    final existing = _sessionsByPeerId[peerId];
    if (existing != null) {
      if (existing.isConnected) return existing;
      if (existing.session?.role == PeerRole.host) {
        await _disposeSession(peerId);
      } else if (_connectingPeers.contains(peerId)) {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (DateTime.now().isBefore(deadline)) {
          if (existing.isConnected) return existing;
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        return existing;
      } else {
        await _disposeSession(peerId);
      }
    }

    _connectingPeers.add(peerId);
    notifyListeners();

    final controller = TransferSessionController();
    _sessionsByPeerId[peerId] = controller;
    _sessionStartedAt[peerId] = DateTime.now();
    _attachSessionListener(peerId, controller);

    try {
      await controller.joinFromWake(request);
      return controller;
    } finally {
      _connectingPeers.remove(peerId);
      notifyListeners();
    }
  }

  Future<void> _startInviteListener() async {
    await _inviteSubscription?.cancel();
    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();
    _myDeviceId = myId;

    _inviteSubscription =
        _registry.incomingPairRef(myId).onChildAdded.listen((event) async {
      await _handleInviteSnapshot(event.snapshot);
    });
    _inviteChangedSubscription =
        _registry.incomingPairRef(myId).onChildChanged.listen((event) async {
      await _handleInviteSnapshot(event.snapshot);
    });
  }

  Future<void> processPendingInvites() async {
    if (!_started) return;

    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();
    final snapshot = await _registry.incomingPairRef(myId).get();
    if (!snapshot.exists || snapshot.value is! Map) return;

    final invites = Map<String, dynamic>.from(snapshot.value as Map);
    for (final entry in invites.entries) {
      await _handleInviteSnapshot(snapshot.child(entry.key));
    }
  }

  Future<void> _handleInviteSnapshot(DataSnapshot snapshot) async {
    final fromId = snapshot.key;
    if (fromId == null) return;

    final value = snapshot.value;
    if (value is! Map) return;

    final roomCode = value['roomCode'] as String?;
    if (roomCode == null || roomCode.isEmpty) return;

    final inviteKey = '$fromId:$roomCode';
    if (_processedInviteKeys.contains(inviteKey)) return;

    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();

    if (!_isKnownPeer(fromId)) {
      await _registry.removePairInvite(
        targetDeviceId: myId,
        fromDeviceId: fromId,
      );
      return;
    }

    if (isConnectedTo(fromId)) {
      await _registry.removePairInvite(
        targetDeviceId: myId,
        fromDeviceId: fromId,
      );
      return;
    }

    if (_shouldHost(myId, fromId)) {
      await _registry.removePairInvite(
        targetDeviceId: myId,
        fromDeviceId: fromId,
      );
      return;
    }

    final existing = _sessionsByPeerId[fromId];
    if (existing != null) {
      if (existing.isConnected) {
        await _registry.removePairInvite(
          targetDeviceId: myId,
          fromDeviceId: fromId,
        );
        return;
      }
      if (existing.session?.role == PeerRole.host) {
        await _disposeSession(fromId);
      } else if (_connectingPeers.contains(fromId)) {
        await _registry.removePairInvite(
          targetDeviceId: myId,
          fromDeviceId: fromId,
        );
        return;
      }
    }

    _processedInviteKeys.add(inviteKey);

    final request = WakeRequest(
      roomCode: roomCode,
      fromDeviceId: fromId,
      fromDeviceName: value['fromDeviceName'] as String? ?? 'Cihaz',
      type: WakeRequestType.connect,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      await acceptWakeRequest(request);
    } catch (e) {
      debugPrint('Davet ile otomatik bağlantı kurulamadı: $e');
      _processedInviteKeys.remove(inviteKey);
    }

    await _registry.removePairInvite(
      targetDeviceId: myId,
      fromDeviceId: fromId,
    );
  }

  void _onPresenceChanged() {
    for (final peer in PairedDevicesService.instance.devices) {
      if (!PairedPresenceService.instance.isStrictlyOnline(peer.deviceId) &&
          _sessionsByPeerId.containsKey(peer.deviceId)) {
        unawaited(_disposeSession(peer.deviceId));
      }
    }
    _scheduleSync(immediate: true);
  }

  void _startPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(_syncInterval, (_) {
      _scheduleSync(immediate: true);
    });
  }

  void _scheduleSync({bool immediate = false}) {
    if (!_started) return;
    _syncDebounce?.cancel();
    final delay = immediate ? Duration.zero : const Duration(seconds: 2);
    _syncDebounce = Timer(delay, () {
      unawaited(_syncConnections());
    });
  }

  Future<void> _syncConnections() async {
    if (!_started || _syncInProgress) return;
    _syncInProgress = true;

    try {
      final myId =
          _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();
      _myDeviceId = myId;

      await _expireStaleSessions();
      await processPendingInvites();
      await _nudgePendingHostSessions();

      for (final peer in PairedDevicesService.instance.devices) {
        if (!PairedPresenceService.instance.isStrictlyOnline(peer.deviceId)) {
          continue;
        }
        if (isConnectedTo(peer.deviceId) ||
            _connectingPeers.contains(peer.deviceId)) {
          continue;
        }

        final pending = _sessionsByPeerId[peer.deviceId];
        if (pending != null && !pending.isConnected) {
          continue;
        }

        final lastAttempt = _lastConnectAttempt[peer.deviceId];
        if (lastAttempt != null &&
            DateTime.now().difference(lastAttempt) < _connectCooldown) {
          continue;
        }

        if (myId.compareTo(peer.deviceId) >= 0) {
          continue;
        }

        await _hostForPeer(peer);
      }
    } finally {
      _syncInProgress = false;
    }
  }

  bool _shouldHost(String myId, String peerId) => myId.compareTo(peerId) < 0;

  Future<void> _hostForPeer(PairedDevice peer) async {
    _lastConnectAttempt[peer.deviceId] = DateTime.now();
    _connectingPeers.add(peer.deviceId);
    notifyListeners();

    final controller = TransferSessionController();
    _sessionsByPeerId[peer.deviceId] = controller;
    _sessionStartedAt[peer.deviceId] = DateTime.now();
    _attachSessionListener(peer.deviceId, controller);

    try {
      await controller.connectToPairedDevice(peer);
    } catch (e) {
      debugPrint('Otomatik bağlantı başlatılamadı (${peer.displayName}): $e');
      await _disposeSession(peer.deviceId);
    } finally {
      _connectingPeers.remove(peer.deviceId);
      notifyListeners();
    }
  }

  Future<void> _disposeSession(String peerId) async {
    final session = _sessionsByPeerId.remove(peerId);
    _sessionStartedAt.remove(peerId);
    _lastInviteNudge.remove(peerId);
    if (session == null) return;
    session.dispose();
    _processedInviteKeys.removeWhere((key) => key.startsWith('$peerId:'));
    notifyListeners();
  }

  Future<void> _nudgePendingHostSessions() async {
    final myId =
        _myDeviceId ?? await DeviceIdentityService.instance.getDeviceId();
    final now = DateTime.now();

    for (final entry in _sessionsByPeerId.entries) {
      final peerId = entry.key;
      final controller = entry.value;
      if (controller.isConnected ||
          controller.session?.role != PeerRole.host) {
        continue;
      }

      final lastNudge = _lastInviteNudge[peerId];
      if (lastNudge != null &&
          now.difference(lastNudge) < _inviteNudgeInterval) {
        continue;
      }

      final peer = PairedDevicesService.instance.devices
          .where((d) => d.deviceId == peerId)
          .firstOrNull;
      final roomCode = controller.session?.roomCode;
      if (peer == null || roomCode == null) continue;

      _lastInviteNudge[peerId] = now;
      try {
        await _registry.sendWakeRequest(
          targetDeviceId: peer.deviceId,
          request: WakeRequest(
            roomCode: roomCode,
            fromDeviceId: myId,
            fromDeviceName: DeviceIdentityService.instance.displayName,
            type: WakeRequestType.connect,
            createdAt: now.millisecondsSinceEpoch,
          ),
        );
        await _registry.sendPairInvite(
          targetDeviceId: peer.deviceId,
          fromDeviceId: myId,
          fromDeviceName: DeviceIdentityService.instance.displayName,
          roomCode: roomCode,
        );
      } catch (e) {
        debugPrint('Davet yenileme başarısız (${peer.displayName}): $e');
      }
    }
  }

  Future<void> _expireStaleSessions() async {
    final now = DateTime.now();
    for (final peerId in _sessionsByPeerId.keys.toList()) {
      final session = _sessionsByPeerId[peerId];
      if (session == null || session.isConnected) continue;

      final started = _sessionStartedAt[peerId];
      if (started == null ||
          now.difference(started) < _pendingSessionTimeout) {
        continue;
      }

      debugPrint(
        'Bekleyen oturum zaman aşımı ($peerId); yeniden denenecek.',
      );
      await _disposeSession(peerId);
    }
  }

  void _attachSessionListener(
    String peerDeviceId,
    TransferSessionController controller,
  ) {
    controller.addListener(() {
      if (controller.isConnected) {
        _processedInviteKeys.removeWhere((key) => key.startsWith('$peerDeviceId:'));
      }

      if (!controller.isConnected &&
          controller.connectionState == WebRtcConnectionState.failed &&
          controller.session != null) {
        // Başarısız oturumu temizle; cooldown sonrası tekrar denenecek.
        if (_sessionsByPeerId[peerDeviceId] == controller) {
          unawaited(_disposeSession(peerDeviceId));
        }
        return;
      }

      if (!controller.isConnected &&
          controller.connectionState == WebRtcConnectionState.idle &&
          controller.session == null &&
          !controller.isBusy) {
        if (_sessionsByPeerId[peerDeviceId] == controller) {
          unawaited(_disposeSession(peerDeviceId));
        }
        return;
      }

      notifyListeners();
    });
  }

  bool _isKnownPeer(String deviceId) {
    return PairedDevicesService.instance.devices
        .any((d) => d.deviceId == deviceId);
  }

  Future<TransferSessionController?> waitForSession(
    String peerDeviceId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final existing = sessionFor(peerDeviceId);
    if (existing != null && existing.isConnected) return existing;

    final peer = PairedDevicesService.instance.devices
        .where((d) => d.deviceId == peerDeviceId)
        .firstOrNull;
    if (peer == null) return null;

    await ensureConnection(peer);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await processPendingInvites();
      final session = sessionFor(peerDeviceId);
      if (session != null && session.isConnected) return session;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return sessionFor(peerDeviceId);
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) return iterator.current;
    return null;
  }
}
