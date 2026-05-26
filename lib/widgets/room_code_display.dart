import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class RoomCodeDisplay extends StatelessWidget {
  const RoomCodeDisplay({
    super.key,
    required this.roomCode,
  });

  final String roomCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              'Oda Kodu',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              roomCode,
              style: theme.textTheme.displaySmall?.copyWith(
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            QrImageView(
              data: roomCode,
              version: QrVersions.auto,
              size: 160,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              'Diğer cihaz bu kodu girebilir veya QR okutabilir.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
