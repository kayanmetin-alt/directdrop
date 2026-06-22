import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/reconnect_request.dart';
import '../services/paired_devices_service.dart';
import '../services/recent_connection_service.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import '../widgets/download_location_settings.dart';
import '../widgets/my_device_qr_card.dart';
import '../widgets/recent_paired_devices_card.dart';
import '../widgets/app_version_label.dart';
import '../widgets/desktop_centered_layout.dart';
import 'incoming_reconnect_screen.dart';
import 'settings_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Ayarlar',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: isMobile
              ? const ClampingScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(horizontalPadding),
          child: DesktopCenteredLayout(
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
              const DownloadLocationSettings(collapsible: true),
              const SizedBox(height: 16),
              const MyDeviceQrCard(),
              const SizedBox(height: 16),
              const RecentPairedDevicesCard(),
              const SizedBox(height: 16),
              const Center(child: AppVersionLabel()),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
