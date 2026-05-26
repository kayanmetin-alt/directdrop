import 'package:flutter/material.dart';

import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';

/// Onay bekleyen gelen dosya — Aktif transferler listesinde gösterilir.
class ActiveTransferApprovalTile extends StatelessWidget {
  const ActiveTransferApprovalTile({
    super.key,
    required this.controller,
    required this.item,
  });

  final TransferSessionController controller;
  final TransferFileItem item;

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.file_download_outlined,
              color: theme.colorScheme.primary,
            ),
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
                  const SizedBox(height: 2),
                  Text(
                    _formatBytes(item.size),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => controller.rejectIncomingFile(item.id),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('Red'),
            ),
            FilledButton(
              onPressed: () => controller.acceptIncomingFile(item.id),
              child: const Text('Onay'),
            ),
          ],
        ),
      ),
    );
  }
}
