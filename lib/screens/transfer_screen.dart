import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';
import '../services/webrtc_service.dart';
import '../services/transfer_history_service.dart';
import '../widgets/active_transfer_tile.dart';
import '../widgets/desktop_file_drop_overlay.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/transfer_history_tile.dart';
import '../widgets/transfer_progress_tile.dart';

class TransferScreen extends StatefulWidget {
  const TransferScreen({
    super.key,
    required this.controller,
    this.incomingFromName,
    this.peerDeviceId,
    this.peerDisplayName,
  });

  final TransferSessionController controller;
  final String? incomingFromName;
  final String? peerDeviceId;
  final String? peerDisplayName;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen>
    with WidgetsBindingObserver {
  bool _sending = false;
  String? _error;
  bool _sendButtonReady = false;
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
      );
    }
    _historyService.load();
    _historyService.addListener(_onHistoryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _sendButtonReady = true);
      });
    });
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withReadStream: false,
        dialogTitle: 'Gönderilecek dosyaları seçin',
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final paths = result.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();

      if (paths.isEmpty) {
        throw StateError('Seçilen dosyaların yolu alınamadı.');
      }

      await _controller.sendFilePaths(paths);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
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
              item.status == TransferStatus.verifying ||
              item.status == TransferStatus.pending,
        )
        .toList();
  }

  Widget _buildActiveTransferItem(TransferFileItem item) {
    if (item.status == TransferStatus.awaitingApproval &&
        item.direction == TransferDirection.receiving) {
      return ActiveTransferApprovalTile(
        controller: _controller,
        item: item,
      );
    }
    return TransferProgressTile(item: item);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final session = _controller.session!;
        final liveTransfers = _controller.fileTransfer?.items ?? [];
        final activeTransfers = _activeTransfers(liveTransfers);
        final history = _historyEntries();
        final peerLabel =
            widget.peerDisplayName ?? _controller.peerDisplayName ?? 'Cihaz';

        return Scaffold(
          appBar: AppBar(
            title: Text(peerLabel),
            actions: [
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
                if (!_controller.isConnected && _controller.isPaired) ...[
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
                const DownloadLocationSettings(),
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
        );
      },
    );
  }
}
