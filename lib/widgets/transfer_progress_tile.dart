import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/transfer_file.dart';

class TransferProgressTile extends StatelessWidget {
  const TransferProgressTile({
    super.key,
    required this.item,
  });

  final TransferFileItem item;

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
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${_formatBytes(item.bytesTransferred)} / ${_formatBytes(item.size)} · ${_statusLabel()}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (item.status == TransferStatus.completed &&
                    item.localPath != null &&
                    item.direction == TransferDirection.receiving)
                  IconButton(
                    onPressed: () => _shareFile(context),
                    icon: const Icon(Icons.ios_share),
                    tooltip: 'Dosyayı paylaş / kaydet',
                  ),
              ],
            ),
            if (item.status == TransferStatus.inProgress ||
                item.status == TransferStatus.verifying) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: item.progress.clamp(0.0, 1.0)),
            ],
            if (item.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                item.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
