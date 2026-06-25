import 'package:flutter/material.dart';

/// Karşı cihazdan onay beklerken gösterilen durum ekranı.
class ConnectWaitingPanel extends StatelessWidget {
  const ConnectWaitingPanel({
    super.key,
    required this.peerDisplayName,
    this.statusMessage,
    this.subtitle,
  });

  final String peerDisplayName;
  final String? statusMessage;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 400,
                minHeight: constraints.maxHeight > 0
                    ? constraints.maxHeight - 64
                    : 0,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.hourglass_top,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '$peerDisplayName cihazına istek iletildi',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    subtitle ??
                        'Karşı cihazda bildirime dokunulması ve onay '
                        'bekleniyor. Onaylanırsa bağlantı otomatik kurulur.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const CircularProgressIndicator(),
                  if (statusMessage != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      statusMessage!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
