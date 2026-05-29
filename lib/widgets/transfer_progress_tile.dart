import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/transfer_file.dart';
import '../utils/file_location_opener.dart';

class TransferProgressTile extends StatelessWidget {
  const TransferProgressTile({
    super.key,
    required this.item,
    this.onPauseToggle,
    this.onCancel,
  });

  final TransferFileItem item;
  final VoidCallback? onPauseToggle;
  final VoidCallback? onCancel;

  bool get _showTransferControls =>
      onPauseToggle != null &&
      onCancel != null &&
      (item.status == TransferStatus.inProgress ||
          item.status == TransferStatus.paused);

  String _statusLabel() {
    switch (item.status) {
      case TransferStatus.pending:
        return 'Bekliyor';
      case TransferStatus.awaitingApproval:
        return 'Onay bekliyor';
      case TransferStatus.inProgress:
        return item.direction == TransferDirection.sending
            ? 'Gönderiliyor'
            : 'Alınıyor';
      case TransferStatus.paused:
        return 'Duraklatıldı';
      case TransferStatus.verifying:
        return 'Doğrulanıyor';
      case TransferStatus.completed:
        return 'Tamamlandı';
      case TransferStatus.failed:
        return 'Hata';
      case TransferStatus.cancelled:
        return 'İptal';
    }
  }

  IconData _statusIcon() {
    switch (item.status) {
      case TransferStatus.completed:
        return Icons.check_circle_outline;
      case TransferStatus.failed:
        return Icons.error_outline;
      case TransferStatus.inProgress:
      case TransferStatus.verifying:
        return Icons.sync;
      case TransferStatus.paused:
        return Icons.pause_circle_outline;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _revealSavedLocation(BuildContext context) async {
    final path = item.localPath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dosya bulunamadı.')),
      );
      return;
    }

    final opened = await FileLocationOpener.revealSavedFile(path);
    if (!context.mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dosya konumu açılamadı.')),
      );
    }
  }

  String get _revealTooltip {
    if (Platform.isIOS) return 'Dosyayı aç';
    if (Platform.isAndroid) return 'Dosyayı aç';
    return 'Kayıt klasörünü aç';
  }

  IconData get _revealIcon {
    if (Platform.isIOS || Platform.isAndroid) {
      return Icons.open_in_new;
    }
    return Icons.folder_open_outlined;
  }

  Future<void> _shareFile(BuildContext context) async {
    final path = item.localPath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dosya bulunamadı.')),
      );
      return;
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, name: item.name)],
        text: item.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_statusIcon()),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '${_formatBytes(item.bytesTransferred)} / ${_formatBytes(item.size)} · ${_statusLabel()}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (item.status == TransferStatus.completed &&
                    item.localPath != null &&
                    item.direction == TransferDirection.receiving) ...[
                  IconButton(
                    onPressed: () => _revealSavedLocation(context),
                    icon: Icon(_revealIcon),
                    tooltip: _revealTooltip,
                  ),
                  if (Platform.isIOS || Platform.isAndroid)
                    IconButton(
                      onPressed: () => _shareFile(context),
                      icon: Icon(
                        Platform.isIOS ? Icons.ios_share : Icons.share_outlined,
                      ),
                      tooltip: 'Dosyayı paylaş',
                    ),
                ],
              ],
            ),
            if (item.status == TransferStatus.inProgress ||
                item.status == TransferStatus.paused ||
                item.status == TransferStatus.verifying) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: item.progress.clamp(0.0, 1.0),
                    ),
                  ),
                  if (_showTransferControls) ...[
                    IconButton(
                      onPressed: onPauseToggle,
                      icon: Icon(
                        item.status == TransferStatus.paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      tooltip: item.status == TransferStatus.paused
                          ? 'Devam et'
                          : 'Duraklat',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: onCancel,
                      icon: Icon(
                        Icons.close_rounded,
                        color: theme.colorScheme.error,
                      ),
                      tooltip: 'İptal',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
            ],
            if (item.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                item.errorMessage!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
