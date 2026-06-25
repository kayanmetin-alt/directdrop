import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import '../providers/transfer_session_controller.dart';
import '../utils/session_exit_helper.dart';
import '../utils/user_facing_error.dart';
import '../utils/session_switch_helper.dart';
import 'active_session_registry.dart';
import 'device_identity_service.dart';
import 'device_registry_service.dart';
import 'desktop_background_service.dart';
import 'desktop_overlay_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_signaling_service.dart';
import 'notification_service.dart';
import 'pair_connect_coordinator.dart';
import 'paired_auto_connect_service.dart';
import 'paired_devices_service.dart';
import 'persistent_invite_code_service.dart';
import 'startup_gate.dart';

/// Son eşleşmeler + Firebase ile yeniden bağlanma.
class RecentConnectionService extends ChangeNotifier {
  RecentConnectionService._();

  static final RecentConnectionService instance = RecentConnectionService._();

  static const _inviteMaxAge = Duration(minutes: 5);

  /// Karşı cihaz bildirime dokunup onaylayana kadar bekleme süresi.
  static const _reconnectWaitTimeout = Duration(minutes: 2);

  /// Cihaz saatleri arasındaki fark (özellikle emülatörlerde) yüzünden
  /// karşı cihazın zaman damgası "gelecekte" görünebilir. Bu tolerans olmadan
  /// taze davet/istek yanlışlıkla "eski" sayılıp yok sayılır.
  static const _clockSkewToleranceMs = 120000; // 2 dk

  final DeviceRegistryService _registry = DeviceRegistryService();
  final FirebaseSignalingService _signaling = FirebaseSignalingService();
  final PairConnectCoordinator _coordinator = PairConnectCoordinator();

  StreamSubscription<DatabaseEvent>? _inviteAddedSubscription;
  StreamSubscription<DatabaseEvent>? _inviteChangedSubscription;
  StreamSubscription<DatabaseEvent>? _reconnectValueSubscription;
  StreamSubscription<DatabaseEvent>? _peerDepartedAddedSubscription;
  StreamSubscription<DatabaseEvent>? _peerDepartedChangedSubscription;
  final Map<String, StreamSubscription<DatabaseEvent>> _pairSessionSubs = {};

  bool _listening = false;
  PairedDevice? _incomingInvitePeer;
  ReconnectRequest? _incomingReconnectRequest;
  String? _autoConnectActivePeerId;
  String? _approvingReconnectFromId;
  final Set<String> _consumedReconnectKeys = {};
  final Map<String, Future<TransferSessionController>> _inflight = {};

  bool get _hasActiveListeners =>
      _reconnectValueSubscription != null && _inviteAddedSubscription != null;

  String _reconnectKey(ReconnectRequest request) =>
      '${request.fromDeviceId}_${request.clientCreatedAt}';

  bool _isReconnectConsumed(ReconnectRequest request) =>
      _consumedReconnectKeys.contains(_reconnectKey(request));

  void _markReconnectConsumed(ReconnectRequest request) {
    _consumedReconnectKeys.add(_reconnectKey(request));
  }

  void Function(PairedDevice peer)? openAutoConnectScreen;
  void Function(ReconnectRequest request)? onShowReconnectPrompt;

  /// Çökme sonrası ilk açılışta mevcut davetlerle otomatik ekran açılmasın.
  bool suppressAutoConnectThisLaunch = false;

  PairedDevice? get incomingInvitePeer => _incomingInvitePeer;
  ReconnectRequest? get incomingReconnectRequest => _incomingReconnectRequest;

  bool get isListening => _listening;

  bool isInflightFor(String peerDeviceId) => _inflight.containsKey(peerDeviceId);

  void clearAutoConnectActive() {
    _autoConnectActivePeerId = null;
  }

  void abandonPeerConnection(String peerDeviceId) {
    _autoConnectActivePeerId = null;
    _inflight.remove(peerDeviceId);
    clearIncomingReconnect();
    clearIncomingInvite();
  }

