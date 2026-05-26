import 'dart:async';

import 'package:flutter/material.dart';

import '../models/paired_device.dart';
import '../providers/transfer_session_controller.dart';
import '../services/paired_auto_connect_service.dart';
import '../services/paired_devices_service.dart';
import '../services/paired_presence_service.dart';
import '../services/active_session_registry.dart';
import 'host_screen.dart';
import 'join_screen.dart';
import 'paired_connect_screen.dart';
import 'transfer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _pairedService = PairedDevicesService.instance;
  final _presenceService = PairedPresenceService.instance;
  final _autoConnect = PairedAutoConnectService.instance;
  final Map<String, TransferSessionController> _listenedSessions = {};

  static const _onlineColor = Color(0xFF22C55E);
  static const _offlineColor = Color(0xFF9CA3AF);

  @override
  void initState() {
    super.initState();
    _pairedService.load();
    _pairedService.addListener(_onChanged);
    _presenceService.addListener(_onChanged);
    _autoConnect.addListener(_onChanged);
  }

  @override
  void dispose() {
    _pairedService.removeListener(_onChanged);
    _presenceService.removeListener(_onChanged);
    _autoConnect.removeListener(_onChanged);
    for (final session in _listenedSessions.values) {
      session.removeListener(_onChanged);
    }
    _listenedSessions.clear();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      _syncSessionListeners();
      setState(() {});
    }
  }

  void _syncSessionListeners() {
    final activeIds = <String>{};

    for (final device in _pairedService.devices) {
      final session = _autoConnect.sessionFor(device.deviceId);
      if (session == null || !session.isConnected) continue;

      activeIds.add(device.deviceId);
      if (!_listenedSessions.containsKey(device.deviceId)) {
        _listenedSessions[device.deviceId] = session;
        session.addListener(_onChanged);
      }
    }

    for (final id in _listenedSessions.keys.toList()) {
      if (!activeIds.contains(id)) {
        _listenedSessions.remove(id)?.removeListener(_onChanged);
      }
    }
  }

  int _pendingApprovalCount(PairedDevice device) {
    return _autoConnect
            .sessionFor(device.deviceId)
            ?.awaitingApprovalFiles
            .length ??
        0;
  }

  List<PairedDevice> _sortedDevices(List<PairedDevice> devices) {
    final sorted = List<PairedDevice>.from(devices);
    sorted.sort((a, b) {
      int rank(PairedDevice d) {
        if (_autoConnect.isConnectedTo(d.deviceId)) return 0;
        if (_presenceService.isStrictlyOnline(d.deviceId)) return 1;
        if (_presenceService.isOnline(d.deviceId)) return 2;
        return 3;
      }

      final rankDiff = rank(a).compareTo(rank(b));
      if (rankDiff != 0) return rankDiff;
      return b.lastConnectedAt.compareTo(a.lastConnectedAt);
    });
    return sorted;
  }

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows;
      default:
        return Icons.devices;
    }
  }

  void _openTransfer(PairedDevice device) {
    final session = _autoConnect.sessionFor(device.deviceId);
    if (session == null || !session.isConnected) return;

    ActiveSessionRegistry.instance.register(session);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TransferScreen(
          controller: session,
          peerDeviceId: device.deviceId,
          peerDisplayName: device.displayName,
        ),
      ),
    );
  }

  void _onDeviceTap(PairedDevice device) {
    final online = _presenceService.isStrictlyOnline(device.deviceId);
    final reachable = _presenceService.isOnline(device.deviceId);
    final connected = _autoConnect.isConnectedTo(device.deviceId);
    final connecting = _autoConnect.isConnectingTo(device.deviceId);

    if (connected) {
      _openTransfer(device);
      return;
    }

    final messenger = ScaffoldMessenger.of(context);

    if (!reachable) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${device.displayName} çevrimdışı.'),
        ),
      );
      return;
    }

    if (online || connecting) {
      unawaited(_connectAndOpen(device));
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${device.displayName} yakın zamanda görüldü; uygulamayı açık tutun.',
        ),
      ),
    );
  }

  Future<void> _connectAndOpen(PairedDevice device) async {
    await _autoConnect.requestConnection(device, force: true);

    final session = await _autoConnect.waitForSession(
      device.deviceId,
      timeout: const Duration(seconds: 45),
    );

    if (!mounted) return;

    if (session != null && session.isConnected) {
      _openTransfer(device);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PairedConnectScreen(peer: device),
      ),
    );
  }

  String _deviceSubtitle(PairedDevice device) {
    final pending = _pendingApprovalCount(device);
    final strictlyOnline = _presenceService.isStrictlyOnline(device.deviceId);
    final reachable = _presenceService.isOnline(device.deviceId);
    final connected = _autoConnect.isConnectedTo(device.deviceId);
    final connecting = _autoConnect.isConnectingTo(device.deviceId);

    if (pending > 0) {
      return pending == 1
          ? '1 dosya onayı bekliyor — dokunun'
          : '$pending dosya onayı bekliyor — dokunun';
    }
    if (connected && strictlyOnline) {
      return 'Çevrimiçi · Bağlı — dosya gönderebilirsiniz';
    }
    if (connected) return 'Bağlantı kesiliyor…';
    if (connecting) return 'Çevrimiçi · Bağlanıyor…';
    if (strictlyOnline) return 'Çevrimiçi · Bağlantı bekleniyor — dokunun';
    if (reachable) return 'Yakın zamanda görüldü · Uygulamayı açık tutun';
    return 'Çevrimdışı · Son: ${_formatDate(device.lastConnectedAt)}';
  }

  Color _iconColor(PairedDevice device) {
    final connected = _autoConnect.isConnectedTo(device.deviceId);
    final online = _presenceService.isStrictlyOnline(device.deviceId);
    if (connected && online) return _onlineColor;
    if (online) return _onlineColor;
    return _offlineColor;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairedDevices = _sortedDevices(_pairedService.devices);

    return Scaffold(
      appBar: AppBar(
        title: const Text('DirectDrop'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.swap_horiz_rounded,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Cihazlar arası anlık dosya transferi',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Çevrimiçi eşleşmiş cihazlar otomatik bağlanır.\n'
                'Bağlı cihaza dokunarak dosya gönderebilirsiniz.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
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
              Text(
                'Eşleşmiş cihazlar',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: pairedDevices.isEmpty
                    ? Center(
                        child: Text(
                          'Henüz kayıtlı cihaz yok.\nQR ile bir kez eşleştirin; burada görünür.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: pairedDevices.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final device = pairedDevices[index];
                          final connected =
                              _autoConnect.isConnectedTo(device.deviceId);
                          final connecting =
                              _autoConnect.isConnectingTo(device.deviceId);
                          final strictlyOnline = _presenceService
                              .isStrictlyOnline(device.deviceId);
                          final reachable =
                              _presenceService.isOnline(device.deviceId);
                          final pending = _pendingApprovalCount(device);

                          return Card(
                            color: pending > 0
                                ? theme.colorScheme.tertiaryContainer
                                    .withValues(alpha: 0.35)
                                : connected
                                    ? theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.25)
                                    : null,
                            child: ListTile(
                              leading: Icon(
                                _platformIcon(device.platform),
                                color: pending > 0
                                    ? theme.colorScheme.tertiary
                                    : _iconColor(device),
                              ),
                              title: Text(device.displayName),
                              subtitle: Text(_deviceSubtitle(device)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (pending > 0)
                                    IconButton(
                                      icon: Badge(
                                        label: Text('$pending'),
                                        child:
                                            const Icon(Icons.file_download),
                                      ),
                                      color: theme.colorScheme.tertiary,
                                      tooltip: 'Onay bekleyen dosya',
                                      onPressed: () => _openTransfer(device),
                                    )
                                  else if (connected)
                                    IconButton(
                                      icon: const Icon(Icons.upload_file),
                                      color: _onlineColor,
                                      tooltip: 'Dosya gönder',
                                      onPressed: () => _openTransfer(device),
                                    )
                                  else if (connecting)
                                    const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  else if (strictlyOnline || connecting)
                                    Icon(
                                      Icons.circle,
                                      size: 10,
                                      color: strictlyOnline
                                          ? _onlineColor
                                          : _offlineColor,
                                    )
                                  else if (reachable)
                                    const Icon(
                                      Icons.circle_outlined,
                                      size: 10,
                                      color: _offlineColor,
                                    ),
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
                                ],
                              ),
                              onTap: () => _onDeviceTap(device),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (now.difference(date).inDays == 0) {
      return 'bugün ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}.${date.month}.${date.year}';
  }
}
