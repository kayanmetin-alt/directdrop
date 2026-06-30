import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/device_presence.dart';
import '../models/paired_device.dart';
import '../models/room.dart';
import '../models/signaling_message.dart';
import '../models/transfer_file.dart';
import '../models/transfer_restore_state.dart';
import '../utils/photo_export_compatibility.dart';
import '../utils/room_code_generator.dart';
import '../services/photo_export_service.dart';
import '../services/device_identity_service.dart';
import '../services/device_registry_service.dart';
import '../services/file_transfer_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_signaling_service.dart';
import '../services/pair_connect_coordinator.dart';
import '../services/paired_devices_service.dart';
import '../services/pairings_registry_service.dart';
import '../services/mobile_transfer_keepalive_service.dart';
import '../services/desktop_background_service.dart';
import '../services/desktop_overlay_service.dart';
import '../services/screen_wake_service.dart';
import '../services/transfer_history_service.dart';
import '../services/transfer_checkpoint_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/media_prepare_overlay.dart';

class TransferSessionController extends ChangeNotifier {
  TransferSessionController({
    FirebaseSignalingService? signaling,
    DeviceRegistryService? deviceRegistry,
  })  : _signaling = signaling ?? FirebaseSignalingService(),
        _deviceRegistry = deviceRegistry ?? DeviceRegistryService();

  static const _uuid = Uuid();

  final FirebaseSignalingService _signaling;
  final DeviceRegistryService _deviceRegistry;
  WebRtcService? _webRtc;
  FileTransferService? _fileTransfer;

  RoomSession? _session;
  WebRtcConnectionState _connectionState = WebRtcConnectionState.idle;
  String? _errorMessage;
  bool _busy = false;
  bool _disposed = false;
  bool _disconnecting = false;
  bool _reconnecting = false;
  bool _peerHasLeft = false;
  bool _userInitiatedLeave = false;
  bool _hadSuccessfulConnection = false;
  bool _pairSaved = false;
  bool _wasBackgrounded = false;
  bool _supersededByReconnect = false;

  bool get supersededByReconnect => _supersededByReconnect;

  /// Yeniden bağlanma akışı başladığında eski oturum ekranının ana sayfaya
  /// dönmesini engellemek için işaretlenir.
  void markSupersededByReconnect() {
    _supersededByReconnect = true;
    _userInitiatedLeave = true;
  }
  int _guestWaitGeneration = 0;
  int _connectionWatchGeneration = 0;
  DateTime? _lastReconnectAt;
  Timer? _deferredReconnectTimer;
  Timer? _connectionWatchTimer;
  Timer? _peerOfflineDebounce;
  StreamSubscription<WebRtcConnectionState>? _connectionSubscription;
  StreamSubscription<List<TransferFileItem>>? _transferSubscription;
  StreamSubscription<DevicePresence>? _peerPresenceSubscription;

  String? peerDeviceId;
  String? peerDisplayName;
  String? peerPlatform;
  final Set<String> _persistedTransferIds = {};
  final Set<String> _notifiedIncomingIds = {};
  Timer? _checkpointDebounce;
  bool _checkpointWriteScheduled = false;
  bool _diskRestoreAttempted = false;

  RoomSession? get session => _session;
  WebRtcConnectionState get connectionState => _connectionState;
  String? get errorMessage => _errorMessage;
  bool get isBusy => _busy;
  bool get isReconnecting => _reconnecting;
  bool get peerHasLeft => _peerHasLeft;
  bool get userInitiatedLeave => _userInitiatedLeave;
  bool get hadSuccessfulConnection => _hadSuccessfulConnection;
  bool get isBackgrounded => _wasBackgrounded;
  bool get isDisposed => _disposed;
  bool get isConnected {
    if (_connectionState == WebRtcConnectionState.disconnected ||
        _connectionState == WebRtcConnectionState.failed) {
      return false;
    }
    return _connectionState == WebRtcConnectionState.connected ||
        (_webRtc?.isDataChannelOpen ?? false);
  }

  bool get canTransferFiles =>
      isConnected &&
      !_reconnecting &&
      !_peerHasLeft &&
      !_userInitiatedLeave &&
      _fileTransfer != null;
  bool get isDataChannelReady => _webRtc?.isDataChannelOpen ?? false;
  bool get isPaired => _session?.remotePeerId != null;
  FileTransferService? get fileTransfer => _fileTransfer;

  void bindPeer({
    required String deviceId,
    required String displayName,
    String? platform,
  }) {
    peerDeviceId = deviceId;
    peerDisplayName = displayName;
    if (platform != null && platform.isNotEmpty && platform != 'unknown') {
      peerPlatform = platform;
    }
    if (_session != null && !_disposed) {
      unawaited(_armPeerDepartureSignals());
    }
  }

  Future<bool> shouldPreferJpegForPhotos() async {
    final peer = await resolvePeerPlatform();
    return PhotoExportCompatibility.prefersJpeg(
      localPlatform: DeviceIdentityService.instance.platformLabel,
      peerPlatform: peer,
    );
  }

