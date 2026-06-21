import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reconnect_request.dart';
import '../models/paired_device.dart';
import '../services/paired_devices_service.dart';
import '../services/recent_connection_service.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'recent_connect_screen.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/my_device_qr_card.dart';
import '../widgets/app_version_label.dart';
import 'about_screen.dart';
import 'incoming_reconnect_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _pairedService = PairedDevicesService.instance;
  final _recentConnect = RecentConnectionService.instance;

  @override
  void initState() {
    super.initState();
    _pairedService.load();
    _pairedService.addListener(_onChanged);
    _recentConnect.addListener(_onChanged);
    unawaited(_recentConnect.ensureListening());
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

  void _openRecentConnect(PairedDevice peer, {bool autoAcceptInvite = false}) {
    if (!autoAcceptInvite) {
      _recentConnect.clearIncomingInvite();
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecentConnectScreen(
          peer: peer,
          autoAcceptInvite: autoAcceptInvite,
        ),
      ),
    );
  }

  Future<void> _approveReconnect(ReconnectRequest request) async {
    _recentConnect.dismissIncomingReconnectUi(request);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => IncomingReconnectScreen(
          request: request,
          autoApprove: true,
        ),
      ),
    );
  }

  void _rejectReconnect(ReconnectRequest request) {
    unawaited(_recentConnect.rejectReconnectRequest(request));
  }

  Widget _buildReconnectTopRow(
    ThemeData theme,
    ReconnectRequest reconnect,
  ) {
    return Material(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            Icon(
              Icons.link,
              color: theme.colorScheme.primary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${reconnect.fromDeviceName} bağlantı kurmak istiyor',
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              color: theme.colorScheme.primary,
              tooltip: 'Onayla',
              onPressed: () => _approveReconnect(reconnect),
            ),
            IconButton(
              icon: const Icon(Icons.cancel_outlined),
              color: theme.colorScheme.error,
              tooltip: 'Reddet',
              onPressed: () => _rejectReconnect(reconnect),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _reconnectRowActions(
    ThemeData theme,
    ReconnectRequest? pendingReconnect,
  ) {
    if (pendingReconnect == null) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.check_circle_outline),
          color: theme.colorScheme.primary,
          tooltip: 'Onayla',
          onPressed: () => _approveReconnect(pendingReconnect),
        ),
        IconButton(
          icon: const Icon(Icons.cancel_outlined),
          color: theme.colorScheme.error,
          tooltip: 'Reddet',
          onPressed: () => _rejectReconnect(pendingReconnect),
        ),
      ],
    );
  }

  Widget _deviceRowCard({
    required ThemeData theme,
    required PairedDevice device,
    required ReconnectRequest? pendingReconnect,
  }) {
    final rowActions = _reconnectRowActions(theme, pendingReconnect);

    return Card(
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
        trailing: rowActions ??
            PopupMenuButton<String>(
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = _pairedService.devices;
    final incoming = _recentConnect.incomingInvitePeer;
    final reconnect = _recentConnect.incomingReconnectRequest;

    final isMobile = Platform.isIOS || Platform.isAndroid;
    final horizontalPadding = isMobile ? 16.0 : 24.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DirectDrop'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Hakkında',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AboutScreen(),
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: AppVersionLabel(compact: true)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: isMobile
              ? const ClampingScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(horizontalPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reconnect != null) ...[
                _buildReconnectTopRow(theme, reconnect),
                const SizedBox(height: 16),
              ],
              if (incoming != null) ...[
                Material(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${incoming.displayName} bağlanıyor…',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const HostScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.upload_file),
                label: const Text('Transfer Başlat'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const JoinScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.download),
                label: const Text('Koda Katıl'),
              ),
              const SizedBox(height: 16),
              const DownloadLocationSettings(),
              const SizedBox(height: 16),
              const MyDeviceQrCard(),
              const SizedBox(height: 16),
              Text(
                'Son eşleşmeler',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Listeden dokunun; karşı cihazda onay isteği görünür.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              if (recent.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Henüz kayıtlı eşleşme yok.\n'
                    'Yukarıdaki QR kodunuzu okutarak veya Koda Katıl ile bağlanın.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
              const SizedBox(height: 16),
              const Center(child: AppVersionLabel()),
            ],
          ),
        ),
      ),
    );
  }
}
