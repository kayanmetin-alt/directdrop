import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';
import '../services/active_session_registry.dart';
import '../services/desktop_background_service.dart';
import '../services/send_file_picker_service.dart';
import '../services/webrtc_service.dart';
import '../services/transfer_history_service.dart';
import '../utils/session_exit_helper.dart';
import '../widgets/incoming_transfer_approval_panel.dart';
import '../widgets/desktop_file_drop_overlay.dart';
import '../widgets/desktop_centered_layout.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/transfer_room_settings_sheet.dart';
import '../widgets/transfer_history_tile.dart';
import '../widgets/transfer_progress_tile.dart';
import '../widgets/app_version_label.dart';
import '../widgets/media_prepare_overlay.dart';

class TransferScreen extends StatefulWidget {
  const TransferScreen({
    super.key,
    required this.controller,
    this.incomingFromName,
    this.peerDeviceId,
    this.peerDisplayName,
    this.peerPlatform,
  });

  final TransferSessionController controller;
  final String? incomingFromName;
  final String? peerDeviceId;
  final String? peerDisplayName;
  final String? peerPlatform;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen>
    with WidgetsBindingObserver {
  bool _sending = false;
  String? _error;
  bool _sendButtonReady = false;
  bool _handledPeerLeft = false;
  bool _historyExpanded = false;
  bool _historySynced = false;
  int _knownHistoryCount = 0;
  final FocusNode _sendButtonFocus = FocusNode(skipTraversal: true);
  final _historyService = TransferHistoryService.instance;

  TransferSessionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.peerDeviceId != null && widget.peerDisplayName != null) {
      _controller.bindPeer(
        deviceId: widget.peerDeviceId!,
        displayName: widget.peerDisplayName!,
        platform: widget.peerPlatform,
      );
    }
    _historyService.addListener(_onHistoryChanged);
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.ensurePeerDeviceResolved());
    unawaited(_initHistoryBaseline());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _sendButtonReady = true);
      });
    });
  }

  Future<void> _initHistoryBaseline() async {
    await _historyService.load();
    await _controller.ensurePeerDeviceResolved();
    if (!mounted) return;
    setState(() {
      _knownHistoryCount = _historyEntries().length;
      _historySynced = true;
    });
  }

  void _onHistoryChanged() {
    if (!mounted) return;
    final count = _historyEntries().length;
    setState(() {
      // Yeni bir kayıt eklendiğinde (transfer tamamlanınca) listeyi otomatik aç.
      if (_historySynced && count > _knownHistoryCount) {
        _historyExpanded = true;
      }
      _knownHistoryCount = count;
    });
  }

  String _historySubtitle(String peerLabel, int count) {
    if (count == 0) {
      return '$peerLabel ile transfer geçmişi yok';
    }
    return _historyExpanded
        ? '$count kayıt — gizlemek için dokunun'
        : '$count kayıt — göstermek için dokunun';
  }

  void _onControllerChanged() {
    if (!mounted || _handledPeerLeft || _controller.userInitiatedLeave) return;
    if (_controller.supersededByReconnect) return;

    final active = ActiveSessionRegistry.instance.activeController;
    if (active != null && !identical(active, _controller)) return;

    final peerLabel =
        widget.peerDisplayName ?? _controller.peerDisplayName ?? 'Karşı cihaz';

    if (_controller.peerHasLeft) {
      _handledPeerLeft = true;
      unawaited(
        SessionExitHelper.leaveAndGoHome(
          controller: _controller,
          peerDeviceId: widget.peerDeviceId ?? _controller.peerDeviceId,
          context: context,
          snackMessage: '$peerLabel bağlantıyı kapattı',
          userInitiatedDisconnect: false,
        ),
      );
      return;
    }

    if (_controller.hadSuccessfulConnection &&
        !_controller.isConnected &&
        !_controller.isReconnecting &&
        !_controller.isBackgrounded &&
        _controller.connectionState == WebRtcConnectionState.failed) {
      _handledPeerLeft = true;
      unawaited(
        SessionExitHelper.leaveAndGoHome(
          controller: _controller,
          peerDeviceId: widget.peerDeviceId ?? _controller.peerDeviceId,
          context: context,
          snackMessage: '$peerLabel bağlantıyı kapattı',
          userInitiatedDisconnect: false,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _historyService.removeListener(_onHistoryChanged);
    _sendButtonFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _controller.markBackgrounded();
        break;
      case AppLifecycleState.resumed:
        _controller.onAppResumed();
        break;
      default:
        break;
    }
  }

  Future<void> _activateAppWindow() async {
    if (Platform.isMacOS || Platform.isWindows) {
      await DesktopBackgroundService.instance.showMainWindow();
    }
  }

  Future<void> _sendPaths(List<String> paths) async {
    if (paths.isEmpty) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await runMediaPrepare(context, (reporter) async {
        await _controller.sendFilePaths(paths, prepareReporter: reporter);
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSend() async {
    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await _activateAppWindow();
      if (!mounted) return;

      final preferJpeg = await _controller.shouldPreferJpegForPhotos();
      if (!mounted) return;

      if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) {
        final paths = await SendFilePickerService.pickFromDeviceStorage();
        if (paths == null || paths.isEmpty) return;
        if (!mounted) return;
        await runMediaPrepare(context, (reporter) async {
          await _controller.sendFilePaths(paths, prepareReporter: reporter);
        });
        return;
      }

      final source = await SendFilePickerService.pickSource(context);
      if (!mounted || source == null) return;

      switch (source) {
        case SendFileSource.photosLibrary:
          if (!mounted) return;
          await runMediaPrepare(context, (reporter) async {
            final paths = await SendFilePickerService.pickFromPhotosLibrary(
              preferJpeg: preferJpeg,
            );
            if (paths == null || paths.isEmpty) return;
            await _controller.sendFilePaths(paths, prepareReporter: reporter);
          });
        case SendFileSource.deviceStorage:
          final paths = await SendFilePickerService.pickFromDeviceStorage();
          if (paths == null || paths.isEmpty) return;
          if (!mounted) return;
          await runMediaPrepare(context, (reporter) async {
            await _controller.sendFilePaths(paths, prepareReporter: reporter);
          });
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _disconnect() async {
    if (!mounted) return;
    await SessionExitHelper.leaveAndGoHome(
      controller: _controller,
      peerDeviceId: widget.peerDeviceId ?? _controller.peerDeviceId,
      context: context,
    );
  }

  Future<void> _confirmClearHistory() async {
    final peerId = widget.peerDeviceId ?? _controller.peerDeviceId;
    if (peerId == null) return;

    final peerLabel =
        widget.peerDisplayName ?? _controller.peerDisplayName ?? 'Bu cihaz';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Geçmişi temizle'),
        content: Text('$peerLabel ile olan transfer geçmişi silinsin mi?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Temizle'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await _historyService.clearForPeer(peerId);
  }

  String _connectionLabel(WebRtcConnectionState state) {
    switch (state) {
      case WebRtcConnectionState.connected:
        return 'Bağlı — doğrudan P2P';
      case WebRtcConnectionState.connecting:
        return _controller.isReconnecting
            ? 'Yeniden bağlanıyor…'
            : 'Bağlanıyor…';
      case WebRtcConnectionState.failed:
        return 'Bağlantı başarısız';
      case WebRtcConnectionState.disconnected:
        return 'Bağlantı kesildi';
      case WebRtcConnectionState.idle:
        return 'Hazır';
    }
  }

  List<dynamic> _historyEntries() {
    final peerId = widget.peerDeviceId ?? _controller.peerDeviceId;
    if (peerId == null) return const [];
    return _historyService.recordsForPeer(peerId);
  }

  List<TransferFileItem> _activeTransfers(List<TransferFileItem> items) {
    return items
        .where(
          (item) =>
              item.status == TransferStatus.awaitingApproval ||
              item.status == TransferStatus.queued ||
              item.status == TransferStatus.inProgress ||
              item.status == TransferStatus.paused ||
              item.status == TransferStatus.verifying ||
              item.status == TransferStatus.pending,
        )
        .toList();
  }

  Widget _buildPeerDepartedBody(BuildContext context, String peerLabel) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 28),
            Text(
              '$peerLabel bağlantıyı kapattı',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'Ana sayfaya dönülüyor…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  List<TransferFileItem> _awaitingIncomingApproval(
    List<TransferFileItem> items,
  ) {
    return items
        .where(
          (item) =>
              item.status == TransferStatus.awaitingApproval &&
              item.direction == TransferDirection.receiving,
        )
        .toList();
  }

  List<TransferFileItem> _activeTransfersExcludingIncomingApproval(
    List<TransferFileItem> items,
  ) {
    return _activeTransfers(items)
        .where(
          (item) =>
              item.status != TransferStatus.awaitingApproval ||
              item.direction != TransferDirection.receiving,
        )
        .toList();
  }

  Widget _buildActiveTransferItem(TransferFileItem item) {
    return TransferProgressTile(
      item: item,
      onPauseToggle: item.status == TransferStatus.inProgress ||
              item.status == TransferStatus.paused
          ? () => _controller.togglePauseTransfer(item.id)
          : null,
      onCancel: item.status == TransferStatus.inProgress ||
              item.status == TransferStatus.paused
          ? () => _controller.cancelTransfer(item.id)
          : null,
    );
  }

  Widget _buildTopSection({
    required BuildContext context,
    required dynamic session,
    required List<TransferFileItem> awaitingIncoming,
    required List<TransferFileItem> activeTransfers,
    required bool showActiveSection,
    required int historyCount,
    required String peerLabel,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: _controller.isReconnecting
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _controller.isConnected ? Icons.link : Icons.link_off,
                    ),
              title: Text(_connectionLabel(_controller.connectionState)),
              subtitle: Text('Oda ${session.roomCode}'),
            ),
          ),
          if (!_controller.isConnected &&
              _controller.isPaired &&
              !_controller.userInitiatedLeave &&
              !_controller.peerHasLeft) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _controller.isReconnecting
                            ? 'Bağlantı geri yükleniyor…'
                            : 'Bağlantı kesildi. Yeniden bağlanabilirsiniz.',
                      ),
                    ),
                    if (!_controller.isReconnecting)
                      TextButton(
                        onPressed: _controller.reconnectIfNeeded,
                        child: const Text('Yeniden bağlan'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (showActiveSection) ...[
            const SizedBox(height: 16),
            Text(
              'Aktif transferler',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (awaitingIncoming.isNotEmpty)
              IncomingTransferApprovalPanel(
                controller: _controller,
                items: awaitingIncoming,
              ),
            ...activeTransfers.map(_buildActiveTransferItem),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            focusNode: _sendButtonFocus,
            autofocus: false,
            onPressed:
                _sendButtonReady && _controller.isConnected && !_sending
                    ? _pickAndSend
                    : null,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.attach_file),
            label: const Text('Dosya Gönder'),
          ),
          if (DesktopFileDropOverlay.isSupported && _controller.isConnected) ...[
            const SizedBox(height: 8),
            Text(
              'veya dosyaları bu pencereye sürükleyip bırakın',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          const DownloadLocationSettings(collapsible: true),
          const SizedBox(height: 16),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _historyExpanded = !_historyExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Transfer geçmişi',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          _historySubtitle(peerLabel, historyCount),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (historyCount > 0 && _historyExpanded)
                    TextButton(
                      onPressed: _confirmClearHistory,
                      child: const Text('Temizle'),
                    ),
                  Icon(
                    _historyExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildHistorySection({
    required BuildContext context,
    required List<dynamic> history,
  }) {
    if (!_historyExpanded) return const SizedBox.shrink();

    if (history.isEmpty) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Center(
            child: Text(
              'Bu bağlantıda henüz kayıtlı transfer yok.\n'
              'Gönderilen ve alınan dosyalar burada listelenir.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: history.length,
        itemBuilder: (context, index) {
          return TransferHistoryTile(record: history[index]);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final session = _controller.session;
        if (session == null) {
          return const SizedBox.shrink();
        }
        final liveTransfers = _controller.fileTransfer?.items ?? [];
        final awaitingIncoming = _awaitingIncomingApproval(liveTransfers);
        final activeTransfers =
            _activeTransfersExcludingIncomingApproval(liveTransfers);
        final showActiveSection =
            awaitingIncoming.isNotEmpty || activeTransfers.isNotEmpty;
        final history = _historyEntries();
        final peerLabel =
            widget.peerDisplayName ?? _controller.peerDisplayName ?? 'Cihaz';

        if (_controller.peerHasLeft) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              await _disconnect();
            },
            child: Scaffold(
              appBar: AppBar(
                title: Text(peerLabel),
                automaticallyImplyLeading: false,
              ),
              body: _buildPeerDepartedBody(context, peerLabel),
            ),
          );
        }

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            await _disconnect();
          },
          child: Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(peerLabel),
                const AppVersionLabel(compact: true),
              ],
            ),
            actions: [
              TransferRoomSettingsIcon(
                onPressed: () => TransferRoomSettingsSheet.show(context),
              ),
              if (history.isNotEmpty)
                IconButton(
                  onPressed: _confirmClearHistory,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  tooltip: 'Geçmişi temizle',
                ),
              IconButton(
                onPressed: _disconnect,
                icon: const Icon(Icons.close),
                tooltip: 'Bağlantıyı kapat',
              ),
            ],
          ),
          body: DesktopFileDropOverlay(
            enabled: _controller.isConnected && !_sending,
            onFilesDropped: _sendPaths,
            child: DesktopCenteredLayout(
              maxWidth: 820,
              child: _historyExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopSection(
                          context: context,
                          session: session,
                          awaitingIncoming: awaitingIncoming,
                          activeTransfers: activeTransfers,
                          showActiveSection: showActiveSection,
                          historyCount: history.length,
                          peerLabel: peerLabel,
                        ),
                        _buildHistorySection(
                          context: context,
                          history: history,
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      child: _buildTopSection(
                        context: context,
                        session: session,
                        awaitingIncoming: awaitingIncoming,
                        activeTransfers: activeTransfers,
                        showActiveSection: showActiveSection,
                        historyCount: history.length,
                        peerLabel: peerLabel,
                      ),
                    ),
            ),
          ),
        ),
        );
      },
    );
  }
}