  Future<String?> resolvePeerPlatform() async {
    if (peerPlatform != null &&
        peerPlatform!.isNotEmpty &&
        peerPlatform != 'unknown') {
      return peerPlatform;
    }

    await _ensurePeerInfo();

    if (peerDeviceId != null) {
      await PairedDevicesService.instance.load();
      final paired =
          PairedDevicesService.instance.findByDeviceId(peerDeviceId!);
      if (paired != null &&
          paired.platform.isNotEmpty &&
          paired.platform != 'unknown') {
        peerPlatform = paired.platform;
        return peerPlatform;
      }

      final device = await _deviceRegistry.readPresence(peerDeviceId!);
      final registryPlatform = device?['platform'] as String?;
      if (registryPlatform != null &&
          registryPlatform.isNotEmpty &&
          registryPlatform != 'unknown') {
        peerPlatform = registryPlatform;
        return peerPlatform;
      }
    }

    final session = _session;
    if (session != null) {
      final roomPlatform = session.role == PeerRole.host
          ? await _signaling.getGuestDevicePlatform(session.roomCode)
          : await _signaling.getHostDevicePlatform(session.roomCode);
      if (roomPlatform != null &&
          roomPlatform.isNotEmpty &&
          roomPlatform != 'unknown') {
        peerPlatform = roomPlatform;
        return peerPlatform;
      }
    }

    peerPlatform = _guessPeerPlatform(peerDisplayName);
    return peerPlatform;
  }

  Future<void> acceptIncomingFile(String fileId) async {
    await _fileTransfer?.acceptIncoming(fileId);
  }

  Future<void> rejectIncomingFile(String fileId) async {
    await _fileTransfer?.rejectIncoming(fileId);
  }

  Future<void> acceptAllIncomingFiles() async {
    await _fileTransfer?.acceptAllIncoming();
    notifyListeners();
  }

  Future<void> rejectAllIncomingFiles() async {
    await _fileTransfer?.rejectAllIncoming();
    notifyListeners();
  }

  Future<void> togglePauseTransfer(String fileId) async {
    final transfer = _fileTransfer;
    if (transfer == null) return;

    TransferFileItem? item;
    for (final entry in transfer.items) {
      if (entry.id == fileId) {
        item = entry;
        break;
      }
    }
    if (item == null) return;

    if (item.status == TransferStatus.paused) {
      await transfer.resumeTransfer(fileId);
    } else if (item.status == TransferStatus.inProgress) {
      await transfer.pauseTransfer(fileId);
    }
  }

  Future<void> cancelTransfer(String fileId) async {
    await _fileTransfer?.cancelTransfer(fileId);
    // Yarım dosya silindi; kalıcı checkpoint'i de hemen kaldır ki uygulama
    // hemen kapansa bile bu transfer bir daha "devam ettirilebilir" görünmesin.
    await TransferCheckpointService.instance.remove(fileId);
  }

  List<TransferFileItem> get awaitingApprovalFiles =>
      _fileTransfer?.awaitingApprovalItems ?? const [];

  String get deviceName => DeviceIdentityService.instance.displayName;

  void _syncScreenWake() {
    final items = _fileTransfer?.items ?? const [];
    final transferActive = ScreenWakeService.hasActiveTransferWork(items);
    unawaited(ScreenWakeService.instance.setTransferActive(transferActive));
    // Mobil keep-alive (Android foreground service / iOS background task) yalnızca
    // gerçek transfer işi (aktif/duraklatılmış/sıradaki) varken tutulur. Boşta
    // bağlı bir oturum pil tüketmemeli; yeni istek FCM ile uyandırır.
    final roomActive = _session != null && !_disposed;
    unawaited(
      MobileTransferKeepAliveService.setSessionActive(
        transferActive && roomActive && isPaired,
      ),
    );
  }

  static Duration get _peerOfflineGracePeriod {
    if (Platform.isAndroid || Platform.isIOS) {
      return const Duration(seconds: 45);
    }
    return const Duration(seconds: 12);
  }

  Future<String> _persistentDeviceId() =>
      DeviceIdentityService.instance.getDeviceId();

