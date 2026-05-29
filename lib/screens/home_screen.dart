import 'dart:async';

import 'package:flutter/material.dart';

import '../models/paired_device.dart';
import '../services/paired_devices_service.dart';
import '../services/recent_connection_service.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'recent_connect_screen.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/app_version_label.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('DirectDrop'),
        centerTitle: true,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(child: AppVersionLabel(compact: true)),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              const SizedBox(height: 20),
              const DownloadLocationSettings(),
              const SizedBox(height: 20),
              Text(
                'Son eşleşmeler',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Yalnızca bir cihazdan eşleşmeye dokunun. Diğer tarafta uygulama '
                'açık kalsın — oda orada otomatik açılır (QR gerekmez).',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: recent.isEmpty
                    ? Center(
                        child: Text(
                          'Henüz kayıtlı eşleşme yok.\n'
                          'İlk bağlantıyı QR veya kod ile yapın.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: recent.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final device = recent[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                _platformIcon(device.platform),
                                color: theme.colorScheme.primary,
                              ),
                              title: Text(device.displayName),
                              subtitle: Text(
                                'Son: ${_formatLastSeen(device.lastConnectedAt)}',
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
                              onTap: () => _openRecentConnect(device),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              const AppVersionLabel(),
            ],
          ),
        ),
      ),
    );
  }
}
