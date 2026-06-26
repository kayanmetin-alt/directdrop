import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class RoomCodeDisplay extends StatelessWidget {
  const RoomCodeDisplay({
    super.key,
    required this.roomCode,
    this.embedded = false,
    this.isDeviceInvite = false,
  });

  final String roomCode;

  /// Kart içinde kullanıldığında dış Card ve fazla boşluk kaldırılır.
  final bool embedded;

  /// `true` → cihaz davet QR'ı; `false` → geçici oda QR'ı (Transfer Başlat).
  final bool isDeviceInvite;

  Future<void> _copyRoomCode(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: roomCode));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Oda kodu kopyalandı: $roomCode'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              roomCode,
              style: theme.textTheme.headlineMedium?.copyWith(
                letterSpacing: isMobile ? 4 : 8,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: () => _copyRoomCode(context),
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'Oda kodunu kopyala',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        SizedBox(height: isMobile ? 16 : 24),
        RepaintBoundary(
          child: QrImageView(
            data: isDeviceInvite
                ? 'directdrop://device/$roomCode'
                : 'directdrop://join/$roomCode',
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
