import 'package:flutter/material.dart';

import '../models/transfer_file.dart';
import '../models/transfer_history_record.dart';
import 'transfer_progress_tile.dart';

class TransferHistoryTile extends StatelessWidget {
  const TransferHistoryTile({
    super.key,
    required this.record,
  });

  final TransferHistoryRecord record;

  String _formatTime(DateTime date) {
    final time =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    if (now.difference(date).inDays == 0) return 'bugün $time';
    return '${date.day}.${date.month}.${date.year} $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final directionLabel = record.direction == TransferDirection.sending
        ? 'Gönderildi'
        : 'Alındı';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4, top: 4),
          child: Text(
            '${record.peerName} · $directionLabel · ${_formatTime(record.completedAt)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TransferProgressTile(item: record.toDisplayItem()),
      ],
    );
  }
}
