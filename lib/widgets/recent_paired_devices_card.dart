import 'package:flutter/material.dart';

import '../models/paired_device.dart';
import '../models/reconnect_request.dart';
import '../screens/recent_connect_screen.dart';
import '../services/paired_devices_service.dart';
import '../services/recent_connection_service.dart';

/// Ana ekranda son eşleşmiş cihazlar — varsayılan kapalı, ok ile açılır.
class RecentPairedDevicesCard extends StatefulWidget {
  const RecentPairedDevicesCard({super.key});

  @override
  State<RecentPairedDevicesCard> createState() =>
      _RecentPairedDevicesCardState();
}

class _RecentPairedDevicesCardState extends State<RecentPairedDevicesCard> {
  final _pairedService = PairedDevicesService.instance;
  final _recentConnect = RecentConnectionService.instance;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _pairedService.addListener(_onChanged);
    _recentConnect.addListener(_onChanged);
  }

  @override
  void dispose() {
    _pairedService.removeListener(_onChanged);
    _recentConnect.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _openRecentConnect(PairedDevice peer) {
    _recentConnect.clearIncomingInvite();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecentConnectScreen(peer: peer),
      ),
    );
  }

  Widget _deviceRowCard({
    required ThemeData theme,
    required PairedDevice device,
    required ReconnectRequest? pendingReconnect,
  }) {
    // Gelen bağlantı isteğinin onayı yalnızca tam ekran "gelen arama" ekranından
    // yapılır; bu satırda artık onay/ret butonu yok, sadece bilgi gösterilir.
    return Card(
      margin: EdgeInsets.zero,
      color: pendingReconnect != null
          ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.35)
          : null,
      child: ListTile(
        leading: Icon(
          _platformIcon(device.platform),
          color: theme.colorScheme.primary,
        ),
        title: Text(device.displayName),
        subtitle: Text(
          pendingReconnect != null
              ? 'Bağlantı isteği bekliyor'
              : 'Son: ${_formatLastSeen(device.lastConnectedAt)}',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'remove') {
              _pairedService.remove(device.deviceId);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'remove',
              child: Text('Listeden kaldır'),
            ),
          ],
        ),
        onTap: pendingReconnect != null
            ? null
            : () => _openRecentConnect(device),
      ),
    );
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows;
      case 'android':
        return Icons.phone_android;
      default:
        return Icons.devices;
    }
  }

  String _formatLastSeen(DateTime date) {
    final now = DateTime.now();
    if (now.difference(date).inDays == 0) {
      return 'bugün ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}.${date.month}.${date.year}';
  }

  String _collapsedSubtitle(int count) {
    if (count == 0) return 'Henüz kayıtlı eşleşme yok';
    if (count == 1) return '1 cihaz — dokunarak listeyi göster';
    return '$count cihaz — dokunarak listeyi göster';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = _pairedService.devices;
    final reconnect = _recentConnect.incomingReconnectRequest;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.devices_outlined,
                    color: theme.colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Son eşleşmeler',
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          _collapsedSubtitle(recent.length),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    tooltip: _expanded ? 'Listeyi gizle' : 'Listeyi göster',
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Listeden dokunun; karşı cihazda onay isteği görünür.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (recent.isEmpty)
                    Text(
                      'Henüz kayıtlı eşleşme yok.\n'
                      'QR kodunuzu okutarak veya Koda Katıl ile bağlanın.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    ...recent.map(
                      (device) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _deviceRowCard(
                          theme: theme,
                          device: device,
                          pendingReconnect:
                              reconnect?.fromDeviceId == device.deviceId
                                  ? reconnect
                                  : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