  /// Aynı cihazdan yeniden bağlanma akışı devam ediyor mu?
  bool isReconnectFlowActiveFor(String peerDeviceId) =>
      _approvingReconnectFromId == peerDeviceId ||
      _incomingReconnectRequest?.fromDeviceId == peerDeviceId;

  Future<void> _supersedeExistingSession(String peerDeviceId) async {
    final active = ActiveSessionRegistry.instance.activeController;
    if (active != null &&
        active.peerDeviceId == peerDeviceId &&
        !active.isDisposed) {
      ActiveSessionRegistry.instance.unregister(active);
      active.markSupersededByReconnect();
      await active.disconnect(notifyPeer: false);
    }
    await PairedAutoConnectService.instance.leavePeer(
      peerDeviceId,
      notifyPeer: false,
    );
  }

  Future<void> ensureListening() async {
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      await _registerWithTimeout();
      _registry.startConnectionMonitor();
      _registry.startHeartbeat();

      final myId = await DeviceIdentityService.instance.getDeviceId();
      final firstStart = !_listening;

      if (_listening && _hasActiveListeners) {
        await _processExistingReconnectRequests(myId);
        return;
      }

      await PairedDevicesService.instance.load();
      _listening = true;

      await _attachRealtimeListeners(myId);

      if (firstStart) {
        PairedDevicesService.instance.addListener(_refreshPairSessionWatchers);
        // Çökme sonrası temizlik bitene kadar bekle; aksi halde bayat davetlerle
        // otomatik bağlantı ekranı açılabilir.
        await StartupGate.waitReady();
        if (!suppressAutoConnectThisLaunch) {
          await _processExistingInvites(myId);
          await _processExistingPeerDeparted(myId);
        }
        suppressAutoConnectThisLaunch = false;
      }

      await _processExistingReconnectRequests(myId);
      await _refreshPairSessionWatchers();
    } catch (e) {
      debugPrint('Davet dinleyicisi: $e');
      _listening = false;
      suppressAutoConnectThisLaunch = false;
    }
  }

  /// Ön plana dönünce veya Firebase yeniden bağlanınca bekleyen istekleri okur.
  Future<void> refreshPendingReconnectRequests() async {
    if (!_listening) {
      await ensureListening();
      return;
    }
    final myId = await DeviceIdentityService.instance.getDeviceId();
    await _processExistingReconnectRequests(myId);
  }

  Future<void> _attachRealtimeListeners(String myId) async {
    await _inviteAddedSubscription?.cancel();
    await _inviteChangedSubscription?.cancel();

    final invitesRef = _registry.pairInvitesRef(myId);
    _inviteAddedSubscription = invitesRef.onChildAdded.listen((event) {
      unawaited(_onInviteSnapshot(event.snapshot));
    });
    _inviteChangedSubscription = invitesRef.onChildChanged.listen((event) {
      unawaited(_onInviteSnapshot(event.snapshot));
    });

    // Tek `onValue` dinleyici yeterli: ilk bağlanmada ve her değişiklikte
    // tetiklenir. Ek child dinleyicileri çift işleme yol açıyordu.
    await _reconnectValueSubscription?.cancel();
    final reconnectRef = _registry.reconnectRequestsRef(myId);
    _reconnectValueSubscription = reconnectRef.onValue.listen((event) {
      unawaited(_onReconnectRequestsValue(event.snapshot, myId));
    });

    await _peerDepartedAddedSubscription?.cancel();
    await _peerDepartedChangedSubscription?.cancel();
    final departedRef = _registry.peerDepartedRef(myId);
    _peerDepartedAddedSubscription = departedRef.onChildAdded.listen((event) {
      unawaited(_onPeerDepartedSnapshot(event.snapshot, myId));
    });
    _peerDepartedChangedSubscription =
        departedRef.onChildChanged.listen((event) {
      unawaited(_onPeerDepartedSnapshot(event.snapshot, myId));
    });
  }

  Future<void> _onReconnectRequestsValue(
    DataSnapshot snapshot,
    String myId,
  ) async {
    if (!snapshot.exists || snapshot.value is! Map) return;

    final requests = Map<String, dynamic>.from(snapshot.value as Map);
    for (final fromId in requests.keys) {
      final data = requests[fromId];
      if (data is! Map) continue;
      final map = Map<String, dynamic>.from(data);
      if (!_isFreshReconnectRequest(map)) {
        if (_isExpiredReconnectRequest(map)) {
          await _registry.clearReconnectRequest(
            targetDeviceId: myId,
            fromDeviceId: fromId,
          );
        }
        continue;
      }
      await promptIncomingReconnect(ReconnectRequest.fromMap(fromId, map));
    }
  }

  void stopListening() {
    _listening = false;
    PairedDevicesService.instance.removeListener(_refreshPairSessionWatchers);
    _inviteAddedSubscription?.cancel();
    _inviteChangedSubscription?.cancel();
    _reconnectValueSubscription?.cancel();
    _peerDepartedAddedSubscription?.cancel();
    _peerDepartedChangedSubscription?.cancel();
    for (final sub in _pairSessionSubs.values) {
      sub.cancel();
    }
    _pairSessionSubs.clear();
    _inviteAddedSubscription = null;
    _inviteChangedSubscription = null;
    _reconnectValueSubscription = null;
    _peerDepartedAddedSubscription = null;
    _peerDepartedChangedSubscription = null;
    _incomingInvitePeer = null;
    _incomingReconnectRequest = null;
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
    if (age < -_clockSkewToleranceMs || age > _inviteMaxAge.inMilliseconds) {
      return;
    }

    _incomingInvitePeer = peer;
    notifyListeners();
    await _tryAutoAcceptInvite(peer);
  }

  void clearIncomingInvite() {
    _incomingInvitePeer = null;
    notifyListeners();
  }

  void clearIncomingReconnect() {
    _incomingReconnectRequest = null;
    notifyListeners();
  }

  Future<void> rejectIncomingReconnect() async {
    final request = _incomingReconnectRequest;
    if (request == null) return;
    await rejectReconnectRequest(request);
  }

  Future<void> rejectIncomingReconnectRequest(ReconnectRequest request) async {
    await rejectReconnectRequest(request);
  }

  Future<void> rejectReconnectRequest(ReconnectRequest request) async {
    if (_isReconnectConsumed(request)) return;

    _markReconnectConsumed(request);
    clearIncomingReconnect();

    final myId = await DeviceIdentityService.instance.getDeviceId();
    await _registry.sendReconnectRejection(
      targetDeviceId: request.fromDeviceId,
      fromDeviceId: myId,
      fromDeviceName: DeviceIdentityService.instance.displayName,
    );
    await _registry.clearReconnectRequest(
      targetDeviceId: myId,
      fromDeviceId: request.fromDeviceId,
    );
  }

  /// Onay / ret dokunulduğunda UI hemen kalksın diye.
  void dismissIncomingReconnectUi(ReconnectRequest request) {
    clearIncomingReconnect();
  }

  Future<TransferSessionController?> approveIncomingReconnect() async {
    final request = _incomingReconnectRequest;
    if (request == null) return null;
    return _approveReconnectRequest(request);
  }

  Future<TransferSessionController?> approveReconnectRequest(
    ReconnectRequest request,
  ) async {
    if (_isReconnectConsumed(request) &&
        _approvingReconnectFromId != request.fromDeviceId) {
      return null;
    }
    return _approveReconnectRequest(request);
  }

  Future<TransferSessionController?> _approveReconnectRequest(
    ReconnectRequest request,
  ) async {
    _markReconnectConsumed(request);
    _approvingReconnectFromId = request.fromDeviceId;
    clearIncomingReconnect();

    await PairedDevicesService.instance.load();
    var peer =
        PairedDevicesService.instance.findByDeviceId(request.fromDeviceId);
    peer ??= PairedDevice(
      deviceId: request.fromDeviceId,
      displayName: request.fromDeviceName,
      platform: 'unknown',
      lastConnectedAt: DateTime.now(),
    );
    if (PairedDevicesService.instance.findByDeviceId(request.fromDeviceId) ==
        null) {
      await PairedDevicesService.instance.savePair(
        deviceId: request.fromDeviceId,
        displayName: request.fromDeviceName,
        platform: 'unknown',
      );
    }

    final myId = await DeviceIdentityService.instance.getDeviceId();
    await _registry.clearReconnectRequest(
      targetDeviceId: myId,
      fromDeviceId: request.fromDeviceId,
    );
    await _registry.clearPeerDeparted(
      myDeviceId: myId,
      fromDeviceId: request.fromDeviceId,
    );
    await _supersedeExistingSession(request.fromDeviceId);

    await FirebaseAuthService.instance.requireUid();
    await _registerWithTimeout();
    await _invalidateStaleReconnectState(myId, peer.deviceId);
    await SessionSwitchHelper.prepareForPeer(peer.deviceId);
    await _coordinator.clearSession(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );
    await _registry.clearPairInvitesBetween(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );

    PairedAutoConnectService.instance.setManualSessionActive(true);
    final controller = TransferSessionController();
    try {
      await controller.hostPairInvite(
        peer,
        reconnectClientCreatedAt: request.clientCreatedAt,
      );
      return controller;
    } catch (e) {
      if (!controller.isConnected && !controller.isDisposed) {
        await controller.disconnect();
        controller.dispose();
      }
      rethrow;
    } finally {
      _approvingReconnectFromId = null;
      PairedAutoConnectService.instance.setManualSessionActive(false);
    }
  }

  /// RTDB yeniden bağlanma + uyandırma bildirimi (çift tetiklemeyi birleştirir).
  Future<void> promptIncomingReconnect(ReconnectRequest request) async {
    if (!_isFreshReconnectRequest({
      'clientCreatedAt': request.clientCreatedAt,
    })) {
      return;
    }

    final existing = _incomingReconnectRequest;
    if (existing != null && existing.fromDeviceId == request.fromDeviceId) {
      if (request.clientCreatedAt <= existing.clientCreatedAt) {
        notifyListeners();
        return;
      }
      _consumedReconnectKeys.removeWhere(
        (key) => key.startsWith('${request.fromDeviceId}_'),
      );
    }

    if (_isReconnectConsumed(request)) return;

    _incomingReconnectRequest = request;
    notifyListeners();

    unawaited(_clearStalePeerDepartedFor(request.fromDeviceId));

    if (Platform.isMacOS || Platform.isWindows) {
      final hidden =
          await DesktopBackgroundService.instance.isMainWindowHidden();
      if (hidden) {
        await DesktopOverlayService.instance.showReconnectBanner(request);
        return;
      }
      await DesktopOverlayService.instance.suppressPanelsForVisibleMainWindow();
    }

    final foreground = _isAppInForeground();

    // Mobilde onay yalnızca tam ekran "gelen arama" ekranıyla yapılır (banner'da
    // onay/ret yok). Bu yüzden ön plan/arka plan kontrolüne takılmadan her
    // durumda tam ekranı tetikle; ekran navigator hazır olunca açılır, arka
    // plandaysa öne gelince hemen görünür (20-30 sn gecikme olmaz).
    if (Platform.isIOS || Platform.isAndroid) {
      onShowReconnectPrompt?.call(request);
      return;
    }

    // Ana pencere görünürken uygulama içi onay ekranı (masaüstü).
    if (foreground) {
      onShowReconnectPrompt?.call(request);
      return;
    }

    if (Platform.isMacOS || Platform.isWindows) {
      await DesktopOverlayService.instance.showReconnectBanner(request);
      return;
    }

    // Masaüstünde (FCM yok) arka planda yerel bildirim göster.
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      unawaited(
        NotificationService.instance.showReconnectRequestNotification(request),
      );
    }
  }

  Future<void> _clearStalePeerDepartedFor(String fromDeviceId) async {
    try {
      final myId = await DeviceIdentityService.instance.getDeviceId();
      await _registry.clearPeerDeparted(
        myDeviceId: myId,
        fromDeviceId: fromDeviceId,
      );
    } catch (e) {
      debugPrint('Bayat ayrılma sinyali temizlenemedi: $e');
    }
  }

  bool _isAppInForeground() {
    final state = SchedulerBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
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
    if (suppressAutoConnectThisLaunch) return;
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

  Future<void> _onReconnectRequestSnapshot(DataSnapshot snapshot) async {
    final fromId = snapshot.key;
    if (fromId == null) return;

    final value = snapshot.value;
    if (value is! Map) return;
    final data = Map<String, dynamic>.from(value);
    if (!_isFreshReconnectRequest(data)) return;

    await promptIncomingReconnect(ReconnectRequest.fromMap(fromId, data));
  }

  Future<void> _onPeerDepartedSnapshot(
    DataSnapshot snapshot,
    String myId,
  ) async {
    final fromId = snapshot.key;
    if (fromId == null) return;

    if (isReconnectFlowActiveFor(fromId)) return;

    final value = snapshot.value;
    if (value is! Map) return;
    final data = Map<String, dynamic>.from(value);
    if (!_isFreshPeerDeparted(data)) return;

    final name = data['fromDeviceName'] as String? ?? 'Karşı cihaz';
    await _registry.clearPeerDeparted(myDeviceId: myId, fromDeviceId: fromId);

    await SessionExitHelper.handlePeerDepartedSignal(
      fromDeviceId: fromId,
      fromDeviceName: name,
    );
  }

  Future<void> _processExistingPeerDeparted(String myId) async {
    try {
      final snapshot = await _registry.peerDepartedRef(myId).get();
      if (!snapshot.exists || snapshot.value is! Map) return;

      final departed = Map<String, dynamic>.from(snapshot.value as Map);
      for (final fromId in departed.keys) {
        final data = departed[fromId];
        if (data is! Map) continue;
        if (!_isFreshPeerDeparted(Map<String, dynamic>.from(data))) {
          await _registry.clearPeerDeparted(
            myDeviceId: myId,
            fromDeviceId: fromId,
          );
          continue;
        }
        await _onPeerDepartedSnapshot(snapshot.child(fromId), myId);
        return;
      }
    } catch (e) {
      debugPrint('Mevcut ayrılma sinyalleri okunamadı: $e');
    }
  }

  bool _isFreshPeerDeparted(Map<String, dynamic> data) {
    final clientMs = (data['clientCreatedAt'] as num?)?.toInt();
    if (clientMs == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - clientMs;
    return age >= -_clockSkewToleranceMs &&
        age <= _inviteMaxAge.inMilliseconds;
  }

  Future<void> _processExistingReconnectRequests(String myId) async {
    try {
      final snapshot = await _registry.reconnectRequestsRef(myId).get();
      if (!snapshot.exists || snapshot.value is! Map) return;

      final requests = Map<String, dynamic>.from(snapshot.value as Map);
      for (final fromId in requests.keys) {
        final data = requests[fromId];
        if (data is! Map) continue;
        if (!_isFreshReconnectRequest(Map<String, dynamic>.from(data))) {
          if (_isExpiredReconnectRequest(Map<String, dynamic>.from(data))) {
            await _registry.clearReconnectRequest(
              targetDeviceId: myId,
              fromDeviceId: fromId,
            );
          }
          continue;
        }
        await _onReconnectRequestSnapshot(snapshot.child(fromId));
        return;
      }
    } catch (e) {
      debugPrint('Mevcut yeniden bağlanma istekleri okunamadı: $e');
    }
  }

  bool _isFreshReconnectRequest(Map<String, dynamic> data) {
    final clientMs = (data['clientCreatedAt'] as num?)?.toInt();
    if (clientMs == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - clientMs;
    return age >= -_clockSkewToleranceMs &&
        age <= _inviteMaxAge.inMilliseconds;
  }

  bool _isExpiredReconnectRequest(Map<String, dynamic> data) {
    final clientMs = (data['clientCreatedAt'] as num?)?.toInt();
    if (clientMs == null) return true;
    final age = DateTime.now().millisecondsSinceEpoch - clientMs;
    return age > _inviteMaxAge.inMilliseconds;
  }

  Future<PairedDevice> _resolvePeerForConnect(PairedDevice peer) async {
    final code = peer.inviteCode?.trim();
    if (code != null && code.isNotEmpty) {
      final lookup = await PersistentInviteCodeService.instance.lookup(code);
      if (lookup != null && lookup.deviceId != peer.deviceId) {
        await PairedDevicesService.instance.reconcileDeviceId(
          oldDeviceId: peer.deviceId,
          newDeviceId: lookup.deviceId,
        );
        return peer.copyWith(deviceId: lookup.deviceId);
      }
      if (lookup != null) return peer;
    }

    // Cihaz çevrimdışı görünse bile devam et — wake/FCM bildirimi gönderilir.
    return peer;
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
      return age >= -_clockSkewToleranceMs &&
          age <= _inviteMaxAge.inMilliseconds;
    }
    final serverMs = (data['createdAt'] as num?)?.toInt();
    if (serverMs != null) {
      final age = DateTime.now().millisecondsSinceEpoch - serverMs;
      return age >= -_clockSkewToleranceMs &&
          age <= _inviteMaxAge.inMilliseconds;
    }
    return false;
  }

  String? _roomCodeFromInviteSnapshot(
    DataSnapshot snapshot, {
    int? minCreatedAtMs,
    int? expectedReconnectCreatedAtMs,
  }) {
    if (!snapshot.exists || snapshot.value is! Map) return null;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (data['rejected'] == true) return null;
    if (!_isFreshInvite(data)) return null;
    if (expectedReconnectCreatedAtMs != null) {
      final token = (data['reconnectClientCreatedAt'] as num?)?.toInt();
      if (token != expectedReconnectCreatedAtMs) return null;
    } else if (minCreatedAtMs != null) {
      final created = (data['clientCreatedAt'] as num?)?.toInt();
      if (created == null || created < minCreatedAtMs) return null;
    }
    final roomCode = data['roomCode'] as String?;
    if (roomCode == null || roomCode.isEmpty) return null;
    return roomCode.trim().toUpperCase();
  }

  StateError? _rejectionFromInviteSnapshot(DataSnapshot snapshot) {
    if (!snapshot.exists || snapshot.value is! Map) return null;
    final data = Map<String, dynamic>.from(snapshot.value as Map);
    if (data['rejected'] != true) return null;
    if (!_isFreshInvite(data)) return null;
    final name = data['fromDeviceName'] as String? ?? 'Karşı cihaz';
    return StateError('$name bağlantı isteğinizi reddetti.');
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
    bool skipPrep = false,
    int? minInviteCreatedAtMs,
    int? expectedReconnectCreatedAtMs,
  }) async {
    var controller = TransferSessionController();
    try {
      onProgress?.call('${peer.displayName} davet etti, odaya katılınıyor…');

      final myId = await DeviceIdentityService.instance.getDeviceId();
      // `_connectToPeer` zaten oturum açma/kayıt/temizlik yaptıysa tekrarlama.
      if (!skipPrep) {
        await FirebaseAuthService.instance.ensureSignedIn();
        await _registerWithTimeout();
        await _invalidateStaleReconnectState(myId, peer.deviceId);
      }

      String? roomCode;
      if (minInviteCreatedAtMs == null && expectedReconnectCreatedAtMs == null) {
        roomCode = await _readInviteRoomCode(peer.deviceId);

        final sessionRole = await _coordinator.readRole(
          myDeviceId: myId,
          peerDeviceId: peer.deviceId,
        );
        if (sessionRole != null && !sessionRole.isHost) {
          roomCode = sessionRole.roomCode;
        }
      }

      roomCode ??= await _waitForRoomCodeFromPeer(
        peer.deviceId,
        peerDisplayName: peer.displayName,
        timeout: _reconnectWaitTimeout,
        onProgress: onProgress,
        minInviteCreatedAtMs: minInviteCreatedAtMs,
        expectedReconnectCreatedAtMs: expectedReconnectCreatedAtMs,
      );

      if (roomCode == null) {
        throw StateError(
          '${peer.displayName} ${_reconnectWaitTimeout.inMinutes} dakika içinde '
          'yanıt vermedi. Karşı cihazda bildirime dokunarak uygulamayı açın '
          've tekrar deneyin.',
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

  /// Kalıcı cihaz QR/kodu ile bağlan (ilk eşleşme veya yeniden bağlanma).
  Future<TransferSessionController> connectViaDeviceInvite(
    DeviceInviteLookup lookup, {
    void Function(String message)? onProgress,
  }) async {
    await PairedDevicesService.instance.savePair(
      deviceId: lookup.deviceId,
      displayName: lookup.displayName,
      platform: lookup.platform,
      inviteCode: lookup.inviteCode,
    );
    final peer = PairedDevicesService.instance.findByDeviceId(lookup.deviceId);
    if (peer == null) {
      throw StateError('Cihaz kaydedilemedi.');
    }
    return connectToPeer(peer, onProgress: onProgress);
  }

  /// Listeden dokununca: QR okutmuş gibi — karşı cihaz ev sahibi olur, biz katılırız.
  Future<TransferSessionController> connectToPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    return _withInflight(
      peer.deviceId,
      () => _connectToPeer(peer, onProgress: onProgress),
    );
  }

  Future<bool> _isRoomJoinableQuiet(String roomCode) async {
    try {
      await _signaling.assertRoomJoinable(roomCode);
      return true;
    } on StateError {
      return false;
    }
  }

  /// Kapalı / dolu odaya bağlı eski pairConnect ve davetleri temizler.
  Future<void> _invalidateStaleReconnectState(
    String myId,
    String peerDeviceId,
  ) async {
    final role = await _coordinator.readRole(
      myDeviceId: myId,
      peerDeviceId: peerDeviceId,
    );
    if (role != null && !await _isRoomJoinableQuiet(role.roomCode)) {
      await _coordinator.clearSession(
        myDeviceId: myId,
        peerDeviceId: peerDeviceId,
      );
    }

    final inviteSnapshot = await _registry
        .pairInvitesRef(myId)
        .child(peerDeviceId)
        .get()
        .timeout(const Duration(seconds: 10));
    if (_rejectionFromInviteSnapshot(inviteSnapshot) != null) {
      await _registry
          .pairInvitesRef(myId)
          .child(peerDeviceId)
          .remove();
      return;
    }

    final inviteCode = _roomCodeFromInviteSnapshot(inviteSnapshot);
    if (inviteCode != null && !await _isRoomJoinableQuiet(inviteCode)) {
      await _registry.clearPairInvitesBetween(
        myDeviceId: myId,
        peerDeviceId: peerDeviceId,
      );
    }
  }

  Future<TransferSessionController> _connectToPeer(
    PairedDevice peer, {
    void Function(String message)? onProgress,
  }) async {
    await FirebaseAuthService.instance.ensureSignedIn();
    await _registerWithTimeout();

    peer = await _resolvePeerForConnect(peer);

    final myId = await DeviceIdentityService.instance.getDeviceId();
    final identity = DeviceIdentityService.instance;

    // Red / eski davetleri önce temizle — aksi halde _invalidateStaleReconnectState reddi okuyup durur.
    await _coordinator.clearSession(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );
    await _registry.clearPairInvitesBetween(
      myDeviceId: myId,
      peerDeviceId: peer.deviceId,
    );
    await _invalidateStaleReconnectState(myId, peer.deviceId);

    onProgress?.call(
      '${peer.displayName} cihazına bildirim gönderildi.\n'
      'Karşı cihazın daveti kabul etmesi bekleniyor…',
    );

    final reconnectCreatedAt = await _registry.sendReconnectRequest(
      targetDeviceId: peer.deviceId,
      fromDeviceId: myId,
      fromDeviceName: identity.displayName,
    );

    onProgress?.call(
      'Bildirim iletildi — ${peer.displayName} onayını bekliyor…\n'
      '(en fazla ${_reconnectWaitTimeout.inMinutes} dakika)',
    );

    // Onay sonrası gelen davet, bu isteğin kimliğiyle eşleşmeli (saat farkından etkilenmez).
    return _acceptInviteFromPeer(
      peer,
      onProgress: onProgress,
      skipPrep: true,
      expectedReconnectCreatedAtMs: reconnectCreatedAt,
    );
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
    controller.bindPeer(
      deviceId: peer.deviceId,
      displayName: peer.displayName,
      platform: peer.platform,
    );

    // Controller'ı hemen döndür — UI ListenableBuilder ile bağlantıyı izler.
    // Davet temizliği arka planda bağlantı kurulunca yapılır.
    unawaited(
      _waitUntilConnected(
        controller,
        timeout: const Duration(seconds: 90),
        onProgress: onProgress,
      ).then((session) async {
        if (session == null) return;
        await _registry.removePairInvite(
          targetDeviceId: myId,
          fromDeviceId: peer.deviceId,
        );
        clearIncomingInvite();
      }),
    );

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
        if (attempt == 1 || attempt % 8 == 0) {
          onProgress?.call('Oda açılması bekleniyor ($roomCode)…');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
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
    final rejection = _rejectionFromInviteSnapshot(snapshot);
    if (rejection != null) throw rejection;
    return _roomCodeFromInviteSnapshot(snapshot);
  }

  Future<String?> _waitForRoomCodeFromPeer(
    String peerDeviceId, {
    required String peerDisplayName,
    required Duration timeout,
    void Function(String message)? onProgress,
    int? minInviteCreatedAtMs,
    int? expectedReconnectCreatedAtMs,
  }) async {
    final myId = await DeviceIdentityService.instance.getDeviceId();
    final ref = _registry.pairInvitesRef(myId).child(peerDeviceId);

    final initial = await ref.get().timeout(const Duration(seconds: 10));
    final rejection = _rejectionFromInviteSnapshot(initial);
    if (rejection != null) throw rejection;

    final existingCode = _roomCodeFromInviteSnapshot(
      initial,
      minCreatedAtMs: minInviteCreatedAtMs,
      expectedReconnectCreatedAtMs: expectedReconnectCreatedAtMs,
    );
    if (existingCode != null) return existingCode;

    final completer = Completer<String?>();
    late final StreamSubscription<DatabaseEvent> sub;
    Timer? progressTimer;
    var elapsedSec = 0;

    progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      elapsedSec += 15;
      final remainingSec = timeout.inSeconds - elapsedSec;
      if (remainingSec <= 0) return;
      final min = remainingSec ~/ 60;
      final sec = remainingSec % 60;
      final timeLeft = min > 0 ? '$min:${sec.toString().padLeft(2, '0')}' : '${sec}s';
      onProgress?.call(
        '$peerDisplayName cihazının daveti kabul etmesi bekleniyor… '
        '($timeLeft kaldı)',
      );
    });

    sub = ref.onValue.listen(
      (event) {
        final rejected = _rejectionFromInviteSnapshot(event.snapshot);
        if (rejected != null && !completer.isCompleted) {
          completer.completeError(rejected);
          return;
        }
        final code = _roomCodeFromInviteSnapshot(
          event.snapshot,
          minCreatedAtMs: minInviteCreatedAtMs,
          expectedReconnectCreatedAtMs: expectedReconnectCreatedAtMs,
        );
        if (code != null && !completer.isCompleted) {
          onProgress?.call('$peerDisplayName onayladı. Odaya katılınıyor…');
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
      progressTimer.cancel();
      await sub.cancel();
    }
  }

  Future<TransferSessionController?> _waitUntilConnected(
    TransferSessionController controller, {
    required Duration timeout,
    void Function(String message)? onProgress,
  }) async {
    if (controller.isConnected) return controller;

    final completer = Completer<TransferSessionController?>();
    Timer? timeoutTimer;
    Timer? nudgeTimer;

    void onControllerChanged() {
      if (controller.isConnected && !completer.isCompleted) {
        completer.complete(controller);
      }
    }

    controller.addListener(onControllerChanged);

    nudgeTimer = Timer(const Duration(seconds: 8), () {
      if (controller.isConnected || controller.isDisposed) return;
      onProgress?.call('Bağlantı gecikti, yeniden deneniyor…');
      unawaited(controller.reconnectIfNeeded());
    });

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(controller.isConnected ? controller : null);
      }
    });

    try {
      if (controller.isConnected) return controller;
      return await completer.future;
    } finally {
      controller.removeListener(onControllerChanged);
      timeoutTimer.cancel();
      nudgeTimer.cancel();
    }
  }
}
