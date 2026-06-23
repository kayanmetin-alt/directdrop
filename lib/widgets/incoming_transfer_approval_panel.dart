import 'package:flutter/material.dart';

import '../models/transfer_file.dart';
import '../providers/transfer_session_controller.dart';
import 'active_transfer_tile.dart';

/// Gelen dosyalar için toplu / tekil onay paneli (açılır liste).
class IncomingTransferApprovalPanel extends StatefulWidget {
  const IncomingTransferApprovalPanel({
    super.key,
    required this.controller,
    required this.items,
  });

  final TransferSessionController controller;
  final List<TransferFileItem> items;

  @override
  State<IncomingTransferApprovalPanel> createState() =>
      _IncomingTransferApprovalPanelState();
}

class _IncomingTransferApprovalPanelState
    extends State<IncomingTransferApprovalPanel> {
  bool _expanded = true;

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  int get _totalBytes =>
      widget.items.fold<int>(0, (sum, item) => sum + item.size);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.items.length;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
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
                          'Gelen dosyalar ($count)',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          'Toplam ${_formatBytes(_totalBytes)} · '
                          'Onaylamadan transfer başlamaz',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () =>
                        widget.controller.acceptAllIncomingFiles(),
                    child: const Text('Tümünü onayla'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        widget.controller.rejectAllIncomingFiles(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      side: BorderSide(color: theme.colorScheme.error),
                    ),
                    child: const Text('Tümünü reddet'),
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(
                      children: [
                        for (final item in widget.items)
                          ActiveTransferApprovalTile(
                            controller: widget.controller,
                            item: item,
                            compact: true,
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
