import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/desktop_banner_entry.dart';
import '../models/reconnect_request.dart';
import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';
import 'active_session_registry.dart';
import 'desktop_background_service.dart';
import 'desktop_window_service.dart';
import 'webrtc_service.dart';
import 'windows_overlay_window.dart';

/// Dosya panelindeki satır durumu.
enum _PanelFilePhase { pending, transferring, completed }

class _PanelFileRow {
  _PanelFileRow({
    required this.id,
    required this.name,
    required this.phase,
    this.progress = 0,
    this.status = '',
  });

  final String id;
  final String name;
  _PanelFilePhase phase;
  double progress;
  String status;
}

/// Reconnect panelinin gösterdiği aşama.
enum ReconnectPanelPhase { prompt, connecting, connected, disconnected }

class DesktopOverlayService extends ChangeNotifier {
  DesktopOverlayService._();

  static final DesktopOverlayService instance = DesktopOverlayService._();

  static const _channel = MethodChannel('com.directdrop.app/overlay');

  static bool get isSupported => Platform.isWindows || Platform.isMacOS;

  /// macOS: native AppKit NSPanel'ler (DesktopAuxiliaryPanels.swift).
  static bool get _usesNativePanels => Platform.isMacOS;

  /// Windows: ana pencereyi küçük bir köşe paneline dönüştürüp Flutter ile çiziyoruz.
  static bool get _usesWindowPanels => Platform.isWindows;

  final List<DesktopBannerEntry> banners = [];

  /// Windows köşe panelinin Flutter tarafında çizilecek anlık içeriği.
  /// macOS native paneline gönderilen payload ile aynı yapıdadır.
  final ValueNotifier<Map<String, dynamic>?> windowPanelData =
      ValueNotifier<Map<String, dynamic>?>(null);

  ReconnectPanelPhase _reconnectPhase = ReconnectPanelPhase.prompt;
  TransferSessionController? _reconnectController;
  String _reconnectPeerName = 'Cihaz';

  /// Giden bağlantı akışında alt başlıkta gösterilecek durum metni
  /// (ör. "İstek gönderildi", "Onay bekleniyor", "Bağlanılıyor…").
  String? _reconnectStatusOverride;

  /// "Bağlantı koptu" bildiriminin alt başlığı (kopma nedeni).
  String _disconnectReason = '';

  String? _filesPanelPeerName;
  final Map<String, _PanelFileRow> _panelFiles = {};

  /// Menü çubuğundan başlatılan GİDEN dosya transferi panelde takip ediliyor mu.
  bool _outgoingPanelActive = false;

  Timer? _filesPanelAutoHideTimer;
  Timer? _reconnectCloseTimer;
  bool _actionHandlerRegistered = false;

  /// Sağ panelden onaylanan oturum — ana pencere açılmadan devam eder.
  bool _overlayOnlySession = false;
  bool get isOverlayOnlySession => _overlayOnlySession;
  TransferSessionController? _sessionController;
  bool _overlaySessionWasConnected = false;

  /// Aktif oturumdan gelen transfer id'leri (eski oturumları ayıklamak için).
  final Set<String> _recentlyActiveIds = {};

  /// Reddedilen dosyalar — banner yenilenirken tekrar eklenmesin.
  final Set<String> _rejectedFileIds = {};

  /// Onaylandı ama henüz awaitingApproval'dan düşmemiş dosyalar.
  final Set<String> _approvedPendingIds = {};

  DateTime? _lastProgressSync;
  Timer? _progressSyncDebounce;

  void Function(ReconnectRequest request)? onReconnectApproved;
  void Function(ReconnectRequest request)? onReconnectRejected;
  void Function(String fileId)? onFileApproved;
  void Function(String fileId)? onFileRejected;
  VoidCallback? onAcceptAllFiles;
  VoidCallback? onRejectAllFiles;
  VoidCallback? onOpenMainApp;

  TransferSessionController? get _controller =>
      ActiveSessionRegistry.instance.activeController;