  Future<RoomSession> createRoom() async {
    _setBusy(true);
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      final peerId = _uuid.v4();
      final roomCode = RoomCodeGenerator.generate();
      final persistentId = await _persistentDeviceId();
      await _signaling.createRoom(
        roomCode: roomCode,
        hostPeerId: peerId,
        deviceName: deviceName,
        devicePlatform: DeviceIdentityService.instance.platformLabel,
        persistentDeviceId: persistentId,
      );

      _session = RoomSession(
        roomCode: roomCode,
        peerId: peerId,
        role: PeerRole.host,
        deviceName: deviceName,
      );

      await _beginSignaling(roomCode: roomCode, localPeerId: peerId);

      _syncScreenWake();
      _waitForGuest(roomCode, peerId);
      notifyListeners();
      return _session!;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _waitForGuest(String roomCode, String hostPeerId) async {
    final waitGeneration = ++_guestWaitGeneration;

    // Misafir zaten katılmış olabilir; önce bir kez kontrol et.
    final existingGuest = await _signaling.getGuestPeerId(roomCode);
    if (_disposed || waitGeneration != _guestWaitGeneration) return;
    if (existingGuest != null) {
      await _onGuestJoined(existingGuest, hostPeerId, waitGeneration);
      return;
    }

    // Olay tabanlı: misafir katılır katılmaz tetiklenir (polling yok).
    final completer = Completer<String?>();
    final sub = _signaling.watchGuestPeerId(roomCode, (guestPeerId) {
      if (!completer.isCompleted) completer.complete(guestPeerId);
    });

    String? guestPeerId;
    try {
      guestPeerId = await completer.future
          .timeout(const Duration(seconds: 90), onTimeout: () => null);
    } finally {
      await sub.cancel();
    }

    if (_disposed || waitGeneration != _guestWaitGeneration) return;

    if (guestPeerId == null) {
      debugPrint('Misafir katılımı zaman aşımına uğradı.');
      _errorMessage = 'Karşı cihaz katılmadı.';
      if (!_disposed) notifyListeners();
      return;
    }

    await _onGuestJoined(guestPeerId, hostPeerId, waitGeneration);
  }

  Future<void> _onGuestJoined(
    String guestPeerId,
    String hostPeerId,
    int waitGeneration,
  ) async {
    if (_disposed ||
        waitGeneration != _guestWaitGeneration ||
        _session == null ||
        _webRtc != null) {
      return;
    }
    _session = _session!.copyWith(remotePeerId: guestPeerId);
    await _startWebRtc(remotePeerId: guestPeerId, isInitiator: true);
    await _signaling.replayPendingMessages(
      localPeerId: hostPeerId,
      onMessage: _onSignalingMessage,
    );
    _scheduleConnectionWatch();
    unawaited(_persistPairIfNeeded());
    _syncScreenWake();
    notifyListeners();
  }

  Future<RoomSession> joinRoom(String roomCode) async {
    _setBusy(true);
    try {
      await FirebaseAuthService.instance.ensureSignedIn();
      await FirebaseAuthService.instance.requireUid();
      final normalizedCode = roomCode.trim().toUpperCase();
      final peerId = _uuid.v4();
      final persistentId = await _persistentDeviceId();
      await _signaling.joinRoom(
        roomCode: normalizedCode,
        guestPeerId: peerId,
        deviceName: deviceName,
        devicePlatform: DeviceIdentityService.instance.platformLabel,
        persistentDeviceId: persistentId,
      );

      final hostPeerId = await _signaling.getHostPeerId(normalizedCode);
      if (hostPeerId == null) {
        throw StateError('Oda sahibi bulunamadı.');
      }

      _session = RoomSession(
        roomCode: normalizedCode,
        peerId: peerId,
        role: PeerRole.guest,
        remotePeerId: hostPeerId,
        deviceName: deviceName,
      );

      await _beginSignaling(roomCode: normalizedCode, localPeerId: peerId);

      await _startWebRtc(
        remotePeerId: hostPeerId,
        isInitiator: false,
      );

      await _signaling.replayPendingMessages(
        localPeerId: peerId,
        onMessage: _onSignalingMessage,
      );
      _scheduleConnectionWatch();

      unawaited(_persistPairIfNeeded());
      _syncScreenWake();
      notifyListeners();
      return _session!;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// Uygulama açıkken eşleşmiş cihaza doğrudan davet gönderir (wake yerine).
  Future<RoomSession> hostPairInvite(
    PairedDevice peer, {
    String? roomCode,
    int? reconnectClientCreatedAt,
  }) async {
    _setBusy(true);
    try {
      bindPeer(
        deviceId: peer.deviceId,
        displayName: peer.displayName,
        platform: peer.platform,
      );
      final peerId = _uuid.v4();
      final resolvedRoomCode = roomCode ?? RoomCodeGenerator.generate();
      final persistentId = await _persistentDeviceId();

      await _deviceRegistry.clearPairInvitesBetween(
        myDeviceId: persistentId,
        peerDeviceId: peer.deviceId,
      );

      final actualRoomCode = await _signaling.createRoom(
        roomCode: resolvedRoomCode,
        hostPeerId: peerId,
        deviceName: deviceName,
        devicePlatform: DeviceIdentityService.instance.platformLabel,
        persistentDeviceId: persistentId,
      );
      await FirebaseAuthService.instance.requireUid();

      _session = RoomSession(
        roomCode: actualRoomCode,
        peerId: peerId,
        role: PeerRole.host,
        deviceName: deviceName,
      );

      await _beginSignaling(roomCode: actualRoomCode, localPeerId: peerId);

      await _deviceRegistry.sendPairInvite(
        targetDeviceId: peer.deviceId,
        fromDeviceId: persistentId,
        fromDeviceName: deviceName,
        roomCode: actualRoomCode,
        reconnectClientCreatedAt: reconnectClientCreatedAt,
      );

      await _armPeerDepartureSignals();
      _waitForGuest(actualRoomCode, peerId);
      _syncScreenWake();
      notifyListeners();
      return _session!;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<RoomSession> joinFromWake(WakeRequest request) =>
      joinRoom(request.roomCode);

  Future<void> _beginSignaling({
    required String roomCode,
    required String localPeerId,
  }) async {
    _signaling.listenForMessages(
      roomCode: roomCode,
      localPeerId: localPeerId,
      onMessage: _onSignalingMessage,
    );
    _signaling.listenForRoomClosed(
      roomCode: roomCode,
      onClosed: _markPeerHasLeft,
    );
    await _signaling.replayPendingMessages(
      localPeerId: localPeerId,
      onMessage: _onSignalingMessage,
    );
  }

  void _markPeerHasLeft() {
    if (_peerHasLeft || _disposed) return;
    _peerHasLeft = true;
    _deferredReconnectTimer?.cancel();
    _connectionWatchTimer?.cancel();
    _reconnecting = false;
    _connectionState = WebRtcConnectionState.disconnected;
    notifyListeners();
  }

  void _scheduleConnectionWatch() {
    _connectionWatchTimer?.cancel();
    final generation = ++_connectionWatchGeneration;
    // İlk bağlantı için ICE/TURN'e zaman tanı (relay yavaş olabilir). Re-offer
    // mekanizması ~9 sn sürer; 15 sn'de hâlâ bağlanmadıysa tazelemeyi dene.
    _connectionWatchTimer = Timer(const Duration(seconds: 15), () {
      unawaited(_onConnectionWatchTimeout(generation, attempt: 1));
    });
  }

  /// Bağlantı zaman aşımında tek seferde "başarısız" demek yerine, sınırlı
  /// sayıda yeniden deneyip her denemeye oturması için süre tanır. Böylece
  /// guest tarafı erken "bağlanılamadı" ekranına düşmez ve host ile karşılıklı
  /// yeniden bağlanma fırtınası oluşmaz.
  Future<void> _onConnectionWatchTimeout(
    int generation, {
    required int attempt,
  }) async {
    if (_disposed || generation != _connectionWatchGeneration) return;
    if (isConnected) return;
    if (_peerHasLeft || _userInitiatedLeave) return;

    // Karşı cihaz gerçekten çevrimdışıysa beklemeden ayrıldı say.
    if (await _isPeerOffline()) {
      if (_disposed || generation != _connectionWatchGeneration) return;
      _markPeerHasLeft();
      return;
    }

    const maxAttempts = 4;
    debugPrint(
      'WebRTC bağlantı zaman aşımı (deneme $attempt/$maxAttempts) — tazeleniyor.',
    );
    await reconnectIfNeeded(force: true);

    // Yeniden bağlanmanın oturmasını bekle (offer/answer + ICE ~ birkaç sn).
    for (var i = 0; i < 80; i++) {
      if (_disposed || generation != _connectionWatchGeneration) return;
      if (isConnected) return;
      if (_peerHasLeft || _userInitiatedLeave) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    if (_disposed || generation != _connectionWatchGeneration) return;
    if (isConnected) return;
    if (_peerHasLeft || _userInitiatedLeave) return;

    if (attempt < maxAttempts) {
      unawaited(_onConnectionWatchTimeout(generation, attempt: attempt + 1));
      return;
    }

    _errorMessage =
        'Karşı cihazla bağlantı kurulamadı. Her iki tarafta uygulama açık mı kontrol edin.';
    _connectionState = WebRtcConnectionState.failed;
    notifyListeners();
  }

  Future<void> _persistPairIfNeeded() async {
    if (_pairSaved || _session == null || _disposed) return;

    final session = _session!;
    final myId = await _persistentDeviceId();
    String? remoteId;
    String? remoteName;
    String? remotePlatform;

    if (session.role == PeerRole.host) {
      remoteId = await _signaling.getGuestPersistentId(session.roomCode);
      remoteName = await _signaling.getGuestDeviceName(session.roomCode);
      remotePlatform =
          await _signaling.getGuestDevicePlatform(session.roomCode);
    } else {
      remoteId = await _signaling.getHostPersistentId(session.roomCode);
      remoteName = await _signaling.getHostDeviceName(session.roomCode);
      remotePlatform =
          await _signaling.getHostDevicePlatform(session.roomCode);
    }

    if (remoteId == null || remoteId.isEmpty || remoteId == myId) return;

    final platform = (remotePlatform != null &&
            remotePlatform.isNotEmpty &&
            remotePlatform != 'unknown')
        ? remotePlatform
        : _guessPeerPlatform(remoteName);

    await PairedDevicesService.instance.savePair(
      deviceId: remoteId,
      displayName: remoteName ?? 'Cihaz',
      platform: platform,
    );
    await PairingsRegistryService.instance.ensurePeerForReconnect(remoteId);
    _pairSaved = true;
  }

  String _guessPeerPlatform(String? displayName) {
    final name = (displayName ?? '').toLowerCase();
    if (name.contains('android')) return 'android';
    if (name.contains('mac')) return 'macos';
    if (name.contains('windows') || name.contains('pc')) return 'windows';
    if (name.contains('iphone') || name.contains('ipad') || name.contains('ios')) {
      return 'ios';
    }
    return 'unknown';
  }

  Future<void> _startWebRtc({
    required String remotePeerId,
    required bool isInitiator,
    TransferRestoreState? transferRestore,
  }) async {
    final session = _session!;
    _webRtc = WebRtcService(
      signaling: _signaling,
      localPeerId: session.peerId,
      remotePeerId: remotePeerId,
      isInitiator: isInitiator,
    );

    await _connectionSubscription?.cancel();
    _connectionSubscription = _webRtc!.connectionState.listen(_onConnectionStateChanged);

    await _webRtc!.initialize();
    _fileTransfer = transferRestore != null
        ? FileTransferService.restore(
            webRtc: _webRtc!,
            state: transferRestore,
          )
        : FileTransferService(webRtc: _webRtc!);
    await _transferSubscription?.cancel();
    _attachFileTransferListener();
  }

  void _attachFileTransferListener() {
    _transferSubscription = _fileTransfer!.transfers.listen((items) {
      if (!_disposed) notifyListeners();
      _syncScreenWake();
      unawaited(_persistCompletedTransfers(items));
      unawaited(_notifyIncomingFilesIfHidden(items));
      unawaited(_syncDesktopOverlay(items));
      _scheduleCheckpointPersist(items);
    });
  }

  // Aktif transfer sırasında _emit() çok sık çağrıldığından debounce yerine
  // throttle kullanıyoruz: en fazla ~2 saniyede bir yaz, ama düzenli olarak yaz
  // (böylece ani kapanmada güncel ilerleme diskte olur).
  void _scheduleCheckpointPersist(List<TransferFileItem> items) {
    if (_checkpointWriteScheduled) return;
    _checkpointWriteScheduled = true;
    _checkpointDebounce = Timer(const Duration(seconds: 2), () {
      _checkpointWriteScheduled = false;
      final current = _fileTransfer?.currentItems ?? items;
      unawaited(_persistTransferCheckpoints(current));
    });
  }

  Future<void> flushTransferCheckpoints() async {
    _checkpointDebounce?.cancel();
    _checkpointDebounce = null;
    _checkpointWriteScheduled = false;
    final items = _fileTransfer?.currentItems;
    if (items == null || items.isEmpty) return;
    await _persistTransferCheckpoints(items);
  }

  Future<void> _persistTransferCheckpoints(List<TransferFileItem> items) async {
    if (_disposed || _userInitiatedLeave) return;
    await _ensurePeerInfo();
    final peerId = peerDeviceId;
    final peerName = peerDisplayName ?? 'Cihaz';
    if (peerId == null) return;

    for (final item in items) {
      if (item.status == TransferStatus.completed ||
          item.status == TransferStatus.cancelled) {
        await TransferCheckpointService.instance.remove(item.id);
      }
    }

    await TransferCheckpointService.instance.syncSession(
      peerDeviceId: peerId,
      peerDisplayName: peerName,
      items: items,
    );
  }

  /// Bağlantı kurulunca diskteki yarım transferleri otomatik geri yükler.
  /// Hangi ekrandan bağlanıldığından bağımsız çalışır (her iki cihazda da).
  void _scheduleDiskRestore() {
    if (_diskRestoreAttempted || _disposed) return;
    unawaited(_runDiskRestoreWhenReady());
  }

  Future<void> _runDiskRestoreWhenReady() async {
    // Veri kanalı açılana kadar bekle.
    for (var i = 0; i < 150; i++) {
      if (_disposed) return;
      if (isDataChannelReady) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_disposed || !isDataChannelReady) return;

    // peerDeviceId çözülene kadar bekle; aksi halde hangi checkpoint'lerin
    // geri yükleneceğini bilemeyiz.
    for (var i = 0; i < 50; i++) {
      if (_disposed) return;
      await _ensurePeerInfo();
      if (peerDeviceId != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await maybeRestoreFromDisk();
  }

  /// Uygulama yeniden açıldıktan sonra diskteki yarım transferleri belleğe yükler.
  Future<void> maybeRestoreFromDisk() async {
    if (_diskRestoreAttempted || _disposed || _webRtc == null || !isConnected) {
      return;
    }

    final currentItems = _fileTransfer?.currentItems ?? [];
    final hasResumableInMemory = currentItems.any(
      (item) =>
          item.bytesTransferred > 0 &&
          item.bytesTransferred < item.size &&
          item.status != TransferStatus.completed &&
          item.status != TransferStatus.cancelled,
    );
    if (hasResumableInMemory) {
      _diskRestoreAttempted = true;
      return;
    }

    await _ensurePeerInfo();
    final peerId = peerDeviceId;
    // peerId henüz çözülmediyse bayrağı set etme; sonraki bağlantı denemesinde
    // (ya da çağrıda) tekrar denenebilsin.
    if (peerId == null) return;

    _diskRestoreAttempted = true;

    final state =
        await TransferCheckpointService.instance.buildRestoreState(peerId);
    if (state == null || state.items.isEmpty) return;

    await applyDiskRestore(state);
  }

  Future<void> applyDiskRestore(TransferRestoreState state) async {
    if (_disposed || _webRtc == null || !isConnected) return;

    await _transferSubscription?.cancel();
    await _fileTransfer?.dispose();
    _fileTransfer = FileTransferService.restore(
      webRtc: _webRtc!,
      state: state,
    );
    _attachFileTransferListener();
    // Diskten geri yükleme: transferleri otomatik başlatma; "duraklatıldı"
    // olarak göster, kullanıcı Play'e basınca devam etsin.
    await _fileTransfer!.resumeAfterReconnect(autoResume: false);
    if (!_disposed) notifyListeners();
  }

  /// Masaüstünde pencere menü çubuğuna gizlenmişken yeni gelen dosya teklifleri
  /// için banner veya bildirim gösterir.
  Future<void> _notifyIncomingFilesIfHidden(
    List<TransferFileItem> items,
  ) async {
    if (!DesktopBackgroundService.isSupported) return;
    if (!DesktopBackgroundService.instance.keepsRunningInBackground) return;

    final pendingIncoming = items
        .where((i) =>
            i.direction == TransferDirection.receiving &&
            i.status == TransferStatus.awaitingApproval)
        .toList();

    final newOnes = pendingIncoming
        .where((i) => !_notifiedIncomingIds.contains(i.id))
        .toList();
    if (newOnes.isEmpty) return;

    final hidden = await DesktopBackgroundService.instance.isMainWindowHidden();
    if (!hidden) return;

    for (final i in newOnes) {
      _notifiedIncomingIds.add(i.id);
    }

    await DesktopOverlayService.instance.showIncomingFilesBanner(
      peerName: peerDisplayName ?? 'Cihaz',
      files: pendingIncoming,
    );
  }

  Future<void> _syncDesktopOverlay(List<TransferFileItem> items) async {
    if (!DesktopOverlayService.isSupported) return;
    if (!await DesktopBackgroundService.instance.isMainWindowHidden()) return;

    final overlay = DesktopOverlayService.instance;
    final hasAwaiting = items.any(
      (i) =>
          i.direction == TransferDirection.receiving &&
          i.status == TransferStatus.awaitingApproval,
    );
    if (!hasAwaiting && !overlay.isOverlayActive) return;

    await overlay.onTransferItemsChanged(items);
  }

  Future<void> _persistCompletedTransfers(List<TransferFileItem> items) async {
    await _ensurePeerInfo();
    final peerId = peerDeviceId;
    final peerName = peerDisplayName ?? 'Cihaz';
    if (peerId == null) return;

    for (final item in items) {
      if (!_isTerminalStatus(item.status)) continue;
      if (_persistedTransferIds.contains(item.id)) continue;
      _persistedTransferIds.add(item.id);
      await TransferHistoryService.instance.addFromTransfer(
        item: item,
        peerDeviceId: peerId,
        peerName: peerName,
      );
    }
  }

  bool _isTerminalStatus(TransferStatus status) {
    return status == TransferStatus.completed ||
        status == TransferStatus.failed ||
        status == TransferStatus.cancelled;
  }

  Future<void> _ensurePeerInfo() async {
    if (peerDeviceId != null) return;
    if (_session == null) return;

    final myId = await _persistentDeviceId();
    String? remoteId;
    String? remoteName;

    if (_session!.role == PeerRole.host) {
      remoteId = await _signaling.getGuestPersistentId(_session!.roomCode);
      remoteName = await _signaling.getGuestDeviceName(_session!.roomCode);
    } else {
      remoteId = await _signaling.getHostPersistentId(_session!.roomCode);
      remoteName = await _signaling.getHostDeviceName(_session!.roomCode);
    }

    if (remoteId == null || remoteId.isEmpty || remoteId == myId) return;

    peerDeviceId = remoteId;
    peerDisplayName = remoteName ?? 'Cihaz';
    if (peerPlatform == null || peerPlatform == 'unknown') {
      final roomPlatform = _session!.role == PeerRole.host
          ? await _signaling.getGuestDevicePlatform(_session!.roomCode)
          : await _signaling.getHostDevicePlatform(_session!.roomCode);
      if (roomPlatform != null &&
          roomPlatform.isNotEmpty &&
          roomPlatform != 'unknown') {
        peerPlatform = roomPlatform;
      }
    }
    await _armPeerDepartureSignals();
    if (!_disposed) notifyListeners();
  }

  /// Kalıcı cihaz kimliğini (transfer geçmişi filtrelemesi için) çözümler.
  Future<void> ensurePeerDeviceResolved() => _ensurePeerInfo();

  void markBackgrounded() {
    _wasBackgrounded = true;
    _fileTransfer?.prepareForBackgroundInterrupt();
    unawaited(_prepareForBackground());
    unawaited(flushTransferCheckpoints());
    unawaited(MobileTransferKeepAliveService.setBackgroundKeepalive(true));
  }

  Future<void> _prepareForBackground() async {
    if (!isPaired || _peerHasLeft || _userInitiatedLeave || _disposed) return;

    try {
      await _deviceRegistry.suspendBackgroundDisconnectHandlers();
      final peerId = peerDeviceId;
      if (peerId != null) {
        final myId = await _persistentDeviceId();
        await _deviceRegistry.cancelPeerDepartedOnDisconnect(
          targetDeviceId: peerId,
          fromDeviceId: myId,
        );
      }
    } catch (e) {
      debugPrint('Arka plan hazırlığı: $e');
    }
  }

  void onAppResumed() {
    if (!_wasBackgrounded) return;
    _wasBackgrounded = false;
    unawaited(MobileTransferKeepAliveService.setBackgroundKeepalive(false));
    unawaited(_restoreFromBackground());
  }

  Future<void> _restoreFromBackground() async {
    if (_disposed || _peerHasLeft || _userInitiatedLeave) return;

    try {
      await _deviceRegistry.restoreBackgroundDisconnectHandlers();
      if (isPaired) {
        await _armPeerDepartureSignals();
      }
    } catch (e) {
      debugPrint('Ön plana dönüş: $e');
    }

    if (_hadSuccessfulConnection &&
        !isConnected &&
        !_reconnecting &&
        (_connectionState == WebRtcConnectionState.disconnected ||
            _connectionState == WebRtcConnectionState.failed)) {
      unawaited(reconnectIfNeeded(force: true));
    }

    _deferredReconnectTimer?.cancel();
    _deferredReconnectTimer = Timer(const Duration(seconds: 2), () {
      unawaited(reconnectIfNeeded());
    });
  }

  void _onConnectionStateChanged(WebRtcConnectionState state) {
    _connectionState = state;

    // Masaüstü menü çubuğu ikonu: bağlıyken renkli, değilken monokrom.
    unawaited(
      DesktopBackgroundService.instance
          .setConnectionActive(state == WebRtcConnectionState.connected),
    );

    if (state == WebRtcConnectionState.connected) {
      _hadSuccessfulConnection = true;
      _connectionWatchTimer?.cancel();
      _deferredReconnectTimer?.cancel();
      unawaited(_persistPairIfNeeded());
      _scheduleDiskRestore();
    } else if (!_peerHasLeft &&
        (state == WebRtcConnectionState.disconnected ||
            state == WebRtcConnectionState.failed)) {
      if (_wasBackgrounded) {
        // iOS arka planda WebRTC askıya alınır; oturumu sonlandırma.
        _connectionState = WebRtcConnectionState.disconnected;
        if (!_disposed) notifyListeners();
        return;
      }
      _scheduleDeferredReconnect();
    }

    if (!_disposed) notifyListeners();
  }

  void _scheduleDeferredReconnect() {
    if (_userInitiatedLeave ||
        _peerHasLeft ||
        _reconnecting ||
        _wasBackgrounded) {
      return;
    }

    unawaited(_scheduleDeferredReconnectAfterPeerCheck());
  }

  Future<void> _scheduleDeferredReconnectAfterPeerCheck() async {
    if (_userInitiatedLeave || _peerHasLeft || _reconnecting || _wasBackgrounded) {
      return;
    }
    if (await _isPeerOffline()) {
      _markPeerHasLeft();
      return;
    }

    _deferredReconnectTimer?.cancel();
    final delay = _hadSuccessfulConnection
        ? const Duration(seconds: 12)
        : const Duration(seconds: 4);
    _deferredReconnectTimer = Timer(delay, () {
      unawaited(reconnectIfNeeded());
    });
  }

  Future<bool> _isPeerOffline() async {
    final peerId = peerDeviceId;
    if (peerId == null) return false;
    try {
      final data = await _deviceRegistry.readPresence(peerId);
      if (data == null) return false;
      return data['online'] != true;
    } catch (e) {
      debugPrint('Karşı cihaz durumu okunamadı: $e');
      return false;
    }
  }

  Future<void> _armPeerDepartureSignals() async {
    if (_disposed || _session == null) return;
    final peerId = peerDeviceId;
    if (peerId == null) return;

    final myId = await _persistentDeviceId();
    try {
      await _deviceRegistry.registerPeerDepartedOnDisconnect(
        targetDeviceId: peerId,
        fromDeviceId: myId,
        fromDeviceName: deviceName,
      );
    } catch (e) {
      debugPrint('peerDeparted onDisconnect kaydı başarısız: $e');
    }

    await _peerPresenceSubscription?.cancel();
    _peerPresenceSubscription =
        _deviceRegistry.watchPresence(peerId).listen(_onPeerPresenceChanged);
  }

  void _onPeerPresenceChanged(DevicePresence presence) {
    if (_peerHasLeft || _userInitiatedLeave || _disposed || _wasBackgrounded) {
      return;
    }
    if (presence.online) {
      _peerOfflineDebounce?.cancel();
      _peerOfflineDebounce = null;
      return;
    }

    _peerOfflineDebounce ??= Timer(_peerOfflineGracePeriod, () {
      _peerOfflineDebounce = null;
      if (!_peerHasLeft && !_userInitiatedLeave && !_disposed) {
        _markPeerHasLeft();
      }
    });
  }

  Future<void> _disarmPeerDepartureSignals() async {
    _peerOfflineDebounce?.cancel();
    _peerOfflineDebounce = null;
    await _peerPresenceSubscription?.cancel();
    _peerPresenceSubscription = null;

    final peerId = peerDeviceId;
    if (peerId == null) return;
    try {
      final myId = await _persistentDeviceId();
      await _deviceRegistry.cancelPeerDepartedOnDisconnect(
        targetDeviceId: peerId,
        fromDeviceId: myId,
      );
    } catch (e) {
      debugPrint('peerDeparted sinyalleri kapatılamadı: $e');
    }
  }

  Future<void> manualReconnect() async {
    await reconnectIfNeeded(force: true, manual: true);
  }

  Future<void> reconnectIfNeeded({bool force = false, bool manual = false}) async {
    if (_disposed || !isPaired || _peerHasLeft || _userInitiatedLeave) return;
    if (_reconnecting) return;

    if (await _isPeerOffline()) {
      _markPeerHasLeft();
      return;
    }

    if (isConnected && !force) return;

    if (!manual) {
      final lastAttempt = _lastReconnectAt;
      if (lastAttempt != null &&
          DateTime.now().difference(lastAttempt) < const Duration(seconds: 5)) {
        return;
      }
    }

    _lastReconnectAt = DateTime.now();
    _deferredReconnectTimer?.cancel();
    _reconnecting = true;
    _errorMessage = null;
    _connectionState = WebRtcConnectionState.connecting;
    notifyListeners();

    try {
      await _connectionSubscription?.cancel();

      TransferRestoreState? transferRestore;
      if (_fileTransfer != null) {
        transferRestore = await _fileTransfer!.detachForReconnect();
      }
      await _webRtc?.dispose();
      _fileTransfer = null;
      _webRtc = null;

      await _signaling.clearSignaling();

      final session = _session!;
      final isInitiator = session.role == PeerRole.host;

      // Konuk yeniden bağlanırken ev sahibine haber ver (yeni offer için).
      if (!isInitiator && session.remotePeerId != null) {
        try {
          await _signaling.sendMessage(
            SignalingMessage(
              type: SignalingType.peerJoined,
              fromPeerId: session.peerId,
              toPeerId: session.remotePeerId!,
            ),
          );
        } catch (e) {
          debugPrint('peerJoined sinyali gönderilemedi: $e');
        }
      }

      // Konuk önce hazır olsun; ev sahibi yeni teklif gönderir.
      if (isInitiator) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }

      if (_disposed || _session == null) return;

      await _startWebRtc(
        remotePeerId: session.remotePeerId!,
        isInitiator: isInitiator,
        transferRestore: transferRestore,
      );

      if (transferRestore != null) {
        await _fileTransfer?.resumeAfterReconnect();
      }

      await _signaling.replayPendingMessages(
        localPeerId: session.peerId,
        onMessage: _onSignalingMessage,
      );
      _scheduleConnectionWatch();
    } catch (e) {
      _errorMessage = e.toString();
      _connectionState = WebRtcConnectionState.failed;
    } finally {
      _reconnecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _onSignalingMessage(SignalingMessage message) async {
    if (message.type == SignalingType.peerLeft) {
      _markPeerHasLeft();
      return;
    }

    if (message.type == SignalingType.peerJoined &&
        _session?.role == PeerRole.host &&
        !_reconnecting) {
      unawaited(reconnectIfNeeded(force: true));
      return;
    }

    if (message.type == SignalingType.offer &&
        _session?.role == PeerRole.guest &&
        !_reconnecting &&
        (_webRtc == null ||
            _connectionState == WebRtcConnectionState.failed ||
            _connectionState == WebRtcConnectionState.disconnected)) {
      final restoredTransfer = await _restartWebRtcForIncomingOffer();
      await _webRtc?.handleSignalingMessage(message);
      // Yarım transfer durumu korunduysa, teklif/yanıt işlendikten sonra
      // (veri kanalı yeniden açılınca) sürdür. Aksi halde teklifi bekleyerek
      // kilitlenmemek için awaited etmiyoruz.
      if (restoredTransfer) {
        unawaited(_fileTransfer?.resumeAfterReconnect() ?? Future<void>.value());
      }
      return;
    }

    try {
      await _webRtc?.handleSignalingMessage(message);
    } catch (e) {
      debugPrint('Signaling mesajı işlenemedi: $e');
      rethrow;
    }
  }

  /// Gelen yeni teklif (offer) için WebRTC'yi yeniden kurar. Yarım kalan
  /// transferleri KORUR: eski servisi dispose etmek yerine durumunu yakalayıp
  /// yeni servise geri yükler. Aksi halde teklifi alan taraf (genelde guest)
  /// aktif/duraklatılmış transfer listesini kaybeder ve karşı cihazda transfer
  /// görünürken bu cihazda görünmez olur.
  ///
  /// Transfer durumu geri yüklendiyse `true` döner; çağıran taraf teklif
  /// işlendikten sonra `resumeAfterReconnect()` ile sürdürür.
  Future<bool> _restartWebRtcForIncomingOffer() async {
    if (_disposed || _session?.remotePeerId == null) return false;

    _deferredReconnectTimer?.cancel();
    await _connectionSubscription?.cancel();

    TransferRestoreState? transferRestore;
    if (_fileTransfer != null) {
      transferRestore = await _fileTransfer!.detachForReconnect();
    }
    await _webRtc?.dispose();
    _fileTransfer = null;
    _webRtc = null;
    _connectionState = WebRtcConnectionState.connecting;
    notifyListeners();

    await _startWebRtc(
      remotePeerId: _session!.remotePeerId!,
      isInitiator: false,
      transferRestore: transferRestore,
    );
    _scheduleConnectionWatch();
    return transferRestore != null;
  }

  Future<void> sendFilePaths(
    List<String> paths, {
    MediaPrepareReporter? prepareReporter,
  }) async {
    if (_fileTransfer == null) {
      throw StateError('Bağlantı henüz hazır değil.');
    }

    if (!canTransferFiles) {
      throw StateError(
        'Bağlantı yok. Dosya göndermeden önce yeniden bağlanın.',
      );
    }

    await _fileTransfer!.ensurePeerReady();
    final preferJpeg = await shouldPreferJpegForPhotos();
    final prepared = await PhotoExportService.preparePathsForTransfer(
      paths,
      preferJpeg: preferJpeg,
    );
    await _fileTransfer!.sendFiles(
      prepared,
      onHashProgress: prepareReporter == null
          ? null
          : (index, count, fraction, name) {
              prepareReporter.reportHashProgress(
                fileIndex: index,
                fileCount: count,
                fileFraction: fraction,
                fileName: name,
              );
            },
    );
    notifyListeners();
  }

  Future<void> disconnect({
    bool userInitiated = false,
    bool notifyPeer = true,
  }) async {
    if (_disconnecting || _disposed) return;
    if (userInitiated) _userInitiatedLeave = true;
    _disconnecting = true;
    _reconnecting = false;
    _guestWaitGeneration++;

    // Menü çubuğu ikonu monokroma dönsün.
    unawaited(DesktopBackgroundService.instance.setConnectionActive(false));

    _checkpointDebounce?.cancel();
    _checkpointDebounce = null;

    _connectionWatchTimer?.cancel();
    _deferredReconnectTimer?.cancel();
    _deferredReconnectTimer = null;

    await _disarmPeerDepartureSignals();

    // Karşı tarafa sinyal gönder — WebRTC kapatılmadan önce; ICE kopunca yeniden bağlanma tetiklenmesin.
    try {
      final session = _session;
      final peerId = peerDeviceId;
      final myId = await _persistentDeviceId();

      if (session != null) {
        if (session.remotePeerId != null) {
          await _signaling.notifyPeerDeparted(
            localPeerId: session.peerId,
            remotePeerId: session.remotePeerId!,
          );
        }
        await _signaling.closeRoom();
      }

      if (notifyPeer &&
          peerId != null &&
          (_hadSuccessfulConnection || _session?.remotePeerId != null)) {
        await _deviceRegistry.sendPeerDeparted(
          targetDeviceId: peerId,
          fromDeviceId: myId,
          fromDeviceName: deviceName,
        );
      }

      if (peerId != null) {
        await PairConnectCoordinator().clearSession(
          myDeviceId: myId,
          peerDeviceId: peerId,
        );
        await _deviceRegistry.clearPairInvitesBetween(
          myDeviceId: myId,
          peerDeviceId: peerId,
        );
        if (userInitiated) {
          await TransferCheckpointService.instance.clearForPeer(peerId);
        }
      }
    } catch (e) {
      debugPrint('disconnect notify peer: $e');
    }

    try {
      await _connectionSubscription?.cancel();
    } catch (e) {
      debugPrint('disconnect subscription: $e');
    }
    _connectionSubscription = null;

    try {
      await _fileTransfer?.dispose();
    } catch (e) {
      debugPrint('disconnect fileTransfer: $e');
    }
    _fileTransfer = null;

    try {
      await _webRtc?.dispose();
    } catch (e) {
      debugPrint('disconnect webRtc: $e');
    }
    _webRtc = null;

    try {
      await _signaling.dispose();
    } catch (e) {
      debugPrint('disconnect signaling: $e');
    }

    _session = null;
    _connectionState = WebRtcConnectionState.idle;
    _disconnecting = false;
    _disposed = true;
    _syncScreenWake();
  }

  void _setBusy(bool value) {
    if (_disposed) return;
    _busy = value;
    notifyListeners();
  }

  Future<void> _tearDown() async {
    _guestWaitGeneration++;
    _connectionWatchTimer?.cancel();
    _deferredReconnectTimer?.cancel();
    _deferredReconnectTimer = null;

    try {
      await _transferSubscription?.cancel();
    } catch (_) {}
    _transferSubscription = null;

    try {
      await _connectionSubscription?.cancel();
    } catch (_) {}
    _connectionSubscription = null;

    try {
      await _fileTransfer?.dispose();
    } catch (_) {}
    _fileTransfer = null;

    try {
      await _webRtc?.dispose();
    } catch (_) {}
    _webRtc = null;

    try {
      if (_session != null) {
        await _signaling.closeRoom();
      }
    } catch (_) {}

    try {
      await _signaling.dispose();
    } catch (_) {}

    _session = null;
    _syncScreenWake();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_tearDown());
    super.dispose();
  }
}
