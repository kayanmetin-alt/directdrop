import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class RoomCodeDisplay extends StatelessWidget {
  const RoomCodeDisplay({
    super.key,
    required this.roomCode,
    this.embedded = false,
  });

  final String roomCode;

  /// Kart içinde kullanıldığında dış Card ve fazla boşluk kaldırılır.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = Platform.isIOS || Platform.isAndroid;
    final qrSize = isMobile ? 128.0 : 160.0;

    final content = Column(
      children: [
        Text(
          'Oda Kodu',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          roomCode,
          style: theme.textTheme.headlineMedium?.copyWith(
            letterSpacing: isMobile ? 4 : 8,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: isMobile ? 16 : 24),
        RepaintBoundary(
          child: QrImageView(
            data: roomCode,
            version: QrVersions.auto,
            size: qrSize,
            backgroundColor: Colors.white,
            gapless: true,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Diğer cihaz bu kodu girebilir veya QR okutabilir.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );

    if (embedded) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: content,
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: content,
      ),
    );
  }
}