  /// macOS'ta yardımcı panel açık mı veya arka plan oturumu panel üzerinden yürüyor mu.
  bool get isOverlayActive =>
      banners.isNotEmpty || _panelFiles.isNotEmpty || _overlayOnlySession;

  void enableOverlayOnlySession() {
    _overlayOnlySession = true;
  }

  void disableOverlayOnlySession() {
    _overlayOnlySession = false;
    _overlaySessionWasConnected = false;
    _detachOverlaySession();
  }

  /// Arka plandaki oturumdan dosya paneli güncellemelerini al.
  void attachOverlaySession(TransferSessionController controller) {
    if (!isSupported) return;
    _detachOverlaySession();
    _overlaySessionWasConnected = false;
    _sessionController = controller;
    controller.addListener(_onOverlaySessionChanged);
    _onOverlaySessionChanged();
  }

  void _detachOverlaySession() {
    _sessionController?.removeListener(_onOverlaySessionChanged);
    _sessionController = null;
  }

  void _onOverlaySessionChanged() {
    final controller = _sessionController;
    if (controller == null) return;

    if (controller.isConnected) {
      _overlaySessionWasConnected = true;
    }

    final items = controller.fileTransfer?.items ?? const <TransferFileItem>[];
    final awaiting = items
        .where(
          (i) =>
              i.direction == TransferDirection.receiving &&
              i.status == TransferStatus.awaitingApproval,
        )
        .toList();

    if (awaiting.isNotEmpty) {
      unawaited(
        showIncomingFilesBanner(
          peerName: controller.peerDisplayName ?? 'Cihaz',
          files: awaiting,
        ),
      );
    } else if (_outgoingPanelActive ||
        _panelFiles.isNotEmpty ||
        _approvedPendingIds.isNotEmpty ||
        banners.isNotEmpty) {
      unawaited(onTransferItemsChanged(items));
    }

    // Terminal kopma: karşı taraf ayrıldı ya da başarılı bağlantı sonrası
    // bağlantı kalıcı olarak başarısız (geçici reconnect denemesi değil).
    final terminated = controller.isDisposed ||
        controller.peerHasLeft ||
        (_overlaySessionWasConnected &&
            !controller.isBackgrounded &&
            !controller.isConnected &&
            !controller.isReconnecting &&
            controller.connectionState == WebRtcConnectionState.failed);

    if (terminated) {
      if (_overlaySessionWasConnected) {
        final peerName = controller.peerDisplayName ?? _reconnectPeerName;
        final reason = controller.peerHasLeft
            ? '$peerName bağlantıyı kapattı'
            : (controller.errorMessage ?? 'Bağlantı koptu');
        unawaited(showDisconnectedNotice(peerName, reason));
      }
      disableOverlayOnlySession();
    }
  }

  /// Sağ köşe panelleri (macOS native / Windows Flutter) yalnızca ana pencere
  /// gizliyken kullanılır.
  ///
  /// Windows'ta panel, ana pencerenin küçültülmüş hâli olduğundan panel açıkken
  /// `isMainWindowHidden()` false döner; bu yüzden panel aktifken veya arka plan
  /// (overlay-only) oturumu sürerken de arka plan modunda kabul edilir.
  static Future<bool> _shouldShowCornerPanels() async {
    if (!isSupported) return false;
    if (instance._overlayOnlySession) return true;
    if (_usesWindowPanels && WindowsOverlayWindow.instance.isActive) return true;
    return DesktopBackgroundService.instance.isMainWindowHidden();
  }

  /// Ana pencere görünürken köşe panellerini kapat (işlem uygulama içinden yapılır).
  Future<void> suppressPanelsForVisibleMainWindow() async {
    if (!isSupported) return;
    _reconnectCloseTimer?.cancel();
    banners.removeWhere(
      (b) =>
          b.kind == DesktopBannerKind.reconnect ||
          b.kind == DesktopBannerKind.incomingFiles,
    );
    _reconnectPhase = ReconnectPanelPhase.prompt;
    _reconnectStatusOverride = null;
    _disconnectReason = '';
    _panelFiles.clear();
    _outgoingPanelActive = false;
    _filesPanelAutoHideTimer?.cancel();
    _recentlyActiveIds.clear();
    notifyListeners();
    await _syncPanels();
  }

