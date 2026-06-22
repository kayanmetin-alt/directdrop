import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';
import '../services/send_file_picker_service.dart';
import '../services/webrtc_service.dart';
import '../services/transfer_history_service.dart';
import '../utils/session_exit_helper.dart';
import '../widgets/active_transfer_tile.dart';
import '../widgets/desktop_file_drop_overlay.dart';
import '../widgets/desktop_centered_layout.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/transfer_room_settings_sheet.dart';
import '../widgets/transfer_history_tile.dart';
import '../widgets/transfer_progress_tile.dart';
import '../widgets/app_version_label.dart';

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
    _historyService.load();
    _historyService.addListener(_onHistoryChanged);
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _sendButtonReady = true);
      });
    });
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted || _handledPeerLeft || _controller.userInitiatedLeave) return;

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
    if (Platform.isMacOS) {
      const channel = MethodChannel('com.directdrop.app/window');
      try {
        await channel.invokeMethod<void>('activate');
      } catch (_) {}
    }
  }

  Future<void> _sendPaths(List<String> paths) async {
    if (paths.isEmpty) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      await _controller.sendFilePaths(paths);
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
      final paths = await SendFilePickerService.pickWithSourceChoice(
        context,
        preferJpeg: preferJpeg,
      );

      if (paths == null || paths.isEmpty) {
        return;
      }

      await _controller.sendFilePaths(paths);
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
    final clearPeer = peerId != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Geçmişi temizle'),
        content: Text(
          clearPeer
              ? 'Bu cihazla olan transfer geçmişi silinsin mi?'
              : 'Tüm transfer geçmişi silinsin mi?',
        ),
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

    if (clearPeer) {
      await _historyService.clearForPeer(peerId);
    } else {
      await _historyService.clearAll();
    }
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
    final records = peerId != null
        ? _historyService.recordsForPeer(peerId)
        : _historyService.records;
    return records;
  }

  List<TransferFileItem> _activeTransfers(List<TransferFileItem> items) {
    return items
        .where(
          (item) =>
              item.status == TransferStatus.awaitingApproval ||
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

  Widget _buildActiveTransferItem(TransferFileItem item) {
    if (item.status == TransferStatus.awaitingApproval &&
        item.direction == TransferDirection.receiving) {
      return ActiveTransferApprovalTile(
        controller: _controller,
        item: item,
      );
    }
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
        final activeTransfers = _activeTransfers(liveTransfers);
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
              child: Padding(
              padding: const EdgeInsets.all(16),
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
                            _controller.isConnected
                                ? Icons.link
                                : Icons.link_off,
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
                if (activeTransfers.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Aktif transferler',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ...activeTransfers.map(_buildActiveTransferItem),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  focusNode: _sendButtonFocus,
                  autofocus: false,
                  onPressed: _sendButtonReady &&
                          _controller.isConnected &&
                          !_sending
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
                if (DesktopFileDropOverlay.isSupported &&
                    _controller.isConnected) ...[
                  const SizedBox(height: 8),
                  Text(
                    'veya dosyaları bu pencereye sürükleyip bırakın',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const DownloadLocationSettings(collapsible: true),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Transfer geçmişi',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (history.isNotEmpty)
                      TextButton(
                        onPressed: _confirmClearHistory,
                        child: const Text('Temizle'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: history.isEmpty
                      ? Center(
                          child: Text(
                            'Henüz kayıtlı transfer yok.\n'
                            'Gönderilen ve alınan dosyalar burada kalıcı olarak listelenir.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        )
                      : ListView.builder(
                          itemCount: history.length,
                          itemBuilder: (context, index) {
                            final record = history[index];
                            return TransferHistoryTile(record: record);
                          },
                        ),
                ),
              ],
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