  void registerActionHandler() {
    if (!_usesNativePanels || _actionHandlerRegistered) return;
    _actionHandlerRegistered = true;
    _channel.setMethodCallHandler(_handleNativeAction);
  }

  Future<void> showReconnectBanner(ReconnectRequest request) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    _reconnectCloseTimer?.cancel();
    _reconnectPhase = ReconnectPanelPhase.prompt;
    _reconnectPeerName = request.fromDeviceName;
    _detachReconnectController();

    final id = 'reconnect_${request.fromDeviceId}_${request.clientCreatedAt}';
    banners.removeWhere((b) => b.kind == DesktopBannerKind.reconnect);
    banners.insert(
      0,
      DesktopBannerEntry(
        id: id,
        kind: DesktopBannerKind.reconnect,
        title: '${request.fromDeviceName} bağlanmak istiyor',
        subtitle: 'Onaylayın veya reddedin.',
        reconnect: request,
        peerName: request.fromDeviceName,
      ),
    );

    await _syncPanels();
    notifyListeners();
  }

  /// Tray menüsünden başlatılan GİDEN bağlantı: panel "bağlanılıyor" aşamasında
  /// açılır (onay/ret butonu yok). Durum metni [updateOutgoingStatus] ile güncellenir.
  Future<void> beginOutgoingConnect(String peerName) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    _reconnectCloseTimer?.cancel();
    _detachReconnectController();
    _reconnectPeerName = peerName;
    _reconnectPhase = ReconnectPanelPhase.connecting;
    _reconnectStatusOverride = 'İstek gönderiliyor…';

    final id = 'outgoing_${peerName}_${DateTime.now().millisecondsSinceEpoch}';
    banners.removeWhere((b) => b.kind == DesktopBannerKind.reconnect);
    banners.insert(
      0,
      DesktopBannerEntry(
        id: id,
        kind: DesktopBannerKind.reconnect,
        title: '$peerName ile bağlanılıyor',
        subtitle: '',
        peerName: peerName,
      ),
    );

    notifyListeners();
    await _syncPanels();
  }

  /// Giden bağlantı durum metnini güncelle (connectToPeer onProgress'ten).
  Future<void> updateOutgoingStatus(String message) async {
    if (!isSupported) return;
    if (_reconnectPhase != ReconnectPanelPhase.connecting) return;
    _reconnectStatusOverride = message;
    notifyListeners();
    await _syncPanels();
  }

  /// Arka planda bağlantı koptuğunda sağ panelde kısa bir bilgilendirme göster.
  Future<void> showDisconnectedNotice(String peerName, String reason) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    _reconnectCloseTimer?.cancel();
    _detachReconnectController();
    _reconnectPeerName = peerName;
    _reconnectPhase = ReconnectPanelPhase.disconnected;
    _reconnectStatusOverride = null;
    _disconnectReason = reason;

    final id = 'disconnected_${peerName}_${DateTime.now().millisecondsSinceEpoch}';
    banners.removeWhere((b) => b.kind == DesktopBannerKind.reconnect);
    banners.insert(
      0,
      DesktopBannerEntry(
        id: id,
        kind: DesktopBannerKind.reconnect,
        title: '$peerName bağlantısı koptu',
        subtitle: reason,
        peerName: peerName,
      ),
    );

    notifyListeners();
    await _syncPanels();

    _reconnectCloseTimer?.cancel();
    _reconnectCloseTimer = Timer(const Duration(seconds: 4), () {
      unawaited(_dismissReconnectBanner());
    });
  }

  /// Onaylandı; bağlantı kuruluyor durumuna geç.
  Future<void> markReconnectConnecting() async {
    if (!isSupported) return;
    _reconnectCloseTimer?.cancel();
    _reconnectPhase = ReconnectPanelPhase.connecting;
    notifyListeners();
    await _syncPanels();
  }

  /// Bağlantı kontrolcüsünü panele bağla; bağlanınca "Bağlandı" + otomatik kapan.
  void attachReconnectController(TransferSessionController controller) {
    if (!isSupported) return;
    _detachReconnectController();
    _reconnectController = controller;
    _reconnectPeerName = controller.peerDisplayName ?? _reconnectPeerName;
    controller.addListener(_onReconnectControllerChanged);
    _onReconnectControllerChanged();
  }

  void _detachReconnectController() {
    _reconnectController?.removeListener(_onReconnectControllerChanged);
    _reconnectController = null;
  }

  void _onReconnectControllerChanged() {
    final controller = _reconnectController;
    if (controller == null) return;
    if (controller.isConnected &&
        _reconnectPhase != ReconnectPanelPhase.connected) {
      _reconnectPhase = ReconnectPanelPhase.connected;
      _reconnectPeerName = controller.peerDisplayName ?? _reconnectPeerName;
      notifyListeners();
      unawaited(_syncPanels());
      _reconnectCloseTimer?.cancel();
      _reconnectCloseTimer = Timer(const Duration(milliseconds: 1800), () {
        _detachReconnectController();
        unawaited(_dismissReconnectBanner());
      });
    }
  }

  Future<void> _dismissReconnectBanner() async {
    banners.removeWhere((b) => b.kind == DesktopBannerKind.reconnect);
    _reconnectPhase = ReconnectPanelPhase.prompt;
    _reconnectStatusOverride = null;
    _disconnectReason = '';
    notifyListeners();
    await _syncPanels();
  }

  Future<void> showIncomingFilesBanner({
    required String peerName,
    required List<TransferFileItem> files,
  }) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    _filesPanelPeerName = peerName;
    for (final f in files) {
      if (_rejectedFileIds.contains(f.id)) continue;
      if (_approvedPendingIds.contains(f.id)) continue;
      final existing = _panelFiles[f.id];
      if (existing != null &&
          existing.phase != _PanelFilePhase.pending) {
        continue;
      }
      _panelFiles[f.id] = _PanelFileRow(
        id: f.id,
        name: f.name,
        phase: _PanelFilePhase.pending,
      );
    }

    _filesPanelAutoHideTimer?.cancel();
    banners.removeWhere((b) => b.kind == DesktopBannerKind.incomingFiles);
    notifyListeners();
    await _syncPanels();
  }

  /// Menü çubuğundan başlatılan GİDEN dosya transferini sağ panelde takip eder.
  /// Satırlar onay butonu olmadan ilerleme çubuğuyla görünür; X ile kapatılabilir
  /// (transfer arka planda sürer).
  Future<void> beginOutgoingFilesPanel({
    required String peerName,
    required TransferSessionController controller,
  }) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    _outgoingPanelActive = true;
    _filesPanelPeerName = peerName;
    _filesPanelAutoHideTimer?.cancel();
    attachOverlaySession(controller);
    notifyListeners();
    await _syncPanels();
  }

  /// Onay/ret: satır aynı panelde kalır; onayda butonlar kalkıp ilerleme çubuğu gelir.
  Future<void> markFileResolved(String fileId, {required bool approved}) async {
    if (!isSupported) return;

    if (approved) {
      _approvedPendingIds.add(fileId);
      final name = _panelFiles[fileId]?.name ?? 'Dosya';
      _panelFiles[fileId] = _PanelFileRow(
        id: fileId,
        name: name,
        phase: _PanelFilePhase.transferring,
        progress: 0,
        status: 'Başlatılıyor',
      );
    } else {
      _rejectedFileIds.add(fileId);
      _panelFiles.remove(fileId);
    }

    _filesPanelAutoHideTimer?.cancel();
    notifyListeners();
    await _syncPanels();
  }

  Future<void> markAllFilesApproved() async {
    if (!isSupported) return;

    for (final entry in _panelFiles.entries.toList()) {
      if (entry.value.phase != _PanelFilePhase.pending) continue;
      _approvedPendingIds.add(entry.key);
      _panelFiles[entry.key] = _PanelFileRow(
        id: entry.value.id,
        name: entry.value.name,
        phase: _PanelFilePhase.transferring,
        progress: 0,
        status: 'Başlatılıyor',
      );
    }

    _filesPanelAutoHideTimer?.cancel();
    notifyListeners();
    await _syncPanels();
  }

  Future<void> markAllFilesRejected() async {
    if (!isSupported) return;

    for (final id in _panelFiles.keys.toList()) {
      final row = _panelFiles[id];
      if (row?.phase == _PanelFilePhase.pending) {
        _rejectedFileIds.add(id);
        _panelFiles.remove(id);
      }
    }

    notifyListeners();
    await _syncPanels();
  }

  void _syncPanelFilesFromTransferItems(List<TransferFileItem> items) {
    for (final item in items) {
      // GİDEN transfer paneli: onay yok, sadece ilerleme/durum gösterilir.
      if (item.direction == TransferDirection.sending) {
        if (!_outgoingPanelActive) continue;
        final done = item.status == TransferStatus.completed;
        _panelFiles[item.id] = _PanelFileRow(
          id: item.id,
          name: item.name,
          phase: done
              ? _PanelFilePhase.completed
              : _PanelFilePhase.transferring,
          progress: item.progress.clamp(0.0, 1.0),
          status: _outgoingStatusLabel(item.status),
        );
        continue;
      }

      if (item.direction != TransferDirection.receiving) continue;

      if (item.status == TransferStatus.awaitingApproval) {
        if (_rejectedFileIds.contains(item.id)) continue;
        if (_approvedPendingIds.contains(item.id)) continue;
        if (!_panelFiles.containsKey(item.id)) {
          _panelFiles[item.id] = _PanelFileRow(
            id: item.id,
            name: item.name,
            phase: _PanelFilePhase.pending,
          );
        }
        continue;
      }

      if (item.status == TransferStatus.queued ||
          item.status == TransferStatus.inProgress ||
          item.status == TransferStatus.verifying ||
          item.status == TransferStatus.paused) {
        // Yalnızca panel/tray üzerinden onaylanmış dosyaları izle; ana pencerede
        // başlayan aktif transferler arka plana alınınca panele taşınmaz.
        final trackedOnPanel = _panelFiles.containsKey(item.id) ||
            _approvedPendingIds.contains(item.id) ||
            _recentlyActiveIds.contains(item.id);
        if (!trackedOnPanel) continue;

        _approvedPendingIds.remove(item.id);
        _recentlyActiveIds.add(item.id);
        _panelFiles[item.id] = _PanelFileRow(
          id: item.id,
          name: item.name,
          phase: _PanelFilePhase.transferring,
          progress: item.progress.clamp(0.0, 1.0),
          status: _statusLabel(item.status),
        );
        continue;
      }

      if (item.status == TransferStatus.completed &&
          _recentlyActiveIds.contains(item.id)) {
        _panelFiles[item.id] = _PanelFileRow(
          id: item.id,
          name: item.name,
          phase: _PanelFilePhase.completed,
          progress: 1,
          status: 'Tamamlandı',
        );
      }
    }
  }

  void _maybeAutoHideFilesPanel() {
    if (_panelFiles.isEmpty) return;

    final hasPending = _panelFiles.values
        .any((r) => r.phase == _PanelFilePhase.pending);
    final hasActive = _panelFiles.values.any(
      (r) => r.phase == _PanelFilePhase.transferring,
    );
    if (hasPending || hasActive) {
      _filesPanelAutoHideTimer?.cancel();
      return;
    }

    _filesPanelAutoHideTimer?.cancel();
    _filesPanelAutoHideTimer = Timer(const Duration(seconds: 3), () {
      _panelFiles.clear();
      _outgoingPanelActive = false;
      _recentlyActiveIds.clear();
      unawaited(_syncPanels());
      notifyListeners();
    });
  }

  Future<void> dismissBanner(String id) async {
    banners.removeWhere((b) => b.id == id);
    notifyListeners();
    await _syncPanels();
  }

  Future<void> showTransferHud() async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;
    if (_panelFiles.isEmpty && banners.isEmpty) return;
    await _syncPanels();
    notifyListeners();
  }

  /// Panel arayüzünü kapatır; arka plandaki transfer/oturum devam eder.
  Future<void> dismissPanelsUiOnly() async {
    if (!isSupported) return;
    _filesPanelAutoHideTimer?.cancel();
    _reconnectCloseTimer?.cancel();
    _detachReconnectController();
    banners.clear();
    _panelFiles.clear();
    _outgoingPanelActive = false;
    _recentlyActiveIds.clear();
    _approvedPendingIds.clear();
    _rejectedFileIds.clear();
    _filesPanelPeerName = null;
    _reconnectPhase = ReconnectPanelPhase.prompt;
    _reconnectStatusOverride = null;
    _disconnectReason = '';
    _progressSyncDebounce?.cancel();
    notifyListeners();
    await _hideAllPanels();
  }

  Future<void> onTransferItemsChanged(List<TransferFileItem> items) async {
    if (!isSupported) return;
    if (!await _shouldShowCornerPanels()) return;

    final hasAwaiting = items.any(
      (i) =>
          i.direction == TransferDirection.receiving &&
          i.status == TransferStatus.awaitingApproval &&
          !_rejectedFileIds.contains(i.id),
    );
    final hasPanelWork =
        _outgoingPanelActive ||
        _panelFiles.isNotEmpty ||
        _approvedPendingIds.isNotEmpty ||
        banners.isNotEmpty;

    if (!hasAwaiting && !hasPanelWork) return;

    _syncPanelFilesFromTransferItems(items);
    _maybeAutoHideFilesPanel();

    notifyListeners();
    if (_panelFiles.isNotEmpty || banners.isNotEmpty) {
      _scheduleProgressSync();
    } else {
      await _syncPanels();
    }
  }

  void _scheduleProgressSync() {
    _progressSyncDebounce?.cancel();
    final now = DateTime.now();
    final last = _lastProgressSync;
    if (last != null && now.difference(last) < const Duration(milliseconds: 120)) {
      _progressSyncDebounce = Timer(const Duration(milliseconds: 120), () {
        _lastProgressSync = DateTime.now();
        unawaited(_syncPanels());
        notifyListeners();
      });
      return;
    }
    _lastProgressSync = now;
    unawaited(_syncPanels());
  }

  Future<void> restoreNormalAndShow() async {
    if (!isSupported) return;
    _filesPanelAutoHideTimer?.cancel();
    _reconnectCloseTimer?.cancel();
    _detachReconnectController();
    disableOverlayOnlySession();
    banners.clear();
    _panelFiles.clear();
    _outgoingPanelActive = false;
    _recentlyActiveIds.clear();
    _rejectedFileIds.clear();
    _approvedPendingIds.clear();
    _filesPanelPeerName = null;
    _progressSyncDebounce?.cancel();
    notifyListeners();
    await _hideAllPanels();
    await DesktopWindowService.configure();
    await DesktopBackgroundService.instance.showMainWindow(force: true);
  }

  Future<void> hideOverlayToTray() async {
    if (!isSupported) return;
    _filesPanelAutoHideTimer?.cancel();
    _reconnectCloseTimer?.cancel();
    _detachReconnectController();
    disableOverlayOnlySession();
    banners.clear();
    _panelFiles.clear();
    _outgoingPanelActive = false;
    _recentlyActiveIds.clear();
    _rejectedFileIds.clear();
    _approvedPendingIds.clear();
    _filesPanelPeerName = null;
    _progressSyncDebounce?.cancel();
    notifyListeners();
    await _hideAllPanels();
  }

  Future<void> _syncPanels() async {
    if (!isSupported) return;

    final reconnectBanner = banners.cast<DesktopBannerEntry?>().firstWhere(
          (b) => b!.kind == DesktopBannerKind.reconnect,
          orElse: () => null,
        );

    Map<String, dynamic>? reconnectPayload;
    if (reconnectBanner != null) {
      final r = reconnectBanner.reconnect;
      reconnectPayload = {
        'title': _reconnectTitle(reconnectBanner),
        'subtitle': _reconnectSubtitle(),
        'phase': _reconnectPhase.name,
        'fromDeviceId': r?.fromDeviceId ?? '',
        'fromDeviceName': r?.fromDeviceName ?? _reconnectPeerName,
        'clientCreatedAt': r?.clientCreatedAt ?? 0,
      };
    }

    Map<String, dynamic>? filesPayload;
    if (_panelFiles.isNotEmpty) {
      final rows = _panelFiles.values.toList();
      final pendingCount =
          rows.where((r) => r.phase == _PanelFilePhase.pending).length;
      final peer = _filesPanelPeerName ?? _controller?.peerDisplayName ?? 'Cihaz';

      final String title;
      final String subtitle;
      if (pendingCount > 0) {
        title = '$peer dosya göndermek istiyor';
        subtitle = '$pendingCount dosya onay bekliyor';
      } else if (_outgoingPanelActive) {
        title = '$peer cihazına gönderiliyor';
        subtitle = '${rows.length} dosya';
      } else {
        title = 'Aktif transfer';
        subtitle = peer;
      }

      filesPayload = {
        'title': title,
        'subtitle': subtitle,
        'showBulkActions': pendingCount > 0,
        'items': [
          for (final row in rows.take(8))
            {
              'id': row.id,
              'name': _truncateFileName(row.name),
              'phase': row.phase.name,
              'progress': row.progress.clamp(0.0, 1.0),
              'status': row.status.isEmpty
                  ? (row.phase == _PanelFilePhase.pending
                      ? 'Onay bekliyor'
                      : 'Başlatılıyor')
                  : row.status,
            },
        ],
      };
    }

    if (reconnectPayload == null && filesPayload == null) {
      await _hideAllPanels();
      return;
    }

    final payload = <String, dynamic>{
      if (reconnectPayload != null) 'reconnect': reconnectPayload,
      if (filesPayload != null) 'files': filesPayload,
    };

    if (_usesWindowPanels) {
      windowPanelData.value = payload;
      await WindowsOverlayWindow.instance.show(
        _estimatePanelHeight(reconnectPayload, filesPayload),
      );
      return;
    }

    if (!_usesNativePanels) return;

    try {
      await _channel.invokeMethod<void>('sync', payload);
    } catch (e, stack) {
      debugPrint('Yardımcı panel senkronu başarısız: $e\n$stack');
    }
  }

  /// Windows köşe penceresinin yüksekliğini içeriğe göre tahmin eder.
  /// Değerler [WindowsOverlayPanels] yerleşimiyle uyumlu tutulmalıdır.
  double _estimatePanelHeight(
    Map<String, dynamic>? reconnect,
    Map<String, dynamic>? files,
  ) {
    double h = 24; // dış dikey boşluk
    if (reconnect != null) {
      h += 70; // avatar + başlık + alt başlık bloğu
      if ((reconnect['phase'] as String? ?? 'prompt') == 'prompt') {
        h += 52; // onay/ret butonları
      }
    }
    if (reconnect != null && files != null) h += 16; // ayraç + boşluk
    if (files != null) {
      h += 48; // dosya başlığı
      if (files['showBulkActions'] == true) h += 46; // toplu butonlar
      final items = (files['items'] as List?) ?? const [];
      h += items.length * 48;
      h += 8;
    }
    return h.clamp(96.0, 640.0);
  }

  String _reconnectTitle(DesktopBannerEntry banner) {
    switch (_reconnectPhase) {
      case ReconnectPanelPhase.connecting:
        return '$_reconnectPeerName ile bağlanılıyor';
      case ReconnectPanelPhase.connected:
        return '$_reconnectPeerName bağlandı';
      case ReconnectPanelPhase.disconnected:
        return '$_reconnectPeerName bağlantısı koptu';
      case ReconnectPanelPhase.prompt:
        return banner.title;
    }
  }

  String _reconnectSubtitle() {
    switch (_reconnectPhase) {
      case ReconnectPanelPhase.connecting:
        // Giden bağlantıda onProgress metni; aksi halde genel ileti.
        return _reconnectStatusOverride ?? 'Oda açılıyor, lütfen bekleyin…';
      case ReconnectPanelPhase.connected:
        return 'Bağlantı kuruldu. Dosya transferine hazır.';
      case ReconnectPanelPhase.disconnected:
        return _disconnectReason.isEmpty ? 'Bağlantı koptu.' : _disconnectReason;
      case ReconnectPanelPhase.prompt:
        return 'Onaylayın veya reddedin.';
    }
  }

  String _truncateFileName(String name, {int maxLen = 42}) {
    if (name.length <= maxLen) return name;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
    final baseMax = maxLen - ext.length - 1;
    if (baseMax < 8) return '${name.substring(0, maxLen - 1)}…';
    return '${name.substring(0, baseMax)}…$ext';
  }

  Future<void> _hideAllPanels() async {
    if (_usesWindowPanels) {
      windowPanelData.value = null;
      await WindowsOverlayWindow.instance.hide();
      return;
    }
    if (!_usesNativePanels) return;
    try {
      await _channel.invokeMethod<void>('hideAll');
    } catch (e, stack) {
      debugPrint('Yardımcı paneller kapatılamadı: $e\n$stack');
    }
  }

  String _statusLabel(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return 'Tamamlandı';
      case TransferStatus.queued:
        return 'Sıraya alındı';
      case TransferStatus.verifying:
        return 'Doğrulanıyor';
      case TransferStatus.paused:
        return 'Duraklatıldı';
      default:
        return 'Alınıyor';
    }
  }

  String _outgoingStatusLabel(TransferStatus status) {
    switch (status) {
      case TransferStatus.completed:
        return 'Gönderildi';
      case TransferStatus.queued:
        return 'Sıraya alındı';
      case TransferStatus.verifying:
        return 'Doğrulanıyor';
      case TransferStatus.paused:
        return 'Duraklatıldı';
      default:
        return 'Gönderiliyor';
    }
  }

  Future<void> _handleNativeAction(MethodCall call) async {
    if (call.method != 'onAction') return;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    await handlePanelAction(args['action'] as String? ?? '', args);
  }

  /// Köşe panelinden gelen aksiyonları işler. macOS native panel kanalı ve
  /// Windows Flutter paneli ([WindowsOverlayPanels]) aynı dağıtımı kullanır.
  Future<void> handlePanelAction(
    String action,
    Map<String, dynamic> args,
  ) async {
    switch (action) {
      case 'reconnect_approve':
        onReconnectApproved?.call(
          ReconnectRequest(
            fromDeviceId: args['fromDeviceId'] as String? ?? '',
            fromDeviceName: args['fromDeviceName'] as String? ?? 'Cihaz',
            clientCreatedAt: (args['clientCreatedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          ),
        );
      case 'reconnect_reject':
        _reconnectCloseTimer?.cancel();
        _detachReconnectController();
        onReconnectRejected?.call(
          ReconnectRequest(
            fromDeviceId: args['fromDeviceId'] as String? ?? '',
            fromDeviceName: args['fromDeviceName'] as String? ?? 'Cihaz',
            clientCreatedAt: (args['clientCreatedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await _dismissReconnectBanner();
      case 'file_accept':
        onFileApproved?.call(args['fileId'] as String? ?? '');
      case 'file_reject':
        onFileRejected?.call(args['fileId'] as String? ?? '');
      case 'files_accept_all':
        onAcceptAllFiles?.call();
      case 'files_reject_all':
        onRejectAllFiles?.call();
      case 'open_main':
        onOpenMainApp?.call();
      case 'panel_dismiss':
        await dismissPanelsUiOnly();
    }
  }
}
